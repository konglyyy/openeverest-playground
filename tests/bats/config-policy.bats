#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies the config policy tracks only supported settings and reports planner
# drift correctly.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

@test "config policy tracks only the public config keys plus derived values" {
  playground_run '
    config_policy_entries
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'ENABLE_BACKUP|Shared backup stack|in_place'* ]]
  [[ "${output}" == *$'EVEREST_UI_PORT|UI port|requires_reset'* ]]
  [[ "${output}" == *$'EVEREST_HELM_CHART_VERSION|Everest Helm chart version|requires_reset'* ]]
  [[ "${output}" == *$'EVEREST_DB_NAMESPACE_CHART_VERSION|DB namespace Helm chart version|requires_reset'* ]]
  [[ "${output}" != *$'EVEREST_NAMESPACE|'* ]]
  [[ "${output}" != *$'PLAYGROUND_VERBOSE|'* ]]
}

@test "effective config snapshots record the cluster name for resume checks" {
  playground_run '
    snapshot="$(mktemp)"
    export CLUSTER_NAME="openeverest-playground-ci"
    write_effective_config_snapshot "${snapshot}"
    grep "^CLUSTER_NAME=" "${snapshot}"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == "CLUSTER_NAME=openeverest-playground-ci" ]]
}

@test "derived topology drift is reported as reset-required" {
  playground_run '
    baseline="$(mktemp)"
    candidate="$(mktemp)"

    export PLAYGROUND_DOCKER_INFO_LOADED=1
    export PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))"
    export PLAYGROUND_DOCKER_CPU_COUNT="6"
    write_effective_config_snapshot "${baseline}"

    clear_runtime_resolution_cache
    export PLAYGROUND_ENV_LOADED=1
    export PLAYGROUND_DOCKER_INFO_LOADED=1
    export PLAYGROUND_DOCKER_MEMORY_BYTES="$((100 * 1024 * 1024 * 1024))"
    export PLAYGROUND_DOCKER_CPU_COUNT="30"
    write_effective_config_snapshot "${candidate}"

    emit_config_changes "${baseline}" "${candidate}"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'requires_reset|RESOLVED_WORKER_LAYOUT|Derived worker layout|small|large, large, medium'* ]]
  [[ "${output}" == *$'requires_reset|RESOLVED_WORKER_LAYOUT_CODE|Derived worker layout code|S|LLM'* ]]
}

@test "applied config match helper reports unchanged requested snapshots" {
  playground_run '
    candidate="$(mktemp)"
    ensure_config_state_dir
    write_effective_config_snapshot "${APPLIED_CONFIG_FILE}"
    write_effective_config_snapshot "${candidate}"
    applied_config_matches_snapshot "${candidate}"
  '

  [ "${status}" -eq 0 ]
}

@test "effective config snapshot fails cleanly when the planner cannot fit a cluster" {
  playground_run '
    # Overrides the detected Docker memory budget for this failure case.
    function docker_memory_bytes() { printf "%s\n" $((4 * 1024 * 1024 * 1024)); }
    # Overrides the detected Docker CPU budget for this failure case.
    function docker_cpu_count() { printf "%s\n" "3"; }
    validate_playground_sizing
  '

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cannot fit the control plane"* ]]
  [[ "${output}" != *"unbound variable"* ]]
}
