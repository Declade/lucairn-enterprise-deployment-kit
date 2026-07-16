#!/bin/bash
set -euo pipefail

# WP4 S2's keyed journey has two test boundaries.  Validation and custody run
# through the real CLI/helper.  Response-state coverage imports that same
# stdlib helper with an in-process transport fake, because this sandbox blocks
# even loopback socket binds.  No test reaches a non-local network.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
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

cat > "$CAPTURE_BIN/docker" <<EOF
#!/bin/bash
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
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --model-name fixture-local-model --model-file fixture.gguf --model-path . --output "$LOCAL_ENV" --skip-doctor >/dev/null
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
            if case == "inference-non2xx": self.response = FixtureResponse(503, b"{}")
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
            else: self.response = FixtureResponse(200, b'{"certificate_id":"cert_fixture_1"}')
            return
        if suffix == "/api/v1/veil/verify":
            assert method == "POST" and json.loads(body) == {"request_id": "req_fixture_1"}
            if case == "verification-non2xx": self.response = FixtureResponse(500, b"{}")
            elif case == "verification-false": self.response = FixtureResponse(200, b'{"signatures_valid":false,"overall_verdict":"VERDICT_VERIFIED"}')
            elif case == "verification-malformed": self.response = FixtureResponse(200, b"not-json")
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
    module.run_journey(key_path, "http://127.0.0.1:1", "fixture-local-model", proxy, None)
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
