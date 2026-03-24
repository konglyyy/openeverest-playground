#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared environment loading and small runtime state helpers.
# -----------------------------------------------------------------------------

# Removes one matching pair of wrapping quotes from a dotenv value.
strip_env_value_quotes() {
  local value="$1"

  case "${value}" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac

  printf '%s\n' "${value}"
}

# Loads simple KEY=value lines from a dotenv-style file without evaluating them
# as shell code, so values containing spaces or `$` stay literal.
load_env_file_exports() {
  local env_file="$1"
  local line=""
  local key=""
  local value=""

  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      '' | \#*)
        continue
        ;;
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        value="$(strip_env_value_quotes "${value}")"
        export "${key}=${value}"
        ;;
    esac
  done <"${env_file}"
}

# Loads `config/playground.env` overrides once and exports all derived defaults used by the
# helper scripts so later functions can rely on a stable environment contract.
load_env() {
  local env_file=""
  local ignored_root_env=""

  if [ -n "${PLAYGROUND_ENV_LOADED:-}" ]; then
    return 0
  fi

  env_file="${PLAYGROUND_ENV_FILE:-${ROOT_DIR}/config/playground.env}"
  ignored_root_env="${ROOT_DIR}/.env"

  if [ -z "${PLAYGROUND_ENV_FILE:-}" ] && [ -f "${ignored_root_env}" ]; then
    warn "Ignoring ${ignored_root_env}. Use ${env_file} for playground config."
  fi

  if [ -f "${env_file}" ]; then
    load_env_file_exports "${env_file}"
  fi

  export PLAYGROUND_ENV_FILE="${env_file}"
  export PLAYGROUND_STATE_DIR="${PLAYGROUND_STATE_DIR:-${STATE_DIR}}"
  export PLAYGROUND_DOCKER_RUNTIME_CACHE_FILE="${PLAYGROUND_DOCKER_RUNTIME_CACHE_FILE:-${PLAYGROUND_STATE_DIR}/docker-runtime-info.env}"
  export CLUSTER_NAME="${CLUSTER_NAME:-openeverest-playground}"
  export K3D_PROFILE_VERSION="${K3D_PROFILE_VERSION:-3}"
  export KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-${CLUSTER_NAME}}"
  export EVEREST_NAMESPACE="${EVEREST_NAMESPACE:-everest-system}"
  export EVEREST_DATABASE_NAMESPACE="${EVEREST_DATABASE_NAMESPACE:-everest-databases}"
  export EVEREST_OLM_NAMESPACE="${EVEREST_OLM_NAMESPACE:-everest-olm}"
  export EVEREST_MONITORING_NAMESPACE="${EVEREST_MONITORING_NAMESPACE:-everest-monitoring}"
  export PLAYGROUND_SYSTEM_NAMESPACE="${PLAYGROUND_SYSTEM_NAMESPACE:-playground-system}"
  export ENABLE_BACKUP="${ENABLE_BACKUP:-false}"
  export EVEREST_UI_HOST="${EVEREST_UI_HOST:-localhost}"
  export EVEREST_UI_PORT="${EVEREST_UI_PORT:-8080}"
  export EVEREST_UI_URL="${EVEREST_UI_URL:-http://${EVEREST_UI_HOST}:${EVEREST_UI_PORT}}"
  export EVEREST_ADMIN_PASSWORD="${EVEREST_ADMIN_PASSWORD:-playground-admin}"
  export PLAYGROUND_VERBOSE="${PLAYGROUND_VERBOSE:-false}"
  export PLAYGROUND_NO_SPINNER="${PLAYGROUND_NO_SPINNER:-false}"
  export PLAYGROUND_QUERY_REQUEST_TIMEOUT="${PLAYGROUND_QUERY_REQUEST_TIMEOUT:-5s}"
  export EVEREST_HELM_REPO_NAME="${EVEREST_HELM_REPO_NAME:-openeverest}"
  export EVEREST_HELM_REPO_URL="${EVEREST_HELM_REPO_URL:-https://openeverest.io/helm-charts/}"
  export EVEREST_HELM_CHART="${EVEREST_HELM_CHART:-openeverest/openeverest}"
  export EVEREST_HELM_CHART_VERSION="${EVEREST_HELM_CHART_VERSION:-}"
  export EVEREST_DB_NAMESPACE_CHART="${EVEREST_DB_NAMESPACE_CHART:-openeverest/everest-db-namespace}"
  export EVEREST_DB_NAMESPACE_CHART_VERSION="${EVEREST_DB_NAMESPACE_CHART_VERSION:-}"
  export HELM_REPO_REFRESH_TTL_SECONDS="${HELM_REPO_REFRESH_TTL_SECONDS:-21600}"
  export HELM_REPO_REFRESH_MARKER="${HELM_REPO_REFRESH_MARKER:-${DOCTOR_STATE_DIR}/helm-repo-refreshed-at}"
  export PLAYGROUND_REGISTRY_CACHE_DIR="${PLAYGROUND_REGISTRY_CACHE_DIR:-${ROOT_DIR}/.cache/dockerhub-registry}"
  export SEAWEEDFS_IMAGE="${SEAWEEDFS_IMAGE:-chrislusf/seaweedfs:latest}"
  export AWS_CLI_IMAGE="${AWS_CLI_IMAGE:-public.ecr.aws/aws-cli/aws-cli:latest}"
  export SEAWEEDFS_SERVICE_NAME="${SEAWEEDFS_SERVICE_NAME:-seaweedfs-s3}"
  export SEAWEEDFS_S3_PORT="${SEAWEEDFS_S3_PORT:-8333}"
  export SEAWEEDFS_S3_HTTPS_PORT="${SEAWEEDFS_S3_HTTPS_PORT:-8443}"
  export SEAWEEDFS_TLS_SECRET_NAME="${SEAWEEDFS_TLS_SECRET_NAME:-seaweedfs-s3-tls}"
  export SEAWEEDFS_VOLUME_SIZE="${SEAWEEDFS_VOLUME_SIZE:-10Gi}"
  export SEAWEEDFS_ACCESS_KEY="${SEAWEEDFS_ACCESS_KEY:-playground-access-key}"
  export SEAWEEDFS_SECRET_KEY="${SEAWEEDFS_SECRET_KEY:-playground-secret-key}"
  export BACKUP_STORAGE_NAME="${BACKUP_STORAGE_NAME:-seaweedfs-backup}"
  export BACKUP_BUCKET_PREFIX="${BACKUP_BUCKET_PREFIX:-everest-backups}"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

  if [ -t 1 ]; then
    export PLAYGROUND_STDOUT_TTY=1
  else
    export PLAYGROUND_STDOUT_TTY=0
  fi

  if [ -t 0 ]; then
    export PLAYGROUND_STDIN_TTY=1
  else
    export PLAYGROUND_STDIN_TTY=0
  fi

  if [ -t 2 ]; then
    export PLAYGROUND_STDERR_TTY=1
  else
    export PLAYGROUND_STDERR_TTY=0
  fi

  PLAYGROUND_ENV_LOADED=1
  export PLAYGROUND_ENV_LOADED
}

