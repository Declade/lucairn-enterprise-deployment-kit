#!/usr/bin/env bash
# Tool runner (Preview) — kit packaging tests.
#
# Covers: the opt-in doctor checks (compose env + Helm values), the
# `tool-policy` helper, the compose service's hardening and network
# attachment, the Helm sub-chart render guards, the image entrypoint's unit
# tests, the image-manifest slot and the wording rules of the customer page.
#
# Hermetic: synthetic values only, no network, no ServiceNow instance, no
# container is started. Sections that need helm / docker compose / node / ruby
# say "skipped" by name when the tool is absent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
ok() { PASS=$((PASS + 1)); echo "ok: $1"; }
die() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
PKCS8_PREFIX=302e020100300506032b657004220420
hex_to_b64() { printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')" | base64 | tr -d '\n'; }
repeat_byte() { local out="" i; for i in $(seq 32); do out="$out$1"; done; printf '%s' "$out"; }
KEY_REAL="$(hex_to_b64 "${PKCS8_PREFIX}7c1f0a93e5d24b6881a3f0c95e7712ab4d09c6e2f318b7a05c44d9e1f6a2b3c8")"
KEY_ZERO="$(hex_to_b64 "${PKCS8_PREFIX}$(repeat_byte 00)")"
KEY_SAME="$(hex_to_b64 "${PKCS8_PREFIX}$(repeat_byte ab)")"
KEY_SEQ="$(hex_to_b64 "${PKCS8_PREFIX}000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")"
KEY_DOWN="$(hex_to_b64 "${PKCS8_PREFIX}201f1e1d1c1b1a191817161514131211100f0e0d0c0b0a090807060504030201")"
KEY_RFC="$(hex_to_b64 "${PKCS8_PREFIX}9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")"
SECRET_CANARY='synthetic-servicenow-password-canary-never-echo'

POLICY_JSON='{"schema":"lucairn-tool-policy/1","connector":"servicenow","presets":{"incident":{"level":"strict"}}}'

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# make_fixture NAME — a kit-like directory: compose file, env file, policy, secrets.
make_fixture() {
  local dir="$TMP/$1"
  mkdir -p "$dir/tool-runner/secrets"
  cp "$ROOT/docker-compose.customer.yml" "$ROOT/docker-compose.self-hosted.yml" "$dir/"
  printf '%s\n' "$POLICY_JSON" > "$dir/tool-runner/policy.json"
  printf '%s\n' 'svc.lucairn.runner' > "$dir/tool-runner/secrets/servicenow_username"
  printf '%s\n' "$SECRET_CANARY" > "$dir/tool-runner/secrets/servicenow_password"
  printf '%s' "$KEY_REAL" > "$dir/tool-runner/secrets/signing_key"
  : > "$dir/tool-runner/secrets/gateway_key"
  : > "$dir/tool-runner/secrets/approver_secret"
  chmod 0400 "$dir"/tool-runner/secrets/*
  cat > "$dir/customer.env" <<ENV
DSA_ENV=development
LUCAIRN_TOOL_RUNNER_ENABLED=true
LUCAIRN_TOOL_RUNNER_INSTANCE_URL=https://example-dev.service-now.com
LUCAIRN_TOOL_RUNNER_INSTANCE_CLASS=dev
LUCAIRN_TOOL_RUNNER_PRINCIPAL=platform-team@example.test
LUCAIRN_TOOL_RUNNER_POLICY_SHA256=$(sha_of "$dir/tool-runner/policy.json")
ENV
  printf '%s' "$dir"
}
set_env() { # FILE KEY VALUE
  grep -v "^$2=" "$1" > "$1.next" || true
  printf '%s=%s\n' "$2" "$3" >> "$1.next"
  mv "$1.next" "$1"
}
put_secret() { # DIR NAME VALUE
  chmod 0600 "$1/tool-runner/secrets/$2"
  printf '%s' "$3" > "$1/tool-runner/secrets/$2"
  chmod 0400 "$1/tool-runner/secrets/$2"
}

# run_check DIR — calls check_tool_runner in a subshell with the CLI sourced
# (empty args: the trailing `main "$@"` degrades to a usage print).
run_check() {
  local dir="$1"
  (
    set +e
    unset COMPOSE_PROFILES DOCTOR_INCLUDE_TOOL_RUNNER
    set --
    # shellcheck disable=SC1091
    source "$ROOT/bin/lucairn" >/dev/null 2>&1
    set +e
    check_tool_runner "$dir/customer.env" "$dir/docker-compose.customer.yml"
  ) > "$TMP/out" 2>&1
}
expect_pass() { run_check "$2" || { cat "$TMP/out" >&2; die "$1: expected the tool runner checks to pass"; }; }
expect_fail() { # LABEL DIR NEEDLE
  if run_check "$2"; then cat "$TMP/out" >&2; die "$1: expected the tool runner checks to FAIL"; fi
  grep -Fq -- "$3" "$TMP/out" || { cat "$TMP/out" >&2; die "$1: failure output lacks: $3"; }
  if grep -Fq -- "$SECRET_CANARY" "$TMP/out"; then die "$1: output echoes a secret value"; fi
}

# ---------------------------------------------------------------------------
# 1. Doctor (compose env): opted out => skipped, never "ok"
# ---------------------------------------------------------------------------
D="$(make_fixture optout)"
set_env "$D/customer.env" LUCAIRN_TOOL_RUNNER_ENABLED false
put_secret "$D" signing_key "$KEY_ZERO"                       # broken on purpose: must not be looked at
set_env "$D/customer.env" LUCAIRN_TOOL_RUNNER_INSTANCE_CLASS ""
expect_pass "opted out" "$D"
grep -Fq 'tool runner: skipped (not opted in' "$TMP/out" || die "opted out: no 'skipped' line"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" = "1" ] || { cat "$TMP/out" >&2; die "opted out: more than the one 'skipped' line"; }
if grep -Eq ': ok|pass' "$TMP/out"; then die "opted out: says ok/pass although nothing was checked"; fi
ok "doctor: opted out prints 'skipped' and checks nothing"

# ---------------------------------------------------------------------------
# 2. Doctor (compose env): opted in, good configuration
# ---------------------------------------------------------------------------
D="$(make_fixture good)"
expect_pass "good config" "$D"
for line in 'tool runner: opted in (Preview)' 'tool runner instance class: ok (dev)' 'tool runner policy: ok (digest matches)' \
  'tool runner signing key: ok (present, Ed25519, not a development default)' 'tool runner write tools: off (no approver secret)' \
  'tool runner environment: ok'; do
  grep -Fq -- "$line" "$TMP/out" || { cat "$TMP/out" >&2; die "good config: missing line: $line"; }
done
if grep -Fq -- "$KEY_REAL" "$TMP/out"; then die "good config: output echoes the signing key"; fi
ok "doctor: opted in with a good configuration passes"

# Opt-in channels 2 and 3.
D="$(make_fixture channels)"
set_env "$D/customer.env" LUCAIRN_TOOL_RUNNER_ENABLED false
set_env "$D/customer.env" COMPOSE_PROFILES "ollama,tool-runner"
expect_pass "COMPOSE_PROFILES channel" "$D"
grep -Fq 'tool runner: opted in' "$TMP/out" || die "COMPOSE_PROFILES=…,tool-runner did not opt in"
set_env "$D/customer.env" COMPOSE_PROFILES "ollama"
( set +e; set --; source "$ROOT/bin/lucairn" >/dev/null 2>&1; set +e; DOCTOR_INCLUDE_TOOL_RUNNER=1 check_tool_runner "$D/customer.env" "$D/docker-compose.customer.yml" ) > "$TMP/out" 2>&1 \
  || die "DOCTOR_INCLUDE_TOOL_RUNNER channel failed"
grep -Fq 'tool runner: opted in' "$TMP/out" || die "DOCTOR_INCLUDE_TOOL_RUNNER=1 did not opt in"
ok "doctor: all three opt-in channels work"

# ---------------------------------------------------------------------------
# 3. Doctor (compose env): signing key
# ---------------------------------------------------------------------------
for pair in "zero:$KEY_ZERO" "same-byte:$KEY_SAME" "counting-up:$KEY_SEQ" "counting-down:$KEY_DOWN" "rfc8032:$KEY_RFC"; do
  D="$(make_fixture "key-${pair%%:*}")"
  put_secret "$D" signing_key "${pair#*:}"
  expect_fail "dev-default key (${pair%%:*})" "$D" 'tool runner signing key: failed (a development default'
done
ok "doctor: a development-default signing key fails (5 shapes)"
D="$(make_fixture key-garbage)"; put_secret "$D" signing_key 'CHANGE-ME'
expect_fail "placeholder key" "$D" 'tool runner signing key: failed (not'
D="$(make_fixture key-wrongtype)"; put_secret "$D" signing_key "$(hex_to_b64 "$(repeat_byte 07)$(repeat_byte 07)")"
expect_fail "non-Ed25519 key" "$D" 'not an Ed25519 private key'
D="$(make_fixture key-missing)"; rm -f "$D/tool-runner/secrets/signing_key"
expect_fail "missing key" "$D" 'tool runner secret signing_key: failed (missing'
D="$(make_fixture key-empty)"; put_secret "$D" signing_key ''
expect_fail "empty key" "$D" 'tool runner secret signing_key: failed (missing, empty'
ok "doctor: a missing, empty or malformed signing key fails"

# ---------------------------------------------------------------------------
# 4. Doctor (compose env): policy
# ---------------------------------------------------------------------------
D="$(make_fixture policy-mismatch)"
printf '%s\n' '{"schema":"lucairn-tool-policy/1","connector":"servicenow","presets":{"incident":{"level":"open"}}}' > "$D/tool-runner/policy.json"
expect_fail "policy digest mismatch" "$D" 'tool runner policy: failed (digest mismatch'
ok "doctor: a policy that is not the approved digest fails"
D="$(make_fixture policy-missing)"; rm -f "$D/tool-runner/policy.json"
expect_fail "policy missing" "$D" 'tool runner policy: failed (no policy file'
D="$(make_fixture policy-nodigest)"; set_env "$D/customer.env" LUCAIRN_TOOL_RUNNER_POLICY_SHA256 ""
expect_fail "digest unset" "$D" 'LUCAIRN_TOOL_RUNNER_POLICY_SHA256 is not set'
D="$(make_fixture policy-otherdoc)"; printf '%s\n' '{"hello":"world"}' > "$D/tool-runner/policy.json"
set_env "$D/customer.env" LUCAIRN_TOOL_RUNNER_POLICY_SHA256 "$(sha_of "$D/tool-runner/policy.json")"
expect_fail "not a policy document" "$D" 'is not a lucairn-tool-policy/1 document'
ok "doctor: a missing policy, an unset digest and a non-policy file fail"

# ---------------------------------------------------------------------------
# 5. Doctor (compose env): instance class, instance, principal
# ---------------------------------------------------------------------------
D="$(make_fixture class-unset)"; set_env "$D/customer.env" LUCAIRN_TOOL_RUNNER_INSTANCE_CLASS ""
expect_fail "class unset" "$D" 'tool runner instance class: failed (LUCAIRN_TOOL_RUNNER_INSTANCE_CLASS is not set'
D="$(make_fixture class-bad)"; set_env "$D/customer.env" LUCAIRN_TOOL_RUNNER_INSTANCE_CLASS production
expect_fail "class invalid" "$D" 'must be dev, test or prod'
D="$(make_fixture class-prod)"; set_env "$D/customer.env" LUCAIRN_TOOL_RUNNER_INSTANCE_CLASS prod
put_secret "$D" approver_secret "$(repeat_byte Ab)"
expect_pass "class prod" "$D"
grep -Fq 'prod — read-only' "$TMP/out" || die "prod: not reported read-only"
grep -Fq 'tool runner write tools: off (an approver secret is present, but the instance class is prod' "$TMP/out" || die "prod: write tools not reported off"
D="$(make_fixture instance-bad)"; set_env "$D/customer.env" LUCAIRN_TOOL_RUNNER_INSTANCE_URL http://example-dev.service-now.com
expect_fail "instance http" "$D" 'tool runner instance: failed'
D="$(make_fixture principal-unset)"; set_env "$D/customer.env" LUCAIRN_TOOL_RUNNER_PRINCIPAL ""
expect_fail "principal unset" "$D" 'tool runner principal: failed'
ok "doctor: instance class must be set (dev|test|prod); prod is read-only"

# ---------------------------------------------------------------------------
# 6. Doctor (compose env): no ServiceNow credential in any environment
# ---------------------------------------------------------------------------
for name in SN_PASSWORD SNOW_USER SERVICENOW_TOKEN sn_instance LUCAIRN_TOOL_RUNNER_GATEWAY_KEY LUCAIRN_TOOL_RUNNER_SERVICENOW_PASSWORD; do
  D="$(make_fixture "env-$name")"
  set_env "$D/customer.env" "$name" "$SECRET_CANARY"
  expect_fail "env file carries $name" "$D" "tool runner environment: failed ($name set in"
done
D="$(make_fixture env-commented)"; printf '%s\n' "#SN_PASSWORD=$SECRET_CANARY" >> "$D/customer.env"
expect_pass "commented-out SN_ line" "$D"
D="$(make_fixture compose-env)"
awk '{ print } /^  sandbox-b:$/ && !done { getline; print; print "    environment:"; print "      SN_PASSWORD: \"${SN_PASSWORD:-}\""; done=1 }' \
  "$D/docker-compose.self-hosted.yml" > "$D/next.yml" && mv "$D/next.yml" "$D/docker-compose.self-hosted.yml"
grep -q 'SN_PASSWORD' "$D/docker-compose.self-hosted.yml" || die "compose fixture: SN_PASSWORD was not planted"
expect_fail "model-facing service carries SN_PASSWORD" "$D" 'tool runner environment: failed (SN_PASSWORD appears in'
ok "doctor: a ServiceNow or Lucairn-key variable in the env file or a compose file fails, names only"

# ---------------------------------------------------------------------------
# 7. Doctor (compose env): secret files
# ---------------------------------------------------------------------------
D="$(make_fixture world-readable)"; chmod 0444 "$D/tool-runner/secrets/servicenow_password"
expect_fail "world-readable password" "$D" 'is readable by every user of this host'
D="$(make_fixture optional-missing)"; rm -f "$D/tool-runner/secrets/approver_secret"
expect_fail "optional secret file missing" "$D" 'tool runner secret approver_secret: failed (missing'
D="$(make_fixture approver-bad)"; put_secret "$D" approver_secret 'too-short'
expect_fail "malformed approver secret" "$D" 'tool runner approver secret: failed'
D="$(make_fixture approver-good)"; put_secret "$D" approver_secret "$(repeat_byte Ab)"
expect_pass "approver secret present" "$D"
grep -Fq 'tool runner write tools: on (approver secret present; every write waits for a human approval)' "$TMP/out" || die "write tools on: line missing"
D="$(make_fixture pwd-missing)"; rm -f "$D/tool-runner/secrets/servicenow_password"
expect_fail "password missing" "$D" 'tool runner secret servicenow_password: failed'
ok "doctor: secret files are checked for presence and mode; approver secret switches write tools"

# ---------------------------------------------------------------------------
# 8. Full `doctor --offline` (SC-6): passes with the runner enabled, fails on
#    a development-default signing key, says "skipped" when opted out.
# ---------------------------------------------------------------------------
STUB="$TMP/stub-bin"; mkdir "$STUB"
cat > "$STUB/docker" <<'SH'
#!/bin/bash
if [ "${1:-}" = compose ]; then case " $* " in *' version '*|*' config '*|*' ps '*) exit 0 ;; esac; fi
exit 1
SH
printf '#!/bin/bash\nprintf 000\n' > "$STUB/curl"
for tool in docker-compose helm kubectl pg_isready crane skopeo; do printf '#!/bin/bash\nexit 1\n' > "$STUB/$tool"; done
chmod 0755 "$STUB"/*
D="$(make_fixture full)"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --model-name fixture-local-model \
  --model-file fixture.gguf --model-path . --output "$D/full.env" --skip-doctor >/dev/null 2>&1
# The real kit compose file (the full doctor needs the kit tree beside it), so
# the policy and the secrets directory are given as absolute paths.
full_doctor() { ( unset COMPOSE_PROFILES DOCTOR_INCLUDE_TOOL_RUNNER; PATH="$STUB:$PATH" bash "$ROOT/bin/lucairn" doctor --env "$D/full.env" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check ) > "$TMP/full.out" 2>&1; }
full_doctor || { cat "$TMP/full.out" >&2; die "full doctor (opted out) failed"; }
grep -Fq 'tool runner: skipped (not opted in' "$TMP/full.out" || die "full doctor (opted out): no 'skipped' line"
grep -Fxq 'doctor: preflight ok (offline)' "$TMP/full.out" || die "full doctor (opted out): no terminal ok"
grep -v '^LUCAIRN_TOOL_RUNNER_ENABLED=' "$D/customer.env" | grep '^LUCAIRN_TOOL_RUNNER_' >> "$D/full.env"
echo 'LUCAIRN_TOOL_RUNNER_ENABLED=true' >> "$D/full.env"
echo "LUCAIRN_TOOL_RUNNER_POLICY_FILE=$D/tool-runner/policy.json" >> "$D/full.env"
echo "LUCAIRN_TOOL_RUNNER_SECRETS_DIR=$D/tool-runner/secrets" >> "$D/full.env"
full_doctor || { cat "$TMP/full.out" >&2; die "SC-6: full doctor with the runner enabled failed"; }
grep -Fq 'tool runner signing key: ok' "$TMP/full.out" || die "SC-6: full doctor did not run the tool runner checks"
grep -Fxq 'doctor: preflight ok (offline)' "$TMP/full.out" || die "SC-6: no terminal ok with the runner enabled"
put_secret "$D" signing_key "$KEY_ZERO"
if full_doctor; then cat "$TMP/full.out" >&2; die "SC-6: full doctor PASSED on a development-default signing key"; fi
grep -Fq 'tool runner signing key: failed (a development default' "$TMP/full.out" || die "SC-6: dev-default failure line missing"
if grep -Fq 'doctor: ok' "$TMP/full.out"; then die "SC-6: doctor printed ok after a tool runner failure"; fi
ok "SC-6: full doctor passes with the runner enabled, fails on a development-default signing key"

# ---------------------------------------------------------------------------
# 9. tool-policy helper
# ---------------------------------------------------------------------------
D="$(make_fixture policy-cli)"
[ "$(bash "$ROOT/bin/lucairn" tool-policy digest "$D/tool-runner/policy.json")" = "$(sha_of "$D/tool-runner/policy.json")" ] || die "tool-policy digest differs from sha256 of the file"
if command -v python3 >/dev/null 2>&1; then
  bash "$ROOT/bin/lucairn" tool-policy validate "$D/tool-runner/policy.json" --structure-only > "$TMP/tp.out" 2>&1 || { cat "$TMP/tp.out" >&2; die "tool-policy validate --structure-only failed on a valid policy"; }
  grep -Fq 'policy structure: ok' "$TMP/tp.out" && grep -Fq 'NOT CHECKED (--structure-only)' "$TMP/tp.out" || die "tool-policy validate: structure-only output wrong"
  printf '%s\n' '{"schema":"lucairn-tool-policy/1","connector":"servicenow","presets":{"incident":{}}}' > "$D/bad.json"
  if bash "$ROOT/bin/lucairn" tool-policy validate "$D/bad.json" --structure-only > "$TMP/tp.out" 2>&1; then die "tool-policy validate accepted a preset without a level"; fi
  grep -Fq 'preset incident needs a level' "$TMP/tp.out" || die "tool-policy validate: reason missing"
  # When the runner image is not on the host the full check is reported as
  # NOT run (exit 2) — never as valid. The stub docker fails every call.
  set +e
  PATH="$STUB:$PATH" bash "$ROOT/bin/lucairn" tool-policy validate "$D/tool-runner/policy.json" > "$TMP/tp.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || { cat "$TMP/tp.out" >&2; die "tool-policy validate without the image: expected exit 2, got $rc"; }
  grep -Fq 'policy presets and levels: NOT CHECKED (runner image' "$TMP/tp.out" || die "tool-policy validate without the image: no NOT CHECKED line"
  ok "tool-policy: digest, structure check, and 'not checked' is never reported as valid"
else
  echo "skipped: tool-policy validate (python3 unavailable)"
fi

# ---------------------------------------------------------------------------
# 10. Compose: service hardening, networks, opt-in
# ---------------------------------------------------------------------------
OVERLAY="$ROOT/docker-compose.self-hosted.yml"
SVC="$(awk '/^  tool-runner:$/ { f=1 } f && /^[a-z]/ { exit } f' "$OVERLAY")"
[ -n "$SVC" ] || die "compose: no tool-runner service in the self-hosted overlay"
for needle in 'profiles: ["tool-runner"]' 'read_only: true' 'no-new-privileges:true' '- ALL' 'user: "${LUCAIRN_TOOL_RUNNER_UID:-10001}:${LUCAIRN_TOOL_RUNNER_GID:-10001}"'; do
  grep -Fq -- "$needle" <<<"$SVC" || die "compose: tool-runner service lacks: $needle"
done
if grep -Eq '^[[:space:]]+(ports|expose):' <<<"$SVC"; then die "compose: tool-runner publishes or exposes a port"; fi
if grep -Fq ':?' <<<"$SVC"; then die "compose: tool-runner uses \${VAR:?} (breaks profile-off installs)"; fi
NETS="$(awk '/^    networks:$/ { f=1; next } f && /^      - / { print $2; next } f { exit }' <<<"$SVC" | sort | tr '\n' ' ')"
[ "$NETS" = "dsa-tool-runner dsa-tool-runner-egress " ] || die "compose: tool-runner networks are '$NETS' (expected only its own two)"
ENV_KEYS="$(awk '/^    environment:$/ { f=1; next } f && /^      [A-Z_]+:/ { sub(/:.*/, "", $1); print $1; next } f && /^      #/ { next } f { exit }' <<<"$SVC")"
if grep -Eiq '(PASSWORD|SECRET|KEY|TOKEN|^SN_|^SNOW_|^SERVICENOW_)' <<<"$ENV_KEYS"; then die "compose: tool-runner environment carries a secret-shaped variable: $ENV_KEYS"; fi
grep -A3 '^  dsa-tool-runner:$' "$OVERLAY" | grep -Fq 'internal: true' || die "compose: dsa-tool-runner is not internal"
# The sanitizer and the identity plane must not share a network with the runner.
if awk '/^  (sanitizer|sandbox-a|id-bridge|audit|veil-witness|sandbox-b|pii-ml):$/ { f=1; next } /^  [a-z0-9-]+:$/ { f=0 } f' "$OVERLAY" "$ROOT/docker-compose.customer.yml" | grep -q 'dsa-tool-runner'; then
  die "compose: a non-gateway service is attached to a tool-runner network"
