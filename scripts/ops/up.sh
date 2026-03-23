#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Resumes a previously initialized playground without reinstalling anything.
# This wrapper keeps `task up` focused on the stop/start lifecycle and swallows
# the expected "run task init first" guard failures so the terminal output stays
# clean without an extra go-task failure footer.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

# Runs the full resume flow behind one top-level loading indicator while still
# letting the expected preflight guard failures exit cleanly.
resume_playground() {
  # Verifies that a prior `task init` completed successfully and that the current
  # `config/playground.env` still matches the last applied config before attempting any resume work.
  if ! "${ROOT_DIR}/scripts/config/check-resume-state.sh"; then
    return 0
  fi

  # Resume mode only checks the local prerequisites needed to start and verify an
  # already-provisioned playground. It does not touch Helm install paths.
  "${ROOT_DIR}/scripts/doctor/check-deps.sh" resume
  "${ROOT_DIR}/scripts/cluster/ensure-cluster.sh" resume
  "${ROOT_DIR}/scripts/platform/wait.sh" resume
  "${ROOT_DIR}/scripts/platform/ensure-ingress.sh"
  "${ROOT_DIR}/scripts/access/print-access.sh" resume
}

run_report_step "Resuming playground" resume_playground
