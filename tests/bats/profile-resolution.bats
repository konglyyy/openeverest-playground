#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies planner sizing, worker-class resolution, and backup-induced sizing
# changes.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

@test "planner fits one small worker at the minimum supported budget" {
  playground_run '
    # Overrides the detected Docker memory budget for this sizing scenario.
    function docker_memory_bytes() { printf "%s\n" $(( (2304 + 2816) * 1024 * 1024 )); }
    # Overrides the detected Docker CPU budget for this sizing scenario.
    function docker_cpu_count() { printf "%s\n" "4"; }
    printf "layout=%s\n" "$(resolved_worker_layout_csv)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'layout=small'* ]]
}

@test "planner prefers three large workers when the Docker budget fits them" {
  playground_run '
    # Overrides the detected Docker memory budget for this sizing scenario.
    function docker_memory_bytes() { printf "%s\n" $((150 * 1024 * 1024 * 1024)); }
    # Overrides the detected Docker CPU budget for this sizing scenario.
    function docker_cpu_count() { printf "%s\n" "40"; }
    printf "layout=%s\n" "$(resolved_worker_layout_csv)"
    printf "code=%s\n" "$(resolved_worker_layout_code)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'layout=large,large,large'* ]]
  [[ "${output}" == *$'code=LLL'* ]]
}

@test "planner falls back to large large medium when three large workers do not fit" {
  playground_run '
    # Overrides the detected Docker memory budget for this sizing scenario.
    function docker_memory_bytes() { printf "%s\n" $((100 * 1024 * 1024 * 1024)); }
    # Overrides the detected Docker CPU budget for this sizing scenario.
    function docker_cpu_count() { printf "%s\n" "30"; }
    printf "layout=%s\n" "$(resolved_worker_layout_csv)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'layout=large,large,medium'* ]]
}

@test "worker classes are derived from the largest engine footprint per band" {
  playground_run '
    printf "small=%s/%s\n" "$(worker_class_cpu_milli small)" "$(worker_class_memory_mib small)"
    printf "medium=%s/%s\n" "$(worker_class_cpu_milli medium)" "$(worker_class_memory_mib medium)"
    printf "large=%s/%s\n" "$(worker_class_cpu_milli large)" "$(worker_class_memory_mib large)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'small=2750/2816'* ]]
  [[ "${output}" == *$'medium=6250/9728'* ]]
  [[ "${output}" == *$'large=10500/38400'* ]]
}

@test "backup increases only the control-plane reservation" {
  playground_run '
    printf "base_cpu=%s\n" "$(control_plane_allocatable_cpu_milli)"
    printf "base_mem=%s\n" "$(control_plane_allocatable_memory_mib)"
    export ENABLE_BACKUP="true"
    printf "backup_cpu=%s\n" "$(control_plane_allocatable_cpu_milli)"
    printf "backup_mem=%s\n" "$(control_plane_allocatable_memory_mib)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'base_cpu=1250'* ]]
  [[ "${output}" == *$'base_mem=1536'* ]]
  [[ "${output}" == *$'backup_cpu=1500'* ]]
  [[ "${output}" == *$'backup_mem=1792'* ]]
}

@test "backup can still fit two small workers slightly under eight GiB" {
  playground_run '
    export ENABLE_BACKUP="true"
    # Overrides the detected Docker memory budget for this backup sizing case.
    function docker_memory_bytes() { printf "%s\n" $((7800 * 1024 * 1024)); }
    # Overrides the detected Docker CPU budget for this backup sizing case.
    function docker_cpu_count() { printf "%s\n" "8"; }
    printf "layout=%s\n" "$(resolved_worker_layout_csv)"
    printf "server_limit=%s\n" "$(resolved_server_node_memory_limit)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'layout=small,small'* ]]
  [[ "${output}" == *$'server_limit=2560m'* ]]
}

