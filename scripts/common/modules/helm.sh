#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared Helm and template-rendering helpers.
# -----------------------------------------------------------------------------

# Checks whether the configured Everest Helm repo is already present locally.
helm_repo_configured() {
  load_env
  helm repo list -o json | jq -e --arg repo_name "${EVEREST_HELM_REPO_NAME}" '.[] | select(.name == $repo_name)' >/dev/null
}

# Returns the configured pinned version for a known chart, if any.
helm_chart_version_for() {
  local chart="$1"

  load_env
  case "${chart}" in
    "${EVEREST_HELM_CHART}")
      printf '%s\n' "${EVEREST_HELM_CHART_VERSION}"
      ;;
    "${EVEREST_DB_NAMESPACE_CHART}")
      printf '%s\n' "${EVEREST_DB_NAMESPACE_CHART_VERSION}"
      ;;
  esac
}

# Verifies that Helm can resolve a specific chart reference without installing it.
helm_chart_resolvable() {
  local chart="$1"
  local chart_version=""

  load_env
  chart_version="$(helm_chart_version_for "${chart}")"

  if [ -n "${chart_version}" ]; then
    helm show chart "${chart}" --version "${chart_version}" >/dev/null 2>&1
  else
    helm show chart "${chart}" >/dev/null 2>&1
  fi
}

# Decides whether the cached Helm repo metadata is stale enough to refresh.
helm_repo_refresh_needed() {
  local now
  local last_refresh
  local age_seconds

  load_env
  ensure_state_dir

  if [ "${FORCE_HELM_REPO_UPDATE:-0}" = "1" ]; then
    return 0
  fi

  if ! helm_repo_configured; then
    return 0
  fi

  if ! helm_chart_resolvable "${EVEREST_HELM_CHART}"; then
    return 0
  fi

  if [ ! -f "${HELM_REPO_REFRESH_MARKER}" ]; then
    return 0
  fi

  now="$(date +%s)"
  last_refresh="$(file_mtime "${HELM_REPO_REFRESH_MARKER}")"
  age_seconds=$((now - last_refresh))

  [ "${age_seconds}" -ge "${HELM_REPO_REFRESH_TTL_SECONDS}" ]
}

# Updates the refresh marker after a successful Helm repo update.
mark_helm_repo_refreshed() {
  load_env
  ensure_state_dir
  touch "${HELM_REPO_REFRESH_MARKER}"
}

# Adds the OpenEverest repo once and only performs a full metadata refresh when the
# local cache is absent, stale, or explicitly forced.
ensure_helm_repo() {
  load_env
  ensure_state_dir

  # Add the repo once, then reuse the local Helm repo config on later runs.
  if ! helm_repo_configured; then
    run_step \
      "Adding Helm repo ${EVEREST_HELM_REPO_NAME}" \
      "Added Helm repo ${EVEREST_HELM_REPO_NAME}" \
      helm repo add "${EVEREST_HELM_REPO_NAME}" "${EVEREST_HELM_REPO_URL}" \
      || return 1
    mark_helm_repo_refreshed
  fi

  # The full repo refresh is the slow path, so only do it when the local cache
  # is missing, stale, or explicitly forced.
  if helm_repo_refresh_needed; then
    run_step \
      "Refreshing Helm repo metadata for ${EVEREST_HELM_CHART}" \
      "Refreshed Helm repo metadata for ${EVEREST_HELM_CHART}." \
      helm repo update "${EVEREST_HELM_REPO_NAME}" \
      || return 1
    mark_helm_repo_refreshed
  fi
}

# Renders a committed template file using a caller-supplied set of `sed`
# substitutions so manifests stay readable in the repo.
render_template() {
  local template="$1"
  shift

  sed "$@" "${template}"
}
