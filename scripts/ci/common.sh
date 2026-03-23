#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Provides shared package-name mapping and missing-tool helpers for contributor
# CI scripts.
# -----------------------------------------------------------------------------

# Returns the current operating system name in the format expected by case statements.
ci_platform() {
  uname -s
}

# Maps one required command name to the Homebrew package that provides it.
ci_homebrew_package_for_cmd() {
  case "$1" in
    actionlint)
      printf '%s\n' "actionlint"
      ;;
    bats)
      printf '%s\n' "bats-core"
      ;;
    helm)
      printf '%s\n' "helm"
      ;;
    jq)
      printf '%s\n' "jq"
      ;;
    k3d)
      printf '%s\n' "k3d"
      ;;
    kubectl)
      printf '%s\n' "kubectl"
      ;;
    shellcheck)
      printf '%s\n' "shellcheck"
      ;;
    shfmt)
      printf '%s\n' "shfmt"
      ;;
    task)
      printf '%s\n' "go-task/tap/go-task"
      ;;
    yamllint)
      printf '%s\n' "yamllint"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

# Maps one required command name to the apt package that provides it.
ci_apt_package_for_cmd() {
  case "$1" in
    actionlint)
      printf '%s\n' "actionlint"
      ;;
    bats)
      printf '%s\n' "bats"
      ;;
    helm)
      printf '%s\n' "helm"
      ;;
    jq)
      printf '%s\n' "jq"
      ;;
    k3d)
      printf '%s\n' "k3d"
      ;;
    kubectl)
      printf '%s\n' "kubectl"
      ;;
    shellcheck)
      printf '%s\n' "shellcheck"
      ;;
    shfmt)
      printf '%s\n' "shfmt"
      ;;
    task)
      printf '%s\n' "task"
      ;;
    yamllint)
      printf '%s\n' "yamllint"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

# Prints a platform-specific install hint for one or more missing commands.
ci_install_hint_for_missing_cmds() {
  local package=""

  case "$(ci_platform)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        printf '%s' "Install them with: brew install"
        for package in "$@"; do
          printf ' %s' "$(ci_homebrew_package_for_cmd "${package}")"
        done
        printf '\n'
      else
        printf '%s\n' "Install Homebrew, then install the missing tools."
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        printf '%s' "Install them with: sudo apt-get install"
        for package in "$@"; do
          printf ' %s' "$(ci_apt_package_for_cmd "${package}")"
        done
        printf '\n'
      else
        printf '%s\n' "Install the missing tools with your system package manager."
      fi
      ;;
    *)
      printf '%s\n' "Install the missing tools before rerunning the CI task."
      ;;
  esac
}

# Fails when one or more required commands are missing from PATH.
ci_require_cmds() {
  local missing=()
  local cmd=""

  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  {
    printf '%s' "Missing required command(s):"
    for cmd in "${missing[@]}"; do
      printf ' %s' "${cmd}"
    done
    printf '\n'
    ci_install_hint_for_missing_cmds "${missing[@]}"
  } >&2
  return 1
}
