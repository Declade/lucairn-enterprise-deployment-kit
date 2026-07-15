#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

REMOTE_CREDENTIALS="$TMPDIR/lucairn-issued-remote-credentials.env"
cat > "$REMOTE_CREDENTIALS" <<'CREDS'
sandbox_b_api_key=lcr-issued-test-api-key_123
sandbox_b_public_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
CREDS

expect_fail() {
  local name="$1"
  shift
  if "$@" >"$TMPDIR/${name}.out" 2>&1; then
    echo "expected failure: $name" >&2
    exit 1
  fi
}

assert_install_lock_reacquirable() {
  local name="$1" output
  output="$TMPDIR/${name}.env"
  "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
    --output "$output" --skip-doctor >"$TMPDIR/${name}.out" 2>&1
  test -f "$output"
  test -f "$output.runtime-profile.yaml"
  test -f "$output.image-manifest.yaml"
  test ! -d "$TMPDIR/.lucairn-init.lock"
}

copy_pre_s1_env() {
  cp "$1" "$2"
  sed '/^LUCAIRN_RUNTIME_PROFILE_REQUIRED=/d' "$2" > "$2.tmp" && mv "$2.tmp" "$2"
}

file_mode() {
  local file="$1"
  case "$(uname -s)" in
    Darwin|FreeBSD|OpenBSD|NetBSD) stat -f '%Lp' "$file" 2>/dev/null ;;
    *) stat -c '%a' "$file" 2>/dev/null ;;
  esac
}

# Adoption changes customer.env by exactly the S1 marker; help must not retain
# the historical promise that it only writes the sidecar.
"$ROOT/bin/lucairn-init" --help > "$TMPDIR/lucairn-init-help.out"
grep -q 'append exactly LUCAIRN_RUNTIME_PROFILE_REQUIRED=1' "$TMPDIR/lucairn-init-help.out"
grep -q 'preserving all existing content and permissions' "$TMPDIR/lucairn-init-help.out"
grep -q 'publish the runtime-profile manifest' "$TMPDIR/lucairn-init-help.out"
! grep -q 'Never rewrites customer.env\.' "$TMPDIR/lucairn-init-help.out"

# A fresh install has no implicit inference fallback.
expect_fail missing-mode "$ROOT/bin/lucairn-init" --dev --output "$TMPDIR/missing.env" --skip-doctor
test ! -e "$TMPDIR/missing.env"
grep -q -- '--runtime-mode is required' "$TMPDIR/missing-mode.out"

# Topology selectors are singular inputs. Repeating one is ambiguous even when
# the repeated value is identical, and must fail before either artifact exists.
for selector_case in runtime-same runtime-conflict local-same local-conflict remote-same remote-conflict allowlist-same allowlist-conflict; do
  REPEAT_ENV="$TMPDIR/repeated-${selector_case}.env"
  case "$selector_case" in
    runtime-same)
      expect_fail "repeated-${selector_case}" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --runtime-mode local-runtime --local-runtime llama-cpp --output "$REPEAT_ENV" --skip-doctor
      ;;
    runtime-conflict)
      expect_fail "repeated-${selector_case}" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --runtime-mode split-remote --local-runtime llama-cpp --output "$REPEAT_ENV" --skip-doctor
      ;;
    local-same)
      expect_fail "repeated-${selector_case}" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --local-runtime llama-cpp --output "$REPEAT_ENV" --skip-doctor
      ;;
    local-conflict)
      expect_fail "repeated-${selector_case}" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --local-runtime vllm --output "$REPEAT_ENV" --skip-doctor
      ;;
    remote-same)
      expect_fail "repeated-${selector_case}" "$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint https://one.example.test --remote-endpoint https://one.example.test --output "$REPEAT_ENV" --skip-doctor
      ;;
    remote-conflict)
      expect_fail "repeated-${selector_case}" "$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint https://one.example.test --remote-endpoint https://two.example.test --output "$REPEAT_ENV" --skip-doctor
      ;;
    allowlist-same)
      expect_fail "repeated-${selector_case}" "$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --byok-allowlist api.one.example.test --byok-allowlist api.one.example.test --output "$REPEAT_ENV" --skip-doctor
      ;;
    allowlist-conflict)
      expect_fail "repeated-${selector_case}" "$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --byok-allowlist api.one.example.test --byok-allowlist api.two.example.test --output "$REPEAT_ENV" --skip-doctor
      ;;
  esac
  test ! -e "$REPEAT_ENV"
  test ! -e "$REPEAT_ENV.runtime-profile.yaml"
done

# Every accepted runtime selection emits deterministic, non-secret state.
LOCAL_ENV="$TMPDIR/local.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --output "$LOCAL_ENV" --skip-doctor >/dev/null
LOCAL_PROFILE="$LOCAL_ENV.runtime-profile.yaml"
grep -qx 'runtime_mode: local-runtime' "$LOCAL_PROFILE"
grep -qx 'local_runtime: llama-cpp' "$LOCAL_PROFILE"
grep -qx 'byok_egress_allowlist: none' "$LOCAL_PROFILE"
grep -qx 'LUCAIRN_RUNTIME_PROFILE_REQUIRED=1' "$LOCAL_ENV"
grep -A2 '^overlays:$' "$LOCAL_PROFILE" | grep -qx '  - docker-compose.self-hosted.yml'
grep -q '^      digest: sha256:' "$LOCAL_PROFILE"
grep -q '^  provenance: operator-declared$' "$LOCAL_PROFILE"
grep -q '^  availability: required-not-verified$' "$LOCAL_PROFILE"
grep -qx "  model_name: $(sed -n 's/^MODEL_NAME=//p' "$LOCAL_ENV")" "$LOCAL_PROFILE"
grep -qx "  model_file: $(sed -n 's/^MODEL_FILE=//p' "$LOCAL_ENV")" "$LOCAL_PROFILE"
grep -qx "  model_path: $(sed -n 's/^MODEL_PATH=//p' "$LOCAL_ENV")" "$LOCAL_PROFILE"
grep -qx '  path: adjacent-env-image-manifest' "$LOCAL_PROFILE"
test -f "$LOCAL_ENV.image-manifest.yaml"
cmp -s "$ROOT/image-manifest.yaml" "$LOCAL_ENV.image-manifest.yaml"
if grep -Eq '(API_KEY|PASSWORD|SECRET|TOKEN|PRIVATE|SIGNING|LICENSE)' "$LOCAL_PROFILE"; then
  echo "runtime profile leaked a secret-shaped field" >&2
  exit 1
fi

before_env="$(cksum "$LOCAL_ENV")"
before_profile="$(cksum "$LOCAL_PROFILE")"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --output "$LOCAL_ENV" --skip-doctor >/dev/null
test "$(cksum "$LOCAL_ENV")" = "$before_env"
test "$(cksum "$LOCAL_PROFILE")" = "$before_profile"
expect_fail conflicting-repeat "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime vllm --output "$LOCAL_ENV" --skip-doctor
test "$(cksum "$LOCAL_ENV")" = "$before_env"
grep -q 'conflicts with requested inputs' "$TMPDIR/conflicting-repeat.out"

# Byte-identical sidecar symlinks are never idempotent state: init must not
# follow them or mutate either the env or target.
SYMLINK_ENV="$TMPDIR/symlink-idempotent.env"
SYMLINK_TARGET="$TMPDIR/symlink-idempotent-target.yaml"
cp "$LOCAL_ENV" "$SYMLINK_ENV"
cp "$LOCAL_PROFILE" "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_ENV.runtime-profile.yaml"
symlink_env_before="$(cksum "$SYMLINK_ENV")"
symlink_target_before="$(cksum "$SYMLINK_TARGET")"
expect_fail symlink-idempotent "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$SYMLINK_ENV" --skip-doctor
test "$(cksum "$SYMLINK_ENV")" = "$symlink_env_before"
test "$(cksum "$SYMLINK_TARGET")" = "$symlink_target_before"
test -L "$SYMLINK_ENV.runtime-profile.yaml"

# An existing profile must reject duplicate optional BYOK fields even when a
# previous failed read would have been coerced to an empty local-mode value.
IDEMPOTENT_DUP_BYOK_ENV="$TMPDIR/idempotent-duplicate-byok.env"
cp "$LOCAL_ENV" "$IDEMPOTENT_DUP_BYOK_ENV"
cp "$LOCAL_PROFILE" "$IDEMPOTENT_DUP_BYOK_ENV.runtime-profile.yaml"
printf 'LUCAIRN_LLM_EGRESS_ALLOWLIST=unexpected.example.test\nLUCAIRN_LLM_EGRESS_ALLOWLIST=\n' >> "$IDEMPOTENT_DUP_BYOK_ENV"
idempotent_dup_byok_env_before="$(cksum "$IDEMPOTENT_DUP_BYOK_ENV")"
idempotent_dup_byok_profile_before="$(cksum "$IDEMPOTENT_DUP_BYOK_ENV.runtime-profile.yaml")"
expect_fail idempotent-duplicate-byok "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$IDEMPOTENT_DUP_BYOK_ENV" --skip-doctor
test "$(cksum "$IDEMPOTENT_DUP_BYOK_ENV")" = "$idempotent_dup_byok_env_before"
test "$(cksum "$IDEMPOTENT_DUP_BYOK_ENV.runtime-profile.yaml")" = "$idempotent_dup_byok_profile_before"

