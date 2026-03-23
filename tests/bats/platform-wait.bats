#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies that platform bring-up fails fast on terminal workload states.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

# Creates isolated stub bins and call-tracking files for each wait-path test.
setup() {
  PLATFORM_WAIT_STUB_BIN="$(mktemp -d)"
  PLATFORM_WAIT_STATE_DIR="$(mktemp -d)"
}

# Removes the temporary stub state created for each test.
teardown() {
  rm -rf "${PLATFORM_WAIT_STUB_BIN}" "${PLATFORM_WAIT_STATE_DIR}"
}

# Writes one executable command stub into the per-test bin directory.
write_stub() {
  local name="$1"
  local body="$2"

  cat >"${PLATFORM_WAIT_STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF
  chmod +x "${PLATFORM_WAIT_STUB_BIN}/${name}"
}

@test "platform wait fails fast when a namespace pod enters ImagePullBackOff" {
  write_stub "kubectl" '
joined=" $* "

if [[ "${joined}" == *" get namespace "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" wait --for=condition=Established "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" -n everest-system get pods -o json "* ]]; then
  cat <<'"'"'EOF'"'"'
{"items":[{"metadata":{"name":"everest-ui"},"status":{"phase":"Pending","conditions":[{"type":"Ready","status":"False"}],"containerStatuses":[{"name":"ui","state":{"waiting":{"reason":"ImagePullBackOff"}}}]}}]}
EOF
  exit 0
fi

if [[ "${joined}" == *" -n everest-system get jobs -o json "* ]]; then
  printf "%s\n" "{\"items\":[]}"
  exit 0
fi

printf "%s\n" "unexpected kubectl call: $*" >&2
exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_NO_SPINNER=true \
    PATH="${PLATFORM_WAIT_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/platform/wait.sh install
    '

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"terminal workload failure in everest-system"* ]]
  [[ "${output}" == *"ImagePullBackOff"* ]]
}

