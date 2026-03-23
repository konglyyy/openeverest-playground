#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Reconciles the optional SeaweedFS-based backup stack.
# When backup is enabled it deploys the shared S3 endpoint plus the backup
# resources used by the shared DB namespace; when disabled it removes them.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env

rendered_storage="$(mktemp)"
rendered_bucket_job="$(mktemp)"
rendered_backup_storage="$(mktemp)"
generated_tls_dir="$(mktemp -d)"
generated_tls_cert="${generated_tls_dir}/tls.crt"
generated_tls_key="${generated_tls_dir}/tls.key"
generated_tls_config="${generated_tls_dir}/openssl.cnf"
trap 'rm -f "${rendered_storage}" "${rendered_bucket_job}" "${rendered_backup_storage}"; rm -rf "${generated_tls_dir}"' EXIT

backup_bucket_job_timeout_seconds="${PLAYGROUND_BACKUP_BUCKET_JOB_TIMEOUT_SECONDS:-300}"

# Flatten the namespace-to-bucket mapping into the whitespace-delimited list
# consumed by the bucket init job template.
bucket_list="$(
  for namespace in $(managed_db_namespaces); do
    backup_bucket_for_namespace "${namespace}"
  done | tr '\n' ' ' | sed 's/[[:space:]]*$//'
)"

# SeaweedFS runs as a single pod with one PVC because the playground only needs
# a compact S3-compatible endpoint for local backup feature testing.
render_template \
  "${ROOT_DIR}/manifests/backup/seaweedfs.yaml" \
  -e "s|__PLAYGROUND_SYSTEM_NAMESPACE__|${PLAYGROUND_SYSTEM_NAMESPACE}|g" \
  -e "s|__SEAWEEDFS_IMAGE__|${SEAWEEDFS_IMAGE}|g" \
  -e "s|__SEAWEEDFS_SERVICE_NAME__|${SEAWEEDFS_SERVICE_NAME}|g" \
  -e "s|__SEAWEEDFS_S3_PORT__|${SEAWEEDFS_S3_PORT}|g" \
  -e "s|__SEAWEEDFS_S3_HTTPS_PORT__|${SEAWEEDFS_S3_HTTPS_PORT}|g" \
  -e "s|__SEAWEEDFS_TLS_SECRET_NAME__|${SEAWEEDFS_TLS_SECRET_NAME}|g" \
  -e "s|__SEAWEEDFS_VOLUME_SIZE__|${SEAWEEDFS_VOLUME_SIZE}|g" \
  -e "s|__SEAWEEDFS_ACCESS_KEY__|${SEAWEEDFS_ACCESS_KEY}|g" \
  -e "s|__SEAWEEDFS_SECRET_KEY__|${SEAWEEDFS_SECRET_KEY}|g" \
  >"${rendered_storage}"
render_template \
  "${ROOT_DIR}/manifests/backup/bucket-job.yaml" \
  -e "s|__PLAYGROUND_SYSTEM_NAMESPACE__|${PLAYGROUND_SYSTEM_NAMESPACE}|g" \
  -e "s|__AWS_CLI_IMAGE__|${AWS_CLI_IMAGE}|g" \
  -e "s|__SEAWEEDFS_SERVICE_NAME__|${SEAWEEDFS_SERVICE_NAME}|g" \
  -e "s|__SEAWEEDFS_S3_PORT__|${SEAWEEDFS_S3_PORT}|g" \
  -e "s|__AWS_DEFAULT_REGION__|${AWS_DEFAULT_REGION}|g" \
  -e "s|__SEAWEEDFS_BUCKET_LIST__|${bucket_list}|g" \
  >"${rendered_bucket_job}"

