#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared playground domain helpers for namespaces, engines, and cluster layout.
# -----------------------------------------------------------------------------

# Lists the DBaaS namespace managed by this playground.
managed_db_namespaces() {
  load_env
  printf '%s\n' "${EVEREST_DATABASE_NAMESPACE}"
}

# Converts the enabled engine footprint into user-facing labels.
managed_engine_display_list() {
  local labels=()
  local engine=""

  while IFS= read -r engine; do
    labels+=("$(database_engine_display_name "${engine}" | tr -d '\n')")
  done < <(managed_database_engines)

  (
    IFS=','
    printf '%s\n' "${labels[*]}"
  ) | sed 's/,/, /g'
}

# Lists the namespaces intentionally managed by the playground.
playground_namespaces() {
  load_env
  printf '%s\n' "kube-system"
  printf '%s\n' "${EVEREST_NAMESPACE}"
  printf '%s\n' "${EVEREST_OLM_NAMESPACE}"
  printf '%s\n' "${EVEREST_MONITORING_NAMESPACE}"
  printf '%s\n' "${EVEREST_DATABASE_NAMESPACE}"
  if backup_enabled; then
    printf '%s\n' "${PLAYGROUND_SYSTEM_NAMESPACE}"
  fi
}

# Derives the Helm release name used for the shared DB namespace install.
db_namespace_release_name() {
  printf 'everest-%s\n' "${EVEREST_DATABASE_NAMESPACE}"
}

# Converts the internal engine keys into labels that read well in output.
database_engine_display_name() {
  case "$1" in
    postgresql)
      printf 'PostgreSQL\n'
      ;;
    pxc)
      printf 'MySQL/PXC\n'
      ;;
    psmdb)
      printf 'MongoDB\n'
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

# Builds the S3 bucket name assigned to the shared DB namespace on the backup store.
backup_bucket_for_namespace() {
  local namespace="$1"

  load_env
  printf '%s-%s\n' "${BACKUP_BUCKET_PREFIX}" "${namespace}"
}

# Returns the in-cluster SeaweedFS S3 HTTP host:port used for internal setup.
seaweedfs_http_endpoint_hostport() {
  load_env
  printf '%s.%s.svc.cluster.local:%s\n' "${SEAWEEDFS_SERVICE_NAME}" "${PLAYGROUND_SYSTEM_NAMESPACE}" "${SEAWEEDFS_S3_PORT}"
}

# Returns the in-cluster SeaweedFS S3 HTTPS host:port used by BackupStorage.
seaweedfs_endpoint_hostport() {
  load_env
  printf '%s.%s.svc.cluster.local:%s\n' "${SEAWEEDFS_SERVICE_NAME}" "${PLAYGROUND_SYSTEM_NAMESPACE}" "${SEAWEEDFS_S3_HTTPS_PORT}"
}

# Returns the in-cluster HTTPS URL for the shared SeaweedFS S3 service.
seaweedfs_endpoint() {
  printf 'https://%s\n' "$(seaweedfs_endpoint_hostport)"
}

# Detects the previous multi-namespace layout so the scripts can require one clean reset.
legacy_db_namespace_layout_present() {
  load_env

  if k get namespace postgresql-dbaas >/dev/null 2>&1; then
    return 0
  fi

  if k get namespace mysql-dbaas >/dev/null 2>&1; then
    return 0
  fi

  if k get namespace mongodb-dbaas >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

# Prints the expected worker classes in index order as index|class lines.
resolved_worker_specs() {
  local index=0
  local worker_class=""
  local old_ifs="${IFS}"

  IFS=','
  for worker_class in $(resolved_worker_layout_csv); do
    printf '%s|%s\n' "${index}" "${worker_class}"
    index=$((index + 1))
  done
  IFS="${old_ifs}"
}

# Compares the live Kubernetes node labels to the expected plan.
cluster_topology_matches_from_kube() {
  local node_json=""
  local server_count=0
  local expected_layout=""
  local actual_layout=""

  load_env

  node_json="$(k_query get nodes -o json 2>/dev/null)" || return 1
  server_count="$(
    printf '%s\n' "${node_json}" \
      | jq -r '
          [
            .items[]
            | select(
                (.metadata.labels["node-role.kubernetes.io/control-plane"] == "true")
                or (.metadata.labels["node-role.kubernetes.io/master"] == "true")
              )
          ] | length
        '
  )"
  actual_layout="$(
    printf '%s\n' "${node_json}" \
      | jq -r '
          [
            .items[]
            | select(
                (.metadata.labels["node-role.kubernetes.io/control-plane"] // "") != "true"
                and (.metadata.labels["node-role.kubernetes.io/master"] // "") != "true"
              )
            | {
                name: .metadata.name,
                worker_class: (.metadata.labels["playground.openeverest.io/worker-class"] // "")
              }
          ]
          | sort_by(.name)
          | map(.worker_class)
          | join(",")
        '
  )"
  expected_layout="$(resolved_worker_layout_csv)"

  [ "${server_count}" = "$(resolved_server_count)" ] && [ "${actual_layout}" = "${expected_layout}" ]
}

# Compares the k3d node roles and worker-class runtime labels to the expected plan.
cluster_topology_matches_from_k3d() {
  local node_json=""
  local server_count=0
  local expected_layout=""
  local actual_layout=""

  load_env

  node_json="$(k3d_node_list_json)" || return 1
  server_count="$(
    printf '%s\n' "${node_json}" \
      | jq -r --arg cluster "${CLUSTER_NAME}" '[.[] | select(.runtimeLabels["k3d.cluster"] == $cluster and .role == "server")] | length'
  )"
  actual_layout="$(
    printf '%s\n' "${node_json}" \
      | jq -r --arg cluster "${CLUSTER_NAME}" '
          [.[] | select(.runtimeLabels["k3d.cluster"] == $cluster and .role == "agent")]
          | sort_by(.name)
          | map(.runtimeLabels["playground.worker-class"] // "")
          | join(",")
        '
  )"
  expected_layout="$(resolved_worker_layout_csv)"

  [ "${server_count}" = "$(resolved_server_count)" ] && [ "${actual_layout}" = "${expected_layout}" ]
}

# Compares the actual cluster topology to the expected plan, preferring the
# stable Kubernetes node labels once the API is available.
cluster_topology_matches() {
  if cluster_query_reachable; then
    cluster_topology_matches_from_kube
    return $?
  fi

  cluster_topology_matches_from_k3d
}
