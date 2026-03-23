#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies dotenv loading and derived default handling for playground
# environment values.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

# Creates a temporary bin directory for command stubs used by the direct
# `init:apply` budget-snapshot regression checks.
setup() {
  ENV_STUB_BIN="$(mktemp -d)"
}

# Removes the temporary bin directory created for each test.
teardown() {
  rm -rf "${ENV_STUB_BIN}"
}

# Writes one executable command stub into the temporary bin directory.
write_stub() {
  local name="$1"
  local body="$2"

  cat >"${ENV_STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${ENV_STUB_BIN}/${name}"
}

@test "load_env keeps unquoted dotenv values with spaces literal" {
  local env_file
  env_file="$(mktemp)"

  cat >"${env_file}" <<'EOF'
BACKUP_BUCKET_PREFIX=OpenEverest Playground
EOF

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="${env_file}" \
    bash -lc '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      . ./scripts/common/lib.sh
      load_env
      printf "%s\n" "${BACKUP_BUCKET_PREFIX}"
    '

  rm -f "${env_file}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "OpenEverest Playground" ]
}

@test "load_env derives the shared backup storage default" {
  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    bash -lc '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      . ./scripts/common/lib.sh
      load_env
      printf "%s\n" "${BACKUP_STORAGE_NAME}"
    '

  [ "${status}" -eq 0 ]
  [ "${output}" = "seaweedfs-backup" ]
}

@test "load_env defaults to config/playground.env" {
  run env \
    NO_COLOR=1 \
    bash -lc '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"

      original_exists="false"
      backup_file=""

      if [ -f "./config/playground.env" ]; then
        original_exists="true"
        backup_file="$(mktemp)"
        cp "./config/playground.env" "${backup_file}"
      fi

      # Restores the original config file after this inline shell script exits.
      cleanup() {
        if [ "${original_exists}" = "true" ]; then
          mv "${backup_file}" "./config/playground.env"
        else
          rm -f "./config/playground.env"
        fi
      }
      trap cleanup EXIT

      printf "%s\n" "ENABLE_BACKUP=true" >"./config/playground.env"

      . ./scripts/common/lib.sh
      load_env
      printf "%s\n" "${PLAYGROUND_ENV_FILE}"
      printf "%s\n" "${ENABLE_BACKUP}"
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'/config/playground.env'* ]]
  [[ "${output}" == *$'\ntrue' ]]
}

@test "load_env ignores a repo-root .env even when config/playground.env is absent" {
  run env \
    NO_COLOR=1 \
    bash -lc '
      set -euo pipefail
      exec 2>&1
      cd "'"${PLAYGROUND_TEST_ROOT}"'"

      config_exists="false"
      config_backup=""
      root_backup=""
      root_env_exists="false"

      if [ -f "./config/playground.env" ]; then
        config_exists="true"
        config_backup="$(mktemp)"
        cp "./config/playground.env" "${config_backup}"
      fi

      if [ -f "./.env" ]; then
        root_env_exists="true"
        root_backup="$(mktemp)"
        cp "./.env" "${root_backup}"
      fi

      # Restores the local config and optional root .env after this inline shell script exits.
      cleanup() {
        if [ "${config_exists}" = "true" ]; then
          mv "${config_backup}" "./config/playground.env"
        else
          rm -f "./config/playground.env"
        fi
        if [ "${root_env_exists}" = "true" ]; then
          mv "${root_backup}" "./.env"
        else
          rm -f "./.env"
        fi
      }
      trap cleanup EXIT

      rm -f "./config/playground.env"
      cat >"./.env" <<'"'"'EOF'"'"'
ENABLE_BACKUP=true
EOF

      . ./scripts/common/lib.sh
      load_env
      printf "env_file=%s\n" "${PLAYGROUND_ENV_FILE}"
      printf "backup=%s\n" "${ENABLE_BACKUP}"
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Ignoring ${PLAYGROUND_TEST_ROOT}/.env"* ]]
  [[ "${output}" == *$'env_file='"${PLAYGROUND_TEST_ROOT}"$'/config/playground.env'* ]]
  [[ "${output}" == *$'\nbackup=false' ]]
}

@test "refresh_docker_runtime_info_snapshot writes a per-run cache that detect_docker_runtime_info reuses after in-process resets" {
  playground_run '
    export PLAYGROUND_RUNTIME_CACHE_DIR="${PLAYGROUND_STATE_DIR}/runtime-cache"
    unset PLAYGROUND_DOCKER_INFO_LOADED
    unset PLAYGROUND_DOCKER_MEMORY_BYTES
    unset PLAYGROUND_DOCKER_MEMORY_MIB
    unset PLAYGROUND_DOCKER_CPU_COUNT

    # Returns a fixed Docker budget so the init-style refresh writes the cache file.
    docker() {
      if [ "${1:-}" = "info" ] && [ "${2:-}" = "--format" ]; then
        printf "%s\n" "8589934592 6"
        return 0
      fi

      return 1
    }

    refresh_docker_runtime_info_snapshot
    printf "first=%s/%s\n" "${PLAYGROUND_DOCKER_MEMORY_BYTES}" "${PLAYGROUND_DOCKER_CPU_COUNT}"

    unset PLAYGROUND_DOCKER_INFO_LOADED
    unset PLAYGROUND_DOCKER_MEMORY_BYTES
    unset PLAYGROUND_DOCKER_MEMORY_MIB
    unset PLAYGROUND_DOCKER_CPU_COUNT

    # Simulates an unavailable Docker CLI so the second probe must hit the cache.
    docker() {
      return 1
    }

    detect_docker_runtime_info
    printf "second=%s/%s\n" "${PLAYGROUND_DOCKER_MEMORY_BYTES}" "${PLAYGROUND_DOCKER_CPU_COUNT}"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'first=8589934592/6'* ]]
  [[ "${output}" == *$'\nsecond=8589934592/6' ]]
}