# A rerun compares the complete rendered profile plus runtime-relevant env,
# rather than accepting a matching five-field subset.
for tamper in overlay deployment image_tag env; do
  TAMPER_ENV="$TMPDIR/${tamper}.env"
  TAMPER_PROFILE="$TAMPER_ENV.runtime-profile.yaml"
  cp "$LOCAL_ENV" "$TAMPER_ENV"
  cp "$LOCAL_PROFILE" "$TAMPER_PROFILE"
  case "$tamper" in
    overlay) sed 's/docker-compose.self-hosted.yml/docker-compose.self-hosted-byok.yml/' "$TAMPER_PROFILE" > "$TAMPER_PROFILE.tmp" && mv "$TAMPER_PROFILE.tmp" "$TAMPER_PROFILE" ;;
    deployment) sed 's/deployment_profile: local-runtime/deployment_profile: managed-byok/' "$TAMPER_PROFILE" > "$TAMPER_PROFILE.tmp" && mv "$TAMPER_PROFILE.tmp" "$TAMPER_PROFILE" ;;
    image_tag) sed 's/^image_tag: .*/image_tag: tampered/' "$TAMPER_PROFILE" > "$TAMPER_PROFILE.tmp" && mv "$TAMPER_PROFILE.tmp" "$TAMPER_PROFILE" ;;
    env) printf 'MODEL_PATH=drifted\n' >> "$TAMPER_ENV" ;;
  esac
  tampered_env_before="$(cksum "$TAMPER_ENV")"
  tampered_profile_before="$(cksum "$TAMPER_PROFILE")"
  expect_fail "tampered-${tamper}" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$TAMPER_ENV" --skip-doctor
  test "$(cksum "$TAMPER_ENV")" = "$tampered_env_before"
  test "$(cksum "$TAMPER_PROFILE")" = "$tampered_profile_before"
done

expect_fail incomplete-local "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --output "$TMPDIR/incomplete.env" --skip-doctor
expect_fail incompatible-mode "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --byok --output "$TMPDIR/conflict.env" --skip-doctor

SPLIT_ENV="$TMPDIR/split.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode split/remote --remote-endpoint https://inference.example.test \
  --remote-credentials "$REMOTE_CREDENTIALS" --output "$SPLIT_ENV" --skip-doctor >/dev/null
grep -qx 'runtime_mode: split-remote' "$SPLIT_ENV.runtime-profile.yaml"
grep -qx 'byok_egress_allowlist: none' "$SPLIT_ENV.runtime-profile.yaml"
grep -qx 'SANDBOX_B_REMOTE_ENDPOINT=https://inference.example.test' "$SPLIT_ENV"
grep -qx 'SANDBOX_B_API_KEY=lcr-issued-test-api-key_123' "$SPLIT_ENV"
grep -qx 'LCR_SANDBOX_B_PUBLIC_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' "$SPLIT_ENV"
grep -qx 'LCR_SANDBOX_B_SIGNING_KEY=' "$SPLIT_ENV"
grep -A2 '^model_inventory:$' "$SPLIT_ENV.runtime-profile.yaml" | grep -qx '  provenance: not-applicable'
grep -A2 '^model_inventory:$' "$SPLIT_ENV.runtime-profile.yaml" | grep -qx '  local_model: none'

# Split remote authentication is an explicit secret-file contract in both dev
# and production paths. Endpoint + license alone can never publish state.
expect_fail split-missing-credentials "$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint https://inference.example.test --output "$TMPDIR/split-missing-credentials.env" --skip-doctor
for bad_credentials_case in blank-api duplicate-api placeholder-api bad-public sentinel-public repeated-byte-public extra-line; do
  BAD_CREDENTIALS="$TMPDIR/${bad_credentials_case}.env"
  case "$bad_credentials_case" in
    blank-api) printf 'sandbox_b_api_key=\nsandbox_b_public_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$BAD_CREDENTIALS" ;;
    duplicate-api) printf 'sandbox_b_api_key=one\nsandbox_b_api_key=two\nsandbox_b_public_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$BAD_CREDENTIALS" ;;
    placeholder-api) printf 'sandbox_b_api_key=REPLACE_WITH_REMOTE_KEY\nsandbox_b_public_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$BAD_CREDENTIALS" ;;
    bad-public) printf 'sandbox_b_api_key=lcr-issued-test-api-key_123\nsandbox_b_public_key=not-hex\n' > "$BAD_CREDENTIALS" ;;
    sentinel-public) printf 'sandbox_b_api_key=lcr-issued-test-api-key_123\nsandbox_b_public_key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$BAD_CREDENTIALS" ;;
    repeated-byte-public) printf 'sandbox_b_api_key=lcr-issued-test-api-key_123\nsandbox_b_public_key=abababababababababababababababababababababababababababababababab\n' > "$BAD_CREDENTIALS" ;;
    extra-line) printf 'sandbox_b_api_key=lcr-issued-test-api-key_123\nsandbox_b_public_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nextra=value\n' > "$BAD_CREDENTIALS" ;;
  esac
  expect_fail "split-${bad_credentials_case}" "$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint https://inference.example.test --remote-credentials "$BAD_CREDENTIALS" --output "$TMPDIR/split-${bad_credentials_case}.out.env" --skip-doctor
  test ! -e "$TMPDIR/split-${bad_credentials_case}.out.env"
done

# Doctor blocks blank or placeholder remote credentials before Compose/inference.
"$ROOT/bin/lucairn" doctor --env "$SPLIT_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check > "$TMPDIR/split-doctor.out"
grep -q 'doctor: ok' "$TMPDIR/split-doctor.out"
SPLIT_BLANK_API_ENV="$TMPDIR/split-blank-api.env"
cp "$SPLIT_ENV" "$SPLIT_BLANK_API_ENV"
cp "$SPLIT_ENV.runtime-profile.yaml" "$SPLIT_BLANK_API_ENV.runtime-profile.yaml"
cp "$SPLIT_ENV.image-manifest.yaml" "$SPLIT_BLANK_API_ENV.image-manifest.yaml"
printf 'SANDBOX_B_API_KEY=\n' >> "$SPLIT_BLANK_API_ENV"
expect_fail split-doctor-blank-api "$ROOT/bin/lucairn" doctor --env "$SPLIT_BLANK_API_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check
grep -q 'SANDBOX_B_API_KEY must be a non-empty' "$TMPDIR/split-doctor-blank-api.out"
SPLIT_SENTINEL_PUBLIC_ENV="$TMPDIR/split-sentinel-public.env"
cp "$SPLIT_ENV" "$SPLIT_SENTINEL_PUBLIC_ENV"
cp "$SPLIT_ENV.runtime-profile.yaml" "$SPLIT_SENTINEL_PUBLIC_ENV.runtime-profile.yaml"
cp "$SPLIT_ENV.image-manifest.yaml" "$SPLIT_SENTINEL_PUBLIC_ENV.image-manifest.yaml"
sed 's/^LCR_SANDBOX_B_PUBLIC_KEY=.*/LCR_SANDBOX_B_PUBLIC_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$SPLIT_SENTINEL_PUBLIC_ENV" > "$SPLIT_SENTINEL_PUBLIC_ENV.tmp"
mv "$SPLIT_SENTINEL_PUBLIC_ENV.tmp" "$SPLIT_SENTINEL_PUBLIC_ENV"
expect_fail split-doctor-sentinel-public "$ROOT/bin/lucairn" doctor --env "$SPLIT_SENTINEL_PUBLIC_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check
grep -q 'LCR_SANDBOX_B_PUBLIC_KEY looks like a repeating-character sentinel' "$TMPDIR/split-doctor-sentinel-public.out"
SPLIT_REPEATED_BYTE_PUBLIC_ENV="$TMPDIR/split-repeated-byte-public.env"
cp "$SPLIT_ENV" "$SPLIT_REPEATED_BYTE_PUBLIC_ENV"
cp "$SPLIT_ENV.runtime-profile.yaml" "$SPLIT_REPEATED_BYTE_PUBLIC_ENV.runtime-profile.yaml"
cp "$SPLIT_ENV.image-manifest.yaml" "$SPLIT_REPEATED_BYTE_PUBLIC_ENV.image-manifest.yaml"
sed 's/^LCR_SANDBOX_B_PUBLIC_KEY=.*/LCR_SANDBOX_B_PUBLIC_KEY=abababababababababababababababababababababababababababababababab/' "$SPLIT_REPEATED_BYTE_PUBLIC_ENV" > "$SPLIT_REPEATED_BYTE_PUBLIC_ENV.tmp"
mv "$SPLIT_REPEATED_BYTE_PUBLIC_ENV.tmp" "$SPLIT_REPEATED_BYTE_PUBLIC_ENV"
expect_fail split-doctor-repeated-byte-public "$ROOT/bin/lucairn" doctor --env "$SPLIT_REPEATED_BYTE_PUBLIC_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check
grep -q 'LCR_SANDBOX_B_PUBLIC_KEY (or legacy VEIL_SANDBOX_B_PUBLIC_KEY) must be a non-sentinel' "$TMPDIR/split-doctor-repeated-byte-public.out"

BYOK_ENV="$TMPDIR/byok.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$BYOK_ENV" --skip-doctor >/dev/null
grep -qx 'runtime_mode: managed-byok' "$BYOK_ENV.runtime-profile.yaml"
grep -qx 'byok_egress_allowlist: api.anthropic.com,api.openai.com' "$BYOK_ENV.runtime-profile.yaml"
test "$(sed -n '/^overlays:/,/^image_manifest:/p' "$BYOK_ENV.runtime-profile.yaml" | grep -c '^  - ' )" -eq 3
grep -A2 '^model_inventory:$' "$BYOK_ENV.runtime-profile.yaml" | grep -qx '  provenance: not-applicable'

