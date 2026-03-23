#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared config policy helpers for the playground.
# They classify config keys by how safely they can change on an existing
# playground and provide snapshot/diff helpers for both `task init` and `task up`.
# -----------------------------------------------------------------------------

CONFIG_STATE_DIR="${STATE_DIR}/config"
APPLIED_CONFIG_FILE="${CONFIG_STATE_DIR}/last-applied.env"

# Emits the tracked config keys, their user-facing labels, and their policy
# modes in the order they should appear in summaries.
config_policy_entries() {
  cat <<'EOF'
RESOLVED_K3D_SERVER_COUNT|Derived k3d server node count|requires_reset
RESOLVED_K3D_AGENT_COUNT|Derived k3d agent node count|requires_reset
RESOLVED_WORKER_LAYOUT|Derived worker layout|requires_reset
RESOLVED_WORKER_LAYOUT_CODE|Derived worker layout code|requires_reset
RESOLVED_DB_ENGINE_SET|Derived DB engine footprint|requires_reset
RESOLVED_CONTROL_PLANE_CPU|Control-plane allocatable CPU|requires_reset
RESOLVED_CONTROL_PLANE_MEMORY|Control-plane allocatable memory|requires_reset
RESOLVED_TOTAL_DB_CPU|Total DB worker allocatable CPU|requires_reset
RESOLVED_TOTAL_DB_MEMORY|Total DB worker allocatable memory|requires_reset
RESOLVED_SERVER_NODE_MEMORY|Control-plane node memory limit|requires_reset
RESOLVED_SERVER_KUBELET_RESERVATION|Control-plane kubelet reservation|requires_reset
RESOLVED_SERVER_NODE_TAINT|Control-plane scheduling taint|requires_reset
EVEREST_UI_PORT|UI port|requires_reset
ENABLE_BACKUP|Shared backup stack|in_place
EVEREST_HELM_CHART_VERSION|Everest Helm chart version|requires_reset
EVEREST_DB_NAMESPACE_CHART_VERSION|DB namespace Helm chart version|requires_reset
EOF
}

# Resolves one tracked config key into the current effective value, including
# profile-derived settings that are not stored directly in `config/playground.env`.
effective_config_value() {
  local key="$1"

  case "${key}" in
    RESOLVED_K3D_SERVER_COUNT)
      resolved_server_count
      ;;
    RESOLVED_K3D_AGENT_COUNT)
      resolved_agent_count
      ;;
    RESOLVED_WORKER_LAYOUT)
      resolved_worker_layout_pretty
      ;;
    RESOLVED_WORKER_LAYOUT_CODE)
      resolved_worker_layout_code
      ;;
    RESOLVED_DB_ENGINE_SET)
      resolved_engine_keys_csv
      ;;
    RESOLVED_CONTROL_PLANE_CPU)
      control_plane_allocatable_cpu_milli
      ;;
    RESOLVED_CONTROL_PLANE_MEMORY)
      control_plane_allocatable_memory_mib
      ;;
    RESOLVED_TOTAL_DB_CPU)
      resolved_total_worker_cpu_milli
      ;;
    RESOLVED_TOTAL_DB_MEMORY)
      resolved_total_worker_memory_mib
      ;;
    RESOLVED_SERVER_NODE_MEMORY)
      resolved_server_node_memory_limit
      ;;
    RESOLVED_SERVER_KUBELET_RESERVATION)
      kubelet_system_reserved_value_for_server
      ;;
    RESOLVED_SERVER_NODE_TAINT)
      resolved_server_node_taint
      ;;
    *)
      printf '%s\n' "${!key-}"
      ;;
  esac
}

# Returns success when the playground previously recorded a successful apply.
applied_config_recorded() {
  [ -f "${APPLIED_CONFIG_FILE}" ]
}

# Returns success when the k3d playground cluster still exists locally.
playground_exists() {
  if ! command -v k3d >/dev/null 2>&1; then
    return 1
  fi

  cluster_listed
}

# Reads the recorded cluster name from a config snapshot.
cluster_name_from_snapshot() {
  local snapshot_file="$1"

  config_value_from_snapshot "${snapshot_file}" "CLUSTER_NAME"
}

# Returns success when the cluster recorded in a snapshot still exists locally.
playground_exists_for_snapshot() {
  local snapshot_file="$1"
  local cluster_name=""
  local cluster_list_output=""

  if ! command -v k3d >/dev/null 2>&1; then
    return 1
  fi

  cluster_name="$(cluster_name_from_snapshot "${snapshot_file}")"
  [ -n "${cluster_name}" ] || return 1

  cluster_list_output="$(k3d_cluster_list_output)" || return 1
  printf '%s\n' "${cluster_list_output}" | awk -v cluster_name="${cluster_name}" 'NR > 1 && $1 == cluster_name { found = 1 } END { exit found ? 0 : 1 }'
}

# Returns success when either the currently requested cluster or the last
# applied cluster still exists, which keeps renamed clusters from bypassing the
# reset-required safeguards.
existing_playground_detected() {
  if playground_exists; then
    return 0
  fi

  if applied_config_recorded && playground_exists_for_snapshot "${APPLIED_CONFIG_FILE}"; then
    return 0
  fi

  return 1
}

