#!/usr/bin/env bash
#
# Focused unit tests for two banked doctor follow-ups:
#
#   1. check_signing_key_compose_preflight — the Compose-v2 eager
#      nested-legacy-signing-key sharp edge (WP1 S4 Fable verdict, carried to
#      WP4 S2 doctor / S7 acceptance: "Docker Compose v2's eager evaluation of
#      the nested legacy signing-key requirement is a pre-existing operator
#      sharp edge; canonical-LCR-only configuration can hit it"). Verifies
#      doctor surfaces an actionable, CANONICAL-var-first message before the
#      operator ever hits Compose's raw interpolation error, and that the
#      severity (FAIL vs WARN) matches whether the runtime's own fail-closed
#      gate is actually armed for the given DSA_ENV/dev-mode combination.
#
#   2. the NVIDIA Container Toolkit registration check inside
#      check_vllm_l3_preflight (banked Fable follow-up from kit PR #96: doctor
#      verified the host driver via nvidia-smi but not that the toolkit is
#      registered with Docker — a DIFFERENT failure mode Compose surfaces only
#      at container-create time). Verifies default-OFF silence (vllm-l3 not
#      opted in), the ok path (docker info lists nvidia), the FAIL path
#      (docker info present but no nvidia runtime, and nvidia-ctk absent), and
#      the nvidia-ctk fallback path (docker info unusable).
#
# Sources bin/lucairn and calls the functions directly against crafted env
# files / PATH stubs — no real Docker, GPU, or network required.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1090
source "$ROOT/bin/lucairn" >/dev/null 2>&1
# bin/lucairn turned on `set -euo pipefail`; turn it back off for the harness
# so a failing case's non-zero return does not abort us.
set +e +u +o pipefail

WK="$(mktemp -d)"
trap 'rm -rf "$WK"' EXIT

FAILS=0
N=0

# assert_case NAME ENV_CONTENTS EXPECT_RC [EXPECT_SUBSTRING]
assert_case() {
  local name="$1" contents="$2" expect_rc="$3" needle="${4:-}"
  N=$((N + 1))
  local f="$WK/$name.env"
  printf '%s\n' "$contents" > "$f"
  local out rc
  out="$(check_signing_key_compose_preflight "$f" 2>&1)"
  rc=$?
  local ok=1
  if [ "$rc" -ne "$expect_rc" ]; then
    ok=0
    echo "FAIL [$name]: expected rc=$expect_rc, got rc=$rc"
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    ok=0
    echo "FAIL [$name]: output did not contain: $needle"
  fi
  if [ "$ok" -eq 1 ]; then
    echo "ok   [$name] (rc=$rc)"
  else
    echo "     output was: $out"
    FAILS=$((FAILS + 1))
  fi
}

# ----------------------------------------------------------------------------
# check_signing_key_compose_preflight
# ----------------------------------------------------------------------------

# Production, dev-mode off, BOTH gateway names unset -> the gateway's own
# fail-closed gate (main.go: DSA_ENV=production && !veilDevMode) IS armed and
# would reject this config -> FAIL, actionable, names the CANONICAL var.
assert_case "prod_no_devmode_gateway_key_missing_fails" \
  'DSA_ENV=production' \
  1 "LCR_GATEWAY_SIGNING_KEY"

# Same case: message must name the canonical var, not just the legacy one,
# and must not silently recommend the legacy name as the fix.
assert_case "prod_no_devmode_message_prefers_canonical" \
  'DSA_ENV=production' \
  1 "Set LCR_GATEWAY_SIGNING_KEY"

# Production but LCR_GATEWAY_SIGNING_KEY set via legacy VEIL_ name only ->
# resolves non-empty via env_value_with_legacy -> no gateway FAIL (sandbox-b
# slot satisfied to isolate the gateway assertion).
assert_case "prod_legacy_veil_name_satisfies" \
  'DSA_ENV=production
VEIL_GATEWAY_SIGNING_KEY=legacy-fixture-key
LCR_SANDBOX_B_SIGNING_KEY=sb-fixture-key' \
  0

# Production but canonical LCR_GATEWAY_SIGNING_KEY set (the documented,
# preferred shape) -> no FAIL, no Compose eager-crash surfaced at all
# (sandbox-b slot satisfied to isolate the gateway assertion).
assert_case "prod_canonical_name_satisfies" \
  'DSA_ENV=production
