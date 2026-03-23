#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared Kubernetes and k3d helpers.
# -----------------------------------------------------------------------------

# Runs kubectl against the explicit playground context instead of the user's
# current kube context.
k() {
  load_env
  kubectl --context "${KUBE_CONTEXT}" "$@"
}

# Runs a bounded kubectl read query so status-style commands do not hang
# indefinitely on an unhealthy or half-stopped cluster.
k_query() {
  load_env
  kubectl --context "${KUBE_CONTEXT}" --request-timeout "${PLAYGROUND_QUERY_REQUEST_TIMEOUT:-5s}" "$@"
}

# Runs Helm against the explicit playground context for the same reason as `k`.
hctx() {
  load_env
  helm --kube-context "${KUBE_CONTEXT}" "$@"
}

# Creates a namespace only when it is missing so reruns stay idempotent.
ensure_namespace() {
  local namespace="$1"

  if ! k get namespace "${namespace}" >/dev/null 2>&1; then
    kubectl --context "${KUBE_CONTEXT}" create namespace "${namespace}" >/dev/null
  fi
}

# Returns the runtime cache file path used for the current run's `k3d cluster list` probe.
k3d_cluster_list_cache_file() {
  runtime_cache_file "k3d-cluster-list.txt"
}

# Returns the runtime cache file path used for the current run's `k3d node list` probe.
k3d_node_list_cache_file() {
  runtime_cache_file "k3d-node-list.json"
}

# Returns the current `k3d cluster list` output, reusing the optional per-run
# cache when one is available.
k3d_cluster_list_output() {
  local cache_file=""

  load_env

  if [ -n "${PLAYGROUND_K3D_CLUSTER_LIST_LOADED:-}" ]; then
    printf '%s\n' "${PLAYGROUND_K3D_CLUSTER_LIST_OUTPUT}"
    return 0
  fi

  if cache_file="$(k3d_cluster_list_cache_file 2>/dev/null)" && [ -f "${cache_file}" ]; then
    PLAYGROUND_K3D_CLUSTER_LIST_OUTPUT="$(cat "${cache_file}")"
    export PLAYGROUND_K3D_CLUSTER_LIST_OUTPUT
    export PLAYGROUND_K3D_CLUSTER_LIST_LOADED=1
    printf '%s\n' "${PLAYGROUND_K3D_CLUSTER_LIST_OUTPUT}"
    return 0
  fi

  PLAYGROUND_K3D_CLUSTER_LIST_OUTPUT="$(k3d cluster list 2>/dev/null)" || return 1
  export PLAYGROUND_K3D_CLUSTER_LIST_OUTPUT
  export PLAYGROUND_K3D_CLUSTER_LIST_LOADED=1

  if cache_file="$(k3d_cluster_list_cache_file 2>/dev/null)"; then
    ensure_runtime_cache_dir || true
    printf '%s\n' "${PLAYGROUND_K3D_CLUSTER_LIST_OUTPUT}" >"${cache_file}"
  fi

  printf '%s\n' "${PLAYGROUND_K3D_CLUSTER_LIST_OUTPUT}"
}

# Returns the current `k3d node list -o json` output, reusing the optional
# per-run cache when one is available.
k3d_node_list_json() {
  local cache_file=""

  load_env

  if [ -n "${PLAYGROUND_K3D_NODE_LIST_LOADED:-}" ]; then
    printf '%s\n' "${PLAYGROUND_K3D_NODE_LIST_OUTPUT}"
    return 0
  fi

  if cache_file="$(k3d_node_list_cache_file 2>/dev/null)" && [ -f "${cache_file}" ]; then
    PLAYGROUND_K3D_NODE_LIST_OUTPUT="$(cat "${cache_file}")"
    export PLAYGROUND_K3D_NODE_LIST_OUTPUT
    export PLAYGROUND_K3D_NODE_LIST_LOADED=1
    printf '%s\n' "${PLAYGROUND_K3D_NODE_LIST_OUTPUT}"
    return 0
  fi

  PLAYGROUND_K3D_NODE_LIST_OUTPUT="$(k3d node list -o json 2>/dev/null)" || return 1
  export PLAYGROUND_K3D_NODE_LIST_OUTPUT
  export PLAYGROUND_K3D_NODE_LIST_LOADED=1

  if cache_file="$(k3d_node_list_cache_file 2>/dev/null)"; then
    ensure_runtime_cache_dir || true
    printf '%s\n' "${PLAYGROUND_K3D_NODE_LIST_OUTPUT}" >"${cache_file}"
  fi

  printf '%s\n' "${PLAYGROUND_K3D_NODE_LIST_OUTPUT}"
}

# Returns success when the named k3d cluster already exists.
cluster_listed() {
  load_env
  k3d_cluster_list_output | awk -v name="${CLUSTER_NAME}" 'NR > 1 && $1 == name { found = 1 } END { exit found ? 0 : 1 }'
}

# Returns success when the cluster API is reachable through kubectl.
cluster_reachable() {
  load_env
  kubectl --context "${KUBE_CONTEXT}" get nodes >/dev/null 2>&1
}

# Returns success when the cluster API answers a short bounded read probe.
cluster_query_reachable() {
  load_env
  k_query get nodes >/dev/null 2>&1
}
