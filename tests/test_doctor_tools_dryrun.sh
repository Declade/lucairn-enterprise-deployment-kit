#!/usr/bin/env bash
#
# T-498 — `lucairn doctor --tools`, the tool-schema-guard dry-run.
#
# PRD: specs/2026-08/prd-2026-08-04-kit-release-readiness-t14-residuals.md,
# Slice B4.  Success criterion: "`bin/lucairn doctor --tools` against a fixture
# tools payload reports would-be refusals without any routed turn."
#
# WHY THIS SUITE IS WORTH HAVING
# ------------------------------
# The kit ships GATEWAY_TOOL_SCHEMA_GUARD=refuse (T-493).  The gateway
# therefore 400s the FIRST routed turn that carries a PII-shaped tool
# declaration, with no observation window.  `doctor --tools` is the safety
# valve that lets an operator find that out offline instead of in production —
# so the thing that must be pinned is not "the command runs" but "the command
# agrees with the shipped guard".  A dry-run that disagrees with the control it
# predicts is worse than no dry-run: it manufactures confidence.
#
# THE FOUR CASES THE PRD NAMES, and what each one is a control FOR:
#
#   clean.json                  a realistic ServiceNow-shaped tool pair with
#                               7-digit incident numbers, epoch bounds and
#                               enums -> 0 findings, exit 0.  If this ever goes
#                               red the guard has become unusable in practice,
#                               which is the attrition failure the whole T-14
#                               design is written to avoid.
#
#   iban-in-default.json        a mod-97-VALID, obviously synthetic IBAN
#                               (DE36 + twenty zeroes — a real IBAN cannot have
#                               an all-zero BBAN, and the check digits are
#                               computed so the CHECKSUM branch is what fires,
#                               not the shape branch) baked into a `default`.
#                               Refused in refuse AND refuse_high_confidence.
#
#   sysid-in-description.json   THE FALSE-POSITIVE CLASS THIS TICKET EXISTS
#                               FOR.  `ab12cd34ef56ab78cd90ef12ab34cd56` is a
#                               32-hex ServiceNow-style sys_id that MATCHES THE
#                               IBAN SHAPE (two letters, two digits, 32 chars —
#                               ~5.5% of sys_ids do) and fails ISO 7064 mod-97.
#                               Before T-497 this payload was REFUSED; after it
#                               it is clean.  This case is therefore a positive
#                               control for T-497, not decoration: revert the
#                               checksum gate and it goes red.
#
#   digit-run-in-enum.json      a 13-digit run in an `enum` (instance data, so
#                               the prose exemption does not apply).  Refused
#                               under `refuse`, only OBSERVED under
#                               `refuse_high_confidence`.  This is the case that
#                               proves the two modes are actually different — a
#                               port that ignored the mode would pass every
#                               other case in this file.
#
# DIFFERENTIAL PINS (the part that makes the rest trustworthy)
# -----------------------------------------------------------
# bin/lucairn-tool-schema-guard.py is a PORT.  Ports drift.  The expectations
# in the `differential pins` block below were not reasoned out — they were
# MEASURED by running the real Go guard
# (dual-sandbox-architecture services/gateway/internal/api, origin/main
# 08e1afb6b, functions scanDeclaredToolSchemas +
# scanDeclaredToolSchemasWithPolicy) over the same bytes and recording BOTH its
# permissive and its strict verdict.  57 hand-built adversarial cases and 7000
# randomised payloads were compared this way: 0 disagreements on kind, matcher,
# detail or pointer skeleton, on either walk.  The subset pinned here is the
# part that a customer/CI box can re-check without a Go toolchain or the DSA
# source.
#
# ⚑ THE FIRST VERSION OF THAT MEASUREMENT WAS GREEN AND WRONG, and the reason
# is worth carrying: the port modelled `refuse_high_confidence` as a PREDICATE
# over the permissive walk's findings ("everything except the digit-run ones")
# instead of running the gateway's actual second walk.  3000 randomised
# payloads agreed, because the generator's numeric literals never combined the
# two properties that separate the models — a 10+-digit run in the LITERAL and
# a decimal expansion past 1024 digits.  `12345678901e999999999` is a
# low-confidence digit-run hit permissively and a fail-closed `bounds_exceeded`
# REFUSAL strictly, so the predicate reported CLEAN where the gateway 400s.  A
# corpus that cannot express the difference between two models cannot
# distinguish them, and green over such a corpus is not evidence.  The
# `refuse_high_confidence_*` pins below are that class, pinned by name.
#
# To re-measure after any upstream guard change, add a throwaway
# package-`api` test that prints `%s|%s|%s|%s` of Kind/MatcherClass/Detail/
# LogPointer for BOTH scanDeclaredToolSchemas and
# scanDeclaredToolSchemasWithPolicy(raw, false), and diff it against this file.
#
# No Docker, no network, no cluster.  Requires python3 (already a declared
# doctor dependency — see doctor_python3_path).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/tool-schemas"
LUCAIRN="$ROOT/bin/lucairn"

