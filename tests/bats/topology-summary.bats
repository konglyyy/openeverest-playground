#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies the topology summary helpers for both live-node data and resolved
# layout fallbacks.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

# Creates a kubectl stub that fails if a test accidentally probes live nodes.
make_failing_kubectl_stub() {
  local stub_bin="${BATS_TEST_TMPDIR}/topology-summary-stub-bin"

  mkdir -p "${stub_bin}"
  cat >"${stub_bin}/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "kubectl should not be called by the ready summary" >&2
exit 1
EOF
  chmod +x "${stub_bin}/kubectl"

  printf '%s\n' "${stub_bin}"
}

@test "live topology metrics parse control-plane and worker allocatable values" {
  playground_run '
    # Returns the fixture node list instead of querying a live cluster.
    function kubectl() { cat "${PLAYGROUND_TEST_FIXTURE_DIR}/nodes-minimal-live.json"; }
    live_topology_metrics_tsv
  '

  [ "${status}" -eq 0 ]
  [ "${output}" = $'1\ttrue\t500\t256\t1\t2500\t2560\tlive' ]
}

@test "init summary prints the topology block without probing live nodes" {
  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_STATE_DIR="${PLAYGROUND_TEST_ROOT}/.state/test-print-access" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT=6 \
    PATH="$(make_failing_kubectl_stub):${PATH}" \
    bash -lc '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/access/print-access.sh init
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'\nTopology\n'* ]]
  [[ "${output}" == *"Resolved layout      1 server + 1 worker node(s) [small]"* ]]
  [[ "${output}" == *"Backup               disabled"* ]]
  [[ "${output}" != *"Live node allocatable could not be queried"* ]]
}

@test "resume summary includes topology and access blocks without probing live nodes" {
  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_STATE_DIR="${PLAYGROUND_TEST_ROOT}/.state/test-print-access" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT=6 \
    PATH="$(make_failing_kubectl_stub):${PATH}" \
    bash -lc '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/access/print-access.sh resume
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'\nTopology\n'* ]]
  [[ "${output}" == *$'\nAccess\n'* ]]
  [[ "${output}" == *"UI URL               http://localhost:8080"* ]]
  [[ "${output}" != *"Live node allocatable could not be queried"* ]]
}

@test "resolved-only topology summary skips live probing and the fallback warning" {
  playground_run '
    export PLAYGROUND_DOCKER_INFO_LOADED=1
    export PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))"
    export PLAYGROUND_DOCKER_CPU_COUNT="6"
    # Fails the test if the resolved-only path still tries the live probe.
    function cluster_query_reachable() { printf "%s\n" "live probe should not run"; return 0; }
    # Fails the test if the resolved-only path still asks for live topology data.
    function live_topology_metrics_tsv() { printf "%s\n" "live metrics should not run"; return 0; }
    print_playground_topology_summary resolved-only
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Resolved layout"* ]]
  [[ "${output}" == *"Control plane        1 x server"* ]]
  [[ "${output}" == *"DB workers           1 x agent"* ]]
  [[ "${output}" != *"Live node allocatable could not be queried"* ]]
  [[ "${output}" != *"live probe should not run"* ]]
  [[ "${output}" != *"live metrics should not run"* ]]
}

@test "live-preferred topology summary falls back cleanly when the cluster is unreachable" {
  playground_run '
    export PLAYGROUND_DOCKER_INFO_LOADED=1
    export PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))"
    export PLAYGROUND_DOCKER_CPU_COUNT="6"
    # Forces the live-preferred path to exercise the resolved fallback branch.
    function cluster_query_reachable() { return 1; }
    print_playground_topology_summary
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Resolved layout"* ]]
  [[ "${output}" == *"Control plane        1 x server"* ]]
  [[ "${output}" == *"DB workers           1 x agent"* ]]
  [[ "${output}" == *"Live node allocatable could not be queried"* ]]
}
