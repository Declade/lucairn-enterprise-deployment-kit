#!/usr/bin/env bash
#
# Unit tests for the SPLIT L3-POOL doctor preflight (kit Slice 4 of PRD
# prd-2026-07-31-l3-rebuild-recoverable-truncation-gemma4.md; operator guide
# docs/L3_SPLIT_POOL.md).
#
# The split topology points the sanitizer's L3 backend at a REMOTE shared-GPU
# vLLM pool on the customer's private network:
#
#   config/default-sanitizer.yaml : l3_runtime: vllm + l3_base_url: http://10.x:8000
#   customer.env                  : LUCAIRN_L3_SPLIT_POOL=true
#   COMPOSE_PROFILES              : NO vllm-l3 (there is no local vLLM container)
#
# That shape is byte-identical, from the config alone, to the BROKEN
# half-enabled in-box shape (`l3_runtime: vllm` with the profile forgotten),
# which doctor must keep failing. The LUCAIRN_L3_SPLIT_POOL marker is what
# tells the two apart, so these cases pin BOTH directions.
#
# POSITIVE CONTROLS. Every FAIL case here asserts rc=1 AND a specific message,
# so deleting the corresponding guard in bin/lucairn turns the case green-path
# (rc=0) and fails this suite:
#   - split declared but l3_runtime not vllm      -> check_l3_split_pool_preflight yaml guard
#   - split declared, l3_base_url unset           -> base_url-present guard
#   - userinfo in l3_base_url                     -> A-E2 credential guard
#   - public FQDN / public IP                     -> _l3_host_is_internal
#   - 10.evil.com (hostname that LOOKS RFC1918)   -> _l3_host_is_internal (the pre-2026-08
#                                                    glob classifier passed this; the
#                                                    sanitizer BLOCKS it at boot)
#   - local target (vllm-l3 / localhost / 127.x)  -> remote-required guard
#   - undeclared split + no profile               -> the ORIGINAL channel-mismatch FAIL
#                                                    must survive the new branch
#
# Sources bin/lucairn and calls the functions directly against crafted env +
# sanitizer-YAML fixtures. No Docker, GPU, or network required.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WK="$(mktemp -d)"
trap 'rm -rf "$WK"' EXIT

FAILS=0
N=0

# mk_case NAME YAML_BODY ENV_BODY — write the fixture pair, echo the env path.
mk_case() {
  local name="$1" yaml_body="$2" env_body="$3"
  local yaml="$WK/$name.yaml" env="$WK/$name.env"
  printf '%s\n' "$yaml_body" > "$yaml"
  { printf 'SANITIZER_CONFIG_FILE=%s\n' "$yaml"; printf '%s\n' "$env_body"; } > "$env"
  printf '%s' "$env"
}

# run_preflight ENV_FILE — run check_vllm_l3_preflight in a clean subshell
# (bin/lucairn sets -euo pipefail when sourced; the harness turns it back off)
# with an EMPTY PATH-visible toolchain for GPU probes: the split lane must
# never reach nvidia-smi/docker.
run_preflight() {
  local env_file="$1"
  bash -c '
    set +e
    source "'"$ROOT"'/bin/lucairn" >/dev/null 2>&1
    set +e +u +o pipefail
    COMPOSE_PROFILES="" check_vllm_l3_preflight "'"$env_file"'" 0
  ' 2>&1
}