WK="$(mktemp -d)"
trap 'rm -rf "$WK"' EXIT

FAILS=0
N=0

pass() { N=$((N + 1)); printf 'ok   %s\n' "$1"; }
bad() { N=$((N + 1)); FAILS=$((FAILS + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not on PATH; doctor --tools cannot run" >&2
  exit 0
fi

# run_tools <expected_exit> <name> [extra args...] — run `doctor --tools`,
# capture combined output into $OUT, assert the exit code.
OUT=""
run_tools() {
  local want="$1" name="$2"
  shift 2
  local rc=0
  OUT="$("$LUCAIRN" doctor --tools "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne "$want" ]; then
    bad "$name (exit)" "expected exit $want, got $rc; output: $OUT"
    return 1
  fi
  pass "$name (exit $want)"
  return 0
}

expect_out() {
  local name="$1" needle="$2"
  case "$OUT" in
    *"$needle"*) pass "$name" ;;
    *) bad "$name" "missing from output: $needle" ;;
  esac
}

expect_not_out() {
  local name="$1" needle="$2"
  case "$OUT" in
    *"$needle"*) bad "$name" "output must NOT contain: $needle" ;;
    *) pass "$name" ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. clean payload -> 0 findings, exit 0, in every mode
# ---------------------------------------------------------------------------
for mode in refuse refuse_high_confidence log; do
  if run_tools 0 "clean/$mode" --tools-file "$FIX/clean.json" --tools-mode "$mode"; then
    expect_out "clean/$mode reports zero findings" "0 finding(s); 0 would 400 under \`refuse\`"
    expect_out "clean/$mode terminal ok" "doctor: preflight ok (tool-schema guard)"
  fi
done

# ---------------------------------------------------------------------------
# 2. synthetic IBAN in a `default` -> refused in BOTH refuse modes, forwarded
#    under log. Pinned matcher: IBAN (Go: pii_shape|IBAN|string value).
# ---------------------------------------------------------------------------
if run_tools 1 "iban/refuse" --tools-file "$FIX/iban-in-default.json" --tools-mode refuse; then
  expect_out "iban matcher class is IBAN" "matcher=IBAN"
  expect_out "iban refused under both refuse modes" "refused under: refuse, refuse_high_confidence"
  expect_out "iban location is the default keyword" "/default"
  expect_out "iban FAIL verdict names the mode" "FAIL (mode \`refuse\` would reject"
fi
run_tools 1 "iban/refuse_high_confidence" --tools-file "$FIX/iban-in-default.json" --tools-mode refuse_high_confidence || true
if run_tools 0 "iban/log" --tools-file "$FIX/iban-in-default.json" --tools-mode log; then
  expect_out "iban under log is an observation" "1 finding(s); 1 would 400 under \`refuse\`"
  expect_out "iban under log still exits ok" "would forward this tools payload"
fi

