#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Runs the minimal end-to-end k3d smoke test and verifies the expected
# lifecycle output and cluster shape.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/versions.env"

WORK_DIR="${ROOT_DIR}/.state/ci-workspace/smoke-minimal"
PLAYGROUND_STATE_DIR="${WORK_DIR}/state"
PLAYGROUND_ENV_FILE="${WORK_DIR}/playground.env"
ARTIFACT_DIR="${ROOT_DIR}/.ci-artifacts/smoke-minimal"
INIT_OUTPUT_FILE="${ARTIFACT_DIR}/init-output.txt"
STATUS_OUTPUT_FILE="${ARTIFACT_DIR}/status-output.txt"
DOWN_OUTPUT_FILE="${ARTIFACT_DIR}/down-output.txt"
UP_OUTPUT_FILE="${ARTIFACT_DIR}/up-output.txt"
RESET_OUTPUT_FILE="${ARTIFACT_DIR}/reset-output.txt"
export PLAYGROUND_STATE_DIR PLAYGROUND_ENV_FILE

# Runs one command, writes its combined output to a file, and replays it to stdout.
run_and_capture() {
  local output_file="$1"
  local exit_code=0
  shift

  if "$@" >"${output_file}" 2>&1; then
    cat "${output_file}"
    return 0
  fi

  exit_code=$?
  cat "${output_file}"
  return "${exit_code}"
}

# Rewrites or appends one KEY=value pair inside the smoke-test env file.
write_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local escaped_value=""
  local temp_file=""

  escaped_value="$(printf '%s' "${value}" | sed 's/[&/]/\\&/g')"
  temp_file="$(mktemp)"

  if grep -q "^${key}=" "${env_file}"; then
    sed "s/^${key}=.*/${key}=${escaped_value}/" "${env_file}" >"${temp_file}"
  else
    cat "${env_file}" >"${temp_file}"
    printf '%s=%s\n' "${key}" "${value}" >>"${temp_file}"
  fi

  mv "${temp_file}" "${env_file}"
}

# Fails the smoke test when a captured output file does not match a pattern.
assert_file_contains() {
  local file="$1"
  local pattern="$2"
  grep -Eq "${pattern}" "${file}" || {
    printf '%s\n' "Expected ${file} to match ${pattern}" >&2
    exit 1
  }
}

# Verifies the init output reports the resolved minimal topology.
assert_init_summary() {
  assert_file_contains "${INIT_OUTPUT_FILE}" '^Topology$'
  assert_file_contains "${INIT_OUTPUT_FILE}" 'Resolved layout[[:space:]]+1 server \+ 1 worker node\(s\) \[small\]'
  assert_file_contains "${INIT_OUTPUT_FILE}" 'DB workers[[:space:]]+1 x agent'
  assert_file_contains "${INIT_OUTPUT_FILE}" 'Engines[[:space:]]+PostgreSQL, MySQL/PXC, MongoDB'
  assert_file_contains "${INIT_OUTPUT_FILE}" 'Backup[[:space:]]+disabled'
}

# Verifies the resume output still reports the resolved minimal topology.
assert_up_summary() {
  if ! grep -Eq '^Topology$' "${UP_OUTPUT_FILE}"; then
    printf '%s\n' "task up should print the topology block." >&2
    exit 1
  fi

  assert_file_contains "${UP_OUTPUT_FILE}" 'Resolved layout[[:space:]]+1 server \+ 1 worker node\(s\) \[small\]'
  assert_file_contains "${UP_OUTPUT_FILE}" 'DB workers[[:space:]]+1 x agent'
}

# Verifies the smoke cluster contains one tainted control-plane node and one worker.
assert_cluster_shape() {
  local node_json=""

  node_json="$(kubectl --context "k3d-openeverest-playground-ci" get nodes -o json)"

  printf '%s' "${node_json}" | jq -e '
    (.items | length) == 2
    and ([.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == "true")] | length) == 1
    and ([.items[] | select((.metadata.labels["node-role.kubernetes.io/control-plane"] // "") != "true")] | length) == 1
    and (
      [.items[]
        | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == "true")
        | any(.spec.taints[]?; .effect == "NoSchedule")
      ] | all
    )
  ' >/dev/null
}

# Verifies the playground created only the shared DB namespace layout.
assert_namespace_shape() {
  kubectl --context "k3d-openeverest-playground-ci" get namespace everest-databases >/dev/null

  if kubectl --context "k3d-openeverest-playground-ci" get namespace postgresql-dbaas >/dev/null 2>&1; then
    printf '%s\n' "postgresql-dbaas should not exist in the shared DB namespace layout." >&2
    exit 1
  fi

  if kubectl --context "k3d-openeverest-playground-ci" get namespace mysql-dbaas >/dev/null 2>&1; then
    printf '%s\n' "mysql-dbaas should not exist in the shared DB namespace layout." >&2
    exit 1
  fi

  if kubectl --context "k3d-openeverest-playground-ci" get namespace mongodb-dbaas >/dev/null 2>&1; then
    printf '%s\n' "mongodb-dbaas should not exist in the shared DB namespace layout." >&2
    exit 1
  fi
}

# Verifies the Everest system pods reached Ready before the smoke test finishes.
assert_pods_ready() {
  kubectl --context "k3d-openeverest-playground-ci" -n everest-system get pods -o json | jq -e '
    [.items[]?
      | select(.metadata.deletionTimestamp == null)
      | select(.status.phase != "Succeeded" and .status.phase != "Failed")] as $pods
    | ($pods | length) > 0
    and all($pods[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  ' >/dev/null
}

mkdir -p "${WORK_DIR}" "${PLAYGROUND_STATE_DIR}" "${ARTIFACT_DIR}"
rm -rf "${WORK_DIR:?}/"* "${ARTIFACT_DIR:?}/"*
cp "${ROOT_DIR}/config/playground.env.example" "${PLAYGROUND_ENV_FILE}"

write_env_value "${PLAYGROUND_ENV_FILE}" "ENABLE_BACKUP" "false"
write_env_value "${PLAYGROUND_ENV_FILE}" "EVEREST_UI_PORT" "18080"
write_env_value "${PLAYGROUND_ENV_FILE}" "EVEREST_HELM_CHART_VERSION" "${EVEREST_HELM_CHART_VERSION}"
write_env_value "${PLAYGROUND_ENV_FILE}" "EVEREST_DB_NAMESPACE_CHART_VERSION" "${EVEREST_DB_NAMESPACE_CHART_VERSION}"

export CLUSTER_NAME="openeverest-playground-ci"
export NO_COLOR=1
export PLAYGROUND_VERBOSE="true"
export PLAYGROUND_NO_SPINNER=true
export PLAYGROUND_CI_SMOKE="true"

cd "${ROOT_DIR}"

run_and_capture "${INIT_OUTPUT_FILE}" task init:apply
assert_init_summary
assert_cluster_shape
assert_namespace_shape
assert_pods_ready

run_and_capture "${STATUS_OUTPUT_FILE}" task status
run_and_capture "${DOWN_OUTPUT_FILE}" task down
run_and_capture "${UP_OUTPUT_FILE}" task up
assert_up_summary
run_and_capture "${RESET_OUTPUT_FILE}" task reset

printf '%s\n' "Minimal smoke test passed."
