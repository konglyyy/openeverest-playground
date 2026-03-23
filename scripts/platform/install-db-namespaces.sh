#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Provisions the shared DBaaS namespace that Everest exposes in the UI.
# All three operators are installed in one namespace to keep the playground
# model simple while preserving multi-engine coverage.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env

if legacy_db_namespace_layout_present; then
  die "This cluster still has the older multi-namespace DB layout. Run 'task reset' once so it can be recreated with the shared ${EVEREST_DATABASE_NAMESPACE} namespace."
fi

rendered_guardrails="$(mktemp)"
trap 'rm -f "${rendered_guardrails}"' EXIT

# Returns the shared namespace guardrail settings derived from the planned worker pool.
guardrail_settings() {
  cat <<'EOF'
default_container_request_cpu=25m
default_container_request_memory=64Mi
default_container_limit_cpu=100m
default_container_limit_memory=128Mi
requests_cpu=__REQUESTS_CPU__
limits_cpu=__LIMITS_CPU__
requests_memory=__REQUESTS_MEMORY__
limits_memory=__LIMITS_MEMORY__
requests_storage=100Gi
EOF
}

# Installs or upgrades the shared Everest DB namespace release with all engines enabled.
install_namespace_release() {
  local helm_args=(
    --namespace "${EVEREST_DATABASE_NAMESPACE}"
    --create-namespace
    --timeout 10m
    --wait
    --set "postgresql=true"
    --set "pxc=true"
    --set "psmdb=true"
  )

  if [ -n "${EVEREST_DB_NAMESPACE_CHART_VERSION}" ]; then
    helm_args+=(--version "${EVEREST_DB_NAMESPACE_CHART_VERSION}")
  fi

  run_quiet hctx upgrade --install "$(db_namespace_release_name)" "${EVEREST_DB_NAMESPACE_CHART}" "${helm_args[@]}"
}

# Renders the shared namespace LimitRange and ResourceQuota from the planned pool.
render_namespace_guardrails() {
  local settings=""
  local default_container_request_cpu=""
  local default_container_request_memory=""
  local default_container_limit_cpu=""
  local default_container_limit_memory=""
  local requests_cpu=""
  local limits_cpu=""
  local requests_memory=""
  local limits_memory=""
  local requests_storage=""
  local guardrail_cpu=""
  local guardrail_memory=""

  # Resolve the sizing plan once in this shell so repeated substitutions reuse
  # the cached worker layout instead of re-running the planner in subshells.
  load_resolved_worker_layout
  guardrail_cpu="$(namespace_guardrail_cpu_quantity)"
  guardrail_memory="$(namespace_guardrail_memory_quantity)"

  settings="$(guardrail_settings \
    | sed \
      -e "s|__REQUESTS_CPU__|${guardrail_cpu}|g" \
      -e "s|__LIMITS_CPU__|${guardrail_cpu}|g" \
      -e "s|__REQUESTS_MEMORY__|${guardrail_memory}|g" \
      -e "s|__LIMITS_MEMORY__|${guardrail_memory}|g")"

  # shellcheck disable=SC2086
  eval "${settings}"

  render_template \
    "${ROOT_DIR}/manifests/db-namespace/guardrails.yaml" \
    -e "s|__DB_NAMESPACE__|${EVEREST_DATABASE_NAMESPACE}|g" \
    -e "s|__DEFAULT_CONTAINER_REQUEST_CPU__|${default_container_request_cpu}|g" \
    -e "s|__DEFAULT_CONTAINER_REQUEST_MEMORY__|${default_container_request_memory}|g" \
    -e "s|__DEFAULT_CONTAINER_LIMIT_CPU__|${default_container_limit_cpu}|g" \
    -e "s|__DEFAULT_CONTAINER_LIMIT_MEMORY__|${default_container_limit_memory}|g" \
    -e "s|__REQUESTS_CPU__|${requests_cpu}|g" \
    -e "s|__LIMITS_CPU__|${limits_cpu}|g" \
    -e "s|__REQUESTS_MEMORY__|${requests_memory}|g" \
    -e "s|__LIMITS_MEMORY__|${limits_memory}|g" \
    -e "s|__REQUESTS_STORAGE__|${requests_storage}|g" \
    >"${rendered_guardrails}"
}

# Applies the rendered namespace guardrails to the shared DB namespace.
reconcile_namespace_guardrails() {
  ensure_namespace "${EVEREST_DATABASE_NAMESPACE}"
  render_namespace_guardrails
  k apply --validate=false -f "${rendered_guardrails}" >/dev/null
}

run_step \
  "Reconciling the shared DBaaS namespace and engine operators" \
  "Reconciled the shared DBaaS namespace and engine operators." \
  install_namespace_release \
  || die "Unable to reconcile the shared DBaaS namespace layout."

run_step \
  "Applying shared DB namespace guardrails" \
  "Applied shared DB namespace guardrails." \
  reconcile_namespace_guardrails \
  || die "Unable to apply the shared DB namespace guardrails."
