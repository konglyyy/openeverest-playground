#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies the doctor command renders the expected summary and failure modes.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

# Creates a temporary bin directory for command stubs used by each test.
setup() {
  DOCTOR_STUB_BIN="$(mktemp -d)"
}

# Removes the temporary bin directory created for each test.
teardown() {
  rm -rf "${DOCTOR_STUB_BIN}"
}

# Writes one executable command stub into the temporary bin directory.
write_stub() {
  local name="$1"
  local body="$2"

  cat >"${DOCTOR_STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${DOCTOR_STUB_BIN}/${name}"
}

@test "doctor prints a styled summary in resume mode" {
  write_stub "docker" 'exit 0'
  write_stub "k3d" 'exit 0'
  write_stub "kubectl" 'exit 0'
  write_stub "jq" 'cat >/dev/null; printf "%s\n" "[]"'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="6" \
    PATH="${DOCTOR_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/doctor/check-deps.sh resume
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'\nOpenEverest playground doctor\n'* ]]
  [[ "${output}" == *"Mode                 resume"* ]]
  [[ "${output}" == *"Resolved layout      1 server + 1 worker node(s) [small]"* ]]
  [[ "${output}" == *"Backup               disabled"* ]]
}

@test "task doctor uses local mode without touching Helm repo checks" {
  local helm_log="${DOCTOR_STUB_BIN}/helm.log"

  write_stub "docker" 'exit 0'
  write_stub "k3d" 'exit 0'
  write_stub "kubectl" 'exit 0'
  write_stub "jq" 'cat >/dev/null; printf "%s\n" "[]"'
  write_stub "helm" "
printf '%s\n' \"\$*\" >>\"${helm_log}\"
exit 99
"

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="6" \
    PATH="${DOCTOR_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      task doctor
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Mode                 local"* ]]
  [[ "${output}" == *"Helm repo            skipped in local mode"* ]]
  [ ! -s "${helm_log}" ]
}

@test "doctor report can be silenced without affecting the checks" {
  write_stub "docker" 'exit 0'
  write_stub "k3d" 'exit 0'
  write_stub "kubectl" 'exit 0'
  write_stub "jq" 'cat >/dev/null; printf "%s\n" "[]"'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="6" \
    PATH="${DOCTOR_STUB_BIN}:${PATH}" \
    PLAYGROUND_DOCTOR_REPORT="false" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/doctor/check-deps.sh resume
    '

  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}
