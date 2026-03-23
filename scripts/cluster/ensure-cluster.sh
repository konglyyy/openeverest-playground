#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Ensures the playground k3d cluster exists and is running.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env
require_cmd k3d
require_cmd kubectl
require_cmd jq
mode="${1:-ensure}"

case "${mode}" in
  ensure | resume) ;;
  *)
    die "Usage: $0 <ensure|resume>"
    ;;
esac

rendered_config="$(mktemp)"
trap 'rm -f "${rendered_config}"' EXIT

# Escapes `\`, `&`, and the chosen sed delimiter so repo-local paths can be
# substituted safely into rendered config templates.
sed_replacement_escape() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

resolved_server_count="$(resolved_server_count)"
resolved_agent_count="$(resolved_agent_count)"
resolved_server_memory_limit="$(resolved_server_node_memory_limit)"
server_system_reserved="$(kubelet_system_reserved_value_for_server)"
server_node_taint="$(resolved_server_node_taint)"
registry_cache_dir="$(sed_replacement_escape "${PLAYGROUND_REGISTRY_CACHE_DIR}")"
created_cluster="false"

ensure_registry_cache_dir

render_template \
  "${ROOT_DIR}/cluster/k3d-config.yaml" \
  -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
  -e "s|__K3D_SERVER_COUNT__|${resolved_server_count}|g" \
  -e "s|__K3D_AGENT_COUNT__|0|g" \
  -e "s|__EVEREST_UI_PORT__|${EVEREST_UI_PORT}|g" \
  -e "s|__SERVER_NODE_TAINT_ARG__|--node-taint=${server_node_taint}|g" \
  -e "s|__SERVER_SYSTEM_RESERVED_ARG__|--kubelet-arg=system-reserved=${server_system_reserved}|g" \
  -e "s|__AGENT_SYSTEM_RESERVED_ARG__|--kubelet-arg=system-reserved=cpu=250m,memory=256Mi|g" \
  -e "s|__REGISTRY_CACHE_DIR__|${registry_cache_dir}|g" \
  >"${rendered_config}"

# Creates one planned k3d agent node with the resolved worker sizing.
create_worker_node() {
  local worker_index="$1"
  local worker_class="$2"
  local worker_memory_limit=""
  local worker_reserved=""

  worker_memory_limit="$(resolved_worker_node_memory_limit_at "${worker_index}")"
  worker_reserved="$(kubelet_system_reserved_value_for_worker_class "${worker_class}")"

  k3d node create "${CLUSTER_NAME}-agent-${worker_index}" \
    --cluster "${CLUSTER_NAME}" \
    --role agent \
    --memory "${worker_memory_limit}" \
    --runtime-label "playground.worker-class=${worker_class}" \
    --k3s-node-label "playground.openeverest.io/worker-class=${worker_class}" \
    --k3s-arg "--kubelet-arg=system-reserved=${worker_reserved}"
}

# Creates the planned k3d agent nodes without per-node readiness waits. k3d's
# node create path is more reliable when the additions are serialized, and the
# shared cluster-level waits below still gate overall readiness.
create_worker_nodes() {
  local worker_index=""
  local worker_class=""

  while IFS='|' read -r worker_index worker_class; do
    create_worker_node "${worker_index}" "${worker_class}" || return 1
  done < <(resolved_worker_specs)
}

# Rewrites the current cluster kubeconfig into the default kubeconfig file so
# later Task steps and separate shells see the same explicit k3d context.
refresh_k3d_kubeconfig() {
  k3d kubeconfig merge "${CLUSTER_NAME}" \
    --kubeconfig-merge-default \
    --kubeconfig-switch-context=false \
    >/dev/null
}

# Returns success when the Kubernetes API reports the full planned node count.
expected_kubernetes_nodes_registered() {
  local node_count=""
  local expected_node_count=0

  expected_node_count=$((resolved_server_count + resolved_agent_count))
  node_count="$(
    k_query get nodes -o json 2>/dev/null \
      | jq -r '.items | length'
  )" || return 1

  [ "${node_count}" = "${expected_node_count}" ]
}

# Waits for the Kubernetes API to list every planned server and worker node.
wait_for_expected_kubernetes_nodes() {
  local deadline=0

  deadline=$((SECONDS + 120))

  until expected_kubernetes_nodes_registered; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      return 1
    fi
    sleep 2
  done
}

# Waits for the worker-class labels and node counts to settle after fresh node
# creation before treating the layout as real drift.
wait_for_cluster_topology_match() {
  local deadline=0

  deadline=$((SECONDS + 60))

  until cluster_topology_matches; do
    clear_k3d_probe_cache
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      return 1
    fi
    sleep 2
  done
}

# Waits for every currently registered Kubernetes node to report Ready.
wait_for_kubernetes_nodes_ready() {
  kubectl --context "${KUBE_CONTEXT}" wait --for=condition=Ready node --all --timeout=300s
}

if cluster_reachable; then
  if ! cluster_topology_matches; then
    die "Cluster ${CLUSTER_NAME} exists with a different node layout. Run 'task reset' once so the playground can recreate it with $(resolved_layout_display)."
  fi
  info "Using existing running k3d cluster ${CLUSTER_NAME}."
elif cluster_listed; then
  run_step \
    "Starting k3d cluster ${CLUSTER_NAME}" \
    "Started k3d cluster ${CLUSTER_NAME}" \
    k3d cluster start "${CLUSTER_NAME}" \
    || die "Unable to start k3d cluster ${CLUSTER_NAME}."
  clear_k3d_probe_cache
elif [ "${mode}" = "resume" ]; then
  die "Playground cluster ${CLUSTER_NAME} is not initialized. Run 'task init' first."
else
  run_step \
    "Creating k3d cluster ${CLUSTER_NAME}" \
    "Created k3d cluster ${CLUSTER_NAME}." \
    k3d cluster create \
    --config "${rendered_config}" \
    --servers-memory "${resolved_server_memory_limit}" \
    || die "Unable to create k3d cluster ${CLUSTER_NAME}."
  created_cluster="true"
  clear_k3d_probe_cache

  run_step \
    "Creating planned DB worker nodes" \
    "Created planned DB worker nodes." \
    create_worker_nodes \
    || die "Unable to create the planned DB worker nodes."
  clear_k3d_probe_cache
fi

refresh_k3d_kubeconfig \
  || die "Unable to refresh the kubeconfig context for ${CLUSTER_NAME}."

if [ "${created_cluster}" = "true" ]; then
  run_step \
    "Waiting for all planned Kubernetes nodes to register" \
    "All planned Kubernetes nodes are registered." \
    wait_for_expected_kubernetes_nodes \
    || die "The planned Kubernetes nodes did not all register in time."
fi

run_step \
  "Waiting for Kubernetes nodes to report Ready" \
  "Kubernetes nodes are Ready." \
  wait_for_kubernetes_nodes_ready \
  || die "Kubernetes nodes did not reach Ready in time."

if [ "${created_cluster}" = "true" ]; then
  run_step \
    "Waiting for planned node labels to settle" \
    "Planned node labels are visible." \
    wait_for_cluster_topology_match \
    || die "Cluster ${CLUSTER_NAME} exists with a different node layout. Run 'task reset' once so the playground can recreate it with $(resolved_layout_display)."
elif ! cluster_topology_matches; then
  die "Cluster ${CLUSTER_NAME} exists with a different node layout. Run 'task reset' once so the playground can recreate it with $(resolved_layout_display)."
fi
