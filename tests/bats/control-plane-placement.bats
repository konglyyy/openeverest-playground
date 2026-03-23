#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies the control-plane placement reconciliation flow.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

# Creates isolated stub state for each control-plane placement test.
setup() {
  CONTROL_PLANE_STUB_BIN="$(mktemp -d)"
  CONTROL_PLANE_TAINT_LOG="${BATS_TEST_TMPDIR}/control-plane-taint.log"
}

# Removes the temporary files created for each control-plane placement test.
teardown() {
  rm -rf "${CONTROL_PLANE_STUB_BIN}"
  rm -f "${CONTROL_PLANE_TAINT_LOG}"
}

# Writes one executable command stub into the per-test bin directory.
write_stub() {
  local name="$1"
  local body="$2"

  cat >"${CONTROL_PLANE_STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${CONTROL_PLANE_STUB_BIN}/${name}"
}

@test "control-plane placement taints the control-plane node with the expected kubectl form" {
  write_stub "kubectl" '
joined=" $* "

if [[ "${joined}" == *" get namespace "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" -n everest-databases get deployment -l olm.owner.kind=ClusterServiceVersion -o name "* ]]; then
  printf "%s\n" "deployment.apps/db-operator"
  exit 0
fi

if [[ "${joined}" == *" get deployment "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" get nodes -l node-role.kubernetes.io/control-plane -o name "* ]]; then
  printf "%s\n" "node/k3d-openeverest-playground-server-0"
  exit 0
fi

if [[ "${joined}" == *" taint "* ]]; then
  printf "%s\n" "$*" >>"'"${CONTROL_PLANE_TAINT_LOG}"'"
  if [[ "${joined}" == *" taint node/"* ]]; then
    printf "%s\n" "taint should use a bare node name" >&2
    exit 1
  fi
  if [[ "${joined}" != *" taint nodes k3d-openeverest-playground-server-0 "* ]]; then
    printf "%s\n" "taint should target the node resource before the node name" >&2
    exit 1
  fi
  exit 0
fi

if [[ "${joined}" == *" patch "* ]]; then
  exit 0
fi

exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PATH="${CONTROL_PLANE_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/platform/reconcile-control-plane-placement.sh
    '

  [ "${status}" -eq 0 ]
  grep -Fq "taint nodes k3d-openeverest-playground-server-0 node-role.kubernetes.io/master:NoSchedule --overwrite" "${CONTROL_PLANE_TAINT_LOG}"
}
