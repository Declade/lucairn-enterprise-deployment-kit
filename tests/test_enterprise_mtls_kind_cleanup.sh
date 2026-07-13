#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

FAKE_BIN="$TMPDIR/bin"
mkdir "$FAKE_BIN"
cat > "$FAKE_BIN/kind" <<'EOF'
#!/usr/bin/env bash
printf 'kind %s\n' "$*" >> "$CLEANUP_LOG"
if [ "${KIND_DELETE_FAIL:-0}" = 1 ]; then
  exit 41
fi
EOF
cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$CLEANUP_LOG"
EOF
chmod 700 "$FAKE_BIN/kind" "$FAKE_BIN/docker"

# shellcheck source=scripts/lib/enterprise-mtls-kind-cleanup.sh
source "$ROOT/scripts/lib/enterprise-mtls-kind-cleanup.sh"

run_cleanup() {
  local body_status="$1" delete_fail="$2" output="$3"
  local state="$TMPDIR/state-${body_status}-${delete_fail}"
  mkdir "$state"
  printf 'secret-bearing fixture\n' > "$state/runtime-values.yaml"
  CLEANUP_LOG="$TMPDIR/cleanup-${body_status}-${delete_fail}.log"
  : > "$CLEANUP_LOG"
  export CLEANUP_LOG KIND_DELETE_FAIL="$delete_fail"
  PATH="$FAKE_BIN:$PATH"
  CLUSTER="lucairn-enterprise-mtls-cleanup-fixture"
  CLUSTER_CREATED=1
  PROBE_IMAGE="local/enterprise-mtls-probe:fixture"
  STATE_DIR="$state"
  ENTERPRISE_MTLS_KIND_CLUSTER_DELETE_FAILED=0
  enterprise_mtls_kind_cleanup_helpers() {
    printf 'helper cleanup\n' >> "$CLEANUP_LOG"
  }

  set +e
  enterprise_mtls_kind_cleanup "$body_status" >"$output" 2>&1
  RUN_STATUS=$?
  set -e

  [ ! -e "$state" ] || { echo "cleanup retained local secret state" >&2; exit 1; }
  grep -Fqx 'helper cleanup' "$CLEANUP_LOG" || { echo "cleanup did not attempt helper removal" >&2; exit 1; }
  grep -Fqx 'kind delete cluster --name lucairn-enterprise-mtls-cleanup-fixture' "$CLEANUP_LOG" \
    || { echo "cleanup did not attempt owned cluster deletion" >&2; exit 1; }
  grep -Fqx 'docker image rm -f local/enterprise-mtls-probe:fixture' "$CLEANUP_LOG" \
    || { echo "cleanup did not attempt probe-image removal" >&2; exit 1; }
}

SUCCESS_OUTPUT="$TMPDIR/success.out"
run_cleanup 0 0 "$SUCCESS_OUTPUT"
[ "$RUN_STATUS" -eq 0 ] || { echo "successful body changed status after successful cleanup" >&2; exit 1; }
[ ! -s "$SUCCESS_OUTPUT" ] || { echo "successful cleanup should not claim retained state" >&2; exit 1; }

FAILURE_OUTPUT="$TMPDIR/body-failure.out"
run_cleanup 17 0 "$FAILURE_OUTPUT"
[ "$RUN_STATUS" -eq 17 ] || { echo "body failure did not retain its nonzero result" >&2; exit 1; }

DELETE_FAILURE_OUTPUT="$TMPDIR/delete-failure.out"
run_cleanup 0 1 "$DELETE_FAILURE_OUTPUT"
[ "$RUN_STATUS" -ne 0 ] || { echo "cluster deletion failure incorrectly returned success" >&2; exit 1; }
grep -Fqx 'ERROR: owned Kind cluster deletion failed for cluster lucairn-enterprise-mtls-cleanup-fixture' "$DELETE_FAILURE_OUTPUT" \
  || { echo "cluster deletion failure lacks its non-secret cluster notice" >&2; exit 1; }
grep -Fqx 'Retry: kind delete cluster --name lucairn-enterprise-mtls-cleanup-fixture' "$DELETE_FAILURE_OUTPUT" \
  || { echo "cluster deletion failure lacks its exact retry command" >&2; exit 1; }
[ "$(wc -l < "$DELETE_FAILURE_OUTPUT" | tr -d ' ')" = 2 ] \
  || { echo "cluster deletion failure emitted an unexpected teardown claim" >&2; exit 1; }
if grep -Fq "$TMPDIR" "$DELETE_FAILURE_OUTPUT"; then
  echo "cluster deletion failure leaked a local state path" >&2
  exit 1
fi

if rg -n -- '--keep|state retained|KEEP=' "$ROOT/scripts/test-enterprise-mtls-kind.sh"; then
  echo "Kind harness retains a public keep/state-retention path" >&2
  exit 1
fi

echo "enterprise mTLS Kind cleanup: success, body-failure, deletion-failure, and no-retention paths verified"
