#!/usr/bin/env bash
#
# T-370 — L3 model-upgrade preparation gate.
#
# This suite pins TWO things that the T-370 change set is only worth having if
# they hold:
#
#   A. THE DEFAULT DID NOT MOVE. The kit's L3 model is `qwen2.5:7b` on every
#      surface — child-chart values, the rendered sanitizer ConfigMap, the
#      rendered model-pull Job, the Compose sanitizer config, the Compose vLLM
#      lane, AND every umbrella values file. T-370 PREPARES a model bump; it
#      must not perform one, and no later edit may quietly perform one either.
#      A gemma4 model name may appear only inside COMMENTS/docs, never as an
#      active value.
#
#      SCOPE NOTE (review F1, and the reason this suite's first version was
#      falsifiable): the renders below use the CHILD chart in isolation, which
#      by construction CANNOT see an override written at the umbrella level.
#      `sandbox-a.sanitizer.llmScanModel` in charts/lucairn/values*.yaml flips
#      both consumers on a real install while every child-chart assertion stays
#      green, so the umbrella files are asserted directly (unset-or-shipped)
#      and are in the gemma-scan list. A suite that renders one chart must say
#      which chart, or its header is a claim it does not test.
#
#   B. THE STORE SIZE IS REACHABLE FROM VALUES, AT AN UNCHANGED DEFAULT.
#      `ollama-identity`'s volumeClaimTemplates size used to be hardcoded
#      10Gi, so a larger L3 model could not be provisioned from values at all.
#      It is now `ollamaIdentity.persistence.size`, defaulting to the same
#      10Gi.
#
# POSITIVE CONTROLS (each case fails against the pre-T-370 tree, or against a
# tree where the guard it describes has been removed):
#   - override-honoured: `--set ollamaIdentity.persistence.size=40Gi` must
#     render 40Gi. The pre-T-370 hardcode renders 10Gi -> this case FAILS,
#     which is exactly what makes it a control and not a tautology.
#   - default-unchanged: with no override the render is still 10Gi, so the
#     new knob cannot be the vehicle for a silent default change.
#   - no-default-flip (five surfaces): flipping ANY of them to gemma4 turns a
#     case red.
#   - gate-text-present: deleting the operator-facing gate sentence from the
#     two config surfaces, or deleting the runbook, turns a case red. The gate
#     is documentation-only (nothing in the kit enforces it), so its PRESENCE
#     is the only thing that can be tested — and is therefore tested.
#
# Requires: helm, yq. No cluster, GPU, Docker, or network.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"
CHILD_CHART="$ROOT/charts/lucairn/charts/sandbox-a"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# The model the kit ships. Every "did the default move" assertion compares
# against THIS constant, so a deliberate future bump is a one-line edit here
# plus a green gate — not a silent drift.
readonly SHIPPED_OLLAMA_MODEL="qwen2.5:7b"
readonly SHIPPED_VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct-AWQ"
readonly SHIPPED_STORE_SIZE="10Gi"

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
    echo "T-370 gate: ERROR — $1 is required" >&2
    exit 2
  }
}

require_command helm
require_command yq

# Render the child chart directly with the L3 shield ENABLED — ollama-identity
# and its model-pull Job only exist when sanitizer.llmScanEnabled=true
# (templates/ollama-identity-statefulset.yaml:1,
# templates/ollama-identity-model-job.yaml:20).

# Minimum values the child chart's schema requires (mirrors the
# `direct-valid.yaml` fixture in tests/test_wp1_s4_helm_boundary.sh). Nothing
# here touches the L3 model or the store size — those come from the chart's
# own defaults, which is the point.
cat >"$TMPDIR/base.yaml" <<YAML
ephemeral: "true"
# T-10: sandbox-a's bundled-Postgres password has no working default any more;
# a direct child render must supply it or templates/_validate.tpl aborts.
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
  # T-393: \`l3Required\` is RETIRED (backticks escaped: this line is inside an
  # UNQUOTED heredoc, which the \${TEST_SECRET_VALUE} interpolation above needs,
  # so a bare backtick pair would run as a command substitution). It is
  # deliberately ABSENT here — the
  # service images refuse to start when they see the retired flag beside an
  # unset replacement posture, so a fixture that sets it describes an install
  # that would CrashLoop. See tests/test_l3_posture_flags.sh.
  nodeIsolation: false
  mtls:
    enabled: false
YAML

render() {
  helm template sandbox-a "$CHILD_CHART" \
    -f "$TMPDIR/base.yaml" \
    --set sanitizer.llmScanEnabled=true \
    "$@"
}

echo "T-370 L3 model-upgrade gate"
echo ""
echo "B. store size is a value, default unchanged"

render >"$TMPDIR/default.yaml"
render --set ollamaIdentity.persistence.size=40Gi >"$TMPDIR/override.yaml"