LCR_GATEWAY_SIGNING_KEY=canonical-fixture-key
LCR_SANDBOX_B_SIGNING_KEY=sb-fixture-key' \
  0

# Armed case message must say the runtime would fail closed at boot.
assert_case "prod_no_devmode_message_says_boot_failclosed" \
  'DSA_ENV=production' \
  1 "fail-closed at startup"

# Development env, gateway key unset: the compose files no longer carry `:?`
# AND the gateway's runtime gate is unarmed (DSA_ENV!=production) — NOTHING
# else would catch a silently-empty signing key, so doctor is the ONLY layer
# and must FAIL (not warn), saying so.
assert_case "dev_env_gateway_key_missing_fails_only_layer" \
  'DSA_ENV=development' \
  1 "UNARMED"

# Production WITH the dev-mode escape hatch set true: gate unarmed -> same
# only-layer reasoning -> FAIL.
assert_case "prod_with_devmode_escape_hatch_fails" \
  'DSA_ENV=production
LCR_DEV_MODE=true' \
  1 "only layer"

# Sandbox-b slot: unset in a non-dev/test DSA_ENV with SANDBOX_B_REMOTE_ENDPOINT
# empty (= local self-hosted Sandbox B per the INSTALL.md deployment-mode
# table): sandbox-b's boot gate (boot_safety.py, skipped only for DSA_ENV in
# {development,test}) is ARMED -> FAIL, actionable, canonical var named.
assert_case "sandbox_b_key_missing_local_prod_fails" \
  'DSA_ENV=production
LCR_GATEWAY_SIGNING_KEY=gw-fixture-key' \
  1 "LCR_SANDBOX_B_SIGNING_KEY"

# Split mode: SANDBOX_B_REMOTE_ENDPOINT set -> no local sandbox-b -> the
# missing local signing key is by design; no FAIL, no mention.
N=$((N + 1))
f="$WK/sandbox_b_split_mode_skip.env"
printf '%s\n' 'DSA_ENV=production
LCR_GATEWAY_SIGNING_KEY=gw-fixture-key
SANDBOX_B_REMOTE_ENDPOINT=https://sandbox-b.example.internal:50054' > "$f"
out="$(check_signing_key_compose_preflight "$f" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qF "LCR_SANDBOX_B_SIGNING_KEY"; then
  echo "ok   [sandbox_b_split_mode_skip] (rc=$rc)"
else
  echo "FAIL [sandbox_b_split_mode_skip]: expected rc=0 and no sandbox-b mention, got rc=$rc, out=$out"
  FAILS=$((FAILS + 1))
fi

# Sandbox-b slot set via canonical name -> no sandbox-b warning text.
N=$((N + 1))
f="$WK/sandbox_b_key_set_no_warning.env"
printf '%s\n' 'DSA_ENV=production
LCR_GATEWAY_SIGNING_KEY=gw-fixture-key
LCR_SANDBOX_B_SIGNING_KEY=sb-fixture-key' > "$f"
out="$(check_signing_key_compose_preflight "$f" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qF "LCR_SANDBOX_B_SIGNING_KEY"; then
  echo "ok   [sandbox_b_key_set_no_warning] (rc=$rc)"
else
  echo "FAIL [sandbox_b_key_set_no_warning]: expected rc=0 and no LCR_SANDBOX_B_SIGNING_KEY mention, got rc=$rc, out=$out"
  FAILS=$((FAILS + 1))
fi

# Sandbox-b slot unset in DSA_ENV=test (local mode): sandbox-b's own boot
# gate is skipped for `test` AND compose no longer hard-fails, so doctor
# surfaces an INFORMATIVE NOTE (rc=0, not a FAIL, not silence) telling the
# operator the emitter would run empty-keyed and to set the key before prod.
assert_case "sandbox_b_key_missing_test_env_informative_note" \
  'DSA_ENV=test
LCR_GATEWAY_SIGNING_KEY=gw-fixture-key' \
  0 "LCR_SANDBOX_B_SIGNING_KEY"

assert_case "sandbox_b_key_missing_dev_env_note_says_before_production" \
  'DSA_ENV=development
LCR_GATEWAY_SIGNING_KEY=gw-fixture-key' \
  0 "before switching to production"

# ----------------------------------------------------------------------------
# check_vllm_l3_preflight — NVIDIA Container Toolkit registration
# ----------------------------------------------------------------------------

STUBDIR="$WK/stub-bin"
mkdir -p "$STUBDIR"

