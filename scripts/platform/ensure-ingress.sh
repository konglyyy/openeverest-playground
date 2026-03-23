#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Verifies that the built-in k3s Traefik ingress controller is available.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env

# Polls until a readiness predicate succeeds, but returns control to the caller
# so it can decide whether to retry, degrade, or fail with a custom message.
wait_for_command() {
  local description="$1"
  local timeout_seconds="$2"
  shift 2

  local deadline
  deadline=$((SECONDS + timeout_seconds))

  until "$@"; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      warn "Timed out waiting for ${description}."
      return 1
    fi
    sleep 5
  done
}

# Returns success once the built-in k3s Traefik deployment exists.
traefik_deployment_exists() {
  k -n kube-system get deployment traefik >/dev/null 2>&1
}

# Waits for the built-in Traefik deployment to exist and then report Ready.
wait_for_traefik_ready() {
  if ! wait_for_command "Traefik deployment" 120 traefik_deployment_exists; then
    printf '%s\n' "This k3d cluster does not expose the built-in ingress controller. Run 'task reset' once to recreate it with ingress support." >&2
    return 1
  fi

  # Do not move on until Traefik itself is Ready; otherwise the UI URL can
  # print before localhost routing is actually serving requests.
  kubectl --context "${KUBE_CONTEXT}" rollout status deployment/traefik -n kube-system --timeout=300s >/dev/null
}

run_step \
  "Waiting for the built-in Traefik ingress controller" \
  "Built-in Traefik ingress controller is ready." \
  wait_for_traefik_ready \
  || die "Unable to confirm the built-in Traefik ingress controller."
