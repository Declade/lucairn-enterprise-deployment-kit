#!/usr/bin/env bash
set -uo pipefail

# T-768 round 2 — the `lucairn doctor` sanitizer-roster check must FAIL CLOSED.
#
# Each case below is a reproduction from the gpt-6.1-sol review of kit PR #143
# (head 34129b4). Every case FAILED against 34129b4's bin/lucairn: the doctor
# check read the first textual `custom_recognizers:` match, skipped a missing
# config with rc 0, let the acknowledgement variable excuse a file it could not
# read, ignored an exported SANITIZER_CONFIG_FILE, counted the words of an
# inline comment as acknowledgements, and skipped the Helm check on a combined
# `doctor --env … --values …` run. This file pins the fixed behaviour. Cases
# named `control-*` are positive controls that pass on both heads; every other
# case is a repro that fails on 34129b4.
#
# All fixtures are synthetic: generated rosters and dummy secret values.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
FLOOR="$ROOT/config/sanitizer-roster-must-have.txt"
CM_TEMPLATE="$CHART/charts/sandbox-a/templates/sanitizer-configmap.yaml"

# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

WK="$(mktemp -d)"
cleanup() { rm -rf "$WK"; }
trap cleanup EXIT

# shellcheck disable=SC1090
source "$ROOT/bin/lucairn" >/dev/null 2>&1
set +e +u +o pipefail

FLOOR_NAMES="$(sed -e 's/#.*$//' -e 's/[[:space:]]//g' "$FLOOR" | grep -v '^$')"
M="$(printf '%s\n' "$FLOOR_NAMES" | wc -l | tr -d ' ')"

# block_list INDENT [EXCLUDE...] — the floor as a block sequence.
block_list() {
  local indent="$1" name skip x
  shift
  for name in $FLOOR_NAMES; do
    skip=0
    for x in "$@"; do [ "$name" = "$x" ] && skip=1; done
    [ "$skip" -eq 1 ] || printf '%s- %s\n' "$indent" "$name"
  done
}

FAILS=0
PASSES=0
# check CASE WANT_RC NEEDLE [ABSENT_NEEDLE] -- CMD...
check() {
  local case_name="$1" want_rc="$2" needle="$3" absent="" out rc
  shift 3
  if [ "$1" != "--" ]; then absent="$1"; shift; fi
  shift
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL [$case_name]: rc=$rc want=$want_rc" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2
    FAILS=$((FAILS + 1)); return
  fi
  if ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL [$case_name]: output lacks '$needle'" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2
    FAILS=$((FAILS + 1)); return
  fi
  if [ -n "$absent" ] && printf '%s' "$out" | grep -qF -- "$absent"; then
    echo "FAIL [$case_name]: output contains '$absent'" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2
    FAILS=$((FAILS + 1)); return
  fi
  PASSES=$((PASSES + 1))
  echo "ok [$case_name]"
}

envfile() {  # envfile NAME CONFIG [EXTRA_LINE]
  { printf 'SANITIZER_CONFIG_FILE=%s\n' "$2"; [ -z "${3:-}" ] || printf '%s\n' "$3"; } > "$WK/$1.env"
  printf '%s' "$WK/$1.env"
}

# A complete, valid roster (the reference good file).
{ printf 'sanitizer:\n  presidio:\n    default_language: de\n    custom_recognizers:\n'; block_list '      '; } > "$WK/full.yaml"
check control-full-roster-ok 0 "sanitizer roster: ok" -- check_sanitizer_roster_floor "$(envfile full "$WK/full.yaml")"

# --- P1-a: structural parse, not the first textual match ---------------------

# R1: a decoy roster inside a block scalar comes first; the real roster lacks
# phone_extended. 34129b4 read the decoy and passed.
{
  printf 'sanitizer:\n  notes: |\n    presidio:\n      custom_recognizers:\n'
  block_list '        '
  printf '  presidio:\n    custom_recognizers:\n'
  block_list '      ' phone_extended
} > "$WK/decoy-block-scalar.yaml"
check first-match-decoy-block-scalar 1 "phone_extended" -- \
  check_sanitizer_roster_floor "$(envfile decoy1 "$WK/decoy-block-scalar.yaml")"