# THE VALUE IS NEVER PRINTED — the shipped guard withholds it, and a diagnostic
# that echoed it would make itself the PII surface the guard exists to prevent.
run_tools 1 "iban/no-value-leak" --tools-file "$FIX/iban-in-default.json" --tools-mode refuse || true
expect_not_out "iban value never printed (skeleton mode)" "DE36000000000000000000"
run_tools 1 "iban/no-value-leak-revealed" --tools-file "$FIX/iban-in-default.json" --tools-mode refuse --reveal-pointers || true
expect_not_out "iban value never printed (--reveal-pointers)" "DE36000000000000000000"
expect_out "--reveal-pointers names the property" "/properties/creditor_account/default"
run_tools 1 "iban/skeleton-default" --tools-file "$FIX/iban-in-default.json" --tools-mode refuse || true
expect_not_out "skeleton mode hides the property name" "creditor_account"
expect_out "skeleton mode fingerprints the property name" "<k:"

# ---------------------------------------------------------------------------
# 3. 32-hex sys_id in a `description` -> NOT refused (the FP class is handled).
#    POSITIVE CONTROL FOR T-497: this exact string matches the IBAN SHAPE, so
#    before the mod-97 gate landed the same payload was a REFUSAL.
# ---------------------------------------------------------------------------
SYSID="ab12cd34ef56ab78cd90ef12ab34cd56"
if ! printf '%s' "$SYSID" | grep -Eq '^[A-Za-z]{2}[0-9]{2}[A-Za-z0-9]{11,30}$'; then
  bad "sysid fixture is still IBAN-SHAPED" "the fixture stopped being a control: $SYSID no longer matches the IBAN shape, so 'clean' proves nothing"
else
  pass "sysid fixture is still IBAN-SHAPED (so a clean verdict is the checksum's doing)"
fi
for mode in refuse refuse_high_confidence; do
  if run_tools 0 "sysid/$mode" --tools-file "$FIX/sysid-in-description.json" --tools-mode "$mode"; then
    expect_out "sysid/$mode is clean" "0 finding(s); 0 would 400 under \`refuse\`"
  fi
done

# ---------------------------------------------------------------------------
# 4. digit run in an `enum` -> refused under refuse, observed under
#    refuse_high_confidence. Pinned matcher: 10plus_digit_run.
# ---------------------------------------------------------------------------
if run_tools 1 "digitrun/refuse" --tools-file "$FIX/digit-run-in-enum.json" --tools-mode refuse; then
  expect_out "digitrun matcher class" "matcher=10plus_digit_run"
  expect_out "digitrun refused ONLY under refuse" "refused under: refuse"
  expect_not_out "digitrun not refused under refuse_high_confidence" "refused under: refuse, refuse_high_confidence"
  expect_out "digitrun location is the enum member" "/enum/0"
fi
if run_tools 0 "digitrun/refuse_high_confidence" --tools-file "$FIX/digit-run-in-enum.json" --tools-mode refuse_high_confidence; then
  expect_out "digitrun observed under refuse_high_confidence" "1 finding(s); 1 would 400 under \`refuse\`, 0 under \`refuse_high_confidence\`"
  expect_out "digitrun forwarded under refuse_high_confidence" "findings above are observations"
fi
run_tools 1 "digitrun/no-value-leak" --tools-file "$FIX/digit-run-in-enum.json" --tools-mode refuse || true
expect_not_out "digit run value never printed" "1234567890123"

# ---------------------------------------------------------------------------
# 5. Differential pins — verdicts MEASURED against the Go guard at 08e1afb6b.
#    Each case is a documented bypass or residual from
#    tool_schema_pii_guard.go's own header; a port that got any of them wrong
#    would silently mispredict the control.
# ---------------------------------------------------------------------------
pin() {
  local name="$1" body="$2" want_exit="$3" want_needle="$4"
  local f="$WK/pin_$name.json"
  printf '%s' "$body" > "$f"
  if run_tools "$want_exit" "pin/$name" --tools-file "$f" --tools-mode refuse; then
    expect_out "pin/$name verdict" "$want_needle"
  fi
}

# TOB-004: a bare number under a vendor extension is DATA, in every context.
pin numbers_outside_value_ctx \
  '[{"input_schema":{"type":"object","x_customer_msisdn":4915112345678}}]' \
  1 "matcher=10plus_digit_run"
