#!/usr/bin/env bash
#
# T-393 / T-385 — L3 posture flags: the kit must not set them on the operator's
# behalf, and must not leave the retired flag set.
#
# WHAT THIS SUITE EXISTS TO STOP (the defect, stated precisely):
#
#   The kit used to render LUCAIRN_L3_REQUIRED UNCONDITIONALLY onto both the
#   sanitizer (sandbox-a) and the veil-witness pod. Two things made it
#   unconditional: the pod templates carried an `else` branch that emitted
#   "false" when global.l3Required was absent, AND charts/lucairn/values.yaml
#   shipped `l3Required: false` so the key was never absent in the first place.
#   Either alone would have been enough.
#
#   The service images that carry the availability/completeness posture split
#   (PRD prd-2026-08-01-l3-availability-vs-certificate-honesty-split.md) treat a
#   SET LUCAIRN_L3_REQUIRED beside an unset replacement posture as an
#   un-migrated deployment and REFUSE TO START — deliberately, so that a
#   deployment which opted into fail-closed cannot be silently relaxed. So the
#   kit's unconditional render turned an image bump into CrashLoopBackOff on
#   100% of installs, on BOTH pods.
#
#   The fix is that the chart states NO posture: each variable renders only when
#   its own key is present, and the image's default applies otherwise.
#
# POSITIVE CONTROLS (each case goes red against the pre-fix tree, or against a
# tree where the guard it describes has been removed — none of these is a
# tautology):
#   - stock-render-emits-nothing: the pre-fix tree renders LUCAIRN_L3_REQUIRED
#     on both pods, so case 1 FAILS there. Re-adding a shipped default to
#     values.yaml turns it red again.
#   - values-ships-no-l3-key: greps the chart's own values.yaml. Independent of
#     the templates, because either surface alone re-creates the defect.
#   - legacy-false-alone-fails: `--set global.l3Required=false` is the EXACT
#     former default. It must be refused at render time. Deleting
#     validators.l3LegacyFlagWithoutPosture turns this red.
#   - legacy-true-alone-fails: same guard, other value.
#   - legacy-with-both-postures-renders: the guard must not be a blanket ban —
#     an operator who states both replacements can keep the retired variable for
#     an older image. If the guard over-fires, this goes red.
#   - airgap-accepts-new-spelling / airgap-still-fires: the air-gap guard's
#     fail-closed test moved from `l3Required` to `l3AvailabilityPosture`.
#     Checking only the old key false-FAILS a migrated install; checking
#     neither drops a security guard. Both directions are pinned.
#   - compose-and-cli-set-no-legacy-default: the Compose + `lucairn-init` half
#     of the same defect. `${VAR:-false}` in a compose file sets the variable on
#     every install exactly as a chart default did.
#   - no-compose-posture-default: the self-hosted overlay must NOT migrate its
#     retired `${LUCAIRN_L3_REQUIRED:-true}` into `${...POSTURE:-reject}`. Both
#     `lucairn-init` and `customer.env.example` have written
#     LUCAIRN_L3_REQUIRED=false for ALL paths since 2026-06, so a defaulted
#     posture would win over that leftover, skip the boot refusal, and
#     fail-close against an unstaged model — 503 on every request.
#   - completeness-posture-reachable-on-compose: this repo has no `env_file:`
#     directive, so a service's `environment:` block is the only channel from
#     customer.env into the container. Without the veil-witness entry, T-385's
#     documented `full` opt-in is dead configuration.
#   - airgap-legacy-is-not-a-bypass (§6): `l3Required` truthy must NOT satisfy
#     the air-gap fail-closed guard. It can only ever be reached alongside a
#     posture that overrides it, so accepting it merely suppresses the guard.
#     Both the boolean and the Go-template-truthy string `"false"` are pinned.
#   - subchart-scoped-global (§6): Helm propagates `global` asymmetrically, so
#     `--set sandbox-a.global.l3Required=true` reaches the pod template without
#     passing the umbrella validator. Each pod template mirrors the guard;
#     deleting either mirror turns these red.
#   - posture-enum (§6): an off-allowlist posture is a boot refusal in both
#     images, so it must be a render error — at BOTH umbrella scope
#     (validators.l3PostureValues) and subchart scope (the mirror in each pod
#     template; the umbrella validator cannot see a subchart-scoped `global`,
#     so an unmirrored enum check is bypassable in exactly the way the legacy
#     check was). Matching no-over-fire cases prove the guards trim+lowercase
#     exactly as the services do, and treat empty/null as absence while
#     refusing whitespace-only.
#
# SCOPE: every render here is of the UMBRELLA chart (charts/lucairn). That is
# deliberate and load-bearing — `global.l3Required` was shipped in the
# umbrella's own values.yaml, which a direct child render cannot see. Assertions
# about files (compose, customer.env.example, bin/lucairn-init, subchart
# values.yaml) are greps and are named as such.
#
# Requires: helm, python3 + PyYAML (both provisioned by .github/workflows/ci.yml).
# No cluster, GPU, Docker, or network.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"
CHART="$ROOT/charts/lucairn"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

