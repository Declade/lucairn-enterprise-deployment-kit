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

# S1 verification must treat a bundle's runtime helper as delivered payload,
# never as executable verifier input. Build a valid S1 bundle solely for the
# two hostile-helper regressions below.
S1_ENV="$TMPDIR/s1-customer.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name m --model-file foo.gguf --model-path . --output "$S1_ENV" --skip-doctor >/dev/null 2>&1
S1_OUT="$TMPDIR/s1-bundles"
"$LUCAIRN" bundle create \
  --customer-slug s1-acme \
  --models-dir "$MODEL_DIR" \
  --model-manifest "$MANIFEST" \
  --env "$S1_ENV" \
  --output "$S1_OUT" >/dev/null
S1_ARCHIVE="$(find "$S1_OUT" -name 'lucairn-customer-bundle-s1-acme-*.tar.gz' -print -quit)"
test -n "$S1_ARCHIVE"
S1_EXTRACT="$TMPDIR/s1-extract"
mkdir "$S1_EXTRACT"
tar -xzf "$S1_ARCHIVE" -C "$S1_EXTRACT"
S1_ROOT="$(find "$S1_EXTRACT" -maxdepth 1 -type d -name 'lucairn-customer-bundle-s1-acme-*' -print -quit)"
test -f "$S1_ROOT/bin/runtime-profile-lib.sh"

refresh_s1_sums() {
  local bundle_root="$1"
  (
    cd "$bundle_root"
    find . -type f ! -path './checksums/SHA256SUMS' | sort | while IFS= read -r file; do
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk -v p="${file#./}" '{print $1 "  " p}'
      else
        shasum -a 256 "$file" | awk -v p="${file#./}" '{print $1 "  " p}'
      fi
    done > checksums/SHA256SUMS
  )
}

SENTINEL="$TMPDIR/untrusted-runtime-helper-sourced"
for helper_case in stale-checksum self-consistent; do
  MALICIOUS_ROOT="$TMPDIR/lucairn-customer-bundle-${helper_case}"
  cp -R "$S1_ROOT" "$MALICIOUS_ROOT"
  cat > "$MALICIOUS_ROOT/bin/runtime-profile-lib.sh" <<'MALICIOUS'
#!/usr/bin/env bash
: > "${LUCAIRN_TEST_UNTRUSTED_HELPER_SENTINEL:?}"
MALICIOUS
  chmod 0755 "$MALICIOUS_ROOT/bin/runtime-profile-lib.sh"
  if [ "$helper_case" = "self-consistent" ]; then
    refresh_s1_sums "$MALICIOUS_ROOT"
  fi
  MALICIOUS_ARCHIVE="$TMPDIR/${helper_case}-malicious-helper.tar.gz"
  tar -czf "$MALICIOUS_ARCHIVE" -C "$TMPDIR" "$(basename "$MALICIOUS_ROOT")"
  rm -f "$SENTINEL"
  set +e
  LUCAIRN_TEST_UNTRUSTED_HELPER_SENTINEL="$SENTINEL" "$LUCAIRN" bundle verify --bundle "$MALICIOUS_ARCHIVE" > "$TMPDIR/${helper_case}-malicious-helper.out" 2>&1
  HELPER_STATUS=$?
  set -e
  if [ "$helper_case" = "stale-checksum" ]; then
    [ "$HELPER_STATUS" -ne 0 ] || { echo "stale malicious helper should fail checksum verification" >&2; exit 1; }
  fi
  test ! -e "$SENTINEL" || { echo "bundle verification sourced untrusted runtime-profile-lib.sh ($helper_case)" >&2; exit 1; }
done

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

# --- audit 2026-05-15 fix-up cases ---

