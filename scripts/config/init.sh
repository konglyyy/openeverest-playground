#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Interactively captures the small set of supported playground choices and
# writes them into `config/playground.env` before delegating to the deterministic apply path.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EXAMPLE_ENV_FILE="${ROOT_DIR}/config/playground.env.example"
ENV_FILE="${ROOT_DIR}/config/playground.env"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/config/policy.sh"

# Rewrites or appends a single KEY=value pair inside an env file.
update_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local rendered_value=""
  local temp_file

  rendered_value="$(render_env_value "${value}")"
  temp_file="$(mktemp)"
  awk -v key="${key}" -v value="${rendered_value}" '
    BEGIN {
      updated = 0
    }
    $0 ~ ("^" key "=") {
      print key "=" value
      updated = 1
      next
    }
    {
      print
    }
    END {
      if (!updated) {
        print key "=" value
      }
    }
  ' "${env_file}" >"${temp_file}"
  mv "${temp_file}" "${env_file}"
}

# Renders one env value back to a shell-safe dotenv form.
render_env_value() {
  local value="$1"
  local escaped_value=""

  case "${value}" in
    \"*\" | \'*\')
      printf '%s\n' "${value}"
      return 0
      ;;
  esac

  case "${value}" in
    *[[:space:]]*)
      escaped_value="$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")"
      printf "'%s'\n" "${escaped_value}"
      ;;
    *)
      printf '%s\n' "${value}"
      ;;
  esac
}

# Returns success when the env key is still part of the supported public config surface.
supported_env_key() {
  local key="$1"

  case "${key}" in
    ENABLE_BACKUP | EVEREST_UI_PORT | EVEREST_HELM_CHART_VERSION | EVEREST_DB_NAMESPACE_CHART_VERSION)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Starts from the committed example file and overlays any existing local values
# so rerunning `task init` refreshes new defaults without discarding prior edits.
refresh_env_file() {
  local refreshed_env
  local line
  local key
  local value

  refreshed_env="$(mktemp)"
  cp "${EXAMPLE_ENV_FILE}" "${refreshed_env}"

  if [ -f "${ENV_FILE}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
      case "${line}" in
        '' | \#*)
          continue
          ;;
        *=*)
          key="${line%%=*}"
          value="${line#*=}"
          if ! supported_env_key "${key}"; then
            continue
          fi
          update_env_value "${refreshed_env}" "${key}" "${value}"
          ;;
      esac
    done <"${ENV_FILE}"
  fi

  mv "${refreshed_env}" "${ENV_FILE}"
}

# Prints a short wizard header so the interactive session feels deliberate and
# makes the setup flow obvious to users.
print_wizard_intro() {
  cat >&2 <<EOF

$(style_title 2 "OpenEverest Playground Setup")
$(style_dim 2 "Choose optional features for your local playground.")

EOF
}

# Returns success when stdin is still connected to a terminal. The prompt
# helpers are invoked inside command substitution, so stdout cannot be used as a
# reliable TTY signal.
interactive_prompt_available() {
  [ -t 0 ]
}

# Returns success when the terminal can support a simple arrow-key menu.
interactive_menu_available() {
  interactive_prompt_available && [ "${TERM:-dumb}" != "dumb" ] && [ "${PLAYGROUND_NO_MENU:-0}" != "1" ]
}

# Writes a prompt to stderr and reads the user's response from stdin. Stdout is
# reserved for the returned answer so callers can capture it safely.
read_prompt_answer() {
  local prompt="$1"
  local answer=""

  printf '%s' "${prompt}" >&2
  IFS= read -r answer || answer=""

  printf '%s\n' "${answer}"
}

# Renders one option row inside the arrow-key selector.
render_menu_option() {
  local label="$1"
  local selected="$2"

  if [ "${selected}" = "true" ]; then
    printf '  %s %s\n' "$(style_accent 2 '❯')" "$(style_accent 2 "${label}")" >&2
  else
    printf '    %s\n' "${label}" >&2
  fi
}

