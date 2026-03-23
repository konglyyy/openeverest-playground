#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Runs the static validation suite over shell, Bats, YAML, and GitHub workflow
# files.
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/ci/common.sh"

cd "${ROOT_DIR}"

yamllint_config='{extends: default, rules: {document-start: disable, line-length: disable, truthy: disable}}'
shell_files=()
bats_files=()
yaml_files=()
workflow_files=()

ci_require_cmds shellcheck shfmt yamllint actionlint

while IFS= read -r file; do
  shell_files+=("${file}")
done < <(find scripts -type f \( -name '*.sh' -o -name '*.bash' \) | sort)

while IFS= read -r file; do
  bats_files+=("${file}")
done < <(find tests -type f -name '*.bats' 2>/dev/null | sort)

while IFS= read -r file; do
  yaml_files+=("${file}")
done < <(
  {
    find cluster helm manifests -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
    find . -maxdepth 1 -type f -name 'Taskfile.yml'
  } | sort
)

while IFS= read -r file; do
  workflow_files+=("${file}")
done < <(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)

if [ "${#shell_files[@]}" -gt 0 ]; then
  bash -n "${shell_files[@]}"
  shellcheck "${shell_files[@]}"
  shfmt -d -i 2 -ci -bn "${shell_files[@]}"
fi

if [ "${#bats_files[@]}" -gt 0 ]; then
  shfmt -ln bats -d -i 2 -ci -bn "${bats_files[@]}"
fi

./scripts/ci/check-comment-conventions.sh

if [ "${#yaml_files[@]}" -gt 0 ]; then
  yamllint -d "${yamllint_config}" "${yaml_files[@]}"
fi

if [ "${#workflow_files[@]}" -gt 0 ]; then
  actionlint "${workflow_files[@]}"
fi

printf '%s\n' "Lint checks passed."