fi
ok "compose: opt-in profile, read-only root, non-root, no ports, own networks, no secret-shaped env"

if docker compose version >/dev/null 2>&1; then
  D="$(make_fixture compose-config)"
  "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --model-name fixture-local-model \
    --model-file fixture.gguf --model-path . --output "$D/c.env" --skip-doctor >/dev/null 2>&1
  cc() { ( unset COMPOSE_PROFILES; docker compose -f "$D/docker-compose.customer.yml" -f "$D/docker-compose.self-hosted.yml" --env-file "$D/c.env" "$@" config ); }
  rm -rf "$D/tool-runner"      # profile off must not need any tool runner file or variable
  cc > "$TMP/cc-off.yml" 2> "$TMP/cc.err" || { cat "$TMP/cc.err" >&2; die "compose config (profile off) failed"; }
  if grep -Eq '^  tool-runner:$|tool_runner_' "$TMP/cc-off.yml"; then die "compose config (profile off) renders the tool-runner service or its secrets"; fi
  cc --profile tool-runner > "$TMP/cc-on.yml" 2> "$TMP/cc.err" || { cat "$TMP/cc.err" >&2; die "compose config (profile on) failed"; }
  grep -q '^  tool-runner:$' "$TMP/cc-on.yml" || die "compose config (profile on) lacks the tool-runner service"
  grep -Fq 'target: /run/secrets/tool_runner_signing_key' "$TMP/cc-on.yml" || die "compose config (profile on): signing key is not a mounted secret"
  ok "compose config: renders with the profile off (no tool runner files needed) and on"
