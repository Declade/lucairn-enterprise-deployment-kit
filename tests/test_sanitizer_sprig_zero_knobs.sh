#!/usr/bin/env bash
set -euo pipefail

# T-562 — Sprig-0 sweep (PRD prd-2026-08-06-residuals-stream.md § S3).
#
# THE DEFECT: several numeric sanitizer knobs render through Sprig's `default`
# filter, e.g. `{{ .Values.sanitizer.llmScanTimeout | default 30 }}`. Sprig's
# `default` treats the numeric zero-value as EMPTY (same rule as an unset key
# or an empty string), so `--set sandbox-a.sanitizer.llmScanTimeout=0` renders
# `timeout_seconds: 30`, not `0`. The chart silently substitutes a value the
# operator never asked for instead of letting the value — or the consuming
# service's own boot validation — decide. First caught and fixed for
# `llmScanRequestBudgetSeconds` (T-472, commit 7c9e239); this suite closes the
# eleven sibling knobs that commit's own PR body flagged as "worth its own
# sweep", using the identical hasKey presence pattern.
#
# Acceptance bar (binding, PRD § S3): preserve the explicit 0, or
# schema-reject it — never silently substitute.
#
# TEN of the eleven knobs below are fixed with hasKey (preserve-zero: the
# value — including an explicit 0 — always reaches the rendered ConfigMap,
# and whatever downstream validation exists gets to decide):
#   llmScanTimeout, llmScanRestoreThreshold, piiranha.grpcDeadlineSeconds,
#   gliner.grpcDeadlineSeconds, gliner.skipMinTextLen,
#   gliner.skipMaxEntityDensity, kAnonymity.k,
#   piiMlClient.circuitBreaker.consecutiveFailures,
#   piiMlClient.circuitBreaker.halfOpenSeconds
#   (that is 9 — llmScanTimeout/llmScanRestoreThreshold + the 2
#   grpcDeadlineSeconds + 2 gliner-only + kAnonymity.k + 2 circuitBreaker)
#
# ONE knob is SCHEMA-REJECTED instead (values.schema.json,
# `exclusiveMinimum: 0`): piiMlClient.deadlineSeconds. It is a raw wall-clock
# gRPC transport timeout — the same knob CLASS as `llm_scan.timeout_seconds`,
# which DSA's sanitizer already refuses at boot for a non-positive value
# (config.py:2208, T-474) — but `PiiMlClientConfig` has NO boot validation at
# all today, so a preserved 0 would pass boot silently and then fail every
# Piiranha/GLiNER gRPC call at runtime wearing an infrastructure fault's
# clothes. Reject before it ever reaches the pod instead.
#
# The ELEVENTH knob, confidenceThreshold, already has a dedicated schema +
# render suite (test_sanitizer_confidence_threshold_schema.sh, T-517); its
# hasKey fix + 0-boundary flip lives THERE, not here, to avoid a second
# suite asserting the same ConfigMap key.
#
# POSITIVE CONTROLS — verified by hand in a scratch copy of this tree
# (2026-08-06, not committed) for 4 representative knobs by reverting the
# template line back to `| default <N>` and re-running this suite:
#   llmScanTimeout, gliner.skipMaxEntityDensity, piiMlClient.circuitBreaker.
#   halfOpenSeconds — each reversion turned exactly that knob's
#   `*-zero-preserved` case red (rendered the shipped default instead of 0).
#   A 5th control removed the deadlineSeconds bound from values.schema.json
#   and turned the schema-rejects-non-positive case red (0 was accepted).
#   confidenceThreshold's own control (revert to `| default 0.35`) lives in
#   test_sanitizer_confidence_threshold_schema.sh and was verified the same
#   way. None of these are tautologies against the current tree.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"

# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

fail() {
  echo "T-562 Sprig-0 sweep: $*" >&2
  exit 1
}

# render OVERRIDE — renders the umbrella chart with every secret guard
# satisfied plus one optional `sandbox-a.sanitizer.<path>=<value>` override.
# Deliberately does NOT use a variable named `path`: this suite is sourced by
# a POSIX-ish shell and `path` collides with zsh's linked path/PATH array
# when a caller's interactive shell happens to be zsh — writing to it
# clobbers $PATH mid-script and every subsequent command silently vanishes.
render() {
  local knobpath="${1:-}"
  # Two explicit branches, not an optional array element: bash 3.2 (macOS's
  # shipped /bin/bash) treats `"${extra[@]}"` on an empty array as an
  # unbound-variable error under `set -u` (fixed only in bash 4.4+).
  if [ -z "$knobpath" ]; then
    helm template lucairn "$CHART" \
      "${HELM_TEST_SECRET_ARGS[@]}" \
      --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
      --set global.skipPullSecretGuard=true
  else
    helm template lucairn "$CHART" \
      "${HELM_TEST_SECRET_ARGS[@]}" \
      --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
      --set global.skipPullSecretGuard=true \
      --set "sandbox-a.sanitizer.$knobpath"
  fi
}

# extract_unique OUTPUT KEY — greps a single rendered ConfigMap key that is
# unique across the whole umbrella render.
extract_unique() {
  printf '%s\n' "$1" | grep -E "^[[:space:]]*$2:" | head -1
}

