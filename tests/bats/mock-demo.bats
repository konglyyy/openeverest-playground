#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies the mock demo commands, local guards, and lightweight CGI UI.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

# Creates a temporary bin directory for command stubs used by each test.
setup() {
  MOCK_STUB_BIN="$(mktemp -d)"
}

# Removes the temporary bin directory created for each test.
teardown() {
  rm -rf "${MOCK_STUB_BIN}"
}

# Writes one executable command stub into the temporary bin directory.
write_stub() {
  local name="$1"
  local body="$2"

  cat >"${MOCK_STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${MOCK_STUB_BIN}/${name}"
}

@test "task mock:seed prompts for init first when no playground was applied yet" {
  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_STATE_DIR="${BATS_TEST_TMPDIR}/missing-state" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/ops/mock-seed.sh
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Playground is not initialized yet. Run 'task init' first."* ]]
}

@test "task mock:app prompts for init first when no playground was applied yet" {
  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_STATE_DIR="${BATS_TEST_TMPDIR}/missing-state" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/ops/mock-app.sh
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Playground is not initialized yet. Run 'task init' first."* ]]
}

@test "task mock:seed requires an interactive terminal after the playground is initialized" {
  write_stub "k3d" '
printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
printf "%s\n" "openeverest-playground 1 1 true"
'
  write_stub "kubectl" '
exit 0
'

  run env \
    NO_COLOR=1 \
    PATH="${MOCK_STUB_BIN}:${PATH}" \
    PLAYGROUND_ENV_FILE="${BATS_TEST_TMPDIR}/playground.env" \
    PLAYGROUND_STATE_DIR="${BATS_TEST_TMPDIR}/state" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="6" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      mkdir -p "${PLAYGROUND_STATE_DIR}/config"
      . ./scripts/common/lib.sh
      . ./scripts/config/policy.sh
      load_env
      write_effective_config_snapshot "${PLAYGROUND_STATE_DIR}/config/last-applied.env"
      ./scripts/ops/mock-seed.sh
    '

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Task mock:seed requires an interactive terminal."* ]]
}

@test "task mock:app requires an interactive terminal after the playground is initialized" {
  write_stub "k3d" '
printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
printf "%s\n" "openeverest-playground 1 1 true"
'
  write_stub "kubectl" '
exit 0
'

  run env \
    NO_COLOR=1 \
    PATH="${MOCK_STUB_BIN}:${PATH}" \
    PLAYGROUND_ENV_FILE="${BATS_TEST_TMPDIR}/playground.env" \
    PLAYGROUND_STATE_DIR="${BATS_TEST_TMPDIR}/state" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="6" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      mkdir -p "${PLAYGROUND_STATE_DIR}/config"
      . ./scripts/common/lib.sh
      . ./scripts/config/policy.sh
      load_env
      write_effective_config_snapshot "${PLAYGROUND_STATE_DIR}/config/last-applied.env"
      ./scripts/ops/mock-app.sh
    '

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Task mock:app requires an interactive terminal."* ]]
}

@test "task mock:app requires a running cluster after the playground is initialized" {
  write_stub "k3d" '
printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
printf "%s\n" "openeverest-playground 1 1 true"
'
  write_stub "kubectl" '
exit 1
'

  run env \
    NO_COLOR=1 \
    PATH="${MOCK_STUB_BIN}:${PATH}" \
    PLAYGROUND_ENV_FILE="${BATS_TEST_TMPDIR}/playground.env" \
    PLAYGROUND_STATE_DIR="${BATS_TEST_TMPDIR}/state" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="6" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      mkdir -p "${PLAYGROUND_STATE_DIR}/config"
      . ./scripts/common/lib.sh
      . ./scripts/config/policy.sh
      load_env
      write_effective_config_snapshot "${PLAYGROUND_STATE_DIR}/config/last-applied.env"
      ./scripts/ops/mock-app.sh
    '

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Cluster openeverest-playground is not running. Start it with 'task up' first."* ]]
}

