#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies fresh cluster creation tolerates delayed node registration and worker
# label propagation before enforcing the final topology check.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

# Creates isolated stub state for each fresh-cluster creation test case.
setup() {
  CREATE_STUB_BIN="$(mktemp -d)"
  CREATE_STATE_FILE="${BATS_TEST_TMPDIR}/create-state"
  : >"${CREATE_STATE_FILE}"
}

# Removes the temporary files created for each fresh-cluster creation test case.
teardown() {
  rm -rf "${CREATE_STUB_BIN}"
  rm -f "${CREATE_STATE_FILE}" "${CREATE_STATE_FILE}.json-count" "${CREATE_STATE_FILE}.node-create-lock"
}

# Writes one executable command stub into the per-test bin directory.
write_stub() {
  local name="$1"
  local body="$2"

  cat >"${CREATE_STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${CREATE_STUB_BIN}/${name}"
}

@test "ensure waits for planned worker nodes and labels to settle on a fresh create" {
  write_stub "k3d" '
state_file="'"${CREATE_STATE_FILE}"'"

if [ "${1:-}" = "cluster" ] && [ "${2:-}" = "list" ]; then
  printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
  if grep -q "^cluster_created$" "${state_file}"; then
    printf "%s\n" "openeverest-playground 1 2 true"
  fi
  exit 0
fi

if [ "${1:-}" = "cluster" ] && [ "${2:-}" = "create" ]; then
  printf "%s\n" "cluster_created" >>"${state_file}"
  exit 0
fi

if [ "${1:-}" = "node" ] && [ "${2:-}" = "create" ]; then
  printf "%s\n" "${3:-unknown}" >>"${state_file}"
  exit 0
fi

if [ "${1:-}" = "kubeconfig" ] && [ "${2:-}" = "merge" ]; then
  printf "%s\n" "kubeconfig_merged" >>"${state_file}"
  exit 0
fi

exit 1
'

  write_stub "kubectl" '
state_file="'"${CREATE_STATE_FILE}"'"
json_count_file="${state_file}.json-count"
joined=" $* "
json_probe_count=0

if [ -f "${json_count_file}" ]; then
  json_probe_count="$(cat "${json_count_file}")"
fi

if [[ "${joined}" == *" get nodes -o json "* ]]; then
  if ! grep -q "^cluster_created$" "${state_file}"; then
    exit 1
  fi

  json_probe_count=$((json_probe_count + 1))
  printf "%s\n" "${json_probe_count}" >"${json_count_file}"

  case "${json_probe_count}" in
    1|2)
      cat <<'"'"'JSON'"'"'
{"items":[{"metadata":{"name":"k3d-openeverest-playground-server-0","labels":{"node-role.kubernetes.io/control-plane":"true"}}},{"metadata":{"name":"k3d-openeverest-playground-agent-0-0","labels":{"playground.openeverest.io/worker-class":"small"}}}]}
JSON
      ;;
    3|4)
      cat <<'"'"'JSON'"'"'
{"items":[{"metadata":{"name":"k3d-openeverest-playground-server-0","labels":{"node-role.kubernetes.io/control-plane":"true"}}},{"metadata":{"name":"k3d-openeverest-playground-agent-0-0","labels":{"playground.openeverest.io/worker-class":"small"}}},{"metadata":{"name":"k3d-openeverest-playground-agent-1-0","labels":{}}}]}
JSON
      ;;
    *)
      cat <<'"'"'JSON'"'"'
{"items":[{"metadata":{"name":"k3d-openeverest-playground-server-0","labels":{"node-role.kubernetes.io/control-plane":"true"}}},{"metadata":{"name":"k3d-openeverest-playground-agent-0-0","labels":{"playground.openeverest.io/worker-class":"small"}}},{"metadata":{"name":"k3d-openeverest-playground-agent-1-0","labels":{"playground.openeverest.io/worker-class":"small"}}}]}
JSON
      ;;
  esac
  exit 0
fi

if [[ "${joined}" == *" get nodes "* ]]; then
  if grep -q "^cluster_created$" "${state_file}"; then
    exit 0
  fi
  exit 1
fi

if [[ "${joined}" == *" wait --for=condition=Ready node --all "* ]]; then
  exit 0
fi

exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_NO_SPINNER=true \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="8" \
    ENABLE_BACKUP="true" \
    CLUSTER_NAME="openeverest-playground" \
    KUBE_CONTEXT="k3d-openeverest-playground" \
    PATH="${CREATE_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/cluster/ensure-cluster.sh ensure
    '

  [ "${status}" -eq 0 ]
  grep -Fxq "kubeconfig_merged" "${CREATE_STATE_FILE}"
  [[ "${output}" == *"Waiting for all planned Kubernetes nodes to register."* ]]
  [[ "${output}" == *"Waiting for planned node labels to settle."* ]]
  [ -f "${CREATE_STATE_FILE}.json-count" ]
  [ "$(cat "${CREATE_STATE_FILE}.json-count")" -ge 5 ]
  [[ "${output}" != *"exists with a different node layout"* ]]
}

@test "ensure creates planned worker nodes serially" {
  write_stub "k3d" '
state_file="'"${CREATE_STATE_FILE}"'"
lock_file="${state_file}.node-create-lock"

if [ "${1:-}" = "cluster" ] && [ "${2:-}" = "list" ]; then
  printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
  if grep -q "^cluster_created$" "${state_file}"; then
    printf "%s\n" "openeverest-playground 1 2 true"
  fi
  exit 0
fi

if [ "${1:-}" = "cluster" ] && [ "${2:-}" = "create" ]; then
  printf "%s\n" "cluster_created" >>"${state_file}"
  exit 0
fi

if [ "${1:-}" = "node" ] && [ "${2:-}" = "create" ]; then
  if [ -f "${lock_file}" ]; then
    printf "%s\n" "concurrent_node_create" >>"${state_file}"
    exit 1
  fi

  : >"${lock_file}"
  sleep 1
  rm -f "${lock_file}"
  printf "%s\n" "${3:-unknown}" >>"${state_file}"
  exit 0
fi

if [ "${1:-}" = "kubeconfig" ] && [ "${2:-}" = "merge" ]; then
  printf "%s\n" "kubeconfig_merged" >>"${state_file}"
  exit 0
fi

exit 1
'

  write_stub "kubectl" '
joined=" $* "

if [[ "${joined}" == *" get nodes -o json "* ]]; then
  cat <<'"'"'JSON'"'"'
{"items":[{"metadata":{"name":"k3d-openeverest-playground-server-0","labels":{"node-role.kubernetes.io/control-plane":"true"}}},{"metadata":{"name":"k3d-openeverest-playground-agent-0-0","labels":{"playground.openeverest.io/worker-class":"small"}}},{"metadata":{"name":"k3d-openeverest-playground-agent-1-0","labels":{"playground.openeverest.io/worker-class":"small"}}}]}
JSON
  exit 0
fi

if [[ "${joined}" == *" get nodes "* ]] || [[ "${joined}" == *" wait --for=condition=Ready node --all "* ]]; then
  exit 0
fi

exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="8" \
    ENABLE_BACKUP="true" \
    CLUSTER_NAME="openeverest-playground" \
    KUBE_CONTEXT="k3d-openeverest-playground" \
    PATH="${CREATE_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/cluster/ensure-cluster.sh ensure
    '

  [ "${status}" -eq 0 ]
  grep -Fxq "kubeconfig_merged" "${CREATE_STATE_FILE}"
  [[ "${output}" != *"Unable to create the planned DB worker nodes"* ]]
  [[ "${output}" != *"concurrent_node_create"* ]]
}
