#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helper loader for the playground shell scripts.
# The public entrypoint stays stable at `scripts/common/lib.sh`, while the
# implementation lives in focused modules under `scripts/common/modules/`.
# -----------------------------------------------------------------------------

if [ -n "${PLAYGROUND_COMMON_LIB_LOADED:-}" ]; then
  return 0
fi

PLAYGROUND_COMMON_LIB_LOADED=1

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${COMMON_DIR}/../.." && pwd)"
STATE_DIR="${PLAYGROUND_STATE_DIR:-${ROOT_DIR}/.state}"
# shellcheck disable=SC2034  # Used by sourced helper modules.
DOCTOR_STATE_DIR="${STATE_DIR}/doctor"

# shellcheck disable=SC1091
. "${COMMON_DIR}/modules/env.sh"
# shellcheck disable=SC1091
. "${COMMON_DIR}/modules/style.sh"
# shellcheck disable=SC1091
. "${COMMON_DIR}/modules/kube.sh"
# shellcheck disable=SC1091
. "${COMMON_DIR}/modules/sizing.sh"
# shellcheck disable=SC1091
. "${COMMON_DIR}/modules/runner.sh"
# shellcheck disable=SC1091
. "${COMMON_DIR}/modules/helm.sh"
# shellcheck disable=SC1091
. "${COMMON_DIR}/modules/playground.sh"
# shellcheck disable=SC1091
. "${COMMON_DIR}/modules/summary.sh"
