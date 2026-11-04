#!/bin/bash
set -euo pipefail

# WP4 S2's keyed journey has two test boundaries.  Validation and custody run
# through the real CLI/helper.  Response-state coverage imports that same
# stdlib helper with an in-process transport fake, because this sandbox blocks
# even loopback socket binds.  No test reaches a non-local network.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
# Kit 2.0 K-A fix round 1: doctor FAILS while this checkout's image-manifest
# still has no signed core/sidecar digests (`pending: true`, before a
# release), and the compose file does not render without them. Every case
# below therefore runs init + doctor from a RELEASED-kit fixture with synthetic
# signed digests (tests/lib/test-helpers.sh); the real tree is REAL_ROOT.
# shellcheck source=lib/test-helpers.sh
. "$ROOT/tests/lib/test-helpers.sh"
lucairn_use_released_kit "$TMPDIR"
BASE_PATH="$PATH"

# The macOS lane has no ubiquitous execve/open tracer.  Its approximation
# wraps every executable doctor can select from PATH and records argv +
# exported environment from inside that child.  It proves the direct-execution
# boundary and catches regressions, but cannot prove kernel-level open/exec
# completeness.  Linux CI strengthens this below with strace when available.
CAPTURE_BIN="$TMPDIR/capture-bin"
CAPTURE_LOG="$TMPDIR/children.capture"
mkdir "$CAPTURE_BIN"
make_capture_wrapper() {
  local tool="$1" real="$2"
  cat > "$CAPTURE_BIN/$tool" <<EOF
#!/bin/bash
{
  printf 'argv:'
  for arg in "\$0" "\$@"; do printf ' %q' "\$arg"; done
  printf '\\n'
  export -p
  printf '%s\\n' '--'
} >> '$CAPTURE_LOG'
exec '$real' "\$@"
EOF
  chmod 0755 "$CAPTURE_BIN/$tool"
}

for tool in awk basename cat date dirname env find grep head hostname lsof mkdir mktemp od pg_isready python3 sed sort stat tr uname; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -z "$real" ] || make_capture_wrapper "$tool" "$real"
done

# Runtime checks remain hermetic; keyed requests use the Python helper, never
# this curl stub.  The stub still records its child boundary for the custody
# approximation and prevents health probes reaching anything outside localhost.
cat > "$CAPTURE_BIN/curl" <<EOF
#!/bin/bash
{
  printf 'argv:'
  for arg in "\$0" "\$@"; do printf ' %q' "\$arg"; done
  printf '\\n'
  export -p
  printf '%s\\n' '--'
} >> '$CAPTURE_LOG'
printf '000'
EOF
chmod 0755 "$CAPTURE_BIN/curl"

# Kit 2.0 K-A fix round 2: the docker stubs below hand bin/compose-env.sh's
# probe renders to the real Compose CLI (client side only).
LUCAIRN_TEST_REAL_DOCKER="$(command -v docker 2>/dev/null || true)"
export LUCAIRN_TEST_REAL_DOCKER
cat > "$CAPTURE_BIN/docker" <<EOF
#!/bin/bash
case " \$* " in *lucairn-env-probe.*) exec "\$LUCAIRN_TEST_REAL_DOCKER" "\$@" ;; esac
{
  printf 'argv:'
  for arg in "\$0" "\$@"; do printf ' %q' "\$arg"; done
  printf '\\n'
  export -p
  printf '%s\\n' '--'
} >> '$CAPTURE_LOG'
if [ "\${1:-}" = compose ]; then
  case " \$* " in
    *' version '*|*' config '*|*' ps '*) exit 0 ;;
  esac
fi
exit 1
EOF
chmod 0755 "$CAPTURE_BIN/docker"
for tool in docker-compose helm kubectl pg_isready; do
  cat > "$CAPTURE_BIN/$tool" <<EOF
#!/bin/bash
{
  printf 'argv:'
  for arg in "\$0" "\$@"; do printf ' %q' "\$arg"; done
  printf '\\n'
  export -p
  printf '%s\\n' '--'
} >> '$CAPTURE_LOG'
exit 1
EOF
  chmod 0755 "$CAPTURE_BIN/$tool"
done

LOCAL_ENV="$TMPDIR/local.env"
"$ROOT/bin/lucairn-init" --confirm-no-registry-volume --dev --runtime-mode local-runtime --local-runtime llama-cpp --model-name fixture-local-model --model-file fixture.gguf --model-path . --output "$LOCAL_ENV" --skip-doctor >/dev/null
awk -v gateway="http://127.0.0.1:99999" '
  /^GATEWAY_BASE_URL=/ { print "GATEWAY_BASE_URL=" gateway; next }
  { print }
' "$LOCAL_ENV" > "$LOCAL_ENV.next"
mv "$LOCAL_ENV.next" "$LOCAL_ENV"

KEY="$TMPDIR/customer.key"
SECRET='lcr_live_full_doctor_custody_canary_never_echo'
printf '%s\n' "$SECRET" > "$KEY"
chmod 600 "$KEY"

