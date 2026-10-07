#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REAL_BASH="$(command -v bash)"
export REAL_BASH

fail() { echo "test runner: FAIL — $*" >&2; exit 1; }

# Exercise the real Makefile with fixture test files, without running the kit.
# The runner itself stays real; only its child test invocations are replaced.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/bash" <<'STUB'
#!/bin/bash
if [ "$1" = scripts/run-tests.sh ]; then
  exec "$REAL_BASH" "$@"
fi
printf '%s\n' "$1" >>"$RUNNER_CALLS"
printf 'fixture output: %s\n' "$1"
printf 'fixture stderr: %s\n' "$1" >&2
case " $RUNNER_FAILURES " in
  *" $1 "*) exit 7 ;;
esac
STUB
chmod +x "$WORK/bin/bash"

export RUNNER_CALLS="$WORK/calls" RUNNER_FAILURES=""
run_make() {
  : >"$RUNNER_CALLS"
  if PATH="$WORK/bin:$PATH" env -u MAKEFLAGS -u MFLAGS make --no-print-directory -s -C "$ROOT" test >"$WORK/output" 2>&1; then
    result=0
  else
    result=$?
  fi
}

# Compare all-green execution with the recipe roster and prerequisites.
run_make
[ "$result" -eq 0 ] || fail "all-green tests failed"
awk '
  /^test:/{active=1; next}
  active && /^$/{exit}
  active {for (i=1; i<=NF; i++) if ($i ~ /^(tests|servicenow)\/.*\.sh$/) print $i}
' "$ROOT/Makefile" >"$WORK/recipe"
printf '%s\n' tests/test_enterprise_mtls_helm.sh tests/test_wp1_s4_helm_boundary.sh \
  tests/test_enterprise_mtls_helm_required.sh tests/test_enterprise_mtls_production_values.sh >"$WORK/prerequisites"
cat "$WORK/prerequisites" "$WORK/recipe" >"$WORK/expected"
cmp -s "$WORK/expected" "$RUNNER_CALLS" || fail "all-green roster or prerequisite order changed"

RUNNER_FAILURES='tests/test_lucairn_cli.sh tests/test_evidence_cli.sh'
run_make
[ "$result" -ne 0 ] || fail "failed tests returned success"
cmp -s "$WORK/expected" "$RUNNER_CALLS" || fail "a failure hid later tests or changed their order"
grep -Fxq 'Failed test files:' "$WORK/output" || fail "missing failure summary"
for script in $RUNNER_FAILURES; do
  grep -Fxq "  $script" "$WORK/output" || fail "summary missing $script"
done
[ "$(grep -c '^  .*\.sh$' "$WORK/output")" -eq 2 ] || fail "summary lists successful tests"
grep -Fxq 'fixture output: tests/static_checks.sh' "$WORK/output" || fail "last test output lost"
grep -Fxq 'fixture stderr: tests/static_checks.sh' "$WORK/output" || fail "last test stderr lost"

RUNNER_FAILURES='tests/test_enterprise_mtls_helm.sh'
run_make
[ "$result" -ne 0 ] || fail "prerequisite failure returned success"
! grep -Fxq tests/test_lucairn_cli.sh "$RUNNER_CALLS" || fail "recipe ran after failed prerequisite"

# An empty roster must fail instead of reporting a successful run.
if bash "$ROOT/scripts/run-tests.sh" >"$WORK/empty.out" 2>"$WORK/empty.err"; then
  result=0
else
  result=$?
fi
[ "$result" -eq 2 ] || fail "empty roster did not exit 2"
[ ! -s "$WORK/empty.out" ] || fail "empty roster wrote to stdout"
printf 'No test files were given.\n' >"$WORK/empty.expected"
cmp -s "$WORK/empty.expected" "$WORK/empty.err" || fail "empty roster diagnostic changed"

echo "test runner: PASS (all green, ordered continuation, failure summary, prerequisites, empty roster)"
