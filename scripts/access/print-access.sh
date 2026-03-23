#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Prints the ready summary shown after `task init` and `task up`.
# Both flows print the same topology and access blocks so the final state is
# easy to scan after either a fresh init or a resume.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env
mode="${1:-resume}"

case "${mode}" in
  init | resume) ;;
  *)
    die "Usage: $0 <init|resume>"
    ;;
esac

print_summary_section "OpenEverest playground is ready"
print_playground_topology_summary resolved-only
print_playground_access_summary
