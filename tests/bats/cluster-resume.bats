#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies resume behavior for stopped k3d playground clusters.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

# Creates isolated stub state for each resume test case.
setup() {
  RESUME_STUB_BIN="$(mktemp -d)"
  RESUME_STATE_FILE="${BATS_TEST_TMPDIR}/resume-state"
  : >"${RESUME_STATE_FILE}"
}

# Removes the temporary files created for each resume test case.
teardown() {
  rm -rf "${RESUME_STUB_BIN}"
  rm -f "${RESUME_STATE_FILE}"
}

# Writes one executable command stub into the per-test bin directory.
write_stub() {
  local name="$1"
  local body="$2"

  cat >"${RESUME_STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${RESUME_STUB_BIN}/${name}"
}

@test "resume starts a stopped cluster before enforcing the topology match" {
  write_stub "k3d" '
state_file="'"${RESUME_STATE_FILE}"'"

if [ "${1:-}" = "cluster" ] && [ "${2:-}" = "list" ]; then
  printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
  printf "%s\n" "openeverest-playground 1 1 true"
  exit 0
fi

if [ "${1:-}" = "cluster" ] && [ "${2:-}" = "start" ]; then
  printf "%s\n" "started" >"${state_file}"
  exit 0
fi

if [ "${1:-}" = "node" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "-o" ] && [ "${4:-}" = "json" ]; then
  if grep -q "^started$" "${state_file}"; then
    cat <<'"'"'JSON'"'"'
[{"name":"k3d-openeverest-playground-server-0","role":"server","runtimeLabels":{"k3d.cluster":"openeverest-playground","playground.worker-class":""}},{"name":"k3d-openeverest-playground-agent-0-0","role":"agent","runtimeLabels":{"k3d.cluster":"openeverest-playground","playground.worker-class":"small"}}]
JSON
  else
    printf "%s\n" "[]"
  fi
  exit 0
fi

if [ "${1:-}" = "kubeconfig" ] && [ "${2:-}" = "merge" ]; then
  printf "%s\n" "kubeconfig_merged" >>"${state_file}"
  exit 0
fi

exit 1
'

  write_stub "kubectl" '
state_file="'"${RESUME_STATE_FILE}"'"
joined=" $* "

if [[ "${joined}" == *" get nodes -o json "* ]]; then
  if grep -q "^started$" "${state_file}"; then
    cat <<'"'"'JSON'"'"'
{"items":[{"metadata":{"name":"k3d-openeverest-playground-server-0","labels":{"node-role.kubernetes.io/control-plane":"true"}},"spec":{"taints":[{"effect":"NoSchedule"}]}},{"metadata":{"name":"k3d-openeverest-playground-agent-0-0","labels":{"playground.openeverest.io/worker-class":"small"}},"spec":{"taints":[]}}]}
JSON
    exit 0
  fi
  exit 1
fi

if [[ "${joined}" == *" get nodes "* ]] || [[ "${joined}" == *" wait --for=condition=Ready node --all "* ]]; then
  if grep -q "^started$" "${state_file}"; then
    exit 0
  fi
  exit 1
fi

exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="2" \
    PLAYGROUND_CI_SMOKE="true" \
    CLUSTER_NAME="openeverest-playground" \
    KUBE_CONTEXT="k3d-openeverest-playground" \
    PATH="${RESUME_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/cluster/ensure-cluster.sh resume
    '

  [ "${status}" -eq 0 ]
  grep -Fxq "kubeconfig_merged" "${RESUME_STATE_FILE}"
  [[ "${output}" == *"Starting k3d cluster openeverest-playground."* ]]
  [[ "${output}" != *"exists with a different node layout"* ]]
}

@test "resume accepts a restarted cluster when worker runtime labels are missing from k3d output" {
  write_stub "k3d" '
state_file="'"${RESUME_STATE_FILE}"'"

if [ "${1:-}" = "cluster" ] && [ "${2:-}" = "list" ]; then
  printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
  printf "%s\n" "openeverest-playground 1 1 true"
  exit 0
fi

if [ "${1:-}" = "cluster" ] && [ "${2:-}" = "start" ]; then
  printf "%s\n" "started" >"${state_file}"
  exit 0
fi

if [ "${1:-}" = "node" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "-o" ] && [ "${4:-}" = "json" ]; then
  if grep -q "^started$" "${state_file}"; then
    cat <<'"'"'JSON'"'"'
[{"name":"k3d-openeverest-playground-server-0","role":"server","runtimeLabels":{"k3d.cluster":"openeverest-playground"}},{"name":"k3d-openeverest-playground-agent-0-0","role":"agent","runtimeLabels":{"k3d.cluster":"openeverest-playground"}}]
JSON
  else
    printf "%s\n" "[]"
  fi
  exit 0
fi

if [ "${1:-}" = "kubeconfig" ] && [ "${2:-}" = "merge" ]; then
  printf "%s\n" "kubeconfig_merged" >>"${state_file}"
  exit 0
fi

exit 1
'

  write_stub "kubectl" '
state_file="'"${RESUME_STATE_FILE}"'"
joined=" $* "

if [[ "${joined}" == *" get nodes -o json "* ]]; then
  if grep -q "^started$" "${state_file}"; then
    cat <<'"'"'JSON'"'"'
{"items":[{"metadata":{"name":"k3d-openeverest-playground-server-0","labels":{"node-role.kubernetes.io/control-plane":"true"}},"spec":{"taints":[{"effect":"NoSchedule"}]}},{"metadata":{"name":"k3d-openeverest-playground-agent-0-0","labels":{"playground.openeverest.io/worker-class":"small"}},"spec":{"taints":[]}}]}
JSON
    exit 0
  fi
  exit 1
fi

if [[ "${joined}" == *" get nodes "* ]] || [[ "${joined}" == *" wait --for=condition=Ready node --all "* ]]; then
  if grep -q "^started$" "${state_file}"; then
    exit 0
  fi
  exit 1
fi

exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="2" \
    PLAYGROUND_CI_SMOKE="true" \
    CLUSTER_NAME="openeverest-playground" \
    KUBE_CONTEXT="k3d-openeverest-playground" \
    PATH="${RESUME_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/cluster/ensure-cluster.sh resume
    '

  [ "${status}" -eq 0 ]
  grep -Fxq "kubeconfig_merged" "${RESUME_STATE_FILE}"
  [[ "${output}" == *"Starting k3d cluster openeverest-playground."* ]]
  [[ "${output}" != *"exists with a different node layout"* ]]
}
