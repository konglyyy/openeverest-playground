#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies that the public Task command surface stays focused on user-facing
# playground commands and the contributor CI entrypoint.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

@test "root task list exposes only top-level playground and ci commands" {
  run env \
    NO_COLOR=1 \
    bash -lc '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      task --list
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"doctor:"* ]]
  [[ "${output}" == *"ci:"* ]]
  [[ "${output}" == *"down:"* ]]
  [[ "${output}" == *"help:"* ]]
  [[ "${output}" == *"init:"* ]]
  [[ "${output}" == *"logs:"* ]]
  [[ "${output}" == *"reset:"* ]]
  [[ "${output}" == *"reset:full:"* ]]
  [[ "${output}" == *"status:"* ]]
  [[ "${output}" == *"up:"* ]]
  [[ "${output}" != *"ci:all:"* ]]
  [[ "${output}" != *"ci:bootstrap:"* ]]
  [[ "${output}" != *"ci:lint:"* ]]
  [[ "${output}" != *"ci:test:"* ]]
  [[ "${output}" != *"ci:smoke:minimal:"* ]]
  [[ "${output}" != *"init:apply:"* ]]
  [[ "${output}" != *"password:"* ]]
  [[ "${output}" != *"default:"* ]]
}

@test "task ci prints the contributor subcommand list" {
  run env \
    NO_COLOR=1 \
    bash -lc '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      task ci
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Available CI commands"* ]]
  [[ "${output}" == *"ci:all:"* ]]
  [[ "${output}" == *"ci:bootstrap:"* ]]
  [[ "${output}" == *"ci:lint:"* ]]
  [[ "${output}" == *"ci:test:"* ]]
  [[ "${output}" == *"ci:smoke:minimal:"* ]]
}