# BYOK input and post-publication profile validation share the same FQDN-only
# grammar. Invalid host-like strings must not reach customer state.
for bad_byok_host in localhost runtime 127.0.0.1 123.456.789.000 api.example.com:443 'https://api.example.com' api.example.com/path '*.example.com' .api.example.com api..example.com api-.example.com -api.example.com; do
  expect_fail "bad-byok-${bad_byok_host//[^A-Za-z0-9]/_}" "$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --byok-allowlist "$bad_byok_host" --output "$TMPDIR/bad-byok.env" --skip-doctor
  test ! -e "$TMPDIR/bad-byok.env"
done
TAMPER_BYOK_ENV="$TMPDIR/tamper-byok.env"
cp "$BYOK_ENV" "$TAMPER_BYOK_ENV"
cp "$BYOK_ENV.runtime-profile.yaml" "$TAMPER_BYOK_ENV.runtime-profile.yaml"
sed 's/^byok_egress_allowlist:.*/byok_egress_allowlist: localhost/' "$TAMPER_BYOK_ENV.runtime-profile.yaml" > "$TAMPER_BYOK_ENV.tmp" && mv "$TAMPER_BYOK_ENV.tmp" "$TAMPER_BYOK_ENV.runtime-profile.yaml"
expect_fail tampered-byok-fqdn "$ROOT/bin/lucairn" doctor --env "$TAMPER_BYOK_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check

# Regeneration guidance is a shell-copyable description of the exact selected
# topology and cannot include any generated secret values.
CUSTOM_REGEN_ENV="$TMPDIR/custom-byok-regenerate.env"
CUSTOM_ALLOWLIST='api.customer.example,models.customer.example'
"$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --byok-allowlist "$CUSTOM_ALLOWLIST" \
  --image-tag custom-image --output "$CUSTOM_REGEN_ENV" --skip-doctor >/dev/null
grep -qx "byok_egress_allowlist: $CUSTOM_ALLOWLIST" "$CUSTOM_REGEN_ENV.runtime-profile.yaml"
grep -Fq -- "--runtime-mode split-remote --remote-endpoint 'https://inference.example.test' --remote-credentials '$REMOTE_CREDENTIALS' --output '$SPLIT_ENV'" "$SPLIT_ENV"
grep -Fq -- "--runtime-mode local-runtime --local-runtime 'llama-cpp' --model-name 'customer-model' --model-file 'customer-model-q4.gguf' --model-path '.' --output '$LOCAL_ENV'" "$LOCAL_ENV"
grep -Fq -- "--runtime-mode managed-byok --byok-allowlist '$CUSTOM_ALLOWLIST' --image-tag 'custom-image' --output '$CUSTOM_REGEN_ENV'" "$CUSTOM_REGEN_ENV"
if grep '^# Regenerate:' "$CUSTOM_REGEN_ENV" | grep -Eq '(DSA_|LCR_|PASSWORD|SECRET|TOKEN|PRIVATE|SIGNING|LICENSE_KEY)='; then
  echo "regeneration guidance leaked a generated secret" >&2
  exit 1
fi
PRODUCTION_LICENSE="$TMPDIR/license bundle.txt"
PRODUCTION_ENV="$TMPDIR/production output.env"
printf 'license_key=test-license\nsigning_key=test-signing\n' > "$PRODUCTION_LICENSE"
"$ROOT/bin/lucairn-init" --production --license "$PRODUCTION_LICENSE" --runtime-mode local-runtime --local-runtime llama-cpp \
  --output "$PRODUCTION_ENV" --skip-doctor >/dev/null
grep -Fq -- "--production --license '$PRODUCTION_LICENSE' --runtime-mode local-runtime --local-runtime 'llama-cpp' --model-name 'customer-model' --model-file 'customer-model-q4.gguf' --model-path '.' --output '$PRODUCTION_ENV'" "$PRODUCTION_ENV"

# The production example has exactly one literal continuation character, so
# users can paste it into a shell as documented.
grep -Fx '  ./bin/lucairn-init --production --license ~/lucairn-license.json \' "$ROOT/bin/lucairn-init"
if grep -Fx '  ./bin/lucairn-init --production --license ~/lucairn-license.json \\' "$ROOT/bin/lucairn-init"; then
  echo "production help example has two continuation characters" >&2
  exit 1
fi

# Credentials and line-injection payloads fail before either public artifact
# exists, so neither rejected value can leak into customer.env or the profile.
for bad_endpoint in \
  $'https://inference.example.test\nMODEL_PATH=owned' \
  'https://user:password@inference.example.test' \
  'https://good.example:99999' 'https://good.example:0' \
  'https://good.example:' \
  'https://a..b' 'https://a.-b' 'https://-a.b' \
  'https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example' \
  'https://good.example?ambiguous=true'; do
  BAD_ENV="$TMPDIR/bad-endpoint-${RANDOM}.env"
  expect_fail bad-endpoint "$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint "$bad_endpoint" --output "$BAD_ENV" --skip-doctor
  test ! -e "$BAD_ENV"
  test ! -e "$BAD_ENV.runtime-profile.yaml"
done

GOOD_ENDPOINT_ENV="$TMPDIR/good-endpoint.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint 'https://good.example:443/v1/models%2Fcurrent' --remote-credentials "$REMOTE_CREDENTIALS" --output "$GOOD_ENDPOINT_ENV" --skip-doctor >/dev/null

# Init must use the same strict grammar as the reader before either artifact
# exists. These were previously accepted values that rendered self-invalid
# YAML, plus file-path injection variants.
for invalid_init_case in endpoint-yaml-meta model-yaml-meta model-file-traversal model-file-absolute model-file-backslash model-path-mid-traversal; do
  INVALID_INIT_ENV="$TMPDIR/${invalid_init_case}.env"
  case "$invalid_init_case" in
    endpoint-yaml-meta)
      expect_fail "$invalid_init_case" "$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint 'https://inference.example.test/v1!models:' --output "$INVALID_INIT_ENV" --skip-doctor
      ;;
    model-yaml-meta)
      expect_fail "$invalid_init_case" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --model-name 'model&name' --model-file model.gguf --model-path . --output "$INVALID_INIT_ENV" --skip-doctor
      ;;
    model-file-traversal)
      expect_fail "$invalid_init_case" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --model-name model-name --model-file ../outside --model-path . --output "$INVALID_INIT_ENV" --skip-doctor
      ;;
    model-file-absolute)
      expect_fail "$invalid_init_case" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --model-name model-name --model-file /outside --model-path . --output "$INVALID_INIT_ENV" --skip-doctor
      ;;
    model-file-backslash)
      expect_fail "$invalid_init_case" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --model-name model-name --model-file 'inside\outside.gguf' --model-path . --output "$INVALID_INIT_ENV" --skip-doctor
      ;;
    model-path-mid-traversal)
      expect_fail "$invalid_init_case" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --model-name model-name --model-file inside.gguf --model-path 'models/../outside' --output "$INVALID_INIT_ENV" --skip-doctor
      ;;
  esac
  test ! -e "$INVALID_INIT_ENV"
  test ! -e "$INVALID_INIT_ENV.runtime-profile.yaml"
done

# A simulated profile publication failure rolls back the fresh pair. The hook
# is test-only and is checked before production's first publish operation.
PUBLISH_FAIL_ENV="$TMPDIR/publish-fail.env"
expect_fail profile-publication env LUCAIRN_TEST_FAIL_RUNTIME_PROFILE_PUBLISH=1 "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$PUBLISH_FAIL_ENV" --skip-doctor
test ! -e "$PUBLISH_FAIL_ENV"
test ! -e "$PUBLISH_FAIL_ENV.runtime-profile.yaml"
test ! -e "$PUBLISH_FAIL_ENV.image-manifest.yaml"

# Fresh publication is exclusive for every collision type and rolls back the
# profile if the second (env) publication cannot proceed.
for collision in directory symlink regular; do
  COLLIDE_ENV="$TMPDIR/collision-${collision}.env"
  COLLIDE_PROFILE="$COLLIDE_ENV.runtime-profile.yaml"
  case "$collision" in
    directory) mkdir "$COLLIDE_PROFILE" ;;
    symlink) ln -s "$TMPDIR/nowhere" "$COLLIDE_PROFILE" ;;
    regular) : > "$COLLIDE_PROFILE" ;;
  esac
  expect_fail "collision-${collision}" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$COLLIDE_ENV" --skip-doctor
  test ! -e "$COLLIDE_ENV"
  case "$collision" in directory) test -d "$COLLIDE_PROFILE" ;; symlink) test -L "$COLLIDE_PROFILE" ;; regular) test -f "$COLLIDE_PROFILE" ;; esac
done
SECOND_FAIL_ENV="$TMPDIR/second-publish.env"
expect_fail second-publication env LUCAIRN_TEST_FAIL_ENV_PUBLISH=1 "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$SECOND_FAIL_ENV" --skip-doctor
test ! -e "$SECOND_FAIL_ENV"
test ! -e "$SECOND_FAIL_ENV.runtime-profile.yaml"
test ! -e "$SECOND_FAIL_ENV.image-manifest.yaml"

# Deterministic transaction races: a deleted/replaced sidecar never allows the
# fresh env to publish. Replacement ownership is preserved (never unlinked by
# cleanup) and therefore remains an explicit fail-closed split state.
for fresh_race in delete replace; do
  FRESH_RACE_ENV="$TMPDIR/fresh-race-${fresh_race}.env"
  expect_fail "fresh-race-${fresh_race}" env LUCAIRN_TEST_TRANSACTION_HOOK="fresh-after-profile:${fresh_race}" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$FRESH_RACE_ENV" --skip-doctor
  test ! -e "$FRESH_RACE_ENV"
  case "$fresh_race" in
    delete) test ! -e "$FRESH_RACE_ENV.runtime-profile.yaml" ;;
    replace)
      test -f "$FRESH_RACE_ENV.runtime-profile.yaml"
      grep -q 'attacker replacement' "$FRESH_RACE_ENV.runtime-profile.yaml"
      ;;
  esac
  test ! -d "$TMPDIR/.lucairn-init.lock"
