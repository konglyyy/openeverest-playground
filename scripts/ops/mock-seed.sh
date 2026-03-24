#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Seeds one user-created database with the mock todo demo data.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/seed/runtime.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/seed/cli.sh"

TASK_SEED_CLIENT_CONNECTION_STRING=""
TASK_SEED_SEED_STATUS=""

trap task_seed_cleanup_port_forward EXIT

# Runs the full interactive mock seed flow.
run_task_mock_seed() {
  local raw_connection_string=""

  if ! ensure_task_seed_command_ready "Task mock:seed" "task mock:seed"; then
    return 0
  fi

  require_cmd docker

  raw_connection_string="$(prompt_nonempty_value "$(style_accent 2 'Connection string') [paste the database URI]: ")"

  if ! task_seed_engine_from_connection_string "${raw_connection_string}" >/dev/null 2>&1; then
    die "Unsupported connection string. Use a PostgreSQL, MySQL, or MongoDB URI."
  fi

  run_task_seed_capture_step \
    TASK_SEED_CLIENT_CONNECTION_STRING \
    "Preparing database access" \
    "Prepared database access" \
    task_seed_prepare_client_connection_string "${raw_connection_string}" \
    || die "Unable to prepare database access from that connection string."

  run_task_seed_capture_step \
    TASK_SEED_SEED_STATUS \
    "Preparing demo todo data" \
    "Prepared demo todo data" \
    task_seed_seed_demo_data "${TASK_SEED_CLIENT_CONNECTION_STRING}" \
    || die "Unable to seed the demo todo data."

  print_summary_section "Mock seed completed"
  print_summary_field "Seed target" "$(style_bold 1 "${TASK_SEED_COLLECTION_NAME}")"
  case "${TASK_SEED_SEED_STATUS}" in
    seeded)
      print_summary_field "Seed data" "$(style_success 1 'inserted into the demo table or collection')"
      ;;
    already-present)
      print_summary_field "Seed data" "$(style_dim 1 'already present; existing demo rows or docs were left unchanged')"
      ;;
    *)
      print_summary_field "Seed data" "$(style_dim 1 'prepared')"
      ;;
  esac

  print_summary_field "Next step" "$(style_action 1 'Run task mock:app to try the mock UI.')"
  printf '\n'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run_task_mock_seed
fi
