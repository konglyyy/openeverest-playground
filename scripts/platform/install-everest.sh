#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Installs or reconciles the configured Everest Helm chart in the cluster using
# the playground's committed values.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/common/lib.sh"

load_env

rendered_values="$(mktemp)"
trap 'rm -f "${rendered_values}"' EXIT

# Render the UI host into the ingress values so the printed URL and routed host stay aligned.
render_template \
  "${ROOT_DIR}/helm/values-everest.yaml" \
  -e "s|__EVEREST_UI_HOST__|${EVEREST_UI_HOST}|g" \
  >"${rendered_values}"

# Query the existing Helm release up front so reruns can distinguish a normal
# reconcile from a half-failed release that needs operator attention.
release_status="$(
  helm --kube-context "${KUBE_CONTEXT}" list --namespace "${EVEREST_NAMESPACE}" -o json \
    | jq -r '.[] | select(.name == "everest") | .status'
)"

if [ -n "${release_status}" ] && [ "${release_status}" != "deployed" ]; then
  die "Existing Helm release 'everest' is in status '${release_status}'. Resolve it or run task reset before retrying."
fi

if ! ensure_helm_repo; then
  die "Unable to prepare the Helm repo for ${EVEREST_HELM_CHART}."
fi

# Installs or reconciles the Everest release with the committed values file.
apply_everest_release() {
  local helm_args=(
    --namespace "${EVEREST_NAMESPACE}"
    --create-namespace
    --timeout 10m
    --wait
    --values "${rendered_values}"
    --set-string "server.initialAdminPassword=${EVEREST_ADMIN_PASSWORD}"
  )

  if [ -n "${EVEREST_HELM_CHART_VERSION}" ]; then
    helm_args+=(--version "${EVEREST_HELM_CHART_VERSION}")
  fi

  hctx upgrade --install everest "${EVEREST_HELM_CHART}" "${helm_args[@]}"
}

if [ "${release_status}" = "deployed" ]; then
  run_step \
    "Reconciling OpenEverest in ${EVEREST_NAMESPACE}" \
    "Reconciled OpenEverest in ${EVEREST_NAMESPACE}" \
    apply_everest_release \
    || die "Unable to install or reconcile the OpenEverest Helm release."
else
  run_step \
    "Installing OpenEverest in ${EVEREST_NAMESPACE}" \
    "Installed OpenEverest in ${EVEREST_NAMESPACE}." \
    apply_everest_release \
    || die "Unable to install or reconcile the OpenEverest Helm release."
fi