# Helper: refresh SHA256SUMS for a tampered extracted bundle root, mirroring
# what `write_checksums` does inside bin/lucairn. Without this, verify_checksums
# catches the tampered manifest line BEFORE the higher-level guards have a
# chance to fire — which would mask the bug we are testing for.
refresh_sums() {
  local root="$1"
  (
    cd "$root"
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
}

# (a) Policy-downgrade tamper. Swap checksum_policy: sha256-required →
# checksum_policy: none, swap one model file's bytes, refresh SHA256SUMS.
# bundle verify with no flags would have accepted this (B2). With
# --require-sha256, it must fail with the sha256 mismatch.
DOWN="$TMPDIR/downgrade"
mkdir -p "$DOWN"
tar -xzf "$BUNDLE" -C "$DOWN"
DOWN_ROOT="$(find "$DOWN" -maxdepth 1 -type d -name 'lucairn-customer-bundle-acme-*' -print -quit)"
test -n "$DOWN_ROOT"
sed -i.bak 's/checksum_policy: sha256-required/checksum_policy: none/' "$DOWN_ROOT/models/model-manifest.yaml"
rm -f "$DOWN_ROOT/models/model-manifest.yaml.bak"
printf 'tampered bytes\n' > "$DOWN_ROOT/models/foo.gguf"
refresh_sums "$DOWN_ROOT"

# Sanity: WITHOUT --require-sha256 the tampered bundle now passes (the
# downgrade succeeds, this is exactly the attack we are blocking).
"$LUCAIRN" bundle verify --bundle "$DOWN_ROOT" > "$TMPDIR/downgrade-no-flag.out" 2>&1 \
  || { echo "expected downgrade WITHOUT --require-sha256 to pass" >&2; cat "$TMPDIR/downgrade-no-flag.out" >&2; exit 1; }
grep -q "bundle verify: ok" "$TMPDIR/downgrade-no-flag.out"

# With --require-sha256, the tampered bundle MUST be rejected on sha256
# mismatch — the receiver-side flag is what closes the downgrade.
set +e
"$LUCAIRN" bundle verify --bundle "$DOWN_ROOT" --require-sha256 > "$TMPDIR/downgrade-flag.out" 2>&1
DOWN_STATUS=$?
set -e
if [ "$DOWN_STATUS" -eq 0 ]; then
  echo "expected --require-sha256 to reject a downgraded tampered bundle" >&2
  cat "$TMPDIR/downgrade-flag.out" >&2
  exit 1
fi
grep -q "sha256 mismatch for foo.gguf" "$TMPDIR/downgrade-flag.out"

# (d) Duplicate customer_slug= lines must be rejected (B3 replay-guard fix).
DUP_SLUG="$TMPDIR/dup-slug"
mkdir -p "$DUP_SLUG"
tar -xzf "$BUNDLE" -C "$DUP_SLUG"
DUP_SLUG_ROOT="$(find "$DUP_SLUG" -maxdepth 1 -type d -name 'lucairn-customer-bundle-acme-*' -print -quit)"
test -n "$DUP_SLUG_ROOT"
# Append a doctored second slug line. `tail -1` would have picked this victim.
printf 'customer_slug=victim\n' >> "$DUP_SLUG_ROOT/bundle-manifest.txt"
refresh_sums "$DUP_SLUG_ROOT"

set +e
"$LUCAIRN" bundle verify --bundle "$DUP_SLUG_ROOT" --customer-slug victim > "$TMPDIR/dup-slug.out" 2>&1
DUP_SLUG_STATUS=$?
set -e
if [ "$DUP_SLUG_STATUS" -eq 0 ]; then
  echo "expected duplicate customer_slug= to be rejected" >&2
  cat "$TMPDIR/dup-slug.out" >&2
  exit 1
fi
grep -q "customer_slug= lines (expected exactly 1)" "$TMPDIR/dup-slug.out"

# (e) Duplicate created_utc= lines must be rejected (B3).
DUP_TS="$TMPDIR/dup-ts"
mkdir -p "$DUP_TS"
tar -xzf "$BUNDLE" -C "$DUP_TS"
DUP_TS_ROOT="$(find "$DUP_TS" -maxdepth 1 -type d -name 'lucairn-customer-bundle-acme-*' -print -quit)"
test -n "$DUP_TS_ROOT"
printf 'created_utc=20200101T000000Z\n' >> "$DUP_TS_ROOT/bundle-manifest.txt"
refresh_sums "$DUP_TS_ROOT"

set +e
"$LUCAIRN" bundle verify --bundle "$DUP_TS_ROOT" --max-age-days 365 > "$TMPDIR/dup-ts.out" 2>&1
DUP_TS_STATUS=$?
set -e
if [ "$DUP_TS_STATUS" -eq 0 ]; then
  echo "expected duplicate created_utc= to be rejected" >&2
  cat "$TMPDIR/dup-ts.out" >&2
  exit 1
fi
grep -q "created_utc= lines (expected exactly 1)" "$TMPDIR/dup-ts.out"

# (f) Future-dated bundle must be rejected (B8 clock-skew/tamper).
FUT="$TMPDIR/future"
mkdir -p "$FUT"
tar -xzf "$BUNDLE" -C "$FUT"
FUT_ROOT="$(find "$FUT" -maxdepth 1 -type d -name 'lucairn-customer-bundle-acme-*' -print -quit)"
test -n "$FUT_ROOT"
FUTURE_TS="$(python3 - <<'PY'
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
print((now + datetime.timedelta(days=30)).strftime("%Y%m%dT%H%M%SZ"))
PY
)"
python3 - "$FUT_ROOT/bundle-manifest.txt" "$FUTURE_TS" <<'PY'
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
refresh_sums "$FUT_ROOT"