# The type-blind structural exemption: `minimum` on a string is not a bound.
pin minimum_on_a_string \
  '[{"input_schema":{"type":"string","minimum":4915112345678}}]' \
  1 "matcher=10plus_digit_run"
# ...but an APPLICABLE bound on an integer stays exempt (stated residual).
pin minimum_on_an_integer \
  '[{"input_schema":{"type":"integer","minimum":4915112345678}}]' \
  0 "0 finding(s)"
# T-495: composition-depth overflow POISONS the declaration (fail closed).
pin composition_depth_overflow \
  '[{"input_schema":{"allOf":[{"allOf":[{"allOf":[{"allOf":[{"allOf":[{"allOf":[{"type":"string"}]}]}]}]}]}],"minimum":4915112345678}}]' \
  1 "matcher=10plus_digit_run"
# ...but a boolean-only composition declares nothing and must NOT poison.
pin composition_boolean_branch \
  '[{"input_schema":{"allOf":[true],"minimum":4915112345678}}]' \
  0 "0 finding(s)"
# Malformed allOf shapes poison too (found while fixing T-495).
pin malformed_allof \
  '[{"input_schema":{"allOf":"x","minimum":4915112345678}}]' \
  1 "matcher=10plus_digit_run"
# T-496: a bare number in a prose-typed position is not prose.
pin bare_number_in_prose_position \
  '[{"description":4915112345678}]' \
  1 "matcher=10plus_digit_run"
# ...while a digit run inside description TEXT is the ACCEPTED residual (T-485).
pin prose_text_digit_run_is_the_residual \
  '[{"description":"epoch 1712345678901 in prose"}]' \
  0 "0 finding(s)"
# draft-07 `dependencies` is name-keyed: "description" there is a PROPERTY NAME.
pin draft07_dependencies_is_name_keyed \
  '[{"type":"object","dependencies":{"description":["customer_4915112345678"]}}]' \
  1 "matcher=10plus_digit_run"
# Value context is STICKY: a "description" inside `default` is instance data.
pin value_context_is_sticky \
  '[{"default":{"description":"49151234567890"}}]' \
  1 "matcher=10plus_digit_run"
# ...and the mirror image: a PROPERTY named "default" keeps its prose exemption.
pin property_named_default_keeps_prose \
  '[{"properties":{"default":{"description":"account 4915112345678 fallback."}}}]' \
  0 "0 finding(s)"
# Zero-width split (U+200B) must not break the matcher.
pin zero_width_split \
  '[{"default":"49151'$'​''12345678"}]' \
  1 "matcher=10plus_digit_run"
# Hangul filler (U+3164) — blank, NFKC-folds to U+1160, and is NOT Cf/Mn/Me.
pin hangul_filler_split \
  '[{"default":"49151'$'ㅤ''12345678"}]' \
  1 "matcher=10plus_digit_run"
# Arabic-Indic digits carry no compatibility decomposition (TOB-003).
pin arabic_indic_digits \
  '[{"default":"'$'٤٩١٥١١٢٣٤٥٦٧٨''"}]' \
  1 "matcher=10plus_digit_run"
# Exponent form: match what the CONSUMER materialises, not what was typed.
pin exponent_expansion \
  '[{"x_customer_msisdn":49151.12345678e8}]' \
  1 "matcher=10plus_digit_run"
# The deleted opaque-id exemption: 32 hex chars, one letter, real MSISDN inside.
pin no_opaque_id_exemption \
  '[{"default":"a0000000000000000004915112345678"}]' \
  1 "matcher=10plus_digit_run"
# Duplicate object key — parser-differential, fail closed (malformed).
pin duplicate_object_key \
  '[{"description":"4915112345678","description":"harmless"}]' \
  1 "kind=malformed_tools"
# Trailing content after the tools array — fail closed.
pin trailing_content \
  '[{"name":"a"}]{"smuggled":"x"}' \
  1 "trailing content after the tools array"
# Undecodable tools array — fail closed.
pin undecodable_array \
  '[{"name":' \
  1 "kind=malformed_tools"
