#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Waits for the OpenEverest playground to become usable.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env

action="${1:-}"
[ -n "${action}" ] || die "Usage: $0 <install|resume>"

platform_pod_timeout_seconds="${PLAYGROUND_PLATFORM_POD_TIMEOUT_SECONDS:-420}"
backup_pod_timeout_seconds="${PLAYGROUND_BACKUP_POD_TIMEOUT_SECONDS:-240}"
engine_discovery_timeout_seconds="${PLAYGROUND_ENGINE_DISCOVERY_TIMEOUT_SECONDS:-600}"
db_operator_selector="app.kubernetes.io/component=operator"

# Retries one readiness check command until it succeeds or times out.
wait_for_command() {
  local description="$1"
  local timeout_seconds="$2"
  shift 2

  local deadline
  deadline=$((SECONDS + timeout_seconds))

  until "$@"; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      printf '%s\n' "Timed out waiting for ${description}." >&2
      return 1
    fi
    sleep 5
  done
}

# Returns success when the requested namespace exists.
namespace_exists() {
  k_query get namespace "$1" >/dev/null 2>&1
}

# Waits for one namespace to exist.
wait_for_namespace() {
  wait_for_command "namespace $1" 300 namespace_exists "$1"
}

# Waits for one CRD to report the Established condition.
wait_for_crd() {
  kubectl --context "${KUBE_CONTEXT}" wait --for=condition=Established --timeout=300s "crd/$1" >/dev/null
}

