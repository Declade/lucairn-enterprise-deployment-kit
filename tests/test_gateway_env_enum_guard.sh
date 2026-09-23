#!/usr/bin/env bash
set -euo pipefail

# T-871 — gateway evidence-admission enums + "$"-refusal on literal env values.
#
# THE DEFECT: dual-sandbox-architecture #622 (main `c3d2aa0d`) made the gateway
# REFUSE TO BOOT on any SET GATEWAY_EVIDENCE_ADMISSION_POSTURE other than
# exactly "enforce"/"log" and on any SET GATEWAY_EVIDENCE_BOOT_MODE other than
# exactly ""/"strict"/"permissive". The kit chart rendered both unchecked
# (`{{ .Values.evidenceGap.posture | quote }}`), so `posture: ENFORCE`,
# `" enforce "`, `""` or `null` (which `quote` rendered as `""`) rendered green
# and would CrashLoop after the next gateway image re-pin. Separately,
# Kubernetes expands `$(NAME)` and reduces `$$` in every container env value
# and arg at Pod creation, so a Helm value containing "$" reaches the process
# as a different string from the rendered one (DSA T-846: "$(DSA_ENV)" became
# "production").
#
# ─── WHAT THIS PROVES ────────────────────────────────────────────────────────
#   1. posture log / enforce render exactly that; posture null renders NO env
#      line (UNSET = LOG); bootMode strict/permissive render, ""/null do not.
#   2. Every off-enum spelling (case, whitespace, empty, other words, "$",
#      non-strings) FAILS `helm template` and is surfaced by `helm lint` (which
#      in Helm 4 reports a template `fail` as INFO and exits 0), and the error names
#      the key and the allowed enum (the refusal reason is grepped, not only
#      the exit status).
#   3. A "$" in the other literal env values / args of the gateway and
#      sandbox-a (sanitizer) sub-charts fails the render — through the
#      umbrella AND through a standalone sandbox-a render.
#   4. No refusal message echoes the offending value (a Redis URL can carry a
#      password).
#
# ─── WHAT THIS DOES NOT PROVE ────────────────────────────────────────────────
#   * That the gateway image refuses to boot — that is DSA #622's own tests.
#     The kit still pins dsa-gateway 0.5.4; this suite makes the chart safe for
#     the re-pin, it does not perform it.
#   * Byte-identity of the shipped values-file renders was measured once when
#     this landed (PR body); it is not re-asserted here.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
CHILD_CHART="$CHART/charts/sandbox-a"

# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

if ! command -v helm >/dev/null 2>&1; then
  echo "T-871 gateway env enum guard: ERROR — Helm CLI is required." >&2
  exit 2
fi

TMPDIR_T871="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T871"' EXIT

PASS=0
fail() { echo "T-871 gateway env enum guard: FAIL — $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); }

common_args=(
  "${HELM_TEST_SECRET_ARGS[@]}"
  --set global.skipPullSecretGuard=true
  --set-string "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}"
)

render() { helm template lucairn "$CHART" "${common_args[@]}" "$@"; }
lint() { helm lint "$CHART" "${common_args[@]}" "$@"; }

# gateway_env <manifest> <NAME> → prints the gateway container's value for NAME,
# or the literal token __ABSENT__ when the container does not declare it.
gateway_env() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
path, name = sys.argv[1], sys.argv[2]
found = None
for doc in yaml.safe_load_all(open(path)):
    if not doc or doc.get("kind") != "Deployment" or doc["metadata"]["name"] != "gateway":
        continue
    for c in doc["spec"]["template"]["spec"]["containers"]:
        if c["name"] != "gateway":
            continue
        for e in c.get("env") or []:
            if e["name"] == name:
                found = e.get("value")
                print("__EMPTY__" if found in (None, "") else found)
                sys.exit(0)
print("__ABSENT__")
PY
}

# expect_render <label> <NAME> <expected-or-__ABSENT__> <helm args...>
expect_render() {
  local label="$1" name="$2" want="$3"; shift 3
  local out="$TMPDIR_T871/$label.yaml"
  render "$@" >"$out" 2>"$out.err" || fail "$label: render failed unexpectedly: $(head -c 400 "$out.err")"
  lint "$@" >"$out.lint" 2>&1 || fail "$label: helm lint failed unexpectedly"
  if grep -qF "funcMap fail" "$out.lint"; then fail "$label: helm lint reported a template refusal"; fi
  local got; got="$(gateway_env "$out" "$name")"
  [ "$got" = "$want" ] || fail "$label: $name rendered as '$got', expected '$want'"
  ok
}