# ⚑ A payload that is a bare OBJECT (or any non-array scalar) is not an input
# error — those bytes ARE the tools value, and the gateway's verdict on them is
# known: json.Decode into []any fails, so it reports malformed_tools and
# REFUSES. Reporting "no tools array found" and exiting as an operator error
# would answer a different question, and would look like a clean bill from a
# direct invocation. Verdict measured against the Go guard.
pin bare_object_is_a_refusal_not_an_input_error \
  '{"name":"lookup","description":"account DE36000000000000000000"}' \
  1 "kind=malformed_tools"
pin bare_scalar_is_a_refusal_not_an_input_error \
  '"not a tools array"' \
  1 "kind=malformed_tools"
pin bare_number_is_a_refusal_not_an_input_error \
  '7' \
  1 "kind=malformed_tools"
# An email in prose IS refused: the prose exemption is digit-run only.
pin email_in_prose \
  '[{"description":"contact ops@example.com for access"}]' \
  1 "matcher=email"
# ---------------------------------------------------------------------------
# 5a. THE refuse_high_confidence RE-WALK CLASS.
#
# `12345678901e999999999` has a 10+-digit run in its LITERAL and an expansion
# past 1024 digits.  Permissively the digit-run matcher fires first and
# toolSchemaScanNumber returns before it ever expands; strictly the digit-run
# matcher is off, the expansion runs, and the over-long result is a fail-closed
# BOUNDS refusal.  So the gateway 400s this under refuse_high_confidence — the
# mode that "relaxes" the matcher — and any implementation that models that
# mode by FILTERING the permissive findings reports it clean.
#
# These cases exist to make that impossible to regress silently. Verdicts
# measured against the Go guard, both walks.
# ---------------------------------------------------------------------------
rhc_pin() {
  local name="$1" body="$2"
  local f="$WK/rhc_$name.json"
  printf '%s' "$body" > "$f"
  if run_tools 1 "rhc/$name/refuse" --tools-file "$f" --tools-mode refuse; then
    expect_out "rhc/$name permissive hit is the digit run" "matcher=10plus_digit_run"
    expect_out "rhc/$name strict-only finding is surfaced" "surfaced only with the digit-run matcher off"
    expect_out "rhc/$name strict-only finding is a bounds refusal" "kind=bounds_exceeded"
  fi
  # THE ASSERTION THAT MATTERS: non-zero under refuse_high_confidence.
  run_tools 1 "rhc/$name/refuse_high_confidence" --tools-file "$f" --tools-mode refuse_high_confidence || true
  if run_tools 0 "rhc/$name/log" --tools-file "$f" --tools-mode log; then
    expect_out "rhc/$name log still forwards" "would forward this tools payload"
  fi
}
rhc_pin digitrun_hides_overlong_expansion '[{"x_msisdn":12345678901e999999999}]'
rhc_pin digitrun_hides_overlong_exp2000 '[{"x_msisdn":1234567890123e2000}]'
printf '[{"a":%s}]' "$(printf '1234567890'; printf '0%.0s' $(seq 1 1020))" > "$WK/rhc_long_literal.json"
run_tools 1 "rhc/long_literal/refuse_high_confidence" --tools-file "$WK/rhc_long_literal.json" --tools-mode refuse_high_confidence || true

# A payload whose ONLY finding is a plain digit run must still be forwarded
# under refuse_high_confidence — otherwise the cases above would pass by the
# guard simply having stopped relaxing anything.
run_tools 0 "rhc/plain_digit_run_still_relaxed" --tools-file "$FIX/digit-run-in-enum.json" --tools-mode refuse_high_confidence || true