sts_storage() {
  yq eval-all \
    'select(.kind == "StatefulSet" and .metadata.name == "ollama-identity")
       | .spec.volumeClaimTemplates[0].spec.resources.requests.storage' \
    "$1"
}

check_eq "default render still requests $SHIPPED_STORE_SIZE" \
  "$SHIPPED_STORE_SIZE" "$(sts_storage "$TMPDIR/default.yaml")"

# POSITIVE CONTROL: pre-T-370 this renders 10Gi (hardcoded) and this case fails.
check_eq "override renders 40Gi (knob is real, not decorative)" \
  "40Gi" "$(sts_storage "$TMPDIR/override.yaml")"

check_eq "values.yaml default for ollamaIdentity.persistence.size" \
  "$SHIPPED_STORE_SIZE" \
  "$(yq '.ollamaIdentity.persistence.size' "$CHILD_CHART/values.yaml")"

echo ""
echo "A. no default was flipped"

check_eq "chart values sanitizer.llmScanModel" \
  "$SHIPPED_OLLAMA_MODEL" \
  "$(yq '.sanitizer.llmScanModel' "$CHILD_CHART/values.yaml")"

# UMBRELLA OVERRIDE PATH (review F1). Everything else in this section renders
# the CHILD chart in isolation, which cannot see an override written at the
# UMBRELLA level. `sandbox-a.sanitizer.llmScanModel` in charts/lucairn/values.yaml
# or any values-*.yaml flips BOTH consumers (the pull Job and the sanitizer
# ConfigMap) on a real umbrella install while every child-chart assertion above
# stays green. Assert the key is unset-or-shipped in every umbrella values file.
# Unset is the shipped state (the child default supplies the model), so an
# explicit value is only acceptable when it IS the shipped model.
for f in "$ROOT"/charts/lucairn/values*.yaml; do
  rel="${f#"$ROOT"/}"
  got="$(yq '.["sandbox-a"].sanitizer.llmScanModel // "«unset»"' "$f")"
  if [ "$got" = "«unset»" ] || [ "$got" = "$SHIPPED_OLLAMA_MODEL" ]; then
    pass "umbrella $rel sandbox-a.sanitizer.llmScanModel is $got"
  else
    fail "umbrella $rel overrides sandbox-a.sanitizer.llmScanModel to '$got'"
  fi
done

check_eq "Compose sanitizer config llm_scan.model" \
  "$SHIPPED_OLLAMA_MODEL" \
  "$(yq '.sanitizer.llm_scan.model' "$ROOT/config/default-sanitizer.yaml")"

# The sanitizer ConfigMap and the model-pull Job read the SAME value, so a
# drift between them is impossible by construction — but a flip of that one
# value would move both, which is what these two cases catch.
yq eval-all \
  'select(.kind == "ConfigMap" and .metadata.name == "sanitizer-config"
          and (.data | has("config.yaml")))
     | .data["config.yaml"]' \
  "$TMPDIR/default.yaml" | head -c 200000 >"$TMPDIR/sanitizer-config.yaml"
cm_model="$(yq '.sanitizer.llm_scan.model' "$TMPDIR/sanitizer-config.yaml")"
check_eq "rendered sanitizer ConfigMap llm_scan.model" \
  "$SHIPPED_OLLAMA_MODEL" "$cm_model"

if grep -qF -- "ollama pull \"$SHIPPED_OLLAMA_MODEL\"" "$TMPDIR/default.yaml"; then
  pass "rendered model-pull Job pulls $SHIPPED_OLLAMA_MODEL"
else
  fail "rendered model-pull Job does not pull $SHIPPED_OLLAMA_MODEL"
fi

# Compose vLLM lane: the `--model` flag is the artifact this lane serves.
vllm_model="$(yq '.services.model-runtime-vllm-l3.command
  | to_entries | .[] | select(.value == "--model") | .key + 1' \
  "$ROOT/docker-compose.self-hosted.yml" \
  | head -1 \
  | xargs -I{} yq ".services.model-runtime-vllm-l3.command[{}]" \
      "$ROOT/docker-compose.self-hosted.yml")"
check_eq "Compose vllm-l3 --model" "$SHIPPED_VLLM_MODEL" "$vllm_model"

# Belt-and-braces: no ACTIVE (non-comment) gemma reference on any config
# surface. Comments and docs are where the option is described; a value is
# where it would take effect.
active_gemma_hits=""
for f in "$CHILD_CHART/values.yaml" \
         "$ROOT/config/default-sanitizer.yaml" \
         "$ROOT/docker-compose.self-hosted.yml" \
         "$ROOT/image-manifest.yaml" \
         "$ROOT"/charts/lucairn/values*.yaml; do
  hits="$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$f" \
    | grep -in "gemma" || true)"
  if [ -n "$hits" ]; then
    active_gemma_hits="$active_gemma_hits\n$f:\n$hits"
  fi
