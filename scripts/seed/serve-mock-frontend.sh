#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Serves the lightweight CGI-based demo todo UI used by `task seed`.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env
port="${1:-8789}"

cd "${ROOT_DIR}/scripts/seed/mock-frontend"
exec python3 -m http.server --bind 127.0.0.1 --cgi "${port}"
