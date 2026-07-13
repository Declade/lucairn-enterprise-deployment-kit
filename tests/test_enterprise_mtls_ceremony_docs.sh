#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/INSTALL.md"
RUNBOOK="$ROOT/docs/KEY_CEREMONY_RUNBOOK.md"
IMAGE='ghcr.io/declade/dsa-veil-witness:0.5.4@sha256:edc110fd5f827604790cee2be4a963ad03ee7201cbfb1262d2b23ff95a500523'

canonical="$(sed -n '/The `sign-manifest` tool ships \*\*inside the pinned/,/> witness-signed-manifest.json/p' "$INSTALL")"
[ -n "$canonical" ] || {
  echo "INSTALL misses the production sign-manifest canonical command" >&2
  exit 1
}

for required in \
  'umask 077' \
  'mktemp "${TMPDIR:-/tmp}/lucairn-witness-signing-key.XXXXXX"' \
  'chmod 0600 "$seed_file"' \
  "trap 'rm -f \"\$seed_file\"' EXIT HUP INT TERM" \
  '-v "$seed_file:/run/secrets/witness-signing-key-hex:ro"' \
  "$IMAGE" \
  "--entrypoint /bin/sh" \
  "-ec 'exec sign-manifest" \
  '$(cat /run/secrets/witness-signing-key-hex)' \
  'printf '\''%s'\'' "$LCR_WITNESS_SIGNING_KEY" > "$seed_file"'; do
  grep -Fq -- "$required" <<<"$canonical" \
    || { echo "INSTALL ceremony command misses: $required" >&2; exit 1; }
done

if grep -Fq -- '--witness-signing-key-hex "$LCR_WITNESS_SIGNING_KEY"' "$INSTALL" "$RUNBOOK"; then
  echo "production ceremony docs still place witness seed expansion in Docker argv" >&2
  exit 1
fi

section="$(sed -n '/^### 6\.2 Run sign-manifest/,/^### 6\.3 /p' "$RUNBOOK")"
quick_reference="$(sed -n '/^## Appendix: Quick Reference/,$p' "$RUNBOOK")"
for required in \
  'canonical private-seed-file command in' \
  'mode-0600 temporary seed file' \
  'read-only `/run/secrets/witness-signing-key-hex` mount' \
  'single-quoted in-container `/bin/sh -ec` command' \
  "$IMAGE"; do
  grep -Fq -- "$required" <<<"$section" \
    || { echo "runbook §6.2 misses ceremony control: $required" >&2; exit 1; }
done
for required in \
  'run §6.2' \
  'mode-0600 temporary seed file + cleanup trap' \
  '/run/secrets mount' \
  'digest-pinned image' \
  'in-container read'; do
  grep -Fq -- "$required" <<<"$quick_reference" \
    || { echo "runbook quick reference misses ceremony control: $required" >&2; exit 1; }
done

echo "enterprise mTLS production ceremony docs: contract ok"
