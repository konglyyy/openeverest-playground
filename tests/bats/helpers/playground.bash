#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Provides shared Bats helpers for running playground functions with a stable
# synthetic environment.
# -----------------------------------------------------------------------------

PLAYGROUND_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PLAYGROUND_TEST_FIXTURE_DIR="${PLAYGROUND_TEST_ROOT}/tests/fixtures"

# Executes one shell snippet inside the standard playground test environment.
playground_run() {
  local script_body="$1"

  run env \
    NO_COLOR=1 \
    PLAYGROUND_TEST_ROOT="${PLAYGROUND_TEST_ROOT}" \
    PLAYGROUND_TEST_FIXTURE_DIR="${PLAYGROUND_TEST_FIXTURE_DIR}" \
    PLAYGROUND_TEST_SCRIPT="${script_body}" \
    bash -lc '
      set -euo pipefail
      export PLAYGROUND_ENV_FILE="${PLAYGROUND_TEST_ROOT}/.state/test/playground.env"
      export PLAYGROUND_STATE_DIR="${PLAYGROUND_TEST_ROOT}/.state/test"
      export PLAYGROUND_DOCKER_RUNTIME_CACHE_FILE="${PLAYGROUND_STATE_DIR}/docker-runtime-info.env"
      export PLAYGROUND_REGISTRY_CACHE_DIR="${PLAYGROUND_TEST_ROOT}/.cache/dockerhub-registry"
      mkdir -p "${PLAYGROUND_STATE_DIR}/doctor" "${PLAYGROUND_REGISTRY_CACHE_DIR}"

      # shellcheck disable=SC1091
      . "${PLAYGROUND_TEST_ROOT}/scripts/common/lib.sh"
      # shellcheck disable=SC1091
      . "${PLAYGROUND_TEST_ROOT}/scripts/config/policy.sh"

      export PLAYGROUND_ENV_LOADED=1
      export CLUSTER_NAME="openeverest-playground"
      export K3D_PROFILE_VERSION="3"
      export KUBE_CONTEXT="k3d-openeverest-playground"
      export EVEREST_NAMESPACE="everest-system"
      export EVEREST_DATABASE_NAMESPACE="everest-databases"
      export EVEREST_OLM_NAMESPACE="everest-olm"
      export EVEREST_MONITORING_NAMESPACE="everest-monitoring"
      export PLAYGROUND_SYSTEM_NAMESPACE="playground-system"
      export EVEREST_UI_HOST="localhost"
      export EVEREST_UI_PORT="8080"
      export EVEREST_ADMIN_PASSWORD="playground-admin"
      export ENABLE_BACKUP="false"
      export PLAYGROUND_VERBOSE="false"
      export PLAYGROUND_NO_SPINNER="true"
      export PLAYGROUND_QUERY_REQUEST_TIMEOUT="5s"
      export EVEREST_HELM_REPO_NAME="openeverest"
      export EVEREST_HELM_REPO_URL="https://openeverest.io/helm-charts/"
      export EVEREST_HELM_CHART="openeverest/openeverest"
      export EVEREST_HELM_CHART_VERSION=""
      export EVEREST_DB_NAMESPACE_CHART="openeverest/everest-db-namespace"
      export EVEREST_DB_NAMESPACE_CHART_VERSION=""
      export HELM_REPO_REFRESH_TTL_SECONDS="21600"
      export HELM_REPO_REFRESH_MARKER="${PLAYGROUND_STATE_DIR}/doctor/helm-repo-refreshed-at"
      export SEAWEEDFS_IMAGE="chrislusf/seaweedfs:latest"
      export AWS_CLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:latest"
      export SEAWEEDFS_SERVICE_NAME="seaweedfs-s3"
      export SEAWEEDFS_S3_PORT="8333"
      export SEAWEEDFS_S3_HTTPS_PORT="8443"
      export SEAWEEDFS_TLS_SECRET_NAME="seaweedfs-s3-tls"
      export SEAWEEDFS_VOLUME_SIZE="10Gi"
      export SEAWEEDFS_ACCESS_KEY="playground-access-key"
      export SEAWEEDFS_SECRET_KEY="playground-secret-key"
      export BACKUP_STORAGE_NAME="seaweedfs-backup"
      export BACKUP_BUCKET_PREFIX="everest-backups"
      export AWS_DEFAULT_REGION="us-east-1"
      export PLAYGROUND_DOCKER_INFO_LOADED=1
      export PLAYGROUND_DOCKER_MEMORY_BYTES="$((8 * 1024 * 1024 * 1024))"
      export PLAYGROUND_DOCKER_CPU_COUNT="6"
      export PLAYGROUND_STDOUT_TTY=0
      export PLAYGROUND_STDIN_TTY=0
      export PLAYGROUND_STDERR_TTY=0

      eval "${PLAYGROUND_TEST_SCRIPT}"
    '
}
