#!/usr/bin/env bash
set -euo pipefail

# T-576 — no kit-shipped sanitizer config may declare a RETIRED sanitizer key.
#
# THE DEFECT (measured 2026-08-07 in a Kind+Helm install, reproduced here
# against the real loader): the chart's sanitizer ConfigMap set
#   presidio.strict_safe_terms_file: /config/safe-terms-strict.txt
# DSA retired that key on 2026-07-25 (commit 811ef43b0, "consolidate 3 FP
# never-redact surfaces into redaction_policy") and made it a BOOT REFUSAL:
# services/sanitizer/config.py:3181-3204 raises
#   "strict_safe_terms_file is retired — migrate its terms into
#    redaction_policy.stop_terms with surface: l1_strict"
# because silently ignoring a still-set file key would silently DROP its
# suppressions into over-redaction. Consequence on a clean install: the
# sanitizer sidecar CrashLoopBackOffs -> sandbox-a never becomes Ready -> the
# gateway's isolation-invariant poller never verifies -> the gateway
# restart-loops on its own startup probe. The whole stack fails to come up.
#
# The belief that let it ship is written verbatim in the old ConfigMap comment:
# "Yaml loader ignores any unrecognised key". That is true for a FORGOTTEN key
# and false for a DELIBERATELY RETIRED one. This suite pins the difference.
#
# WHAT THIS PROVES: no shipped sanitizer config declares a key in the retired
# set, and the l1_strict replacement surface is actually populated (so a future
# "just delete the key" fix cannot silently drop the false-positive
# suppression it was there to provide).
#
# WHAT THIS DOES NOT PROVE: that the whole rendered config is ACCEPTED by the
# sanitizer image's config.py. This repo cannot import DSA's loader, so the
# blocklist below is maintained by hand. The end-to-end proof — feeding every
# shipped config through the real `load_sanitizer_config` from DSA origin/main
# — is run out-of-band and recorded in the PR body. When DSA retires another
# key, ADD IT to RETIRED_KEYS here.
#
# POSITIVE CONTROL: assertion 4 re-injects the retired key into a scratch copy
# of a shipped config and requires the detector to fire on it. If the detector
# were a tautology (e.g. a mistyped grep that never matches) that assertion
# goes red.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"

# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

fail() {
  echo "T-576 retired sanitizer config keys: $*" >&2
  exit 1
}

# Keys the sanitizer's config loader REFUSES to boot on. Mirrors
# services/sanitizer/config.py `_RETIRED_PRESIDIO_FILE_KEYS`.
# NOT retired (do not add): safe_terms_file, spacy_location_stop_terms_file —
# config.py:3196-3198 names those two as still-valid file-based keys.
RETIRED_KEYS="strict_safe_terms_file gliner_stop_terms_file"

TMPDIR_T576="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_T576"; }
trap cleanup EXIT

# declares_retired_key FILE — echo each retired key declared as an ACTIVE
# (non-commented) `<indent><key>:` mapping entry in FILE. Silent when clean.
# A commented-out mention is fine — this suite's own fix leaves explanatory
# comments naming the keys, and a comment cannot reach the loader.
declares_retired_key() {
  local file="$1" key
  for key in $RETIRED_KEYS; do
    if grep -qE "^[[:space:]]*${key}:[[:space:]]" "$file"; then
      echo "$key"
    fi
  done
}

# ---------------------------------------------------------------------------
# 1. The Helm-rendered sanitizer ConfigMap.
# ---------------------------------------------------------------------------
RENDER="$TMPDIR_T576/render.yaml"
helm template lucairn "$CHART" \
  "${HELM_TEST_SECRET_ARGS[@]}" \
  --set global.skipPullSecretGuard=true \
  --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
  > "$RENDER" || fail "helm template failed"

python3 - "$RENDER" "$TMPDIR_T576" <<'PY' || exit 1
import sys, yaml
render, outdir = sys.argv[1], sys.argv[2]
found = None
for doc in yaml.safe_load_all(open(render)):
    if doc and doc.get("kind") == "ConfigMap" \
            and doc["metadata"]["name"] == "sanitizer-config":
        found = doc
if found is None:
    print("sanitizer-config ConfigMap absent from the render", file=sys.stderr)
    sys.exit(1)
open(outdir + "/rendered-config.yaml", "w").write(found["data"]["config.yaml"])
# The dead data key must be gone: it existed ONLY to back the retired
# strict_safe_terms_file directive, so keeping it would mount a file that
# nothing reads.
if "safe-terms-strict.txt" in found["data"]:
    print("ConfigMap still ships the dead `safe-terms-strict.txt` data key "
          "(it backed the retired strict_safe_terms_file directive)",
          file=sys.stderr)
    sys.exit(1)
# The still-VALID location stop-list must remain — proving assertion 1 did not
# pass by deleting the whole safe-terms surface.
if "safe-terms-strict-location.txt" not in found["data"]:
    print("ConfigMap lost `safe-terms-strict-location.txt` — that key is NOT "
          "retired and must still be delivered", file=sys.stderr)
    sys.exit(1)
PY

