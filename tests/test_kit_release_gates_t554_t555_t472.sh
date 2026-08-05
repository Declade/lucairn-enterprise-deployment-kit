#!/usr/bin/env bash
#
# Kit release gates T-554 / T-555 / T-472.
#
# Every case here comes from the 2026-08-04 CLEAN-ROOM REHEARSAL
# (specs/2026-08/rehearsal-2026-08-04-kit-clean-room.md) — the first time the
# kit was actually RUN rather than rendered. Ten PRs of render + unit tests had
# gone green; running the artifact found what none of them could.
#
# ── WHAT EACH GATE STOPS ──────────────────────────────────────────────────────
#
# T-554 (rehearsal F2 — the executable half of F1)
#   `check_image_manifest` had exactly ONE call site (bin/lucairn, Compose
#   branch). The Helm `doctor --values` path never called it, so a Kubernetes
#   operator bumping `global.imageTag` got ZERO warning before an upgrade that
#   can crash-loop the stack — which is exactly what F1 did. The fix wires the
#   HELM path into the SAME function. A forked twin checker would drift from
#   the Compose one, which is the very bug class image-manifest.yaml exists to
#   document, so "exactly one definition" is itself an assertion below.
#
#   RED-PROOF (reproduced 2026-08-05 before the fix):
#     bin/lucairn @ origin/main + a values file carrying global.imageTag=latest
#     -> `doctor --values` emitted ZERO lines matching "image manifest"/
#     "imageTag". Silent. The post-fix tree warns on the same fixture.
#   NON-COVERAGE: doctor compares the manifest against the VALUES. It cannot
#     see registry-side tag mutation (someone re-pushing :0.5.4). That is what
#     `doctor --strict` digest pinning is for.
#
# T-555 (rehearsal F1 + F3)
#   F1: `helm upgrade --set global.imageTag=latest` CrashLooped veil-witness
#       with `required environment variable VEIL_DB_URL is not set` while the
#       chart emitted only LCR_DB_URL. That error string is the PRE-rename
#       `requireEnv` message; a rename-aware image says "LCR_DB_URL (or legacy
#       VEIL_DB_URL)". So :latest is an image built before the 2026-06-02
#       Stage 3 rename. The chart + INSTALL.md both claimed the image accepts
#       either name via envcompat — true only in ONE direction (old NAMES
#       against a NEW image), and the docs did not say so.
#   F3: INSTALL.md's `DOCKER_CONFIG=$(mktemp -d)` + `docker login` recipe still
#       wrote credsStore on Docker Desktop 29.6.1, producing the exact unusable
#       payload it claimed to prevent.
#
#   RED-PROOF: `helm template` on the origin/main chart greps ZERO VEIL_DB_URL
#     (reproduced 2026-08-05). NON-COVERAGE: emitting both DB-URL names does
#     NOT make :latest installable — a pre-rename image also needs
#     VEIL_BRIDGE_PUBLIC_KEY / VEIL_SANITIZER_PUBLIC_KEY, which arrive via an
#     envFrom ConfigMap whose keys are LCR_-named. Only manifest-listed tags
#     are validated. Case `install-does-not-claim-latest-works` pins that the
#     docs never over-claim it.
#
# T-472
#   The charts had ZERO references to `request_budget_seconds` (verified
#   2026-08-05), so the TOTAL wall-clock bound on one request's L3 inference
#   was unreachable from Helm. `llmScanTimeout` bounds a SINGLE call: 20 calls
#   of 29s each satisfy it and still run ~580s. Default is the image's own
#   shipped default (90) so a stock render is behaviour-neutral.
#
# ── POSITIVE CONTROLS (none of these is a tautology) ──────────────────────────
#   - helm-doctor-warns-on-drift: deleting the check_image_manifest_helm call
#     from the values-only branch turns it red.
#   - helm-doctor-silent-on-pinned: a checker that warns unconditionally (a
#     plausible over-fix) turns it red. Pins the FALSE-POSITIVE direction.
#   - helm-doctor-is-warn-only: a checker that returns non-zero turns it red.
#   - one-manifest-checker-definition: forking a Helm-only twin turns it red.
#   - compose-path-still-checked: dropping the original Compose call site while
#     adding the Helm one turns it red.
#   - witness-emits-both-db-url-names: reverting the chart to LCR-only turns it
#     red (that IS the pre-fix tree).
#   - db-url-names-share-one-secret-key: emitting VEIL_DB_URL from a different
#     key (a plausible botched merge) turns it red.
#   - install-corrects-envcompat-direction / install-cites-measured-error:
#     restoring the unqualified "images accept both forms" claim turns them red.
#   - install-credential-recipe-verifies: restoring the bare mktemp+login recipe
#     with no verification turns it red.
#   - budget-knob-rendered / budget-knob-is-plumbed: deleting the values key or
#     hardcoding the configmap literal turns them red.
#
# No Docker, no cluster, no network. helm + ruby + python3 only.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/tests/lib/test-helpers.sh"

