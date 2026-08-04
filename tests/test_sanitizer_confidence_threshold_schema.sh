#!/usr/bin/env bash
set -euo pipefail

# T-517 — `sandbox-a.sanitizer.confidenceThreshold` is a bounded [0, 1] number.
#
# THE DEFECT this suite locks closed: the value is rendered straight into the
# sanitizer ConfigMap as `presidio.confidence_threshold`
# (charts/lucairn/charts/sandbox-a/templates/sanitizer-configmap.yaml). A value
# the detector cannot use is INVISIBLE at runtime — Presidio scores never
# exceed 1.0, so `2.0` keeps ZERO detections; every request still returns 200
# with clean-looking output and the certificate still lists `presidio_ner` in
# `layers_active`. That is a false attestation, not a degraded scan. Before
# this schema entry the chart accepted it silently and the operator's only
# signal would have been a customer noticing un-redacted PII.
#
# The bounds are the whole control, so this suite asserts BOTH directions:
# every out-of-contract shape is REFUSED at `helm template` time (direct child
# AND umbrella), and every legitimate value — including the 0 and 1 boundaries
# — still renders AND still reaches the ConfigMap.
#
# The sanitizer enforces the same bounds independently at boot
# (services/sanitizer/config.py `PresidioConfig.__post_init__`, same ticket) so
# Compose and hosted installs are covered too; this is the render-time half.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
CHILD_CHART="$CHART/charts/sandbox-a"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "T-517 confidenceThreshold schema: ERROR — $1 is required" >&2
    exit 2
  }
}

require_command helm
require_command ruby

fail() {
  echo "T-517 confidenceThreshold schema: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Diagnostic matchers.
#
# Helm has shipped two schema validators with different message formats, and
# the kit is rendered by both (CI pins helm v3.16.4 → xeipuuv/gojsonschema;
# developer machines run helm v4 → santhosh-tekuri/jsonschema). Every pattern
# below accepts either wording AND pins the FIELD, so a render that failed for
# an unrelated reason (a missing password, a template bug) cannot be mistaken
# for the schema doing its job. The table test at the bottom proves that.
# ---------------------------------------------------------------------------

schema_error_pattern() {
  case "$1" in
    maximum)
      printf "(at '/sanitizer/confidenceThreshold': maximum|sanitizer\\.confidenceThreshold: Must be less than or equal to)"
      ;;
    minimum)
      printf "(at '/sanitizer/confidenceThreshold': minimum|sanitizer\\.confidenceThreshold: Must be greater than or equal to)"
      ;;
    type)
      printf "(at '/sanitizer/confidenceThreshold': got [a-z]+, want number|sanitizer\\.confidenceThreshold: Invalid type\\. Expected: number, given: )"
      ;;
    *) echo "unknown schema error shape: $1" >&2; exit 2 ;;
  esac
}

# NaN is a special case: helm cannot even convert a YAML `.nan` to JSON, so it
# is refused BEFORE schema validation ("json: unsupported value: NaN"). Newer
# validators that do reach the schema reject it on the bounds instead — every
# comparison against NaN is false, so NaN satisfies neither `minimum` nor
# `maximum`. Both are fail-closed; accept either, and nothing else.
nan_error_pattern() {
  printf "(unsupported value: NaN|at '/sanitizer/confidenceThreshold': (maximum|minimum)|sanitizer\\.confidenceThreshold: Must be (less|greater) than or equal to)"
}

schema_diagnostic_matches() {
  grep -Eq "$(schema_error_pattern "$1")" "$2"
}

# ---------------------------------------------------------------------------
# Fixtures. The direct child render needs the same non-schema inputs every
# other direct-child suite supplies (T-10 password guard + the `global` block
# the child normally inherits from the umbrella).
# ---------------------------------------------------------------------------

write_child_values() {
  local threshold_line="$1"
  {
    cat <<YAML
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
  l3Required: false
  nodeIsolation: false
  mtls:
    enabled: false
sanitizer:
YAML
    [ -z "$threshold_line" ] || printf '  confidenceThreshold: %s\n' "$threshold_line"
    printf '  safePatterns: []\n'
  } >"$TMPDIR/child-values.yaml"
}

render_child() {
  helm template sandbox-a "$CHILD_CHART" -f "$TMPDIR/child-values.yaml"
}

assert_child_rejected() {
  local name="$1" shape="$2" value="$3"
  write_child_values "$value"
  if render_child >"$TMPDIR/$name.out" 2>&1; then
    fail "accepted invalid confidenceThreshold ($name = $value)"
  fi
  schema_diagnostic_matches "$shape" "$TMPDIR/$name.out" || {
    cat "$TMPDIR/$name.out" >&2
    fail "$name did not report the expected $shape schema error"
  }
}