# extract_in_block OUTPUT START END KEY — greps a key that appears more than
# once in the render (grpc_deadline_seconds appears under BOTH `piiranha:`
# and `gliner:`) by scoping the search to the line range between the two
# markers.
extract_in_block() {
  printf '%s\n' "$1" | sed -n "/^[[:space:]]*$2:/,/^[[:space:]]*$3:/p" | grep "$4" | head -1
}

# assert_eq NAME ACTUAL EXPECTED
assert_eq() {
  [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"
}

echo "T-562 Sprig-0 sweep: stock render (no overrides) — every knob at its shipped default"
STOCK="$(render '')"
assert_eq "stock timeout_seconds"                "$(extract_unique "$STOCK" timeout_seconds)"                "        timeout_seconds: 30"
assert_eq "stock restore_threshold"               "$(extract_unique "$STOCK" restore_threshold)"               "        restore_threshold: 0.85"
assert_eq "stock piiranha grpc_deadline_seconds"  "$(extract_in_block "$STOCK" piiranha gliner grpc_deadline_seconds)"       "        grpc_deadline_seconds: 5"
assert_eq "stock gliner grpc_deadline_seconds"    "$(extract_in_block "$STOCK" gliner k_anonymity grpc_deadline_seconds)"    "        grpc_deadline_seconds: 5"
assert_eq "stock skip_min_text_len"               "$(extract_unique "$STOCK" skip_min_text_len)"               "        skip_min_text_len: 32"
assert_eq "stock skip_max_entity_density"         "$(extract_unique "$STOCK" skip_max_entity_density)"         "        skip_max_entity_density: 0.3"
assert_eq "stock kAnonymity k"                    "$(extract_in_block "$STOCK" k_anonymity pii_ml_client '^[[:space:]]*k:')" "        k: 5"
assert_eq "stock deadline_seconds"                "$(extract_unique "$STOCK" deadline_seconds)"                "        deadline_seconds: 5"
assert_eq "stock circuit_breaker_open_after"      "$(extract_unique "$STOCK" circuit_breaker_open_after)"      "        circuit_breaker_open_after: 3"
assert_eq "stock circuit_breaker_half_open_seconds" "$(extract_unique "$STOCK" circuit_breaker_half_open_seconds)" "        circuit_breaker_half_open_seconds: 30"
echo "  PASS"

# ---------------------------------------------------------------------------
# Preserve-zero knobs: explicit 0 must render 0, not the shipped default.
# ---------------------------------------------------------------------------

echo "T-562 Sprig-0 sweep: explicit 0 preserved (9 preserve-zero knobs)"

OUT="$(render "llmScanTimeout=0")"
assert_eq "llmScanTimeout-zero-preserved" "$(extract_unique "$OUT" timeout_seconds)" "        timeout_seconds: 0"

OUT="$(render "llmScanRestoreThreshold=0")"
assert_eq "llmScanRestoreThreshold-zero-preserved" "$(extract_unique "$OUT" restore_threshold)" "        restore_threshold: 0"

OUT="$(render "piiranha.grpcDeadlineSeconds=0")"
assert_eq "piiranha.grpcDeadlineSeconds-zero-preserved" "$(extract_in_block "$OUT" piiranha gliner grpc_deadline_seconds)" "        grpc_deadline_seconds: 0"

OUT="$(render "gliner.grpcDeadlineSeconds=0")"
assert_eq "gliner.grpcDeadlineSeconds-zero-preserved" "$(extract_in_block "$OUT" gliner k_anonymity grpc_deadline_seconds)" "        grpc_deadline_seconds: 0"

OUT="$(render "gliner.skipMinTextLen=0")"
assert_eq "skipMinTextLen-zero-preserved" "$(extract_unique "$OUT" skip_min_text_len)" "        skip_min_text_len: 0"

OUT="$(render "gliner.skipMaxEntityDensity=0")"
assert_eq "skipMaxEntityDensity-zero-preserved" "$(extract_unique "$OUT" skip_max_entity_density)" "        skip_max_entity_density: 0"

OUT="$(render "kAnonymity.k=0")"
assert_eq "kAnonymity.k-zero-preserved" "$(extract_in_block "$OUT" k_anonymity pii_ml_client '^[[:space:]]*k:')" "        k: 0"

OUT="$(render "piiMlClient.circuitBreaker.consecutiveFailures=0")"
assert_eq "consecutiveFailures-zero-preserved" "$(extract_unique "$OUT" circuit_breaker_open_after)" "        circuit_breaker_open_after: 0"

OUT="$(render "piiMlClient.circuitBreaker.halfOpenSeconds=0")"
assert_eq "halfOpenSeconds-zero-preserved" "$(extract_unique "$OUT" circuit_breaker_half_open_seconds)" "        circuit_breaker_half_open_seconds: 0"

echo "  PASS"

# ---------------------------------------------------------------------------
# Override control: a distinct non-default, non-zero value must still plumb
# through cleanly (the fix must not have broken the ordinary override path).
# ---------------------------------------------------------------------------

echo "T-562 Sprig-0 sweep: non-default override still plumbs"

OUT="$(render "llmScanTimeout=45")"
assert_eq "llmScanTimeout-override" "$(extract_unique "$OUT" timeout_seconds)" "        timeout_seconds: 45"

OUT="$(render "llmScanRestoreThreshold=0.6")"
assert_eq "llmScanRestoreThreshold-override" "$(extract_unique "$OUT" restore_threshold)" "        restore_threshold: 0.6"

OUT="$(render "piiranha.grpcDeadlineSeconds=7")"
assert_eq "piiranha.grpcDeadlineSeconds-override" "$(extract_in_block "$OUT" piiranha gliner grpc_deadline_seconds)" "        grpc_deadline_seconds: 7"

OUT="$(render "gliner.grpcDeadlineSeconds=9")"
assert_eq "gliner.grpcDeadlineSeconds-override" "$(extract_in_block "$OUT" gliner k_anonymity grpc_deadline_seconds)" "        grpc_deadline_seconds: 9"

OUT="$(render "gliner.skipMinTextLen=64")"
assert_eq "skipMinTextLen-override" "$(extract_unique "$OUT" skip_min_text_len)" "        skip_min_text_len: 64"

OUT="$(render "gliner.skipMaxEntityDensity=0.5")"
assert_eq "skipMaxEntityDensity-override" "$(extract_unique "$OUT" skip_max_entity_density)" "        skip_max_entity_density: 0.5"

OUT="$(render "kAnonymity.k=11")"
assert_eq "kAnonymity.k-override" "$(extract_in_block "$OUT" k_anonymity pii_ml_client '^[[:space:]]*k:')" "        k: 11"

OUT="$(render "piiMlClient.deadlineSeconds=8")"
assert_eq "deadlineSeconds-override" "$(extract_unique "$OUT" deadline_seconds)" "        deadline_seconds: 8"

OUT="$(render "piiMlClient.circuitBreaker.consecutiveFailures=6")"
assert_eq "consecutiveFailures-override" "$(extract_unique "$OUT" circuit_breaker_open_after)" "        circuit_breaker_open_after: 6"

OUT="$(render "piiMlClient.circuitBreaker.halfOpenSeconds=45")"
assert_eq "halfOpenSeconds-override" "$(extract_unique "$OUT" circuit_breaker_half_open_seconds)" "        circuit_breaker_half_open_seconds: 45"

echo "  PASS"

# ---------------------------------------------------------------------------
# piiMlClient.deadlineSeconds — the ONE schema-reject knob. 0 and negative
# must be REFUSED at helm template/lint time, not rendered.
# ---------------------------------------------------------------------------

echo "T-562 Sprig-0 sweep: piiMlClient.deadlineSeconds schema-rejects non-positive"

if render "piiMlClient.deadlineSeconds=0" >/tmp/t562-deadline-zero.out 2>&1; then
  fail "piiMlClient.deadlineSeconds=0 was accepted — must be schema-rejected"
fi
grep -q "deadlineSeconds" /tmp/t562-deadline-zero.out \
  || fail "deadlineSeconds=0 refusal did not name the field — check values.schema.json message"
rm -f /tmp/t562-deadline-zero.out

if render "piiMlClient.deadlineSeconds=-1" >/tmp/t562-deadline-neg.out 2>&1; then
  fail "piiMlClient.deadlineSeconds=-1 was accepted — must be schema-rejected"
fi
grep -q "deadlineSeconds" /tmp/t562-deadline-neg.out \
  || fail "deadlineSeconds=-1 refusal did not name the field — check values.schema.json message"
rm -f /tmp/t562-deadline-neg.out

echo "  PASS"

# ---------------------------------------------------------------------------
# customer-values.yaml.example must still render clean. It does not set any
# of these 11 knobs directly (only piiranha/gliner/kAnonymity `enabled`), so
# this is the "omitted key still falls through to the shipped default" path.
# ---------------------------------------------------------------------------

echo "T-562 Sprig-0 sweep: customer-values.yaml.example still renders clean"

CUSTOMER_OUT="$(helm template lucairn "$CHART" -f "$ROOT/customer-values.yaml.example" \
  "${HELM_TEST_SECRET_ARGS[@]}" \
  --set global.skipPullSecretGuard=true \
  --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}")" \
  || fail "customer-values.yaml.example failed to render after the T-562 template changes"

assert_eq "customer-example timeout_seconds"     "$(extract_unique "$CUSTOMER_OUT" timeout_seconds)"     "        timeout_seconds: 30"
assert_eq "customer-example restore_threshold"   "$(extract_unique "$CUSTOMER_OUT" restore_threshold)"   "        restore_threshold: 0.85"
assert_eq "customer-example deadline_seconds"    "$(extract_unique "$CUSTOMER_OUT" deadline_seconds)"    "        deadline_seconds: 5"
assert_eq "customer-example kAnonymity k"        "$(extract_in_block "$CUSTOMER_OUT" k_anonymity pii_ml_client '^[[:space:]]*k:')" "        k: 5"

echo "  PASS"

echo "T-562 Sprig-0 sweep: PASS"
