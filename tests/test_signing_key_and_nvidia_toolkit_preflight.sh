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
# resolves non-empty via env_value_with_legacy -> no FAIL.
assert_case "prod_legacy_veil_name_satisfies" \
  'DSA_ENV=production
VEIL_GATEWAY_SIGNING_KEY=legacy-fixture-key' \
  0

# Production but canonical LCR_GATEWAY_SIGNING_KEY set (the documented,
# preferred shape) -> no FAIL, no Compose eager-crash surfaced at all.
assert_case "prod_canonical_name_satisfies" \
  'DSA_ENV=production
LCR_GATEWAY_SIGNING_KEY=canonical-fixture-key' \
  0

# Development env with LCR_DEV_MODE unset: the gateway gate's condition is
# DSA_ENV=production, so development already bypasses it regardless of
# LCR_DEV_MODE — WARN only, never FAIL, since compose itself would only
# ever be run this way in a non-prod context per the operator's own env.
assert_case "dev_env_gateway_key_missing_warns_not_fails" \
  'DSA_ENV=development' \
  0 "warn:"

# Production WITH the dev-mode escape hatch set true: gateway gate condition
# (isProduction && !veilDevMode) is false -> gate not armed -> WARN not FAIL.
assert_case "prod_with_devmode_escape_hatch_warns" \
  'DSA_ENV=production
LCR_DEV_MODE=true' \
  0 "warn:"

# Sandbox-b slot: unset in a non-dev/test DSA_ENV -> sandbox-b's gate
# (boot_safety.py, skipped only for DSA_ENV in {development,test}) WOULD be
# armed if Sandbox B is actually deployed -> pre-emptive WARN naming the
# canonical var (doctor cannot know if compose.self-hosted.yml will be used,
# so this is WARN not FAIL — matches the function's documented contract).
assert_case "sandbox_b_key_missing_warns" \
  'DSA_ENV=production
LCR_GATEWAY_SIGNING_KEY=gw-fixture-key' \
  0 "LCR_SANDBOX_B_SIGNING_KEY"

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

# Sandbox-b slot unset in DSA_ENV=test -> sandbox-b's own gate is skipped for
# `test`, so no pre-emptive warning is needed either.
assert_case "sandbox_b_key_missing_test_env_no_warn" \
  'DSA_ENV=test
LCR_GATEWAY_SIGNING_KEY=gw-fixture-key' \
  0

N=$((N + 1))
f="$WK/sandbox_b_key_missing_test_env_no_warn_check.env"
printf '%s\n' 'DSA_ENV=test
LCR_GATEWAY_SIGNING_KEY=gw-fixture-key' > "$f"
out="$(check_signing_key_compose_preflight "$f" 2>&1)"
if ! printf '%s' "$out" | grep -qF "LCR_SANDBOX_B_SIGNING_KEY"; then
  echo "ok   [sandbox_b_key_missing_test_env_no_warn_text]"
else
  echo "FAIL [sandbox_b_key_missing_test_env_no_warn_text]: unexpected sandbox-b warning in test env: $out"
  FAILS=$((FAILS + 1))
fi

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
  # assert_vllm_case NAME PATH_STUBS ENV_FILE EXPECT_RC EXPECT_SUBSTRING
  local name="$1" path_stubs="$2" env_file="$3" expect_rc="$4" needle="${5:-}"
  N=$((N + 1))
  local out rc
  out="$(PATH="$path_stubs:$PATH" bash -c '
    set +e
    source "'"$ROOT"'/bin/lucairn" >/dev/null 2>&1
    set +e +u +o pipefail
    check_vllm_l3_preflight "'"$env_file"'" 0
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

# --- docker info unusable (e.g. permission/remote DOCKER_HOST), but
# nvidia-ctk IS on PATH -> treat as sufficient positive signal, no FAIL.
NVIDIA_CTK_FALLBACK="$WK/nvidia-ctk-fallback"
mkdir -p "$NVIDIA_CTK_FALLBACK"
make_stub "$NVIDIA_CTK_FALLBACK/nvidia-smi" 'echo "Driver Version: 550.54.15    CUDA Version: 12.8"
exit 0'
make_stub "$NVIDIA_CTK_FALLBACK/docker" 'exit 1'
make_stub "$NVIDIA_CTK_FALLBACK/nvidia-ctk" 'exit 0'
assert_vllm_case "docker_info_unusable_nvidia_ctk_present_ok" "$NVIDIA_CTK_FALLBACK" "$VLLM_ENV" 0 "nvidia-ctk on PATH"

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

echo
echo "ran $N case(s)"
if [ "$FAILS" -ne 0 ]; then
  echo "signing-key compose preflight + nvidia toolkit doctor tests: FAILED ($FAILS)" >&2
  exit 1
fi
echo "signing-key compose preflight + nvidia toolkit doctor tests: ok"