set +e
"$LUCAIRN" bundle verify --bundle "$FUT_ROOT" --max-age-days 30 > "$TMPDIR/future.out" 2>&1
FUT_STATUS=$?
set -e
if [ "$FUT_STATUS" -eq 0 ]; then
  echo "expected future-dated bundle to be rejected" >&2
  cat "$TMPDIR/future.out" >&2
  exit 1
fi
grep -q "in the future" "$TMPDIR/future.out"

# (g) Leading/trailing whitespace on created_utc= still parses cleanly (B5).
WS="$TMPDIR/whitespace"
mkdir -p "$WS"
tar -xzf "$BUNDLE" -C "$WS"
WS_ROOT="$(find "$WS" -maxdepth 1 -type d -name 'lucairn-customer-bundle-acme-*' -print -quit)"
test -n "$WS_ROOT"
python3 - "$WS_ROOT/bundle-manifest.txt" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
out = []
for line in lines:
    if line.startswith("created_utc="):
        ts = line.split("=", 1)[1]
        out.append(f"created_utc=  {ts}  ")
    else:
        out.append(line)
path.write_text("\n".join(out) + "\n")
PY
refresh_sums "$WS_ROOT"

"$LUCAIRN" bundle verify --bundle "$WS_ROOT" --max-age-days 365 > "$TMPDIR/ws.out"
grep -q "bundle verify: ok" "$TMPDIR/ws.out"

# (h) Staging dir with customer-data/README.txt sentinel + demo-data/d.csv
# must NOT trip the ambiguity check (B6). bundle prepare should succeed and
# select demo-data as the data dir.
STAGE="$TMPDIR/stage-h"
mkdir -p "$STAGE/install" "$STAGE/models" "$STAGE/customer-data" "$STAGE/demo-data"
echo "No customer demo data included." > "$STAGE/customer-data/README.txt"
touch "$STAGE/customer-data/.DS_Store"
printf 'a,b\n1,2\n' > "$STAGE/demo-data/d.csv"
cp "$ROOT/docker-compose.customer.yml" "$STAGE/install/docker-compose.customer.yml"
cp "$ROOT/docker-compose.self-hosted.yml" "$STAGE/install/docker-compose.self-hosted.yml"
cp "$ENV_FILE" "$STAGE/customer.env"
cat > "$STAGE/models/model-manifest.yaml" <<YAML
model:
  name: m
  format: gguf
  runtime: llama-cpp
  checksum_policy: sha256-required
  files:
    - path: foo.gguf
      sha256: $GOOD_SHA
YAML
cp "$MODEL_DIR/foo.gguf" "$STAGE/models/foo.gguf"

OUT_H="$TMPDIR/bundles-h"
"$LUCAIRN" bundle prepare \
  --customer-slug acme \
  --staging-dir "$STAGE" \
  --output "$OUT_H" > "$TMPDIR/stage-h.out" 2>&1 \
  || { echo "expected bundle prepare to ignore sentinel + dotfile and pick demo-data" >&2; cat "$TMPDIR/stage-h.out" >&2; exit 1; }
grep -q "selected staging dir: $STAGE/demo-data" "$TMPDIR/stage-h.out"

echo "bundle verify replay-guard tests: ok"