make_stub() {
  # make_stub ABS_PATH BODY — writes an executable stub script at ABS_PATH.
  local path="$1" body="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$path"
}

# Sanitizer config fixture that opts into vllm-l3 (channel 1: l3_runtime: vllm)
# with a valid internal base_url, so the WSL2/GPU/toolkit checks are the ones
# under test rather than an earlier misconfig short-circuit.
VLLM_SANITIZER_CONFIG="$WK/sanitizer-vllm.yaml"
cat > "$VLLM_SANITIZER_CONFIG" <<'YAML'
l3_runtime: vllm
l3_base_url: http://vllm-l3:8000
YAML

VLLM_ENV="$WK/vllm.env"
cat > "$VLLM_ENV" <<EOF
SANITIZER_CONFIG_FILE=$VLLM_SANITIZER_CONFIG
COMPOSE_PROFILES=vllm-l3
EOF

NO_VLLM_ENV="$WK/no-vllm.env"
: > "$NO_VLLM_ENV"

assert_vllm_case() {
  # assert_vllm_case NAME PATH_STUBS ENV_FILE EXPECT_RC EXPECT_SUBSTRING [OFFLINE]
  local name="$1" path_stubs="$2" env_file="$3" expect_rc="$4" needle="${5:-}" offline="${6:-0}"
  N=$((N + 1))
  local out rc
  out="$(PATH="$path_stubs:$PATH" bash -c '
    set +e
    source "'"$ROOT"'/bin/lucairn" >/dev/null 2>&1
    set +e +u +o pipefail
    check_vllm_l3_preflight "'"$env_file"'" "'"$offline"'"
  ' 2>&1)"
  rc=$?
  local ok=1
  if [ "$rc" -ne "$expect_rc" ]; then
    ok=0
    echo "FAIL [$name]: expected rc=$expect_rc, got rc=$rc"
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    ok=0
    echo "FAIL [$name]: output did not contain: $needle"
  fi
  if [ "$ok" -eq 1 ]; then
    echo "ok   [$name] (rc=$rc)"
  else
    echo "     output was: $out"
    FAILS=$((FAILS + 1))
  fi
}

# --- Default-OFF silence: vllm-l3 not opted in -> no GPU/toolkit checks run
# at all (no nvidia-smi/docker on PATH would otherwise crash the function if
# it mistakenly ran them unconditionally).
BARE="$WK/bare-bin"
mkdir -p "$BARE"
for tool in bash sh cat grep sed awk printf tr head mktemp; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -z "$real" ] || ln -sf "$real" "$BARE/$tool"
done
assert_vllm_case "not_opted_in_no_gpu_tools_needed" "$BARE" "$NO_VLLM_ENV" 0

# --- GPU present + Toolkit registered: docker info lists "nvidia" runtime.
GPU_TOOLKIT_OK="$WK/gpu-toolkit-ok"
mkdir -p "$GPU_TOOLKIT_OK"
make_stub "$GPU_TOOLKIT_OK/nvidia-smi" 'if [ "$1" = "" ]; then
  echo "Driver Version: 550.54.15    CUDA Version: 12.8"
fi
exit 0'
make_stub "$GPU_TOOLKIT_OK/docker" 'if [ "$1" = "info" ]; then
  echo "Runtimes: runc nvidia io.containerd.runc.v2"
  exit 0
fi
exit 0'
assert_vllm_case "gpu_and_toolkit_ok" "$GPU_TOOLKIT_OK" "$VLLM_ENV" 0 "NVIDIA Container Toolkit: ok (registered with Docker)"

# --- GPU present, Docker reachable, but NO nvidia runtime registered, and no
# nvidia-ctk fallback on PATH -> FAIL, actionable, names the exact fix.
GPU_NO_TOOLKIT="$WK/gpu-no-toolkit"
mkdir -p "$GPU_NO_TOOLKIT"
make_stub "$GPU_NO_TOOLKIT/nvidia-smi" 'echo "Driver Version: 550.54.15    CUDA Version: 12.8"
exit 0'
make_stub "$GPU_NO_TOOLKIT/docker" 'if [ "$1" = "info" ]; then
  echo "Runtimes: runc io.containerd.runc.v2"
  exit 0
fi
exit 0'
assert_vllm_case "gpu_present_toolkit_missing_fails" "$GPU_NO_TOOLKIT" "$VLLM_ENV" 1 "NVIDIA Container Toolkit is not registered with Docker"
assert_vllm_case "gpu_present_toolkit_missing_names_fix" "$GPU_NO_TOOLKIT" "$VLLM_ENV" 1 "nvidia-ctk runtime configure --runtime=docker"