done

# These hooks fire inside the publication primitives immediately after their
# respective final name becomes visible.  Parent-owned staged identities must
# let signal cleanup remove both fresh artifacts before a new writer takes the
# same directory lock.
for fresh_visible in profile env; do
  FRESH_SIGNAL_ENV="$TMPDIR/fresh-${fresh_visible}-visible-signal.env"
  expect_fail "fresh-${fresh_visible}-visible-signal" \
    env LUCAIRN_TEST_TRANSACTION_HOOK="fresh-${fresh_visible}-visible:signal" \
    "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
    --output "$FRESH_SIGNAL_ENV" --skip-doctor
  test ! -e "$FRESH_SIGNAL_ENV"
  test ! -L "$FRESH_SIGNAL_ENV"
  test ! -e "$FRESH_SIGNAL_ENV.runtime-profile.yaml"
  test ! -L "$FRESH_SIGNAL_ENV.runtime-profile.yaml"
  test ! -e "$FRESH_SIGNAL_ENV.image-manifest.yaml"
  test ! -L "$FRESH_SIGNAL_ENV.image-manifest.yaml"
  test ! -d "$TMPDIR/.lucairn-init.lock"
  assert_install_lock_reacquirable "fresh-${fresh_visible}-lock-reacquired"
done

# A pre-S1 installation remains usable until the operator explicitly adopts a
# matching profile; a corrupt present manifest is never silently ignored.
LEGACY_ENV="$TMPDIR/legacy.env"
cp "$LOCAL_ENV" "$LEGACY_ENV"
sed -e '/^LUCAIRN_RUNTIME_PROFILE_REQUIRED=/d' \
    -e 's/^MODEL_NAME=.*/MODEL_NAME=preserved-model/' \
    -e 's/^MODEL_FILE=.*/MODEL_FILE=preserved-model.gguf/' \
    -e 's|^MODEL_PATH=.*|MODEL_PATH=../preserved-models|' \
    "$LEGACY_ENV" > "$LEGACY_ENV.tmp" && mv "$LEGACY_ENV.tmp" "$LEGACY_ENV"
legacy_before="$(cksum "$LEGACY_ENV")"
legacy_before_copy="$TMPDIR/legacy-before.env"
cp "$LEGACY_ENV" "$legacy_before_copy"
legacy_mode="$(file_mode "$LEGACY_ENV")"
"$ROOT/bin/lucairn" doctor --env "$LEGACY_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check >"$TMPDIR/legacy-doctor.out"
grep -q 'runtime profile: legacy install' "$TMPDIR/legacy-doctor.out"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --adopt-runtime-profile --output "$LEGACY_ENV" --skip-doctor >/dev/null
# Adoption is intentionally not byte-identical: it preserves all prior bytes,
# settings, secrets, and permissions while atomically adding the one S1 marker.
grep -qx 'LUCAIRN_RUNTIME_PROFILE_REQUIRED=1' "$LEGACY_ENV"
sed '/^LUCAIRN_RUNTIME_PROFILE_REQUIRED=1$/d' "$LEGACY_ENV" > "$TMPDIR/legacy-without-marker.env"
cmp -s "$legacy_before_copy" "$TMPDIR/legacy-without-marker.env"
test "$(file_mode "$LEGACY_ENV")" = "$legacy_mode"
test -f "$LEGACY_ENV.runtime-profile.yaml"
grep -qx '  model_name: preserved-model' "$LEGACY_ENV.runtime-profile.yaml"
grep -qx '  model_file: preserved-model.gguf' "$LEGACY_ENV.runtime-profile.yaml"
grep -qx '  model_path: ../preserved-models' "$LEGACY_ENV.runtime-profile.yaml"
printf 'schema_version: 999\n' > "$LEGACY_ENV.runtime-profile.yaml"
expect_fail corrupt-state "$ROOT/bin/lucairn" doctor --env "$LEGACY_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check
grep -q 'runtime profile: failed' "$TMPDIR/corrupt-state.out"

# An explicit adoption failure never changes the legacy env.
ADOPT_ENV="$TMPDIR/adopt-preserved.env"
copy_pre_s1_env "$LOCAL_ENV" "$ADOPT_ENV"
rm -f "$ADOPT_ENV.runtime-profile.yaml"
adopt_before="$(cksum "$ADOPT_ENV")"
mkdir "$ADOPT_ENV.runtime-profile.yaml"
expect_fail adopt-directory "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --adopt-runtime-profile --output "$ADOPT_ENV" --skip-doctor
test "$(cksum "$ADOPT_ENV")" = "$adopt_before"

# A signal/failure during adoption restores the exact pre-adoption env and
# leaves no S1 sidecar or stale lock.
for adoption_abort in signal fail-after-env; do
  ADOPTION_ABORT_ENV="$TMPDIR/adoption-abort-${adoption_abort}.env"
  copy_pre_s1_env "$LOCAL_ENV" "$ADOPTION_ABORT_ENV"
  rm -f "$ADOPTION_ABORT_ENV.runtime-profile.yaml"
  cp "$ADOPTION_ABORT_ENV" "$ADOPTION_ABORT_ENV.before"
  adoption_abort_mode="$(file_mode "$ADOPTION_ABORT_ENV")"
  case "$adoption_abort" in
    signal)
      expect_fail "adoption-abort-${adoption_abort}" env LUCAIRN_TEST_TRANSACTION_HOOK=adoption-after-profile:signal "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --adopt-runtime-profile --output "$ADOPTION_ABORT_ENV" --skip-doctor
      ;;
    fail-after-env)
      expect_fail "adoption-abort-${adoption_abort}" env LUCAIRN_TEST_FAIL_ADOPTION_AFTER_ENV_PUBLISH=1 "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --adopt-runtime-profile --output "$ADOPTION_ABORT_ENV" --skip-doctor
      ;;
  esac
  cmp -s "$ADOPTION_ABORT_ENV.before" "$ADOPTION_ABORT_ENV"
  test "$(file_mode "$ADOPTION_ABORT_ENV")" = "$adoption_abort_mode"
  test ! -e "$ADOPTION_ABORT_ENV.runtime-profile.yaml"
  test ! -e "$ADOPTION_ABORT_ENV.image-manifest.yaml"
  test ! -d "$TMPDIR/.lucairn-init.lock"
done

# os.replace signals the parent from inside the adoption publication primitive,
# after the new env is visible but before normal return.  Cleanup restores only
# the staged identity, leaving the exact legacy bytes/mode and no sidecar.
ADOPTION_VISIBLE_SIGNAL_ENV="$TMPDIR/adoption-env-visible-signal.env"
copy_pre_s1_env "$LOCAL_ENV" "$ADOPTION_VISIBLE_SIGNAL_ENV"
rm -f "$ADOPTION_VISIBLE_SIGNAL_ENV.runtime-profile.yaml"
cp "$ADOPTION_VISIBLE_SIGNAL_ENV" "$ADOPTION_VISIBLE_SIGNAL_ENV.before"
adoption_visible_signal_mode="$(file_mode "$ADOPTION_VISIBLE_SIGNAL_ENV")"
expect_fail adoption-env-visible-signal \
  env LUCAIRN_TEST_TRANSACTION_HOOK=adoption-env-visible:signal \
  "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --adopt-runtime-profile --output "$ADOPTION_VISIBLE_SIGNAL_ENV" --skip-doctor
cmp -s "$ADOPTION_VISIBLE_SIGNAL_ENV.before" "$ADOPTION_VISIBLE_SIGNAL_ENV"
test "$(file_mode "$ADOPTION_VISIBLE_SIGNAL_ENV")" = "$adoption_visible_signal_mode"
test ! -e "$ADOPTION_VISIBLE_SIGNAL_ENV.runtime-profile.yaml"
test ! -L "$ADOPTION_VISIBLE_SIGNAL_ENV.runtime-profile.yaml"
test ! -e "$ADOPTION_VISIBLE_SIGNAL_ENV.image-manifest.yaml"
test ! -d "$TMPDIR/.lucairn-init.lock"
assert_install_lock_reacquirable adoption-env-visible-lock-reacquired

# The first TERM arrives after the adopted env becomes visible. The test-only
# cleanup hook sends a second TERM while rollback and lock release are pending;
# it must be ignored so the original signal exit and exact legacy state survive.
ADOPTION_DOUBLE_SIGNAL_ENV="$TMPDIR/adoption-double-signal.env"
copy_pre_s1_env "$LOCAL_ENV" "$ADOPTION_DOUBLE_SIGNAL_ENV"
rm -f "$ADOPTION_DOUBLE_SIGNAL_ENV.runtime-profile.yaml"
cp "$ADOPTION_DOUBLE_SIGNAL_ENV" "$ADOPTION_DOUBLE_SIGNAL_ENV.before"
adoption_double_signal_mode="$(file_mode "$ADOPTION_DOUBLE_SIGNAL_ENV")"
if env LUCAIRN_TEST_TRANSACTION_HOOK=adoption-env-visible:signal LUCAIRN_TEST_CLEANUP_HOOK=second-term \
  "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --adopt-runtime-profile --output "$ADOPTION_DOUBLE_SIGNAL_ENV" --skip-doctor \
  >"$TMPDIR/adoption-double-signal.out" 2>&1; then
  echo "expected double-signal adoption cleanup failure" >&2
  exit 1
