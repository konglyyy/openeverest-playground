#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared sizing, topology, and Docker budget helpers.
# -----------------------------------------------------------------------------

# Returns the runtime cache file path used for the current run's Docker budget probe.
docker_runtime_cache_file() {
  runtime_cache_file "docker-runtime-info.env"
}

# Loads one Docker budget snapshot file into the current shell when it is valid.
load_docker_runtime_info_file() {
  local cache_file="$1"

  if [ ! -f "${cache_file}" ]; then
    return 1
  fi

  load_env_file_exports "${cache_file}"

  case "${PLAYGROUND_DOCKER_MEMORY_BYTES:-}" in
    '' | *[!0-9]*)
      return 1
      ;;
  esac

  case "${PLAYGROUND_DOCKER_CPU_COUNT:-}" in
    '' | *[!0-9]*)
      return 1
      ;;
  esac

  export PLAYGROUND_DOCKER_MEMORY_MIB="$((PLAYGROUND_DOCKER_MEMORY_BYTES / 1024 / 1024))"
  export PLAYGROUND_DOCKER_INFO_LOADED=1
}

# Loads a previously detected Docker budget from the optional per-run cache file.
load_cached_docker_runtime_info() {
  local cache_file=""

  if ! cache_file="$(docker_runtime_cache_file 2>/dev/null)"; then
    return 1
  fi

  load_docker_runtime_info_file "${cache_file}"
}

# Loads the Docker budget snapshot recorded in the persistent playground state.
load_recorded_docker_runtime_info() {
  load_env
  load_docker_runtime_info_file "${PLAYGROUND_DOCKER_RUNTIME_CACHE_FILE}"
}

# Persists the detected Docker budget into the optional per-run cache file.
write_docker_runtime_cache() {
  local cache_file=""

  if ! cache_file="$(docker_runtime_cache_file 2>/dev/null)"; then
    return 0
  fi

  ensure_runtime_cache_dir || return 0
  cat >"${cache_file}" <<EOF
PLAYGROUND_DOCKER_MEMORY_BYTES=${PLAYGROUND_DOCKER_MEMORY_BYTES}
PLAYGROUND_DOCKER_CPU_COUNT=${PLAYGROUND_DOCKER_CPU_COUNT}
EOF
}

# Persists the detected Docker budget into the persistent playground state.
write_recorded_docker_runtime_cache() {
  load_env
  ensure_playground_state_dir
  cat >"${PLAYGROUND_DOCKER_RUNTIME_CACHE_FILE}" <<EOF
PLAYGROUND_DOCKER_MEMORY_BYTES=${PLAYGROUND_DOCKER_MEMORY_BYTES}
PLAYGROUND_DOCKER_CPU_COUNT=${PLAYGROUND_DOCKER_CPU_COUNT}
EOF
}

# Captures the current Docker budget as `memory_bytes cpu_count` without exiting
# so callers can choose their own error handling.
probe_docker_runtime_info() {
  local docker_info=""
  local memory_bytes=""
  local cpu_count=""

  docker_info="$(docker info --format '{{.MemTotal}} {{.NCPU}}' 2>/dev/null || true)"
  memory_bytes="${docker_info%% *}"
  cpu_count="${docker_info##* }"

  if [[ ! ${memory_bytes} =~ ^[0-9]+$ || ! ${cpu_count} =~ ^[0-9]+$ ]]; then
    memory_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || true)"
    cpu_count="$(docker info --format '{{.NCPU}}' 2>/dev/null || true)"
  fi

  case "${memory_bytes}" in
    '' | *[!0-9]*)
      return 1
      ;;
  esac

  case "${cpu_count}" in
    '' | *[!0-9]*)
      return 1
      ;;
  esac

  printf '%s %s\n' "${memory_bytes}" "${cpu_count}"
}

# Exports one detected Docker budget into the current shell.
set_docker_runtime_info() {
  local memory_bytes="$1"
  local cpu_count="$2"

  export PLAYGROUND_DOCKER_MEMORY_BYTES="${memory_bytes}"
  export PLAYGROUND_DOCKER_MEMORY_MIB="$((memory_bytes / 1024 / 1024))"
  export PLAYGROUND_DOCKER_CPU_COUNT="${cpu_count}"
  export PLAYGROUND_DOCKER_INFO_LOADED=1
}

