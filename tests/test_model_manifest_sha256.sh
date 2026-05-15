#!/usr/bin/env bash
set -euo pipefail

# Regression test for the manifest-side sha256 enforcement (audit 2026-05-15 F2).
# Drives the validator through `bin/lucairn bundle create`, which calls
# validate_model_manifest before staging anything.
#
# Cases:
#   (a) matching sha256 passes with checksum_policy: sha256-required
#   (b) mismatched sha256 fails with checksum_policy: sha256-required
#   (c) missing sha256 with checksum_policy: sha256-required fails
#   (d) legacy plain-string entry passes with checksum_policy: sha256-optional
#   (e) sha256-optional + matching sha256 passes
#   (f) sha256-optional + mismatched sha256 still fails
#   (g) checksum_policy: none skips sha256 entirely
#   (h) unsupported checksum_policy rejected

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

# Minimal env for `bundle create` (require_env_values is NOT called here, only
# require_file). All non-secret stand-ins.
ENV_FILE="$TMPDIR/customer.env"
cat > "$ENV_FILE" <<'ENV'
DSA_ENV=test
ENV

MODEL_DIR="$TMPDIR/models"
mkdir -p "$MODEL_DIR"
printf 'fake model weight bytes\n' > "$MODEL_DIR/foo.gguf"
GOOD_SHA="$(sha_of "$MODEL_DIR/foo.gguf")"
BAD_SHA="0000000000000000000000000000000000000000000000000000000000000000"

assert_create_passes() {
  local label="$1" manifest="$2"
  local out_dir="$TMPDIR/out-$label"
  rm -rf "$out_dir"
  if ! "$LUCAIRN" bundle create \
      --customer-slug "test-${label}" \
      --models-dir "$MODEL_DIR" \
      --model-manifest "$manifest" \
      --env "$ENV_FILE" \
      --output "$out_dir" > "$TMPDIR/$label.out" 2>&1; then
    echo "case ($label) expected pass but failed:" >&2
    cat "$TMPDIR/$label.out" >&2
    exit 1
  fi
}

assert_create_fails_matching() {
  local label="$1" manifest="$2" pattern="$3"
  local out_dir="$TMPDIR/out-$label"
  rm -rf "$out_dir"
  set +e
  "$LUCAIRN" bundle create \
    --customer-slug "test-${label}" \
    --models-dir "$MODEL_DIR" \
    --model-manifest "$manifest" \
    --env "$ENV_FILE" \
    --output "$out_dir" > "$TMPDIR/$label.out" 2>&1
  local status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "case ($label) expected fail but passed" >&2
    cat "$TMPDIR/$label.out" >&2
    exit 1
  fi
  if ! grep -Eq "$pattern" "$TMPDIR/$label.out"; then
    echo "case ($label) failed with wrong message:" >&2
    cat "$TMPDIR/$label.out" >&2
    echo "expected pattern: $pattern" >&2
    exit 1
  fi
}

# (a) matching sha256 passes with sha256-required
cat > "$TMPDIR/a.yaml" <<YAML
model:
  name: m
  format: gguf
  runtime: llama-cpp
  checksum_policy: sha256-required
  files:
    - path: foo.gguf
      sha256: $GOOD_SHA
YAML
assert_create_passes a "$TMPDIR/a.yaml"

# (b) mismatched sha256 fails with sha256-required
cat > "$TMPDIR/b.yaml" <<YAML
model:
  name: m
  format: gguf
  runtime: llama-cpp
  checksum_policy: sha256-required
  files:
    - path: foo.gguf
      sha256: $BAD_SHA
YAML
assert_create_fails_matching b "$TMPDIR/b.yaml" "sha256 mismatch for foo\.gguf"

# (c) missing sha256 with sha256-required fails (legacy plain-string shape)
cat > "$TMPDIR/c.yaml" <<'YAML'
model:
  name: m
  format: gguf
  runtime: llama-cpp
  checksum_policy: sha256-required
  files:
    - foo.gguf
YAML
assert_create_fails_matching c "$TMPDIR/c.yaml" "no sha256 declared for foo\.gguf"

# (d) legacy plain-string entry passes with sha256-optional
cat > "$TMPDIR/d.yaml" <<'YAML'
model:
  name: m
  format: gguf
  runtime: llama-cpp
  checksum_policy: sha256-optional
  files:
    - foo.gguf
YAML
assert_create_passes d "$TMPDIR/d.yaml"

# (e) sha256-optional + matching sha256 passes
cat > "$TMPDIR/e.yaml" <<YAML
model:
  name: m
  format: gguf
  runtime: llama-cpp
  checksum_policy: sha256-optional
  files:
    - path: foo.gguf
      sha256: $GOOD_SHA
YAML
assert_create_passes e "$TMPDIR/e.yaml"

# (f) sha256-optional + mismatched sha256 still fails
cat > "$TMPDIR/f.yaml" <<YAML
model:
  name: m
  format: gguf
  runtime: llama-cpp
  checksum_policy: sha256-optional
  files:
    - path: foo.gguf
      sha256: $BAD_SHA
YAML
assert_create_fails_matching f "$TMPDIR/f.yaml" "sha256 mismatch for foo\.gguf"

# (g) checksum_policy: none skips sha256 entirely
cat > "$TMPDIR/g.yaml" <<'YAML'
model:
  name: m
  format: gguf
  runtime: llama-cpp
  checksum_policy: none
  files:
    - foo.gguf
YAML
assert_create_passes g "$TMPDIR/g.yaml"

# (h) unsupported checksum_policy is rejected
cat > "$TMPDIR/h.yaml" <<'YAML'
model:
  name: m
  format: gguf
  runtime: llama-cpp
  checksum_policy: bogus
  files:
    - foo.gguf
YAML
assert_create_fails_matching h "$TMPDIR/h.yaml" "unsupported checksum_policy"

echo "model manifest sha256 tests: ok"