else
  adoption_double_signal_status=$?
fi
test "$adoption_double_signal_status" -eq 143
cmp -s "$ADOPTION_DOUBLE_SIGNAL_ENV.before" "$ADOPTION_DOUBLE_SIGNAL_ENV"
test "$(file_mode "$ADOPTION_DOUBLE_SIGNAL_ENV")" = "$adoption_double_signal_mode"
test ! -L "$ADOPTION_DOUBLE_SIGNAL_ENV"
test ! -e "$ADOPTION_DOUBLE_SIGNAL_ENV.runtime-profile.yaml"
test ! -L "$ADOPTION_DOUBLE_SIGNAL_ENV.runtime-profile.yaml"
test ! -e "$ADOPTION_DOUBLE_SIGNAL_ENV.image-manifest.yaml"
test ! -d "$TMPDIR/.lucairn-init.lock"
assert_install_lock_reacquirable adoption-double-signal-lock-reacquired

# Adoption and existing-profile idempotency share the same exact runtime-env
# contract.  Older optional fields may be absent when empty, but duplicate
# runtime selectors must never be resolved by choosing the last value.
DUP_SELECTOR_ENV="$TMPDIR/adopt-duplicate-selector.env"
copy_pre_s1_env "$LOCAL_ENV" "$DUP_SELECTOR_ENV"
rm -f "$DUP_SELECTOR_ENV.runtime-profile.yaml"
printf 'MODEL_RUNTIME_PROFILE=wrong-runtime\nMODEL_RUNTIME_PROFILE=llama-cpp\n' >> "$DUP_SELECTOR_ENV"
dup_selector_before="$(cksum "$DUP_SELECTOR_ENV")"
expect_fail adopt-duplicate-selector "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --adopt-runtime-profile --output "$DUP_SELECTOR_ENV" --skip-doctor
test "$(cksum "$DUP_SELECTOR_ENV")" = "$dup_selector_before"
test ! -e "$DUP_SELECTOR_ENV.runtime-profile.yaml"

DUP_ENDPOINT_ENV="$TMPDIR/adopt-duplicate-endpoint.env"
copy_pre_s1_env "$SPLIT_ENV" "$DUP_ENDPOINT_ENV"
rm -f "$DUP_ENDPOINT_ENV.runtime-profile.yaml"
printf 'SANDBOX_B_REMOTE_ENDPOINT=https://wrong.example.test\nSANDBOX_B_REMOTE_ENDPOINT=https://inference.example.test\n' >> "$DUP_ENDPOINT_ENV"
dup_endpoint_before="$(cksum "$DUP_ENDPOINT_ENV")"
expect_fail adopt-duplicate-endpoint "$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint https://inference.example.test --remote-credentials "$REMOTE_CREDENTIALS" --adopt-runtime-profile --output "$DUP_ENDPOINT_ENV" --skip-doctor
test "$(cksum "$DUP_ENDPOINT_ENV")" = "$dup_endpoint_before"
test ! -e "$DUP_ENDPOINT_ENV.runtime-profile.yaml"

# Adoption binds the issued remote API/public pair before mutating a legacy
# split env, but does not reject an otherwise unused historical local signing
# field: the remote seed remains remote and is not part of split coherence.
SPLIT_ADOPT_ENV="$TMPDIR/adopt-split-credentials.env"
copy_pre_s1_env "$SPLIT_ENV" "$SPLIT_ADOPT_ENV"
rm -f "$SPLIT_ADOPT_ENV.runtime-profile.yaml" "$SPLIT_ADOPT_ENV.image-manifest.yaml"
printf 'LCR_SANDBOX_B_SIGNING_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >> "$SPLIT_ADOPT_ENV"
SPLIT_ADOPT_BEFORE="$(cksum "$SPLIT_ADOPT_ENV")"
MISMATCH_REMOTE_CREDENTIALS="$TMPDIR/mismatched-remote-credentials.env"
printf 'sandbox_b_api_key=lcr-issued-different-api-key\nsandbox_b_public_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$MISMATCH_REMOTE_CREDENTIALS"
expect_fail adopt-split-credentials-mismatch "$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint https://inference.example.test --remote-credentials "$MISMATCH_REMOTE_CREDENTIALS" --adopt-runtime-profile --output "$SPLIT_ADOPT_ENV" --skip-doctor
test "$(cksum "$SPLIT_ADOPT_ENV")" = "$SPLIT_ADOPT_BEFORE"
"$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint https://inference.example.test --remote-credentials "$REMOTE_CREDENTIALS" --adopt-runtime-profile --output "$SPLIT_ADOPT_ENV" --skip-doctor >/dev/null
grep -qx 'LUCAIRN_RUNTIME_PROFILE_REQUIRED=1' "$SPLIT_ADOPT_ENV"

DUP_ALLOWLIST_ENV="$TMPDIR/adopt-duplicate-allowlist.env"
copy_pre_s1_env "$BYOK_ENV" "$DUP_ALLOWLIST_ENV"
rm -f "$DUP_ALLOWLIST_ENV.runtime-profile.yaml"
printf 'LUCAIRN_LLM_EGRESS_ALLOWLIST=wrong.example.test\nLUCAIRN_LLM_EGRESS_ALLOWLIST=api.anthropic.com,api.openai.com\n' >> "$DUP_ALLOWLIST_ENV"
dup_allowlist_before="$(cksum "$DUP_ALLOWLIST_ENV")"
expect_fail adopt-duplicate-allowlist "$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --adopt-runtime-profile --output "$DUP_ALLOWLIST_ENV" --skip-doctor
test "$(cksum "$DUP_ALLOWLIST_ENV")" = "$dup_allowlist_before"
test ! -e "$DUP_ALLOWLIST_ENV.runtime-profile.yaml"

IMAGE_MISMATCH_ENV="$TMPDIR/adopt-image-mismatch.env"
copy_pre_s1_env "$LOCAL_ENV" "$IMAGE_MISMATCH_ENV"
rm -f "$IMAGE_MISMATCH_ENV.runtime-profile.yaml"
sed 's/^LUCAIRN_IMAGE_TAG=.*/LUCAIRN_IMAGE_TAG=other-tag/' "$IMAGE_MISMATCH_ENV" > "$IMAGE_MISMATCH_ENV.tmp" && mv "$IMAGE_MISMATCH_ENV.tmp" "$IMAGE_MISMATCH_ENV"
image_mismatch_before="$(cksum "$IMAGE_MISMATCH_ENV")"
expect_fail adopt-image-mismatch "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --adopt-runtime-profile --output "$IMAGE_MISMATCH_ENV" --skip-doctor
test "$(cksum "$IMAGE_MISMATCH_ENV")" = "$image_mismatch_before"
test ! -e "$IMAGE_MISMATCH_ENV.runtime-profile.yaml"

DEPLOYMENT_MISMATCH_ENV="$TMPDIR/adopt-deployment-mismatch.env"
copy_pre_s1_env "$LOCAL_ENV" "$DEPLOYMENT_MISMATCH_ENV"
rm -f "$DEPLOYMENT_MISMATCH_ENV.runtime-profile.yaml"
sed 's/^DSA_ENV=.*/DSA_ENV=production/' "$DEPLOYMENT_MISMATCH_ENV" > "$DEPLOYMENT_MISMATCH_ENV.tmp" && mv "$DEPLOYMENT_MISMATCH_ENV.tmp" "$DEPLOYMENT_MISMATCH_ENV"
deployment_mismatch_before="$(cksum "$DEPLOYMENT_MISMATCH_ENV")"
expect_fail adopt-deployment-mismatch "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --adopt-runtime-profile --output "$DEPLOYMENT_MISMATCH_ENV" --skip-doctor
test "$(cksum "$DEPLOYMENT_MISMATCH_ENV")" = "$deployment_mismatch_before"
test ! -e "$DEPLOYMENT_MISMATCH_ENV.runtime-profile.yaml"

# A legacy managed-BYOK allowlist is adopted only when the operator explicitly
# selects the same allowlist, rather than silently accepting any custom value.
CUSTOM_BYOK_ENV="$TMPDIR/adopt-custom-byok.env"
copy_pre_s1_env "$BYOK_ENV" "$CUSTOM_BYOK_ENV"
rm -f "$CUSTOM_BYOK_ENV.runtime-profile.yaml"
sed 's/^LUCAIRN_LLM_EGRESS_ALLOWLIST=.*/LUCAIRN_LLM_EGRESS_ALLOWLIST=api.customer.example/' "$CUSTOM_BYOK_ENV" > "$CUSTOM_BYOK_ENV.tmp" && mv "$CUSTOM_BYOK_ENV.tmp" "$CUSTOM_BYOK_ENV"
custom_byok_before="$(cksum "$CUSTOM_BYOK_ENV")"
expect_fail adopt-custom-byok-default "$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --adopt-runtime-profile --output "$CUSTOM_BYOK_ENV" --skip-doctor
test "$(cksum "$CUSTOM_BYOK_ENV")" = "$custom_byok_before"
test ! -e "$CUSTOM_BYOK_ENV.runtime-profile.yaml"
"$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --byok-allowlist api.customer.example --adopt-runtime-profile --output "$CUSTOM_BYOK_ENV" --skip-doctor >/dev/null
grep -qx 'LUCAIRN_RUNTIME_PROFILE_REQUIRED=1' "$CUSTOM_BYOK_ENV"
sed '/^LUCAIRN_RUNTIME_PROFILE_REQUIRED=1$/d' "$CUSTOM_BYOK_ENV" > "$TMPDIR/custom-byok-without-marker.env"
custom_byok_original="$TMPDIR/custom-byok-before.env"
copy_pre_s1_env "$BYOK_ENV" "$custom_byok_original"
sed 's/^LUCAIRN_LLM_EGRESS_ALLOWLIST=.*/LUCAIRN_LLM_EGRESS_ALLOWLIST=api.customer.example/' "$custom_byok_original" > "$custom_byok_original.tmp" && mv "$custom_byok_original.tmp" "$custom_byok_original"
cmp -s "$custom_byok_original" "$TMPDIR/custom-byok-without-marker.env"
grep -qx 'runtime_mode: managed-byok' "$CUSTOM_BYOK_ENV.runtime-profile.yaml"
grep -qx 'byok_egress_allowlist: api.customer.example' "$CUSTOM_BYOK_ENV.runtime-profile.yaml"