# Detects the Docker budget from the current shell, the optional per-run cache,
# or the persistent snapshot recorded during `task init`.
detect_docker_runtime_info() {
  load_env

  if [ -n "${PLAYGROUND_DOCKER_INFO_LOADED:-}" ]; then
    if [ -z "${PLAYGROUND_DOCKER_MEMORY_MIB:-}" ] && [ -n "${PLAYGROUND_DOCKER_MEMORY_BYTES:-}" ]; then
      export PLAYGROUND_DOCKER_MEMORY_MIB="$((PLAYGROUND_DOCKER_MEMORY_BYTES / 1024 / 1024))"
    fi
    return 0
  fi

  if load_cached_docker_runtime_info; then
    return 0
  fi

  if load_recorded_docker_runtime_info; then
    return 0
  fi

  return 1
}

# Probes Docker once and records that budget for later doctor/status/topology use.
refresh_docker_runtime_info_snapshot() {
  local docker_info=""
  local memory_bytes=""
  local cpu_count=""

  docker_info="$(probe_docker_runtime_info)" || return 1
  memory_bytes="${docker_info%% *}"
  cpu_count="${docker_info##* }"

  set_docker_runtime_info "${memory_bytes}" "${cpu_count}"
  write_docker_runtime_cache
  write_recorded_docker_runtime_cache
}

# Loads the Docker memory and CPU budget snapshot recorded for this playground.
load_docker_runtime_info() {
  if detect_docker_runtime_info; then
    return 0
  fi

  die "Docker budget is not recorded yet. Run 'task init' to capture it for this playground."
}

# Returns success when the Docker daemon answers a lightweight local probe.
docker_daemon_reachable() {
  docker info --format '{{.ServerVersion}}' >/dev/null 2>&1
}

# Returns the detected Docker memory budget in bytes.
docker_memory_bytes() {
  load_docker_runtime_info
  printf '%s\n' "${PLAYGROUND_DOCKER_MEMORY_BYTES}"
}

# Returns the detected Docker CPU budget as a whole-number CPU count.
docker_cpu_count() {
  load_docker_runtime_info
  printf '%s\n' "${PLAYGROUND_DOCKER_CPU_COUNT}"
}

# Lists other running Docker containers that are not part of this playground.
docker_other_running_containers() {
  load_env

  docker ps --format '{{.Names}}' 2>/dev/null | awk -v prefix="k3d-${CLUSTER_NAME}-" '
    index($0, prefix) != 1 && $0 != "" {
      print
    }
  '
}

# Converts one Docker memory usage token such as 512MiB into rounded MiB.
docker_memory_token_to_mib() {
  awk -v raw="$1" '
    function round(value) {
      return int(value + 0.5);
    }
    BEGIN {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw);
      if (raw == "") {
        print 0;
        exit;
      }

      if (match(raw, /^([0-9]+(\.[0-9]+)?)([A-Za-z]+)$/, parts) == 0) {
        print 0;
        exit;
      }

      value = parts[1] + 0;
      unit = parts[3];

      if (unit == "B") {
        print round(value / 1024 / 1024);
      } else if (unit == "KiB" || unit == "kB" || unit == "KB") {
        print round(value / 1024);
      } else if (unit == "MiB" || unit == "MB") {
        print round(value);
      } else if (unit == "GiB" || unit == "GB") {
        print round(value * 1024);
      } else if (unit == "TiB" || unit == "TB") {
        print round(value * 1024 * 1024);
      } else {
        print 0;
      }
    }
  '
}

# Returns the number of other running containers currently using Docker.
docker_other_running_container_count() {
  local count=0
  local container_name=""

  while IFS= read -r container_name; do
    [ -n "${container_name}" ] || continue
    count=$((count + 1))
  done < <(docker_other_running_containers)

  printf '%s\n' "${count}"
}

# Returns the approximate live memory usage of other running containers in Mi.
docker_other_running_container_memory_mib() {
  local containers=()
  local container_name=""
  local total_memory_mib=0
  local stats_output=""
  local stats_line=""
  local usage_token=""
  local usage_mib=0

  while IFS= read -r container_name; do
    [ -n "${container_name}" ] || continue
    containers+=("${container_name}")
  done < <(docker_other_running_containers)

  if [ "${#containers[@]}" -eq 0 ]; then
    printf '0\n'
    return 0
  fi

  stats_output="$(docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' "${containers[@]}" 2>/dev/null || true)"

  while IFS= read -r stats_line; do
    [ -n "${stats_line}" ] || continue
    usage_token="$(printf '%s\n' "${stats_line}" | awk -F'\t' '
      {
        usage = $2
        sub(/[[:space:]]*\/.*/, "", usage)
        print usage
      }
    ')"
    usage_mib="$(docker_memory_token_to_mib "${usage_token}")"
    total_memory_mib=$((total_memory_mib + usage_mib))
  done <<<"${stats_output}"

  printf '%s\n' "${total_memory_mib}"
}

