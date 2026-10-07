#!/usr/bin/env bash
set -uo pipefail

passed=0
failed=()
for test_file in "$@"; do
  printf '\n==> %s\n' "$test_file"
  if bash "$test_file"; then
    passed=$((passed + 1))
    printf 'PASS: %s\n' "$test_file"
  else
    status=$?
    failed+=("$test_file")
    printf 'FAIL: %s (exit %s)\n' "$test_file" "$status"
  fi
done

printf '\nTest files: %s passed, %s failed\n' "$passed" "${#failed[@]}"
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'Failed test files:\n'
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
