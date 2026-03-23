#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Prints recent logs from the Everest control-plane workloads.
# Everest does not expose one stable instance label across all control-plane
# pods, so this script discovers the actual pods in `everest-system` and tails
# each one directly.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env

# Returns the current control-plane pod names in a stable order so log output is
# easy to scan between repeated runs.
everest_pod_names() {
  k -n "${EVEREST_NAMESPACE}" get pods -o json \
    | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name' \
    | sort
}

if ! cluster_listed; then
  die "Playground is not initialized yet. Run 'task init' first."
fi

if ! cluster_reachable; then
  die "Cluster ${CLUSTER_NAME} is not running. Start it with 'task up' first."
fi

if ! k get namespace "${EVEREST_NAMESPACE}" >/dev/null 2>&1; then
  die "Namespace ${EVEREST_NAMESPACE} does not exist. Run 'task init' to provision the playground."
fi

pod_names="$(everest_pod_names)"
if [ -z "${pod_names}" ]; then
  die "No OpenEverest control-plane pods were found in ${EVEREST_NAMESPACE}."
fi

info "OpenEverest logs"

# Print each pod separately so operator and server logs remain distinguishable.
while IFS= read -r pod_name; do
  [ -n "${pod_name}" ] || continue

  printf '\n%s\n' "$(style_title 1 "${pod_name}")"
  if ! k -n "${EVEREST_NAMESPACE}" logs "${pod_name}" --all-containers --tail=200; then
    warn "Unable to read logs from pod ${pod_name}."
  fi
done <<EOF
${pod_names}
EOF