# Returns a human-readable advisory when Docker is already busy with other work.
docker_contention_warning_message() {
  local container_count=0
  local total_memory_mib=0

  container_count="$(docker_other_running_container_count)"
  if [ "${container_count}" -eq 0 ]; then
    return 1
  fi

  total_memory_mib="$(docker_other_running_container_memory_mib)"

  if [ "${total_memory_mib}" -gt 0 ]; then
    printf '%s\n' "Docker currently has ${container_count} other running container(s) using about $(format_memory_mib "${total_memory_mib}"). The planner uses Docker's total exposed budget and does not subtract live usage. Stop them if you want this resolved layout to be more reliable."
  else
    printf '%s\n' "Docker currently has ${container_count} other running container(s). The planner uses Docker's total exposed budget and does not subtract live usage. Stop them if you want this resolved layout to be more reliable."
  fi
}

# Rounds a positive integer up to the nearest multiple.
round_up_to_multiple() {
  local value="$1"
  local multiple="$2"

  printf '%s\n' $((((value + multiple - 1) / multiple) * multiple))
}

# Applies the shared 10 percent CPU headroom and 250m rounding rule.
apply_planner_cpu_headroom_milli() {
  local base_cpu_milli="$1"

  printf '%s\n' "$(round_up_to_multiple $(((base_cpu_milli * 110 + 99) / 100)) 250)"
}

# Applies the shared 10 percent memory headroom and 256Mi rounding rule.
apply_planner_memory_headroom_mib() {
  local base_memory_mib="$1"

  printf '%s\n' "$(round_up_to_multiple $(((base_memory_mib * 110 + 99) / 100)) 256)"
}

# Returns the measured base CPU requirement for one engine/size pair.
engine_class_base_cpu_milli() {
  case "$1:$2" in
    postgresql:small) printf '2000\n' ;;
    postgresql:medium) printf '5000\n' ;;
    postgresql:large) printf '9000\n' ;;
    pxc:small) printf '2250\n' ;;
    pxc:medium) printf '4750\n' ;;
    pxc:large) printf '8500\n' ;;
    psmdb:small) printf '2500\n' ;;
    psmdb:medium) printf '5500\n' ;;
    psmdb:large) printf '9500\n' ;;
    *) return 1 ;;
  esac
}

# Returns the measured base memory requirement for one engine/size pair in Mi.
engine_class_base_memory_mib() {
  case "$1:$2" in
    postgresql:small) printf '2080\n' ;;
    postgresql:medium) printf '8224\n' ;;
    postgresql:large) printf '32799\n' ;;
    pxc:small) printf '2304\n' ;;
    pxc:medium) printf '7936\n' ;;
    pxc:large) printf '30720\n' ;;
    psmdb:small) printf '2560\n' ;;
    psmdb:medium) printf '8704\n' ;;
    psmdb:large) printf '34816\n' ;;
    *) return 1 ;;
  esac
}

# Returns the largest base CPU requirement for one worker class across engines.
worker_class_base_cpu_milli() {
  local worker_class="$1"
  local max_cpu_milli=0
  local candidate_cpu_milli=0
  local engine=""

  for engine in postgresql pxc psmdb; do
    candidate_cpu_milli="$(engine_class_base_cpu_milli "${engine}" "${worker_class}")"
    if [ "${candidate_cpu_milli}" -gt "${max_cpu_milli}" ]; then
      max_cpu_milli="${candidate_cpu_milli}"
    fi
  done

  printf '%s\n' "${max_cpu_milli}"
}

# Returns the largest base memory requirement for one worker class across engines.
worker_class_base_memory_mib() {
  local worker_class="$1"
  local max_memory_mib=0
  local candidate_memory_mib=0
  local engine=""

  for engine in postgresql pxc psmdb; do
    candidate_memory_mib="$(engine_class_base_memory_mib "${engine}" "${worker_class}")"
    if [ "${candidate_memory_mib}" -gt "${max_memory_mib}" ]; then
      max_memory_mib="${candidate_memory_mib}"
    fi
  done

  printf '%s\n' "${max_memory_mib}"
}