# Lets the user choose from a small option list with the arrow keys.
select_menu_option() {
  local question="$1"
  local default_index="$2"
  shift 2

  local -a option_labels=()
  local -a option_values=()
  local option_spec=""
  local option_label=""
  local option_value=""
  local selected_index="${default_index}"
  local option_count=0
  local key=""
  local escape_sequence=""
  local selection_made="false"
  local index=0
  local menu_lines=0

  while [ "$#" -gt 0 ]; do
    option_spec="$1"
    option_label="${option_spec%%|*}"
    option_value="${option_spec#*|}"
    option_labels+=("${option_label}")
    option_values+=("${option_value}")
    option_count=$((option_count + 1))
    shift
  done

  print_wizard_question "${question}"
  menu_lines=$((option_count + 1))

  # Draw the selector on stderr so stdout remains reserved for the chosen value.
  while :; do
    index=0
    while [ "${index}" -lt "${option_count}" ]; do
      if [ "${index}" -eq "${selected_index}" ]; then
        render_menu_option "${option_labels[${index}]}" true
      else
        render_menu_option "${option_labels[${index}]}" false
      fi
      index=$((index + 1))
    done
    printf '    %s\n' "$(style_dim 2 'Up/Down to select.')" >&2

    IFS= read -rsn1 key || key=""

    case "${key}" in
      '')
        selection_made="true"
        ;;
      'j' | 'J')
        selected_index=$(((selected_index + 1) % option_count))
        ;;
      'k' | 'K')
        selected_index=$(((selected_index - 1 + option_count) % option_count))
        ;;
      ' ')
        selection_made="true"
        ;;
      $'\x1b')
        IFS= read -rsn2 escape_sequence || escape_sequence=""
        case "${escape_sequence}" in
          '[A')
            selected_index=$(((selected_index - 1 + option_count) % option_count))
            ;;
          '[B')
            selected_index=$(((selected_index + 1) % option_count))
            ;;
        esac
        ;;
    esac

    if [ "${selection_made}" = "true" ]; then
      printf '\n' >&2
      printf '%s\n' "${option_values[${selected_index}]}"
      return 0
    fi

    # Move back to the start of the rendered option block and clear each line
    # before redrawing the selector in its updated state.
    printf '\033[%sA' "${menu_lines}" >&2
    index=0
    while [ "${index}" -lt "${menu_lines}" ]; do
      printf '\033[2K\r' >&2
      if [ "${index}" -lt $((menu_lines - 1)) ]; then
        printf '\033[1B' >&2
      fi
      index=$((index + 1))
    done
    if [ "${menu_lines}" -gt 1 ]; then
      printf '\033[%sA' $((menu_lines - 1)) >&2
    fi
  done
}

# Prints one compact wizard prompt line.
print_wizard_question() {
  local question="$1"

  printf '%s %s\n' "$(style_accent 2 '?')" "${question}" >&2
}

# Prompts for whether one optional feature should be enabled.
prompt_feature_toggle() {
  local question="$1"
  local default_answer="$2"
  local answer=""
  local default_index=0
  local no_label="No"
  local yes_label="Yes"

  if [ "${default_answer}" = "true" ]; then
    default_index=1
  else
    no_label="${no_label} (default)"
  fi

  if interactive_menu_available; then
    answer="$(
      select_menu_option \
        "${question}" \
        "${default_index}" \
        "${no_label}|false" \
        "${yes_label}|true"
    )"
  elif interactive_prompt_available; then
    answer="$(read_prompt_answer "$(style_accent 2 ' ->') ${question} [$([ "${default_answer}" = "true" ] && printf 'Y/n' || printf 'y/N')]: ")"
  else
    info "No interactive terminal detected. Using the current/default playground feature set." >&2
  fi

  case "${answer}" in
    true | false)
      printf '%s\n' "${answer}"
      ;;
    '')
      printf '%s\n' "${default_answer}"
      ;;
    [Yy] | [Yy][Ee][Ss])
      printf 'true\n'
      ;;
    [Nn] | [Nn][Oo])
      printf 'false\n'
      ;;
    *)
      warn "Unrecognized answer '${answer}'. Keeping the current/default choice."
      printf '%s\n' "${default_answer}"
      ;;
  esac
}

# Prompts for whether the optional backup stack should be enabled, defaulting to
# the current config if it exists.
prompt_enable_backup() {
  local default_answer="$1"

  prompt_feature_toggle "Would you like to enable backup testing?" "${default_answer}"
}

# Prints a compact summary of the plan that will be applied next.
print_plan_summary() {
  local backup_flag="$1"
  local backup_label=""
  local contention_warning=""

  if [ "${backup_flag}" = "true" ]; then
    backup_label="$(style_success 1 'enabled')"
  else
    backup_label="$(style_dim 1 'disabled')"
  fi

  printf '%s %s\n' "$(style_accent 1 '[INFO]')" "$(style_bold 1 'Playground plan saved')"
  printf '%s\n\n' "$(style_dim 1 "${ENV_FILE}")"
  printf '  %-22s %s\n' "Docker budget" "$(style_bold 1 "$(format_bytes_as_gib "$(docker_memory_bytes)") / $(docker_cpu_count) CPU")"
  printf '  %-22s %s\n' "Resolved layout" "$(style_bold 1 "$(resolved_layout_display)")"
  printf '  %-22s %s\n' "Control plane" "$(style_bold 1 "$(format_cpu_milli "$(control_plane_allocatable_cpu_milli)") / $(format_memory_mib "$(control_plane_allocatable_memory_mib)")")"
  printf '  %-22s %s\n' "DB worker pool" "$(style_bold 1 "$(format_cpu_milli "$(resolved_total_worker_cpu_milli)") / $(format_memory_mib "$(resolved_total_worker_memory_mib)")")"
  printf '  %-22s %s\n' "DB engines" "$(managed_engine_display_list)"
  printf '  %-22s %b\n' "Shared backup stack" "${backup_label}"

  contention_warning="$(docker_contention_warning_message 2>/dev/null || true)"
  if [ -n "${contention_warning}" ]; then
    printf '\n%s %s\n' "$(style_warning 1 '[WARN]')" "${contention_warning}"
  fi

  printf '\n'
}

