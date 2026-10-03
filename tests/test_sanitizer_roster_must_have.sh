#!/usr/bin/env bash
set -euo pipefail

# T-768 — the sanitizer recognizer roster may not shrink or drift silently.
#
# THE DEFECT: the kit's two roster surfaces (Compose config/default-sanitizer.yaml
# and the Helm sandbox-a sanitizer ConfigMap) sat at 33 recognizers while the
# upstream sanitizer default grew to 46. Nothing noticed: a recognizer that is
# not listed is simply never loaded, and the sanitizer boots and answers
# normally. The kit now ships 34 (33 + medical_record_number) and the floor is
# those 34.
#
# WHAT THIS PROVES:
#   1. Both shipped surfaces carry every name in
#      config/sanitizer-roster-must-have.txt (the floor), checked on the
#      RENDERED Helm ConfigMap and on the Compose file, parsed as YAML.
#   2. The two surfaces carry the SAME roster (no silent drift between them).
#   3. The deliberately-absent names (not in the pinned image, held back for
#      false positives, opt-in only, or no-ops on the pinned image) are absent
#      from both surfaces and from the floor.
#   4. `bin/lucairn doctor`'s structural reader (POSIX awk, because offline
#      doctor must stay Python-free) agrees with PyYAML, the pinned
#      sanitizer's own loader, on both shipped surfaces; and on an adversarial
#      corpus it either reads exactly the roster PyYAML reads or refuses the
#      file. It never accepts a file PyYAML rejects, never reads a different
#      roster.
#   5. POSITIVE CONTROLS: removing one floor name makes the doctor check FAIL
#      (Compose and Helm), acknowledging it downgrades to a warning with
#      honest counts, and the flow-style list form is parsed.
#
# The fail-closed doctor behaviour (sol round-1 repros) is pinned separately
# by tests/test_sanitizer_roster_doctor_repros.sh.
#
# WHAT THIS DOES NOT PROVE: that the pinned sanitizer image registers every
# floor name. That was verified against the image's source registry when the
# floor was written (PR body for T-768). When the kit pins a new sanitizer
# image, re-verify before adding names here.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
FLOOR="$ROOT/config/sanitizer-roster-must-have.txt"
COMPOSE_CFG="$ROOT/config/default-sanitizer.yaml"
CM_TEMPLATE="$CHART/charts/sandbox-a/templates/sanitizer-configmap.yaml"

# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

fail() {
  echo "T-768 sanitizer roster floor: $*" >&2
  exit 1
}

WK="$(mktemp -d)"
cleanup() { rm -rf "$WK"; }
trap cleanup EXIT

[ -f "$FLOOR" ] || fail "floor list missing: $FLOOR"

# ---------------------------------------------------------------------------
# Render the Helm ConfigMap and extract its config.yaml.
# ---------------------------------------------------------------------------
helm template lucairn "$CHART" \
  "${HELM_TEST_SECRET_ARGS[@]}" \
  --set global.skipPullSecretGuard=true \
  --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
  > "$WK/render.yaml" || fail "helm template failed"

# ---------------------------------------------------------------------------
# 1-3. YAML-level assertions on both surfaces.
# ---------------------------------------------------------------------------
python3 - "$WK/render.yaml" "$COMPOSE_CFG" "$FLOOR" "$WK" <<'PY' || exit 1
import sys, yaml
render, compose_cfg, floor_path, outdir = sys.argv[1:5]

floor = []
for raw in open(floor_path):
    name = raw.split("#", 1)[0].strip()
    if name:
        floor.append(name)
if len(floor) != len(set(floor)):
    print("floor list has duplicate names", file=sys.stderr); sys.exit(1)

cm = None
for doc in yaml.safe_load_all(open(render)):
    if doc and doc.get("kind") == "ConfigMap" and doc["metadata"]["name"] == "sanitizer-config":
        cm = doc
if cm is None:
    print("sanitizer-config ConfigMap absent from the render", file=sys.stderr); sys.exit(1)
open(outdir + "/rendered-config.yaml", "w").write(cm["data"]["config.yaml"])