# The documented mint → mode-0600 file → keyed doctor sequence must produce a
# helper-valid file, not a banner polluted by status text. Use a curl stub so
# this verifies the actual mint output mode without contacting a gateway.
MINT_BIN="$TMPDIR/mint-bin"
mkdir "$MINT_BIN"
cat > "$MINT_BIN/curl" <<'MINT_CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-X|-H|--data-binary|--max-time) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' '{"dsa_api_key":"lcr_live_documented_mint_key"}' > "$out"
printf '201'
MINT_CURL
chmod 0755 "$MINT_BIN/curl"
DOCUMENTED_KEY="$TMPDIR/documented-customer.key"
(
  umask 077
  LUCAIRN_ADMIN_KEY='admin-fixture-key' PATH="$MINT_BIN:$CAPTURE_BIN:$BASE_PATH" \
    "$ROOT/bin/lucairn-mint-customer" --raw-key-only \
    --name 'Documented Mint Fixture' --email mint@example.test --tier enterprise > "$DOCUMENTED_KEY"
)
chmod 600 "$DOCUMENTED_KEY"
printf '%s\n' 'lcr_live_documented_mint_key' | cmp -s - "$DOCUMENTED_KEY" || {
  echo 'documented mint command did not produce a key-only file' >&2
  exit 1
}

GNU_STAT_BIN="$TMPDIR/gnu-stat-bin"
mkdir "$GNU_STAT_BIN"
cat > "$GNU_STAT_BIN/stat" <<'STAT'
#!/usr/bin/env bash
set -euo pipefail
# A previous Bash reader had to work around GNU/BSD `stat` differences.  The
# helper uses fstat on its sole FD, so this shim must not be consulted at all.
echo "unexpected stat invocation: $*" >&2
exit 98
STAT
chmod 0755 "$GNU_STAT_BIN/stat"

doctor() {
  local _case_name="$1"
  PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor \
    --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" \
    --customer-key-file "$KEY" --skip-image-check
}

doctor_with_path() {
  local _case_name="$1" path="$2"
  PATH="$path" bash "$ROOT/bin/lucairn" doctor \
    --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" \
    --customer-key-file "$KEY" --skip-image-check
}

expect_failure() {
  local name="$1" expected="$2"
  shift 2
  if "$@" > "$TMPDIR/$name.out" 2>&1; then
    echo "expected failure: $name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$TMPDIR/$name.out" || { cat "$TMPDIR/$name.out" >&2; exit 1; }
  ! grep -Fq "$SECRET" "$TMPDIR/$name.out" || { echo "customer key leaked in $name output" >&2; exit 1; }
}

# The helper gets past byte validation for the file produced by the documented
# mint command. The deliberately invalid fixture gateway is reached only after
# that acceptance, so this must not fail as a malformed customer key.
expect_failure documented-mint-key-file 'configuration: failed (GATEWAY_BASE_URL is invalid for online doctor)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor \
    --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" \
    --customer-key-file "$DOCUMENTED_KEY" --skip-image-check

assert_no_canary_in_capture() {
  ! grep -Fq "$SECRET" "$CAPTURE_LOG" || {
    echo 'custody canary leaked to a captured child argv/environment' >&2; exit 1;
  }
}