# Prompts before mutating an existing playground in place so `task init` never
# surprises the user with a config change they did not explicitly approve.
confirm_existing_playground_changes() {
  local answer=""

  if ! interactive_prompt_available; then
    die "Applying config changes to an existing playground requires an interactive terminal. Re-run 'task init' interactively or use 'task up' if you already intend the current config."
  fi

  printf '\n%s\n' "$(style_warning 2 'Existing playground changes detected')" >&2
  printf '%s\n' "$(style_dim 2 'Review the summary above before continuing.')" >&2

  if interactive_menu_available; then
    answer="$(
      select_menu_option \
        "Apply supported changes to the existing playground?" \
        0 \
        "No (default)|false" \
        "Yes|true"
    )"
  else
    answer="$(read_prompt_answer "$(style_warning 2 ' ->') Apply these changes to the existing playground? [y/N]: ")"
  fi

  case "${answer}" in
    true)
      return 0
      ;;
    [Yy] | [Yy][Ee][Ss])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

load_env
starting_env_file="$(mktemp)"
starting_snapshot="$(mktemp)"
requested_snapshot="$(mktemp)"
inspection_result_file="$(mktemp)"
playground_runtime_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/openeverest-playground-runtime.XXXXXX")"
skip_apply="false"
export PLAYGROUND_RUNTIME_CACHE_DIR="${playground_runtime_cache_dir}"
trap 'rm -f "${starting_env_file}" "${starting_snapshot}" "${requested_snapshot}" "${inspection_result_file}"; rm -rf "${playground_runtime_cache_dir}"' EXIT

# Renders an effective config snapshot for an arbitrary env file in a clean
# Bash subprocess so the current shell environment does not leak into it.
write_snapshot_for_env_file() {
  local env_file="$1"
  local snapshot_file="$2"

  env \
    PATH="${PATH}" \
    PLAYGROUND_ENV_FILE="${env_file}" \
    PLAYGROUND_STATE_DIR="${PLAYGROUND_STATE_DIR}" \
    PLAYGROUND_RUNTIME_CACHE_DIR="${PLAYGROUND_RUNTIME_CACHE_DIR:-}" \
    bash -lc '
      set -euo pipefail
      cd "'"${ROOT_DIR}"'"
      # shellcheck disable=SC1091
      . "'"${ROOT_DIR}"'/scripts/common/lib.sh"
      # shellcheck disable=SC1091
      . "'"${ROOT_DIR}"'/scripts/config/policy.sh"
      write_effective_config_snapshot "'"${snapshot_file}"'"
    '
}

# Writes one key/value pair into the inspection result file shared across the
# named preflight substeps.
write_inspection_result() {
  local key="$1"
  local value="$2"

  printf '%s=%s\n' "${key}" "${value}" >>"${inspection_result_file}"
}

# Looks up one key from the inspection result file created during the
# post-prompt preflight step.
inspection_result_value() {
  local key="$1"

  awk -F= -v key="${key}" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
    }
    END {
      if (value != "") {
        print value
      }
    }
  ' "${inspection_result_file}"
}

# Resolves the requested plan against the live Docker budget and records the
# resulting effective config snapshot for later comparison.
inspect_requested_playground_plan() {
  : >"${inspection_result_file}"
  refresh_docker_runtime_info_snapshot
  write_effective_config_snapshot "${requested_snapshot}"
  validate_playground_sizing
}

# Detects whether this run is targeting a brand-new cluster or reconciling an
# existing playground, and records the right baseline snapshot for comparisons.
inspect_existing_playground_state() {
  if existing_playground_detected; then
    write_inspection_result "RESULT" "existing"
    if applied_config_recorded; then
      write_inspection_result "BASELINE_MODE" "applied"
      write_inspection_result "BASELINE_SNAPSHOT" "${APPLIED_CONFIG_FILE}"
    else
      write_snapshot_for_env_file "${starting_env_file}" "${starting_snapshot}" || return 1
      write_inspection_result "BASELINE_MODE" "starting"
      write_inspection_result "BASELINE_SNAPSHOT" "${starting_snapshot}"
    fi
  else
    write_inspection_result "RESULT" "new"
  fi
}

