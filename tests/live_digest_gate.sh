#!/usr/bin/env bash
# live_digest_gate.sh — LIVE upstream drift gate for the third-party image pins.
#
# Why this exists (astra post-merge review of kit #137, finding M1): the
# unit test tests/test_digest_pin.sh is FIXTURE-ONLY — its resolver is a stub
# `crane` that answers the manifest's own recorded digests, and it runs on a
# hermetic PATH with no real docker/crane/skopeo. Before that isolation, the
# kit's only live drift detection was an accident: on the Ubuntu runner the real
# /usr/bin/docker was on the unit test's PATH and answered first. When docker
# failed (network, rate limit), the stub answered and CI went green without any
# live resolution. This script is the explicit replacement for that accident.
#
# What it does:
#   * Reads the entries of `image_digests:` from the manifest (default:
#     <kit root>/image-manifest.yaml, or $1) using the CLI's own parser
#     (parse_image_digests in bin/lucairn — the same parser `doctor --strict`
#     uses). Nothing is hardcoded here.
#   * Selects every NON-pending entry whose ref is a public third-party
#     container image: a ref NOT under ghcr.io/declade/ and not an ollama:// or
#     hf:// model URI. First-party ghcr.io/declade/ packages are private (an
#     anonymous ghcr.io token + manifest request returns 401), so this gate
#     cannot resolve them and they are NOT live-checked in CI.
#   * Resolves each ref's CURRENT index digest with the real
#     `docker buildx imagetools inspect <ref> --format '{{json .Manifest}}'`
#     and takes the top-level `.digest` with jq.
#   * Prints the full observed and recorded digest for every ref.
#   * Exits non-zero if ANY selected ref is unresolved, returns anything other
#     than exactly one JSON object whose .digest is sha256:<64 hex>, or differs
#     from the recorded digest; also if the manifest has an INVALID entry or an
#     entry with an empty ref, or if zero refs were selected.
#
# There is NO fixture fallback and NO stub: if docker/jq are missing or the
# registry lookup fails, the gate FAILS. A lookup is retried up to 3 times
# (transient network errors) before it counts as unresolved.
#
# Usage: bash tests/live_digest_gate.sh [path/to/image-manifest.yaml]
# Runs in CI as the `live-digest-gate` job (.github/workflows/ci.yml).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/lucairn"
MANIFEST="${1:-$ROOT/image-manifest.yaml}"
FIRST_PARTY_PREFIX="ghcr.io/declade/"
ATTEMPTS=3

die() { echo "live-digest-gate: FAIL: $*" >&2; exit 1; }

[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
command -v docker >/dev/null 2>&1 || die "docker is not on PATH — the live gate cannot resolve anything (no fallback)"
command -v jq >/dev/null 2>&1 || die "jq is not on PATH — required to read the top-level index digest"
docker buildx version >/dev/null 2>&1 || die "docker buildx is unavailable — required for 'imagetools inspect'"

PARSED="$(
  set --
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  parse_image_digests "$MANIFEST"
)" || die "parse_image_digests failed on $MANIFEST"
[ -n "$PARSED" ] || die "parse_image_digests returned no entries for $MANIFEST"

# Manifest integrity, checked on the VERDICT column, never on the ref text: an
# INVALID entry with an EMPTY ref must not escape (astra #138 note 1). Also
# reject any entry whose ref is empty and any line that is not "<ref>\t<verdict>".
invalid_count="$(printf '%s\n' "$PARSED" | awk -F'\t' '$2=="INVALID" {n++} END {print n+0}')"
[ "$invalid_count" -eq 0 ] \
  || die "manifest has $invalid_count INVALID image_digests entr(y/ies): $(printf '%s\n' "$PARSED" | awk -F'\t' '$2=="INVALID" {printf "[%s] ", $1}')"