# Renders the namespace-scoped secret and BackupStorage manifest for one DBaaS
# namespace so the caller can either apply or delete it as needed.
render_namespace_backup_resources() {
  local namespace="$1"

  # Everest's BackupStorage CR expects a full endpoint URL here. The operator
  # derives the pgBackRest S3 host/port/TLS settings from that URL.
  render_template \
    "${ROOT_DIR}/manifests/backup/backup-storage.yaml" \
    -e "s|__DB_NAMESPACE__|${namespace}|g" \
    -e "s|__BACKUP_STORAGE_NAME__|${BACKUP_STORAGE_NAME}|g" \
    -e "s|__BACKUP_SECRET_NAME__|${BACKUP_STORAGE_NAME}-credentials|g" \
    -e "s|__SEAWEEDFS_ACCESS_KEY__|${SEAWEEDFS_ACCESS_KEY}|g" \
    -e "s|__SEAWEEDFS_SECRET_KEY__|${SEAWEEDFS_SECRET_KEY}|g" \
    -e "s|__SEAWEEDFS_ENDPOINT__|$(seaweedfs_endpoint)|g" \
    -e "s|__AWS_DEFAULT_REGION__|${AWS_DEFAULT_REGION}|g" \
    -e "s|__BACKUP_BUCKET__|$(backup_bucket_for_namespace "${namespace}")|g" \
    >"${rendered_backup_storage}"
}

# Generates a self-signed certificate for the in-cluster SeaweedFS HTTPS
# endpoint so pgBackRest can talk to S3 over TLS without requiring a public CA.
render_seaweedfs_tls_assets() {
  cat >"${generated_tls_config}" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_req

[req_distinguished_name]
CN = ${SEAWEEDFS_SERVICE_NAME}.${PLAYGROUND_SYSTEM_NAMESPACE}.svc.cluster.local

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${SEAWEEDFS_SERVICE_NAME}
DNS.2 = ${SEAWEEDFS_SERVICE_NAME}.${PLAYGROUND_SYSTEM_NAMESPACE}
DNS.3 = ${SEAWEEDFS_SERVICE_NAME}.${PLAYGROUND_SYSTEM_NAMESPACE}.svc
DNS.4 = ${SEAWEEDFS_SERVICE_NAME}.${PLAYGROUND_SYSTEM_NAMESPACE}.svc.cluster.local
EOF

  openssl req \
    -x509 \
    -nodes \
    -newkey rsa:2048 \
    -sha256 \
    -days 3650 \
    -keyout "${generated_tls_key}" \
    -out "${generated_tls_cert}" \
    -config "${generated_tls_config}" \
    >/dev/null 2>&1
}

# Reconciles the TLS secret mounted by SeaweedFS for its HTTPS S3 listener.
reconcile_seaweedfs_tls_secret() {
  require_cmd openssl
  render_seaweedfs_tls_assets

  kubectl --context "${KUBE_CONTEXT}" create secret tls "${SEAWEEDFS_TLS_SECRET_NAME}" \
    -n "${PLAYGROUND_SYSTEM_NAMESPACE}" \
    --cert="${generated_tls_cert}" \
    --key="${generated_tls_key}" \
    --dry-run=client \
    -o yaml \
    | kubectl --context "${KUBE_CONTEXT}" apply --validate=false -f - >/dev/null
}

# Removes backup resources that this playground owns when backup testing is
# disabled or toggled off in a later `task init` run.
remove_backup_resources() {
  for namespace in $(managed_db_namespaces); do
    if ! k get namespace "${namespace}" >/dev/null 2>&1; then
      continue
    fi

    render_namespace_backup_resources "${namespace}"
    k delete -f "${rendered_backup_storage}" --ignore-not-found >/dev/null
  done

  if k get namespace "${PLAYGROUND_SYSTEM_NAMESPACE}" >/dev/null 2>&1; then
    k delete job seaweedfs-bucket-init -n "${PLAYGROUND_SYSTEM_NAMESPACE}" --ignore-not-found >/dev/null
    k delete secret "${SEAWEEDFS_TLS_SECRET_NAME}" -n "${PLAYGROUND_SYSTEM_NAMESPACE}" --ignore-not-found >/dev/null
    k delete -f "${rendered_storage}" --ignore-not-found >/dev/null
    k delete namespace "${PLAYGROUND_SYSTEM_NAMESPACE}" --ignore-not-found >/dev/null
  fi
}