done
if [ -z "$active_gemma_hits" ]; then
  pass "no active (non-comment) gemma reference on any config surface"
else
  fail "active gemma reference found:$(printf '%b' "$active_gemma_hits")"
fi

echo ""
echo "Gate text is present where an operator would flip the value"

GATE_NEEDLE="requires the per-artifact recall gate"
NOT_TRANSFERABLE="it is not transferable"

for f in "$CHILD_CHART/values.yaml" \
         "$ROOT/config/default-sanitizer.yaml" \
         "$ROOT/docs/L3_MODEL_UPGRADE.md"; do
  rel="${f#"$ROOT"/}"
  if grep -qF -- "$GATE_NEEDLE" "$f" && grep -qF -- "$NOT_TRANSFERABLE" "$f"; then
    pass "gate sentence present in $rel"
  else
    fail "gate sentence missing from $rel"
  fi
done

# The runbook must actually carry the four things it was written for; a stub
# file would otherwise satisfy the case above.
for section in "The gate" "vLLM-lane artifact candidates" \
               "Upgrade runbook" "Model licence"; do
  if grep -qF -- "$section" "$ROOT/docs/L3_MODEL_UPGRADE.md"; then
    pass "runbook covers: $section"
  else
    fail "runbook missing section: $section"
  fi
done

echo ""
echo "Kit-local citations in the runbook still resolve"

# Review F4, mechanized. The runbook's `file:line` citations rotted THREE times
# during this change set — twice from comment insertions in the very commits
# that wrote them. A prose "re-derive these" warning demonstrably does not hold;
# this does. Each row pins a cited line to a token that must appear ON it, so
# any edit that shifts the line turns the suite red instead of leaving a
# confidently-wrong citation in a customer-facing document.
#
# Add a row whenever the runbook gains a kit-local citation.
JOB="$CHILD_CHART/templates/ollama-identity-model-job.yaml"
STS="$CHILD_CHART/templates/ollama-identity-statefulset.yaml"
VAL="$ROOT/charts/lucairn/templates/_validators.tpl"
VALY="$ROOT/charts/lucairn/templates/validators.yaml"

check_citation() {
  local file="$1" line="$2" needle="$3" label="$4" got
  got="$(sed -n "${line}p" "$file")"
  if printf '%s' "$got" | grep -qF -- "$needle"; then
    pass "$label -> ${file##*/}:$line"
  else
    fail "$label: ${file##*/}:$line no longer contains '$needle' (line reads: $(printf '%s' "$got" | head -c 90))"
  fi
}

# check_anchor FILE NEEDLE LABEL [CONTEXT_NEEDLE]
#
# CONTENT-based citation: asserts the file still contains the construct, with
# no reference to WHERE in the file it sits.
#
# ⚑ WHY THIS EXISTS (citation rot — the class kit commit c5695e2 already lists
# as fixed once).  check_citation above pins a LINE NUMBER, and a line number is
# never the thing under test: it is a property of every OTHER edit to the file.
# The `bin/lucairn` anchor below broke on an unrelated PR (T-498, which inserted
# a new doctor subcommand ~900 lines above it) and reported "the manifest-entry
# anchor is gone" when the manifest-entry parser was untouched. A test that goes
# red for reasons unrelated to what it asserts teaches people to re-point it
# without reading it, which is how a real regression eventually slips through.
#
# CONTEXT_NEEDLE is optional and keeps the assertion SPECIFIC where the bare
# needle would be too weak on its own: it names the enclosing construct, so
# "the string still appears somewhere in the file" cannot pass for "the string
# still appears in the parser that needs it".
check_anchor() {
  local file="$1" needle="$2" label="$3" ctx="${4:-}" n
  n="$(grep -cF -- "$needle" "$file" 2>/dev/null || true)"
  [ -n "$n" ] || n=0
  if [ "$n" -eq 0 ]; then
    fail "$label: ${file##*/} no longer contains '$needle' anywhere"
    return
  fi
  if [ -n "$ctx" ] && ! grep -qF -- "$ctx" "$file"; then
    fail "$label: ${file##*/} contains '$needle' but its enclosing construct '$ctx' is gone"
    return
  fi
  pass "$label -> ${file##*/} (content anchor, $n occurrence(s))"
}