# Ensures the `.state/config` directory exists before config snapshots are saved.
ensure_config_state_dir() {
  mkdir -p "${CONFIG_STATE_DIR}"
}

# Looks up one tracked config value from a snapshot file.
config_value_from_snapshot() {
  local snapshot_file="$1"
  local key="$2"

  awk -F= -v key="${key}" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
    }
    END {
      if (value != "") {
        print value
      }
    }
  ' "${snapshot_file}"
}

# Writes the current effective config into a stable snapshot file so later
# commands can compare intent against the last successful apply.
write_effective_config_snapshot() {
  local snapshot_file="$1"
  local key
  local label
  local mode
  local value_file
  local value=""
  local cluster_name=""

  load_env
  cluster_name="${CLUSTER_NAME:-}"
  : >"${snapshot_file}"
  printf '%s=%s\n' "CLUSTER_NAME" "${cluster_name}" >>"${snapshot_file}"
  value_file="$(mktemp)"

  while IFS='|' read -r key label mode; do
    : >"${value_file}"
    effective_config_value "${key}" >"${value_file}"
    IFS= read -r value <"${value_file}" || value=""
    printf '%s=%s\n' "${key}" "${value}" >>"${snapshot_file}"
  done < <(config_policy_entries)

  rm -f "${value_file}"
}

# Renders one value for human-readable summaries.
display_config_value() {
  local value="${1:-}"

  if [ -n "${value}" ]; then
    printf '%s' "${value}"
  else
    printf '(empty)'
  fi
}

# Emits every tracked config change as a pipe-delimited line:
# mode, key, label, previous value, next value.
emit_config_changes() {
  local baseline_file="$1"
  local candidate_file="$2"
  local key
  local label
  local mode
  local previous_value
  local next_value

  while IFS='|' read -r key label mode; do
    previous_value="$(config_value_from_snapshot "${baseline_file}" "${key}")"
    next_value="$(config_value_from_snapshot "${candidate_file}" "${key}")"

    if [ "${previous_value}" != "${next_value}" ]; then
      printf '%s|%s|%s|%s|%s\n' "${mode}" "${key}" "${label}" "${previous_value}" "${next_value}"
    fi
  done < <(config_policy_entries)
}

# Returns success when any tracked config key changed between two snapshots.
config_changes_present() {
  local baseline_file="$1"
  local candidate_file="$2"

  emit_config_changes "${baseline_file}" "${candidate_file}" | awk 'NR == 1 { found = 1 } END { exit found ? 0 : 1 }'
}

# Returns success when the requested snapshot matches the last recorded apply.
applied_config_matches_snapshot() {
  local candidate_file="$1"

  applied_config_recorded || return 1

  if config_changes_present "${APPLIED_CONFIG_FILE}" "${candidate_file}"; then
    return 1
  fi

  return 0
}

# Returns success when at least one change of the requested mode is present.
config_changes_include_mode() {
  local baseline_file="$1"
  local candidate_file="$2"
  local requested_mode="$3"

  emit_config_changes "${baseline_file}" "${candidate_file}" | awk -F'\\|' -v requested_mode="${requested_mode}" '$1 == requested_mode { found = 1 } END { exit found ? 0 : 1 }'
}

# Prints all changes for one policy mode and returns success when any were found.
print_config_changes_for_mode() {
  local baseline_file="$1"
  local candidate_file="$2"
  local requested_mode="$3"
  local heading="$4"
  local mode=""
  local key=""
  local label=""
  local previous_value=""
  local next_value=""
  local found=1
  local styled_heading=""

  while IFS='|' read -r mode key label previous_value next_value; do
    if [ "${found}" -ne 0 ]; then
      case "${requested_mode}" in
        requires_reset)
          styled_heading="$(style_error 1 "${heading}")"
          ;;
        in_place)
          styled_heading="$(style_accent 1 "${heading}")"
          ;;
        local_only)
          styled_heading="$(style_dim 1 "${heading}")"
          ;;
        *)
          styled_heading="${heading}"
          ;;
      esac

      printf '%s:\n' "${styled_heading}"
      found=0
    fi

    printf -- '- %s: %s -> %s\n' \
      "$(style_bold 1 "${label}")" \
      "$(display_config_value "${previous_value}")" \
      "$(display_config_value "${next_value}")"
  done < <(emit_config_changes "${baseline_file}" "${candidate_file}" | awk -F'\\|' -v requested_mode="${requested_mode}" '$1 == requested_mode')

  return "${found}"
}

# Prints a grouped summary of the config drift between two snapshots.
print_config_change_summary() {
  local baseline_file="$1"
  local candidate_file="$2"
  local printed_any=1

  if print_config_changes_for_mode "${baseline_file}" "${candidate_file}" "requires_reset" "Reset-required changes"; then
    printed_any=0
  fi

  if print_config_changes_for_mode "${baseline_file}" "${candidate_file}" "in_place" "In-place changes"; then
    printed_any=0
  fi

  if print_config_changes_for_mode "${baseline_file}" "${candidate_file}" "local_only" "Local-only changes"; then
    printed_any=0
  fi

  return "${printed_any}"
}