# Reconciles the shared SeaweedFS deployment and waits for its pod to become ready.
reconcile_shared_backup_endpoint() {
  ensure_namespace "${PLAYGROUND_SYSTEM_NAMESPACE}"
  reconcile_seaweedfs_tls_secret
  k apply --validate=false -f "${rendered_storage}"
  kubectl --context "${KUBE_CONTEXT}" rollout status deployment/seaweedfs -n "${PLAYGROUND_SYSTEM_NAMESPACE}" --timeout=300s >/dev/null
}

# Recreates the bucket-init job and waits for it to provision the shared backup buckets.
backup_bucket_job_complete() {
  k_query get job seaweedfs-bucket-init -n "${PLAYGROUND_SYSTEM_NAMESPACE}" -o json | jq -e '
    any(.status.conditions[]?; .type == "Complete" and .status == "True")
  ' >/dev/null
}

# Returns the first terminal failure reason reported by the bucket-init Job.
backup_bucket_job_failure_reason() {
  k_query get job seaweedfs-bucket-init -n "${PLAYGROUND_SYSTEM_NAMESPACE}" -o json | jq -r '
    if any(.status.conditions[]?; .type == "Failed" and .status == "True") then
      "seaweedfs-bucket-init reports a failed Job condition"
    elif (
      (.status.failed // 0) > 0
      and (.status.succeeded // 0) == 0
      and (.status.failed // 0) >= (.spec.backoffLimit // 0)
    ) then
      "seaweedfs-bucket-init exhausted its Job retries"
    else
      empty
    end
  ' 2>/dev/null
}

# Waits for the bucket-init Job to complete and aborts early on failed status.
wait_for_backup_bucket_job() {
  local deadline=0
  local reason=""

  deadline=$((SECONDS + backup_bucket_job_timeout_seconds))

  until backup_bucket_job_complete; do
    if reason="$(backup_bucket_job_failure_reason)" && [ -n "${reason}" ]; then
      printf '%s\n' "Detected a terminal backup bucket initialization failure: ${reason}." >&2
      return 1
    fi

    if [ "${SECONDS}" -ge "${deadline}" ]; then
      printf '%s\n' "Timed out waiting for the seaweedfs-bucket-init Job to complete." >&2
      return 1
    fi

    sleep 5
  done
}

# Recreates the bucket-init job and waits for it to provision the shared backup buckets.
reconcile_backup_buckets() {
  # The bucket init job is recreated on each run so spec changes remain safe.
  k delete job seaweedfs-bucket-init -n "${PLAYGROUND_SYSTEM_NAMESPACE}" --ignore-not-found >/dev/null
  k apply --validate=false -f "${rendered_bucket_job}"
  wait_for_backup_bucket_job
}

# Applies the backup definition in each managed DB namespace. The playground
# layout exposes one shared DB namespace, so this reconciles one
# BackupStorage object.
reconcile_namespace_backup_storage() {
  local namespace=""

  for namespace in $(managed_db_namespaces); do
    ensure_namespace "${namespace}"
    render_namespace_backup_resources "${namespace}"

    # Reapplying the secret and BackupStorage keeps the shared DB namespace
    # backup definition aligned with the shared SeaweedFS endpoint and credentials.
    k apply --validate=false -f "${rendered_backup_storage}"
  done
}

if ! backup_enabled; then
  if k get namespace "${PLAYGROUND_SYSTEM_NAMESPACE}" >/dev/null 2>&1; then
    run_step \
      "Removing optional backup resources" \
      "Removed optional backup resources" \
      remove_backup_resources \
      || die "Unable to remove the optional backup resources."
  fi
  exit 0
fi

run_step \
  "Starting SeaweedFS for the shared backup endpoint" \
  "Started SeaweedFS for the shared backup endpoint." \
  reconcile_shared_backup_endpoint \
  || die "Unable to start SeaweedFS for the shared backup endpoint."

run_step \
  "Creating shared backup buckets" \
  "Created shared backup buckets." \
  reconcile_backup_buckets \
  || die "Unable to create the shared backup buckets."

# Each managed DB namespace gets its own BackupStorage object even though the
# underlying endpoint and credentials are shared.
run_step \
  "Reconciling DB namespace backup storage" \
  "Reconciled DB namespace backup storage." \
  reconcile_namespace_backup_storage \
  || die "Unable to apply the DB namespace backup storage resources."
