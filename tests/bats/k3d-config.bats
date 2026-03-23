#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies the rendered k3d config always includes the Docker Hub cache proxy.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

@test "rendered k3d config enables the Docker Hub pull-through cache without unsupported registry fields" {
  playground_run '
    # Escapes path characters that would otherwise break a sed replacement.
    escape_for_sed() {
      printf "%s" "$1" | sed -e "s/[&|\\\\]/\\\\&/g"
    }

    rendered="$(render_template \
      "${PLAYGROUND_TEST_ROOT}/cluster/k3d-config.yaml" \
      -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
      -e "s|__K3D_SERVER_COUNT__|1|g" \
      -e "s|__K3D_AGENT_COUNT__|0|g" \
      -e "s|__EVEREST_UI_PORT__|${EVEREST_UI_PORT}|g" \
      -e "s|__SERVER_NODE_TAINT_ARG__|--node-taint=$(resolved_server_node_taint)|g" \
      -e "s|__SERVER_SYSTEM_RESERVED_ARG__|--kubelet-arg=system-reserved=$(kubelet_system_reserved_value_for_server)|g" \
      -e "s|__AGENT_SYSTEM_RESERVED_ARG__|--kubelet-arg=system-reserved=cpu=250m,memory=256Mi|g" \
      -e "s|__REGISTRY_CACHE_DIR__|$(escape_for_sed "${PLAYGROUND_REGISTRY_CACHE_DIR}")|g")"

    printf "%s\n" "${rendered}"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'registries:\n  create:\n    name: docker-io'* ]]
  [[ "${output}" == *$'proxy:\n      remoteURL: https://registry-1.docker.io'* ]]
  [[ "${output}" == *".cache/dockerhub-registry:/var/lib/registry"* ]]
  [[ "${output}" == *$'"docker.io":\n        endpoint:\n          - http://docker-io:5000'* ]]
  [[ "${output}" != *"deleteEnabled:"* ]]
}