# Compares the requested config snapshot against the chosen baseline so the
# user-facing decision logic can avoid repeating the diff work later on.
compare_requested_playground_config() {
  local baseline_snapshot=""

  write_inspection_result "CHANGES_PRESENT" "false"
  write_inspection_result "REQUIRES_RESET" "false"
  write_inspection_result "IN_PLACE_CHANGES" "false"
  write_inspection_result "LOCAL_ONLY_CHANGES" "false"

  if [ "$(inspection_result_value "RESULT")" != "existing" ]; then
    return 0
  fi

  baseline_snapshot="$(inspection_result_value "BASELINE_SNAPSHOT")"
  [ -n "${baseline_snapshot}" ] || return 1

  if config_changes_present "${baseline_snapshot}" "${requested_snapshot}"; then
    write_inspection_result "CHANGES_PRESENT" "true"
  fi

  if config_changes_include_mode "${baseline_snapshot}" "${requested_snapshot}" "requires_reset"; then
    write_inspection_result "REQUIRES_RESET" "true"
  fi

  if config_changes_include_mode "${baseline_snapshot}" "${requested_snapshot}" "in_place"; then
    write_inspection_result "IN_PLACE_CHANGES" "true"
  fi

  if config_changes_include_mode "${baseline_snapshot}" "${requested_snapshot}" "local_only"; then
    write_inspection_result "LOCAL_ONLY_CHANGES" "true"
  fi
}

if interactive_prompt_available; then
  print_wizard_intro
fi

refresh_env_file
cp "${ENV_FILE}" "${starting_env_file}"

default_backup="false"
if backup_enabled; then
  default_backup="true"
fi

selected_backup="$(prompt_enable_backup "${default_backup}")"

update_env_value "${ENV_FILE}" "ENABLE_BACKUP" "${selected_backup}"

# Reload the environment so the summary and delegated `task up` run use the
# exact config that was just written to disk.
clear_runtime_resolution_cache
PLAYGROUND_ENV_LOADED=""
export PLAYGROUND_ENV_LOADED
load_env
run_step \
  "Inspecting Docker budget and resolved layout" \
  "Inspected Docker budget and resolved layout." \
  inspect_requested_playground_plan \
  || die "Unable to inspect the Docker budget and resolved layout."
run_step \
  "Checking current playground state" \
  "Checked current playground state." \
  inspect_existing_playground_state \
  || die "Unable to check the current playground state."
run_step \
  "Comparing requested config with the current playground state" \
  "Compared the requested config with the current playground state." \
  compare_requested_playground_config \
  || die "Unable to compare the requested config with the current playground state."

inspection_result="$(inspection_result_value "RESULT")"

if [ "${inspection_result}" = "existing" ]; then
  baseline_snapshot="$(inspection_result_value "BASELINE_SNAPSHOT")"
  baseline_mode="$(inspection_result_value "BASELINE_MODE")"
  changes_present="$(inspection_result_value "CHANGES_PRESENT")"
  requires_reset="$(inspection_result_value "REQUIRES_RESET")"
  in_place_changes="$(inspection_result_value "IN_PLACE_CHANGES")"

  if [ "${baseline_mode}" = "applied" ]; then
    info "Existing playground detected. Comparing the requested plan against the last applied config."
  else
    warn "Existing playground detected, but no applied config snapshot is recorded yet. Comparing against the current local config for this run."
  fi

  if [ "${requires_reset}" = "true" ]; then
    warn "Requested changes are not safe to reconcile in place."
    print_config_change_summary "${baseline_snapshot}" "${requested_snapshot}"
    die "Run 'task reset' and then 'task init' to apply those changes cleanly."
  fi

  if [ "${changes_present}" = "true" ]; then
    print_config_change_summary "${baseline_snapshot}" "${requested_snapshot}"

    if [ "${in_place_changes}" = "true" ]; then
      if ! confirm_existing_playground_changes; then
        die "Aborted. Existing playground left unchanged."
      fi
    else
      info "Only local-only settings changed. Reapplying the current playground config."
    fi
  elif applied_config_matches_snapshot "${requested_snapshot}"; then
    info "Existing playground config is unchanged. Nothing to apply."
    skip_apply="true"
  else
    info "Existing playground config is unchanged, but no applied snapshot is recorded yet. Reapplying once to record the current baseline."
  fi
else
  info "No existing playground detected. Applying the selected plan."
fi

print_plan_summary "${selected_backup}"

if [ "${skip_apply}" = "true" ]; then
  info "Playground is already initialized with this config. Use 'task up' to start it, 'task status' to inspect it, or 'task reset' for a fresh install."
  exit 0
fi

info "Initializing the playground. This can take a few minutes on a fresh setup."

task --taskfile "${ROOT_DIR}/Taskfile.yml" init:apply