# Fails fast when a required CLI is not present in the current environment.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# Ensures the root playground state directory exists before writes.
ensure_playground_state_dir() {
  load_env
  mkdir -p "${PLAYGROUND_STATE_DIR}"
}

# Ensures the local `.state/doctor` cache directory exists before writes.
ensure_state_dir() {
  ensure_playground_state_dir
  mkdir -p "${DOCTOR_STATE_DIR}"
}

# Ensures the repo-local Docker Hub pull-through cache directory exists before cluster creation.
ensure_registry_cache_dir() {
  load_env
  mkdir -p "${PLAYGROUND_REGISTRY_CACHE_DIR}"
}

# Ensures the optional per-run runtime probe cache directory exists before writes.
ensure_runtime_cache_dir() {
  if [ -z "${PLAYGROUND_RUNTIME_CACHE_DIR:-}" ]; then
    return 1
  fi

  mkdir -p "${PLAYGROUND_RUNTIME_CACHE_DIR}"
}

# Returns one path inside the optional per-run runtime probe cache directory.
runtime_cache_file() {
  local cache_name="$1"

  if [ -z "${PLAYGROUND_RUNTIME_CACHE_DIR:-}" ]; then
    return 1
  fi

  printf '%s/%s\n' "${PLAYGROUND_RUNTIME_CACHE_DIR}" "${cache_name}"
}

