#!/usr/bin/env bash
set -euo pipefail

# The Helm contract is mandatory. Exercise the exact Make prerequisite under a
# deliberately minimal PATH that has bash, make, and the shell utilities used
# by the contract test but no helm binary. Do not call `make test` here: this
# regression itself is part of that target.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
NO_HELM_PATH="$TMPDIR/no-helm-bin"
mkdir -p "$NO_HELM_PATH"

for command in bash make dirname mktemp rm; do
  command_path="$(command -v "$command")"
  ln -s "$command_path" "$NO_HELM_PATH/$command"
done

assert_helm_required() {
  local description="$1"
  shift
  local output="$TMPDIR/${description}.out"

  if PATH="$NO_HELM_PATH" "$@" >"$output" 2>&1; then
    echo "Helm-required regression unexpectedly passed: $description" >&2
    exit 1
  fi
  grep -Fq 'enterprise mTLS Helm contract: ERROR — Helm CLI is required' "$output" \
    || { echo "Helm-required regression lacked the actionable error: $description" >&2; cat "$output" >&2; exit 1; }
}

assert_helm_required mandatory-contract-test bash "$ROOT/tests/test_enterprise_mtls_helm.sh"
assert_helm_required make-test-prerequisite make -s -C "$ROOT" test-enterprise-mtls-helm

# `test-enterprise-mtls-helm` is a direct prerequisite of `test`, so the
# second failure is the bounded proof that `make test` fails before later
# tests can turn an unavailable Helm CLI into a successful suite.
if ! make -n -C "$ROOT" test | head -n 1 | grep -Fxq 'bash tests/test_enterprise_mtls_helm.sh'; then
  echo "make test no longer starts with the mandatory Helm contract prerequisite" >&2
  exit 1
fi

echo "enterprise mTLS Helm absence regression: contract and make-test path fail"
