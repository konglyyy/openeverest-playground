#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies the status command output across not-created, stopped, and running
# playground states.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

# Creates a temporary bin directory for command stubs used by each test.
setup() {
  STATUS_STUB_BIN="$(mktemp -d)"
}

# Removes the temporary bin directory created for each test.
teardown() {
  rm -rf "${STATUS_STUB_BIN}"
}

# Writes one executable command stub into the temporary bin directory.
write_stub() {
  local name="$1"
  local body="$2"

  cat >"${STATUS_STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${STATUS_STUB_BIN}/${name}"
}

@test "status omits access details before the playground exists" {
  write_stub "k3d" '
printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
'
  write_stub "kubectl" '
exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PATH="${STATUS_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/ops/status.sh
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'\nOpenEverest playground status\n'* ]]
  [[ "${output}" == *"Status               not created"* ]]
  [[ "${output}" != *$'\nAccess\n'* ]]
}

@test "status prints access details when the cluster exists but is stopped" {
  write_stub "k3d" '
printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
printf "%s\n" "openeverest-playground 1 1 true"
'
  write_stub "kubectl" '
exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PATH="${STATUS_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/ops/status.sh
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Status               stopped or unreachable"* ]]
  [[ "${output}" == *$'\nAccess\n'* ]]
}

@test "status prints access details alongside the running cluster summary" {
  local node_json_probe_count_file="${BATS_TEST_TMPDIR}/status-node-json-count.txt"

  write_stub "k3d" '
printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
printf "%s\n" "openeverest-playground 1 1 true"
'
  write_stub "kubectl" '
joined=" $* "

if [[ "${joined}" == *" get nodes -o json "* ]]; then
  count=0
  if [ -f "'"${node_json_probe_count_file}"'" ]; then
    count="$(cat "'"${node_json_probe_count_file}"'")"
  fi
  count=$((count + 1))
  printf "%s" "${count}" >"'"${node_json_probe_count_file}"'"
  cat <<'"'"'JSON'"'"'
{"items":[{"metadata":{"name":"openeverest-playground-server-0","labels":{"node-role.kubernetes.io/control-plane":"true"}},"spec":{"taints":[{"effect":"NoSchedule"}]},"status":{"allocatable":{"cpu":"1250m","memory":"1792Mi"}}},{"metadata":{"name":"openeverest-playground-agent-0","labels":{"playground.openeverest.io/worker-class":"small"}},"spec":{"taints":[]},"status":{"allocatable":{"cpu":"2750m","memory":"2816Mi"}}}]}
JSON
  exit 0
fi

if [[ "${joined}" == *" get nodes -o wide "* ]]; then
  printf "%s\n" "NAME STATUS ROLES AGE VERSION INTERNAL-IP EXTERNAL-IP OS-IMAGE KERNEL-VERSION CONTAINER-RUNTIME"
  printf "%s\n" "k3d-openeverest-playground-server-0 Ready control-plane 1d v1.30.0 172.18.0.2 <none> Alpine 6.6 containerd://1.7"
  exit 0
fi

if [[ "${joined}" == *" get nodes "* ]]; then
  printf "%s\n" "NAME STATUS ROLES AGE VERSION"
  printf "%s\n" "k3d-openeverest-playground-server-0 Ready control-plane 1d v1.30.0"
  exit 0
fi

if [[ "${joined}" == *" get namespace "* ]]; then
  printf "%s\n" "kube-system Active 1d"
  printf "%s\n" "everest-system Active 1d"
  printf "%s\n" "everest-olm Active 1d"
  printf "%s\n" "everest-monitoring Active 1d"
  printf "%s\n" "everest-databases Active 1d"
  exit 0
fi

if [[ "${joined}" == *" -n everest-databases get dbengine --no-headers "* ]]; then
  printf "%s\n" "postgresql Available 1d"
  printf "%s\n" "pxc Available 1d"
  printf "%s\n" "psmdb Available 1d"
  exit 0
fi

exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="6" \
    PATH="${STATUS_STUB_BIN}:${PATH}" \
    ENABLE_BACKUP="false" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/ops/status.sh
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Context              k3d-openeverest-playground"* ]]
  [[ "${output}" == *$'\nTopology\n'* ]]
  [[ "${output}" == *$'\nNodes\n'* ]]
  [[ "${output}" == *$'\nNamespaces\n'* ]]
  [[ "${output}" == *$'\nDBaaS\n'* ]]
  [[ "${output}" == *"Expected engines     PostgreSQL, MySQL/PXC, MongoDB"* ]]
  [[ "${output}" == *$'\nAccess\n'* ]]
  [ "$(cat "${node_json_probe_count_file}")" = "1" ]
}