# ---------------------------------------------------------------------------
# 5b. A PII-shaped object KEY is a hit, and the key never appears in the report
#     — including in the pointers of findings BELOW it, and including under
#     --reveal-pointers. The gateway never faces this (it stops at the key hit);
#     enumerating every finding does, and a key fingerprinted on line 1 that is
#     spelled out on line 2 is not fingerprinted at all.
# NOTE: a real temp FILE, not a `<(…)` process substitution — require_readable_file
# uses `[ -f ]`, which is false for /dev/fd/N. An earlier draft of this case used
# `<(…)`, and it "passed" the exit assertion for the wrong reason (the arg check
# exits 1 too), which is exactly the shape of green this suite exists to prevent.
printf '%s' '[{"properties":{"patient_1234567890":{"type":"string"}}}]' > "$WK/pii_object_key.json"
if run_tools 1 "pin/pii_object_key" --tools-file "$WK/pii_object_key.json" --tools-mode refuse; then
  expect_out "pin/pii_object_key detail" "detail=object key"
  expect_not_out "pin/pii_object_key never echoes the key" "patient_1234567890"
fi
printf '%s' '[{"properties":{"p1234567890123":{"description":"ops@example.com"}}}]' > "$WK/key_then_descendant.json"
if run_tools 1 "pin/pii_key_redacts_descendant_pointers" --tools-file "$WK/key_then_descendant.json" --tools-mode refuse --reveal-pointers; then
  expect_out "pin/pii_key_redacts_descendant_pointers finds both" "matcher=email"
  expect_not_out "pin/pii_key_redacts_descendant_pointers never echoes the key" "p1234567890123"
fi
# A `"tools": null` member is how a real request body spells "no tools", and
# the gateway returns clean for it before decoding anything.
printf '%s' '{"model":"x","tools":null}' > "$WK/tools_null.json"
if run_tools 0 "pin/tools_null_member_is_clean" --tools-file "$WK/tools_null.json" --tools-mode refuse; then
  expect_out "pin/tools_null_member_is_clean" "0 finding(s)"
fi
# A space-grouped IBAN is the STATED residual: NBSP/space are visible
# separators and are deliberately not folded.
pin space_grouped_iban_is_the_stated_residual \
  '[{"default":"DE89 3704 0044 0532 0130 00"}]' \
  0 "0 finding(s)"

# ---------------------------------------------------------------------------
# 6. Input shapes: bare array, request body, MCP tools/list response, stdin.
# ---------------------------------------------------------------------------
printf '{"model":"x","tools":%s}' "$(cat "$FIX/iban-in-default.json")" > "$WK/request-body.json"
if run_tools 1 "shape/request-body" --tools-file "$WK/request-body.json" --tools-mode refuse; then
  expect_out "shape/request-body provenance" 'from the "tools" member'
fi
printf '{"jsonrpc":"2.0","id":1,"result":{"tools":%s}}' "$(cat "$FIX/clean.json")" > "$WK/mcp-list.json"
if run_tools 0 "shape/mcp-tools-list" --tools-file "$WK/mcp-list.json" --tools-mode refuse; then
  expect_out "shape/mcp-tools-list provenance" 'from the MCP "result.tools" member'
fi
rc=0
OUT="$("$LUCAIRN" doctor --tools --tools-file - --tools-mode refuse < "$FIX/iban-in-default.json" 2>&1)" || rc=$?
if [ "$rc" -eq 1 ]; then pass "shape/stdin (exit 1)"; else bad "shape/stdin" "expected exit 1, got $rc"; fi
expect_out "shape/stdin reads the payload" "matcher=IBAN"

# ---------------------------------------------------------------------------
# 7. Mode resolution: --tools-mode > GATEWAY_TOOL_SCHEMA_GUARD in --env >
#    the gateway's own `refuse` default. Mirrors toolSchemaGuardMode():
#    unset, empty and INVALID all fail toward `refuse`.
# ---------------------------------------------------------------------------
printf 'GATEWAY_TOOL_SCHEMA_GUARD=log\n' > "$WK/log.env"
printf 'GATEWAY_TOOL_SCHEMA_GUARD=\n' > "$WK/empty.env"
printf 'GATEWAY_TOOL_SCHEMA_GUARD=LOG_ONLY\n' > "$WK/typo.env"
printf 'GATEWAY_TOOL_SCHEMA_GUARD=  Refuse_High_Confidence  \n' > "$WK/spaced.env"
printf '# nothing here\n' > "$WK/absent.env"

