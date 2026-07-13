#!/usr/bin/env bash
# Harness-local cleanup policy for scripts/test-enterprise-mtls-kind.sh.
#
# The caller owns CLUSTER, CLUSTER_CREATION_ATTEMPTED, PROBE_IMAGE, and
# STATE_DIR. This helper never prints a state path or any credential-related
# value. A failed owned-cluster deletion is the one cleanup failure that
# changes the gate result, because retaining a running cluster can retain
# projected Secrets.

enterprise_mtls_kind_cleanup() {
  local body_status="$1"
  local cluster_delete_failed=0

  ENTERPRISE_MTLS_KIND_CLUSTER_DELETE_FAILED=0

  # The harness defines this after it knows which temporary in-container
  # helpers were installed. It is intentionally best effort: a Pod may already
  # be unreachable while the owned cluster is being torn down.
  if declare -F enterprise_mtls_kind_cleanup_helpers >/dev/null 2>&1; then
    enterprise_mtls_kind_cleanup_helpers >/dev/null 2>&1 || true
  fi

  # `kind create cluster --wait` can fail after creating cluster resources.
  # Once creation has been attempted, always ask Kind to delete our uniquely
  # named cluster. A nonzero delete is benign only when Kind can positively
  # confirm the exact name is absent; an unreadable cluster list is fail-closed.
  if [ "${CLUSTER_CREATION_ATTEMPTED:-0}" -eq 1 ]; then
    if ! kind delete cluster --name "$CLUSTER" >/dev/null 2>&1; then
      local clusters
      if ! clusters="$(kind get clusters 2>/dev/null)" \
        || printf '%s\n' "$clusters" | grep -Fqx -- "$CLUSTER"; then
        printf 'ERROR: owned Kind cluster deletion failed for cluster %s\n' "$CLUSTER" >&2
        printf 'Retry: kind delete cluster --name %s\n' "$CLUSTER" >&2
        cluster_delete_failed=1
      fi
    fi
  fi

  if [ -n "${PROBE_IMAGE:-}" ]; then
    docker image rm -f "$PROBE_IMAGE" >/dev/null 2>&1 || true
  fi
  if [ -n "${STATE_DIR:-}" ]; then
    rm -rf -- "$STATE_DIR"
  fi

  if [ "$cluster_delete_failed" -ne 0 ]; then
    ENTERPRISE_MTLS_KIND_CLUSTER_DELETE_FAILED=1
    return 1
  fi
  return "$body_status"
}
