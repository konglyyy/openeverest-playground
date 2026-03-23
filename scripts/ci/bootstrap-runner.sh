#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Installs the GitHub Actions runner dependencies needed by the validation
# workflow jobs.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/versions.env"

mode="${1:-}"
[ -n "${mode}" ] || {
  printf '%s\n' "Usage: $0 <static|shell-tests|smoke-minimal>" >&2
  exit 1
}

# Installs one or more apt packages without interactive prompts.
install_apt_packages() {
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends "$@"
}

# Installs the pinned Task binary when the runner image does not include it.
install_task() {
  local archive
  local temp_dir

  if command -v task >/dev/null 2>&1; then
    return 0
  fi

  temp_dir="$(mktemp -d)"
  archive="${temp_dir}/task.tar.gz"

  curl -fsSL -o "${archive}" "https://github.com/go-task/task/releases/download/v${TASK_VERSION}/task_linux_amd64.tar.gz"
  tar -xzf "${archive}" -C "${temp_dir}" task
  sudo install -m 0755 "${temp_dir}/task" /usr/local/bin/task
  rm -rf "${temp_dir}"
}

# Installs the pinned actionlint binary when the runner image does not include it.
install_actionlint() {
  local archive
  local temp_dir

  if command -v actionlint >/dev/null 2>&1; then
    return 0
  fi

  temp_dir="$(mktemp -d)"
  archive="${temp_dir}/actionlint.tar.gz"

  curl -fsSL -o "${archive}" "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
  tar -xzf "${archive}" -C "${temp_dir}" actionlint
  sudo install -m 0755 "${temp_dir}/actionlint" /usr/local/bin/actionlint
  rm -rf "${temp_dir}"
}

# Installs the pinned k3d binary when the runner image does not include it.
install_k3d() {
  if command -v k3d >/dev/null 2>&1; then
    return 0
  fi

  curl -fsSL -o /tmp/k3d "https://github.com/k3d-io/k3d/releases/download/v${K3D_VERSION}/k3d-linux-amd64"
  sudo install -m 0755 /tmp/k3d /usr/local/bin/k3d
  rm -f /tmp/k3d
}

# Installs the pinned kubectl binary when the runner image does not include it.
install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    return 0
  fi

  curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
}

# Installs the pinned Helm binary when the runner image does not include it.
install_helm() {
  local archive
  local temp_dir

  if command -v helm >/dev/null 2>&1; then
    return 0
  fi

  temp_dir="$(mktemp -d)"
  archive="${temp_dir}/helm.tar.gz"

  curl -fsSL -o "${archive}" "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  tar -xzf "${archive}" -C "${temp_dir}"
  sudo install -m 0755 "${temp_dir}/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "${temp_dir}"
}

case "${mode}" in
  static)
    install_apt_packages curl ca-certificates jq shellcheck shfmt yamllint
    install_task
    install_actionlint
    ;;
  shell-tests)
    install_apt_packages curl ca-certificates jq bats
    install_task
    ;;
  smoke-minimal)
    install_apt_packages curl ca-certificates jq
    install_task
    install_k3d
    install_kubectl
    install_helm
    ;;
  *)
    printf '%s\n' "Unsupported bootstrap mode: ${mode}" >&2
    exit 1
    ;;
esac