if run_tools 0 "mode/env-log" --tools-file "$FIX/digit-run-in-enum.json" --env "$WK/log.env"; then
  expect_out "mode/env-log resolves to log" "tool-schema guard mode: log"
fi
if run_tools 1 "mode/env-empty-fails-safe" --tools-file "$FIX/digit-run-in-enum.json" --env "$WK/empty.env"; then
  expect_out "mode/env-empty resolves to refuse" "tool-schema guard mode: refuse"
fi
if run_tools 1 "mode/env-typo-fails-safe" --tools-file "$FIX/digit-run-in-enum.json" --env "$WK/typo.env"; then
  expect_out "mode/env-typo resolves to refuse" "tool-schema guard mode: refuse"
  expect_out "mode/env-typo warns loudly" "is not one of log|refuse|refuse_high_confidence"
fi
if run_tools 0 "mode/env-case-and-space" --tools-file "$FIX/digit-run-in-enum.json" --env "$WK/spaced.env"; then
  expect_out "mode/env-case-and-space normalises" "tool-schema guard mode: refuse_high_confidence"
fi
if run_tools 1 "mode/env-absent-fails-safe" --tools-file "$FIX/digit-run-in-enum.json" --env "$WK/absent.env"; then
  expect_out "mode/env-absent resolves to refuse" "tool-schema guard mode: refuse"
fi
if run_tools 1 "mode/no-env-uses-code-default" --tools-file "$FIX/digit-run-in-enum.json"; then
  expect_out "mode/no-env says where the default came from" "gateway code default"
fi
# --tools-mode WINS over the env file (an operator asking a what-if question).
if run_tools 1 "mode/flag-overrides-env" --tools-file "$FIX/digit-run-in-enum.json" --env "$WK/log.env" --tools-mode refuse; then
  expect_out "mode/flag-overrides-env" "tool-schema guard mode: refuse"
fi

# ---------------------------------------------------------------------------
# 8. Operator errors are errors, not silent passes.
# ---------------------------------------------------------------------------
rc=0
OUT="$("$LUCAIRN" doctor --tools 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then pass "missing --tools-file is an error"; else bad "missing --tools-file" "exited 0"; fi
expect_out "missing --tools-file explains itself" "requires --tools-file"

rc=0
OUT="$("$LUCAIRN" doctor --tools --tools-file "$WK/does-not-exist.json" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then pass "missing payload file is an error"; else bad "missing payload file" "exited 0"; fi

rc=0
OUT="$("$LUCAIRN" doctor --tools --tools-file "$FIX/clean.json" --tools-mode nonsense 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then pass "invalid --tools-mode is an error"; else bad "invalid --tools-mode" "exited 0"; fi

# A payload that ANNOUNCES the MCP shape and then does not carry it is the one
# genuine "I could not find a tools array" case: the operator plainly meant
# result.tools, and the honest answer is that the response lists no tools —
# NOT a refusal for a payload the gateway would never be handed.
printf '{"jsonrpc":"2.0","id":1,"result":{"nextCursor":"abc"}}' > "$WK/mcp_no_tools.json"
rc=0
OUT="$("$LUCAIRN" doctor --tools --tools-file "$WK/mcp_no_tools.json" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then pass "MCP result with no tools member is an error, not a clean bill"; else bad "MCP result with no tools member" "exited 0 — a payload the tool could not read is not a payload it cleared"; fi
expect_out "MCP result with no tools member says why" 'no "tools" member inside it'
expect_not_out "MCP result with no tools member is NOT reported as a guard refusal" "kind=malformed_tools"