# Explicit adoption is deletion-detectable in every supported topology.  Once
# it succeeds, removing its sidecar must never reclassify the env as legacy.
for adopted_mode in split-remote managed-byok local-runtime; do
  ADOPT_DELETE_ENV="$TMPDIR/adopt-delete-${adopted_mode}.env"
  case "$adopted_mode" in
    split-remote)
      copy_pre_s1_env "$SPLIT_ENV" "$ADOPT_DELETE_ENV"
      "$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint https://inference.example.test --remote-credentials "$REMOTE_CREDENTIALS" --adopt-runtime-profile --output "$ADOPT_DELETE_ENV" --skip-doctor >/dev/null
      ;;
    managed-byok)
      copy_pre_s1_env "$BYOK_ENV" "$ADOPT_DELETE_ENV"
      "$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --adopt-runtime-profile --output "$ADOPT_DELETE_ENV" --skip-doctor >/dev/null
      ;;
    local-runtime)
      copy_pre_s1_env "$LOCAL_ENV" "$ADOPT_DELETE_ENV"
      "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --adopt-runtime-profile --output "$ADOPT_DELETE_ENV" --skip-doctor >/dev/null
      ;;
  esac
  grep -qx 'LUCAIRN_RUNTIME_PROFILE_REQUIRED=1' "$ADOPT_DELETE_ENV"
  rm -f "$ADOPT_DELETE_ENV.runtime-profile.yaml"
  expect_fail "adopt-delete-${adopted_mode}" "$ROOT/bin/lucairn" doctor --env "$ADOPT_DELETE_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check
  grep -q 'LUCAIRN_RUNTIME_PROFILE_REQUIRED=1 requires' "$TMPDIR/adopt-delete-${adopted_mode}.out"
done

# The allowlist is canonical profile state: a profile-only drift is rejected
# on idempotent reuse and neither artifact is repaired or overwritten.
sed 's/^byok_egress_allowlist: .*/byok_egress_allowlist: api.drift.example/' "$CUSTOM_BYOK_ENV.runtime-profile.yaml" > "$CUSTOM_BYOK_ENV.runtime-profile.yaml.tmp" && mv "$CUSTOM_BYOK_ENV.runtime-profile.yaml.tmp" "$CUSTOM_BYOK_ENV.runtime-profile.yaml"
custom_byok_env_drift_before="$(cksum "$CUSTOM_BYOK_ENV")"
custom_byok_profile_drift_before="$(cksum "$CUSTOM_BYOK_ENV.runtime-profile.yaml")"
expect_fail idempotent-custom-byok-profile-drift "$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --byok-allowlist api.customer.example --output "$CUSTOM_BYOK_ENV" --skip-doctor
test "$(cksum "$CUSTOM_BYOK_ENV")" = "$custom_byok_env_drift_before"
test "$(cksum "$CUSTOM_BYOK_ENV.runtime-profile.yaml")" = "$custom_byok_profile_drift_before"

# The doctor rejects a hybrid remote endpoint in managed/local state.
HYBRID_ENV="$TMPDIR/hybrid.env"
cp "$LOCAL_ENV" "$HYBRID_ENV"
cp "$LOCAL_PROFILE" "$HYBRID_ENV.runtime-profile.yaml"
printf 'SANDBOX_B_REMOTE_ENDPOINT=https://leftover.example.test\n' >> "$HYBRID_ENV"
expect_fail hybrid-local "$ROOT/bin/lucairn" doctor --env "$HYBRID_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check
HYBRID_BYOK_ENV="$TMPDIR/hybrid-byok.env"
cp "$BYOK_ENV" "$HYBRID_BYOK_ENV"
cp "$BYOK_ENV.runtime-profile.yaml" "$HYBRID_BYOK_ENV.runtime-profile.yaml"
printf 'SANDBOX_B_REMOTE_ENDPOINT=https://leftover.example.test\n' >> "$HYBRID_BYOK_ENV"
expect_fail hybrid-byok "$ROOT/bin/lucairn" doctor --env "$HYBRID_BYOK_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check

# Strict readers reject duplicate profile/env state before support-bundle can
# copy it, rather than selecting the first or last value.
DUP_PROFILE_ENV="$TMPDIR/duplicate-profile.env"
cp "$LOCAL_ENV" "$DUP_PROFILE_ENV"
cp "$LOCAL_PROFILE" "$DUP_PROFILE_ENV.runtime-profile.yaml"
printf 'runtime_mode: split-remote\n' >> "$DUP_PROFILE_ENV.runtime-profile.yaml"
expect_fail duplicate-profile "$ROOT/bin/lucairn" support-bundle --env "$DUP_PROFILE_ENV" --compose "$ROOT/docker-compose.customer.yml" --output "$TMPDIR/duplicate-profile-bundles"
test ! -e "$TMPDIR/duplicate-profile-bundles"
DUP_ENV="$TMPDIR/duplicate-env.env"
cp "$LOCAL_ENV" "$DUP_ENV"
cp "$LOCAL_PROFILE" "$DUP_ENV.runtime-profile.yaml"
printf 'MODEL_RUNTIME_PROFILE=vllm\n' >> "$DUP_ENV"
expect_fail duplicate-env "$ROOT/bin/lucairn" support-bundle --env "$DUP_ENV" --compose "$ROOT/docker-compose.customer.yml" --output "$TMPDIR/duplicate-env-bundles"
test ! -e "$TMPDIR/duplicate-env-bundles"

# A sidecar itself declares S1 material; marker-less sidecar state is not a
# legacy fallback, including when the sidecar otherwise parses correctly.
SIDECAR_WITHOUT_MARKER_ENV="$TMPDIR/sidecar-without-marker.env"
copy_pre_s1_env "$LOCAL_ENV" "$SIDECAR_WITHOUT_MARKER_ENV"
cp "$LOCAL_PROFILE" "$SIDECAR_WITHOUT_MARKER_ENV.runtime-profile.yaml"
expect_fail sidecar-without-marker "$ROOT/bin/lucairn" doctor --env "$SIDECAR_WITHOUT_MARKER_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check
grep -q 'requires LUCAIRN_RUNTIME_PROFILE_REQUIRED=1' "$TMPDIR/sidecar-without-marker.out"

# A generated S1 env cannot silently fall back to legacy if its sidecar is
# deleted. Each command must fail before creating output or invoking runtime
# tooling; genuine marker-absent pre-S1 envs remain covered above.
MISSING_PROFILE_ENV="$TMPDIR/missing-profile.env"
cp "$LOCAL_ENV" "$MISSING_PROFILE_ENV"
expect_fail missing-profile-doctor "$ROOT/bin/lucairn" doctor --env "$MISSING_PROFILE_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check
expect_fail missing-profile-support "$ROOT/bin/lucairn" support-bundle --env "$MISSING_PROFILE_ENV" --compose "$ROOT/docker-compose.customer.yml" --output "$TMPDIR/missing-profile-support"
test ! -e "$TMPDIR/missing-profile-support"
MISSING_MODELS="$TMPDIR/missing-profile-models"
mkdir "$MISSING_MODELS"
printf 'model\n' > "$MISSING_MODELS/customer-model-q4.gguf"
if command -v sha256sum >/dev/null 2>&1; then MISSING_MODEL_SHA="$(sha256sum "$MISSING_MODELS/customer-model-q4.gguf" | awk '{print $1}')"; else MISSING_MODEL_SHA="$(shasum -a 256 "$MISSING_MODELS/customer-model-q4.gguf" | awk '{print $1}')"; fi
cat > "$TMPDIR/missing-profile-model-manifest.yaml" <<EOF
model:
  name: customer-model
  format: gguf
  runtime: llama-cpp
  files:
    - path: customer-model-q4.gguf
      sha256: $MISSING_MODEL_SHA
  checksum_policy: sha256-required
EOF
expect_fail missing-profile-bundle-create "$ROOT/bin/lucairn" bundle create --customer-slug missing-profile --models-dir "$MISSING_MODELS" --model-manifest "$TMPDIR/missing-profile-model-manifest.yaml" --env "$MISSING_PROFILE_ENV" --output "$TMPDIR/missing-profile-bundle"
test ! -e "$TMPDIR/missing-profile-bundle"
MISSING_STAGE="$TMPDIR/missing-profile-stage"
mkdir -p "$MISSING_STAGE/models"
cp "$MISSING_PROFILE_ENV" "$MISSING_STAGE/customer.env"
cp "$TMPDIR/missing-profile-model-manifest.yaml" "$MISSING_STAGE/models/model-manifest.yaml"
cp "$MISSING_MODELS/customer-model-q4.gguf" "$MISSING_STAGE/models/customer-model-q4.gguf"
expect_fail missing-profile-bundle-prepare "$ROOT/bin/lucairn" bundle prepare --customer-slug missing-profile --staging-dir "$MISSING_STAGE" --output "$TMPDIR/missing-profile-prepare"
test ! -e "$TMPDIR/missing-profile-prepare"
expect_fail missing-profile-backup "$ROOT/bin/lucairn" backup --env "$MISSING_PROFILE_ENV" --compose "$ROOT/docker-compose.customer.yml"
expect_fail missing-profile-restore "$ROOT/bin/lucairn" restore --env "$MISSING_PROFILE_ENV" --compose "$ROOT/docker-compose.customer.yml" --stamp 20260715T000000Z
for missing_profile_case in doctor support bundle-create bundle-prepare backup restore; do
  grep -q 'LUCAIRN_RUNTIME_PROFILE_REQUIRED=1 requires' "$TMPDIR/missing-profile-${missing_profile_case}.out"
