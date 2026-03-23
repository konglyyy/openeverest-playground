#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Records the effective config after a successful apply flow.
# This snapshot becomes the baseline for later drift checks in `task init`
# and `task up`, which keeps config-policy decisions consistent.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/config/policy.sh"

load_env
ensure_config_state_dir
write_effective_config_snapshot "${APPLIED_CONFIG_FILE}"