def roster(cfg):
    lst = (((cfg or {}).get("sanitizer") or {}).get("presidio") or {}).get("custom_recognizers")
    if not isinstance(lst, list):
        return None
    return [str(x) for x in lst]

surfaces = {
    "helm (rendered)": roster(yaml.safe_load(cm["data"]["config.yaml"])),
    "compose (config/default-sanitizer.yaml)": roster(yaml.safe_load(open(compose_cfg))),
}

# Names that must NOT be on any default surface or in the floor while the kit
# pins the 0.5.4 sanitizer image: (a) not registered by 0.5.4 -> boot refusal;
# (b) bare-shape ID recognizers held back for false positives (no zoner);
# (c) opt-in only for healthcare/clinical installs (ordinary-word false
# positives at 0.35); (d) no-ops on 0.5.4 (entity type discarded by the
# scanner).
NOT_IN_PINNED_IMAGE = {"labeled_id", "patientennummer_id_prefix", "attribution_person"}
HELD_BACK_FP = {"format_ticket", "format_numeric_run", "format_hex_block",
                "format_uuid", "format_ulid"}
OPT_IN_ONLY = {"de_places", "drugs_and_diagnoses"}
NO_OP_ON_PINNED = {"de_companies", "software_products"}
ABSENT = NOT_IN_PINNED_IMAGE | HELD_BACK_FP | OPT_IN_ONLY | NO_OP_ON_PINNED
EXPECTED_FLOOR_SIZE = 34

rc = 0
if len(floor) != EXPECTED_FLOOR_SIZE:
    print(f"floor list has {len(floor)} names, expected {EXPECTED_FLOOR_SIZE}", file=sys.stderr)
    rc = 1
leaked_floor = ABSENT & set(floor)
if leaked_floor:
    print(f"floor list names deliberately-absent recognizer(s) {sorted(leaked_floor)}", file=sys.stderr)
    rc = 1
for label, names in surfaces.items():
    if names is None:
        print(f"{label}: sanitizer.presidio.custom_recognizers missing or not a list", file=sys.stderr)
        rc = 1
        continue
    dups = sorted({n for n in names if names.count(n) > 1})
    if dups:
        print(f"{label}: duplicate recognizer(s) {dups}", file=sys.stderr); rc = 1
    missing = [n for n in floor if n not in names]
    if missing:
        print(f"{label}: missing floor recognizer(s) {missing}", file=sys.stderr); rc = 1
    bad = sorted(ABSENT & set(names))
    if bad:
        print(f"{label}: lists deliberately-absent recognizer(s) {bad}", file=sys.stderr); rc = 1
    open(outdir + "/" + ("helm" if label.startswith("helm") else "compose") + ".names", "w").write(
        "\n".join(names) + "\n")
vals = [set(v) for v in surfaces.values() if v is not None]
if len(vals) == 2 and vals[0] != vals[1]:
    a, b = vals
    print(f"helm and compose rosters differ: only-helm={sorted(a - b)} only-compose={sorted(b - a)}", file=sys.stderr)
    rc = 1
if rc == 0:
    print(f"ok: both surfaces carry all {len(floor)} floor recognizers, identical rosters "
          f"({len(vals[0])} names), no deliberately-absent names")
sys.exit(rc)
PY

# ---------------------------------------------------------------------------
# 4-5. The doctor check itself.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
source "$ROOT/bin/lucairn" >/dev/null 2>&1
set +e +u +o pipefail

# 4a. Reader agreement with PyYAML on the shipped surfaces, in file order. The
# raw template goes through the same extraction doctor uses when helm is
# unavailable.
_sanitizer_configmap_extract template "$CM_TEMPLATE" "$WK/template-config.yaml" >/dev/null \
  || fail "doctor could not extract config.yaml from the raw ConfigMap template"
for pair in "compose:$COMPOSE_CFG" "helm:$WK/rendered-config.yaml" "helm:$WK/template-config.yaml"; do
  kind="${pair%%:*}"; file="${pair#*:}"
  _sanitizer_roster_names "$file" > "$WK/doctor.names" \
    || fail "doctor's roster reader refused the shipped file ${file#"$ROOT"/}"
  cmp -s "$WK/doctor.names" "$WK/$kind.names" \
    || { diff "$WK/$kind.names" "$WK/doctor.names" >&2; fail "doctor's roster reader disagrees with PyYAML on ${file#"$ROOT"/}"; }
