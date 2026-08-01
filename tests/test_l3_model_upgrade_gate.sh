#!/usr/bin/env bash
#
# T-370 — L3 model-upgrade preparation gate.
#
# This suite pins TWO things that the T-370 change set is only worth having if
# they hold:
#
#   A. THE DEFAULT DID NOT MOVE. The kit's L3 model is `qwen2.5:7b` on every
#      surface — Helm values, the rendered sanitizer ConfigMap, the rendered
#      model-pull Job, the Compose sanitizer config, and the Compose vLLM
#      lane. T-370 PREPARES a model bump; it must not perform one, and no
#      later edit may quietly perform one either. A gemma4 model name may
#      appear only inside COMMENTS/docs, never as an active value.
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
cat >"$TMPDIR/base.yaml" <<'YAML'
ephemeral: "true"
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
         "$ROOT/image-manifest.yaml"; do
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