# R2: a decoy roster under the wrong parent (sanitizer.llm_scan) comes first.
{
  printf 'sanitizer:\n  llm_scan:\n    custom_recognizers: ['
  printf '%s\n' "$FLOOR_NAMES" | paste -sd, - | tr -d '\n'
  printf ']\n  presidio:\n    custom_recognizers:\n'
  block_list '      ' phone_extended
} > "$WK/decoy-wrong-parent.yaml"
check first-match-decoy-wrong-parent 1 "phone_extended" -- \
  check_sanitizer_roster_floor "$(envfile decoy2 "$WK/decoy-wrong-parent.yaml")"

# R2b (sol's exact repro): the whole floor under diagnostics.custom_recognizers
# and an EMPTY sanitizer.presidio.custom_recognizers.
{
  printf 'diagnostics:\n  custom_recognizers:\n'; block_list '    '
  printf 'sanitizer:\n  presidio:\n    custom_recognizers: []\n'
} > "$WK/sol-diagnostics.yaml"
check sol-diagnostics-decoy 1 "lacks floor recognizer(s)" -- \
  check_sanitizer_roster_floor "$(envfile soldiag "$WK/sol-diagnostics.yaml")"

# R3: a duplicate top-level `sanitizer:` mapping. PyYAML (the pinned
# sanitizer's loader) keeps the LAST one; 34129b4 read the first. Ambiguous ->
# FAIL.
{
  printf 'sanitizer:\n  presidio:\n    custom_recognizers:\n'; block_list '      '
  printf 'sanitizer:\n  presidio:\n    custom_recognizers:\n'; block_list '      ' phone_extended
} > "$WK/dup-sanitizer.yaml"
check duplicate-sanitizer-mapping 1 "duplicate key sanitizer" -- \
  check_sanitizer_roster_floor "$(envfile dup "$WK/dup-sanitizer.yaml")"

# R4: invalid YAML after a complete roster -> FAIL (the sanitizer refuses it).
{ cat "$WK/full.yaml"; printf '    supported_languages: [de, en\n'; } > "$WK/invalid.yaml"
check invalid-yaml-fails 1 "cannot read" -- \
  check_sanitizer_roster_floor "$(envfile invalid "$WK/invalid.yaml")"

# R4b (sol's exact repro): `broken: [` appended to the SHIPPED config.
{ cat "$ROOT/config/default-sanitizer.yaml"; printf 'broken: [\n'; } > "$WK/sol-broken.yaml"
check sol-shipped-plus-broken-trailer 1 "cannot read" -- \
  check_sanitizer_roster_floor "$(envfile solbroken "$WK/sol-broken.yaml")"

# R5: a valid MULTI-LINE flow list carrying the whole floor is accepted.
{
  printf 'sanitizer:\n  presidio:\n    custom_recognizers: [\n'
  printf '%s\n' "$FLOOR_NAMES" | sed 's/^/      /; s/$/,  # entry/'
  printf '    ]\n'
} > "$WK/flow-multiline.yaml"
check multiline-flow-list-ok 0 "sanitizer roster: ok" -- \
  check_sanitizer_roster_floor "$(envfile flowml "$WK/flow-multiline.yaml")"

# R6: duplicate roster entries -> at least a WARN.
{ cat "$WK/full.yaml"; printf '      - vin\n'; } > "$WK/dup-entry.yaml"
check duplicate-roster-entry-warns 0 "duplicate roster entr" -- \
  check_sanitizer_roster_floor "$(envfile dupentry "$WK/dup-entry.yaml")"

# --- P1-b: a missing file or a read failure is never a skip, never acked ----

# R7: the active config file does not exist -> FAIL (34129b4: "skip", rc 0).
check missing-config-fails 1 "not found" -- \
  check_sanitizer_roster_floor "$(envfile missing "$WK/does-not-exist.yaml")"

