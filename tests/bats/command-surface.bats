#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Verifies that the public Task command surface stays focused on the user-facing
# playground, mock-demo, and contributor CI entrypoints.
# -----------------------------------------------------------------------------

load 'helpers/playground.bash'

@test "root task list exposes the public playground, mock, and ci commands" {
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
  [[ "${output}" == *"mock:"* ]]
  [[ "${output}" == *"mock:app:"* ]]
  [[ "${output}" == *"mock:seed:"* ]]
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

@test "task mock prints the mock demo subcommand list" {
  run env \
    NO_COLOR=1 \
    bash -lc '
      cd "'"${PLAYGROUND_TEST_ROOT}"'"
      task mock
    '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Available mock demo commands"* ]]
  [[ "${output}" == *"mock:seed:"* ]]
  [[ "${output}" == *"mock:app:"* ]]
}
