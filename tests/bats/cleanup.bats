#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies the public cleanup commands preserve or purge local cache/state with
# the intended granularity.
# -----------------------------------------------------------------------------

create_fake_k3d() {
  local bin_dir="$1"
  local cluster_marker="$2"

  cat >"${bin_dir}/k3d" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\$1 \$2" in
  "cluster list")
    printf '%s\n' "NAME SERVERS AGENTS LOADBALANCER"
    if [ -f "${cluster_marker}" ]; then
      printf '%s\n' "openeverest-playground 1 0 true"
    fi
    ;;
  "cluster delete")
    rm -f "${cluster_marker}"
    ;;
  *)
    printf 'unexpected k3d invocation: %s\n' "\$*" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "${bin_dir}/k3d"
}

@test "task reset removes local state but preserves the Docker Hub cache" {
  sandbox="$(mktemp -d)"
  stub_dir="${sandbox}/bin"
  cluster_marker="${sandbox}/cluster-present"

  mkdir -p "${stub_dir}"
  : >"${cluster_marker}"
  create_fake_k3d "${stub_dir}" "${cluster_marker}"

  run env \
    NO_COLOR=1 \
    PATH="${stub_dir}:${PATH}" \
    PLAYGROUND_ENV_FILE="${sandbox}/playground.env" \
    PLAYGROUND_STATE_DIR="${sandbox}/state" \
    PLAYGROUND_REGISTRY_CACHE_DIR="${sandbox}/cache/dockerhub-registry" \
    PLAYGROUND_NO_SPINNER=true \
    CLUSTER_NAME="openeverest-playground" \
    bash -c '
      set -euo pipefail
      cd "'"${BATS_TEST_DIRNAME}"'/../.."
      mkdir -p "${PLAYGROUND_STATE_DIR}/doctor" "${PLAYGROUND_REGISTRY_CACHE_DIR}"
      touch "${PLAYGROUND_STATE_DIR}/doctor/marker" "${PLAYGROUND_REGISTRY_CACHE_DIR}/blob"
      ./scripts/cluster/cleanup.sh reset
      [ ! -e "${PLAYGROUND_STATE_DIR}" ]
      [ -f "${PLAYGROUND_REGISTRY_CACHE_DIR}/blob" ]
      [ ! -f "'"${cluster_marker}"'" ]
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Deleting k3d cluster openeverest-playground"* ]]
  [[ "${output}" == *"Removing local playground state"* ]]
  [[ "${output}" != *"Removing Docker Hub pull-through cache"* ]]
}

@test "task reset:full removes local state and the Docker Hub cache" {
  sandbox="$(mktemp -d)"
  stub_dir="${sandbox}/bin"
  cluster_marker="${sandbox}/cluster-present"

  mkdir -p "${stub_dir}"
  : >"${cluster_marker}"
  create_fake_k3d "${stub_dir}" "${cluster_marker}"

  run env \
    NO_COLOR=1 \
    PATH="${stub_dir}:${PATH}" \
    PLAYGROUND_ENV_FILE="${sandbox}/playground.env" \
    PLAYGROUND_STATE_DIR="${sandbox}/state" \
    PLAYGROUND_REGISTRY_CACHE_DIR="${sandbox}/cache/dockerhub-registry" \
    PLAYGROUND_NO_SPINNER=true \
    CLUSTER_NAME="openeverest-playground" \
    bash -c '
      set -euo pipefail
      cd "'"${BATS_TEST_DIRNAME}"'/../.."
      mkdir -p "${PLAYGROUND_STATE_DIR}/doctor" "${PLAYGROUND_REGISTRY_CACHE_DIR}"
      touch "${PLAYGROUND_STATE_DIR}/doctor/marker" "${PLAYGROUND_REGISTRY_CACHE_DIR}/blob"
      ./scripts/cluster/cleanup.sh reset-full
      [ ! -e "${PLAYGROUND_STATE_DIR}" ]
      [ ! -e "${PLAYGROUND_REGISTRY_CACHE_DIR}" ]
      [ ! -f "'"${cluster_marker}"'" ]
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Deleting k3d cluster openeverest-playground"* ]]
  [[ "${output}" == *"Removing Docker Hub pull-through cache"* ]]
}

@test "task reset:full purges local state and cache even when the cluster is absent" {
  sandbox="$(mktemp -d)"
  stub_dir="${sandbox}/bin"
  cluster_marker="${sandbox}/cluster-present"

  mkdir -p "${stub_dir}"
  create_fake_k3d "${stub_dir}" "${cluster_marker}"

  run env \
    NO_COLOR=1 \
    PATH="${stub_dir}:${PATH}" \
    PLAYGROUND_ENV_FILE="${sandbox}/playground.env" \
    PLAYGROUND_STATE_DIR="${sandbox}/state" \
    PLAYGROUND_REGISTRY_CACHE_DIR="${sandbox}/cache/dockerhub-registry" \
    PLAYGROUND_NO_SPINNER=true \
    CLUSTER_NAME="openeverest-playground" \
    bash -c '
      set -euo pipefail
      cd "'"${BATS_TEST_DIRNAME}"'/../.."
      mkdir -p "${PLAYGROUND_STATE_DIR}/doctor" "${PLAYGROUND_REGISTRY_CACHE_DIR}"
      touch "${PLAYGROUND_STATE_DIR}/doctor/marker" "${PLAYGROUND_REGISTRY_CACHE_DIR}/blob"
      ./scripts/cluster/cleanup.sh reset-full
      [ ! -e "${PLAYGROUND_STATE_DIR}" ]
      [ ! -e "${PLAYGROUND_REGISTRY_CACHE_DIR}" ]
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"does not exist. Purging local state and cache only."* ]]
  [[ "${output}" == *"Removing Docker Hub pull-through cache"* ]]
}