done
echo "ok: doctor's roster reader matches PyYAML on the Compose file, the rendered ConfigMap and the raw template"

# 4b. Adversarial corpus (tests/fixtures/sanitizer-roster-corpus, synthetic).
# For each file the reader must either read EXACTLY the roster PyYAML reads,
# taken the way the pinned sanitizer takes it (config.py:717-753), or refuse
# the file. Accepting a file PyYAML rejects, or reading a different roster,
# fails this test. The starter templates ride along as real-world inputs.
CORPUS="$ROOT/tests/fixtures/sanitizer-roster-corpus"
mkdir -p "$WK/corpus-out"
for f in "$CORPUS"/*.yaml "$ROOT"/starter-templates/*/config.yaml; do
  [ -f "$f" ] || fail "corpus file missing: $f"
  out="$WK/corpus-out/$(printf '%s' "${f#"$ROOT"/}" | tr '/' '_')"
  if _sanitizer_roster_names "$f" > "$out.names"; then echo ok > "$out.rc"; else echo refused > "$out.rc"; fi
  printf '%s\n' "$f" > "$out.src"
done
python3 - "$WK/corpus-out" <<'PY' || exit 1
import glob, os, sys, yaml
bad = agree = refused = 0
for src in sorted(glob.glob(sys.argv[1] + "/*.src")):
    stem = src[:-4]
    path = open(src).read().strip()
    awk_ok = open(stem + ".rc").read().strip() == "ok"
    awk_names = [l for l in open(stem + ".names").read().split("\n") if l]
    try:
        data = yaml.safe_load(open(path)) or {}
        s = data.get("sanitizer", {})
        r = [] if not s else s.get("presidio", {}).get("custom_recognizers", [])
        py = [str(x) for x in r] if isinstance(r, list) else None
    except Exception:
        py = None
    name = os.path.basename(path) if "fixtures" in path else path.split("starter-templates/")[-1]
    if awk_ok and py is None:
        print(f"{name}: doctor ACCEPTED a file the sanitizer cannot load", file=sys.stderr); bad += 1
    elif awk_ok and awk_names != py:
        print(f"{name}: doctor read {awk_names}, the sanitizer reads {py}", file=sys.stderr); bad += 1
    elif awk_ok:
        agree += 1
    else:
        refused += 1
if bad:
    sys.exit(1)
if agree < 15 or refused < 10:
    print(f"corpus lost its shape: {agree} agreed, {refused} refused", file=sys.stderr); sys.exit(1)
print(f"ok: adversarial corpus: {agree} read exactly as PyYAML reads them, {refused} refused (fail closed), 0 misread")
PY

FAILS=0
# expect RC NEEDLE -- CMD...  (runs CMD, checks rc and that output contains NEEDLE)
expect() {
  local want_rc="$1" needle="$2"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL: '$*' rc=$rc want=$want_rc" >&2; echo "$out" >&2; FAILS=$((FAILS + 1)); return
  fi
  if ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: '$*' output lacks '$needle'" >&2; echo "$out" >&2; FAILS=$((FAILS + 1)); return
  fi
  echo "ok: rc=$rc '$needle'"
}

# Shipped state passes, Compose and Helm (rendered with dummy secret values).
printf 'SANITIZER_CONFIG_FILE=%s\n' "$COMPOSE_CFG" > "$WK/shipped.env"
expect 0 "sanitizer roster: ok" -- check_sanitizer_roster_floor "$WK/shipped.env"
cat > "$WK/values.yaml" <<EOF
admin: {secrets: {values: {adminPassword: "${TEST_SECRET_VALUE}"}}}
audit: {secrets: {values: {postgresPassword: "${TEST_SECRET_VALUE}", auditAppPassword: "${TEST_SECRET_VALUE}"}}}
id-bridge: {secrets: {values: {postgresPassword: "${TEST_SECRET_VALUE}"}}}
observability: {secrets: {values: {grafanaAdminPassword: "${TEST_SECRET_VALUE}"}}}
sandbox-a: {secrets: {values: {postgresPassword: "${TEST_SECRET_VALUE}"}}}
veil-witness: {secrets: {values: {postgresPassword: "${TEST_SECRET_VALUE}", veilAppPassword: "${TEST_SECRET_VALUE}"}}}
EOF
expect 0 "sanitizer roster (Helm): ok" -- check_sanitizer_roster_floor_helm "$CHART" "$WK/values.yaml"

# Positive control (Compose): drop ONE floor name -> FAIL naming it.
grep -vE '^[[:space:]]+- phone_extended$' "$COMPOSE_CFG" > "$WK/shrunk.yaml"
grep -qE '^[[:space:]]+- phone_extended$' "$WK/shrunk.yaml" && fail "control did not remove phone_extended"
printf 'SANITIZER_CONFIG_FILE=%s\n' "$WK/shrunk.yaml" > "$WK/shrunk.env"
expect 1 "lacks floor recognizer(s): phone_extended" -- check_sanitizer_roster_floor "$WK/shrunk.env"

# Acknowledged removal -> warning, rc 0, and honest counts.
printf 'SANITIZER_CONFIG_FILE=%s\nLUCAIRN_SANITIZER_ROSTER_ACK_REMOVED=phone_extended\n' "$WK/shrunk.yaml" > "$WK/ack.env"
expect 0 "33 of 34 floor recognizers present; acknowledged absent: phone_extended" -- check_sanitizer_roster_floor "$WK/ack.env"

# Acknowledging a DIFFERENT name does not excuse the real gap.
printf 'SANITIZER_CONFIG_FILE=%s\nLUCAIRN_SANITIZER_ROSTER_ACK_REMOVED=vin,us_ssn\n' "$WK/shrunk.yaml" > "$WK/wrongack.env"
expect 1 "phone_extended" -- check_sanitizer_roster_floor "$WK/wrongack.env"

# A config with no custom_recognizers at all -> FAIL (every floor name missing).
printf 'sanitizer:\n  presidio:\n    default_language: de\n' > "$WK/empty.yaml"
printf 'SANITIZER_CONFIG_FILE=%s\n' "$WK/empty.yaml" > "$WK/empty.env"
expect 1 "lacks floor recognizer(s): sozialversicherungsnummer" -- check_sanitizer_roster_floor "$WK/empty.env"

# Flow-style list carrying the full floor -> ok.
{
  printf 'sanitizer:\n  presidio:\n    custom_recognizers: ['
  _sanitizer_must_have_names "$FLOOR" | paste -sd, - | sed 's/,/, /g' | tr -d '\n'
  printf ']  # flow style\n'
} > "$WK/flow.yaml"
printf 'SANITIZER_CONFIG_FILE=%s\n' "$WK/flow.yaml" > "$WK/flow.env"
expect 0 "sanitizer roster: ok" -- check_sanitizer_roster_floor "$WK/flow.env"

# A commented-out entry does not count.
sed -E 's/^([[:space:]]+)- medical_record_number$/\1# - medical_record_number/' "$COMPOSE_CFG" > "$WK/commented.yaml"
printf 'SANITIZER_CONFIG_FILE=%s\n' "$WK/commented.yaml" > "$WK/commented.env"
expect 1 "medical_record_number" -- check_sanitizer_roster_floor "$WK/commented.env"

# Positive control (Helm): a chart copy whose ConfigMap lost a floor name -> FAIL.
cp -R "$CHART" "$WK/chart"
grep -vE '^[[:space:]]+- medical_record_number$' "$CM_TEMPLATE" \
  > "$WK/chart/charts/sandbox-a/templates/sanitizer-configmap.yaml"
expect 1 "lacks floor recognizer(s): medical_record_number" -- check_sanitizer_roster_floor_helm "$WK/chart" "$WK/values.yaml"

[ "$FAILS" -eq 0 ] || fail "$FAILS doctor assertion(s) failed"
echo "T-768 sanitizer roster floor: PASS"