else
  echo "skipped: compose config render (docker compose unavailable)"
fi

# ---------------------------------------------------------------------------
# 11. Helm sub-chart
# ---------------------------------------------------------------------------
if command -v helm >/dev/null 2>&1; then
  CHART="$ROOT/charts/lucairn"
  printf '%s\n' "$POLICY_JSON" > "$TMP/policy.json"
  PSHA="$(sha_of "$TMP/policy.json")"
  BASE=(lucairn "$CHART" "${HELM_TEST_SECRET_ARGS[@]}" --set global.skipPullSecretGuard=true --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}")
  ON=(--set toolRunner.enabled=true --set tool-runner.instanceUrl=https://example-dev.service-now.com --set tool-runner.instanceClass=dev
      --set-string tool-runner.principal=platform-team@example.test --set-file "tool-runner.policy.json=$TMP/policy.json"
      --set-string "tool-runner.policy.sha256=$PSHA" --set-string tool-runner.secrets.values.servicenowUsername=svc.lucairn.runner
      --set-string "tool-runner.secrets.values.servicenowPassword=$SECRET_CANARY" --set-string "tool-runner.secrets.values.signingKey=$KEY_REAL"
      --set "tool-runner.egress.servicenow.cidrs={203.0.113.0/24}")
  helm template "${BASE[@]}" > "$TMP/h-off.yaml" || die "helm template (tool runner off) failed"
  if grep -q 'tool-runner' "$TMP/h-off.yaml"; then die "helm (off): tool-runner resources rendered by default"; fi
  helm template "${BASE[@]}" "${ON[@]}" > "$TMP/h-on.yaml" || die "helm template (tool runner on) failed"
  for f in namespace serviceaccount configmap secret networkpolicy pvc deployment; do
    grep -Fq "# Source: lucairn/charts/tool-runner/templates/$f.yaml" "$TMP/h-on.yaml" || die "helm (on): $f.yaml not rendered"
  done
  TR="$(awk '/^# Source: lucairn\/charts\/tool-runner\//{f=1} /^# Source: /&&!/tool-runner\//{f=0} f' "$TMP/h-on.yaml")"
  DEPLOY="$(awk '/^# Source: lucairn\/charts\/tool-runner\/templates\/deployment.yaml/{f=1; next} /^# Source: /{f=0} f' "$TMP/h-on.yaml")"
  if grep -Fq -- "$SECRET_CANARY" <<<"$DEPLOY" || grep -Fq -- "$KEY_REAL" <<<"$DEPLOY"; then die "helm (on): a secret value is in the Deployment"; fi
  if grep -Eq 'envFrom|secretKeyRef' <<<"$DEPLOY"; then die "helm (on): the Deployment takes a secret through the environment"; fi
  for needle in 'readOnlyRootFilesystem: true' 'runAsNonRoot: true' 'allowPrivilegeEscalation: false' 'automountServiceAccountToken: false' 'mountPath: /run/secrets'; do
    grep -Fq -- "$needle" <<<"$DEPLOY" || die "helm (on): Deployment lacks: $needle"
  done
  if grep -Eq 'containerPort|hostPort' <<<"$DEPLOY"; then die "helm (on): the Deployment opens a container port"; fi
  if grep -Eq '^kind: (Service|Ingress)$' <<<"$TR"; then die "helm (on): a Service or Ingress exposes the tool runner"; fi
  grep -Fq 'name: default-deny-all' <<<"$TR" || die "helm (on): no default-deny policy in the tool runner namespace"
  grep -Fq 'cidr: "203.0.113.0/24"' <<<"$TR" || die "helm (on): ServiceNow egress range missing"
  grep -Fq 'app.kubernetes.io/name: gateway' <<<"$TR" || die "helm (on): gateway egress rule missing"
  if grep -Eq 'dsa.io/namespace: (identity|bridge|ai|audit|witness)' <<<"$TR"; then die "helm (on): egress reaches a plane other than the gateway"; fi
  if grep -Fq '0.0.0.0/0' <<<"$TR"; then die "helm (on): open egress rendered without allowAnyHttps"; fi
  [ "$(awk '/policy.json:/ { gsub(/"/, "", $2); print $2 }' <<<"$TR" | base64 -d 2>/dev/null | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}')" = "$PSHA" ] \
    || die "helm (on): the mounted policy bytes do not have the approved digest"
  ok "helm: off by default; on renders namespace, default-deny, two egress rules, file-mounted secrets, no Service"

  helm_fails() { # LABEL NEEDLE ARGS...
    local label="$1" needle="$2"; shift 2
    if helm template "${BASE[@]}" "${ON[@]}" "$@" > /dev/null 2> "$TMP/h.err"; then die "helm: $label rendered, expected a failure"; fi
    grep -Fq -- "$needle" "$TMP/h.err" || { cat "$TMP/h.err" >&2; die "helm: $label failed without: $needle"; }
    if grep -Fq -- "$SECRET_CANARY" "$TMP/h.err"; then die "helm: $label error echoes a secret"; fi
  }
  for pair in "zero:$KEY_ZERO" "same-byte:$KEY_SAME" "counting-up:$KEY_SEQ" "counting-down:$KEY_DOWN" "rfc8032:$KEY_RFC"; do
    helm_fails "dev-default key (${pair%%:*})" 'is a development default' --set-string "tool-runner.secrets.values.signingKey=${pair#*:}"
  done
  helm_fails "placeholder key" 'still a shipped placeholder' --set-string tool-runner.secrets.values.signingKey=CHANGE-ME
  helm_fails "empty key" 'signingKey is empty' --set-string tool-runner.secrets.values.signingKey=
  helm_fails "policy digest mismatch" 'policy digest mismatch' --set-string "tool-runner.policy.sha256=$(repeat_byte bb)"
  helm_fails "instance class unset" 'tool-runner.instanceClass must be set' --set tool-runner.instanceClass=
  helm_fails "no ServiceNow ranges" 'egress.servicenow.cidrs is empty' --set tool-runner.egress.servicenow.cidrs=null
  helm_fails "SN_ variable" 'extraEnv.SN_PASSWORD is refused' --set-string tool-runner.extraEnv.SN_PASSWORD=x
  helm_fails "empty password" 'servicenowPassword is empty' --set-string tool-runner.secrets.values.servicenowPassword=
  ok "helm: render fails on a dev-default key, a digest mismatch, no instance class, no egress ranges, an SN_ variable"

  helm template "${BASE[@]}" "${ON[@]}" --set tool-runner.secrets.backend=vault --set-string tool-runner.secrets.values.signingKey= \
    --set-string tool-runner.secrets.values.servicenowPassword= > "$TMP/h-vault.yaml" || die "helm (vault backend) failed"
  grep -Fq '# Source: lucairn/charts/tool-runner/templates/externalsecret.yaml' "$TMP/h-vault.yaml" || die "helm (vault): no ExternalSecret"
  if grep -Fq '# Source: lucairn/charts/tool-runner/templates/secret.yaml' "$TMP/h-vault.yaml"; then die "helm (vault): native Secret rendered too"; fi
  # (rendered to a file: `helm | grep -q` would SIGPIPE under pipefail)
  helm template "${BASE[@]}" "${ON[@]}" --set tool-runner.egress.servicenow.cidrs=null --set tool-runner.egress.servicenow.allowAnyHttps=true > "$TMP/h-any.yaml" \
    || die "helm (allowAnyHttps) failed"
  grep -Fq '10.0.0.0/8' "$TMP/h-any.yaml" || die "helm (allowAnyHttps): private ranges are not excluded"
  helm lint "$CHART" "${HELM_TEST_SECRET_ARGS[@]}" --set global.skipPullSecretGuard=true --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" "${ON[@]}" > "$TMP/lint.out" 2>&1 \
    || { cat "$TMP/lint.out" >&2; die "helm lint (tool runner on) failed"; }
  ok "helm: ExternalSecret backend, explicit open-egress opt-out, lint with the tool runner on"
