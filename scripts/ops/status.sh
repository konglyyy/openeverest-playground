#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Summarizes the current playground state without mutating anything.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env

STATUS_NODES_OUTPUT=""
STATUS_NODE_JSON=""
STATUS_TOPOLOGY_METRICS=""
STATUS_NAMESPACE_ROWS=""
STATUS_DBENGINE_ROWS=""
STATUS_BACKUPSTORAGE_ROWS=""
STATUS_CLUSTER_QUERY_OK=1
STATUS_NAMESPACE_QUERY_OK=1
STATUS_DBENGINE_QUERY_OK=1
STATUS_BACKUPSTORAGE_QUERY_OK=1

# Prints the topology block, including a fallback warning if rendering fails.
print_topology_status_section() {
  if [ -n "${STATUS_TOPOLOGY_METRICS}" ] && print_playground_topology_summary_from_metrics_tsv "${STATUS_TOPOLOGY_METRICS}"; then
    return 0
  fi

  if print_playground_topology_summary resolved-only; then
    return 0
  fi

  print_summary_section "Topology"
  print_summary_field "Resolved layout" "$(style_dim 1 'unavailable')"
  print_summary_multiline_field \
    "Warning" \
    "$(style_warning 1 'Topology details could not be rendered from the current cluster state.')"
}

# Prints the top-level cluster status block for the requested lifecycle state.
print_status_overview() {
  local state="$1"

  print_summary_section "OpenEverest playground status"
  print_summary_field "Cluster" "$(style_bold 1 "${CLUSTER_NAME}")"

  case "${state}" in
    not-created)
      print_summary_field "Status" "$(style_dim 1 'not created')"
      print_summary_field "Start" "$(style_action 1 'task init')"
      ;;
    inactive)
      print_summary_field "Status" "$(style_warning 1 'stopped or unreachable')"
      print_summary_field "Resume" "$(style_action 1 'task up')"
      print_summary_field "Query timeout" "$(style_dim 1 "${PLAYGROUND_QUERY_REQUEST_TIMEOUT}")"
      print_summary_multiline_field \
        "Hint" \
        "The Kubernetes API did not answer quickly enough. If the cluster should already be running, check Docker and kubectl health."
      ;;
    running)
      print_summary_field "Status" "$(style_success 1 'running')"
      print_summary_field "Context" "$(style_bold 1 "${KUBE_CONTEXT}")"
      ;;
  esac
}

# Collects cluster, namespace, and DBaaS rows for the running-status report.
collect_status_data() {
  local namespace=""
  local namespace_rows=""
  local -a namespaces=()

  if ! STATUS_NODE_JSON="$(k_query get nodes -o json 2>/dev/null)"; then
    STATUS_CLUSTER_QUERY_OK=0
    STATUS_NODE_JSON=""
    STATUS_TOPOLOGY_METRICS=""
    STATUS_NODES_OUTPUT="Kubernetes node status could not be queried within ${PLAYGROUND_QUERY_REQUEST_TIMEOUT}."
    return 0
  fi

  STATUS_TOPOLOGY_METRICS="$(topology_metrics_tsv_from_node_json "${STATUS_NODE_JSON}" 2>/dev/null || true)"

  if ! STATUS_NODES_OUTPUT="$(k_query get nodes -o wide 2>/dev/null)"; then
    STATUS_NODES_OUTPUT="Kubernetes node status could not be queried within ${PLAYGROUND_QUERY_REQUEST_TIMEOUT}."
  fi

  while IFS= read -r namespace; do
    namespaces+=("${namespace}")
  done < <(playground_namespaces)

  if [ "${#namespaces[@]}" -gt 0 ]; then
    if ! namespace_rows="$(k_query get namespace "${namespaces[@]}" --ignore-not-found --no-headers 2>/dev/null)"; then
      STATUS_NAMESPACE_QUERY_OK=0
    else
      STATUS_NAMESPACE_ROWS="${namespace_rows}"
    fi
  fi

  if ! STATUS_DBENGINE_ROWS="$(k_query -n "${EVEREST_DATABASE_NAMESPACE}" get dbengine --no-headers 2>/dev/null)"; then
    STATUS_DBENGINE_QUERY_OK=0
    STATUS_DBENGINE_ROWS=""
  fi

  if backup_enabled; then
    if ! STATUS_BACKUPSTORAGE_ROWS="$(k_query -n "${EVEREST_DATABASE_NAMESPACE}" get backupstorage --no-headers 2>/dev/null)"; then
      STATUS_BACKUPSTORAGE_QUERY_OK=0
      STATUS_BACKUPSTORAGE_ROWS=""
    fi
  fi
}