@test "task mock helpers rewrite localhost connection strings for Dockerized clients" {
  playground_run '
    . "${PLAYGROUND_TEST_ROOT}/scripts/seed/runtime.sh"
    printf "conn=%s\n" "$(task_seed_prepare_client_connection_string "postgresql://demo:secret@localhost:5432/app")"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'conn=postgresql://demo:secret@host.docker.internal:5432/app'* ]]
}

@test "task mock:seed exits cleanly when demo data is already present" {
  write_stub "k3d" '
printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
printf "%s\n" "openeverest-playground 1 1 true"
'
  write_stub "kubectl" '
exit 0
'
  write_stub "docker" '
exit 0
'

  run env \
    NO_COLOR=1 \
    PATH="${MOCK_STUB_BIN}:${PATH}" \
    PLAYGROUND_ENV_FILE="${BATS_TEST_TMPDIR}/playground.env" \
    PLAYGROUND_STATE_DIR="${BATS_TEST_TMPDIR}/state" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="6" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      mkdir -p "${PLAYGROUND_STATE_DIR}/config"
      . ./scripts/common/lib.sh
      . ./scripts/config/policy.sh
      load_env
      write_effective_config_snapshot "${PLAYGROUND_STATE_DIR}/config/last-applied.env"
      . ./scripts/ops/mock-seed.sh
      # Forces the sourced mock seed flow down the interactive path for this test.
      interactive_prompt_available() { return 0; }
      # Supplies one stable demo connection string without prompting.
      prompt_nonempty_value() { printf "%s\n" "postgresql://demo:secret@localhost:5432/app"; }
      # Short-circuits DB access preparation without contacting a live cluster.
      task_seed_prepare_client_connection_string() { printf "%s\n" "postgresql://demo:secret@host.docker.internal:5432/app"; }
      # Simulates the already-seeded path without contacting a live database.
      task_seed_seed_demo_data() { printf "%s\n" "already-present"; }
      run_task_mock_seed
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Mock seed completed"* ]]
  [[ "${output}" == *"already present; existing demo rows or docs were left unchanged"* ]]
  [[ "${output}" == *"Next step"* ]]
  [[ "${output}" == *"Run task mock:app to try the mock UI."* ]]
}

@test "task mock:seed suggests running task mock:app manually after printing the seed summary" {
  write_stub "k3d" '
printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
printf "%s\n" "openeverest-playground 1 1 true"
'
  write_stub "kubectl" '
exit 0
'
  write_stub "docker" '
exit 0
'

  run env \
    NO_COLOR=1 \
    PATH="${MOCK_STUB_BIN}:${PATH}" \
    PLAYGROUND_ENV_FILE="${BATS_TEST_TMPDIR}/playground.env" \
    PLAYGROUND_STATE_DIR="${BATS_TEST_TMPDIR}/state" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="6" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      mkdir -p "${PLAYGROUND_STATE_DIR}/config"
      . ./scripts/common/lib.sh
      . ./scripts/config/policy.sh
      load_env
      write_effective_config_snapshot "${PLAYGROUND_STATE_DIR}/config/last-applied.env"
      . ./scripts/ops/mock-seed.sh
      # Forces the sourced mock seed flow down the interactive path for this test.
      interactive_prompt_available() { return 0; }
      # Supplies one stable demo connection string without prompting.
      prompt_nonempty_value() { printf "%s\n" "postgresql://demo:secret@localhost:5432/app"; }
      # Short-circuits DB access preparation without contacting a live cluster.
      task_seed_prepare_client_connection_string() { printf "%s\n" "postgresql://demo:secret@host.docker.internal:5432/app"; }
      # Simulates a fresh seed without contacting a live database.
      task_seed_seed_demo_data() { printf "%s\n" "seeded"; }
      run_task_mock_seed
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Mock seed completed"* ]]
  [[ "${output}" == *"Next step"* ]]
  [[ "${output}" == *"Run task mock:app to try the mock UI."* ]]
}