ACK_ALL="LUCAIRN_SANITIZER_ROSTER_ACK_REMOVED=$(printf '%s\n' "$FLOOR_NAMES" | paste -sd, -)"
# R8: acknowledging every floor name cannot turn a missing file into success.
check ack-cannot-mask-missing-file 1 "not found" -- \
  check_sanitizer_roster_floor "$(envfile ackmissing "$WK/does-not-exist.yaml" "$ACK_ALL")"
# R9: ...nor an unparseable file (34129b4 read zero names, acked all, rc 0).
printf 'sanitizer: [\n' > "$WK/garbage.yaml"
check ack-cannot-mask-parse-failure 1 "cannot read" -- \
  check_sanitizer_roster_floor "$(envfile ackgarbage "$WK/garbage.yaml" "$ACK_ALL")"

# --- P1-c: the config Compose will actually mount ---------------------------

# R10: customer.env points at the complete file, but an EXPORTED
# SANITIZER_CONFIG_FILE (Compose: shell env beats --env-file) points at a
# shrunk one. Doctor must check the shrunk one and say which file it read.
{ printf 'sanitizer:\n  presidio:\n    custom_recognizers:\n'; block_list '      ' phone_extended; } > "$WK/shrunk.yaml"
exported_divergence() {
  ( export SANITIZER_CONFIG_FILE="$WK/shrunk.yaml"; check_sanitizer_roster_floor "$1" )
}
check exported-config-file-wins 1 "$WK/shrunk.yaml" -- exported_divergence "$(envfile exported "$WK/full.yaml")"
check exported-config-file-names-gap 1 "phone_extended" -- exported_divergence "$(envfile exported2 "$WK/full.yaml")"
# R10b (sol's exact repro): exported SANITIZER_CONFIG_FILE -> the ITSM starter
# template (no roster at the required path) while the env file names the
# shipped default.
exported_starter() {
  ( export SANITIZER_CONFIG_FILE="$ROOT/starter-templates/itsm/config.yaml"; check_sanitizer_roster_floor "$1" )
}
check sol-exported-starter-itsm 1 "starter-templates/itsm/config.yaml" -- \
  exported_starter "$(envfile starter "$ROOT/config/default-sanitizer.yaml")"
# R10c: the sanitizer reads SANITIZER_CONFIG_PATH; pointing it away from the
# mounted /config/config.yaml means doctor would check the wrong file -> FAIL.
check config-path-override-fails 1 "SANITIZER_CONFIG_PATH" -- \
  check_sanitizer_roster_floor "$(envfile cfgpath "$WK/full.yaml" 'SANITIZER_CONFIG_PATH=/config/other.yaml')"

# --- P2-a: ack parsing and honest wording -----------------------------------

{ printf 'sanitizer:\n  presidio:\n    custom_recognizers:\n'; block_list '      ' phone_extended vin; } > "$WK/shrunk2.yaml"
# R11: `vin # phone_extended` acknowledges ONLY vin.
check inline-comment-ack 1 "phone_extended" -- \
  check_sanitizer_roster_floor "$(envfile ackcomment "$WK/shrunk2.yaml" 'LUCAIRN_SANITIZER_ROSTER_ACK_REMOVED=vin # phone_extended')"
# R12: an acknowledged removal says "N of M present", never "carries all".
{ printf 'sanitizer:\n  presidio:\n    custom_recognizers:\n'; block_list '      ' vin; } > "$WK/shrunk-vin.yaml"
check acked-wording "$((0))" "$((M - 1)) of $M floor recognizers present; acknowledged absent: vin" "carries all" -- \
  check_sanitizer_roster_floor "$(envfile ackvin "$WK/shrunk-vin.yaml" 'LUCAIRN_SANITIZER_ROSTER_ACK_REMOVED=vin')"

# --- P2-b: the Helm side -----------------------------------------------------

