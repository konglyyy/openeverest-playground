#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Stops or deletes the local k3d cluster used by the playground.
# `down` preserves cluster state for faster restarts, while `reset` removes the
# cluster plus local state. `reset-full` also purges the repo-local Docker Hub
# cache for a fully cold next run.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"
load_env

action="${1:-}"
[ -n "${action}" ] || die "Usage: $0 <down|reset|reset-full>"

# Removes the effective playground state directory for the current run.
remove_local_state() {
  rm -rf "${PLAYGROUND_STATE_DIR}"
}

# Removes the repo-local Docker Hub pull-through cache directory.
remove_registry_cache() {
  rm -rf "${PLAYGROUND_REGISTRY_CACHE_DIR}"
}

case "${action}" in
  down)
    if ! cluster_listed; then
      info "Cluster ${CLUSTER_NAME} does not exist."
      exit 0
    fi

    run_step \
      "Stopping k3d cluster ${CLUSTER_NAME}" \
      "Stopped k3d cluster ${CLUSTER_NAME}" \
      k3d cluster stop "${CLUSTER_NAME}" \
      || die "Unable to stop k3d cluster ${CLUSTER_NAME}."
    clear_k3d_probe_cache
    ;;
  reset)
    if ! cluster_listed; then
      info "Cluster ${CLUSTER_NAME} does not exist."
      exit 0
    fi

    run_step \
      "Deleting k3d cluster ${CLUSTER_NAME}" \
      "Deleted k3d cluster ${CLUSTER_NAME}" \
      k3d cluster delete "${CLUSTER_NAME}" \
      || die "Unable to delete k3d cluster ${CLUSTER_NAME}."
    clear_k3d_probe_cache

    run_step \
      "Removing local playground state" \
      "Removed local playground state" \
      remove_local_state \
      || die "Unable to remove the local playground state."
    ;;
  reset-full)
    if cluster_listed; then
      run_step \
        "Deleting k3d cluster ${CLUSTER_NAME}" \
        "Deleted k3d cluster ${CLUSTER_NAME}" \
        k3d cluster delete "${CLUSTER_NAME}" \
        || die "Unable to delete k3d cluster ${CLUSTER_NAME}."
      clear_k3d_probe_cache
    else
      info "Cluster ${CLUSTER_NAME} does not exist. Purging local state and cache only."
    fi

    run_step \
      "Removing local playground state" \
      "Removed local playground state" \
      remove_local_state \
      || die "Unable to remove the local playground state."

    run_step \
      "Removing Docker Hub pull-through cache" \
      "Removed Docker Hub pull-through cache" \
      remove_registry_cache \
      || die "Unable to remove the Docker Hub pull-through cache."
    ;;
  *)
    die "Unsupported cleanup action: ${action}"
    ;;
esac