else
  echo "skipped: Helm sub-chart renders (helm unavailable)"
fi

# Doctor, Helm values path.
if command -v ruby >/dev/null 2>&1; then
  helm_doctor() {
    local files=("$@")
    ( set +e; set --; source "$ROOT/bin/lucairn" >/dev/null 2>&1; set +e; check_tool_runner_helm "$ROOT/charts/lucairn" "${files[@]}" ) > "$TMP/hd.out" 2>&1
  }
  printf 'global: {}\n' > "$TMP/v-off.yaml"
  helm_doctor "$TMP/v-off.yaml" || die "doctor (Helm): opted out failed"
  grep -Fxq 'tool runner (Helm): skipped (not opted in — toolRunner.enabled is not true)' "$TMP/hd.out" || { cat "$TMP/hd.out" >&2; die "doctor (Helm): no 'skipped' line"; }
  [ "$(wc -l < "$TMP/hd.out" | tr -d ' ')" = "1" ] || die "doctor (Helm): opted out printed more than 'skipped'"
  write_values() { # FILE KEY CLASS SHA
    cat > "$1" <<YAML
toolRunner:
  enabled: true
tool-runner:
  instanceUrl: https://example-dev.service-now.com
  instanceClass: "$3"
  policy:
    json: |
      $POLICY_JSON
    sha256: "$4"
  secrets:
    values:
      signingKey: "$2"
YAML
  }
  VSHA="$(printf '%s\n' "$POLICY_JSON" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}')"
  write_values "$TMP/v-on.yaml" "$KEY_REAL" dev "$VSHA"
  helm_doctor "$TMP/v-on.yaml" || { cat "$TMP/hd.out" >&2; die "doctor (Helm): good values failed"; }
  grep -Fq 'tool runner signing key (Helm): ok' "$TMP/hd.out" && grep -Fq 'tool runner policy (Helm): ok (digest matches)' "$TMP/hd.out" || { cat "$TMP/hd.out" >&2; die "doctor (Helm): ok lines missing"; }
  write_values "$TMP/v-dev.yaml" "$KEY_SEQ" dev "$VSHA"
  if helm_doctor "$TMP/v-dev.yaml"; then die "doctor (Helm): dev-default key passed"; fi
  grep -Fq 'tool runner signing key (Helm): failed (a development default' "$TMP/hd.out" || die "doctor (Helm): dev-default line missing"
  write_values "$TMP/v-digest.yaml" "$KEY_REAL" dev "$(repeat_byte cc)"
  if helm_doctor "$TMP/v-digest.yaml"; then die "doctor (Helm): digest mismatch passed"; fi
  grep -Fq 'tool runner policy (Helm): failed (digest mismatch' "$TMP/hd.out" || die "doctor (Helm): digest mismatch line missing"
  write_values "$TMP/v-class.yaml" "$KEY_REAL" "" "$VSHA"
  if helm_doctor "$TMP/v-class.yaml"; then die "doctor (Helm): unset instance class passed"; fi
  printf 'sandbox-b:\n  extraEnv:\n    SN_PASSWORD: x\n' > "$TMP/v-sn.yaml"
  if helm_doctor "$TMP/v-on.yaml" "$TMP/v-sn.yaml"; then die "doctor (Helm): SN_PASSWORD in a model-facing service's values passed"; fi
  grep -Fq 'sandbox-b.extraEnv.SN_PASSWORD' "$TMP/hd.out" || die "doctor (Helm): SN_PASSWORD path not named"
  # Wiring: the values-only doctor run reaches the tool runner check. (Its exit
  # code is not asserted for the opted-out case: with the stub helm the
  # unrelated mTLS render gate fails closed, by design.)
  ( PATH="$STUB:$PATH" bash "$ROOT/bin/lucairn" doctor --values "$TMP/v-off.yaml" || true ) > "$TMP/hd.out" 2>&1
  grep -Fq 'tool runner (Helm): skipped' "$TMP/hd.out" || { cat "$TMP/hd.out" >&2; die "doctor --values: tool runner line missing"; }
  if ( PATH="$STUB:$PATH" bash "$ROOT/bin/lucairn" doctor --values "$TMP/v-dev.yaml" ) > "$TMP/hd.out" 2>&1; then die "doctor --values passed on a dev-default signing key"; fi
  grep -Fq 'tool runner signing key (Helm): failed (a development default' "$TMP/hd.out" || { cat "$TMP/hd.out" >&2; die "doctor --values: dev-default line missing"; }
  ok "doctor (Helm values): skipped when off; fails on a dev-default key, a digest mismatch, no class, an SN_ variable"