# expect_refusal <label> <required-substring>... -- <helm args...>
# Both helm template AND helm lint must fail, and the template error must carry
# every required substring.
expect_refusal() {
  local label="$1"; shift
  local needles=()
  while [ "$1" != "--" ]; do needles+=("$1"); shift; done
  shift
  local err="$TMPDIR_T871/$label.err"
  if render "$@" >/dev/null 2>"$err"; then
    fail "$label: render SUCCEEDED; expected a refusal"
  fi
  local n
  for n in "${needles[@]}"; do
    grep -qF -- "$n" "$err" || fail "$label: refusal does not contain '$n': $(head -c 600 "$err")"
  done
  # ⚑ MEASURED (Helm v4.1.3): `helm lint` — even with --strict — reports a
  # template `fail` as `level=INFO msg="funcMap fail"` and still exits 0, so
  # its exit status cannot be the gate (`helm template` / `helm install` do
  # fail). Assert lint SURFACES the same refusal text instead.
  lint "$@" >"$err.lint" 2>&1 || true
  grep -qF "funcMap fail" "$err.lint" && grep -qF -- "${needles[0]}" "$err.lint" \
    || fail "$label: helm lint did not surface the refusal: $(head -c 400 "$err.lint")"
  ok
}

POSTURE_KEY="gateway.evidenceGap.posture"
BOOT_KEY="gateway.evidenceGap.bootMode"
POSTURE_ENUM='["enforce","log"]'
BOOT_ENUM='["","strict","permissive"]'

# ── 1. accepted shapes ──────────────────────────────────────────────────────
expect_render posture-default GATEWAY_EVIDENCE_ADMISSION_POSTURE log
expect_render posture-log GATEWAY_EVIDENCE_ADMISSION_POSTURE log --set-string "$POSTURE_KEY=log"
expect_render posture-enforce GATEWAY_EVIDENCE_ADMISSION_POSTURE enforce --set-string "$POSTURE_KEY=enforce"
expect_render posture-null GATEWAY_EVIDENCE_ADMISSION_POSTURE __ABSENT__ --set "$POSTURE_KEY=null"
expect_render bootmode-default GATEWAY_EVIDENCE_BOOT_MODE __ABSENT__
expect_render bootmode-empty GATEWAY_EVIDENCE_BOOT_MODE __ABSENT__ --set-string "$BOOT_KEY="
expect_render bootmode-null GATEWAY_EVIDENCE_BOOT_MODE __ABSENT__ --set "$BOOT_KEY=null"
expect_render bootmode-strict GATEWAY_EVIDENCE_BOOT_MODE strict --set-string "$BOOT_KEY=strict"
expect_render bootmode-permissive GATEWAY_EVIDENCE_BOOT_MODE permissive --set-string "$BOOT_KEY=permissive"

# ── 2. refused posture / bootMode spellings ────────────────────────────────
PADDED="$TMPDIR_T871/padded.yaml"
printf 'gateway:\n  evidenceGap:\n    posture: " enforce "\n' >"$PADDED"
PADDED_BOOT="$TMPDIR_T871/padded-boot.yaml"
printf 'gateway:\n  evidenceGap:\n    bootMode: "strict "\n' >"$PADDED_BOOT"

expect_refusal posture-upper "$POSTURE_KEY" "$POSTURE_ENUM" "only after lowercasing" "CrashLoopBackOff" -- --set-string "$POSTURE_KEY=ENFORCE"
expect_refusal posture-title "$POSTURE_KEY" "$POSTURE_ENUM" "only after lowercasing" -- --set-string "$POSTURE_KEY=Enforce"
expect_refusal posture-padded "$POSTURE_KEY" "$POSTURE_ENUM" "leading or trailing whitespace" -- -f "$PADDED"
expect_refusal posture-empty "$POSTURE_KEY" "$POSTURE_ENUM" "an empty string" -- --set-string "$POSTURE_KEY="
expect_refusal posture-word "$POSTURE_KEY" "$POSTURE_ENUM" "a 10-character string" -- --set-string "$POSTURE_KEY=production"
expect_refusal posture-expansion "$POSTURE_KEY" 'contains "$"' 'a `$(NAME)` variable reference' -- --set-string "$POSTURE_KEY=\$(DSA_ENV)"
expect_refusal posture-dollar-dollar "$POSTURE_KEY" 'contains "$"' -- --set-string "$POSTURE_KEY=\$\$log"
expect_refusal posture-nonstring "$POSTURE_KEY" "$POSTURE_ENUM" "a YAML" -- --set "$POSTURE_KEY=true"
expect_refusal bootmode-upper "$BOOT_KEY" "$BOOT_ENUM" "only after lowercasing" -- --set-string "$BOOT_KEY=STRICT"
expect_refusal bootmode-title "$BOOT_KEY" "$BOOT_ENUM" -- --set-string "$BOOT_KEY=Permissive"
expect_refusal bootmode-padded "$BOOT_KEY" "$BOOT_ENUM" "leading or trailing whitespace" -- -f "$PADDED_BOOT"
expect_refusal bootmode-expansion "$BOOT_KEY" 'contains "$"' -- --set-string "$BOOT_KEY=\$(MODE)"
expect_refusal bootmode-nonstring "$BOOT_KEY" "$BOOT_ENUM" "a YAML" -- --set "$BOOT_KEY=false"

