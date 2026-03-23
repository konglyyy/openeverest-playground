#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Pins playground control-plane services and database operators onto the tainted
# server node so DB workloads remain on worker nodes, then adds the legacy
# master taint that Everest capacity estimation also reads.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env

# Returns the deployment patch that pins workloads to the control-plane node.
control_plane_patch_json() {
  cat <<'EOF'
{
  "spec": {
    "template": {
      "spec": {
        "nodeSelector": {
          "node-role.kubernetes.io/control-plane": "true"
        },
        "tolerations": [
          {
            "key": "node-role.kubernetes.io/control-plane",
            "operator": "Exists",
            "effect": "NoSchedule"
          },
          {
            "key": "node-role.kubernetes.io/master",
            "operator": "Exists",
            "effect": "NoSchedule"
          }
        ]
      }
    }
  }
}
EOF
}

# Applies the control-plane placement patch to matching deployments in one namespace.
patch_deployments_in_namespace() {
  local namespace="$1"
  local selector="${2:-}"
  local deployment_names=""
  local deployment_name=""
  local patch_json=""

  if ! k get namespace "${namespace}" >/dev/null 2>&1; then
    return 0
  fi

  patch_json="$(control_plane_patch_json)"

  if [ -n "${selector}" ]; then
    deployment_names="$(k -n "${namespace}" get deployment -l "${selector}" -o name 2>/dev/null || true)"
  else
    deployment_names="$(k -n "${namespace}" get deployment -o name 2>/dev/null || true)"
  fi

  if [ -z "${deployment_names}" ]; then
    return 0
  fi

  while IFS= read -r deployment_name; do
    [ -n "${deployment_name}" ] || continue
    k -n "${namespace}" patch "${deployment_name}" --type merge -p "${patch_json}" >/dev/null
  done <<<"${deployment_names}"
}

# Waits for the operator-managed deployments to appear in the shared DB namespace.
wait_for_db_operator_deployments() {
  local deadline=0

  deadline=$((SECONDS + 300))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if k -n "${EVEREST_DATABASE_NAMESPACE}" get deployment -l olm.owner.kind=ClusterServiceVersion -o name 2>/dev/null | awk 'NR == 1 { found = 1 } END { exit found ? 0 : 1 }'; then
      return 0
    fi
    sleep 5
  done

  return 1
}

# Adds the legacy master NoSchedule taint to each control-plane node.
apply_master_taint_to_control_plane() {
  local node_names=""
  local node_name=""

  node_names="$(k get nodes -l node-role.kubernetes.io/control-plane -o name 2>/dev/null || true)"
  if [ -z "${node_names}" ]; then
    die "Unable to find the playground control-plane node."
  fi

  while IFS= read -r node_name; do
    [ -n "${node_name}" ] || continue
    node_name="${node_name#node/}"
    k taint nodes "${node_name}" node-role.kubernetes.io/master:NoSchedule --overwrite >/dev/null
  done <<<"${node_names}"
}

# Reconciles control-plane placement for Everest services and DB operators.
reconcile_control_plane_placement() {
  patch_deployments_in_namespace "${EVEREST_NAMESPACE}"
  patch_deployments_in_namespace "${EVEREST_MONITORING_NAMESPACE}"
  patch_deployments_in_namespace "${EVEREST_OLM_NAMESPACE}"

  if backup_enabled; then
    patch_deployments_in_namespace "${PLAYGROUND_SYSTEM_NAMESPACE}"
  fi

  if wait_for_db_operator_deployments; then
    patch_deployments_in_namespace "${EVEREST_DATABASE_NAMESPACE}" "olm.owner.kind=ClusterServiceVersion"
  else
    die "Timed out waiting for DB operator deployments to appear in ${EVEREST_DATABASE_NAMESPACE}."
  fi

  apply_master_taint_to_control_plane
}

run_step \
  "Pinning control-plane services to the tainted server node" \
  "Pinned control-plane services to the tainted server node." \
  reconcile_control_plane_placement \
  || die "Unable to pin the control-plane services to the server node."