# --- Anchoring guard (Codex LOW): "nvidia" appearing OUTSIDE the Runtimes
# line (e.g. a kernel-version string) must NOT green the check — the Runtimes
# line itself has no nvidia runtime here, so this is a definitive FAIL.
NVIDIA_ELSEWHERE="$WK/nvidia-elsewhere"
mkdir -p "$NVIDIA_ELSEWHERE"
make_stub "$NVIDIA_ELSEWHERE/nvidia-smi" 'echo "Driver Version: 550.54.15    CUDA Version: 12.8"
exit 0'
make_stub "$NVIDIA_ELSEWHERE/docker" 'if [ "$1" = "info" ]; then
  echo " Kernel Version: 5.15.0-nvidia-custom"
  echo " Runtimes: runc io.containerd.runc.v2"
  exit 0
fi
exit 0'
assert_vllm_case "nvidia_outside_runtimes_line_not_green" "$NVIDIA_ELSEWHERE" "$VLLM_ENV" 1 "not registered with Docker"

# --- docker info unusable (e.g. permission/remote DOCKER_HOST), but
# nvidia-ctk IS on PATH -> INCONCLUSIVE (installed is not registered — the
# runtime may never have been configured / docker never restarted). WARN,
# never "ok", never FAIL.
NVIDIA_CTK_FALLBACK="$WK/nvidia-ctk-fallback"
mkdir -p "$NVIDIA_CTK_FALLBACK"
make_stub "$NVIDIA_CTK_FALLBACK/nvidia-smi" 'echo "Driver Version: 550.54.15    CUDA Version: 12.8"
exit 0'
make_stub "$NVIDIA_CTK_FALLBACK/docker" 'exit 1'
make_stub "$NVIDIA_CTK_FALLBACK/nvidia-ctk" 'exit 0'
assert_vllm_case "docker_info_unusable_nvidia_ctk_inconclusive_warn" "$NVIDIA_CTK_FALLBACK" "$VLLM_ENV" 0 "INCONCLUSIVE"

N=$((N + 1))
out="$(PATH="$NVIDIA_CTK_FALLBACK:$PATH" bash -c '
  set +e
  source "'"$ROOT"'/bin/lucairn" >/dev/null 2>&1
  set +e +u +o pipefail
  check_vllm_l3_preflight "'"$VLLM_ENV"'" 0
' 2>&1)"
if ! printf '%s' "$out" | grep -qF "NVIDIA Container Toolkit: ok"; then
  echo "ok   [ctk_fallback_never_reports_ok]"
else
  echo "FAIL [ctk_fallback_never_reports_ok]: inconclusive ctk path must not print an ok verdict: $out"
  FAILS=$((FAILS + 1))
fi

# --- docker info usable but output has NO Runtimes line to anchor on ->
# cannot assert registration either way -> inconclusive branch (WARN with
# nvidia-ctk present).
NO_RUNTIMES_LINE="$WK/no-runtimes-line"
mkdir -p "$NO_RUNTIMES_LINE"
make_stub "$NO_RUNTIMES_LINE/nvidia-smi" 'echo "Driver Version: 550.54.15    CUDA Version: 12.8"
exit 0'
make_stub "$NO_RUNTIMES_LINE/docker" 'if [ "$1" = "info" ]; then
  echo " Server Version: 27.0.0"
  exit 0
fi
exit 0'
make_stub "$NO_RUNTIMES_LINE/nvidia-ctk" 'exit 0'
assert_vllm_case "docker_info_no_runtimes_line_inconclusive" "$NO_RUNTIMES_LINE" "$VLLM_ENV" 0 "INCONCLUSIVE"

# --- --offline: the docker-daemon probe must be SKIPPED entirely (air-gap
# contract). PATH has nvidia-smi but NO docker and NO nvidia-ctk — if the
# toolkit block ran, this would FAIL "cannot confirm"; offline must instead
# note the skip and pass.
OFFLINE_GPU="$WK/offline-gpu"
mkdir -p "$OFFLINE_GPU"
make_stub "$OFFLINE_GPU/nvidia-smi" 'echo "Driver Version: 550.54.15    CUDA Version: 12.8"
exit 0'
assert_vllm_case "offline_skips_docker_info_probe" "$OFFLINE_GPU" "$VLLM_ENV" 0 "skipped (--offline" 1

