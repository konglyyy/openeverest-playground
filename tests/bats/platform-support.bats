#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies the platform-detection helpers and WSL-specific doctor guidance.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

# Creates a temporary bin directory for command stubs used by each test.
setup() {
  PLATFORM_STUB_BIN="$(mktemp -d)"
}

# Removes the temporary bin directory created for each test.
teardown() {
  rm -rf "${PLATFORM_STUB_BIN}"
}

# Writes one executable command stub into the temporary bin directory.
write_stub() {
  local name="$1"
  local body="$2"

  cat >"${PLATFORM_STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${PLATFORM_STUB_BIN}/${name}"
}

@test "WSL detection helper recognizes Microsoft kernel strings" {
  playground_run '
    export PLAYGROUND_PROC_VERSION_FILE="${PLAYGROUND_TEST_FIXTURE_DIR}/proc-version-wsl.txt"
    export PLAYGROUND_OSRELEASE_FILE="${PLAYGROUND_TEST_FIXTURE_DIR}/missing-osrelease.txt"
    if running_under_wsl; then
      printf "yes\n"
    else
      printf "no\n"
    fi
  '

  [ "${status}" -eq 0 ]
  [ "${output}" = "yes" ]
}

@test "Windows-mounted WSL paths are detected" {
  playground_run '
    if path_is_windows_mount "/mnt/c/Users/example/openeverest-playground"; then
      printf "yes\n"
    else
      printf "no\n"
    fi
  '

  [ "${status}" -eq 0 ]
  [ "${output}" = "yes" ]
}

@test "doctor prints a WSL-specific Docker integration hint" {
  write_stub "docker" '
if [ "${1:-}" = "info" ]; then
  exit 1
fi
exit 0
'
  write_stub "k3d" 'exit 0'
  write_stub "kubectl" 'exit 0'
  write_stub "jq" 'exit 0'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_PROC_VERSION_FILE="${PLAYGROUND_TEST_FIXTURE_DIR}/proc-version-wsl.txt" \
    PLAYGROUND_OSRELEASE_FILE="${PLAYGROUND_TEST_FIXTURE_DIR}/missing-osrelease.txt" \
    PATH="${PLATFORM_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/doctor/check-deps.sh resume
    '

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Docker daemon is not reachable from WSL."* ]]
  [[ "${output}" == *"enable WSL integration for this distro"* ]]
}
