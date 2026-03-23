#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Verifies that shell and Bats files start with a purpose comment and that each
# function definition is preceded by a short comment describing its role.
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck disable=SC2016
comment_check_awk='
  function report(message) {
    printf "%s:%s: %s\n", file, NR, message
    failed = 1
  }

  BEGIN {
    failed = 0
    header_checked = 0
    previous_nonblank = ""
  }

  {
    trimmed = $0
    sub(/^[[:space:]]+/, "", trimmed)

    if (!header_checked) {
      if (NR == 1 && trimmed ~ /^#!/) {
        next
      }

      if (trimmed == "") {
        next
      }

      header_checked = 1
      if (trimmed !~ /^#/) {
        report("missing top-of-file purpose comment")
      }
    }

    if ($0 ~ /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{.*$/) {
      function_name = $0
      sub(/^[[:space:]]*(function[[:space:]]+)?/, "", function_name)
      sub(/[[:space:]]*\(\)[[:space:]]*\{.*/, "", function_name)

      if (previous_nonblank !~ /^[[:space:]]*#/) {
        report("missing comment for function " function_name)
      }
    }

    if (trimmed != "") {
      previous_nonblank = $0
    }
  }

  END {
    exit failed
  }
'

cd "${ROOT_DIR}"

files=()
while IFS= read -r file; do
  files+=("${file}")
done < <(find scripts tests -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.bats" \) | sort)

if [ "${#files[@]}" -eq 0 ]; then
  printf '%s\n' "No shell or Bats files found."
  exit 0
fi

status=0
for file in "${files[@]}"; do
  if ! awk -v file="${file}" "${comment_check_awk}" "${file}"; then
    status=1
  fi
done

if [ "${status}" -ne 0 ]; then
  exit "${status}"
fi

printf '%s\n' "Comment convention checks passed."