# Returns success when every non-terminal pod in one namespace is Ready.
pods_ready_in_namespace() {
  local namespace="$1"
  local selector="${2:-}"
  local query_args=(-n "${namespace}" get pods)

  if [ -n "${selector}" ]; then
    query_args+=(-l "${selector}")
  fi

  query_args+=(-o json)

  k_query "${query_args[@]}" | jq -e '
    [.items[]?
      | select(.metadata.deletionTimestamp == null)
      | select(.status.phase != "Succeeded" and .status.phase != "Failed")] as $pods
    | ($pods | length) > 0
    | if . then
        all($pods[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      else
        false
      end
  ' >/dev/null
}

# Returns the first terminal waiting reason from a still-active pod in one namespace.
pod_failure_reason_in_namespace() {
  local namespace="$1"
  local selector="${2:-}"
  local query_args=(-n "${namespace}" get pods)

  if [ -n "${selector}" ]; then
    query_args+=(-l "${selector}")
  fi

  query_args+=(-o json)

  k_query "${query_args[@]}" | jq -r '
    [
      .items[]?
      | select(.metadata.deletionTimestamp == null)
      | .metadata.name as $pod
      | ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
      | .name as $container
      | (.state.waiting.reason // "") as $reason
      | select(
          $reason == "ImagePullBackOff"
          or $reason == "ErrImagePull"
          or $reason == "CrashLoopBackOff"
          or $reason == "CreateContainerConfigError"
          or $reason == "CreateContainerError"
          or $reason == "InvalidImageName"
          or $reason == "RunContainerError"
        )
      | "\($pod) container \($container) is stuck in \($reason)"
    ][0] // empty
  ' 2>/dev/null
}

# Returns the first terminal workload failure reason found in one namespace.
namespace_workload_failure_reason() {
  local namespace="$1"
  local selector="${2:-}"
  local reason=""

  reason="$(pod_failure_reason_in_namespace "${namespace}" "${selector}")"
  if [ -n "${reason}" ]; then
    printf '%s\n' "${reason}"
    return 0
  fi

  return 1
}

# Returns success when one DB engine reports installed status and available versions.
dbengine_ready() {
  local engine_type="$1"

  k_query -n "${EVEREST_DATABASE_NAMESPACE}" get dbengine -o json | jq -e --arg engine_type "${engine_type}" '
    any(
      .items[];
      ((.spec.type // "") == $engine_type or ((.metadata.name // "") | test($engine_type)))
      and (.status.status // "") == "installed"
      and ((.status.availableVersions.engine // {}) | length > 0)
    )
  ' >/dev/null
}

# Returns the first DatabaseEngine object that already reports a terminal error state.
dbengine_failure_reason() {
  k_query -n "${EVEREST_DATABASE_NAMESPACE}" get dbengine -o json | jq -r '
    [
      .items[]?
      | (.status.status // "") as $status
      | select(($status | ascii_downcase) | test("failed|error"))
      | "\(.metadata.name) reports status \($status)"
    ][0] // empty
  ' 2>/dev/null
}

# Returns success when the shared BackupStorage object exists in the DB namespace.
backupstorage_exists() {
  k_query -n "${EVEREST_DATABASE_NAMESPACE}" get backupstorage "${BACKUP_STORAGE_NAME}" >/dev/null 2>&1
}

# Waits for one namespace to have only Ready non-terminal pods and aborts early
# when any active pod is already in a terminal failure state.
wait_for_namespace_pods_ready() {
  local namespace="$1"
  local timeout_seconds="$2"
  local selector="${3:-}"
  local deadline=0
  local reason=""

  deadline=$((SECONDS + timeout_seconds))

  until pods_ready_in_namespace "${namespace}" "${selector}"; do
    if reason="$(namespace_workload_failure_reason "${namespace}" "${selector}")" && [ -n "${reason}" ]; then
      printf '%s\n' "Detected a terminal workload failure in ${namespace}: ${reason}." >&2
      return 1
    fi

    if [ "${SECONDS}" -ge "${deadline}" ]; then
      printf '%s\n' "Timed out waiting for pods in ${namespace}." >&2
      return 1
    fi

    sleep 5
  done
}

# Returns success when every managed DB engine reports installed status and versions.
all_dbengines_ready() {
  local engine=""

  while IFS= read -r engine; do
    dbengine_ready "${engine}" || return 1
  done < <(managed_database_engines)
}

# Returns the first terminal engine discovery reason visible in the DB namespace.
db_operator_failure_reason() {
  local reason=""

  reason="$(namespace_workload_failure_reason "${EVEREST_DATABASE_NAMESPACE}" "${db_operator_selector}")"
  if [ -n "${reason}" ]; then
    printf '%s\n' "${reason}"
    return 0
  fi

  reason="$(dbengine_failure_reason)"
  if [ -n "${reason}" ]; then
    printf '%s\n' "${reason}"
    return 0
  fi

  return 1
}

# Waits for the Everest namespaces and CRDs that gate later readiness checks.
wait_for_platform_prerequisites() {
  wait_for_namespace "${EVEREST_NAMESPACE}" || return 1
  wait_for_namespace "${EVEREST_OLM_NAMESPACE}" || return 1
  wait_for_namespace "${EVEREST_MONITORING_NAMESPACE}" || return 1
  wait_for_namespace "${EVEREST_DATABASE_NAMESPACE}" || return 1
  wait_for_crd "databaseclusters.everest.percona.com" || return 1
  wait_for_crd "databaseengines.everest.percona.com" || return 1
  if backup_enabled; then
    wait_for_namespace "${PLAYGROUND_SYSTEM_NAMESPACE}" || return 1
    wait_for_crd "backupstorages.everest.percona.com" || return 1
  fi
}

# Waits for the main Everest namespaces to have only Ready non-terminal pods.
wait_for_platform_pods() {
  wait_for_namespace_pods_ready "${EVEREST_NAMESPACE}" "${platform_pod_timeout_seconds}" || return 1
  wait_for_namespace_pods_ready "${EVEREST_OLM_NAMESPACE}" "${platform_pod_timeout_seconds}" || return 1
  wait_for_namespace_pods_ready "${EVEREST_MONITORING_NAMESPACE}" "${platform_pod_timeout_seconds}" || return 1
  wait_for_namespace_pods_ready "${EVEREST_DATABASE_NAMESPACE}" "${platform_pod_timeout_seconds}" || return 1

  if backup_enabled; then
    wait_for_namespace_pods_ready "${PLAYGROUND_SYSTEM_NAMESPACE}" "${backup_pod_timeout_seconds}" || return 1
  fi
}

# Waits for the core Everest control-plane pods needed to use the UI after a resume.
# User-created database workloads are excluded so an unhealthy restored replica
# does not block `task up` from bringing the playground back.
wait_for_resume_platform_pods() {
  wait_for_namespace_pods_ready "${EVEREST_NAMESPACE}" "${platform_pod_timeout_seconds}" || return 1
  wait_for_namespace_pods_ready "${EVEREST_OLM_NAMESPACE}" "${platform_pod_timeout_seconds}" || return 1
  wait_for_namespace_pods_ready "${EVEREST_MONITORING_NAMESPACE}" "${platform_pod_timeout_seconds}" || return 1
  wait_for_namespace_pods_ready "${EVEREST_DATABASE_NAMESPACE}" "${platform_pod_timeout_seconds}" "${db_operator_selector}" || return 1

  if backup_enabled; then
    wait_for_namespace_pods_ready "${PLAYGROUND_SYSTEM_NAMESPACE}" "${backup_pod_timeout_seconds}" || return 1
  fi
}

# Waits for all managed engines to publish versions under one shared deadline.
wait_for_engine_discovery() {
  local deadline=0
  local reason=""

  deadline=$((SECONDS + engine_discovery_timeout_seconds))

  until all_dbengines_ready; do
    if reason="$(db_operator_failure_reason)" && [ -n "${reason}" ]; then
      printf '%s\n' "Detected a terminal database engine discovery failure: ${reason}." >&2
      return 1
    fi

    if [ "${SECONDS}" -ge "${deadline}" ]; then
      printf '%s\n' "Timed out waiting for database operators to publish supported engine versions." >&2
      return 1
    fi

    sleep 5
  done
}

# Waits for the shared BackupStorage object to appear when backup is enabled.
wait_for_backup_storage_definitions() {
  wait_for_command "BackupStorage ${BACKUP_STORAGE_NAME} in ${EVEREST_DATABASE_NAMESPACE}" 300 backupstorage_exists
}

case "${action}" in
  install)
    run_step \
      "Waiting for OpenEverest namespaces and CRDs" \
      "OpenEverest namespaces and CRDs are ready." \
      wait_for_platform_prerequisites \
      || die "OpenEverest namespaces or CRDs did not become ready."

    run_step \
      "Waiting for OpenEverest system pods to become ready" \
      "OpenEverest system pods are ready." \
      wait_for_platform_pods \
      || die "OpenEverest system pods did not become ready."

    run_step \
      "Waiting for database operators to publish supported engine versions" \
      "Database operators published supported engine versions." \
      wait_for_engine_discovery \
      || die "Database operators did not publish supported engine versions in time."

    if backup_enabled; then
      run_step \
        "Waiting for shared backup storage" \
        "Shared backup storage is ready." \
        wait_for_backup_storage_definitions \
        || die "Shared backup storage did not become ready."
    fi
    ;;
  resume)
    run_step \
      "Waiting for OpenEverest namespaces and CRDs" \
      "OpenEverest namespaces and CRDs are ready." \
      wait_for_platform_prerequisites \
      || die "OpenEverest namespaces or CRDs did not become ready."

    run_step \
      "Waiting for OpenEverest control-plane pods to become ready" \
      "OpenEverest control-plane pods are ready." \
      wait_for_resume_platform_pods \
      || die "OpenEverest control-plane pods did not become ready."

    run_step \
      "Waiting for database operators to publish supported engine versions" \
      "Database operators published supported engine versions." \
      wait_for_engine_discovery \
      || die "Database operators did not publish supported engine versions in time."

    if backup_enabled; then
      run_step \
        "Waiting for shared backup storage" \
        "Shared backup storage is ready." \
        wait_for_backup_storage_definitions \
        || die "Shared backup storage did not become ready."
    fi
    ;;
  *)
    die "Unsupported wait target: ${action}"
    ;;
esac