WK="$(mktemp -d)"
trap 'rm -rf "$WK"' EXIT

FAILS=0
N=0

pass() { N=$((N + 1)); echo "  ok   — $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "  FAIL — $1"; }

check() { # check DESC CONDITION_RC
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

# want DESC CMD... — run CMD, report, and NEVER abort the suite under `set -e`.
# (A bare `grep -q ...` on its own line would kill the run on the first miss
# and silently truncate the report, which is how this harness first misled us.)
want() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# reject DESC CMD... — the inverse: the command MUST fail.
reject() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A values file that renders cleanly (carries the T-10 mandatory secrets) so
# `doctor --values` reaches the image-manifest check and terminates green.
# Only global.imageTag differs between the two fixtures — the drift signal must
# be attributable to that one field and nothing else.
mk_values() { # mk_values PATH TAG
  cat > "$1" <<EOF
global:
  imageTag: "$2"
admin:
  secrets: { values: { adminPassword: ${TEST_SECRET_VALUE} } }
audit:
  secrets:
    values:
      postgresPassword: ${TEST_SECRET_VALUE}
      auditAppPassword: ${TEST_SECRET_VALUE}
id-bridge:
  secrets: { values: { postgresPassword: ${TEST_SECRET_VALUE} } }
observability:
  secrets: { values: { grafanaAdminPassword: ${TEST_SECRET_VALUE} } }
sandbox-a:
  secrets: { values: { postgresPassword: ${TEST_SECRET_VALUE} } }
veil-witness:
  secrets:
    values:
      postgresPassword: ${TEST_SECRET_VALUE}
      veilAppPassword: ${TEST_SECRET_VALUE}
EOF
}

MANIFEST_TAG="$(awk -F: '/^default_lucairn_image_tag:/ { sub(/^[^:]+:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit }' "$ROOT/image-manifest.yaml")"
[ -n "$MANIFEST_TAG" ] || { echo "harness error: could not read default_lucairn_image_tag"; exit 1; }

mk_values "$WK/pinned.yaml" "$MANIFEST_TAG"
mk_values "$WK/drift.yaml" "definitely-not-a-pinned-tag"

echo "== T-554: image-manifest drift is visible on the Helm doctor path =="

DRIFT_OUT="$WK/drift.out"
set +e
bash "$ROOT/bin/lucairn" doctor --values "$WK/drift.yaml" > "$DRIFT_OUT" 2>&1
DRIFT_RC=$?
set -e

want "helm-doctor-warns-on-drift: doctor --values names the pinned tag" grep -q "image-manifest.yaml pins $MANIFEST_TAG" "$DRIFT_OUT"

want "helm-doctor-warns-on-drift: the warning names the Helm key, not an env var" grep -q "global.imageTag" "$DRIFT_OUT"

# The operator must be told WHY an unpinned tag is dangerous, not merely that
# it differs. This sentence is the rehearsal's root cause in one line.
want "helm-doctor-warns-on-drift: warning explains the chart<->image contract risk" grep -qi "UNVALIDATED against this chart" "$DRIFT_OUT"

# WARN-only: the manifest is advisory. --strict digest pinning is the gate.
[ "$DRIFT_RC" -eq 0 ]
check "helm-doctor-is-warn-only: drift does not change doctor's exit code" $?

PINNED_OUT="$WK/pinned.out"
set +e
bash "$ROOT/bin/lucairn" doctor --values "$WK/pinned.yaml" > "$PINNED_OUT" 2>&1
PINNED_RC=$?
set -e

# FALSE-POSITIVE direction: a checker that always warns is not a checker.
reject "helm-doctor-silent-on-pinned: no drift warning when values match the manifest" \
  grep -q "image-manifest.yaml pins" "$PINNED_OUT"

[ "$PINNED_RC" -eq 0 ]
check "helm-doctor-silent-on-pinned: pinned values-only run exits 0" $?

# The check must actually have RUN on the pinned fixture (silence could
# otherwise mean the whole check was skipped, which would also silence drift).
want "helm-doctor-ran: the Helm manifest check executed on the pinned fixture" grep -q "image manifest (Helm): read from" "$PINNED_OUT"

# ONE oracle, not two. A Helm-only twin would drift from the Compose checker.
DEF_COUNT="$(grep -c '^check_image_manifest() {' "$ROOT/bin/lucairn" || true)"
[ "$DEF_COUNT" -eq 1 ]
check "one-manifest-checker-definition: exactly one check_image_manifest implementation (found $DEF_COUNT)" $?

# The Helm wrapper must DELEGATE, not reimplement.
want "one-manifest-checker-definition: the Helm wrapper calls the shared function" grep -q 'check_image_manifest "" "\$helm_tag" "\$helm_registry" helm' "$ROOT/bin/lucairn"

# The original Compose call site must survive the wiring.
want "compose-path-still-checked: the Compose call site is intact" grep -q '^  check_image_manifest "\$env_file"' "$ROOT/bin/lucairn"

echo ""
echo "== T-555a: the witness renders BOTH DB-URL env names =="

RENDER="$WK/render.yaml"
helm template lucairn "$ROOT/charts/lucairn" \
  "${HELM_TEST_SECRET_ARGS[@]}" \
  --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
  --set global.skipPullSecretGuard=true > "$RENDER" 2>"$WK/render.err"
check "umbrella chart renders" $?

want "witness-emits-both-db-url-names: LCR_DB_URL present (canonical, unchanged)" grep -q "name: LCR_DB_URL" "$RENDER"

want "witness-emits-both-db-url-names: VEIL_DB_URL present (RED on origin/main: 0 matches)" grep -q "name: VEIL_DB_URL" "$RENDER"

# Same value, or the two names disagree and the legacy one poisons an old image
# with a wrong DSN. Both must resolve to the least-privilege veil_app role.
python3 - "$RENDER" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
found = {}
for d in docs:
    if d.get("kind") != "Deployment":
        continue
    if d["metadata"]["name"] != "veil-witness":
        continue
    for c in d["spec"]["template"]["spec"]["containers"]:
        for e in c.get("env", []):
            if e["name"] in ("LCR_DB_URL", "VEIL_DB_URL"):
                found[e["name"]] = e.get("valueFrom", {}).get("secretKeyRef")
assert set(found) == {"LCR_DB_URL", "VEIL_DB_URL"}, f"expected both names, got {sorted(found)}"
assert found["LCR_DB_URL"] is not None, "LCR_DB_URL is not sourced from a secret"
assert found["LCR_DB_URL"] == found["VEIL_DB_URL"], (
    f"the two DB-URL names resolve differently: {found}")
assert found["LCR_DB_URL"]["key"] == "DATABASE_URL_APP", (
    "DB URL must stay on the least-privilege veil_app key (INT-001)")
PY
check "db-url-names-share-one-secret-key: both names read the same DATABASE_URL_APP key" $?

echo ""
echo "== T-555b: INSTALL.md describes what the image actually does =="

INSTALL="$ROOT/INSTALL.md"
# Markdown re-wraps, and blockquote continuation lines carry a leading '> '.
# Strip the markers, then flatten to one line, so a phrase assertion pins the
# CLAIM rather than the line break that happened to sit inside it.
INSTALL_FLAT="$WK/install.flat"
sed 's/^> \{0,1\}//' "$INSTALL" | tr '\n' ' ' | tr -s ' ' > "$INSTALL_FLAT"

# The unqualified claim is what F1 falsified. It must be gone.
reject "install-corrects-envcompat-direction: unqualified v0.5.0+ envcompat claim removed" \
  grep -q "images (v0.5.0+) read each" "$INSTALL_FLAT"

want "install-corrects-envcompat-direction: the one-directional caveat is stated" grep -qi "ONE-DIRECTIONAL" "$INSTALL_FLAT"

# The measured evidence, not an assertion of belief.
want "install-cites-measured-error: the reproduced boot error is quoted" grep -q "required environment variable VEIL_DB_URL is not set" "$INSTALL_FLAT"

# The docs must not leave an operator thinking :latest is now fine.
want "install-does-not-claim-latest-works: the residual is stated explicitly" grep -q "does not make an arbitrary tag installable" "$INSTALL_FLAT"

want "install-does-not-claim-latest-works: only manifest-listed tags are claimed" grep -q "Only the tags recorded in \`image-manifest.yaml\` are validated" "$INSTALL_FLAT"

# The chart comment made the same claim; it must carry the same correction.
WITNESS_TPL="$ROOT/charts/lucairn/charts/veil-witness/templates/deployment.yaml"
reject "chart-comment-corrected: the v0.5.0+ envcompat claim is gone from the template" \
  grep -q "image (v0.5.0+) accepts both forms" "$WITNESS_TPL"

want "chart-comment-corrected: the template cites the actual image call" grep -q "requireEnvCompat" "$WITNESS_TPL"

echo ""
echo "== T-555c: the credential-isolation recipe actually isolates =="

# The old recipe's failure was SILENT — it produced a config Kubernetes cannot
# use and nothing checked. A verification step is the load-bearing fix.
want "install-credential-recipe-verifies: recipe ends in a pass/fail verification" grep -q "pull secret: ok" "$INSTALL_FLAT"

want "install-credential-recipe-verifies: verification rejects helper metadata" grep -q "credHelpers" "$INSTALL_FLAT"

# The wrapping trap that silently corrupts a long PAT on GNU base64.
want "install-credential-recipe-verifies: base64 output is un-wrapped" grep -q "base64 | tr -d" "$INSTALL"

# The disproven claim must not stand unqualified any more.
want "install-credential-recipe-verifies: the disproven mktemp-alone claim is corrected" grep -q "alone is NOT enough" "$INSTALL_FLAT"

# The verification snippet in the docs must actually work. Extract-and-run is
# overkill; instead re-run its logic against the exact payload the rehearsal
# produced and assert it is REJECTED (positive control for the guard itself).
python3 - <<'PY'
import base64, json, sys

def verify(cfg):
    if "credsStore" in cfg or "credHelpers" in cfg:
        return "helper"
    auth = cfg.get("auths", {}).get("ghcr.io", {}).get("auth")
    if not auth:
        return "no-auth"
    if ":" not in base64.b64decode(auth).decode():
        return "bad-pair"
    return "ok"

# The EXACT payload the 2026-08-04 rehearsal got from the old recipe.
rehearsal = {"auths": {"ghcr.io": {}}, "credsStore": "osxkeychain"}
assert verify(rehearsal) == "helper", "the rehearsal payload must be rejected"

good = {"auths": {"ghcr.io": {"auth": base64.b64encode(b"user:token").decode()}}}
assert verify(good) == "ok", "a correctly built payload must pass"

assert verify({"auths": {"ghcr.io": {}}}) == "no-auth"
PY
check "install-credential-recipe-verifies: the documented check rejects the rehearsal payload" $?

echo ""
echo "== T-472: request_budget_seconds is reachable from Helm =="

want "budget-knob-rendered: default renders at the image default (90)" grep -q "request_budget_seconds: 90" "$RENDER"

# Behaviour-neutral by default: the rendered default must equal the sanitizer
# image's own default, or a stock Helm install silently changes L3 timing.
python3 - "$RENDER" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
for d in docs:
    if d.get("kind") != "ConfigMap":
        continue
    for key, body in (d.get("data") or {}).items():
        if "llm_scan" not in body:
            continue
        cfg = yaml.safe_load(body)
        scan = (cfg.get("sanitizer") or cfg).get("llm_scan")
        if not isinstance(scan, dict) or "request_budget_seconds" not in scan:
            continue
        assert scan["request_budget_seconds"] == 90, scan["request_budget_seconds"]
        # It must be a real total budget, not an alias of the per-call timeout.
        assert "timeout_seconds" in scan, "per-call timeout disappeared"
        sys.exit(0)
sys.exit("no sanitizer ConfigMap carried llm_scan.request_budget_seconds")
PY
check "budget-knob-rendered: parsed from the sanitizer ConfigMap, per-call timeout intact" $?

# The knob must be PLUMBED, not a hardcoded literal that happens to read 90.
OVERRIDE="$WK/override.yaml"
helm template lucairn "$ROOT/charts/lucairn" \
  "${HELM_TEST_SECRET_ARGS[@]}" \
  --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
  --set global.skipPullSecretGuard=true \
  --set "sandbox-a.sanitizer.llmScanRequestBudgetSeconds=137" > "$OVERRIDE" 2>/dev/null
want "budget-knob-is-plumbed: an operator override reaches the sanitizer config" grep -q "request_budget_seconds: 137" "$OVERRIDE"

# And the values key must be documented where an operator will look for it.
want "budget-knob-is-plumbed: the key ships in the subchart values.yaml" grep -q "llmScanRequestBudgetSeconds" "$ROOT/charts/lucairn/charts/sandbox-a/values.yaml"

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "kit release gates T-554 / T-555 / T-472: PASS ($N assertions)"
else
  echo "kit release gates T-554 / T-555 / T-472: FAIL ($FAILS of $N assertions)"
  exit 1
fi
