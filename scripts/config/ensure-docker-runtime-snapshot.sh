#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Ensures the hidden apply path has the recorded Docker budget snapshot that the
# rest of the lifecycle reuses after `task init`.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env

if detect_docker_runtime_info; then
  exit 0
fi

refresh_docker_runtime_info_snapshot || {
  die "Unable to record the Docker budget for this playground. Verify Docker is running and retry."
}