# Returns the planned allocatable CPU for one worker class in millicpu.
worker_class_cpu_milli() {
  apply_planner_cpu_headroom_milli "$(worker_class_base_cpu_milli "$1")"
}

# Returns the planned allocatable memory for one worker class in Mi.
worker_class_memory_mib() {
  apply_planner_memory_headroom_mib "$(worker_class_base_memory_mib "$1")"
}

# Returns the base control-plane reservation before add-ons.
control_plane_base_cpu_milli() {
  apply_planner_cpu_headroom_milli 1000
}

# Returns the base control-plane memory reservation in Mi before add-ons.
control_plane_base_memory_mib() {
  printf '1536\n'
}

# Returns one optional control-plane add-on CPU reservation in millicpu.
control_plane_addon_cpu_milli() {
  case "$1" in
    backup)
      apply_planner_cpu_headroom_milli 200
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns one optional control-plane add-on memory reservation in Mi.
control_plane_addon_memory_mib() {
  case "$1" in
    backup)
      printf '256\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns the total planned allocatable CPU reservation for the control plane.
control_plane_allocatable_cpu_milli() {
  local total_cpu_milli=0

  total_cpu_milli="$(control_plane_base_cpu_milli)"

  if backup_enabled; then
    total_cpu_milli=$((total_cpu_milli + $(control_plane_addon_cpu_milli backup)))
  fi

  printf '%s\n' "${total_cpu_milli}"
}

# Returns the total planned allocatable memory reservation for the control plane.
control_plane_allocatable_memory_mib() {
  local total_memory_mib=0

  total_memory_mib="$(control_plane_base_memory_mib)"

  if backup_enabled; then
    total_memory_mib=$((total_memory_mib + $(control_plane_addon_memory_mib backup)))
  fi

  printf '%s\n' "${total_memory_mib}"
}

# Converts allocatable memory into a Docker memory limit string with reserved headroom.
memory_limit_string_for_allocatable_mib() {
  local allocatable_memory_mib="$1"
  local node_limit_mib=0

  node_limit_mib="$(round_up_to_multiple $((allocatable_memory_mib + 512)) 256)"
  printf '%sm\n' "${node_limit_mib}"
}

# Keeps extra fixed headroom on the server container because the control-plane
# node also carries k3s system processes in addition to the scheduled pods.
server_memory_limit_string_for_allocatable_mib() {
  local allocatable_memory_mib="$1"
  local node_limit_mib=0

  node_limit_mib="$(round_up_to_multiple $((allocatable_memory_mib + 768)) 256)"
  printf '%sm\n' "${node_limit_mib}"
}

# Converts a Docker/Kubernetes memory quantity such as 3072m or 3072Mi into Mi.
memory_limit_mib() {
  case "$1" in
    *Mi)
      printf '%s\n' "${1%Mi}"
      ;;
    *Gi)
      printf '%s\n' $((${1%Gi} * 1024))
      ;;
    *m)
      printf '%s\n' "${1%m}"
      ;;
    *g)
      printf '%s\n' $((${1%g} * 1024))
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns the Docker memory limit used for the control-plane node container.
resolved_server_node_memory_limit() {
  server_memory_limit_string_for_allocatable_mib "$(control_plane_allocatable_memory_mib)"
}

# Returns the raw planner layout options in descending preference order.
planner_layout_options() {
  cat <<'EOF'
large,large,large
large,large,medium
large,medium,medium
medium,medium,medium
medium,medium,small
medium,small,small
small,small,small
large,large
large,medium
medium,medium
medium,small
small,small
large
medium
small
EOF
}

# Returns one worker layout's total CPU requirement in millicpu.
worker_layout_cpu_milli() {
  local layout_csv="$1"
  local total_cpu_milli=0
  local worker_class=""
  local old_ifs="${IFS}"

  IFS=','
  for worker_class in ${layout_csv}; do
    [ -n "${worker_class}" ] || continue
    total_cpu_milli=$((total_cpu_milli + $(worker_class_cpu_milli "${worker_class}")))
  done
  IFS="${old_ifs}"

  printf '%s\n' "${total_cpu_milli}"
}