assert_child_accepted() {
  local name="$1" value="$2" expected="$3"
  write_child_values "$value"
  render_child >"$TMPDIR/render-$name.yaml" 2>"$TMPDIR/render-$name.err" || {
    cat "$TMPDIR/render-$name.err" >&2
    fail "rejected VALID confidenceThreshold ($name = $value)"
  }
  # The bound is worthless if the value never reaches the sanitizer. Assert the
  # rendered ConfigMap actually carries it.
  ruby -ryaml -e '
    documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    cm = documents.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "sanitizer-config" } \
      || abort("render misses ConfigMap/sanitizer-config")
    body = cm.fetch("data").values.find { |v| v.include?("confidence_threshold") } \
      || abort("sanitizer ConfigMap carries no confidence_threshold")
    parsed = YAML.safe_load(body).dig("sanitizer", "presidio", "confidence_threshold")
    expected = Float(ARGV.fetch(1))
    abort "confidence_threshold drift: rendered #{parsed.inspect}, expected #{expected}" unless Float(parsed) == expected
  ' "$TMPDIR/render-$name.yaml" "$expected"
}

# ---------------------------------------------------------------------------
# 1. Refusals — direct child chart.
# ---------------------------------------------------------------------------

assert_child_rejected above-one      maximum '2.0'
assert_child_rejected just-above-one maximum '1.0001'
assert_child_rejected negative       minimum '-0.1'
# A quoted decimal reads as valid to a human but is a STRING to Helm. The
# chart pipes it through `| default 0.35` unquoted, so it happened to work —
# which is exactly why it must be pinned now: the contract is a number.
assert_child_rejected quoted-string  type    '"0.35"'
assert_child_rejected word           type    '"high"'
# `true` would coerce to 1.0 in the sanitizer and keep almost nothing.
assert_child_rejected boolean        type    'true'
assert_child_rejected list           type    '[]'
assert_child_rejected map            type    '{}'

# NaN — see nan_error_pattern above for why this one is matched separately.
write_child_values '.nan'
if render_child >"$TMPDIR/nan.out" 2>&1; then
  fail "accepted a NaN confidenceThreshold"
fi
grep -Eq "$(nan_error_pattern)" "$TMPDIR/nan.out" || {
  cat "$TMPDIR/nan.out" >&2
  fail "NaN was refused, but not for a confidenceThreshold/NaN reason"
}

# ---------------------------------------------------------------------------
# 2. Controls — every legitimate value still renders AND still lands in the
#    ConfigMap. A bound that also rejects the shipped default is not a fix.
# ---------------------------------------------------------------------------

assert_child_accepted shipped-default '0.35' '0.35'
assert_child_accepted boundary-one    '1'    '1'
assert_child_accepted typical         '0.3'  '0.3'

# The 0 boundary is ACCEPTED by the schema — the sanitizer's own contract is
# [0, 1] and a chart that refused a value the service accepts would be a
# divergence, not a guard.
#
# ⚠️ PRE-EXISTING, OUT OF SCOPE HERE (found while writing this suite, reported
# with the PR): the template renders `{{ .Values.sanitizer.confidenceThreshold
# | default 0.35 }}`, and Go templates treat 0 as EMPTY, so `0` is silently
# rewritten to the 0.35 default instead of reaching the sanitizer. An operator
# asking for "keep every detection" quietly gets the shipped default. That is a
# TEMPLATE defect (`default` vs `hasKey`), not a schema one, and fixing it
# touches the render path this PR deliberately does not. Pinned here so the
# behaviour is recorded and a later fix has a test that must be updated
# ON PURPOSE rather than a silent change.
write_child_values '0'
render_child >"$TMPDIR/render-boundary-zero.yaml" 2>"$TMPDIR/render-boundary-zero.err" || {
  cat "$TMPDIR/render-boundary-zero.err" >&2
  fail "schema rejected the VALID 0 boundary"
}
grep -q "confidence_threshold: 0.35" "$TMPDIR/render-boundary-zero.yaml" \
  || fail "the documented \`default\` truthiness quirk for 0 changed — re-read the comment above and update this assertion deliberately"

# Omitting the key entirely must keep working — the template's `| default 0.35`
# is the pre-existing contract and this schema entry does not make the key
# required.
write_child_values ''
render_child >"$TMPDIR/render-omitted.yaml" 2>"$TMPDIR/render-omitted.err" || {
  cat "$TMPDIR/render-omitted.err" >&2
  fail "rejected a values file that omits confidenceThreshold"
}
grep -q "confidence_threshold: 0.35" "$TMPDIR/render-omitted.yaml" \
  || fail "omitted confidenceThreshold no longer falls back to the 0.35 default"

# The chart's own checked-in default must satisfy its own schema.
ruby -ryaml -e '
  value = YAML.load_file(ARGV.fetch(0)).dig("sanitizer", "confidenceThreshold")
  abort "values.yaml sanitizer.confidenceThreshold must be a number, got #{value.inspect}" unless value.is_a?(Numeric)
  abort "values.yaml sanitizer.confidenceThreshold #{value} is outside [0, 1]" unless value >= 0 && value <= 1
