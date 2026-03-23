#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared user-facing summaries.
# -----------------------------------------------------------------------------

SUMMARY_LABEL_WIDTH=20

# Returns a tab-delimited topology summary derived from the resolved plan.
resolved_topology_metrics_tsv() {
  local control_total_cpu_milli=0
  local control_total_memory_mib=0

  load_resolved_worker_layout
  control_total_cpu_milli="$(control_plane_allocatable_cpu_milli)"
  control_total_memory_mib="$(control_plane_allocatable_memory_mib)"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "1" \
    "true" \
    "${control_total_cpu_milli}" \
    "${control_total_memory_mib}" \
    "${PLAYGROUND_RESOLVED_AGENT_COUNT}" \
    "${PLAYGROUND_RESOLVED_TOTAL_WORKER_CPU_MILLI}" \
    "${PLAYGROUND_RESOLVED_TOTAL_WORKER_MEMORY_MIB}" \
    "resolved"
}

# Returns a tab-delimited topology summary sourced from one rendered node list JSON payload.
topology_metrics_tsv_from_node_json() {
  local node_json="$1"

  printf '%s\n' "${node_json}" | jq -r '
    def cpu_to_m:
      if . == null or . == "" then 0
      elif test("m$") then (sub("m$"; "") | tonumber)
      else (tonumber * 1000)
      end;
    def mem_to_mi:
      if . == null or . == "" then 0
      elif test("Ki$") then (((sub("Ki$"; "") | tonumber) / 1024) | floor)
      elif test("Mi$") then (sub("Mi$"; "") | tonumber)
      elif test("Gi$") then ((sub("Gi$"; "") | tonumber) * 1024)
      else 0
      end;
    [.items[] | {
      control_plane: (
        (.metadata.labels["node-role.kubernetes.io/control-plane"] == "true")
        or (.metadata.labels["node-role.kubernetes.io/master"] == "true")
      ),
      no_schedule: any(.spec.taints[]?; .effect == "NoSchedule"),
      cpu_m: (.status.allocatable.cpu | cpu_to_m),
      mem_mi: (.status.allocatable.memory | mem_to_mi)
    }] as $nodes
    | ($nodes | map(select(.control_plane))) as $control
    | ($nodes | map(select(.control_plane | not))) as $workers
    | if (($control | length) == 0 or ($workers | length) == 0) then
        empty
      else
        [
          ($control | length),
          (all($control[]; .no_schedule)),
          ($control | map(.cpu_m) | add),
          ($control | map(.mem_mi) | add),
          ($workers | length),
          ($workers | map(.cpu_m) | add),
          ($workers | map(.mem_mi) | add),
          "live"
        ] | @tsv
      end
  '
}

# Returns a tab-delimited topology summary sourced from live node allocatable values.
live_topology_metrics_tsv() {
  local node_json=""

  load_env
  node_json="$(k_query get nodes -o json 2>/dev/null)" || return 1
  topology_metrics_tsv_from_node_json "${node_json}"
}

# Prints the human-readable topology summary from one prepared metrics payload.
print_playground_topology_summary_from_metrics_tsv() {
  local topology_metrics="$1"
  local show_live_query_fallback_note="${2:-false}"
  local control_count=0
  local control_no_schedule="true"
  local control_total_cpu_milli=0
  local control_total_memory_mib=0
  local worker_count=0
  local worker_total_cpu_milli=0
  local worker_total_memory_mib=0
  local source="resolved"
  local control_avg_cpu_milli=0
  local control_avg_memory_mib=0
  local worker_avg_cpu_milli=0
  local worker_avg_memory_mib=0
  local control_schedule_label=""
  local backup_label=""

  load_docker_runtime_info
  load_resolved_worker_layout

  IFS=$'\t' read -r \
    control_count \
    control_no_schedule \
    control_total_cpu_milli \
    control_total_memory_mib \
    worker_count \
    worker_total_cpu_milli \
    worker_total_memory_mib \
    source <<<"${topology_metrics}"

  control_avg_cpu_milli=$((control_total_cpu_milli / control_count))
  control_avg_memory_mib=$((control_total_memory_mib / control_count))
  worker_avg_cpu_milli=$((worker_total_cpu_milli / worker_count))
  worker_avg_memory_mib=$((worker_total_memory_mib / worker_count))

  if [ "${control_no_schedule}" = "true" ]; then
    control_schedule_label="$(style_success 1 'NoSchedule')"
  else
    control_schedule_label="$(style_warning 1 'schedulable')"
  fi

  if backup_enabled; then
    backup_label="$(style_success 1 'enabled')"
  else
    backup_label="$(style_dim 1 'disabled')"
  fi

  printf '\n%s\n' "$(style_title 1 'Topology')"
  printf '  %b %b\n' \
    "$(summary_label_cell 'Docker budget')" \
    "$(style_bold 1 "$(format_bytes_as_gib "$(docker_memory_bytes)") / $(docker_cpu_count) CPU")"
  printf '  %b %b\n' \
    "$(summary_label_cell 'Resolved layout')" \
    "$(style_bold 1 "$(resolved_layout_display)")"
  printf '  %b %b\n' \
    "$(summary_label_cell 'Control plane')" \
    "$(style_bold 1 "${control_count} x server") (${control_schedule_label}, $(format_cpu_milli "${control_avg_cpu_milli}") / $(format_memory_mib "${control_avg_memory_mib}") allocatable)"
  printf '  %b %b\n' \
    "$(summary_label_cell 'DB workers')" \
    "$(style_bold 1 "${worker_count} x agent") ($(resolved_worker_layout_pretty), $(format_cpu_milli "${worker_avg_cpu_milli}") / $(format_memory_mib "${worker_avg_memory_mib}") avg allocatable)"
  printf '  %b %b\n' \
    "$(summary_label_cell 'Total DB pool')" \
    "$(style_bold 1 "$(format_cpu_milli "${worker_total_cpu_milli}") / $(format_memory_mib "${worker_total_memory_mib}") allocatable")"
  printf '  %b %b\n' "$(summary_label_cell 'Engines')" "$(style_bold 1 "$(managed_engine_display_list)")"
  printf '  %b %b\n' "$(summary_label_cell 'Backup')" "${backup_label}"

  if [ "${show_live_query_fallback_note}" = "true" ] && [ "${source}" != "live" ]; then
    printf '%s\n' "$(style_dim 1 '  Live node allocatable could not be queried; showing the resolved layout instead.')"
  fi
}

