#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared output styling and logging helpers.
# -----------------------------------------------------------------------------

# Returns success when the target stream is an interactive terminal and color
# has not been explicitly disabled by the user or terminal environment.
supports_color() {
  local fd="${1:-1}"

  if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ] || [ "${PLAYGROUND_NO_COLOR:-0}" = "1" ]; then
    return 1
  fi

  case "${fd}" in
    1)
      [ "${PLAYGROUND_STDOUT_TTY:-0}" = "1" ]
      ;;
    2)
      [ "${PLAYGROUND_STDERR_TTY:-0}" = "1" ]
      ;;
    *)
      [ -t "${fd}" ]
      ;;
  esac
}

# Wraps text in an ANSI style sequence when the target stream supports color.
style_text() {
  local fd="$1"
  local style_code="$2"
  shift 2

  if supports_color "${fd}"; then
    printf '\033[%sm%s\033[0m' "${style_code}" "$*"
  else
    printf '%s' "$*"
  fi
}

# Renders emphasized text for headings or key values.
style_bold() {
  local fd="${1:-1}"
  shift
  style_text "${fd}" "1" "$*"
}

# Renders muted helper text that should stay visible without competing with the
# main prompt or summary content.
style_dim() {
  local fd="${1:-1}"
  shift
  style_text "${fd}" "2" "$*"
}

# Renders the shared accent color used for interactive prompts.
style_accent() {
  local fd="${1:-1}"
  shift
  style_text "${fd}" "1;36" "$*"
}

# Renders dimmed labels and metadata so the main values stand out more clearly.
style_label() {
  local fd="${1:-1}"
  shift
  style_text "${fd}" "2" "$*"
}

# Renders commands, URLs, and other actionable values with the shared accent.
style_action() {
  local fd="${1:-1}"
  shift
  style_text "${fd}" "1;36" "$*"
}

# Renders positive status text such as an enabled feature.
style_success() {
  local fd="${1:-1}"
  shift
  style_text "${fd}" "1;32" "$*"
}

# Renders friendly setup titles and other welcoming callouts.
style_title() {
  local fd="${1:-1}"
  shift
  style_text "${fd}" "1;33" "$*"
}

# Renders cautionary text such as confirmation prompts.
style_warning() {
  local fd="${1:-1}"
  shift
  style_text "${fd}" "1;33" "$*"
}

# Renders error-oriented text for reset-required changes or fatal outcomes.
style_error() {
  local fd="${1:-1}"
  shift
  style_text "${fd}" "1;31" "$*"
}

# Prints an informational log line with the shared playground prefix.
# Operational logs go to stderr so they still behave like live terminal output
# even when task runners buffer or pipe stdout.
info() {
  printf '%s %s\n' "$(style_accent 2 '[INFO]')" "$*" >&2
}

# Prints a warning log line to stderr.
warn() {
  printf '%s %s\n' "$(style_warning 2 '[WARN]')" "$*" >&2
}

# Prints an error log line and terminates the current script.
die() {
  printf '%s %s\n' "$(style_error 2 '[ERROR]')" "$*" >&2
  exit 1
}