# assert_case NAME ENV_FILE EXPECT_RC [EXPECT_SUBSTRING]
assert_case() {
  local name="$1" env_file="$2" expect_rc="$3" needle="${4:-}"
  N=$((N + 1))
  local out rc ok=1
  # `if` form, not `out=$(...); rc=$?` — the harness runs under `set -e`, where
  # a failing command substitution in an assignment aborts the whole suite.
  if out="$(run_preflight "$env_file")"; then rc=0; else rc=$?; fi
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

# assert_absent NAME ENV_FILE SUBSTRING — the run must NOT print SUBSTRING.
assert_absent() {
  local name="$1" env_file="$2" needle="$3"
  N=$((N + 1))
  local out
  out="$(run_preflight "$env_file" || true)"
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL [$name]: output unexpectedly contained: $needle"
    echo "     output was: $out"
    FAILS=$((FAILS + 1))
  else
    echo "ok   [$name]"
  fi
}

SPLIT_YAML='l3_runtime: vllm
l3_base_url: http://10.0.0.10:8000'

# ---------------------------------------------------------------------------
# The happy path: the split shape doctor previously rejected outright.
# ---------------------------------------------------------------------------

GOOD="$(mk_case good "$SPLIT_YAML" 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_rfc1918_pool_passes" "$GOOD" 0 "l3-split-pool: config ok"

# No in-box check may run on a pool client (this box has no GPU and no local
# vLLM container). Every in-box message is prefixed "vllm-l3:", the split lane's
# are prefixed "l3-split-pool:" — absence of the former proves the in-box
# GPU/WSL2/toolkit/profile path was not entered.
assert_absent "split_runs_no_inbox_vllm_checks" "$GOOD" "vllm-l3:"
assert_case "split_says_gpu_checks_skipped" "$GOOD" 0 "GPU / NVIDIA-toolkit / WSL2 checks SKIPPED"

# Other private forms an operator may legitimately use.
for host_case in "172.16.4.9" "192.168.7.20" "l3pool.internal" "l3pool"; do
  ENVF="$(mk_case "good-${host_case//./-}" "l3_runtime: vllm
l3_base_url: http://${host_case}:8000" 'LUCAIRN_L3_SPLIT_POOL=true')"
  assert_case "split_accepts_${host_case//./-}" "$ENVF" 0 "l3-split-pool: config ok"
done

# ---------------------------------------------------------------------------
# Fail-closed cases (positive controls — each one dies if its guard is removed)
# ---------------------------------------------------------------------------

PUBLIC_FQDN="$(mk_case public-fqdn 'l3_runtime: vllm
l3_base_url: http://pool.example.com:8000' 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_public_fqdn_fails" "$PUBLIC_FQDN" 1 "is NOT internal (public FQDN/IP)"

PUBLIC_IP="$(mk_case public-ip 'l3_runtime: vllm
l3_base_url: http://203.0.113.9:8000' 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_public_ip_fails" "$PUBLIC_IP" 1 "is NOT internal (public FQDN/IP)"

# A hostname that only LOOKS like an RFC1918 address. The pre-2026-08 doctor
# classifier was a `case` glob list (10.*|192.168.*|…) that matched hostnames
# too, so this passed doctor and was then blocked by the sanitizer at boot
# (services/sanitizer/llm_scan.py:476-483 — dotted hostname, no private suffix).
LOOKALIKE="$(mk_case rfc1918-lookalike 'l3_runtime: vllm
l3_base_url: http://10.evil.com:8000' 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_rfc1918_lookalike_hostname_fails" "$LOOKALIKE" 1 "is NOT internal (public FQDN/IP)"

# Leading-zero octets are not an IP to Python's ipaddress -> the sanitizer sees
# a dotted hostname and blocks. Doctor must agree.
LEADING_ZERO="$(mk_case leading-zero 'l3_runtime: vllm
l3_base_url: http://010.0.0.1:8000' 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_leading_zero_octets_fail" "$LEADING_ZERO" 1 "is NOT internal (public FQDN/IP)"

# Cloud metadata / link-local is NEVER internal (classic SSRF egress target).
LINK_LOCAL="$(mk_case link-local 'l3_runtime: vllm
l3_base_url: http://169.254.169.254:8000' 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_link_local_imds_fails" "$LINK_LOCAL" 1 "is NOT internal (public FQDN/IP)"

# Public IPv6 literal. The pre-2026-08 host extraction truncated at the first
# ':' ("[2001") and then silently passed it (no dot -> no glob match).
PUBLIC_V6="$(mk_case public-v6 'l3_runtime: vllm
l3_base_url: http://[2001:4860:4860::8888]:8000' 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_public_ipv6_fails" "$PUBLIC_V6" 1 "is NOT internal (public FQDN/IP)"

# ULA IPv6 is a legitimate private pool address.
ULA_V6="$(mk_case ula-v6 'l3_runtime: vllm
l3_base_url: http://[fd00::5]:8000' 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_ula_ipv6_passes" "$ULA_V6" 0 "l3-split-pool: config ok"

# Userinfo would make the HTTP client synthesize an Authorization header —
# the vLLM L3 backend is credential-free by construction (A-E2).
USERINFO="$(mk_case userinfo 'l3_runtime: vllm
l3_base_url: http://operator:secret@10.0.0.10:8000' 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_userinfo_fails" "$USERINFO" 1 "contains userinfo"

# A split pool is REMOTE. These all resolve to something on this box that
# serves no L3 -> fail-closed 503 on every request.
for local_host in "vllm-l3" "localhost" "127.0.0.1" "0.0.0.0"; do
  ENVF="$(mk_case "local-${local_host//./-}" "l3_runtime: vllm
l3_base_url: http://${local_host}:8000" 'LUCAIRN_L3_SPLIT_POOL=true')"
  assert_case "split_rejects_local_target_${local_host//./-}" "$ENVF" 1 "is a LOCAL target"
done

# Declared split but the YAML runtime switch was never flipped -> L3 still goes
# to ollama-identity while the operator believes it goes to the pool.
NO_RUNTIME="$(mk_case no-runtime 'l3_base_url: http://10.0.0.10:8000' 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_without_yaml_runtime_fails" "$NO_RUNTIME" 1 "does not set 'l3_runtime: vllm'"

# Declared split with the runtime flipped but no endpoint.
NO_URL="$(mk_case no-url 'l3_runtime: vllm' 'LUCAIRN_L3_SPLIT_POOL=true')"
assert_case "split_without_base_url_fails" "$NO_URL" 1 "'l3_base_url' is unset/commented"

# A typo'd marker must NOT silently fall back to "not declared" (that would skip
# the split preflight while the operator believes it runs).
TYPO="$(mk_case typo "$SPLIT_YAML" 'LUCAIRN_L3_SPLIT_POOL=ture')"
assert_case "split_marker_typo_fails_loud" "$TYPO" 1 "unrecognized value"

# Explicit OFF is honoured (and then the ORIGINAL in-box rules apply again).
OFF="$(mk_case off "$SPLIT_YAML" 'LUCAIRN_L3_SPLIT_POOL=false')"
assert_case "split_marker_false_falls_back_to_inbox_rules" "$OFF" 1 "the vllm-l3 profile is not in COMPOSE_PROFILES"

# ---------------------------------------------------------------------------
# No-regression on the in-box lane: the new branch must be inert when the
# marker is absent.
# ---------------------------------------------------------------------------

# The half-enabled in-box shape (YAML says vllm, profile missing) is EXACTLY the
# split shape minus the marker, and must still FAIL as before.
HALF="$(mk_case half-enabled 'l3_runtime: vllm
l3_base_url: http://vllm-l3:8000' '')"
assert_case "inbox_half_enabled_still_fails" "$HALF" 1 "the vllm-l3 profile is not in COMPOSE_PROFILES"
assert_absent "inbox_half_enabled_says_nothing_about_split" "$HALF" "l3-split-pool:"

# The "config ok" line must not claim "no local vllm-l3 profile" when the
# profile IS active — the WARN path and the summary line have to agree.
PROFILE_TOO="$(mk_case profile-too "$SPLIT_YAML" 'LUCAIRN_L3_SPLIT_POOL=true
COMPOSE_PROFILES=vllm-l3')"
assert_case "split_with_active_profile_warns" "$PROFILE_TOO" 0 "compose profile is ALSO active"
assert_absent "split_ok_line_does_not_claim_absent_profile" "$PROFILE_TOO" "no local vllm-l3 profile"

# Stock install (no L3 runtime override at all) stays silent.
STOCK="$(mk_case stock 'model: qwen2.5:7b' '')"
assert_case "inbox_stock_install_silent" "$STOCK" 0
assert_absent "inbox_stock_install_says_nothing_about_split" "$STOCK" "l3-split-pool:"

# ---------------------------------------------------------------------------
# Direct classifier unit cases — pins the doctor<->sanitizer convergence
# contract independently of the preflight wiring.
# ---------------------------------------------------------------------------

classifier_case() {
  # classifier_case URL EXPECT(internal|external)
  local url="$1" expect="$2" got
  N=$((N + 1))
  got="$(bash -c '
    set +e
    source "'"$ROOT"'/bin/lucairn" >/dev/null 2>&1
    set +e +u +o pipefail
    h="$(_l3_base_url_host "'"$url"'")"
    if _l3_host_is_internal "$h"; then printf "internal"; else printf "external"; fi
  ' 2>/dev/null)"
  if [ "$got" = "$expect" ]; then
    echo "ok   [classifier $url -> $got]"
  else
    echo "FAIL [classifier $url]: expected $expect, got $got"
    FAILS=$((FAILS + 1))
  fi
}

# Verified 2026-08-01 against the sanitizer's own `_is_internal_l3_base_url`
# (dual-sandbox-architecture services/sanitizer/llm_scan.py:431-492) by
# exec'ing that function on this exact list: every URL doctor calls internal is
# also internal there (the subset property the guard depends on).
classifier_case "http://10.0.0.10:8000"            internal
classifier_case "http://172.16.3.4:8000"           internal
classifier_case "http://172.31.255.254:8000"       internal
classifier_case "http://192.168.1.5:8000"          internal
classifier_case "http://l3pool.internal:8000"      internal
classifier_case "http://l3pool.svc.cluster.local:8000" internal
classifier_case "http://vllm-l3:8000"              internal
classifier_case "http://[fd00::5]:8000"            internal
classifier_case "http://172.15.3.4:8000"           external
classifier_case "http://172.32.0.1:8000"           external
classifier_case "http://10.evil.com:8000"          external
classifier_case "http://pool.example.com:8000"     external
classifier_case "http://169.254.169.254:8000"      external
classifier_case "http://[2001:4860:4860::8888]:8000" external
classifier_case "http://[fe80::1]:8000"            external
classifier_case "http://999.0.0.1:8000"            external

echo
if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS/$N assertions FAILED"
  exit 1
fi
echo "$N/$N assertions passed"
