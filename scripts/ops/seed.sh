#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Seeds one user-created database with a tiny demo dataset and can optionally
# open a local mock todo UI against it.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/seed/runtime.sh"

TASK_SEED_FRONTEND_PORT="${PLAYGROUND_TASK_SEED_UI_PORT:-8789}"
TASK_SEED_KEEP_RUNTIME="false"

# Stops transient task seed processes unless the mock frontend should keep running.
cleanup_task_seed_runtime() {
  if [ "${TASK_SEED_KEEP_RUNTIME}" != "true" ]; then
    stop_task_seed_runtime
  fi
}

trap cleanup_task_seed_runtime EXIT

# Returns success when stdin is connected to an interactive terminal.
interactive_prompt_available() {
  [ -t 0 ]
}

# Writes one prompt to stderr and returns the typed answer on stdout.
read_prompt_answer() {
  local prompt="$1"
  local answer=""

  printf '%s' "${prompt}" >&2
  IFS= read -r answer || answer=""
  printf '%s\n' "${answer}"
}

# Re-prompts until the user provides a non-empty connection string.
prompt_nonempty_value() {
  local prompt="$1"
  local answer=""

  while :; do
    answer="$(read_prompt_answer "${prompt}")"
    if [ -n "${answer}" ]; then
      printf '%s\n' "${answer}"
      return 0
    fi
    warn "Please enter a connection string."
  done
}

# Prompts for a yes/no answer and falls back to the requested default.
prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-yes}"
  local answer=""

  while :; do
    answer="$(read_prompt_answer "${prompt}")"
    case "${answer}" in
      '')
        printf '%s\n' "${default_answer}"
        return 0
        ;;
      y | Y | yes | YES | Yes)
        printf 'yes\n'
        return 0
        ;;
      n | N | no | NO | No)
        printf 'no\n'
        return 0
        ;;
    esac
    warn "Please answer yes or no."
  done
}

# Resolves the raw user-provided URI into the client-facing form task seed uses.
prepare_task_seed_connection_string() {
  local raw_connection_string="$1"

  ensure_task_seed_state_dir
  task_seed_prepare_client_connection_string "${raw_connection_string}" >"$(task_seed_state_dir)/prepared-connection-string"
}

# Seeds or reuses the demo dataset and records the outcome for the final summary.
seed_task_seed_demo_data() {
  local client_connection_string="$1"

  ensure_task_seed_state_dir
  task_seed_seed_demo_data "${client_connection_string}" >"$(task_seed_state_dir)/seed-status"
}

# Starts the local mock frontend server and waits for it to begin accepting requests.
start_task_seed_frontend() {
  local connection_string="$1"
  local pid_file=""
  local log_file=""
  local pid=0
  local attempt=0

  require_cmd python3
  ensure_task_seed_state_dir
  stop_task_seed_frontend

  pid_file="$(task_seed_frontend_pid_file)"
  log_file="$(task_seed_frontend_log_file)"
  : >"${log_file}"

  (
    export PLAYGROUND_TASK_SEED_CONNECTION_STRING="${connection_string}"
    exec "${ROOT_DIR}/scripts/seed/serve-mock-frontend.sh" "${TASK_SEED_FRONTEND_PORT}"
  ) >"${log_file}" 2>&1 &
  pid=$!
  printf '%s\n' "${pid}" >"${pid_file}"

  while [ "${attempt}" -lt 20 ]; do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      rm -f "${pid_file}"
      return 1
    fi

    if grep -q "Serving HTTP on" "${log_file}" 2>/dev/null; then
      return 0
    fi

    sleep 0.2
    attempt=$((attempt + 1))
  done

  kill -0 "${pid}" >/dev/null 2>&1
}

# Opens the mock frontend URL with the platform-default browser helper.
open_task_seed_frontend() {
  local url="$1"

  if command -v open >/dev/null 2>&1; then
    open "${url}" >/dev/null 2>&1 && return 0
  fi

  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${url}" >/dev/null 2>&1 && return 0
  fi

  if command -v wslview >/dev/null 2>&1; then
    wslview "${url}" >/dev/null 2>&1 && return 0
  fi

  return 1
}

# Runs the full interactive task seed flow from prompt to optional UI launch.
run_task_seed() {
  local raw_connection_string=""
  local client_connection_string=""
  local with_frontend=""
  local frontend_url=""
  local seed_status=""

  if ! "${ROOT_DIR}/scripts/config/check-resume-state.sh"; then
    return 0
  fi

  if ! cluster_query_reachable; then
    die "Cluster ${CLUSTER_NAME} is not running. Start it with 'task up' first."
  fi

  if ! interactive_prompt_available; then
    die "Task seed requires an interactive terminal. Re-run 'task seed' in a terminal session."
  fi

  stop_task_seed_runtime
  require_cmd docker

  raw_connection_string="$(prompt_nonempty_value "$(style_accent 2 'Connection string') [paste the database URI]: ")"

  if ! task_seed_engine_from_connection_string "${raw_connection_string}" >/dev/null 2>&1; then
    die "Unsupported connection string. Use a PostgreSQL, MySQL, or MongoDB URI."
  fi

  with_frontend="$(prompt_yes_no "$(style_accent 2 'Open the mock todo frontend too?') [Y/n]: " "yes")"

  run_step \
    "Preparing database access" \
    "Prepared database access" \
    prepare_task_seed_connection_string "${raw_connection_string}" \
    || die "Unable to prepare database access from that connection string."

  client_connection_string="$(cat "$(task_seed_state_dir)/prepared-connection-string")"
  rm -f "$(task_seed_state_dir)/prepared-connection-string"

  run_step \
    "Preparing demo todo data" \
    "Prepared demo todo data" \
    seed_task_seed_demo_data "${client_connection_string}" \
    || die "Unable to seed the demo todo data."
  seed_status="$(cat "$(task_seed_state_dir)/seed-status")"
  rm -f "$(task_seed_state_dir)/seed-status"

  frontend_url="http://127.0.0.1:${TASK_SEED_FRONTEND_PORT}/cgi-bin/todos.sh"

  if [ "${with_frontend}" = "yes" ]; then
    run_step \
      "Starting mock todo frontend" \
      "Started mock todo frontend" \
      start_task_seed_frontend "${client_connection_string}" \
      || die "Unable to start the mock todo frontend."

    TASK_SEED_KEEP_RUNTIME="true"

    if ! open_task_seed_frontend "${frontend_url}"; then
      warn "Unable to open the browser automatically. Open ${frontend_url} manually."
    fi
  fi

  print_summary_section "Task seed completed"
  print_summary_field "Seed target" "$(style_bold 1 "${TASK_SEED_COLLECTION_NAME}")"
  case "${seed_status}" in
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

  if [ "${with_frontend}" = "yes" ]; then
    print_summary_field "Mock frontend" "$(style_action 1 "${frontend_url}")"
    if [ -f "$(task_seed_port_forward_pid_file)" ]; then
      print_summary_field "DB access" "$(style_dim 1 'Local port-forward stays up while the mock frontend is running.')"
    fi
  else
    print_summary_field "Mock frontend" "$(style_dim 1 'not started')"
  fi

  printf '\n'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run_task_seed
fi
