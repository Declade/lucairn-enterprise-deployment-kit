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
case "$1 $2" in
  "delete cluster")
    [ "${KIND_DELETE_FAIL:-0}" != 1 ] || exit 41
    ;;
  "get clusters")
    printf '%s\n' "${KIND_CLUSTER_LIST:-}"
    ;;
esac
EOF
cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$CLEANUP_LOG"
EOF
cat > "$FAKE_BIN/rm" <<'EOF'
#!/usr/bin/env bash
target="${!#}"
if [ "${RM_STATE_DELETE_FAIL:-0}" = 1 ] && [[ "$target" == */state-* ]]; then
  exit 42
fi
exec /bin/rm "$@"
EOF
chmod 700 "$FAKE_BIN/kind" "$FAKE_BIN/docker" "$FAKE_BIN/rm"

# shellcheck source=scripts/lib/enterprise-mtls-kind-cleanup.sh
source "$ROOT/scripts/lib/enterprise-mtls-kind-cleanup.sh"

run_cleanup() {
  local body_status="$1" delete_fail="$2" cluster_list="$3" creation_attempted="$4" state_delete_fail="$5" output="$6"
  local state="$TMPDIR/state-${body_status}-${delete_fail}-${creation_attempted}-${state_delete_fail}"
  mkdir "$state"
  printf 'secret-bearing fixture\n' > "$state/runtime-values.yaml"
  CLEANUP_LOG="$TMPDIR/cleanup-${body_status}-${delete_fail}.log"
  : > "$CLEANUP_LOG"
  export CLEANUP_LOG KIND_DELETE_FAIL="$delete_fail" KIND_CLUSTER_LIST="$cluster_list" RM_STATE_DELETE_FAIL="$state_delete_fail"
  PATH="$FAKE_BIN:$PATH"
  CLUSTER="lucairn-enterprise-mtls-cleanup-fixture"
  CLUSTER_CREATION_ATTEMPTED="$creation_attempted"
  PROBE_IMAGE="local/enterprise-mtls-probe:fixture"
  export STATE_DIR="$state"
  ENTERPRISE_MTLS_KIND_CLUSTER_DELETE_FAILED=0
  ENTERPRISE_MTLS_KIND_STATE_DELETE_FAILED=0
  enterprise_mtls_kind_cleanup_helpers() {
    printf 'helper cleanup\n' >> "$CLEANUP_LOG"
  }

  set +e
  enterprise_mtls_kind_cleanup "$body_status" >"$output" 2>&1
  RUN_STATUS=$?
  set -e

  if [ "$state_delete_fail" = 1 ]; then
    [ -e "$state" ] || { echo "state-deletion failure did not preserve its test fixture" >&2; exit 1; }
    /bin/rm -rf "$state"
  else
    [ ! -e "$state" ] || { echo "cleanup retained local secret state" >&2; exit 1; }
  fi
  grep -Fqx 'helper cleanup' "$CLEANUP_LOG" || { echo "cleanup did not attempt helper removal" >&2; exit 1; }
  grep -Fqx 'kind delete cluster --name lucairn-enterprise-mtls-cleanup-fixture' "$CLEANUP_LOG" \
    || { echo "cleanup did not attempt owned cluster deletion" >&2; exit 1; }
  grep -Fqx 'docker image rm -f local/enterprise-mtls-probe:fixture' "$CLEANUP_LOG" \
    || { echo "cleanup did not attempt probe-image removal" >&2; exit 1; }
}

SUCCESS_OUTPUT="$TMPDIR/success.out"
run_cleanup 0 0 lucairn-enterprise-mtls-cleanup-fixture 1 0 "$SUCCESS_OUTPUT"
[ "$RUN_STATUS" -eq 0 ] || { echo "successful body changed status after successful cleanup" >&2; exit 1; }
[ ! -s "$SUCCESS_OUTPUT" ] || { echo "successful cleanup should not claim retained state" >&2; exit 1; }

FAILURE_OUTPUT="$TMPDIR/body-failure.out"
run_cleanup 17 0 lucairn-enterprise-mtls-cleanup-fixture 1 0 "$FAILURE_OUTPUT"
[ "$RUN_STATUS" -eq 17 ] || { echo "body failure did not retain its nonzero result" >&2; exit 1; }

DELETE_FAILURE_OUTPUT="$TMPDIR/delete-failure.out"
run_cleanup 0 1 lucairn-enterprise-mtls-cleanup-fixture 1 0 "$DELETE_FAILURE_OUTPUT"
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