# Keep the helper's full response/polling contract deterministic without a
# socket.  This swaps only the in-process transport class: the tested helper
# still performs its real one-FD key read, byte validation, JSON parsing,
# request construction, and status handling.  `time.sleep` is replaced only to
# avoid a 33-second wait for the deliberate 12-attempt exhaustion regression.
helper_fixture() {
  local case_name="$1"
  python3 - "$ROOT/bin/lucairn-doctor-keyed.py" "$KEY" "$case_name" <<'PY'
import base64
import importlib.util
import json
import sys
from urllib.parse import urlsplit

helper_path, key_path, case = sys.argv[1:]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lucairn_doctor_keyed", helper_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
attempts = {"certificate": 0}
sleeps = []

# What bin/lucairn reports about the install's L3 shield (names only).
l3_config = {
    "partial-l3-on": "on:LUCAIRN_L3_AVAILABILITY_POSTURE=reject",
    "verified-l3-on": "on:LUCAIRN_L3_AVAILABILITY_POSTURE=reject",
    "partial-l3-unknown": None,
    "partial-l3-shell": "on:shell:LUCAIRN_L3_AVAILABILITY_POSTURE=reject",
    "partial-l3-compose-unknown": "unknown:compose-unreadable",
}.get(case, "off")

# What bin/lucairn reports as the recorded runtime mode (K-E fix round 1): the
# per-request BYOK skip applies on managed-byok only. Every byok/400 case runs
# on managed-byok, so a refusal of another shape fails even where the skip
# exists; the rest run on the suite's local-runtime install.
runtime_mode = {
    "byok-local-runtime": "local-runtime",
    "byok-split-remote": "split-remote",
    "byok-mode-unknown": None,
}.get(case, "managed-byok" if case.startswith(("byok-", "inference-400-")) else "local-runtime")

# A certificate of the kit 2.0 default shape (run log 2026-11-04 row 2): four
# signed claims, the core's PII_SANITIZED claim ran a live scan without
# llm_pii_scan (L3 off), so the witness certifies COMPLETENESS_PARTIAL and
# VERDICT_PARTIAL with every signature valid. The partial-* cases change one
# thing each.
def signed_claim(service, claim_type, payload):
    canonical = {"claim_id": "clm_" + service, "claim_type": claim_type, "data_not_seen": [], "data_seen": [],
                 "payload": payload, "request_id": "req_fixture_1", "service_id": service,
                 "timestamp": "2026-11-04T12:36:27Z"}
    encoded = base64.b64encode(json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    return {"claim_id": "clm_" + service, "request_id": "req_fixture_1", "service_id": service,
            "claim_type": claim_type, "canonical_payload": encoded.decode("ascii")}

sanitizer_payload = {"layers_active": ["presidio_ner", "gliner_ner"], "pii_entities_found": 3, "redaction_manifest_hash": "0" * 64}
ai_payload = {"isolation_probe": "ISOLATION_PROBE_BYOK_EXEMPT", "upstream_auth_mode": "byok"}
if case == "partial-unredacted": sanitizer_payload["layers_active"].append("user_unredacted_segment")
if case == "partial-l3-ran": sanitizer_payload["layers_active"].append("llm_pii_scan")
if case == "partial-cache-only": sanitizer_payload["layers_active"] = ["sanitizer_internal_cache_replay"]
if case == "partial-inference-unfinished": ai_payload["inference_outcome"] = "failed"
claims = [
    signed_claim("dsa-bridge", "CLAIM_TYPE_TOKEN_GENERATED", {}),
    signed_claim("dsa-sanitizer", "CLAIM_TYPE_PII_SANITIZED", sanitizer_payload),
    signed_claim("dsa-ai", "CLAIM_TYPE_INFERENCE_COMPLETED", ai_payload),
    signed_claim("dsa-audit", "CLAIM_TYPE_EVENTS_RECORDED", {}),
]
default_partial = {
    "signatures_valid": True, "completeness": "COMPLETENESS_PARTIAL", "missing_services": [],
    "temporal_consistent": True, "data_visibility_consistent": True, "isolation_verified": True,
    "overall_verdict": "VERDICT_PARTIAL", "byok_exempt": True, "anchor_verifications": [],
    "upstream_auth_mode": "byok", "temporal_order_status": "valid", "cert_tier": "full_chain",
    "l3_coverage_scope": {"record_status": "absent"}, "l3_coverage_evidence": {"record_status": "absent"},
}
sealed = dict(default_partial)
reverified = dict(default_partial, anchor_verifications=[
    {"rail": "tsa", "outcome": "ANCHOR_VERIFY_OUTCOME_ABSENT"},
    {"rail": "rekor", "outcome": "ANCHOR_VERIFY_OUTCOME_ABSENT"},
])
if case == "partial-missing-service":
    claims.pop()
    sealed["missing_services"] = reverified["missing_services"] = ["dsa-audit"]
if case == "partial-order-not-checked": reverified["temporal_order_status"] = "not_checked"
if case == "partial-anchor-failed": reverified["anchor_verifications"] = [{"rail": "tsa", "outcome": "ANCHOR_VERIFY_OUTCOME_FAILED"}]
if case == "partial-sealed-temporal": sealed["temporal_consistent"] = False
partial_certificate = {"certificate_id": "cert_fixture_1", "request_id": "req_fixture_1", "claims": claims, "verification": sealed}
if case == "partial-no-claims": del partial_certificate["claims"]

class FixtureResponse:
    def __init__(self, status, body):
        self.status = status
        self.body = body

    def read(self, _limit):
        return self.body

class FixtureConnection:
    def __init__(self, host, port=None, timeout=None, context=None):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.context = context
        self.response = None
        if case == "proxy-explicit":
            assert (host, port) == ("proxy.example", 8080)

    def set_tunnel(self, host, port):
        assert case == "https-proxy-explicit"
        assert (host, port) == ("127.0.0.1", 443)

    def request(self, method, target, body=None, headers=None):
        assert headers and headers["x-api-key"].startswith(("dsa_", "lcr_live_"))
        assert self.timeout == 5
        if case == "proxy-explicit":
            assert target.startswith("http://127.0.0.1:1/")
        else:
            assert target.startswith("/")
        suffix = urlsplit(target).path if target.startswith("http") else target
        if suffix == "/v1/chat/completions":
            assert method == "POST" and json.loads(body) == {
                "model": "fixture-local-model",
                "messages": [{"role": "user", "content": "Respond with the word ready."}],
                "max_tokens": 8,
            }
            byok_refusal = b'{"error":{"message":"Upstream LLM API key required.","type":"invalid_request_error","code":"missing_upstream_key"}}'
            if case == "inference-non2xx": self.response = FixtureResponse(503, b"{}")
            elif case in ("byok-missing-upstream-key", "byok-local-runtime", "byok-split-remote", "byok-mode-unknown"): self.response = FixtureResponse(400, byok_refusal)
            elif case == "byok-refusal-wrong-status": self.response = FixtureResponse(401, byok_refusal)
            elif case == "inference-400-other-code": self.response = FixtureResponse(400, b'{"error":{"message":"Unknown model.","type":"invalid_request_error","code":"model_not_found"}}')
            elif case == "inference-400-code-wrong-type": self.response = FixtureResponse(400, b'{"error":{"message":"x","type":"api_error","code":"missing_upstream_key"}}')
            elif case == "inference-400-code-top-level": self.response = FixtureResponse(400, b'{"code":"missing_upstream_key","message":"x"}')
            elif case == "inference-400-malformed": self.response = FixtureResponse(400, b"missing_upstream_key")
            elif case == "inference-malformed": self.response = FixtureResponse(200, b"not-json")
            elif case == "inference-missing-id": self.response = FixtureResponse(200, b'{"metadata":{"dsa_compliance":{}}}')
            else: self.response = FixtureResponse(200, b'{"metadata":{"dsa_compliance":{"request_id":"req_fixture_1"}}}')
            return
        if suffix == "/api/v1/veil/certificate/req_fixture_1":
            assert method == "GET" and body is None
            attempts["certificate"] += 1
            if case == "evidence-terminal": self.response = FixtureResponse(500, b"{}")
            elif case == "evidence-exhaust": self.response = FixtureResponse(202, b"{}")
            elif case in ("success", "proxy-explicit") and attempts["certificate"] < 3: self.response = FixtureResponse(202, b"{}")
            elif case.startswith("partial-"): self.response = FixtureResponse(200, json.dumps(partial_certificate).encode("utf-8"))
            else: self.response = FixtureResponse(200, b'{"certificate_id":"cert_fixture_1"}')
            return
        if suffix == "/api/v1/veil/verify":
            assert method == "POST" and json.loads(body) == {"request_id": "req_fixture_1"}
            if case == "verification-non2xx": self.response = FixtureResponse(500, b"{}")
            elif case == "verification-false": self.response = FixtureResponse(200, b'{"signatures_valid":false,"overall_verdict":"VERDICT_VERIFIED"}')
            elif case == "verification-malformed": self.response = FixtureResponse(200, b"not-json")
            elif case == "verdict-failed": self.response = FixtureResponse(200, b'{"signatures_valid":true,"overall_verdict":"VERDICT_FAILED"}')
            elif case.startswith("partial-"): self.response = FixtureResponse(200, json.dumps(reverified).encode("utf-8"))
            else: self.response = FixtureResponse(200, b'{"signatures_valid":true,"overall_verdict":"VERDICT_VERIFIED"}')
            return
        raise AssertionError(f"unexpected fixture request: {method} {suffix}")

    def getresponse(self):
        return self.response

    def close(self):
        pass

module.http.client.HTTPConnection = FixtureConnection
module.http.client.HTTPSConnection = FixtureConnection
module.time.sleep = lambda seconds: sleeps.append(seconds)
try:
    proxy = "http://proxy.example:8080" if case == "proxy-explicit" else None
    module.run_journey(key_path, "http://127.0.0.1:1", "fixture-local-model", proxy, None, l3_config=l3_config, runtime_mode=runtime_mode)
    if case == "byok-missing-upstream-key":
        # The skip ends the keyed journey: no certificate read, no verify call.
        assert attempts["certificate"] == 0
except module.DoctorFailure:
    if case == "evidence-exhaust":
        assert attempts["certificate"] == 12
        assert sleeps == [3] * 11
    raise
PY
}

# Offline doctor remains Python-free: a poisoning python3 on PATH must not be
# selected.  It is intentionally a complete configuration preflight, not a
# reduced code path.
NO_PYTHON_BIN="$TMPDIR/no-python-bin"
mkdir "$NO_PYTHON_BIN"
cat > "$NO_PYTHON_BIN/python3" <<'PYTHON'
#!/bin/bash
echo 'offline doctor unexpectedly invoked python3' >&2
exit 99
PYTHON
chmod 0755 "$NO_PYTHON_BIN/python3"
PATH="$NO_PYTHON_BIN:$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor \
  --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check \
  > "$TMPDIR/offline.out" 2>&1
tail -1 "$TMPDIR/offline.out" | grep -Fx 'doctor: preflight ok (offline)'

# Online keyed doctor fails closed, naming the pinned prerequisite, when the
# only python3 candidate is unavailable.
expect_failure no-python 'configuration: failed (online doctor requires Python 3.8+' \
  doctor_with_path success "$NO_PYTHON_BIN:$CAPTURE_BIN:$BASE_PATH"

# Key validation is isolated inside the helper, before any authenticated HTTP
# request.  These preserve each frozen r1-r5 regression fixture.
expect_failure missing-key 'configuration: failed (customer key file is not an existing regular file)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$TMPDIR/missing" --skip-image-check
chmod 644 "$KEY"
expect_failure bad-mode 'configuration: failed (customer key file must have mode 0600)' doctor success
chmod 600 "$KEY"
: > "$TMPDIR/empty.key"; chmod 600 "$TMPDIR/empty.key"
expect_failure empty-key 'configuration: failed (customer key file is empty)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$TMPDIR/empty.key" --skip-image-check
mkdir "$TMPDIR/key-directory"
expect_failure directory-key 'configuration: failed (customer key file is not an existing regular file)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$TMPDIR/key-directory" --skip-image-check
ln -s "$KEY" "$TMPDIR/symlink.key"
expect_failure symlink-key 'configuration: failed (customer key file is not an existing regular file)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$TMPDIR/symlink.key" --skip-image-check
printf 'not a valid key\n' > "$TMPDIR/malformed.key"; chmod 600 "$TMPDIR/malformed.key"
expect_failure malformed-key 'configuration: failed (customer key file is malformed)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$TMPDIR/malformed.key" --skip-image-check
printf 'lcr_live_a\0bc\n' > "$TMPDIR/nul.key"; chmod 600 "$TMPDIR/nul.key"
expect_failure nul-key 'configuration: failed (customer key file is malformed)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$TMPDIR/nul.key" --skip-image-check
for invalid_key in sk-provider-key dsa_ lcr_live_ lcr_live_bad^key; do
  invalid_file="$TMPDIR/invalid-${invalid_key}.key"
  printf '%s\n' "$invalid_key" > "$invalid_file"; chmod 600 "$invalid_file"
  expect_failure "invalid-${invalid_key}" 'configuration: failed (customer key file is malformed)' \
    env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$invalid_file" --skip-image-check
done
printf 'lcr_live_validline\nsecond-line\n' > "$TMPDIR/multiline.key"; chmod 600 "$TMPDIR/multiline.key"
expect_failure multiline-key 'configuration: failed (customer key file is malformed)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$TMPDIR/multiline.key" --skip-image-check
printf 'dsa_validline\nsecond-line\n' > "$TMPDIR/multiline-dsa.key"; chmod 600 "$TMPDIR/multiline-dsa.key"
expect_failure multiline-dsa-key 'configuration: failed (customer key file is malformed)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$TMPDIR/multiline-dsa.key" --skip-image-check
printf 'lcr_live_valid_key\n\n' > "$TMPDIR/multiline-blank.key"; chmod 600 "$TMPDIR/multiline-blank.key"
expect_failure multiline-blank-key 'configuration: failed (customer key file is malformed)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$TMPDIR/multiline-blank.key" --skip-image-check
NON_C_LOCALE="$(locale -a | LC_ALL=C grep -Ev '^(C|POSIX)$' | head -n 1 || true)"
[ -n "$NON_C_LOCALE" ] || NON_C_LOCALE=C
printf 'lcr_live_café\n' > "$TMPDIR/non-ascii.key"; chmod 600 "$TMPDIR/non-ascii.key"
expect_failure non-c-locale-key 'configuration: failed (customer key file is malformed)' \
  env LC_ALL="$NON_C_LOCALE" PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$TMPDIR/non-ascii.key" --skip-image-check

# The local model comes only from S1's recorded inventory.
ABSENT_ENV="$TMPDIR/absent.env"; cp "$LOCAL_ENV" "$ABSENT_ENV"; cp "$LOCAL_ENV.image-manifest.yaml" "$ABSENT_ENV.image-manifest.yaml"
sed '/^  model_name:/d' "$LOCAL_ENV.runtime-profile.yaml" > "$ABSENT_ENV.runtime-profile.yaml"
expect_failure absent-local-model 'configuration: failed (local-runtime model name is absent or ambiguous)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$ABSENT_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$KEY" --model ignored-fallback --skip-image-check
AMBIGUOUS_ENV="$TMPDIR/ambiguous.env"; cp "$LOCAL_ENV" "$AMBIGUOUS_ENV"; cp "$LOCAL_ENV.image-manifest.yaml" "$AMBIGUOUS_ENV.image-manifest.yaml"; cp "$LOCAL_ENV.runtime-profile.yaml" "$AMBIGUOUS_ENV.runtime-profile.yaml"; printf '  model_name: second-model\n' >> "$AMBIGUOUS_ENV.runtime-profile.yaml"
expect_failure ambiguous-local-model 'configuration: failed (local-runtime model name is absent or ambiguous)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$AMBIGUOUS_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$KEY" --model ignored-fallback --skip-image-check
SPLIT_ENV="$TMPDIR/split.env"; cp "$LOCAL_ENV" "$SPLIT_ENV"; printf 'runtime_mode: split-remote\n' > "$SPLIT_ENV.runtime-profile.yaml"
expect_failure split-model 'configuration: failed (--model is required for split-remote)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$SPLIT_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$KEY" --skip-image-check
BYOK_ENV="$TMPDIR/byok.env"; cp "$LOCAL_ENV" "$BYOK_ENV"; printf 'runtime_mode: managed-byok\n' > "$BYOK_ENV.runtime-profile.yaml"
expect_failure byok-model 'configuration: failed (--model is required for managed-byok)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$BYOK_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$KEY" --skip-image-check

# The helper has no platform stat dependency: a hostile GNU-stat stand-in does
# does not run, while a mode-0600 key reaches the helper's runtime step.
expect_failure gnu-stat 'configuration: failed (GATEWAY_BASE_URL is invalid for online doctor)' doctor_with_path success "$GNU_STAT_BIN:$CAPTURE_BIN:$BASE_PATH"
! grep -Fq 'unexpected stat invocation' "$TMPDIR/gnu-stat.out" || { echo 'helper used platform stat' >&2; exit 1; }

expect_failure unavailable-listener 'configuration: failed (GATEWAY_BASE_URL is invalid for online doctor)' doctor success
expect_failure inference-non2xx 'inference: failed (gateway returned HTTP 503)' helper_fixture inference-non2xx
expect_failure inference-malformed 'inference: failed (response is malformed or missing metadata.dsa_compliance.request_id)' helper_fixture inference-malformed
expect_failure inference-missing-id 'inference: failed (response is malformed or missing metadata.dsa_compliance.request_id)' helper_fixture inference-missing-id
# Kit 2.0 (PRD row 2): on a per-request-BYOK key (the mint default) the
# gateway refuses the doctor's keyed turn with missing_upstream_key, because
# neither the key nor the doctor holds a provider key. That exact refusal is a
# named skip, not a failure; any other keyed-step error still fails.
helper_fixture byok-missing-upstream-key > "$TMPDIR/byok-skip.out" 2>&1 \
  || { cat "$TMPDIR/byok-skip.out" >&2; echo 'byok-missing-upstream-key: the per-request BYOK refusal must be a skip, not a failure' >&2; exit 1; }
grep -Fx 'keyed inference: skipped — per-request BYOK install, no provider key for the doctor; run one real turn to check it' "$TMPDIR/byok-skip.out"
grep -Fx 'evidence: skipped (no keyed turn to read a certificate for)' "$TMPDIR/byok-skip.out"
grep -Fx 'verification: skipped (no keyed turn to verify)' "$TMPDIR/byok-skip.out"
! grep -Eq 'failed|doctor: ok|inference: ok' "$TMPDIR/byok-skip.out" \
  || { cat "$TMPDIR/byok-skip.out" >&2; echo 'byok-missing-upstream-key: the skip must not read as a pass or a failure' >&2; exit 1; }
# K-E fix round 1 (review P2 on PR #162): the skip holds on a managed-byok
# install only. On local-runtime / split-remote no provider key travels per
# request, so the same refusal is a wrongly provisioned key; an unknown mode
# fails too. None of them may print the skip lines.
expect_failure byok-local-runtime 'inference: failed (gateway refused the key with missing_upstream_key on a local-runtime install: it was minted for per-request BYOK, which only a managed-byok install uses; mint the doctor key with --no-byok-per-request)' helper_fixture byok-local-runtime
expect_failure byok-split-remote 'inference: failed (gateway refused the key with missing_upstream_key on a split-remote install' helper_fixture byok-split-remote
expect_failure byok-mode-unknown "inference: failed (gateway refused the key with missing_upstream_key, and the doctor was not told this install's runtime mode" helper_fixture byok-mode-unknown
for byok_case in byok-local-runtime byok-split-remote byok-mode-unknown; do
  ! grep -Eq 'skipped|doctor: ok' "$TMPDIR/$byok_case.out" \
    || { cat "$TMPDIR/$byok_case.out" >&2; echo "$byok_case: the BYOK skip must not apply" >&2; exit 1; }
done
expect_failure byok-refusal-wrong-status 'inference: failed (gateway returned HTTP 401)' helper_fixture byok-refusal-wrong-status
expect_failure inference-400-other-code 'inference: failed (gateway returned HTTP 400)' helper_fixture inference-400-other-code
expect_failure inference-400-code-wrong-type 'inference: failed (gateway returned HTTP 400)' helper_fixture inference-400-code-wrong-type
expect_failure inference-400-code-top-level 'inference: failed (gateway returned HTTP 400)' helper_fixture inference-400-code-top-level
expect_failure inference-400-malformed 'inference: failed (gateway returned HTTP 400)' helper_fixture inference-400-malformed
expect_failure evidence-terminal 'evidence: failed (certificate endpoint returned HTTP 500)' helper_fixture evidence-terminal
expect_failure evidence-exhaust 'evidence: failed (certificate was not ready after 12 attempts)' helper_fixture evidence-exhaust
expect_failure verification-non2xx 'verification: failed (verify endpoint returned HTTP 500)' helper_fixture verification-non2xx
expect_failure verification-false 'verification: failed (response is malformed or witness signature is not verified)' helper_fixture verification-false
expect_failure verification-malformed 'verification: failed (response is malformed or witness signature is not verified)' helper_fixture verification-malformed

helper_fixture success > "$TMPDIR/success.out" 2>&1
grep -Fx 'inference: ok (authenticated)' "$TMPDIR/success.out"
grep -Fx 'evidence: ok (certificate received)' "$TMPDIR/success.out"
grep -Fx 'verification: ok (witness signature: verified; anchors: not checked)' "$TMPDIR/success.out"
tail -1 "$TMPDIR/success.out" | grep -Fx 'doctor: ok'
! grep -Fq 'verdict partial' "$TMPDIR/success.out" || { echo 'success: a verified verdict must not print the partial line' >&2; exit 1; }
expect_failure verdict-failed 'verification: failed (response is malformed or witness signature is not verified)' helper_fixture verdict-failed

# Kit 2.0 (PRD row 2, owner baseline 31 Oct): the kit default runs the L3 shield
# OFF, so a correct install's certificate reads VERDICT_PARTIAL for the
# L3-coverage reason only. That is accepted as a named line; nothing else is.
helper_fixture partial-l3-off > "$TMPDIR/partial-l3-off.out" 2>&1 \
  || { cat "$TMPDIR/partial-l3-off.out" >&2; echo 'partial-l3-off: the default L3-off PARTIAL must pass' >&2; exit 1; }
grep -Fx 'verification: ok (witness signature: verified; anchors: not checked)' "$TMPDIR/partial-l3-off.out"
grep -Fx 'verdict partial: L3 off on this install (expected)' "$TMPDIR/partial-l3-off.out"
tail -1 "$TMPDIR/partial-l3-off.out" | grep -Fx 'doctor: ok'
helper_fixture verified-l3-on > "$TMPDIR/verified-l3-on.out" 2>&1 \
  || { cat "$TMPDIR/verified-l3-on.out" >&2; echo 'verified-l3-on: a verified verdict passes whatever the L3 setting' >&2; exit 1; }
tail -1 "$TMPDIR/verified-l3-on.out" | grep -Fx 'doctor: ok'
expect_failure partial-l3-on 'verification: failed (verdict partial: L3 is configured on for this install (LUCAIRN_L3_AVAILABILITY_POSTURE=reject))' helper_fixture partial-l3-on
expect_failure partial-l3-unknown 'verification: failed (verdict partial: the doctor was not told whether L3 is off on this install)' helper_fixture partial-l3-unknown
expect_failure partial-l3-shell 'verification: failed (verdict partial: L3 is configured on for this install (LUCAIRN_L3_AVAILABILITY_POSTURE=reject, exported in this shell: Docker Compose uses it over customer.env))' helper_fixture partial-l3-shell
expect_failure partial-l3-compose-unknown "verification: failed (verdict partial: the doctor could not read this install's L3 settings through Docker Compose (compose-unreadable))" helper_fixture partial-l3-compose-unknown
expect_failure partial-missing-service 'verification: failed (verdict partial: missing services: dsa-audit' helper_fixture partial-missing-service
expect_failure partial-order-not-checked 'verification: failed (verdict partial: claim order not_checked)' helper_fixture partial-order-not-checked
expect_failure partial-anchor-failed 'verification: failed (verdict partial: anchor tsa failed)' helper_fixture partial-anchor-failed
expect_failure partial-sealed-temporal 'verification: failed (verdict partial: sealed temporal_consistent is not true)' helper_fixture partial-sealed-temporal
expect_failure partial-unredacted 'verification: failed (verdict partial: a message was sent unredacted)' helper_fixture partial-unredacted
expect_failure partial-l3-ran 'verification: failed (verdict partial: llm_pii_scan present, so L3 coverage is not the cause)' helper_fixture partial-l3-ran
expect_failure partial-cache-only 'verification: failed (verdict partial: no live scan on this request, so L3 coverage is not the cause)' helper_fixture partial-cache-only
expect_failure partial-inference-unfinished 'verification: failed (verdict partial: inference did not finish (claim dsa-ai))' helper_fixture partial-inference-unfinished
expect_failure partial-no-claims 'verification: failed (verdict partial: certificate claims are unreadable)' helper_fixture partial-no-claims
for partial_case in partial-l3-on partial-l3-unknown partial-l3-shell partial-l3-compose-unknown partial-missing-service partial-order-not-checked partial-anchor-failed partial-sealed-temporal partial-unredacted partial-l3-ran partial-cache-only partial-inference-unfinished partial-no-claims; do
  ! grep -Eq 'verdict partial: L3 off on this install|doctor: ok' "$TMPDIR/$partial_case.out" \
    || { cat "$TMPDIR/$partial_case.out" >&2; echo "$partial_case: must not read as accepted" >&2; exit 1; }
done

# bin/lucairn tells the helper what the install's L3 setting is: "off" on the
# default env, the NAME of the first L3 setting otherwise (never its value).
: > "$CAPTURE_LOG"
expect_failure l3-config-default 'configuration: failed (GATEWAY_BASE_URL is invalid for online doctor)' doctor success
grep 'lucairn-doctor-keyed\.py' "$CAPTURE_LOG" | grep -Fq -- '--l3-config off' \
  || { grep 'lucairn-doctor-keyed' "$CAPTURE_LOG" >&2; echo 'doctor must pass --l3-config off on the default env' >&2; exit 1; }
# ... and the runtime mode its runtime profile records (a name), which gates
# the per-request BYOK skip (K-E fix round 1).
grep 'lucairn-doctor-keyed\.py' "$CAPTURE_LOG" | grep -Fq -- '--runtime-mode local-runtime' \
  || { grep 'lucairn-doctor-keyed' "$CAPTURE_LOG" >&2; echo 'doctor must pass --runtime-mode local-runtime for the local-runtime install' >&2; exit 1; }
L3_ON_ENV="$TMPDIR/l3-on.env"; cp "$LOCAL_ENV" "$L3_ON_ENV"; cp "$LOCAL_ENV.image-manifest.yaml" "$L3_ON_ENV.image-manifest.yaml"; cp "$LOCAL_ENV.runtime-profile.yaml" "$L3_ON_ENV.runtime-profile.yaml"
printf 'OLLAMA_URL=http://l3-user:l3-secret-canary@ollama.example:11434\n' >> "$L3_ON_ENV"
: > "$CAPTURE_LOG"
expect_failure l3-config-on 'configuration: failed (GATEWAY_BASE_URL is invalid for online doctor)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$L3_ON_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$KEY" --skip-image-check
grep 'lucairn-doctor-keyed\.py' "$CAPTURE_LOG" | grep -Fq -- '--l3-config on:OLLAMA_URL' \
  || { grep 'lucairn-doctor-keyed' "$CAPTURE_LOG" >&2; echo 'doctor must name OLLAMA_URL as the L3 setting' >&2; exit 1; }
! grep 'lucairn-doctor-keyed\.py' "$CAPTURE_LOG" | grep -Fq 'l3-secret-canary' \
  || { echo 'the L3 setting value must never reach the helper' >&2; exit 1; }

# K-E fix round 1 (review P2 on PR #162): the L3 settings are read the way
# Docker Compose reads them. customer.env says `degrade`, the shell exports
# `reject`: Compose interpolates `reject` into the sanitizer, so the doctor must
# not report L3 off (the old raw-file reader said "off" and the L3-off PARTIAL
# exception was wrongly allowed). Without the export the same env is "off".
L3_SHELL_ENV="$TMPDIR/l3-shell.env"; cp "$LOCAL_ENV" "$L3_SHELL_ENV"; cp "$LOCAL_ENV.image-manifest.yaml" "$L3_SHELL_ENV.image-manifest.yaml"; cp "$LOCAL_ENV.runtime-profile.yaml" "$L3_SHELL_ENV.runtime-profile.yaml"
printf 'LUCAIRN_L3_AVAILABILITY_POSTURE=degrade\n' >> "$L3_SHELL_ENV"
: > "$CAPTURE_LOG"
expect_failure l3-config-file-degrade 'configuration: failed (GATEWAY_BASE_URL is invalid for online doctor)' \
  env PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$L3_SHELL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$KEY" --skip-image-check
grep 'lucairn-doctor-keyed\.py' "$CAPTURE_LOG" | grep -Fq -- '--l3-config off' \
  || { grep 'lucairn-doctor-keyed' "$CAPTURE_LOG" >&2; echo 'doctor must pass --l3-config off for a file posture degrade with no export' >&2; exit 1; }
: > "$CAPTURE_LOG"
expect_failure l3-config-shell-reject 'configuration: failed (GATEWAY_BASE_URL is invalid for online doctor)' \
  env LUCAIRN_L3_AVAILABILITY_POSTURE=reject PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$L3_SHELL_ENV" --compose "$ROOT/docker-compose.customer.yml" --customer-key-file "$KEY" --skip-image-check
grep 'lucairn-doctor-keyed\.py' "$CAPTURE_LOG" | grep -Fq -- '--l3-config on:shell:LUCAIRN_L3_AVAILABILITY_POSTURE=reject' \
  || { grep 'lucairn-doctor-keyed' "$CAPTURE_LOG" >&2; echo 'doctor must report the exported posture reject (Compose uses it over customer.env)' >&2; exit 1; }

# The helper accepts proxy/CA configuration only from its explicit arguments.
# Both failure probes stop before a network connection is attempted.
expect_failure invalid-proxy 'configuration: failed (online doctor proxy must be an http:// URL)' \
  python3 "$ROOT/bin/lucairn-doctor-keyed.py" --key-file "$KEY" --gateway-url http://127.0.0.1:1 --model fixture-local-model --proxy https://proxy.invalid
expect_failure missing-private-ca 'configuration: failed (online doctor private CA file is not readable)' \
  python3 "$ROOT/bin/lucairn-doctor-keyed.py" --key-file "$KEY" --gateway-url https://127.0.0.1:1 --model fixture-local-model --ca-file "$TMPDIR/missing-ca.pem"

# The real AuthenticatedClient request path is exercised with a patched socket
# constructor: the explicit proxy becomes the only proxy endpoint even when
# conventional proxy variables are poisoned in the helper process environment.
HTTP_PROXY='http://poison.invalid:9' HTTPS_PROXY='http://poison.invalid:9' ALL_PROXY='http://poison.invalid:9' \
  helper_fixture proxy-explicit > "$TMPDIR/proxy.out" 2>&1
tail -1 "$TMPDIR/proxy.out" | grep -Fx 'doctor: ok'

# Decisive custody test: the root Bash intentionally begins with the canary.
# `unset` is its first executable statement, so every captured descendant must
# be canary-free; only the isolated helper receives the key file path.
: > "$CAPTURE_LOG"
if DOCTOR_CUSTOMER_KEY="$SECRET" PATH="$CAPTURE_BIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor \
  --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" \
  --customer-key-file "$KEY" --skip-image-check > "$TMPDIR/custody.out" 2>&1; then
  echo 'expected invalid-gateway failure in custody fixture' >&2
  exit 1
fi
grep -Fx 'configuration: failed (GATEWAY_BASE_URL is invalid for online doctor)' "$TMPDIR/custody.out"
assert_no_canary_in_capture
! grep -Fq "$SECRET" "$TMPDIR/custody.out" || { echo 'customer key leaked to doctor output' >&2; exit 1; }

# Inherited Bash tracing, including a separate trace FD, must not contain key
# bytes.  The helper is a Python process with no inherited environment.
if DOCTOR_CUSTOMER_KEY="$SECRET" BASH_XTRACEFD=3 PATH="$CAPTURE_BIN:$BASE_PATH" bash -x "$ROOT/bin/lucairn" doctor \
  --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" \
  --customer-key-file "$KEY" --skip-image-check > "$TMPDIR/xtrace.stdout" 2> "$TMPDIR/xtrace.stderr" 3> "$TMPDIR/xtrace.fd"; then
  echo 'expected invalid-gateway failure in xtrace fixture' >&2
  exit 1
fi
for output in "$TMPDIR/xtrace.stdout" "$TMPDIR/xtrace.stderr" "$TMPDIR/xtrace.fd"; do
  ! grep -Fq "$SECRET" "$output" || { echo "customer key leaked to $output" >&2; exit 1; }
done

# Linux must run this decisive execve/open proof. The initial traced Bash is
# explicitly allowed to inherit the canary; every other PID is a descendant
# and must be canary-free. Exactly one openat of the key path must belong to
# the Python helper process. macOS runs the documented PATH-capture
# approximation above because strace is not a standard macOS facility.
if [ "$(uname -s)" = Linux ]; then
  command -v strace >/dev/null 2>&1 || {
    echo 'full doctor custody: strace is required on Linux' >&2
    exit 1
  }
  TRACE="$TMPDIR/custody.strace"
  if DOCTOR_CUSTOMER_KEY="$SECRET" PATH="$CAPTURE_BIN:$BASE_PATH" strace -f -v -s 8192 \
    -e trace=execve,openat -o "$TRACE" bash "$ROOT/bin/lucairn" doctor \
    --env "$LOCAL_ENV" --compose "$ROOT/docker-compose.customer.yml" \
    --customer-key-file "$KEY" --skip-image-check > "$TMPDIR/strace.out" 2>&1; then
    echo 'expected invalid-gateway failure in strace fixture' >&2
    exit 1
  fi
  ROOT_PID="$(awk 'match($1, /^[0-9]+$/) { print $1; exit }' "$TRACE")"
  [ -n "$ROOT_PID" ] || { echo 'strace did not identify root Bash PID' >&2; exit 1; }
  if awk -v root="$ROOT_PID" -v canary="$SECRET" '$1 != root && /execve/ && index($0, canary)' "$TRACE" | grep -q .; then
    echo 'custody canary leaked to a traced descendant execve argv/environment' >&2
    exit 1
  fi
  HELPER_PID="$(awk '/execve/ && /lucairn-doctor-keyed\.py/ { print $1; exit }' "$TRACE")"
  [ -n "$HELPER_PID" ] || { echo 'strace did not observe helper execve' >&2; exit 1; }
  KEY_OPEN_PIDS="$(awk -v key="$KEY" '$0 ~ /openat/ && index($0, key) { print $1 }' "$TRACE")"
  KEY_OPEN_COUNT="$(printf '%s\n' "$KEY_OPEN_PIDS" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$KEY_OPEN_COUNT" = 1 ] && [ "$KEY_OPEN_PIDS" = "$HELPER_PID" ] || {
    echo "only helper may open the key file exactly once (saw PIDs: ${KEY_OPEN_PIDS:-none}; helper: $HELPER_PID)" >&2
    exit 1
  }
else
  echo 'full doctor custody: macOS/no-strace PATH-capture approximation active'
fi

echo 'full doctor tests: ok'