# Returns the file modification time in epoch seconds on both macOS and Linux.
file_mtime() {
  local path="$1"

  if stat -f "%m" "${path}" >/dev/null 2>&1; then
    stat -f "%m" "${path}"
  else
    stat -c "%Y" "${path}"
  fi
}

# Clears cached derived runtime values so callers can reload the config file in-process
# and recompute the effective sizing profile.
clear_runtime_resolution_cache() {
  clear_docker_runtime_cache
  clear_k3d_probe_cache
  unset PLAYGROUND_RESOLVED_SIZING_PROFILE
  unset PLAYGROUND_RESOLVED_WORKER_LAYOUT_CSV
  unset PLAYGROUND_RESOLVED_AGENT_COUNT
  unset PLAYGROUND_RESOLVED_TOTAL_WORKER_CPU_MILLI
  unset PLAYGROUND_RESOLVED_TOTAL_WORKER_MEMORY_MIB
  unset EVEREST_UI_URL
}

# Clears cached Docker budget probes from both the current shell and the optional
# per-run runtime cache directory.
clear_docker_runtime_cache() {
  local cache_file=""

  unset PLAYGROUND_DOCKER_INFO_LOADED
  unset PLAYGROUND_DOCKER_MEMORY_BYTES
  unset PLAYGROUND_DOCKER_MEMORY_MIB
  unset PLAYGROUND_DOCKER_CPU_COUNT

  if cache_file="$(runtime_cache_file "docker-runtime-info.env" 2>/dev/null)"; then
    rm -f "${cache_file}"
  fi
}

# Clears cached k3d list probes from both the current shell and the optional
# per-run runtime cache directory.
clear_k3d_probe_cache() {
  local cluster_cache_file=""
  local node_cache_file=""

  unset PLAYGROUND_K3D_CLUSTER_LIST_LOADED
  unset PLAYGROUND_K3D_CLUSTER_LIST_OUTPUT
  unset PLAYGROUND_K3D_NODE_LIST_LOADED
  unset PLAYGROUND_K3D_NODE_LIST_OUTPUT

  if cluster_cache_file="$(runtime_cache_file "k3d-cluster-list.txt" 2>/dev/null)"; then
    rm -f "${cluster_cache_file}"
  fi

  if node_cache_file="$(runtime_cache_file "k3d-node-list.json" 2>/dev/null)"; then
    rm -f "${node_cache_file}"
  fi
}

# Returns success when the current shell is running inside WSL.
running_under_wsl() {
  local proc_version_file="${PLAYGROUND_PROC_VERSION_FILE:-/proc/version}"
  local osrelease_file="${PLAYGROUND_OSRELEASE_FILE:-/proc/sys/kernel/osrelease}"

  if [ -r "${osrelease_file}" ] && grep -qi "microsoft" "${osrelease_file}"; then
    return 0
  fi

  if [ -r "${proc_version_file}" ] && grep -qi "microsoft" "${proc_version_file}"; then
    return 0
  fi

  return 1
}

# Returns success when the given path points into a Windows-mounted drive in WSL.
path_is_windows_mount() {
  local path="${1:-}"

  case "${path}" in
    /mnt/[A-Za-z]/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns success when the playground repo lives under a Windows-mounted drive in WSL.
playground_root_on_windows_mount() {
  path_is_windows_mount "${ROOT_DIR}"
}

# Returns success when the given flag-like value is enabled.
is_truthy() {
  local raw_value="${1:-}"
  local normalized_flag

  normalized_flag="$(printf '%s' "${raw_value}" | tr '[:upper:]' '[:lower:]')"

  case "${normalized_flag}" in
    1 | true | yes | on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns success when the current config enables the optional backup stack.
backup_enabled() {
  load_env
  is_truthy "${ENABLE_BACKUP}"
}

# Returns success when the user explicitly asked to stream verbose tool output.
verbose_output_enabled() {
  load_env
  is_truthy "${PLAYGROUND_VERBOSE}"
}