BODY_AND_CLUSTER_FAILURE_OUTPUT="$TMPDIR/body-and-cluster-delete-failure.out"
run_cleanup 17 1 lucairn-enterprise-mtls-cleanup-fixture 1 0 "$BODY_AND_CLUSTER_FAILURE_OUTPUT"
[ "$RUN_STATUS" -eq 17 ] || { echo "cluster deletion failure replaced an existing body failure" >&2; exit 1; }
[ "$ENTERPRISE_MTLS_KIND_CLUSTER_DELETE_FAILED" -eq 1 ] || { echo "combined body/cluster failure was not tracked" >&2; exit 1; }

# A failed `kind create cluster --wait` can leave resources behind after the
# creation attempt is recorded but before the command returns successfully.
# Cleanup must still attempt deletion and preserve the create/wait failure
# status when that delete succeeds.
CREATE_WAIT_FAILURE_OUTPUT="$TMPDIR/create-wait-failure.out"
run_cleanup 23 0 lucairn-enterprise-mtls-cleanup-fixture 1 0 "$CREATE_WAIT_FAILURE_OUTPUT"
[ "$RUN_STATUS" -eq 23 ] || { echo "create/wait failure did not retain its nonzero result after attempted-cluster cleanup" >&2; exit 1; }
[ ! -s "$CREATE_WAIT_FAILURE_OUTPUT" ] || { echo "create/wait cleanup incorrectly claimed retained state" >&2; exit 1; }

# A partial create can also leave no cluster at all. Kind reports that delete
# as nonzero, but an exact absent-cluster probe makes this benign.
ABSENT_CLUSTER_OUTPUT="$TMPDIR/absent-cluster.out"
run_cleanup 0 1 '' 1 0 "$ABSENT_CLUSTER_OUTPUT"
[ "$RUN_STATUS" -eq 0 ] || { echo "absent attempted cluster incorrectly changed the result" >&2; exit 1; }
[ ! -s "$ABSENT_CLUSTER_OUTPUT" ] || { echo "absent attempted cluster incorrectly claimed retained state" >&2; exit 1; }

STATE_DELETE_FAILURE_OUTPUT="$TMPDIR/state-delete-failure.out"
run_cleanup 0 0 lucairn-enterprise-mtls-cleanup-fixture 1 1 "$STATE_DELETE_FAILURE_OUTPUT"
[ "$RUN_STATUS" -ne 0 ] || { echo "private-state deletion failure incorrectly returned success" >&2; exit 1; }
[ "$ENTERPRISE_MTLS_KIND_STATE_DELETE_FAILED" -eq 1 ] || { echo "private-state deletion failure was not tracked" >&2; exit 1; }
grep -Fqx 'ERROR: private Kind harness state deletion failed' "$STATE_DELETE_FAILURE_OUTPUT" \
  || { echo "private-state deletion failure lacks its path-safe notice" >&2; exit 1; }
[ "$(wc -l < "$STATE_DELETE_FAILURE_OUTPUT" | tr -d ' ')" = 1 ] \
  || { echo "private-state deletion failure emitted an unexpected teardown claim" >&2; exit 1; }
if grep -Fq "$TMPDIR" "$STATE_DELETE_FAILURE_OUTPUT" || grep -Fq 'secret-bearing fixture' "$STATE_DELETE_FAILURE_OUTPUT"; then
  echo "private-state deletion failure leaked a state path or secret fixture" >&2
  exit 1
fi

BODY_AND_STATE_FAILURE_OUTPUT="$TMPDIR/body-and-state-delete-failure.out"
run_cleanup 17 0 lucairn-enterprise-mtls-cleanup-fixture 1 1 "$BODY_AND_STATE_FAILURE_OUTPUT"
[ "$RUN_STATUS" -eq 17 ] || { echo "private-state deletion failure replaced an existing body failure" >&2; exit 1; }
[ "$ENTERPRISE_MTLS_KIND_STATE_DELETE_FAILED" -eq 1 ] || { echo "combined body/state failure was not tracked" >&2; exit 1; }

attempt_line="$(rg -n 'CLUSTER_CREATION_ATTEMPTED=1' "$ROOT/scripts/test-enterprise-mtls-kind.sh" | cut -d: -f1)"
create_line="$(rg -n 'kind create cluster --name' "$ROOT/scripts/test-enterprise-mtls-kind.sh" | cut -d: -f1)"
[ "$attempt_line" -lt "$create_line" ] \
  || { echo "Kind harness does not record creation attempt before create/wait" >&2; exit 1; }

if rg -n -- '--keep|state retained|KEEP=' "$ROOT/scripts/test-enterprise-mtls-kind.sh"; then
  echo "Kind harness retains a public keep/state-retention path" >&2
  exit 1
fi

echo "enterprise mTLS Kind cleanup: success, body-failure, combined-body cleanup failures, cluster/state-deletion-failure, create/wait-failure, absent-cluster, and no-retention paths verified"