' "$CHILD_CHART/values.yaml"

# ---------------------------------------------------------------------------
# 3. Umbrella path — the schema must bind through `--set sandbox-a.…` too,
#    which is how an operator actually tunes this (PRD B6 success criterion).
# ---------------------------------------------------------------------------

umbrella_render() {
  helm template lucairn "$CHART" \
    "${HELM_TEST_SECRET_ARGS[@]}" \
    --set global.skipPullSecretGuard=true \
    --set-string "veil-witness.secrets.values.signingKey=$TEST_SIGNING_KEY" \
    "$@"
}

# `helm --set` cannot produce a float: strvals parses an integer as int64 and
# leaves EVERYTHING else a string, so `--set …=2.0` arrives as the string
# "2.0". That is still refused — by `type` rather than by `maximum` — and the
# integer form `--set …=2` exercises the bound itself. Both are asserted so a
# future schema edit cannot close one door and leave the other open.
if umbrella_render --set sandbox-a.sanitizer.confidenceThreshold=2.0 \
    >"$TMPDIR/umbrella-invalid-str.out" 2>&1; then
  fail "umbrella accepted confidenceThreshold=2.0"
fi
schema_diagnostic_matches type "$TMPDIR/umbrella-invalid-str.out" || {
  cat "$TMPDIR/umbrella-invalid-str.out" >&2
  fail "umbrella refusal of --set 2.0 did not name the confidenceThreshold type"
}

if umbrella_render --set sandbox-a.sanitizer.confidenceThreshold=2 \
    >"$TMPDIR/umbrella-invalid-num.out" 2>&1; then
  fail "umbrella accepted confidenceThreshold=2"
fi
schema_diagnostic_matches maximum "$TMPDIR/umbrella-invalid-num.out" || {
  cat "$TMPDIR/umbrella-invalid-num.out" >&2
  fail "umbrella refusal of --set 2 did not name the confidenceThreshold maximum"
}

# The supported way to express a float override — a values file, or --set-json.
umbrella_render --set-json 'sandbox-a.sanitizer.confidenceThreshold=0.35' \
  >"$TMPDIR/umbrella-valid.yaml" 2>"$TMPDIR/umbrella-valid.err" || {
  cat "$TMPDIR/umbrella-valid.err" >&2
  fail "umbrella rejected confidenceThreshold=0.35 via --set-json"
}
grep -q "confidence_threshold: 0.35" "$TMPDIR/umbrella-valid.yaml" \
  || fail "umbrella render did not carry confidence_threshold: 0.35"

# Control: the default umbrella render (nobody touches the key) still works.
umbrella_render >"$TMPDIR/umbrella-default.yaml" 2>"$TMPDIR/umbrella-default.err" || {
  cat "$TMPDIR/umbrella-default.err" >&2
  fail "umbrella render broke with the schema entry in place"
}
grep -q "confidence_threshold: 0.35" "$TMPDIR/umbrella-default.yaml" \
  || fail "default umbrella render lost confidence_threshold: 0.35"

# ---------------------------------------------------------------------------
# 4. Matcher self-test — the assertions above are only worth something if the
#    patterns cannot be satisfied by an unrelated Helm failure. A guard that
#    cannot fail closed is decoration.
# ---------------------------------------------------------------------------

table="$TMPDIR/diagnostic-table.txt"

while IFS='|' read -r shape line; do
  [ -n "$shape" ] || continue
  printf '%s\n' "$line" >"$table"
  schema_diagnostic_matches "$shape" "$table" \
    || fail "diagnostic table rejected a real $shape message: $line"
done <<'TABLE'
maximum|- at '/sanitizer/confidenceThreshold': maximum: got 2, want 1
maximum|- sanitizer.confidenceThreshold: Must be less than or equal to 1
minimum|- at '/sanitizer/confidenceThreshold': minimum: got -0.1, want 0
minimum|- sanitizer.confidenceThreshold: Must be greater than or equal to 0
type|- at '/sanitizer/confidenceThreshold': got string, want number
type|- at '/sanitizer/confidenceThreshold': got boolean, want number
type|- sanitizer.confidenceThreshold: Invalid type. Expected: number, given: string
TABLE

for negative in \
  "Error: chart dependency is missing" \
  "- at '/ephemeral': got boolean, want string" \
  "- sandbox-a/templates/_validate.tpl: adminPassword must not be empty" \
  "- at '/sanitizer/qiEngineThreshold': maximum: got 2, want 1"
do
  printf '%s\n' "$negative" >"$table"
  for shape in maximum minimum type; do
    ! schema_diagnostic_matches "$shape" "$table" \
      || fail "diagnostic table accepted an unrelated failure as $shape: $negative"
  done
done

printf '%s\n' "Error: chart dependency is missing" >"$table"
! grep -Eq "$(nan_error_pattern)" "$table" \
  || fail "NaN matcher accepted an unrelated failure"

echo "T-517 confidenceThreshold schema: PASS"