@test "detect_docker_runtime_info reuses the recorded Docker budget after runtime cache resets" {
  playground_run '
    export PLAYGROUND_RUNTIME_CACHE_DIR="${PLAYGROUND_STATE_DIR}/runtime-cache"
    unset PLAYGROUND_DOCKER_INFO_LOADED
    unset PLAYGROUND_DOCKER_MEMORY_BYTES
    unset PLAYGROUND_DOCKER_MEMORY_MIB
    unset PLAYGROUND_DOCKER_CPU_COUNT

    # Returns a fixed Docker budget so the init-style refresh writes the recorded snapshot.
    docker() {
      if [ "${1:-}" = "info" ] && [ "${2:-}" = "--format" ]; then
        printf "%s\n" "8589934592 6"
        return 0
      fi

      return 1
    }

    refresh_docker_runtime_info_snapshot
    printf "first=%s/%s\n" "${PLAYGROUND_DOCKER_MEMORY_BYTES}" "${PLAYGROUND_DOCKER_CPU_COUNT}"

    clear_docker_runtime_cache

    # Simulates an unavailable Docker CLI so the second probe must hit the recorded snapshot.
    docker() {
      return 1
    }

    detect_docker_runtime_info
    printf "second=%s/%s\n" "${PLAYGROUND_DOCKER_MEMORY_BYTES}" "${PLAYGROUND_DOCKER_CPU_COUNT}"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'first=8589934592/6'* ]]
  [[ "${output}" == *$'\nsecond=8589934592/6' ]]
}

@test "ensure_docker_runtime_snapshot records the Docker budget for direct init apply flows" {
  local state_dir

  state_dir="$(mktemp -d)"
  write_stub "docker" '
if [ "${1:-}" = "info" ] && [ "${2:-}" = "--format" ]; then
  case "${3:-}" in
    "{{.MemTotal}} {{.NCPU}}")
      printf "%s\n" "8589934592 6"
      exit 0
      ;;
    "{{.MemTotal}}")
      printf "%s\n" "8589934592"
      exit 0
      ;;
    "{{.NCPU}}")
      printf "%s\n" "6"
      exit 0
      ;;
  esac
fi

exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_STATE_DIR="${state_dir}" \
    PATH="${ENV_STUB_BIN}:${PATH}" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/config/ensure-docker-runtime-snapshot.sh
      cat "'"${state_dir}"'/docker-runtime-info.env"
    '

  rm -rf "${state_dir}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"PLAYGROUND_DOCKER_MEMORY_BYTES=8589934592"* ]]
  [[ "${output}" == *"PLAYGROUND_DOCKER_CPU_COUNT=6"* ]]
}

@test "ensure_docker_runtime_snapshot reuses the recorded Docker budget without probing Docker again" {
  local state_dir

  state_dir="$(mktemp -d)"
  cat >"${state_dir}/docker-runtime-info.env" <<'EOF'
PLAYGROUND_DOCKER_MEMORY_BYTES=8589934592
PLAYGROUND_DOCKER_CPU_COUNT=6
EOF
  write_stub "docker" 'exit 1'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_STATE_DIR="${state_dir}" \
    PATH="${ENV_STUB_BIN}:${PATH}" \
    bash -c '
      set -euo pipefail
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/config/ensure-docker-runtime-snapshot.sh
      cat "'"${state_dir}"'/docker-runtime-info.env"
    '

  rm -rf "${state_dir}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"PLAYGROUND_DOCKER_MEMORY_BYTES=8589934592"* ]]
  [[ "${output}" == *"PLAYGROUND_DOCKER_CPU_COUNT=6"* ]]
}

@test "k3d_cluster_list_output reuses the per-run cache file after in-process resets" {
  playground_run '
    export PLAYGROUND_RUNTIME_CACHE_DIR="${PLAYGROUND_STATE_DIR}/runtime-cache"

    # Returns a fixed cluster list so the first probe writes the cache file.
    k3d() {
      if [ "${1:-}" = "cluster" ] && [ "${2:-}" = "list" ]; then
        printf "%s\n" "NAME SERVERS AGENTS LOADBALANCER" "openeverest-playground 1 1 true"
        return 0
      fi

      return 1
    }

    first_output="$(k3d_cluster_list_output)"
    printf "first=%s\n" "$(printf "%s" "${first_output}" | tail -n 1)"

    unset PLAYGROUND_K3D_CLUSTER_LIST_LOADED
    unset PLAYGROUND_K3D_CLUSTER_LIST_OUTPUT

    # Simulates an unavailable k3d CLI so the second probe must hit the cache.
    k3d() {
      return 1
    }

    second_output="$(k3d_cluster_list_output)"
    printf "second=%s\n" "$(printf "%s" "${second_output}" | tail -n 1)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'first=openeverest-playground 1 1 true'* ]]
  [[ "${output}" == *$'\nsecond=openeverest-playground 1 1 true' ]]
}
