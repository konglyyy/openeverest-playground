#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Runs the deterministic shell and Bats test suite with playground-specific
# environment variables cleared first.
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/ci/common.sh"

cd "${ROOT_DIR}"

ci_require_cmds bats jq task

# Task loads the local `config/playground.env` for command runs, but the shell test suite must
# control its own environment explicitly so local playground settings do not
# leak into deterministic assertions.
unset \
  PLAYGROUND_ENV_FILE \
  PLAYGROUND_STATE_DIR \
  PLAYGROUND_DOCKER_RUNTIME_CACHE_FILE \
  PLAYGROUND_REGISTRY_CACHE_DIR \
  PLAYGROUND_ENV_LOADED \
  CLUSTER_NAME \
  K3D_PROFILE_VERSION \
  KUBE_CONTEXT \
  EVEREST_NAMESPACE \
  EVEREST_DATABASE_NAMESPACE \
  EVEREST_OLM_NAMESPACE \
  EVEREST_MONITORING_NAMESPACE \
  PLAYGROUND_SYSTEM_NAMESPACE \
  EVEREST_UI_HOST \
  EVEREST_UI_PORT \
  EVEREST_UI_URL \
  EVEREST_ADMIN_PASSWORD \
  ENABLE_BACKUP \
  PLAYGROUND_VERBOSE \
  PLAYGROUND_NO_SPINNER \
  PLAYGROUND_QUERY_REQUEST_TIMEOUT \
  EVEREST_HELM_REPO_NAME \
  EVEREST_HELM_REPO_URL \
  EVEREST_HELM_CHART \
  EVEREST_HELM_CHART_VERSION \
  EVEREST_DB_NAMESPACE_CHART \
  EVEREST_DB_NAMESPACE_CHART_VERSION \
  HELM_REPO_REFRESH_TTL_SECONDS \
  HELM_REPO_REFRESH_MARKER \
  SEAWEEDFS_IMAGE \
  AWS_CLI_IMAGE \
  SEAWEEDFS_SERVICE_NAME \
  SEAWEEDFS_S3_PORT \
  SEAWEEDFS_S3_HTTPS_PORT \
  SEAWEEDFS_TLS_SECRET_NAME \
  SEAWEEDFS_VOLUME_SIZE \
  SEAWEEDFS_ACCESS_KEY \
  SEAWEEDFS_SECRET_KEY \
  BACKUP_STORAGE_NAME \
  BACKUP_BUCKET_PREFIX \
  AWS_DEFAULT_REGION

bats --recursive tests/bats

printf '%s\n' "Shell tests passed."