# Returns one worker layout's total memory requirement in Mi.
worker_layout_memory_mib() {
  local layout_csv="$1"
  local total_memory_mib=0
  local worker_class=""
  local old_ifs="${IFS}"

  IFS=','
  for worker_class in ${layout_csv}; do
    [ -n "${worker_class}" ] || continue
    total_memory_mib=$((total_memory_mib + $(worker_class_memory_mib "${worker_class}")))
  done
  IFS="${old_ifs}"

  printf '%s\n' "${total_memory_mib}"
}

# Counts the worker nodes represented by one comma-delimited layout string.
worker_layout_count() {
  local layout_csv="$1"
  local worker_count=0
  local worker_class=""
  local old_ifs="${IFS}"

  IFS=','
  for worker_class in ${layout_csv}; do
    [ -n "${worker_class}" ] || continue
    worker_count=$((worker_count + 1))
  done
  IFS="${old_ifs}"

  printf '%s\n' "${worker_count}"
}

# Returns success when CI smoke mode should bypass budget-driven layout planning.
ci_smoke_mode_enabled() {
  load_env
  is_truthy "${PLAYGROUND_CI_SMOKE:-false}"
}

# Resolves and caches the worker layout derived from the current Docker budget.
load_resolved_worker_layout() {
  local total_cpu_milli=0
  local total_memory_mib=0
  local control_plane_cpu_milli=0
  local control_plane_memory_mib=0
  local remaining_cpu_milli=0
  local remaining_memory_mib=0
  local layout_csv=""
  local layout_cpu_milli=0
  local layout_memory_mib=0
  local layout_agent_count=0

  if [ -n "${PLAYGROUND_RESOLVED_WORKER_LAYOUT_CSV:-}" ] \
    && [ -n "${PLAYGROUND_RESOLVED_AGENT_COUNT:-}" ] \
    && [ -n "${PLAYGROUND_RESOLVED_TOTAL_WORKER_CPU_MILLI:-}" ] \
    && [ -n "${PLAYGROUND_RESOLVED_TOTAL_WORKER_MEMORY_MIB:-}" ]; then
    return 0
  fi

  if ci_smoke_mode_enabled; then
    layout_csv="small"
    layout_cpu_milli="$(worker_layout_cpu_milli "${layout_csv}")"
    layout_memory_mib="$(worker_layout_memory_mib "${layout_csv}")"
    layout_agent_count="$(worker_layout_count "${layout_csv}")" || return 1
    export PLAYGROUND_RESOLVED_WORKER_LAYOUT_CSV="${layout_csv}"
    export PLAYGROUND_RESOLVED_AGENT_COUNT="${layout_agent_count}"
    export PLAYGROUND_RESOLVED_TOTAL_WORKER_CPU_MILLI="${layout_cpu_milli}"
    export PLAYGROUND_RESOLVED_TOTAL_WORKER_MEMORY_MIB="${layout_memory_mib}"
    return 0
  fi

  total_cpu_milli=$(($(docker_cpu_count) * 1000))
  total_memory_mib=$(($(docker_memory_bytes) / 1024 / 1024))
  control_plane_cpu_milli="$(control_plane_allocatable_cpu_milli)"
  control_plane_memory_mib="$(control_plane_allocatable_memory_mib)"
  remaining_cpu_milli=$((total_cpu_milli - control_plane_cpu_milli))
  remaining_memory_mib=$((total_memory_mib - control_plane_memory_mib))

  while IFS= read -r layout_csv; do
    layout_cpu_milli="$(worker_layout_cpu_milli "${layout_csv}")"
    layout_memory_mib="$(worker_layout_memory_mib "${layout_csv}")"

    if [ "${layout_cpu_milli}" -le "${remaining_cpu_milli}" ] && [ "${layout_memory_mib}" -le "${remaining_memory_mib}" ]; then
      layout_agent_count="$(worker_layout_count "${layout_csv}")" || return 1
      export PLAYGROUND_RESOLVED_WORKER_LAYOUT_CSV="${layout_csv}"
      export PLAYGROUND_RESOLVED_AGENT_COUNT="${layout_agent_count}"
      export PLAYGROUND_RESOLVED_TOTAL_WORKER_CPU_MILLI="${layout_cpu_milli}"
      export PLAYGROUND_RESOLVED_TOTAL_WORKER_MEMORY_MIB="${layout_memory_mib}"
      return 0
    fi
  done < <(planner_layout_options)

  die "Detected Docker budget $(format_bytes_as_gib "$(docker_memory_bytes)") / $(docker_cpu_count) CPU cannot fit the control plane ($(format_cpu_milli "${control_plane_cpu_milli}") / $(format_memory_mib "${control_plane_memory_mib}")) plus one small worker ($(format_cpu_milli "$(worker_class_cpu_milli small)") / $(format_memory_mib "$(worker_class_memory_mib small)")). Increase Docker resources and retry."
}