@test "engine discovery fails fast when a DB operator pod enters CrashLoopBackOff" {
  local db_pod_call_file="${PLATFORM_WAIT_STATE_DIR}/db-pod-calls.txt"

  write_stub "kubectl" '
joined=" $* "

# Emits one Ready pod payload so the script can advance to engine discovery.
ready_pods_json() {
  cat <<'"'"'EOF'"'"'
{"items":[{"metadata":{"name":"ready-pod"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[{"name":"main","ready":true,"state":{"running":{"startedAt":"2026-01-01T00:00:00Z"}}}]}}]}
EOF
}

if [[ "${joined}" == *" get namespace "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" wait --for=condition=Established "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" -n everest-system get pods -o json "* ]] || [[ "${joined}" == *" -n everest-olm get pods -o json "* ]] || [[ "${joined}" == *" -n everest-monitoring get pods -o json "* ]]; then
  ready_pods_json
  exit 0
fi

if [[ "${joined}" == *" -n everest-databases get pods -o json "* ]]; then
  ready_pods_json
  exit 0
fi

if [[ "${joined}" == *" get jobs -o json "* ]]; then
  printf "%s\n" "{\"items\":[]}"
  exit 0
fi

if [[ "${joined}" == *" -n everest-databases get pods -l app.kubernetes.io/component=operator -o json "* ]]; then
  count=0
  if [ -f "'"${db_pod_call_file}"'" ]; then
    count="$(cat "'"${db_pod_call_file}"'")"
  fi
  count=$((count + 1))
  printf "%s" "${count}" >"'"${db_pod_call_file}"'"

  if [ "${count}" -eq 1 ]; then
    ready_pods_json
  else
    cat <<'"'"'EOF'"'"'
{"items":[{"metadata":{"name":"postgres-operator"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"False"}],"containerStatuses":[{"name":"operator","ready":false,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}
EOF
  fi
  exit 0
fi

if [[ "${joined}" == *" -n everest-databases get dbengine -o json "* ]]; then
  printf "%s\n" "{\"items\":[]}"
  exit 0
fi

printf "%s\n" "unexpected kubectl call: $*" >&2
exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_NO_SPINNER=true \
    PATH="${PLATFORM_WAIT_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/platform/wait.sh install
    '

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"terminal database engine discovery failure"* ]]
  [[ "${output}" == *"CrashLoopBackOff"* ]]
}

@test "resume wait ignores unhealthy user database pods and waits only for DB operator control-plane pods" {
  write_stub "kubectl" '
joined=" $* "

# Emits one Ready pod payload so resume can advance past the control-plane checks.
ready_pods_json() {
  cat <<'"'"'EOF'"'"'
{"items":[{"metadata":{"name":"ready-pod"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[{"name":"main","ready":true,"state":{"running":{"startedAt":"2026-01-01T00:00:00Z"}}}]}}]}
EOF
}

if [[ "${joined}" == *" get namespace "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" wait --for=condition=Established "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" -n everest-system get pods -o json "* ]] || [[ "${joined}" == *" -n everest-olm get pods -o json "* ]] || [[ "${joined}" == *" -n everest-monitoring get pods -o json "* ]]; then
  ready_pods_json
  exit 0
fi

if [[ "${joined}" == *" -n everest-databases get pods -l app.kubernetes.io/component=operator -o json "* ]]; then
  ready_pods_json
  exit 0
fi

if [[ "${joined}" == *" -n everest-databases get pods -o json "* ]]; then
  printf "%s\n" "resume should not gate on all pods in everest-databases" >&2
  exit 1
fi

if [[ "${joined}" == *" -n everest-databases get dbengine -o json "* ]]; then
  cat <<'"'"'EOF'"'"'
{"items":[
  {"metadata":{"name":"postgresql"},"spec":{"type":"postgresql"},"status":{"status":"installed","availableVersions":{"engine":{"17.7":{"imagePath":"docker.io/percona/percona-distribution-postgresql:17.7-2"}}}}},
  {"metadata":{"name":"pxc"},"spec":{"type":"pxc"},"status":{"status":"installed","availableVersions":{"engine":{"8.4":{"imagePath":"docker.io/percona/percona-xtradb-cluster-operator:1.16.1"}}}}},
  {"metadata":{"name":"psmdb"},"spec":{"type":"psmdb"},"status":{"status":"installed","availableVersions":{"engine":{"8.0":{"imagePath":"docker.io/percona/percona-server-mongodb-operator:1.20.1"}}}}}
]}
EOF
  exit 0
fi

printf "%s\n" "unexpected kubectl call: $*" >&2
exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_NO_SPINNER=true \
    PATH="${PLATFORM_WAIT_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/platform/wait.sh resume
    '

  [ "${status}" -eq 0 ]
}

@test "backup stack fails fast when the bucket init job reports Failed" {
  write_stub "openssl" '
keyout=""
certout=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -keyout)
      keyout="$2"
      shift 2
      ;;
    -out)
      certout="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

: >"${keyout}"
: >"${certout}"
'

  write_stub "kubectl" '
joined=" $* "

if [[ "${joined}" == *" get namespace "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" create secret tls "* ]] && [[ "${joined}" == *" --dry-run=client "* ]]; then
  cat <<'"'"'EOF'"'"'
apiVersion: v1
kind: Secret
metadata:
  name: seaweedfs-s3-tls
EOF
  exit 0
fi

if [[ "${joined}" == *" apply --validate=false -f "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" rollout status deployment/seaweedfs "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" delete job seaweedfs-bucket-init "* ]]; then
  exit 0
fi

if [[ "${joined}" == *" get job seaweedfs-bucket-init -n playground-system -o json "* ]]; then
  cat <<'"'"'EOF'"'"'
{"status":{"conditions":[{"type":"Failed","status":"True"}],"failed":1},"spec":{"backoffLimit":0}}
EOF
  exit 0
fi

printf "%s\n" "unexpected kubectl call: $*" >&2
exit 1
'

  run env \
    NO_COLOR=1 \
    PLAYGROUND_ENV_FILE="/tmp/nonexistent-playground.env" \
    PLAYGROUND_NO_SPINNER=true \
    ENABLE_BACKUP=true \
    PATH="${PLATFORM_WAIT_STUB_BIN}:${PATH}" \
    bash -c '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      ./scripts/platform/install-backup-stack.sh
    '

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"terminal backup bucket initialization failure"* ]]
  [[ "${output}" == *"failed Job condition"* ]]
}