# --- docker info unusable AND nvidia-ctk absent -> cannot confirm -> FAIL.
NEITHER="$WK/neither"
mkdir -p "$NEITHER"
make_stub "$NEITHER/nvidia-smi" 'echo "Driver Version: 550.54.15    CUDA Version: 12.8"
exit 0'
make_stub "$NEITHER/docker" 'exit 1'
assert_vllm_case "docker_info_unusable_no_nvidia_ctk_fails" "$NEITHER" "$VLLM_ENV" 1 "cannot confirm the NVIDIA Container Toolkit is installed"

# --- No NVIDIA GPU at all (nvidia-smi absent): the pre-existing driver-FAIL
# path fires and the toolkit check must never even run (no docker stub
# provided — if the toolkit block ran unconditionally, this would hang/error
# on a missing `docker` rather than reporting the driver failure cleanly).
NO_GPU="$WK/no-gpu"
mkdir -p "$NO_GPU"
for tool in bash sh cat grep sed awk printf tr head mktemp; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -z "$real" ] || ln -sf "$real" "$NO_GPU/$tool"
done
assert_vllm_case "no_gpu_driver_fails_before_toolkit_check" "$NO_GPU" "$VLLM_ENV" 1 "no NVIDIA GPU detected"

# ----------------------------------------------------------------------------
# CLI-level: the operator-visible doctor run (NOT a direct function call) must
# surface the gate-aware canonical-var diagnostic for a missing gateway
# signing key. require_env_values fires before the preflight and
# short-circuits doctor, so this proves the enriched message actually reaches
# the operator through the real CLI path.
# ----------------------------------------------------------------------------

run_doctor_cli_case() {
  # run_doctor_cli_case NAME ENV_CONTENTS EXPECT_RC NEEDLE...
  local name="$1" contents="$2" expect_rc="$3"
  shift 3
  N=$((N + 1))
  local f="$WK/cli-$name.env"
  printf '%s\n' "$contents" > "$f"
  local out rc ok=1 needle
  out="$(bash "$ROOT/bin/lucairn" doctor --env "$f" --compose "$ROOT/docker-compose.customer.yml" --offline 2>&1)"
  rc=$?
  if [ "$rc" -ne "$expect_rc" ]; then
    ok=0
    echo "FAIL [cli_$name]: expected rc=$expect_rc, got rc=$rc"
  fi
  for needle in "$@"; do
    if ! printf '%s' "$out" | grep -qF -- "$needle"; then
      ok=0
      echo "FAIL [cli_$name]: doctor output did not contain: $needle"
    fi
  done
  if [ "$ok" -eq 1 ]; then
    echo "ok   [cli_$name] (rc=$rc)"
  else
    echo "     output was: $out"
    FAILS=$((FAILS + 1))
  fi
}

# Armed posture (production, no dev-mode): operator sees the missing line,
# the boot-fail-closed explanation, and the canonical-var fix.
run_doctor_cli_case "gateway_key_missing_prod_armed" \
  'DSA_ENV=production' \
  1 \
  "missing LCR_GATEWAY_SIGNING_KEY (or legacy VEIL_GATEWAY_SIGNING_KEY)" \
  "fail-closed at startup" \
  "Set LCR_GATEWAY_SIGNING_KEY in customer.env"

# Unarmed posture (development): operator sees the only-layer explanation.
run_doctor_cli_case "gateway_key_missing_dev_unarmed" \
  'DSA_ENV=development' \
  1 \
  "missing LCR_GATEWAY_SIGNING_KEY (or legacy VEIL_GATEWAY_SIGNING_KEY)" \
  "UNARMED" \
  "This doctor check is the only layer"

# ----------------------------------------------------------------------------
# Compose files: canonical-LCR-only configs must now PARSE/render clean (the
# `:?` on the legacy inner slot is gone). YAML-parse via python3+yaml or ruby
# when available; real `docker compose config` render when docker exists (CI).
# ----------------------------------------------------------------------------

N=$((N + 1))
if python3 -c 'import yaml' 2>/dev/null; then
  if python3 - "$ROOT/docker-compose.customer.yml" "$ROOT/docker-compose.self-hosted.yml" <<'PY'
import sys, yaml
for p in sys.argv[1:]:
    with open(p) as fh:
        yaml.safe_load(fh)
PY
  then
    echo "ok   [compose_yaml_parse] (python3+yaml)"
  else
    echo "FAIL [compose_yaml_parse]: compose files no longer YAML-parse"
    FAILS=$((FAILS + 1))
  fi