# Returns the resolved worker layout as a comma-delimited class list.
resolved_worker_layout_csv() {
  load_resolved_worker_layout
  printf '%s\n' "${PLAYGROUND_RESOLVED_WORKER_LAYOUT_CSV}"
}

# Returns the number of control-plane nodes.
resolved_server_count() {
  printf '1\n'
}

# Returns the number of schedulable DB worker nodes.
resolved_agent_count() {
  load_resolved_worker_layout
  printf '%s\n' "${PLAYGROUND_RESOLVED_AGENT_COUNT}"
}

# Returns one resolved worker class by zero-based index.
resolved_worker_class_at() {
  local requested_index="$1"
  local layout_csv=""
  local current_index=0
  local worker_class=""
  local old_ifs="${IFS}"

  load_resolved_worker_layout
  layout_csv="${PLAYGROUND_RESOLVED_WORKER_LAYOUT_CSV}"
  IFS=','
  for worker_class in ${layout_csv}; do
    if [ "${current_index}" -eq "${requested_index}" ]; then
      printf '%s\n' "${worker_class}"
      IFS="${old_ifs}"
      return 0
    fi
    current_index=$((current_index + 1))
  done
  IFS="${old_ifs}"

  return 1
}

# Returns the Docker memory limit for one resolved worker node by index.
resolved_worker_node_memory_limit_at() {
  memory_limit_string_for_allocatable_mib "$(worker_class_memory_mib "$(resolved_worker_class_at "$1")")"
}

# Returns the total planned worker CPU pool in millicpu.
resolved_total_worker_cpu_milli() {
  load_resolved_worker_layout
  printf '%s\n' "${PLAYGROUND_RESOLVED_TOTAL_WORKER_CPU_MILLI}"
}

# Returns the total planned worker memory pool in Mi.
resolved_total_worker_memory_mib() {
  load_resolved_worker_layout
  printf '%s\n' "${PLAYGROUND_RESOLVED_TOTAL_WORKER_MEMORY_MIB}"
}

# Returns the server kubelet reservation string.
kubelet_system_reserved_value_for_server() {
  local target_cpu_milli=0
  local target_memory_mib=0
  local node_limit_mib=0
  local node_capacity_milli=0
  local reserved_cpu_milli=0
  local reserved_memory_mib=0

  load_docker_runtime_info
  target_cpu_milli="$(control_plane_allocatable_cpu_milli)"
  target_memory_mib="$(control_plane_allocatable_memory_mib)"
  node_capacity_milli=$((PLAYGROUND_DOCKER_CPU_COUNT * 1000))
  node_limit_mib="$(memory_limit_mib "$(resolved_server_node_memory_limit)")"

  reserved_cpu_milli=$((node_capacity_milli - target_cpu_milli))
  if [ "${reserved_cpu_milli}" -lt 250 ]; then
    reserved_cpu_milli=250
  fi

  reserved_memory_mib=$((node_limit_mib - target_memory_mib))
  if [ "${reserved_memory_mib}" -lt 256 ]; then
    reserved_memory_mib=256
  fi

  printf 'cpu=%sm,memory=%sMi\n' "${reserved_cpu_milli}" "${reserved_memory_mib}"
}