@test "shared namespace guardrails use the total planned worker pool" {
  playground_run '
    # Overrides the detected Docker memory budget for this guardrail scenario.
    function docker_memory_bytes() { printf "%s\n" $((100 * 1024 * 1024 * 1024)); }
    # Overrides the detected Docker CPU budget for this guardrail scenario.
    function docker_cpu_count() { printf "%s\n" "30"; }
    printf "quota_cpu=%s\n" "$(namespace_guardrail_cpu_quantity)"
    printf "quota_memory=%s\n" "$(namespace_guardrail_memory_quantity)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'quota_cpu=27250m'* ]]
  [[ "${output}" == *$'quota_memory=86528Mi'* ]]
}

@test "backup-enabled guardrails add backup job headroom" {
  playground_run '
    export ENABLE_BACKUP="true"
    # Overrides the detected Docker memory budget for this backup guardrail case.
    function docker_memory_bytes() { printf "%s\n" $((8 * 1024 * 1024 * 1024)); }
    # Overrides the detected Docker CPU budget for this backup guardrail case.
    function docker_cpu_count() { printf "%s\n" "6"; }
    printf "quota_memory=%s\n" "$(namespace_guardrail_memory_quantity)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'quota_memory=3072Mi'* ]]
}

@test "validation fails cleanly when the control plane plus one small worker do not fit" {
  playground_run '
    # Overrides the detected Docker memory budget for this validation failure.
    function docker_memory_bytes() { printf "%s\n" $((4 * 1024 * 1024 * 1024)); }
    # Overrides the detected Docker CPU budget for this validation failure.
    function docker_cpu_count() { printf "%s\n" "3"; }
    validate_playground_sizing
  '

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cannot fit the control plane"* ]]
}

@test "CI smoke mode pins a small worker layout even when the detected budget is smaller" {
  playground_run '
    export PLAYGROUND_CI_SMOKE="true"
    # Overrides the detected Docker memory budget for this smoke-mode case.
    function docker_memory_bytes() { printf "%s\n" $((8 * 1024 * 1024 * 1024)); }
    # Overrides the detected Docker CPU budget for this smoke-mode case.
    function docker_cpu_count() { printf "%s\n" "2"; }
    printf "layout=%s\n" "$(resolved_worker_layout_csv)"
    printf "workers=%s\n" "$(resolved_agent_count)"
    validate_playground_sizing
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'layout=small'* ]]
  [[ "${output}" == *$'workers=1'* ]]
}

@test "shared backup helpers still render the HTTPS endpoint form" {
  playground_run '
    printf "http_hostport=%s\n" "$(seaweedfs_http_endpoint_hostport)"
    printf "https_hostport=%s\n" "$(seaweedfs_endpoint_hostport)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'http_hostport=seaweedfs-s3.playground-system.svc.cluster.local:8333'* ]]
  [[ "${output}" == *$'https_hostport=seaweedfs-s3.playground-system.svc.cluster.local:8443'* ]]
}

@test "docker contention warning reports other running containers without counting playground nodes" {
  playground_run '
    # Stubs the Docker CLI so the contention helper sees only the test fixtures.
    function docker() {
      if [ "${1:-}" = "ps" ] && [ "${2:-}" = "--format" ]; then
        printf "%s\n" "k3d-openeverest-playground-server-0"
        printf "%s\n" "postgres-dev"
        printf "%s\n" "redis-dev"
        return 0
      fi

      if [ "${1:-}" = "stats" ] && [ "${2:-}" = "--no-stream" ]; then
        printf "%s\t%s\n" "postgres-dev" "256MiB / 8GiB"
        printf "%s\t%s\n" "redis-dev" "1GiB / 8GiB"
        return 0
      fi

      return 1
    }

    printf "%s\n" "$(docker_contention_warning_message)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"2 other running container(s)"* ]]
  [[ "${output}" == *"1.2Gi"* ]]
  [[ "${output}" != *"k3d-openeverest-playground-server-0"* ]]
}