elif command -v ruby >/dev/null 2>&1; then
  if ruby -ryaml -e 'ARGV.each { |p| YAML.load_file(p, aliases: true) rescue YAML.load_file(p) }' \
      "$ROOT/docker-compose.customer.yml" "$ROOT/docker-compose.self-hosted.yml" 2>/dev/null; then
    echo "ok   [compose_yaml_parse] (ruby)"
  else
    echo "FAIL [compose_yaml_parse]: compose files no longer YAML-parse (ruby)"
    FAILS=$((FAILS + 1))
  fi
else
  echo "skip [compose_yaml_parse] (no python3+yaml, no ruby)"
fi

# Real Compose render, canonical-LCR-only (docker-gated — runs in CI). This is
# the direct regression test for the sharp edge: before the fix, this exact
# render failed with "required variable VEIL_GATEWAY_SIGNING_KEY is missing".
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  CANONICAL_ONLY_ENV="$WK/canonical-only-compose.env"
  cat > "$CANONICAL_ONLY_ENV" <<'ENV'
DSA_ENV=production
DSA_SERVICE_TOKEN=test-service-token
AUDIT_APP_PASSWORD=test-audit-app-password
BUILD_AUTH_TOKEN=test-build-auth-token
CANARY_HMAC_KEY=test-canary-hmac-key
CUSTOMER_KEY_ID=test-customer-key-id
DSA_BRIDGE_ENCRYPTION_KEY=test-bridge-encryption-key
GATEWAY_KEYSTORE_KEY=dGVzdC1rZXlzdG9yZS1rZXktMzItYnl0ZXMtbG9uZw==
PORTAL_API_KEY=test-portal-api-key
POSTGRES_AUDIT_PASSWORD=test-postgres-audit-password
POSTGRES_BRIDGE_PASSWORD=test-postgres-bridge-password
POSTGRES_SANDBOX_A_PASSWORD=test-postgres-sandbox-a-password
POSTGRES_VEIL_PASSWORD=test-postgres-veil-password
VEIL_APP_PASSWORD=test-veil-app-password
LCR_GATEWAY_SIGNING_KEY=test-gateway-signing-key
DSA_LICENSE_KEY=
DSA_LICENSE_SIGNING_KEY=
LUCAIRN_LICENSE_KEY=
LUCAIRN_LICENSE_PUBLIC_KEY=
ENV
  N=$((N + 1))
  if docker compose --env-file "$CANONICAL_ONLY_ENV" \
      -f "$ROOT/docker-compose.customer.yml" config >/dev/null 2>"$WK/compose-render-customer.err"; then
    echo "ok   [compose_render_canonical_only_customer]"
  else
    echo "FAIL [compose_render_canonical_only_customer]: canonical-LCR-only render failed:"
    cat "$WK/compose-render-customer.err"
    FAILS=$((FAILS + 1))
  fi

  CANONICAL_ONLY_SH_ENV="$WK/canonical-only-selfhosted.env"
  cat "$CANONICAL_ONLY_ENV" > "$CANONICAL_ONLY_SH_ENV"
  cat >> "$CANONICAL_ONLY_SH_ENV" <<'ENV'
DSA_ADMIN_KEY=test-admin-key
LCR_SANDBOX_B_SIGNING_KEY=test-sandbox-b-signing-key
ENV
  N=$((N + 1))
  if docker compose --env-file "$CANONICAL_ONLY_SH_ENV" \
      -f "$ROOT/docker-compose.customer.yml" -f "$ROOT/docker-compose.self-hosted.yml" \
      config >/dev/null 2>"$WK/compose-render-selfhosted.err"; then
    echo "ok   [compose_render_canonical_only_selfhosted]"
  else
    echo "FAIL [compose_render_canonical_only_selfhosted]: canonical-LCR-only self-hosted render failed:"
    cat "$WK/compose-render-selfhosted.err"
    FAILS=$((FAILS + 1))
  fi
else
  echo "skip [compose_render_canonical_only] (docker compose unavailable — CI covers the render)"
fi

echo
echo "ran $N case(s)"
if [ "$FAILS" -ne 0 ]; then
  echo "signing-key compose preflight + nvidia toolkit doctor tests: FAILED ($FAILS)" >&2
  exit 1
fi
echo "signing-key compose preflight + nvidia toolkit doctor tests: ok"
