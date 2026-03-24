#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Runs the lightweight CGI-based mock todo app in the foreground.
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

TASK_SEED_FRONTEND_PORT="${PLAYGROUND_TASK_SEED_UI_PORT:-8789}"
TASK_SEED_CLIENT_CONNECTION_STRING=""
TASK_SEED_FRONTEND_SERVER_PID=""
TASK_SEED_FRONTEND_LOG_FILE=""
TASK_SEED_FRONTEND_CONNECTION_FILE=""
TASK_SEED_APP_STOPPING="false"

# Returns success when the foreground mock frontend server is still running.
task_seed_frontend_running() {
  [ -n "${TASK_SEED_FRONTEND_SERVER_PID}" ] && kill -0 "${TASK_SEED_FRONTEND_SERVER_PID}" >/dev/null 2>&1
}

# Returns success when the foreground mock frontend is answering local HTTP
# requests.
task_seed_frontend_responding() {
  python3 -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=1).read(1)' "$1" >/dev/null 2>&1
}

# Replays the captured frontend server output when startup or runtime fails.
replay_task_seed_frontend_log() {
  if [ -n "${TASK_SEED_FRONTEND_LOG_FILE}" ] && [ -s "${TASK_SEED_FRONTEND_LOG_FILE}" ]; then
    sed 's/^/  /' "${TASK_SEED_FRONTEND_LOG_FILE}" >&2
  fi
}

# Writes the current mock app connection string into the command-scoped CGI
# handoff file.
write_task_seed_frontend_connection_file() {
  local connection_string="$1"
  local previous_umask=""

  load_env
  ensure_playground_state_dir

  TASK_SEED_FRONTEND_CONNECTION_FILE="$(task_seed_frontend_connection_file)"
  previous_umask="$(umask)"
  umask 077
  printf '%s\n' "${connection_string}" >"${TASK_SEED_FRONTEND_CONNECTION_FILE}"
  umask "${previous_umask}"
}

# Stops the foreground mock frontend server and removes its temporary log file.
cleanup_task_seed_frontend() {
  if task_seed_frontend_running; then
    kill "${TASK_SEED_FRONTEND_SERVER_PID}" >/dev/null 2>&1 || true
    wait "${TASK_SEED_FRONTEND_SERVER_PID}" 2>/dev/null || true
  fi

  if [ -n "${TASK_SEED_FRONTEND_LOG_FILE}" ] && [ -f "${TASK_SEED_FRONTEND_LOG_FILE}" ]; then
    rm -f "${TASK_SEED_FRONTEND_LOG_FILE}"
  fi

  if [ -n "${TASK_SEED_FRONTEND_CONNECTION_FILE}" ] && [ -f "${TASK_SEED_FRONTEND_CONNECTION_FILE}" ]; then
    rm -f "${TASK_SEED_FRONTEND_CONNECTION_FILE}"
  fi

  TASK_SEED_FRONTEND_SERVER_PID=""
  TASK_SEED_FRONTEND_LOG_FILE=""
  TASK_SEED_FRONTEND_CONNECTION_FILE=""
}

# Cleans up the foreground app runtime when the command exits or is interrupted.
cleanup_task_seed_app() {
  TASK_SEED_APP_STOPPING="true"
  cleanup_task_seed_frontend
  task_seed_cleanup_port_forward
}

# Starts the mock frontend server and waits for it to begin accepting requests.
start_task_seed_frontend() {
  local connection_string="$1"
  local attempt=0
  local frontend_probe_url="http://127.0.0.1:${TASK_SEED_FRONTEND_PORT}/"

  cleanup_task_seed_frontend
  TASK_SEED_FRONTEND_LOG_FILE="$(mktemp)"
  write_task_seed_frontend_connection_file "${connection_string}"

  (
    cd "${ROOT_DIR}/scripts/seed/mock-frontend"
    exec python3 -m http.server --bind 127.0.0.1 --cgi "${TASK_SEED_FRONTEND_PORT}"
  ) >"${TASK_SEED_FRONTEND_LOG_FILE}" 2>&1 &
  TASK_SEED_FRONTEND_SERVER_PID=$!

  while [ "${attempt}" -lt 20 ]; do
    if ! task_seed_frontend_running; then
      replay_task_seed_frontend_log
      return 1
    fi

    if task_seed_frontend_responding "${frontend_probe_url}"; then
      return 0
    fi

    sleep 0.2
    attempt=$((attempt + 1))
  done

  replay_task_seed_frontend_log
  return 1
}

# Waits for the foreground mock frontend to exit and reports unexpected
# failures.
wait_for_task_seed_frontend() {
  local exit_code=0

  if [ -z "${TASK_SEED_FRONTEND_SERVER_PID}" ]; then
    return 0
  fi

  if wait "${TASK_SEED_FRONTEND_SERVER_PID}"; then
    return 0
  fi

  exit_code=$?

  if [ "${TASK_SEED_APP_STOPPING}" = "true" ]; then
    return 0
  fi

  replay_task_seed_frontend_log
  return "${exit_code}"
}

# Runs the interactive mock app flow and keeps the frontend attached to the
# current terminal session.
run_task_mock_app() {
  local raw_connection_string=""
  local frontend_url="http://127.0.0.1:${TASK_SEED_FRONTEND_PORT}/cgi-bin/todos.sh"

  if ! ensure_task_seed_command_ready "Task mock:app" "task mock:app"; then
    return 0
  fi

  trap cleanup_task_seed_app EXIT INT TERM HUP

  require_cmd docker
  require_cmd python3

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

  run_task_seed_step \
    "Starting mock todo app" \
    "Started mock todo app" \
    start_task_seed_frontend "${TASK_SEED_CLIENT_CONNECTION_STRING}" \
    || die "Unable to start the mock todo app."

  if ! open_task_seed_frontend "${frontend_url}"; then
    warn "Unable to open the browser automatically. Open ${frontend_url} manually."
  fi

  print_summary_section "Mock app running"
  print_summary_field "Mock frontend" "$(style_action 1 "${frontend_url}")"
  if task_seed_port_forward_running; then
    print_summary_field "DB access" "$(style_dim 1 'Local port-forward stays up while this command is running.')"
  fi
  print_summary_field "Stop" "$(style_dim 1 'Press Ctrl-C to stop the mock app.')"
  printf '\n'

  wait_for_task_seed_frontend || die "The mock todo app stopped unexpectedly."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run_task_mock_app
fi