VALUES="$WK/values.yaml"
cat > "$VALUES" <<EOF
admin: {secrets: {values: {adminPassword: "${TEST_SECRET_VALUE}"}}}
audit: {secrets: {values: {postgresPassword: "${TEST_SECRET_VALUE}", auditAppPassword: "${TEST_SECRET_VALUE}"}}}
id-bridge: {secrets: {values: {postgresPassword: "${TEST_SECRET_VALUE}"}}}
observability: {secrets: {values: {grafanaAdminPassword: "${TEST_SECRET_VALUE}"}}}
sandbox-a: {secrets: {values: {postgresPassword: "${TEST_SECRET_VALUE}"}}}
veil-witness: {secrets: {values: {postgresPassword: "${TEST_SECRET_VALUE}", veilAppPassword: "${TEST_SECRET_VALUE}"}}}
EOF
printf 'sandbox-a:\n  enabled: false\n' > "$WK/no-sandbox-a.yaml"

# R13: the Helm check reads the RENDERED chart.
check helm-rendered-ok 0 "rendered" -- check_sanitizer_roster_floor_helm "$CHART" "$VALUES"
# R14: sandbox-a really disabled -> explicit skip, rc 0.
check helm-sandbox-a-disabled 0 "sandbox-a disabled — no sanitizer ConfigMap rendered" -- \
  check_sanitizer_roster_floor_helm "$CHART" "$VALUES" "$WK/no-sandbox-a.yaml"
# R15: a chart whose sanitizer ConfigMap template is missing -> FAIL
# (34129b4: "not found (skip)", rc 0).
cp -R "$CHART" "$WK/chart-no-cm"
rm -f "$WK/chart-no-cm/charts/sandbox-a/templates/sanitizer-configmap.yaml"
check helm-missing-template-fails 1 "FAIL" -- check_sanitizer_roster_floor_helm "$WK/chart-no-cm" "$VALUES"
# R16: no helm on PATH -> fall back to the raw template and SAY so.
without_helm() {
  ( have() { [ "$1" != helm ] && command -v "$1" >/dev/null 2>&1; }; check_sanitizer_roster_floor_helm "$@" )
}
check helm-unavailable-fallback 0 "helm not available" -- without_helm "$CHART" "$VALUES"
cp -R "$CHART" "$WK/chart-shrunk"
grep -vE '^[[:space:]]+- phone_extended$' "$CM_TEMPLATE" > "$WK/chart-shrunk/charts/sandbox-a/templates/sanitizer-configmap.yaml"
check control-helm-rendered-gap-fails 1 "phone_extended" -- check_sanitizer_roster_floor_helm "$WK/chart-shrunk" "$VALUES"
check control-helm-raw-gap-fails 1 "phone_extended" -- without_helm "$WK/chart-shrunk" "$VALUES"

# R17: a combined `doctor --env … --values …` run executes BOTH roster checks.
DEV_ENV="$WK/dev.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name fixture-local-model --model-file fixture.gguf --model-path . \
  --output "$DEV_ENV" --skip-doctor >/dev/null 2>&1 \
  || { echo "FAIL: lucairn-init --dev could not write the fixture env" >&2; exit 1; }
combined() { ( unset SANITIZER_CONFIG_FILE; "$ROOT/bin/lucairn" doctor --env "$DEV_ENV" --values "$@" --offline --skip-image-check ); }
# One full doctor run is ~45 s; run it once and assert on its saved output.
combined "$VALUES" > "$WK/combined.out" 2>&1
echo "$?" > "$WK/combined.rc"
saved_combined() { cat "$WK/combined.out"; return "$(cat "$WK/combined.rc")"; }
check combined-runs-helm-check 0 "sanitizer roster (Helm)" -- saved_combined
check control-combined-runs-compose-check 0 "sanitizer roster: ok" -- saved_combined
check combined-helm-sandbox-a-disabled 0 "sandbox-a disabled — no sanitizer ConfigMap rendered" -- \
  combined "$VALUES" --values "$WK/no-sandbox-a.yaml"

echo "T-768 doctor roster repros: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ] || exit 1
echo "T-768 doctor roster repros: PASS"
