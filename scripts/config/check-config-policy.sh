#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Enforces the playground config policy before `task up` mutates the cluster.
# It compares the requested config against the last successful apply and blocks
# changes that the repo cannot safely reconcile in place.
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

if ! existing_playground_detected; then
  exit 0
fi

if ! applied_config_recorded; then
  warn "Existing playground detected, but no applied config snapshot is recorded yet. This run will adopt the current config as the baseline if it succeeds."
  exit 0
fi

if config_changes_include_mode "${APPLIED_CONFIG_FILE}" "${candidate_snapshot}" "requires_reset"; then
  warn "The requested playground config does not match the recorded baseline."
  print_config_change_summary "${APPLIED_CONFIG_FILE}" "${candidate_snapshot}"
  die "One or more requested changes require recreating the playground. Run 'task reset' and then retry 'task up' or 'task init'."
fi

if config_changes_include_mode "${APPLIED_CONFIG_FILE}" "${candidate_snapshot}" "in_place"; then
  info "Applying in-place playground config changes."
  print_config_change_summary "${APPLIED_CONFIG_FILE}" "${candidate_snapshot}"
elif config_changes_include_mode "${APPLIED_CONFIG_FILE}" "${candidate_snapshot}" "local_only"; then
  info "Applying local-only config changes."
  print_config_change_summary "${APPLIED_CONFIG_FILE}" "${candidate_snapshot}"
fi