FAILS=0
N=0

pass() { N=$((N + 1)); echo "  ok   — $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "  FAIL — $1"; }

check_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    pass "$name"
  else
    fail "$name (want '$want', got '$got')"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "T-393 gate: ERROR — $1 is required" >&2
    exit 2
  }
}

require_command helm
require_command python3
python3 -c 'import yaml' 2>/dev/null || {
  echo "T-393 gate: ERROR — PyYAML is required (CI provisions python3-yaml)" >&2
  exit 2
}

# Render the UMBRELLA chart. The umbrella is the only scope that can show the
# defect: `global.l3Required` was shipped in charts/lucairn/values.yaml, which a
# direct child render cannot see (the scope note in tests/test_l3_model_upgrade_
# gate.sh makes the same point about umbrella-level overrides).
render() {
  helm template lucairn "$CHART" \
    "${HELM_TEST_SECRET_ARGS[@]}" \
    --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
    --set global.skipPullSecretGuard=true \
    "$@"
}

# l3_env <render-file> <workload-name> <container-name>
# Prints "NAME=value" for every LUCAIRN_L3_* env on that container, sorted, one
# per line. Empty output means the container carries none.
l3_env() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
path, workload, container = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
with open(path) as fh:
    for doc in yaml.safe_load_all(fh):
        if not doc or doc.get("kind") not in ("Deployment", "StatefulSet"):
            continue
        if doc.get("metadata", {}).get("name") != workload:
            continue
        for c in doc["spec"]["template"]["spec"].get("containers", []):
            if c.get("name") != container:
                continue
            for e in (c.get("env") or []):
                if e.get("name", "").startswith("LUCAIRN_L3"):
                    out.append("%s=%s" % (e["name"], e.get("value")))
print("\n".join(sorted(out)))
PY
}

sanitizer_l3_env() { l3_env "$1" sandbox-a sanitizer; }
witness_l3_env() { l3_env "$1" veil-witness veil-witness; }

echo "T-393 / T-385 L3 posture flag gate"
echo ""
echo "1. stock render states NO posture (the image defaults apply)"