emptyref_count="$(printf '%s\n' "$PARSED" | awk -F'\t' 'NF>0 && $0!="" && (NF!=2 || $1=="") {n++} END {print n+0}')"
[ "$emptyref_count" -eq 0 ] \
  || die "manifest has $emptyref_count image_digests entr(y/ies) with an empty ref or a malformed parser line"

# The single-document contract, validated on the RAW resolver bytes before any
# shell normalisation (astra #138 note 2): exactly ONE JSON value, an object,
# whose .digest is a string matching \Asha256:[0-9a-f]{64}\z (\A/\z, not ^/$,
# so a trailing newline inside the string cannot match). jq's `// empty` and
# bash's command-substitution newline stripping are NOT used to decide validity.
DIGEST_CONTRACT='length == 1 and (.[0] | type) == "object" and (.[0].digest | type) == "string" and (.[0].digest | test("\\Asha256:[0-9a-f]{64}\\z"))'

resolve() {
  # $1 = ref. On success prints the validated digest and returns 0.
  # Returns 1 = UNRESOLVED (no output after $ATTEMPTS attempts),
  #         2 = MALFORMED  (output present but violates the contract; raw bytes
  #                         left in $RAWF for the report).
  local ref="$1" i=1
  while [ "$i" -le "$ATTEMPTS" ]; do
    : > "$RAWF"
    if docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' >"$RAWF" 2>"$ERRF" && [ -s "$RAWF" ]; then
      jq -e -s "$DIGEST_CONTRACT" "$RAWF" >/dev/null 2>>"$ERRF" || return 2
      jq -j '.digest' "$RAWF"
      return 0
    fi
    [ "$i" -lt "$ATTEMPTS" ] && sleep $((i * 5))
    i=$((i + 1))
  done
  return 1
}

ERRF="$(mktemp)"
RAWF="$(mktemp)"
trap 'rm -f "$ERRF" "$RAWF"' EXIT

checked=0; bad=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  ref="${line%%$'\t'*}"; recorded="${line#*$'\t'}"   # split on the ONE tab; no IFS whitespace collapsing
  case "$recorded" in sha256:*) ;; *) continue ;; esac            # PENDING -> not pinned yet
  case "$ref" in "$FIRST_PARTY_PREFIX"*|ollama://*|hf://*) continue ;; esac
  checked=$((checked + 1))
  : > "$ERRF"
  observed="$(resolve "$ref")"; rrc=$?
  echo "live-digest-gate: $ref"
  echo "  recorded: $recorded"
  echo "  observed: ${observed:-<none>}"
  if [ "$rrc" -eq 2 ]; then
    echo "  RESULT: MALFORMED (resolver output is not exactly one JSON object with .digest = sha256:<64 hex>; raw: $(head -c 300 "$RAWF" | tr '\n' ' '))"
    bad=$((bad + 1))
  elif [ "$rrc" -ne 0 ] || [ -z "$observed" ]; then
    echo "  RESULT: UNRESOLVED (no digest after $ATTEMPTS attempts; last error: $(tr '\n' ' ' < "$ERRF" | cut -c1-300))"
    bad=$((bad + 1))
  elif ! printf '%s' "$observed" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    echo "  RESULT: MALFORMED (observed value is not sha256:<64 hex>)"
    bad=$((bad + 1))
  elif [ "$observed" != "$recorded" ]; then
    echo "  RESULT: MISMATCH (recorded != observed; usually upstream re-pointed a moving tag — review, then re-pin by hand; see OPS.md § Digest-pin enforcement)"
    bad=$((bad + 1))
  else
    echo "  RESULT: ok"
  fi
done <<EOF
$PARSED
EOF

[ "$checked" -gt 0 ] || die "selected zero third-party pinned refs from $MANIFEST — nothing was verified"
echo "live-digest-gate: checked=$checked failed=$bad"
[ "$bad" -eq 0 ] || die "$bad of $checked third-party pinned refs did not verify live against their registry"
echo "live-digest-gate: ok"
