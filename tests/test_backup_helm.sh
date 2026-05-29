#!/usr/bin/env bash
# WS-2 / HA-01 — Helm backup-CronJob render + fail-fast tests.
#
# Asserts the acceptance criteria that CAN be checked statically with
# `helm template`:
#   - backup.enabled=false renders NO CronJob (existing installs unchanged).
#   - backup.enabled=true (full config) renders exactly 3 CronJobs, one per
#     compliance DB, each in its source namespace, with the S3 + age Secret
#     refs wired and the dump encrypted before upload.
#   - half-config (enabled but no bucket / no age recipient) fails fast.
#   - rendered CronJobs are valid against kubeconform (when available).
#
# The full backup -> S3 -> restore round-trip is the LIVE-VERIFY-on-Vast gate
# (PRD § LIVE-VERIFY) and is NOT covered here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
VALUES="$ROOT/customer-values.yaml.example"

if ! command -v helm >/dev/null 2>&1; then
  echo "backup-helm tests: skipped (helm not installed)"
  exit 0
fi

# Common --set flags that satisfy the chart's pre-existing validators so the
# render reaches our CronJob template. imagePullDockerConfigJson satisfies the
# pull-secret guard.
COMMON=(--set "global.imagePullDockerConfigJson=x")

render() {
  helm template lucairn "$CHART" -f "$VALUES" "${COMMON[@]}" "$@"
}

# 1. enabled=false -> zero CronJobs.
n="$(render 2>/dev/null | grep -c "kind: CronJob" || true)"
[ "$n" = "0" ] || { echo "FAIL: backup.enabled=false rendered $n CronJob(s), expected 0" >&2; exit 1; }
echo "  ok: backup.enabled=false renders no CronJob"

# 2. enabled=true full config -> exactly 3 CronJobs in the 3 compliance NSs.
ENABLED=(
  --set backup.enabled=true
  --set backup.s3.bucket=lucairn-backups
  --set backup.s3.accessKeySecretRef.name=lucairn-backup-s3
  --set backup.s3.secretKeySecretRef.name=lucairn-backup-s3
  --set backup.encryption.recipientSecretRef.name=lucairn-backup-age
)
# Dump the render to a file and grep the FILE — `printf "$OUT" | grep -q` would
# SIGPIPE printf (rc 141) under `set -o pipefail`, falsely failing the check.
RENDER_OUT="$(mktemp)"
trap 'rm -f "$RENDER_OUT"' EXIT
render "${ENABLED[@]}" 2>/dev/null > "$RENDER_OUT"
n="$(grep -c "kind: CronJob" "$RENDER_OUT" || true)"
[ "$n" = "3" ] || { echo "FAIL: expected 3 CronJobs, got $n" >&2; exit 1; }
grep -q "name: lucairn-backup-audit" "$RENDER_OUT" || { echo "FAIL: missing audit CronJob" >&2; exit 1; }
grep -q "name: lucairn-backup-id-bridge" "$RENDER_OUT" || { echo "FAIL: missing id-bridge CronJob" >&2; exit 1; }
grep -q "name: lucairn-backup-veil-witness" "$RENDER_OUT" || { echo "FAIL: missing veil-witness CronJob" >&2; exit 1; }
grep -q "namespace: dsa-audit" "$RENDER_OUT" || { echo "FAIL: missing dsa-audit ns" >&2; exit 1; }
grep -q "namespace: dsa-bridge" "$RENDER_OUT" || { echo "FAIL: missing dsa-bridge ns" >&2; exit 1; }
grep -q "namespace: dsa-witness" "$RENDER_OUT" || { echo "FAIL: missing dsa-witness ns" >&2; exit 1; }
# Encryption is in the pipeline (age) and the dump is age-checked before upload.
grep -q 'age -r "${RECIPIENT}"' "$RENDER_OUT" || { echo "FAIL: age encryption step missing" >&2; exit 1; }
grep -q "age-encryption.org" "$RENDER_OUT" || { echo "FAIL: plaintext-upload guard missing" >&2; exit 1; }
# S3 + age Secret refs are wired (never inline values).
grep -q "name: lucairn-backup-age" "$RENDER_OUT" || { echo "FAIL: age recipient secret ref missing" >&2; exit 1; }
grep -q "name: lucairn-backup-s3" "$RENDER_OUT" || { echo "FAIL: s3 cred secret ref missing" >&2; exit 1; }
echo "  ok: backup.enabled=true renders 3 CronJobs (audit/id-bridge/veil-witness) with S3 + age secret refs"

# 3. half-config fails fast: no bucket. (customer-values.example provides a
# default bucket, so explicitly clear it to exercise the guard.)
ERR1="$(mktemp)"
if render --set backup.enabled=true --set backup.s3.bucket= --set backup.encryption.recipientSecretRef.name=age >/dev/null 2>"$ERR1"; then
  echo "FAIL: enabled without bucket should have failed" >&2; rm -f "$ERR1"; exit 1
fi
grep -q "backup.s3.bucket is empty" "$ERR1" || { echo "FAIL: wrong error for missing bucket" >&2; cat "$ERR1" >&2; rm -f "$ERR1"; exit 1; }
rm -f "$ERR1"

# 4. half-config fails fast: no age recipient.
ERR2="$(mktemp)"
if render --set backup.enabled=true --set backup.s3.bucket=b --set backup.encryption.recipientSecretRef.name= >/dev/null 2>"$ERR2"; then
  echo "FAIL: enabled without age recipient should have failed" >&2; rm -f "$ERR2"; exit 1
fi
grep -q "uploaded UNENCRYPTED" "$ERR2" || { echo "FAIL: wrong error for missing age recipient" >&2; cat "$ERR2" >&2; rm -f "$ERR2"; exit 1; }
rm -f "$ERR2"
echo "  ok: half-config (no bucket / no age recipient) fails fast"

# 5. kubeconform validity of the rendered CronJobs (when available).
if command -v kubeconform >/dev/null 2>&1; then
  kubeconform -summary -ignore-missing-schemas < "$RENDER_OUT" >/tmp/bk-kc.out 2>&1 \
    || { echo "FAIL: kubeconform rejected the rendered manifests" >&2; cat /tmp/bk-kc.out >&2; exit 1; }
  grep -q "Invalid: 0" /tmp/bk-kc.out || { echo "FAIL: kubeconform reported invalid resources" >&2; cat /tmp/bk-kc.out >&2; exit 1; }
  echo "  ok: rendered CronJobs pass kubeconform"
else
  echo "  skip: kubeconform not installed"
fi

echo "backup-helm tests: ok"