# ⚑ LOW 2 CONTROL. --reveal-pointers changes what a security diagnostic PRINTS.
# It is parsed with the other doctor flags, so on its own it would be accepted
# and do nothing — the exact mirror of --compose being ignored INSIDE tools
# mode, which is rejected above. A silently inert flag on this command is a
# quiet promise that the caller-facing pointers were shown when they were not.
#
# ⚑ "IT EXITED NON-ZERO" IS NOT THE ASSERTION HERE, and writing it that way
# would have been green with the guard deleted: the ordinary offline battery
# also exits non-zero against customer.env.example (placeholder secrets). The
# discriminating facts are that the SPECIFIC rejection is printed and that it
# fires BEFORE any battery output — so the two assertions below are on the
# message and on the ABSENCE of the battery's first success line.
rc=0
OUT="$("$LUCAIRN" doctor --reveal-pointers --offline --env "$ROOT/customer.env.example" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "--reveal-pointers without --tools exits non-zero (necessary, not sufficient — see below)"
else
  bad "--reveal-pointers without --tools" "exited 0 — the flag was silently accepted and did nothing"
fi
expect_out "--reveal-pointers rejection is actionable" "only applies to 'doctor --tools'"
expect_not_out "--reveal-pointers rejected BEFORE the ordinary battery runs" "env file: ok"
# ...and it must still WORK inside tools mode, or the guard above is just a ban.
if run_tools 1 "reveal-pointers/still-works-in-tools-mode" --tools-file "$FIX/iban-in-default.json" --tools-mode refuse --reveal-pointers; then
  expect_out "reveal-pointers still reveals in tools mode" "/properties/creditor_account/default"
fi

# Flags belonging to the OTHER doctor batteries must be rejected, not ignored:
# this mode short-circuits before those batteries run, so accepting them would
# print "preflight ok" for checks that never executed.
for flag in "--compose $ROOT/docker-compose.customer.yml" "--values $ROOT/charts/lucairn/values.yaml"; do
  rc=0
  # shellcheck disable=SC2086
  OUT="$("$LUCAIRN" doctor --tools --tools-file "$FIX/clean.json" $flag 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "doctor --tools rejects ${flag%% *} rather than ignoring it"
  else
    bad "doctor --tools rejects ${flag%% *}" "exited 0 — it silently ignored a battery flag"
  fi
done

printf '' > "$WK/empty.json"
rc=0
OUT="$("$LUCAIRN" doctor --tools --tools-file "$WK/empty.json" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then pass "empty payload file is an error"; else bad "empty payload file" "exited 0"; fi

# ---------------------------------------------------------------------------
# 9. The command is documented where an operator will look.
# ---------------------------------------------------------------------------
# ⚑ NOT `grep -q 'doctor --tools' OPS.md`. Kit main already contained that
# literal before this command existed (PR #112 forward-referenced it), so that
# assertion was green with the whole section deleted — a tautology. Assert on
# strings only the real documentation can produce.
if grep -q -- '--tools-file' "$ROOT/OPS.md"; then
  pass "OPS.md documents the --tools-file input"
else
  bad "OPS.md documents the --tools-file input" "OPS.md never shows how to supply the payload"
fi
if grep -qi 'before the first routed turn' "$ROOT/OPS.md"; then
  pass "OPS.md says to run it BEFORE the first routed turn"
else
  bad "OPS.md ordering instruction" "OPS.md must tell the operator to run this before the first routed turn"
fi
# The forward reference PR #112 left behind ("will report… Until that ships")
# is now false. A doc that tells operators the safety valve does not exist yet
# is worse than one that never mentioned it.
if grep -q 'Until that ships' "$ROOT/OPS.md"; then
  bad "stale forward reference removed" "OPS.md still says 'Until that ships' — the T-498 command has shipped"
else
  pass "stale 'Until that ships' forward reference removed from OPS.md"
fi
# The digit-run/prose residual must be stated where the operator reads the
# report, or a clean verdict is read as a stronger claim than it is.
if grep -q 'digit-run-run\|10+-digit-run matcher is NOT applied to prose' "$ROOT/OPS.md"; then
  pass "OPS.md states the prose digit-run residual"
else
  bad "OPS.md states the prose digit-run residual" "a clean report must not be read as 'no personal data'"
fi
if "$LUCAIRN" --help 2>&1 | grep -q -- '--tools-file'; then
  pass "usage advertises --tools-file"
else
  bad "usage advertises --tools-file" "lucairn --help does not mention --tools-file"
fi

printf '\n%d checks, %d failures\n' "$N" "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