hits="$(declares_retired_key "$TMPDIR_T576/rendered-config.yaml")"
[ -z "$hits" ] || fail "rendered sanitizer ConfigMap declares retired key(s): $hits"
echo "ok: helm-rendered sanitizer config declares no retired key"

# ---------------------------------------------------------------------------
# 2. Every sanitizer config the kit ships on disk (Compose lane + starter
#    templates). The Compose install path reads these directly.
# ---------------------------------------------------------------------------
SHIPPED="$ROOT/config/default-sanitizer.yaml"
for f in "$ROOT"/starter-templates/*/config.yaml; do
  [ -f "$f" ] && SHIPPED="$SHIPPED $f"
done
for f in $SHIPPED; do
  hits="$(declares_retired_key "$f")"
  [ -z "$hits" ] || fail "${f#"$ROOT"/} declares retired key(s): $hits"
done
echo "ok: shipped on-disk sanitizer configs declare no retired key ($(echo $SHIPPED | wc -w | tr -d ' ') files)"

# ---------------------------------------------------------------------------
# 3. The replacement surface is POPULATED, not merely absent.
#    Deleting the retired key alone would boot fine and silently lose the
#    product-vocabulary false-positive suppression it provided.
# ---------------------------------------------------------------------------
python3 - "$TMPDIR_T576/rendered-config.yaml" "$ROOT/config/default-sanitizer.yaml" \
         "$ROOT/starter-templates/itsm/config.yaml" <<'PY' || exit 1
import sys, yaml
# The ten product-vocabulary terms the retired kit file carried. Semantics are
# whole-detected-span exact, ANY entity type: "Claude" alone is suppressed,
# "Claude Muller" still redacts.
EXPECTED = {"claude", "opus", "sonnet", "haiku", "anthropic",
            "lucairn", "codex", "veil", "signable", "remedy"}
# Real names must never appear on this surface — an l1_strict entry for a real
# given name or surname is an UNDER-redaction (identity data stops being
# redacted). Mirrors DSA's test_shipped_strict_safe_list_has_no_real_names.
FORBIDDEN = {"marc", "grep", "muller", "mueller", "schulz", "schmidt"}
rc = 0
for path in sys.argv[1:]:
    data = yaml.safe_load(open(path)) or {}
    policy = (data.get("sanitizer") or {}).get("redaction_policy") or {}
    terms = {
        str(e.get("term", "")).casefold()
        for e in (policy.get("stop_terms") or [])
        if isinstance(e, dict) and e.get("surface") == "l1_strict"
    }
    missing = EXPECTED - terms
    if missing:
        print(f"{path}: redaction_policy.stop_terms is missing l1_strict "
              f"term(s) {sorted(missing)} — the retired strict_safe_terms_file "
              f"suppression was dropped, not migrated", file=sys.stderr)
        rc = 1
    leaked = FORBIDDEN & terms
    if leaked:
        print(f"{path}: l1_strict stop_terms contains real-name term(s) "
              f"{sorted(leaked)} — that is an UNDER-redaction", file=sys.stderr)
        rc = 1
sys.exit(rc)
PY
echo "ok: l1_strict stop_terms carries all ten migrated terms and no real names"

# ---------------------------------------------------------------------------
# 4. POSITIVE CONTROL — the detector must go red on a config that really does
#    declare the retired key. Without this, assertions 1-2 could be passing
#    because the matcher never matches anything.
# ---------------------------------------------------------------------------
CONTROL="$TMPDIR_T576/control.yaml"
cp "$ROOT/config/default-sanitizer.yaml" "$CONTROL"
# Re-inject the exact line the fix removed, at the presidio block's indent.
python3 - "$CONTROL" <<'PY' || exit 1
import sys
path = sys.argv[1]
lines = open(path).read().split("\n")
for i, line in enumerate(lines):
    if line.startswith("    safe_terms_file:"):
        lines.insert(i + 1,
                     "    strict_safe_terms_file: /config/safe-terms-strict.txt")
        open(path, "w").write("\n".join(lines))
        sys.exit(0)
print("positive control could not find the presidio safe_terms_file anchor — "
      "the control would be vacuous", file=sys.stderr)
sys.exit(1)
PY

control_hits="$(declares_retired_key "$CONTROL")"
case "$control_hits" in
  *strict_safe_terms_file*) : ;;
  *) fail "POSITIVE CONTROL FAILED — a config that DOES declare strict_safe_terms_file was reported clean; every assertion above is uninterpretable" ;;
esac
# And a commented-out mention must NOT trip it (assertions 1-2 rely on that:
# the fix leaves explanatory comments naming the retired keys).
COMMENT_CONTROL="$TMPDIR_T576/comment-control.yaml"
printf '%s\n' \
  "sanitizer:" \
  "  presidio:" \
  "    # strict_safe_terms_file: /config/safe-terms-strict.txt" \
  "    # NO strict_safe_terms_file here." \
  > "$COMMENT_CONTROL"
[ -z "$(declares_retired_key "$COMMENT_CONTROL")" ] \
  || fail "detector fires on a COMMENTED mention — it would block the fix's own explanatory comments"
echo "ok: positive control fires on a live retired key and ignores a commented one"

echo "T-576 retired sanitizer config keys: PASS"
