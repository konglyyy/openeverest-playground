#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Captures smoke-test diagnostics into CI artifact files without letting any
# single failing command abort the overall collection pass.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
target="${1:-smoke-minimal}"
artifact_dir="${ROOT_DIR}/.ci-artifacts/${target}"
work_dir="${ROOT_DIR}/.state/ci-workspace/${target}"
env_file="${work_dir}/playground.env"
state_dir="${work_dir}/state"

mkdir -p "${artifact_dir}"

# Writes one command's stdout and stderr to an artifact file.
capture_output() {
  local name="$1"
  shift

  if "$@" >"${artifact_dir}/${name}" 2>&1; then
    return 0
  fi

  return 0
}

capture_output docker-ps.txt docker ps -a
capture_output docker-system-df.txt docker system df
capture_output k3d-clusters.txt k3d cluster list

if [ ! -f "${env_file}" ]; then
  exit 0
fi

export PLAYGROUND_ENV_FILE="${env_file}"
export PLAYGROUND_STATE_DIR="${state_dir}"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"
load_env

capture_output env.txt bash -lc 'env | sort'
capture_output kubectl-version.txt kubectl --context "${KUBE_CONTEXT}" version

if cluster_reachable; then
  capture_output nodes.txt kubectl --context "${KUBE_CONTEXT}" get nodes -o wide
  capture_output describe-nodes.txt kubectl --context "${KUBE_CONTEXT}" describe nodes
  capture_output namespaces.txt kubectl --context "${KUBE_CONTEXT}" get namespaces
  capture_output all-resources.txt kubectl --context "${KUBE_CONTEXT}" get all -A
  capture_output events.txt kubectl --context "${KUBE_CONTEXT}" get events -A --sort-by=.metadata.creationTimestamp

  if kubectl --context "${KUBE_CONTEXT}" get namespace "${EVEREST_NAMESPACE}" >/dev/null 2>&1; then
    capture_output everest-pods.txt kubectl --context "${KUBE_CONTEXT}" -n "${EVEREST_NAMESPACE}" get pods -o wide
    capture_output everest-logs.txt "${ROOT_DIR}/scripts/ops/logs.sh"
  fi
fi