# Independent of the templates: the chart's own values must not supply the key.
# A shipped `l3Required:` here is set on EVERY install whether or not the
# operator asked for it, which is half of how T-393 happened. Checked BEFORE the
# render, because re-adding it makes the render itself fail (the migration guard
# fires on the chart's own default) and an aborted suite reports nothing.
for f in "$CHART/values.yaml" "$CHART"/values-*.yaml "$CHART"/charts/*/values.yaml; do
  if grep -Eq '^[[:space:]]+l3Required:' "$f"; then
    fail "$(basename "$f") ships no active l3Required key"
  else
    pass "$(basename "$f") ships no active l3Required key"
  fi
done

if render >"$TMPDIR/stock.yaml" 2>"$TMPDIR/stock.err"; then
  check_eq "sanitizer carries no LUCAIRN_L3_* env" "" "$(sanitizer_l3_env "$TMPDIR/stock.yaml")"
  check_eq "veil-witness carries no LUCAIRN_L3_* env" "" "$(witness_l3_env "$TMPDIR/stock.yaml")"
else
  fail "stock render succeeds: $(head -1 "$TMPDIR/stock.err")"
  fail "sanitizer carries no LUCAIRN_L3_* env (render failed)"
  fail "veil-witness carries no LUCAIRN_L3_* env (render failed)"
fi

echo ""
echo "2. each posture renders ONLY on its own service, ONLY when set"

render --set global.l3CompletenessPosture=partial >"$TMPDIR/completeness.yaml"
check_eq "completeness posture lands on the veil-witness" \
  "LUCAIRN_L3_COMPLETENESS_POSTURE=partial" "$(witness_l3_env "$TMPDIR/completeness.yaml")"
check_eq "completeness posture does NOT leak onto the sanitizer" \
  "" "$(sanitizer_l3_env "$TMPDIR/completeness.yaml")"

render --set global.l3CompletenessPosture=full >"$TMPDIR/completeness-full.yaml"
check_eq "the legacy over-claiming posture is still selectable (T-385)" \
  "LUCAIRN_L3_COMPLETENESS_POSTURE=full" "$(witness_l3_env "$TMPDIR/completeness-full.yaml")"

render --set global.l3AvailabilityPosture=reject >"$TMPDIR/availability.yaml"
check_eq "availability posture lands on the sanitizer" \
  "LUCAIRN_L3_AVAILABILITY_POSTURE=reject" "$(sanitizer_l3_env "$TMPDIR/availability.yaml")"
check_eq "availability posture does NOT leak onto the veil-witness" \
  "" "$(witness_l3_env "$TMPDIR/availability.yaml")"

echo ""
echo "3. the retired flag: refused alone, honoured beside both replacements"

# `false` is the EXACT value charts/lucairn/values.yaml used to ship, so this
# case reproduces the pre-fix stock install and must be refused.
for legacy_value in false true; do
  if render --set "global.l3Required=${legacy_value}" >"$TMPDIR/legacy-${legacy_value}.yaml" 2>"$TMPDIR/legacy-${legacy_value}.err"; then
    fail "global.l3Required=${legacy_value} alone is refused at render time"
  elif grep -q "is RETIRED (T-393)" "$TMPDIR/legacy-${legacy_value}.err"; then
    pass "global.l3Required=${legacy_value} alone is refused at render time"
  else
    fail "global.l3Required=${legacy_value} alone failed for the WRONG reason: $(head -1 "$TMPDIR/legacy-${legacy_value}.err")"
  fi
done

# Both replacements stated -> the operator has migrated, and may keep the
# retired variable for an image that still reads it.
render --set global.l3Required=true \
  --set global.l3AvailabilityPosture=reject \
  --set global.l3CompletenessPosture=partial >"$TMPDIR/legacy-migrated.yaml"
check_eq "migrated install still renders the retired flag on the sanitizer" \
  "LUCAIRN_L3_AVAILABILITY_POSTURE=reject
LUCAIRN_L3_REQUIRED=true" "$(sanitizer_l3_env "$TMPDIR/legacy-migrated.yaml")"
check_eq "migrated install still renders the retired flag on the veil-witness" \
  "LUCAIRN_L3_COMPLETENESS_POSTURE=partial
LUCAIRN_L3_REQUIRED=true" "$(witness_l3_env "$TMPDIR/legacy-migrated.yaml")"

# Half a migration is still a CrashLoop next door, so it is still refused.
for half in l3AvailabilityPosture=reject l3CompletenessPosture=partial; do
  if render --set global.l3Required=true --set "global.${half}" >/dev/null 2>"$TMPDIR/half.err"; then
    fail "half-migrated (global.${half} only) is refused"
  elif grep -q "is RETIRED (T-393)" "$TMPDIR/half.err"; then
    pass "half-migrated (global.${half} only) is refused"
  else
    fail "half-migrated (global.${half} only) failed for the WRONG reason"
  fi
done

echo ""
echo "4. the air-gap fail-closed guard moved to the new spelling"

airgap() {
  render --set sandbox-a.sanitizer.llmScanEnabled=true \
    --set global.llmShieldEnabled=true \
    --set global.identityModelRegistryEgress=false \
    "$@"
}

if airgap --set global.l3AvailabilityPosture=reject >/dev/null 2>"$TMPDIR/airgap-ok.err"; then
  pass "air-gap + l3AvailabilityPosture=reject renders (no false-fail on a migrated install)"
else
  fail "air-gap + l3AvailabilityPosture=reject renders: $(head -1 "$TMPDIR/airgap-ok.err")"
fi

# The sanitizer parses its posture case-insensitively after trimming, so a value
# the service WOULD accept must not be false-failed by the render guard.
if airgap --set-string global.l3AvailabilityPosture=Reject >/dev/null 2>"$TMPDIR/airgap-case.err"; then
  pass "air-gap guard matches the service's trim+lower parse (Reject)"
else
  fail "air-gap guard matches the service's trim+lower parse (Reject): $(head -1 "$TMPDIR/airgap-case.err")"
fi

if airgap --set global.l3AvailabilityPosture=degrade >/dev/null 2>"$TMPDIR/airgap-bad.err"; then
  fail "air-gap without a fail-closed posture is refused"
elif grep -q "no fail-closed L3 posture" "$TMPDIR/airgap-bad.err"; then
  pass "air-gap without a fail-closed posture is refused"
else
  fail "air-gap without a fail-closed posture failed for the WRONG reason"
fi

if airgap >/dev/null 2>"$TMPDIR/airgap-unset.err"; then
  fail "air-gap with NO posture at all is refused (image default is degrade)"
elif grep -q "no fail-closed L3 posture" "$TMPDIR/airgap-unset.err"; then
  pass "air-gap with NO posture at all is refused (image default is degrade)"
else
  fail "air-gap with NO posture at all failed for the WRONG reason"
fi

echo ""
echo "5. Compose + CLI must not set the retired flag either"

# `${VAR:-false}` in a compose file sets the variable on every install exactly
# as a chart default did, so the same defect lives on this path.
if grep -Eq '^\s*LUCAIRN_L3_REQUIRED:\s*"\$\{LUCAIRN_L3_REQUIRED:-\}"' "$ROOT/docker-compose.customer.yml"; then
  pass "docker-compose.customer.yml forwards the retired flag with NO default"
else
  fail "docker-compose.customer.yml forwards the retired flag with NO default"
fi
if grep -Eq '^\s*LUCAIRN_L3_REQUIRED:\s*"\$\{LUCAIRN_L3_REQUIRED:-(true|false)\}"' \
     "$ROOT/docker-compose.customer.yml" "$ROOT/docker-compose.self-hosted.yml"; then
  fail "no compose file supplies a LUCAIRN_L3_REQUIRED default"
else
  pass "no compose file supplies a LUCAIRN_L3_REQUIRED default"
fi
# ⚠️ NO compose file may DEFAULT a posture. The self-hosted overlay's retired
# `${LUCAIRN_L3_REQUIRED:-true}` looks like it should migrate to
# `${LUCAIRN_L3_AVAILABILITY_POSTURE:-reject}`, and that is an OUTAGE: since
# 2026-06 both `lucairn-init` and `customer.env.example` wrote
# LUCAIRN_L3_REQUIRED=false for ALL paths, so a defaulted posture would win over
# that leftover value, skip the sanitizer's migration refusal, and fail-close
# against an unstaged model — 503 on every request. This case is the regression
# control for that.
for f in docker-compose.customer.yml docker-compose.self-hosted.yml; do
  if grep -Eq '^[[:space:]]*LUCAIRN_L3_AVAILABILITY_POSTURE:[[:space:]]*"\$\{LUCAIRN_L3_AVAILABILITY_POSTURE:-\}"' "$ROOT/$f"; then
    pass "$f forwards the availability posture with NO default"
  else
    fail "$f forwards the availability posture with NO default"
  fi
done
if grep -Eq '^[[:space:]]*LUCAIRN_L3_(AVAILABILITY_POSTURE|COMPLETENESS_POSTURE):[[:space:]]*"\$\{[A-Z_]+:-[a-zA-Z]' \
     "$ROOT/docker-compose.customer.yml" "$ROOT/docker-compose.self-hosted.yml"; then
  fail "no compose file supplies a posture default"
else
  pass "no compose file supplies a posture default"
fi
# T-385's escape hatch has to be REACHABLE. This repo has no `env_file:`
# directive, so a service's `environment:` block is the only channel from
# customer.env into the container: without this entry the variable is dead
# config and the documented `full` opt-in cannot be exercised on Compose.
if grep -Eq '^[[:space:]]*LUCAIRN_L3_COMPLETENESS_POSTURE:[[:space:]]*"\$\{LUCAIRN_L3_COMPLETENESS_POSTURE:-\}"' \
     "$ROOT/docker-compose.customer.yml"; then
  pass "the veil-witness service forwards the completeness posture (T-385 opt-in reachable)"
else
  fail "the veil-witness service forwards the completeness posture (T-385 opt-in reachable)"
fi

# The generated customer.env and its hand-copied template are both env files the
# sanitizer will refuse to boot on if they still assign the retired variable.
for f in customer.env.example bin/lucairn-init; do
  if grep -Eq '^[[:space:]]*LUCAIRN_L3_REQUIRED=' "$ROOT/$f"; then
    fail "$f assigns no LUCAIRN_L3_REQUIRED value"
  else
    pass "$f assigns no LUCAIRN_L3_REQUIRED value"
  fi
done
for f in customer.env.example bin/lucairn-init; do
  if grep -Eq '^[[:space:]]*LUCAIRN_L3_AVAILABILITY_POSTURE=degrade' "$ROOT/$f"; then
    pass "$f writes the replacement posture"
  else
    fail "$f writes the replacement posture"
  fi
done

echo ""
echo "6. guard-bypass regression controls (T-393 review)"

# HIGH-1. The air-gap guard once carried an `or (dig "l3Required" ...)` arm.
# It could only be REACHED when a posture was also set, and when a posture is
# set the image resolves the posture and merely warns about the retired flag —
# so the arm's one reachable effect was to let `degrade` through the air-gap
# guard. This case renders clean against that arm and red without it.
if airgap --set global.l3Required=true \
     --set global.l3AvailabilityPosture=degrade \
     --set global.l3CompletenessPosture=partial >/dev/null 2>"$TMPDIR/airgap-legacy.err"; then
  fail "air-gap + legacy l3Required=true + degrade is REFUSED (the legacy arm is not a bypass)"
elif grep -q "no fail-closed L3 posture" "$TMPDIR/airgap-legacy.err"; then
  pass "air-gap + legacy l3Required=true + degrade is REFUSED (the legacy arm is not a bypass)"
else
  fail "air-gap + legacy l3Required=true + degrade failed for the WRONG reason"
fi
# Same shape with a STRING legacy value: Go-template truthiness makes "false"
# truthy, so a quoted legacy false suppressed the guard too.
if airgap --set-string global.l3Required=false \
     --set global.l3AvailabilityPosture=degrade \
     --set global.l3CompletenessPosture=partial >/dev/null 2>"$TMPDIR/airgap-legacy-str.err"; then
  fail "air-gap + string legacy \"false\" + degrade is REFUSED"
elif grep -q "no fail-closed L3 posture" "$TMPDIR/airgap-legacy-str.err"; then
  pass "air-gap + string legacy \"false\" + degrade is REFUSED"
else
  fail "air-gap + string legacy \"false\" + degrade failed for the WRONG reason"
fi

# MEDIUM-5. Helm propagates `global` asymmetrically: a SUBCHART-scoped global
# reaches the pod template's coalesced `.Values.global` without ever passing the
# umbrella validator. Each pod template mirrors the guard for exactly this.
for sub in sandbox-a veil-witness; do
  if render --set "${sub}.global.l3Required=true" >/dev/null 2>"$TMPDIR/sub-$sub.err"; then
    fail "subchart-scoped ${sub}.global.l3Required is refused (umbrella guard cannot see it)"
  elif grep -q "is RETIRED (T-393)" "$TMPDIR/sub-$sub.err"; then
    pass "subchart-scoped ${sub}.global.l3Required is refused (umbrella guard cannot see it)"
  else
    fail "subchart-scoped ${sub}.global.l3Required failed for the WRONG reason"
  fi
done

# MEDIUM-6. An off-allowlist posture is a boot refusal in both images, so it is
# a render error here. The likely typo is renaming the retired variable and
# keeping its value.
for bad in "global.l3AvailabilityPosture=true" "global.l3AvailabilityPosture=Degraded" \
           "global.l3CompletenessPosture=false" "global.l3CompletenessPosture=PARTIALLY"; do
  if render --set-string "$bad" >/dev/null 2>"$TMPDIR/enum.err"; then
    fail "off-allowlist $bad is refused"
  elif grep -qE 'must be "(degrade|partial)"' "$TMPDIR/enum.err"; then
    pass "off-allowlist $bad is refused"
  else
    fail "off-allowlist $bad failed for the WRONG reason"
  fi
done
# The enum guard must also be MIRRORED into the pod templates, for the same
# reason the legacy-flag guard is: a subchart-scoped `global` never reaches the
# umbrella validator. `true` is the guard's own documented most-likely typo — a
# rename of the retired flag that kept its value.
for bad in "sandbox-a.global.l3AvailabilityPosture=Degraded" \
           "sandbox-a.global.l3AvailabilityPosture=true" \
           "veil-witness.global.l3CompletenessPosture=PARTIALLY"; do
  if render --set-string "$bad" >/dev/null 2>"$TMPDIR/sub-enum.err"; then
    fail "subchart-scoped off-allowlist $bad is refused"
  elif grep -qE 'must be "(degrade|partial)"' "$TMPDIR/sub-enum.err"; then
    pass "subchart-scoped off-allowlist $bad is refused"
  else
    fail "subchart-scoped off-allowlist $bad failed for the WRONG reason"
  fi
done
if render --set-string sandbox-a.global.l3AvailabilityPosture=reject >/dev/null 2>"$TMPDIR/sub-ok.err"; then
  pass "a VALID subchart-scoped posture still renders (mirror does not over-fire)"
else
  fail "a VALID subchart-scoped posture still renders: $(head -1 "$TMPDIR/sub-ok.err")"
fi

# ...but a value the IMAGE would accept must still render (no over-firing).
if render --set-string global.l3AvailabilityPosture=Reject \
     --set-string global.l3CompletenessPosture=" Full " >/dev/null 2>"$TMPDIR/enum-ok.err"; then
  pass "enum guard trims+lowercases like the services do (no false-fail)"
else
  fail "enum guard trims+lowercases like the services do: $(head -1 "$TMPDIR/enum-ok.err")"
fi

# EMPTY IS ABSENCE, WHITESPACE-ONLY IS A VALUE — both services draw the line
# exactly there (config.py `_parse_strict_enum` / l3_posture.go
# `parseL3CompletenessPosture` return the default for "" and refuse "   "), and a
# render guard that drew it anywhere else would be a second opinion rather than a
# preview of the image.
cat >"$TMPDIR/empty-posture.yaml" <<'YAML'
global:
  l3AvailabilityPosture: ""
  l3CompletenessPosture:
YAML
if render -f "$TMPDIR/empty-posture.yaml" >/dev/null 2>"$TMPDIR/empty.err"; then
  pass "an empty/null posture is treated as absence, exactly as the images do"
else
  fail "an empty/null posture is treated as absence: $(head -1 "$TMPDIR/empty.err")"
fi
cat >"$TMPDIR/ws-posture.yaml" <<'YAML'
global:
  l3AvailabilityPosture: "   "
YAML
if render -f "$TMPDIR/ws-posture.yaml" >/dev/null 2>"$TMPDIR/ws.err"; then
  fail "a whitespace-only posture is REFUSED (it is a value, not an absence)"
elif grep -q 'must be "degrade"' "$TMPDIR/ws.err"; then
  pass "a whitespace-only posture is REFUSED (it is a value, not an absence)"
else
  fail "a whitespace-only posture failed for the WRONG reason"
fi

echo ""
echo "7. bin/lucairn doctor WARN branches (offline, no docker/network)"

# Pure unit test, matching tests/test_manifest_blob.sh and
# tests/test_l3_split_pool_preflight.sh: source bin/lucairn with EMPTY args (so
# the trailing `main "$@"` degrades to a harmless usage print) and call
# check_l3_required_wired directly against hand-built env files. The function is
# warn-only and always returns 0, so every assertion is on the WARN TEXT — a
# check that returns 0 either way is only a control if you read what it said.
run_doctor_l3() {
  local env_file="$1"
  bash -c '
    set +e
    source "'"$ROOT"'/bin/lucairn" >/dev/null 2>&1
    set +e +u +o pipefail
    check_l3_required_wired "'"$env_file"'"
    printf "RC=%s\n" "$?"
  ' 2>&1
}

# assert_doctor NAME ENV_BODY EXPECT_SUBSTRING|"" [FORBID_SUBSTRING]
assert_doctor() {
  local name="$1" body="$2" needle="$3" forbid="${4:-}" out
  printf '%s\n' "$body" >"$TMPDIR/doctor.env"
  out="$(run_doctor_l3 "$TMPDIR/doctor.env")"
  if ! printf '%s' "$out" | grep -q "RC=0"; then
    fail "$name (function did not return 0 — it is warn-only by contract)"
    return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    fail "$name (expected WARN containing [$needle]; got: $(printf '%s' "$out" | head -c 130))"
    return
  fi
  if [ -n "$forbid" ] && printf '%s' "$out" | grep -qF -- "$forbid"; then
    fail "$name (WARN unexpectedly contained [$forbid])"
    return
  fi
  pass "$name"
}

# A leftover retired flag is a boot refusal, so the doctor must name it offline.
assert_doctor "doctor warns on a leftover LUCAIRN_L3_REQUIRED" \
  "LUCAIRN_L3_REQUIRED=false" \
  "LUCAIRN_L3_REQUIRED is RETIRED but still set"

# The likeliest migration typo: rename the variable, keep the old value. Both
# services refuse to boot on it, so an offline pre-flight has to catch it.
assert_doctor "doctor warns on an off-allowlist availability posture" \
  "LUCAIRN_L3_AVAILABILITY_POSTURE=true" \
  "is not one of degrade|reject"
assert_doctor "doctor warns on an off-allowlist completeness posture" \
  "LUCAIRN_L3_COMPLETENESS_POSTURE=false" \
  "is not one of partial|full"

# Whitespace-only is a VALUE, not an absence — both services refuse it.
assert_doctor "doctor warns on a whitespace-only posture" \
  'LUCAIRN_L3_AVAILABILITY_POSTURE="   "' \
  "is not one of degrade|reject"

# ⚠️ REGRESSION CONTROL for the normaliser. This check used to squeeze the value
# with `tr -d "[:space:]"`, which deletes INTERNAL whitespace: "re ject" became
# "reject" and passed silently, while the sanitizer's own `.strip()` leaves
# "re ject", finds it off-allowlist and refuses to boot — an offline pre-flight
# that green-lights a stack which cannot start. Trimming ends only is what makes
# this case red against that bug. (bin/lucairn carries the same lesson as a
# security fix on the image-digest gate.)
assert_doctor "doctor rejects internal whitespace (not just leading/trailing)" \
  'LUCAIRN_L3_AVAILABILITY_POSTURE="re ject"' \
  "is not one of degrade|reject"

# ...but a value the SERVICES would accept must not be flagged as off-allowlist.
# " Reject " normalises to reject, so the only warn here is the shield-wiring
# one — which is exactly what the next case asserts.
assert_doctor "doctor accepts a padded/capitalised valid posture" \
  'LUCAIRN_L3_AVAILABILITY_POSTURE=" Reject "' \
  "" \
  "is not one of degrade|reject"

# Fail-closed posture with no L3 shield wired: the silent-503 trap. This warn is
# SPLIT-INSTALL-ONLY by design — a non-empty SANDBOX_B_REMOTE_ENDPOINT is what
# tells the offline heuristic that the self-hosted overlay (which DOES define
# ollama-identity) is not in play. Writing the fixture without it produced a
# green assertion for the wrong reason, so both shapes are pinned.
assert_doctor "doctor warns on reject + no shield on a SPLIT install" \
  "$(printf 'LUCAIRN_L3_AVAILABILITY_POSTURE=reject\nSANDBOX_B_REMOTE_ENDPOINT=https://sandbox-b.example:8443\n')" \
  "no L3 shield appears wired"
assert_doctor "doctor stays quiet on reject when self-hosted wires the shield" \
  "LUCAIRN_L3_AVAILABILITY_POSTURE=reject" \
  "" \
  "no L3 shield appears wired"

# The shipped default must be silent on all three branches.
assert_doctor "doctor is silent on the shipped degrade default" \
  "LUCAIRN_L3_AVAILABILITY_POSTURE=degrade" \
  "" \
  "L3"

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "T-393 / T-385 L3 posture flag gate: PASS ($N assertions)"
else
  echo "T-393 / T-385 L3 posture flag gate: FAIL ($FAILS of $N assertions)"
  exit 1
fi
