#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Validates the local toolchain before resume or cluster mutation happens.
# Full mode also ensures the Everest Helm repo metadata is locally available,
# refreshing it only when the cache is stale or missing.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env
mode="${1:-full}"
case "${mode}" in
  full) ;;
  local) ;;
  resume) ;;
  *)
    die "Usage: $0 <full|local|resume>"
    ;;
esac

wsl_note=""
resolved_layout=""
docker_budget_label=""
tooling_label=""
helm_status_label=""
everest_chart_label=""
db_namespace_chart_label=""
backup_label="$(style_dim 1 'disabled')"
doctor_report_enabled="${PLAYGROUND_DOCTOR_REPORT:-true}"
docker_budget_recorded="false"

# Prints the human-readable summary for the doctor checks.
print_doctor_report() {
  print_summary_section "OpenEverest playground doctor"
  print_summary_field "Mode" "$(style_bold 1 "${mode}")"
  if [ "${docker_budget_recorded}" = "true" ]; then
    print_summary_field "Docker budget" "$(style_bold 1 "${docker_budget_label}")"
    print_summary_field "Resolved layout" "$(style_bold 1 "${resolved_layout}")"
  else
    print_summary_field "Docker budget" "$(style_dim 1 "${docker_budget_label}")"
    print_summary_field "Resolved layout" "$(style_dim 1 "${resolved_layout}")"
  fi
  print_summary_field "Backup" "${backup_label}"

  print_summary_section "Checks"
  print_summary_field "CLI tools" "$(style_bold 1 "${tooling_label}")"
  print_summary_field "Docker daemon" "$(style_success 1 'reachable')"
  print_summary_field "k3d" "$(style_success 1 'reachable')"
  print_summary_field "Helm repo" "${helm_status_label}"
  print_summary_field "Everest chart" "${everest_chart_label}"
  print_summary_field "DB namespace chart" "${db_namespace_chart_label}"

  if [ -n "${wsl_note}" ]; then
    print_summary_section "Notes"
    print_summary_multiline_field "WSL" "$(style_warning 1 "${wsl_note}")"
  fi
}

# Validates the required local dependencies and optionally checks Helm metadata.
run_doctor_checks() {
  if running_under_wsl && playground_root_on_windows_mount; then
    wsl_note="The playground is under a Windows-mounted path (${ROOT_DIR}). For better filesystem and Docker performance, prefer a path inside your Linux home directory."
  fi

  # Fail early if the baseline CLIs are missing rather than halfway through `up`.
  required_cmds=(docker k3d kubectl jq)
  tooling_label="docker, k3d, kubectl, jq"

  if [ "${mode}" != "resume" ]; then
    required_cmds+=(helm)
    tooling_label="${tooling_label}, helm"
  fi

  if backup_enabled; then
    required_cmds+=(openssl)
    tooling_label="${tooling_label}, openssl"
  fi

  for cmd in "${required_cmds[@]}"; do
    require_cmd "${cmd}"
  done

  # Docker availability is the real gate behind k3d, image pulls, and Helm hooks.
  if ! docker_daemon_reachable; then
    if running_under_wsl; then
      die "Docker daemon is not reachable from WSL. If you are using Docker Desktop, enable WSL integration for this distro and retry."
    fi
    die "Docker daemon is not reachable. Start Docker Desktop or another Docker runtime and retry."
  fi

  if ! k3d version >/dev/null 2>&1; then
    die "k3d is installed but could not run. Verify your local k3d installation."
  fi

  docker_budget_label="not recorded yet"
  resolved_layout="run 'task init' to record the Docker budget"

  if detect_docker_runtime_info; then
    validate_playground_sizing
    resolved_layout="$(resolved_layout_display)"
    docker_budget_label="$(format_bytes_as_gib "$(docker_memory_bytes)") / $(docker_cpu_count) CPU"
    docker_budget_recorded="true"
  elif [ "${mode}" != "local" ]; then
    die "Docker budget is not recorded yet. Run 'task init' to refresh the recorded playground budget."
  fi

  if backup_enabled; then
    backup_label="$(style_success 1 'enabled')"
  fi

  helm_status_label="$(style_dim 1 "skipped in ${mode} mode")"
  everest_chart_label="$(style_dim 1 "skipped in ${mode} mode")"
  db_namespace_chart_label="$(style_dim 1 "skipped in ${mode} mode")"

  if [ "${mode}" = "full" ]; then
    # The networked Helm check only refreshes metadata when the local cache is
    # stale or absent.
    if ! ensure_helm_repo; then
      die "Unable to prepare ${EVEREST_HELM_CHART} from ${EVEREST_HELM_REPO_URL}. Check network access and retry."
    fi

    if ! helm_chart_resolvable "${EVEREST_HELM_CHART}"; then
      die "Unable to resolve ${EVEREST_HELM_CHART} from the configured Helm repo."
    fi

    if ! helm_chart_resolvable "${EVEREST_DB_NAMESPACE_CHART}"; then
      die "Unable to resolve ${EVEREST_DB_NAMESPACE_CHART} from the configured Helm repo."
    fi

    helm_status_label="$(style_success 1 'ready')"
    everest_chart_label="$(style_success 1 'resolvable')"
    db_namespace_chart_label="$(style_success 1 'resolvable')"
  fi

  if is_truthy "${doctor_report_enabled}"; then
    print_doctor_report
    printf '\n'
  fi
}

run_report_step "Checking playground prerequisites" run_doctor_checks
