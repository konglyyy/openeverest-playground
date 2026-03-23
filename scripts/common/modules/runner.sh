#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared command execution helpers for setup flows.
# -----------------------------------------------------------------------------

# Returns success when the current environment should animate long-running
# steps with a spinner instead of printing static start lines.
spinner_enabled() {
  load_env

  if verbose_output_enabled; then
    return 1
  fi

  if [ -n "${ACCESSIBLE:-}" ] || is_truthy "${PLAYGROUND_NO_SPINNER}"; then
    return 1
  fi

  [ "${PLAYGROUND_STDIN_TTY:-0}" = "1" ] || [ "${PLAYGROUND_STDERR_TTY:-0}" = "1" ] || [ "${PLAYGROUND_STDOUT_TTY:-0}" = "1" ]
}

# Returns a simple ASCII spinner frame for the current tick.
spinner_frame() {
  local index="${1:-0}"
  local frames=("." ".." "...")

  printf '%s' "${frames[$((index % ${#frames[@]}))]}"
}

# Runs a command and captures stdout/stderr in a file for optional replay.
capture_command_output() {
  local output_file="$1"
  shift

  "$@" >"${output_file}" 2>&1
  return $?
}

# Replays captured command output with a small indent so it is visually grouped
# under the playground-owned error line.
replay_captured_output() {
  local output_file="$1"

  if [ -s "${output_file}" ]; then
    sed 's/^/  /' "${output_file}" >&2
  fi
}

# Runs a noisy command quietly during normal setup. When verbose mode is off,
# stdout/stderr are captured and only replayed if the command fails.
run_quiet() {
  local output_file=""
  local exit_code=0

  if verbose_output_enabled; then
    "$@"
    return $?
  fi

  output_file="$(mktemp)"

  capture_command_output "${output_file}" "$@"
  exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    rm -f "${output_file}"
    return 0
  fi

  warn "A setup command failed. Showing the captured tool output:"
  replay_captured_output "${output_file}"
  rm -f "${output_file}"
  return "${exit_code}"
}

# Runs one long-lived setup step with either a spinner or a concise static line.
# The completion message is shown only when the spinner path is active.
run_step() {
  local start_message="$1"
  local completion_message="$2"
  shift 2

  local output_file=""
  local exit_code=0
  local frame_index=0
  local pid=0

  if verbose_output_enabled; then
    info "${start_message}."
    "$@"
    return $?
  fi

  output_file="$(mktemp)"

  if ! spinner_enabled; then
    info "${start_message}."
    capture_command_output "${output_file}" "$@"
    exit_code=$?

    if [ "${exit_code}" -eq 0 ]; then
      rm -f "${output_file}"
      return 0
    fi

    warn "A setup command failed. Showing the captured tool output:"
    replay_captured_output "${output_file}"
    rm -f "${output_file}"
    return "${exit_code}"
  fi

  capture_command_output "${output_file}" "$@" &
  pid=$!

  while kill -0 "${pid}" >/dev/null 2>&1; do
    printf '\r\033[2K%s %s %s' \
      "$(style_accent 2 '[INFO]')" \
      "${start_message}" \
      "$(style_accent 2 "$(spinner_frame "${frame_index}")")" >&2
    frame_index=$((frame_index + 1))
    sleep 1
  done

  if wait "${pid}"; then
    exit_code=0
  else
    exit_code=$?
  fi

  printf '\r\033[2K' >&2

  if [ "${exit_code}" -eq 0 ]; then
    printf '%s %s\n' \
      "$(style_accent 2 '[INFO]')" \
      "${completion_message}" >&2
    rm -f "${output_file}"
    return 0
  fi

  printf '%s %s\n' "$(style_error 2 '[ERROR]')" "${start_message} failed." >&2
  replay_captured_output "${output_file}"
  rm -f "${output_file}"
  return "${exit_code}"
}

# Runs a read-only report command with the shared spinner treatment. Unlike
# `run_step`, successful stdout is preserved and emitted after the spinner clears.
run_report_step() {
  local start_message="$1"
  shift

  local output_file=""
  local exit_code=0
  local frame_index=0
  local pid=0

  if verbose_output_enabled || ! spinner_enabled; then
    "$@"
    return $?
  fi

  output_file="$(mktemp)"

  capture_command_output "${output_file}" "$@" &
  pid=$!

  while kill -0 "${pid}" >/dev/null 2>&1; do
    printf '\r\033[2K%s %s %s' \
      "$(style_accent 2 '[INFO]')" \
      "${start_message}" \
      "$(style_accent 2 "$(spinner_frame "${frame_index}")")" >&2
    frame_index=$((frame_index + 1))
    sleep 1
  done

  if wait "${pid}"; then
    exit_code=0
  else
    exit_code=$?
  fi

  printf '\r\033[2K' >&2

  if [ "${exit_code}" -eq 0 ]; then
    cat "${output_file}"
    rm -f "${output_file}"
    return 0
  fi

  replay_captured_output "${output_file}"
  rm -f "${output_file}"
  return "${exit_code}"
}
