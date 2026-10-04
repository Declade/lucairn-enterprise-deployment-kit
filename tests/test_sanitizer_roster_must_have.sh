#!/usr/bin/env bash
set -euo pipefail

# T-768 — the sanitizer recognizer roster may not shrink or drift silently.
#
# THE DEFECT: the kit's two roster surfaces (Compose config/default-sanitizer.yaml
# and the Helm sandbox-a sanitizer ConfigMap) sat at 33 recognizers while the
# upstream sanitizer default grew to 46. Nothing noticed: a recognizer that is
# not listed is simply never loaded, and the sanitizer boots and answers
# normally. Kit 1.9.4 shipped 34 (33 + medical_record_number); kit 1.9.5 pins
# the 0.5.5 sanitizer, which registers attribution_person and labeled_id, and
# ships 36. The floor is those 36.
#
# WHAT THIS PROVES:
#   1. Both shipped surfaces carry every name in
#      config/sanitizer-roster-must-have.txt (the floor), checked on the
#      RENDERED Helm ConfigMap and on the Compose file, parsed as YAML.
#   2. The two surfaces carry the SAME roster (no silent drift between them).
#   3. The deliberately-absent names (not in the pinned image, held back for
#      false positives, opt-in only, or no-ops on the pinned image) are absent
#      from both surfaces and from the floor.
#   4. POSITIVE CONTROL: the same check FAILS when one floor name is removed
#      from a copy of the Compose file (so a green run is not vacuous).
#
# There is deliberately NO runtime `lucairn doctor` roster check: a round-2
# attempt (a Python-free YAML subset reader) could be made to report a full
# roster while the sanitizer's real loader got none (escaped keys, non-LF line
# breaks, .env grammar variants, Helm value injection). A doctor check must ask
# the pinned sanitizer image's own loader — tracked as a follow-up.
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
roster_check() {
python3 - "$1" "$2" "$FLOOR" "$WK" <<'PY'
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
# pins the 0.5.5 sanitizer image: (b) bare-shape ID recognizers held back for
# false positives (the two-lane zoner that keeps sys_ids/UUIDs/INC ids intact
# is off by default and not enabled by the kit); (c) opt-in only for
# healthcare/clinical installs (ordinary-word false positives at 0.35); (d)
# no-ops on 0.5.5 (entity type discarded by the scanner). The former (a) set —
# names 0.5.4 did not register — is empty on 0.5.5: attribution_person and
# labeled_id are now in the floor, patientennummer_id_prefix moved to (b).
HELD_BACK_FP = {"format_ticket", "format_numeric_run", "format_hex_block",
                "format_uuid", "format_ulid", "patientennummer_id_prefix"}
OPT_IN_ONLY = {"de_places", "drugs_and_diagnoses"}
NO_OP_ON_PINNED = {"de_companies", "software_products"}
ABSENT = HELD_BACK_FP | OPT_IN_ONLY | NO_OP_ON_PINNED
EXPECTED_FLOOR_SIZE = 36

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

}

roster_check "$WK/render.yaml" "$COMPOSE_CFG" || fail "roster check failed on the shipped surfaces"

# ---------------------------------------------------------------------------
# 4. Positive control: drop ONE floor name from a copy of the Compose file.
# ---------------------------------------------------------------------------
grep -vE '^[[:space:]]+- phone_extended$' "$COMPOSE_CFG" > "$WK/shrunk.yaml"
grep -qE '^[[:space:]]+- phone_extended$' "$WK/shrunk.yaml" && fail "control did not remove phone_extended"
if roster_check "$WK/render.yaml" "$WK/shrunk.yaml" 2>"$WK/control.err"; then
  fail "positive control: the check PASSED on a roster missing phone_extended"
fi
grep -q "phone_extended" "$WK/control.err" || { cat "$WK/control.err" >&2; fail "positive control failed for the wrong reason"; }
echo "ok: positive control — removing phone_extended makes the check fail"

echo "T-768 sanitizer roster floor: PASS"