# ── 3. "$" in the other literal env values / args (sweep) ──────────────────
for key in \
  gateway.sessionTtl gateway.waitTimeout gateway.streaming.timeoutSeconds \
  gateway.streaming.enabled gateway.enableTestProvider \
  gateway.evidenceGap.mountPath gateway.evidenceGap.fileName; do
  expect_refusal "sweep-$key" "GATEWAY ENV: $key" 'contains "$"' -- --set-string "$key=\$(HOME)"
done
expect_refusal sweep-global-mtls-mount "global.mtls.mountPath" 'contains "$"' -- --set-string "global.mtls.mountPath=/run/\$(X)"
# With sandbox-a disabled the GATEWAY's own check must catch the global mTLS
# names (otherwise sandbox-a's twin could be the only guard that fires).
for key in global.mtls.mountPath global.mtls.caBundleKey global.mtls.certKey global.mtls.keyKey; do
  expect_refusal "sweep-gateway-$key" "GATEWAY ENV: $key" 'contains "$"' -- \
    --set sandbox-a.enabled=false --set-string "$key=\$(X)"
done
for key in \
  sanitizerCache.redisUrl sanitizerCache.ttlSeconds sanitizerStreamState.redisUrl \
  sanitizerStreamState.ttlSeconds sanitizerStreamState.mutationMarkerTtlSeconds \
  sanitizer.gunicornTimeout sanitizer.piiMlClient.endpoint postgresql.user postgresql.database; do
  expect_refusal "sweep-sandbox-a-$key" "sandbox-a: $key" 'contains "$"' -- --set-string "sandbox-a.$key=\$(HOME)"
done

expect_refusal sweep-sandbox-a-ollama-keepalive "sandbox-a: ollamaIdentity.keepAlive" 'contains "$"' -- \
  -f "$CHART/values-test.yaml" --set-string "sandbox-a.ollamaIdentity.keepAlive=\$(X)"

# ── 4. no echo of the offending value ──────────────────────────────────────
SECRETISH='kitT871NotARealPassword'
expect_refusal no-echo-redis "sandbox-a: sanitizerCache.redisUrl" "value withheld" -- \
  --set-string "sandbox-a.sanitizerCache.redisUrl=redis://:${SECRETISH}\$\$x@cache:6379/0"
if grep -qF "$SECRETISH" "$TMPDIR_T871/no-echo-redis.err"; then
  fail "no-echo-redis: the refusal ECHOED the Redis URL password"
fi
expect_refusal no-echo-posture "$POSTURE_KEY" "value withheld" -- --set-string "$POSTURE_KEY=${SECRETISH}"
if grep -qF "$SECRETISH" "$TMPDIR_T871/no-echo-posture.err"; then
  fail "no-echo-posture: the refusal ECHOED the posture value"
fi
ok

# ── 5. standalone sandbox-a render carries its own "$"-refusal twin ─────────
DIRECT="$TMPDIR_T871/direct.yaml"
cat >"$DIRECT" <<YAML
ephemeral: "true"
secrets:
  values:
    postgresPassword: "${TEST_SECRET_VALUE}"
global:
  imageRegistry: ""
  imageTag: "0.5.4"
  imagePullSecrets: []
  postgresqlSslmode: disable
  dsaServiceToken: ""
  dsaEnv: development
  nodeIsolation: false
  mtls:
    enabled: false
YAML
helm template sandbox-a "$CHILD_CHART" -f "$DIRECT" >/dev/null 2>"$TMPDIR_T871/direct-ok.err" \
  || fail "standalone sandbox-a: valid render failed: $(head -c 400 "$TMPDIR_T871/direct-ok.err")"
ok
if helm template sandbox-a "$CHILD_CHART" -f "$DIRECT" \
    --set-string "sanitizerCache.redisUrl=redis://\$(REDIS_HOST):6379/0" >/dev/null 2>"$TMPDIR_T871/direct-bad.err"; then
  fail "standalone sandbox-a: render with a \$(VAR) redisUrl SUCCEEDED"
fi
grep -qF 'sandbox-a: sanitizerCache.redisUrl' "$TMPDIR_T871/direct-bad.err" \
  || fail "standalone sandbox-a: wrong refusal: $(head -c 400 "$TMPDIR_T871/direct-bad.err")"
grep -qF 'a `$(NAME)` variable reference' "$TMPDIR_T871/direct-bad.err" \
  || fail "standalone sandbox-a: refusal does not name the \$(NAME) shape"
ok

echo "T-871 gateway env enum guard: PASS ($PASS assertions)"