check_citation "$JOB"  20  "identityModelRegistryEgress"           "air-gap render gate"
check_citation "$JOB"  25  "ollama-identity-model-pull-r"          "revision-suffixed Job name"
check_citation "$JOB"  44  "activeDeadlineSeconds:"                "pull deadline"
check_citation "$JOB" 101  "Values.ollamaIdentity.image.repository" "model-pull CLI image"
check_citation "$JOB" 119  "Waiting for ollama-identity"           "readiness wait (start)"
check_citation "$JOB" 128  "done;"                                 "readiness wait (end)"
check_citation "$JOB" 129  "echo \"Pulling"                        "pull echo"
check_citation "$JOB" 130  "ollama pull"                           "pull command"
check_citation "$STS"  30  "Values.ollamaIdentity.image.repository" "ollama-identity image"
check_citation "$STS"  65  "readinessProbe:"                       "readiness probe"
check_citation "$STS"  80  "limits.memory"                         "memory limit"
# CONTENT-anchored (was `check_citation "$VAL" 976 …`, converted 2026-08-04
# under the G2/G3 kit release-gates PR). The G3 edit inserted ~13 lines of
# prose into the l3PostureValues validator earlier in this same file, which
# shifted this line-numbered citation to 989 on that PR alone — the third
# unrelated PR this file's line-976 anchor has broken under (T-498's doctor
# subcommand and PR #116's own predecessor citation being the first two), and
# the class check_anchor exists to close (see its doc comment above and the
# `bin/lucairn` conversion below).
#
# The needle is the FULL `{{- define "…" -}}` directive, not the bare
# validator name: the bare name `validators.l3AirGapWithoutFailClosed` also
# appears two lines into this validator's own doc comment (`_validators.tpl`
# "validators.l3AirGapWithoutFailClosed  (T-375 item 2b, SEC-001)"), so a
# needle of just the name would still pass with the `{{- define }}` block
# deleted entirely and only the comment left behind — the exact failure mode
# PR #116's first draft hit on `bin/lucairn`. Wrapping the needle in the
# template define syntax rules that out: the comment prose is never valid Go
# template syntax, so it can never contain this exact string.
#
# CONTEXT_NEEDLE pins a fragment of the guard's own fail() message so a
# gutted-but-still-defined stub (an empty `{{- define … -}}{{- end -}}`, which
# would still satisfy the needle above) also fails this check — the point of
# T-375 item 2b / SEC-001 is the fail-closed BEHAVIOUR, not merely that a
# template block by this name still exists.
check_anchor "$VAL" \
  '{{- define "validators.l3AirGapWithoutFailClosed" -}}' \
  "air-gap fail-closed validator" \
  'l3AvailabilityPosture=reject so a missing model fails visibly at /readyz'
check_citation "$VALY" 27  "l3AirGapWithoutFailClosed"             "validator invocation"
# CONTENT-anchored (was `check_citation … 1962 …`, converted 2026-08-04 under
# T-498). `bin/lucairn` is an 8.9k-line file that nearly every kit PR edits, so
# a line number into it is a tripwire for unrelated work rather than a check on
# this parser: the T-498 doctor subcommand landed ~900 lines above it and turned
# this assertion red while the manifest-entry parser was untouched.
#
# ⚑ THE NEEDLE IS THE WHOLE AWK PATTERN, and the first draft of this conversion
# got that wrong in a way worth recording. It reused the old line-scoped needle
# `-7b-awq-model:` — which was safe when `sed -n 1962p` had already narrowed the
# haystack to one line, and is NOT safe against the whole file, because the
# comment two lines above the parser also says "qwen2.5-7b-awq-model:". Renaming
# the model in the awk pattern left the comment behind, so the anchor still
# passed: a control that could not fail. Escaping the dot is what separates the
# two — prose writes `qwen2.5-…`, the awk regex writes `qwen2\.5-…` — and
# pinning the full pattern also asserts the anchor is still an anchor (matched
# at line start, whole line) rather than a mention.
#
# The context needle names the enclosing function, so "the pattern is somewhere
# in bin/lucairn" cannot pass for "the vllm-l3 revision parser still keys off
# the manifest entry name". Renaming the manifest entry still breaks this
# deliberately (the F2 finding in miniature) — that is the point of the check.
check_anchor "$ROOT/bin/lucairn" \
  '/^[[:space:]]*qwen2\.5-7b-awq-model:[[:space:]]*$/' \
  "doctor B-E2 manifest-entry anchor" \
  "check_vllm_l3_revision_consistency()"

# The licence re-confirmation is a PRD locked constraint, not advice.
if grep -qF -- "ai.google.dev/gemma/terms" "$ROOT/docs/L3_MODEL_UPGRADE.md"; then
  pass "runbook names the licence page to re-confirm before customer ship"
else
  fail "runbook does not name ai.google.dev/gemma/terms"
fi

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "T-370 L3 model-upgrade gate: PASS ($N checks)"
else
  echo "T-370 L3 model-upgrade gate: FAIL ($FAILS of $N checks)" >&2
  exit 1
fi
