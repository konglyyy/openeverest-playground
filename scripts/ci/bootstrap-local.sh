#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Installs the local toolchain needed for contributor CI tasks on macOS or
# Linux.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

mode="${1:-all}"
packages=()
resolved_packages=()

case "$(ci_platform)" in
  Darwin)
    command -v brew >/dev/null 2>&1 || {
      printf '%s\n' "Homebrew is required for local CI bootstrap on macOS." >&2
      exit 1
    }
    ;;
  Linux)
    command -v apt-get >/dev/null 2>&1 || {
      printf '%s\n' "apt-get is required for local CI bootstrap on Linux." >&2
      exit 1
    }
    ;;
  *)
    printf '%s\n' "Unsupported platform for local CI bootstrap: $(ci_platform)" >&2
    exit 1
    ;;
esac

case "${mode}" in
  lint)
    packages=(shellcheck shfmt yamllint actionlint)
    ;;
  test)
    packages=(bats jq)
    ;;
  smoke)
    packages=(helm kubectl k3d jq)
    ;;
  all)
    packages=(shellcheck shfmt yamllint actionlint bats jq helm kubectl k3d)
    ;;
  *)
    printf '%s\n' "Usage: $0 <lint|test|smoke|all>" >&2
    exit 1
    ;;
esac

case "$(ci_platform)" in
  Darwin)
    for package in "${packages[@]}"; do
      resolved_packages+=("$(ci_homebrew_package_for_cmd "${package}")")
    done
    brew install "${resolved_packages[@]}"
    ;;
  Linux)
    for package in "${packages[@]}"; do
      resolved_packages+=("$(ci_apt_package_for_cmd "${package}")")
    done
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "${resolved_packages[@]}"
    ;;
esac

if [ "${mode}" = "smoke" ] || [ "${mode}" = "all" ]; then
  printf '%s\n' "Docker must still be installed and running before task ci:smoke:minimal will pass."
fi
