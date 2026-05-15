#!/usr/bin/env bash
set -euo pipefail

# Regression test for bundle verify anti-replay guards (audit 2026-05-15 F3):
#   --customer-slug X rejects bundles for a different slug
#   --max-age-days N rejects bundles older than N days

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

LUCAIRN="$ROOT/bin/lucairn"

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

ENV_FILE="$TMPDIR/customer.env"
cat > "$ENV_FILE" <<'ENV'
DSA_ENV=test
ENV

MODEL_DIR="$TMPDIR/models"
mkdir -p "$MODEL_DIR"
printf 'fake gguf bytes\n' > "$MODEL_DIR/foo.gguf"
GOOD_SHA="$(sha_of "$MODEL_DIR/foo.gguf")"

MANIFEST="$TMPDIR/model-manifest.yaml"
cat > "$MANIFEST" <<YAML
model:
  name: m
  format: gguf
  runtime: llama-cpp
  checksum_policy: sha256-required
  files:
    - path: foo.gguf
      sha256: $GOOD_SHA
YAML

OUT="$TMPDIR/bundles"
"$LUCAIRN" bundle create \
  --customer-slug acme \
  --models-dir "$MODEL_DIR" \
  --model-manifest "$MANIFEST" \
  --env "$ENV_FILE" \
  --output "$OUT" > "$TMPDIR/create.out"

BUNDLE="$(find "$OUT" -name 'lucairn-customer-bundle-acme-*.tar.gz' -print -quit)"
test -n "$BUNDLE"

# Baseline: plain verify still passes.
"$LUCAIRN" bundle verify --bundle "$BUNDLE" > "$TMPDIR/verify-base.out"
grep -q "bundle verify: ok" "$TMPDIR/verify-base.out"

# (1) Matching customer-slug passes.
"$LUCAIRN" bundle verify --bundle "$BUNDLE" --customer-slug acme > "$TMPDIR/verify-slug-ok.out"
grep -q "bundle verify: ok" "$TMPDIR/verify-slug-ok.out"

# (2) Mismatched customer-slug fails.
set +e
"$LUCAIRN" bundle verify --bundle "$BUNDLE" --customer-slug wrong-co > "$TMPDIR/verify-slug-bad.out" 2>&1
SLUG_STATUS=$?
set -e
if [ "$SLUG_STATUS" -eq 0 ]; then
  echo "expected --customer-slug mismatch to fail" >&2
  cat "$TMPDIR/verify-slug-bad.out" >&2
  exit 1
fi
grep -q "customer_slug mismatch" "$TMPDIR/verify-slug-bad.out"

# (3) Generous --max-age-days passes.
"$LUCAIRN" bundle verify --bundle "$BUNDLE" --max-age-days 365 > "$TMPDIR/verify-age-ok.out"
grep -q "bundle verify: ok" "$TMPDIR/verify-age-ok.out"

# (4) Stale bundle fails (rewrite created_utc to a past date).
STALE="$TMPDIR/stale"
mkdir -p "$STALE"
tar -xzf "$BUNDLE" -C "$STALE"
STALE_ROOT="$(find "$STALE" -maxdepth 1 -type d -name 'lucairn-customer-bundle-acme-*' -print -quit)"
test -n "$STALE_ROOT"

# Replace created_utc with a date well over 1 year in the past.
PAST_TS="$(python3 - <<'PY'
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
print((now - datetime.timedelta(days=400)).strftime("%Y%m%dT%H%M%SZ"))
PY
)"
# In-place rewrite of the manifest, then refresh SHA256SUMS so verify_checksums
# does not flag the doctored file.
python3 - "$STALE_ROOT/bundle-manifest.txt" "$PAST_TS" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
new_ts = sys.argv[2]
lines = path.read_text().splitlines()
out = []
for line in lines:
    if line.startswith("created_utc="):
        out.append(f"created_utc={new_ts}")
    else:
        out.append(line)
path.write_text("\n".join(out) + "\n")
PY

# Regenerate SHA256SUMS (mirrors what `write_checksums` does inside bin/lucairn).
(
  cd "$STALE_ROOT"
  : > checksums/SHA256SUMS
  find . -type f ! -path './checksums/SHA256SUMS' | sort | while IFS= read -r file; do
    if command -v sha256sum >/dev/null 2>&1; then
      h="$(sha256sum "$file" | awk '{print $1}')"
    else
      h="$(shasum -a 256 "$file" | awk '{print $1}')"
    fi
    printf '%s  %s\n' "$h" "${file#./}"
  done > checksums/SHA256SUMS
)

set +e
"$LUCAIRN" bundle verify --bundle "$STALE_ROOT" --max-age-days 30 > "$TMPDIR/verify-age-bad.out" 2>&1
AGE_STATUS=$?
set -e
if [ "$AGE_STATUS" -eq 0 ]; then
  echo "expected --max-age-days 30 to reject a 400-day-old bundle" >&2
  cat "$TMPDIR/verify-age-bad.out" >&2
  exit 1
fi
grep -q "days old (max allowed: 30)" "$TMPDIR/verify-age-bad.out"

# (5) Bad --max-age-days argument is rejected up-front.
set +e
"$LUCAIRN" bundle verify --bundle "$BUNDLE" --max-age-days "abc" > "$TMPDIR/verify-age-arg.out" 2>&1
ARG_STATUS=$?
set -e
if [ "$ARG_STATUS" -eq 0 ]; then
  echo "expected non-integer --max-age-days to be rejected" >&2
  exit 1
fi
grep -q "non-negative integer" "$TMPDIR/verify-age-arg.out"

# (6) Combining both flags on a healthy bundle passes.
"$LUCAIRN" bundle verify \
  --bundle "$BUNDLE" \
  --customer-slug acme \
  --max-age-days 365 > "$TMPDIR/verify-combined.out"
grep -q "bundle verify: ok" "$TMPDIR/verify-combined.out"

echo "bundle verify replay-guard tests: ok"