# Renders the namespace rows as a simple table body for the summary helper.
namespace_status_table() {
  printf 'NAME\tSTATUS\tAGE\n'
  if [ "${STATUS_NAMESPACE_QUERY_OK}" -eq 0 ]; then
    printf '%s\n' "Namespace status could not be queried within ${PLAYGROUND_QUERY_REQUEST_TIMEOUT}."
    return 0
  fi

  if [ -n "${STATUS_NAMESPACE_ROWS}" ]; then
    printf '%s\n' "${STATUS_NAMESPACE_ROWS}"
  fi
}

# Prints the DBaaS section, including database engine and backup storage status.
print_dbaas_status_section() {
  local backupstorage_lines=""

  print_summary_section "DBaaS"
  printf '  %b\n' "$(style_bold 1 "${EVEREST_DATABASE_NAMESPACE}")"
  print_summary_field "Expected engines" "$(style_bold 1 "$(managed_engine_display_list)")"

  if [ "${STATUS_DBENGINE_QUERY_OK}" -eq 0 ]; then
    print_summary_field "DatabaseEngine" "$(style_warning 1 "Unavailable within ${PLAYGROUND_QUERY_REQUEST_TIMEOUT}")"
  else
    if [ -n "${STATUS_DBENGINE_ROWS}" ]; then
      print_summary_multiline_field "DatabaseEngine" "${STATUS_DBENGINE_ROWS}"
    else
      print_summary_field "DatabaseEngine" "$(style_dim 1 'No DatabaseEngine resources found')"
    fi
  fi

  if backup_enabled; then
    print_summary_field "Backup bucket" "$(style_bold 1 "$(backup_bucket_for_namespace "${EVEREST_DATABASE_NAMESPACE}")")"
    if [ "${STATUS_BACKUPSTORAGE_QUERY_OK}" -eq 0 ]; then
      print_summary_field "BackupStorage" "$(style_warning 1 "Unavailable within ${PLAYGROUND_QUERY_REQUEST_TIMEOUT}")"
    else
      backupstorage_lines="$(printf '%s\n' "${STATUS_BACKUPSTORAGE_ROWS}" | awk -v name="${BACKUP_STORAGE_NAME}" '$1 == name')"
      if [ -n "${backupstorage_lines}" ]; then
        print_summary_multiline_field "BackupStorage" "${backupstorage_lines}"
      else
        print_summary_field "BackupStorage" "$(style_dim 1 'No BackupStorage resources found')"
      fi
    fi
  fi

  printf '\n'
}

# Falls back to a warning block when DBaaS details cannot be rendered safely.
print_dbaas_status_section_safe() {
  if print_dbaas_status_section; then
    return 0
  fi

  print_summary_section "DBaaS"
  print_summary_multiline_field \
    "Warning" \
    "$(style_warning 1 'DBaaS details could not be rendered from the current cluster state.')"
  printf '\n'
}

# Chooses the right status view for the current cluster lifecycle state.
render_status_report() {
  if ! cluster_listed; then
    print_status_overview "not-created"
    printf '\n'
    return 0
  fi

  collect_status_data

  if [ "${STATUS_CLUSTER_QUERY_OK}" -eq 0 ]; then
    print_status_overview "inactive"
    print_playground_access_summary
    return 0
  fi

  print_status_overview "running"
  print_topology_status_section
  print_summary_table "Nodes" "${STATUS_NODES_OUTPUT}"
  print_summary_table "Namespaces" "$(namespace_status_table)"
  print_dbaas_status_section_safe

  if backup_enabled; then
    print_summary_section "Backup"
    print_summary_field "Endpoint" "$(style_action 1 "$(seaweedfs_endpoint)")"
    print_summary_field "Credentials" "$(style_dim 1 'One shared access key pair reused across the shared DB namespace')"
  fi

  print_playground_access_summary
}

run_report_step "Querying playground status" render_status_report