# Returns one worker-class kubelet reservation string.
kubelet_system_reserved_value_for_worker_class() {
  local worker_class="$1"
  local target_cpu_milli=0
  local target_memory_mib=0
  local node_limit_mib=0
  local node_capacity_milli=0
  local reserved_cpu_milli=0
  local reserved_memory_mib=0

  load_docker_runtime_info
  target_cpu_milli="$(worker_class_cpu_milli "${worker_class}")"
  target_memory_mib="$(worker_class_memory_mib "${worker_class}")"
  node_capacity_milli=$((PLAYGROUND_DOCKER_CPU_COUNT * 1000))
  node_limit_mib="$(memory_limit_mib "$(memory_limit_string_for_allocatable_mib "${target_memory_mib}")")"

  reserved_cpu_milli=$((node_capacity_milli - target_cpu_milli))
  if [ "${reserved_cpu_milli}" -lt 250 ]; then
    reserved_cpu_milli=250
  fi

  reserved_memory_mib=$((node_limit_mib - target_memory_mib))
  if [ "${reserved_memory_mib}" -lt 256 ]; then
    reserved_memory_mib=256
  fi

  printf 'cpu=%sm,memory=%sMi\n' "${reserved_cpu_milli}" "${reserved_memory_mib}"
}

# Returns the total worker pool CPU quota quantity for the shared DB namespace.
namespace_guardrail_cpu_quantity() {
  printf '%sm\n' "$(resolved_total_worker_cpu_milli)"
}

# Returns the total worker pool memory quota quantity for the shared DB namespace.
namespace_guardrail_memory_quantity() {
  local total_memory_mib=0

  total_memory_mib="$(resolved_total_worker_memory_mib)"
  if backup_enabled; then
    total_memory_mib=$((total_memory_mib + 256))
  fi

  printf '%sMi\n' "${total_memory_mib}"
}

# Returns the node taint applied to the control-plane node.
resolved_server_node_taint() {
  printf 'node-role.kubernetes.io/control-plane=true:NoSchedule\n'
}

# Lists the database engines intentionally enabled by the playground.
managed_database_engines() {
  printf 'postgresql\n'
  printf 'pxc\n'
  printf 'psmdb\n'
}

# Renders the comma-delimited engine keys installed in the playground.
resolved_engine_keys_csv() {
  local engines=()
  local engine=""
  local IFS=','

  while IFS= read -r engine; do
    engines+=("${engine}")
  done < <(managed_database_engines)

  printf '%s\n' "${engines[*]}"
}

# Formats a byte count into a compact GiB label.
format_bytes_as_gib() {
  awk -v bytes="$1" 'BEGIN { printf "%.1f GiB", bytes / 1024 / 1024 / 1024 }'
}

# Formats millicpu as a human-friendly CPU count.
format_cpu_milli() {
  awk -v cpu_milli="$1" '
    BEGIN {
      value = cpu_milli / 1000;
      if (value == int(value)) {
        printf "%d CPU", value;
      } else {
        printf "%.1f CPU", value;
      }
    }
  '
}

# Formats memory in Mi with a Gi-style display when appropriate.
format_memory_mib() {
  awk -v mib="$1" '
    BEGIN {
      if (mib >= 1024) {
        value = mib / 1024;
        if (value == int(value)) {
          printf "%dGi", value;
        } else {
          printf "%.1fGi", value;
        }
      } else {
        printf "%dMi", mib;
      }
    }
  '
}

# Returns a short worker-class code.
worker_class_code() {
  case "$1" in
    small) printf 'S' ;;
    medium) printf 'M' ;;
    large) printf 'L' ;;
    *) return 1 ;;
  esac
}

# Returns the resolved worker layout as a short code such as LLM.
resolved_worker_layout_code() {
  local layout_csv=""
  local worker_class=""
  local code=""
  local old_ifs="${IFS}"

  load_resolved_worker_layout
  layout_csv="${PLAYGROUND_RESOLVED_WORKER_LAYOUT_CSV}"
  IFS=','
  for worker_class in ${layout_csv}; do
    code="${code}$(worker_class_code "${worker_class}")"
  done
  IFS="${old_ifs}"

  printf '%s\n' "${code}"
}

# Returns the resolved worker layout as a human-readable list.
resolved_worker_layout_pretty() {
  load_resolved_worker_layout
  printf '%s\n' "${PLAYGROUND_RESOLVED_WORKER_LAYOUT_CSV//,/, }"
}

# Returns the resolved worker layout as a human-readable summary.
resolved_layout_display() {
  load_resolved_worker_layout
  printf '1 server + %s worker node(s) [%s]\n' "${PLAYGROUND_RESOLVED_AGENT_COUNT}" "${PLAYGROUND_RESOLVED_WORKER_LAYOUT_CSV//,/, }"
}

# Validates that the requested features fit the current Docker budget.
validate_playground_sizing() {
  resolved_worker_layout_csv >/dev/null
}