else
  echo "skipped: doctor Helm-values checks (ruby unavailable)"
fi

# ---------------------------------------------------------------------------
# 12. Image: entrypoint unit tests, Dockerfile, manifest slot
# ---------------------------------------------------------------------------
if command -v node >/dev/null 2>&1 && node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)'; then
  node --test "$ROOT"/apps/tool-runner/test/*.test.mjs > "$TMP/node.out" 2>&1 || { cat "$TMP/node.out" >&2; die "entrypoint unit tests failed"; }
  ok "image entrypoint: $(grep -E '^(ℹ|#) pass ' "$TMP/node.out" | awk '{print $3}') unit tests pass"
else
  echo "skipped: entrypoint unit tests (node 20+ unavailable)"
fi
DF="$ROOT/apps/tool-runner/Dockerfile"
for needle in 'ARG RUNNER_SHA256' 'sha256sum -c' 'USER 10001:10001' 'npm ci --omit=dev --ignore-scripts' 'ENTRYPOINT ["node", "/opt/lucairn-kit/entrypoint.mjs"]'; do
  grep -Fq -- "$needle" "$DF" || die "Dockerfile lacks: $needle"
done
[ "$(grep -c '^FROM ' "$DF")" -ge 2 ] || die "Dockerfile is not multi-stage"
if grep -Eq '^(EXPOSE|ENV .*(PASSWORD|SECRET|TOKEN))' "$DF"; then die "Dockerfile exposes a port or bakes a secret-shaped ENV"; fi
( set +e; set --; source "$ROOT/bin/lucairn" >/dev/null 2>&1; parse_image_digests "$ROOT/image-manifest.yaml" ) > "$TMP/digests.out"
grep -Fxq "$(printf 'ghcr.io/declade/lucairn-tool-runner:0.1.0\tPENDING')" "$TMP/digests.out" || die "image-manifest: lucairn-tool-runner is not a pending (unreleased) slot"
if grep -q 'INVALID' "$TMP/digests.out"; then die "image-manifest: an entry parses as INVALID"; fi
grep -A4 '^  lucairn-tool-runner:$' "$ROOT/image-manifest.yaml" | grep -q 'image_tag: "0.1.0"' || die "image-manifest: optional_services entry missing"
ok "image: Dockerfile shape, and the manifest lists the image as a pending (unreleased) slot"

# ---------------------------------------------------------------------------
# 13. Customer page: required statements, banned wording
# ---------------------------------------------------------------------------
DOC="$ROOT/docs/TOOL_RUNNER.md"
[ -f "$DOC" ] || die "docs/TOOL_RUNNER.md is missing"
for needle in 'Preview' 'never handed to the model' 'Every write needs a human approval' 'signed receipt' 'scrubbed, not guaranteed' \
  'only covers what goes through Lucairn tools' 'dedicated service account' 'security_admin' 'needs_security_admin' 'Production writes are off'; do
  grep -Fq -- "$needle" "$DOC" || die "docs: required statement missing: $needle"
done
for f in "$DOC" "$ROOT/apps/tool-runner/Dockerfile" "$ROOT/apps/tool-runner/entrypoint.mjs" "$ROOT"/charts/lucairn/charts/tool-runner/values.yaml \
  "$ROOT"/charts/lucairn/charts/tool-runner/templates/*; do
  if grep -EinH 'certifi(ed|cation)|SOC ?2|\bISO\b|HIPAA|\bE2E\b|end-to-end encr|encrypted at rest|uptime|\bMFA\b|Pro\+|Solo (Free|Pro)|\bT-[0-9]{3,}\b' "$f"; then
    die "banned wording or an internal reference in $f"
  fi
done
ok "docs: the promise, the service-account requirements and the wording rules hold"

echo "tool runner kit tests: $PASS groups passed"