done

# The distributed manual template has no active S1 marker, so copying it alone
# is diagnosed as legacy/manual state rather than a broken marker/sidecar pair.
TEMPLATE_ENV="$TMPDIR/template-alone.env"
cp "$ROOT/customer.env.example" "$TEMPLATE_ENV"
expect_fail template-alone "$ROOT/bin/lucairn" doctor --env "$TEMPLATE_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check
grep -q 'runtime profile: legacy install' "$TMPDIR/template-alone.out"
if grep -q 'LUCAIRN_RUNTIME_PROFILE_REQUIRED=1 requires' "$TMPDIR/template-alone.out"; then
  echo "template alone must not be classified as broken S1 state" >&2
  exit 1
fi

# Lifecycle compose invocations retain ordered overlays and append the selected
# runtime profile after them. A minimal docker stub records support-bundle's
# Compose calls without needing a daemon.
DOCKER_STUB_DIR="$TMPDIR/docker-stub"
mkdir -p "$DOCKER_STUB_DIR"
cat > "$DOCKER_STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = compose ]; then
  shift
  if [ "$1" = version ]; then exit 0; fi
  printf '%s\n' "$*" >> "$LUCAIRN_TEST_COMPOSE_ARGS"
  exit 0
fi
exit 1
STUB
chmod +x "$DOCKER_STUB_DIR/docker"
LUCAIRN_TEST_COMPOSE_ARGS="$TMPDIR/compose-args" PATH="$DOCKER_STUB_DIR:$PATH" \
  "$ROOT/bin/lucairn" support-bundle --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --output "$TMPDIR/bundles" >/dev/null
grep -q -- "-f $ROOT/docker-compose.customer.yml -f $ROOT/docker-compose.self-hosted.yml --profile llama-cpp --env-file $LOCAL_ENV ps" "$TMPDIR/compose-args"

# Every accepted local runtime resolves the same recorded overlay order in
# doctor and every lifecycle wrapper. The Docker stub captures only arguments;
# no daemon is contacted. This is deliberately table-driven so a new runtime
# name cannot go green without exercising init -> profile -> doctor -> action.
for runtime_name in llama-cpp vllm tgi ollama onnxruntime triton custom-runtime; do
  MATRIX_ENV="$TMPDIR/runtime-matrix-${runtime_name}.env"
  "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime "$runtime_name" \
    --output "$MATRIX_ENV" --skip-doctor >/dev/null
  grep -qx "local_runtime: $runtime_name" "$MATRIX_ENV.runtime-profile.yaml"
  "$ROOT/bin/lucairn" doctor --env "$MATRIX_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check > "$TMPDIR/runtime-matrix-${runtime_name}-doctor.out"
  grep -q "runtime profile: ok (local-runtime; overlays=docker-compose.customer.yml|docker-compose.self-hosted.yml)" "$TMPDIR/runtime-matrix-${runtime_name}-doctor.out"
  : > "$TMPDIR/compose-args"
  for lifecycle_verb in up down status pull; do
    LUCAIRN_TEST_COMPOSE_ARGS="$TMPDIR/compose-args" PATH="$DOCKER_STUB_DIR:$PATH" \
      "$ROOT/bin/lucairn" "$lifecycle_verb" --env "$MATRIX_ENV" --compose "$ROOT/docker-compose.customer.yml" >/dev/null
  done
  LUCAIRN_TEST_COMPOSE_ARGS="$TMPDIR/compose-args" PATH="$DOCKER_STUB_DIR:$PATH" \
    "$ROOT/bin/lucairn" logs --env "$MATRIX_ENV" --compose "$ROOT/docker-compose.customer.yml" --tail 17 --service gateway >/dev/null
  for expected_action in 'up -d' down ps pull 'logs --no-color --tail 17 gateway'; do
    grep -Fq -- "-f $ROOT/docker-compose.customer.yml -f $ROOT/docker-compose.self-hosted.yml --profile $runtime_name --env-file $MATRIX_ENV $expected_action" "$TMPDIR/compose-args"
  done
done

# Split and managed-BYOK use their recorded non-local overlay sets too.
: > "$TMPDIR/compose-args"
for lifecycle_verb in up down status pull; do
  LUCAIRN_TEST_COMPOSE_ARGS="$TMPDIR/compose-args" PATH="$DOCKER_STUB_DIR:$PATH" \
    "$ROOT/bin/lucairn" "$lifecycle_verb" --env "$SPLIT_ENV" --compose "$ROOT/docker-compose.customer.yml" >/dev/null
  LUCAIRN_TEST_COMPOSE_ARGS="$TMPDIR/compose-args" PATH="$DOCKER_STUB_DIR:$PATH" \
    "$ROOT/bin/lucairn" "$lifecycle_verb" --env "$BYOK_ENV" --compose "$ROOT/docker-compose.customer.yml" >/dev/null
done
LUCAIRN_TEST_COMPOSE_ARGS="$TMPDIR/compose-args" PATH="$DOCKER_STUB_DIR:$PATH" \
  "$ROOT/bin/lucairn" logs --env "$SPLIT_ENV" --compose "$ROOT/docker-compose.customer.yml" --tail 17 >/dev/null
LUCAIRN_TEST_COMPOSE_ARGS="$TMPDIR/compose-args" PATH="$DOCKER_STUB_DIR:$PATH" \
  "$ROOT/bin/lucairn" logs --env "$BYOK_ENV" --compose "$ROOT/docker-compose.customer.yml" --tail 17 --service sandbox-b >/dev/null
grep -Fq -- "-f $ROOT/docker-compose.customer.yml --env-file $SPLIT_ENV up -d" "$TMPDIR/compose-args"
grep -Fq -- "-f $ROOT/docker-compose.customer.yml --env-file $SPLIT_ENV logs --no-color --tail 17" "$TMPDIR/compose-args"
grep -Fq -- "-f $ROOT/docker-compose.customer.yml -f $ROOT/docker-compose.self-hosted.yml -f $ROOT/docker-compose.self-hosted-byok.yml --env-file $BYOK_ENV pull" "$TMPDIR/compose-args"
grep -Fq -- "-f $ROOT/docker-compose.customer.yml -f $ROOT/docker-compose.self-hosted.yml -f $ROOT/docker-compose.self-hosted-byok.yml --env-file $BYOK_ENV logs --no-color --tail 17 sandbox-b" "$TMPDIR/compose-args"

# The wrappers expose no destructive/free-form Compose pass-through.
: > "$TMPDIR/compose-args"
expect_fail lifecycle-down-volume "$ROOT/bin/lucairn" down --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" -v
expect_fail lifecycle-up-smuggle "$ROOT/bin/lucairn" up --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --force-recreate
expect_fail lifecycle-bad-tail "$ROOT/bin/lucairn" logs --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --tail 10001
expect_fail lifecycle-bad-service "$ROOT/bin/lucairn" logs --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --service '../gateway'
test ! -s "$TMPDIR/compose-args"

# A real extracted managed-BYOK bundle resolves provider/topology checks from
# install/, not the verifier kit root. This is the customer command printed in
# the handoff, with a non-secret dummy provider key added after extraction.
BYOK_BUNDLE_MODELS="$TMPDIR/byok-bundle-models"
mkdir "$BYOK_BUNDLE_MODELS"
BYOK_BUNDLE_MANIFEST="$TMPDIR/byok-bundle-model-manifest.yaml"
cat > "$BYOK_BUNDLE_MANIFEST" <<'YAML'
model:
  name: managed-provider
  format: openai-compatible
  runtime: external-openai-compatible
  checksum_policy: external-runtime-no-model-file
YAML
BYOK_BUNDLE_OUT="$TMPDIR/byok-bundle-output"
"$ROOT/bin/lucairn" bundle create --customer-slug byok-doctor --models-dir "$BYOK_BUNDLE_MODELS" \
  --model-manifest "$BYOK_BUNDLE_MANIFEST" --env "$BYOK_ENV" --output "$BYOK_BUNDLE_OUT" >/dev/null
