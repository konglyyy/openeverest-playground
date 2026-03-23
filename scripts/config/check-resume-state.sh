#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Verifies that `task up` can resume a previously initialized playground.
# It blocks first-run usage, missing clusters, and unapplied config drift so
# `task up` stays a pure resume command instead of a hidden reconcile path.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/config/policy.sh"

load_env

candidate_snapshot="$(mktemp)"
trap 'rm -f "${candidate_snapshot}"' EXIT

write_effective_config_snapshot "${candidate_snapshot}"

if ! applied_config_recorded; then
  die "Playground is not initialized yet. Run 'task init' first."
fi

if config_changes_present "${APPLIED_CONFIG_FILE}" "${candidate_snapshot}"; then
  warn "Current config differs from the initialized playground state."
  print_config_change_summary "${APPLIED_CONFIG_FILE}" "${candidate_snapshot}"
  die "Run 'task init' to apply those config changes before using 'task up'."
fi

if ! playground_exists_for_snapshot "${APPLIED_CONFIG_FILE}"; then
  die "The initialized playground cluster is missing. Run 'task init' to recreate it."
fi