# Prints the human-readable topology summary used by the ready and status flows.
print_playground_topology_summary() {
  local summary_mode="${1:-live-preferred}"
  local topology_metrics=""
  local show_live_query_fallback_note="false"

  case "${summary_mode}" in
    live-preferred)
      if cluster_query_reachable; then
        topology_metrics="$(live_topology_metrics_tsv 2>/dev/null || true)"
      fi

      if [ -z "${topology_metrics}" ]; then
        topology_metrics="$(resolved_topology_metrics_tsv)"
        show_live_query_fallback_note="true"
      fi
      ;;
    resolved-only)
      topology_metrics="$(resolved_topology_metrics_tsv)"
      ;;
    *)
      printf '%s\n' "Unknown topology summary mode: ${summary_mode}" >&2
      return 1
      ;;
  esac

  print_playground_topology_summary_from_metrics_tsv "${topology_metrics}" "${show_live_query_fallback_note}"
}

# Prints a compact section heading for the user-facing access and topology summaries.
print_summary_section() {
  local title="$1"

  printf '\n%s\n' "$(style_title 1 "${title}")"
}

# Renders one muted summary label with stable padding before ANSI styling.
summary_label_cell() {
  local label="$1"
  local padded_label=""

  padded_label="$(printf "%-${SUMMARY_LABEL_WIDTH}s" "${label}")"
  style_label 1 "${padded_label}"
}

# Prints one aligned summary row with a muted label and emphasized value.
print_summary_field() {
  local label="$1"
  local value="$2"

  printf '  %b %b\n' "$(summary_label_cell "${label}")" "${value}"
}

# Prints one aligned summary field whose value spans multiple lines.
print_summary_multiline_field() {
  local label="$1"
  local value="$2"
  local line=""

  printf '  %b\n' "$(summary_label_cell "${label}")"
  while IFS= read -r line || [ -n "${line}" ]; do
    if [ -n "${line}" ]; then
      printf '    %s\n' "${line}"
    else
      printf '\n'
    fi
  done <<<"${value}"
}

# Prints a titled table-like block and dims the header row.
print_summary_table() {
  local title="$1"
  local table="$2"
  local line=""
  local is_header="true"

  print_summary_section "${title}"
  while IFS= read -r line || [ -n "${line}" ]; do
    if [ -z "${line}" ]; then
      printf '\n'
      continue
    fi

    if [ "${is_header}" = "true" ]; then
      printf '  %b\n' "$(style_label 1 "${line}")"
      is_header="false"
    else
      printf '  %s\n' "${line}"
    fi
  done <<<"${table}"
}

# Prints the stable access details for the current playground configuration.
print_playground_access_summary() {
  load_env

  print_summary_section "Access"
  print_summary_field "UI URL" "$(style_action 1 "${EVEREST_UI_URL}")"
  print_summary_field "Username" "$(style_bold 1 'admin')"
  print_summary_field "Password" "$(style_bold 1 "${EVEREST_ADMIN_PASSWORD}")"

  printf '\n'
}