BYOK_BUNDLE_ARCHIVE="$(find "$BYOK_BUNDLE_OUT" -name 'lucairn-customer-bundle-byok-doctor-*.tar.gz' -print -quit)"
BYOK_BUNDLE_EXTRACT="$TMPDIR/byok-bundle-extract"
mkdir "$BYOK_BUNDLE_EXTRACT"
tar -xzf "$BYOK_BUNDLE_ARCHIVE" -C "$BYOK_BUNDLE_EXTRACT"
BYOK_BUNDLE_ROOT="$(find "$BYOK_BUNDLE_EXTRACT" -maxdepth 1 -type d -name 'lucairn-customer-bundle-byok-doctor-*' -print -quit)"
test -f "$BYOK_BUNDLE_ROOT/VERSION"
test -f "$BYOK_BUNDLE_ROOT/RELEASE_DATE"
test -x "$BYOK_BUNDLE_ROOT/scripts/derive-veil-pubkey.sh"
test -f "$BYOK_BUNDLE_ROOT/install/docker-compose.self-hosted-byok.yml"
sed 's/^ANTHROPIC_API_KEY=.*/ANTHROPIC_API_KEY=dummy-provider-key/' "$BYOK_BUNDLE_ROOT/install/customer.env" > "$BYOK_BUNDLE_ROOT/install/customer.env.tmp"
mv "$BYOK_BUNDLE_ROOT/install/customer.env.tmp" "$BYOK_BUNDLE_ROOT/install/customer.env"
"$BYOK_BUNDLE_ROOT/bin/lucairn" doctor --env "$BYOK_BUNDLE_ROOT/install/customer.env" \
  --compose "$BYOK_BUNDLE_ROOT/install/docker-compose.customer.yml" --offline --skip-image-check > "$TMPDIR/extracted-byok-doctor.out" 2>&1
grep -q 'byok overlay: ok .*compose=.*install/docker-compose.self-hosted-byok.yml' "$TMPDIR/extracted-byok-doctor.out"
grep -q 'doctor: ok' "$TMPDIR/extracted-byok-doctor.out"
! grep -q 'scripts/derive-veil-pubkey.sh missing or non-executable' "$TMPDIR/extracted-byok-doctor.out"
! grep -q 'repo VERSION (unknown); the kit may be in a half-updated state' "$TMPDIR/extracted-byok-doctor.out"

# The init-time image manifest is a third required S1 artifact.  It is bound
# by the profile hash and never falls back to the mutable kit-root manifest.
for snapshot_case in missing symlink malformed hash-mismatch profile-path; do
  SNAPSHOT_ENV="$TMPDIR/snapshot-${snapshot_case}.env"
  cp "$LOCAL_ENV" "$SNAPSHOT_ENV"
  cp "$LOCAL_PROFILE" "$SNAPSHOT_ENV.runtime-profile.yaml"
  cp "$LOCAL_ENV.image-manifest.yaml" "$SNAPSHOT_ENV.image-manifest.yaml"
  case "$snapshot_case" in
    missing) rm -f "$SNAPSHOT_ENV.image-manifest.yaml" ;;
    symlink)
      rm -f "$SNAPSHOT_ENV.image-manifest.yaml"
      ln -s "$LOCAL_ENV.image-manifest.yaml" "$SNAPSHOT_ENV.image-manifest.yaml"
      ;;
    malformed) printf 'not an image manifest\n' > "$SNAPSHOT_ENV.image-manifest.yaml" ;;
    hash-mismatch) printf '# repinned elsewhere\n' >> "$SNAPSHOT_ENV.image-manifest.yaml" ;;
    profile-path)
      sed 's/^  path: .*/  path: image-manifest.yaml/' "$SNAPSHOT_ENV.runtime-profile.yaml" > "$SNAPSHOT_ENV.profile.tmp" && mv "$SNAPSHOT_ENV.profile.tmp" "$SNAPSHOT_ENV.runtime-profile.yaml"
      ;;
  esac
  expect_fail "snapshot-${snapshot_case}" "$ROOT/bin/lucairn" doctor --env "$SNAPSHOT_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check
done

# A later mutable-kit manifest repin does not affect saved S1 validation: the
# helper receives only the recorded env-adjacent snapshot, which remains an
# exact init-time copy even when another manifest file has different bytes.
REPIN_CANDIDATE="$TMPDIR/repinned-kit-image-manifest.yaml"
cp "$ROOT/image-manifest.yaml" "$REPIN_CANDIDATE"
printf '# later kit repin\n' >> "$REPIN_CANDIDATE"
"$ROOT/bin/lucairn" __validate-runtime-profile --env "$LOCAL_ENV" \
  --profile "$LOCAL_ENV.runtime-profile.yaml" \
  --manifest "$LOCAL_ENV.image-manifest.yaml" \
  --lib "$ROOT/bin/runtime-profile-lib.sh" >/dev/null
! cmp -s "$REPIN_CANDIDATE" "$LOCAL_ENV.image-manifest.yaml"

# Snapshot publication is owned by the same transaction as env/profile. A
# signal in its visible interval leaves no successful one-of-three state.
SNAPSHOT_SIGNAL_ENV="$TMPDIR/fresh-snapshot-visible-signal.env"
expect_fail fresh-snapshot-visible-signal \
  env LUCAIRN_TEST_TRANSACTION_HOOK=fresh-snapshot-visible:signal \
  "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --output "$SNAPSHOT_SIGNAL_ENV" --skip-doctor
test ! -e "$SNAPSHOT_SIGNAL_ENV"
test ! -e "$SNAPSHOT_SIGNAL_ENV.runtime-profile.yaml"
test ! -e "$SNAPSHOT_SIGNAL_ENV.image-manifest.yaml"
test ! -d "$TMPDIR/.lucairn-init.lock"

# Stale-lock recovery is liveness-aware. Live owners remain untouched; only a
# real errno-proven ESRCH owner can be reclaimed.
LOCK_TEST_ENV="$TMPDIR/stale-lock.env"
LOCK_TEST_DIR="$TMPDIR/.lucairn-init.lock"
LIVE_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef
mkdir "$LOCK_TEST_DIR"
printf 'pid=%s\ntoken=%s\n' "$$" "$LIVE_TOKEN" > "$LOCK_TEST_DIR/owner"
expect_fail live-init-lock "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$LOCK_TEST_ENV" --skip-doctor
test -d "$LOCK_TEST_DIR"
grep -qx "pid=$$" "$LOCK_TEST_DIR/owner"

# The removed test hook cannot override the real live-owner check.
expect_fail exported-liveness-hook-live-init-lock \
  env LUCAIRN_TEST_LOCK_LIVENESS_ERRNO=ESRCH \
  "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$LOCK_TEST_ENV" --skip-doctor
test -d "$LOCK_TEST_DIR"
grep -qx "pid=$$" "$LOCK_TEST_DIR/owner"
rm -rf "$LOCK_TEST_DIR"

DEAD_LOCK_ENV="$TMPDIR/dead-lock.env"
DEAD_PID="$(python3 - <<'PY'
import os

for candidate in (2**31 - 1, 2**30 - 1, 2**29 - 1):
    try:
        os.kill(candidate, 0)
    except ProcessLookupError:
        print(candidate)
        break
else:
    raise SystemExit("could not find a non-existent PID")
PY
)"
mkdir "$LOCK_TEST_DIR"
printf 'pid=%s\ntoken=%s\n' "$DEAD_PID" "$LIVE_TOKEN" > "$LOCK_TEST_DIR/owner"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$DEAD_LOCK_ENV" --skip-doctor >/dev/null
test -f "$DEAD_LOCK_ENV.image-manifest.yaml"
test ! -d "$LOCK_TEST_DIR"

# A verifier that cannot establish liveness is ambiguous, never stale-lock
# proof. The shim is scoped to this invocation and no signal is sent to PID 1.
PYTHON_SHIM_DIR="$TMPDIR/python-liveness-shim"
mkdir "$PYTHON_SHIM_DIR"
cat > "$PYTHON_SHIM_DIR/python3" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$PYTHON_SHIM_DIR/python3"
BLOCKED_LOCK_ENV="$TMPDIR/unusable-python-lock.env"
mkdir "$LOCK_TEST_DIR"
printf 'pid=1\ntoken=%s\n' "$LIVE_TOKEN" > "$LOCK_TEST_DIR/owner"
expect_fail unusable-python-init-lock \
  env PATH="$PYTHON_SHIM_DIR:$PATH" \
  "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$BLOCKED_LOCK_ENV" --skip-doctor
test -d "$LOCK_TEST_DIR"
grep -qx 'pid=1' "$LOCK_TEST_DIR/owner"
test ! -e "$BLOCKED_LOCK_ENV"
grep -q 'alive or cannot be proven dead' "$TMPDIR/unusable-python-init-lock.out"
rm -rf "$LOCK_TEST_DIR"

FRESH_CORRUPT_ENV="$TMPDIR/fresh-corrupt-lock.env"
mkdir "$LOCK_TEST_DIR"
printf 'corrupt\n' > "$LOCK_TEST_DIR/owner"
expect_fail fresh-corrupt-lock "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$FRESH_CORRUPT_ENV" --skip-doctor
test -d "$LOCK_TEST_DIR"
rm -rf "$LOCK_TEST_DIR"

OLD_CORRUPT_ENV="$TMPDIR/old-corrupt-lock.env"
mkdir "$LOCK_TEST_DIR"
printf 'corrupt\n' > "$LOCK_TEST_DIR/owner"
touch -t 200001010000 "$LOCK_TEST_DIR"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$OLD_CORRUPT_ENV" --skip-doctor >/dev/null
test -f "$OLD_CORRUPT_ENV"
test ! -d "$LOCK_TEST_DIR"

printf 'unsafe lock\n' > "$LOCK_TEST_DIR"
expect_fail non-directory-init-lock "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$TMPDIR/non-directory-lock.env" --skip-doctor
test -f "$LOCK_TEST_DIR"
rm -f "$LOCK_TEST_DIR"
ln -s "$TMPDIR/nowhere" "$LOCK_TEST_DIR"
expect_fail symlink-init-lock "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$TMPDIR/symlink-lock.env" --skip-doctor
test -L "$LOCK_TEST_DIR"
rm -f "$LOCK_TEST_DIR"

echo "runtime profile tests: ok"