@test "task mock:app prints the running summary and browser fallback guidance" {
  write_stub "k3d" '
printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER"
printf "%s\n" "openeverest-playground 1 1 true"
'
  write_stub "kubectl" '
exit 0
'
  write_stub "docker" '
exit 0
'

  run env \
    NO_COLOR=1 \
    PATH="${MOCK_STUB_BIN}:${PATH}" \
    PLAYGROUND_ENV_FILE="${BATS_TEST_TMPDIR}/playground.env" \
    PLAYGROUND_STATE_DIR="${BATS_TEST_TMPDIR}/state" \
    PLAYGROUND_DOCKER_INFO_LOADED=1 \
    PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))" \
    PLAYGROUND_DOCKER_CPU_COUNT="6" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      mkdir -p "${PLAYGROUND_STATE_DIR}/config"
      . ./scripts/common/lib.sh
      . ./scripts/config/policy.sh
      load_env
      write_effective_config_snapshot "${PLAYGROUND_STATE_DIR}/config/last-applied.env"
      . ./scripts/ops/mock-app.sh
      # Forces the sourced mock app flow down the interactive path for this test.
      interactive_prompt_available() { return 0; }
      # Supplies one stable demo connection string without prompting.
      prompt_nonempty_value() { printf "%s\n" "postgresql://demo:secret@localhost:5432/app"; }
      # Short-circuits DB access preparation without contacting a live cluster.
      task_seed_prepare_client_connection_string() { printf "%s\n" "postgresql://demo:secret@host.docker.internal:5432/app"; }
      # Avoids launching a real browser in the test environment.
      open_task_seed_frontend() { return 1; }
      # Simulates a ready foreground frontend without starting a real server.
      start_task_seed_frontend() { return 0; }
      # Avoids waiting on a real long-lived process.
      wait_for_task_seed_frontend() { return 0; }
      run_task_mock_app
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Mock app running"* ]]
  [[ "${output}" == *"http://127.0.0.1:8789/cgi-bin/todos.sh"* ]]
  [[ "${output}" == *"Unable to open the browser automatically."* ]]
  [[ "${output}" == *"Press Ctrl-C to stop the mock app."* ]]
}

@test "task mock CGI renders a todo page when the database query succeeds" {
  write_stub "docker" '
printf "%s\t%s\t%s\n" "1" "Buy milk" "false"
printf "%s\t%s\t%s\n" "2" "Ship demo" "true"
'

  run env \
    NO_COLOR=1 \
    PATH="${MOCK_STUB_BIN}:${PATH}" \
    REQUEST_METHOD="GET" \
    PLAYGROUND_TASK_SEED_CONNECTION_STRING="postgresql://demo:secret@host.docker.internal:5432/app" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/seed/mock-frontend/cgi-bin/todos.sh
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Content-Type: text/html; charset=utf-8"* ]]
  [[ "${output}" == *"OpenEverest mock app"* ]]
  [[ "${output}" == *"Buy milk"* ]]
  [[ "${output}" == *"Ship demo"* ]]
}

@test "task mock CGI POST returns an HTML redirect shim instead of a blank page" {
  write_stub "docker" '
exit 0
'

  run env \
    NO_COLOR=1 \
    PATH="${MOCK_STUB_BIN}:${PATH}" \
    REQUEST_METHOD="POST" \
    CONTENT_LENGTH="24" \
    PLAYGROUND_TASK_SEED_CONNECTION_STRING="postgresql://demo:secret@host.docker.internal:5432/app" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      printf "action=create&title=Test" | ./scripts/seed/mock-frontend/cgi-bin/todos.sh
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Content-Type: text/html; charset=utf-8"* ]]
  [[ "${output}" == *"Returning to the todo view."* ]]
  [[ "${output}" == *"window.location.replace"* ]]
  [[ "${output}" == *"/cgi-bin/todos.sh"* ]]
}

@test "task mock CGI explains how to reload the app when the connection string is missing" {
  run env \
    NO_COLOR=1 \
    REQUEST_METHOD="GET" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/seed/mock-frontend/cgi-bin/todos.sh
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Rerun task mock:app."* ]]
}
