#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared terminal helpers for the optional mock demo commands.
# -----------------------------------------------------------------------------

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

# Re-prompts until the user provides a non-empty value.
prompt_nonempty_value() {
  local prompt="$1"
  local answer=""

  while :; do
    answer="$(read_prompt_answer "${prompt}")"
    if [ -n "${answer}" ]; then
      printf '%s\n' "${answer}"
      return 0
    fi
    warn "Please enter a value."
  done
}

# Opens one mock frontend URL with the platform-default browser helper.
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

# Runs one stateful mock-command step in the current shell so function side
# effects remain visible to the caller.
run_task_seed_step() {
  local start_message="$1"
  local completion_message="$2"
  shift 2

  info "${start_message}."
  "$@" || return $?
  info "${completion_message}."
}

# Runs one stateful mock-command step in the current shell and captures its
# stdout into the named shell variable.
run_task_seed_capture_step() {
  local result_var_name="$1"
  local start_message="$2"
  local completion_message="$3"
  local output_file=""
  local output_value=""
  shift 3

  output_file="$(mktemp)"
  info "${start_message}."

  if ! "$@" >"${output_file}"; then
    if [ -s "${output_file}" ]; then
      replay_captured_output "${output_file}"
    fi
    rm -f "${output_file}"
    return 1
  fi

  output_value="$(cat "${output_file}")"
  rm -f "${output_file}"
  printf -v "${result_var_name}" '%s' "${output_value}"
  info "${completion_message}."
}

# Verifies that one interactive mock command can safely talk to the playground.
ensure_task_seed_command_ready() {
  local command_label="$1"
  local command_name="$2"

  if ! "${ROOT_DIR}/scripts/config/check-resume-state.sh"; then
    return 1
  fi

  if ! cluster_query_reachable; then
    die "Cluster ${CLUSTER_NAME} is not running. Start it with 'task up' first."
  fi

  if ! interactive_prompt_available; then
    die "${command_label} requires an interactive terminal. Re-run '${command_name}' in a terminal session."
  fi
}
