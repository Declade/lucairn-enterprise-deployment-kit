#!/usr/bin/env bash
# sign-witness-manifest.sh — produce the witness-signed key manifest for a
# Compose install (kit 2.0.1, T-1479; PRD prd-2026-11-21-kit-customer-install-fix.md).
#
# With DSA_ENV=production the gateway refuses to start without
# /certs/witness-signed-manifest.json: a base64 canonical copy of its
# /.well-known/veil-keys.json key roster, signed with the witness seed. The
# gateway rebuilds the roster from its own environment at boot and refuses a
# blob whose active keys differ in any byte or in their ORDER
# (services/gateway/internal/api/veil.go buildPublicKeyManifest +
# verifyEnvKeysMatchBlobActive). So the roster here is built by the SAME rule:
# the seven slots below, in this order, each one only when its public key is
# non-empty — and NOT LCR_GATEWAY_PUBLIC_KEY (the gateway's claim key is not
# in the published roster).
#
# bin/lucairn-init --production runs this script itself. Run it again by hand
# only after you changed a key in customer.env (then recreate the gateway).
#
# Usage:
#   scripts/sign-witness-manifest.sh --env customer.env [--out <file>]
#
# Default output: <dir of the env file>/.certs/witness-signed-manifest.json
# (the host side of the gateway's `${SANDBOX_B_CERT_DIR:-./.certs}:/certs`
# mount when customer.env sits beside docker-compose.customer.yml), or
# $SANDBOX_B_CERT_DIR/witness-signed-manifest.json when customer.env sets it.
#
# The signing tool is the one shipped in the witness image, pinned by the
# signed digest of keys/image-digests-${LUCAIRN_IMAGE_TAG}.txt (as the manual
# ceremony in docs/KEY_CEREMONY_RUNBOOK.md § 6.2 is), from the registry of
# customer.env:
#   ${LUCAIRN_IMAGE_REGISTRY}/dsa-veil-witness@<signed digest>
# A mirror works only when it serves that same digest, i.e. the image was
# copied with all its platforms (crane copy, skopeo copy --all, docker buildx
# imagetools create) - the same condition `bin/lucairn verify-images` checks.
# A mutable tag is never run with the witness seed mounted. The container gets
# no network and the seed reaches it as a read-only private file, never as
# an argument of this host's docker command, and nothing secret is printed.
# Stated limit: inside the container the tool (images 1.1.1) takes the seed as
# a command-line flag, so while it runs (well under a second) the seed is in
# that process's arguments, which a local user of this host who may read
# other users' process lists can see. Run this on a host without untrusted
# local users.
#
# Refuses (exit 4) when the existing manifest holds keys that are not active
# (retired keys kept for the retention window): this script would rebuild
# every row as active and drop them. Rotations with retired keys follow the
# manual ceremony, docs/KEY_CEREMONY_RUNBOOK.md § 6.
#
# customer.env is read with a deliberately small parser: KEY=value,
# KEY="value" or KEY='value'. A value this script needs that holds $, a
# backslash or a backquote is refused (Compose would interpolate it; this
# script will not guess how). Stated limit: a line written
# `export KEY=value` is NOT read (Compose accepts it; here the key counts as
# absent and its roster row is left out); write such lines without `export`.
# Stated limit: the script does not check that the witness seed matches
# LCR_WITNESS_MANIFEST_PUBLIC_KEY; a mismatch is signed and the gateway then
# refuses to boot. The manifest it replaces is kept as <out>.prev.
#
# Exit codes: 0 written · 2 usage · 3 docker / image not available ·
#             4 customer.env incomplete or unreadable · 5 signing failed

set -euo pipefail

log() { printf '[sign-witness-manifest] %s\n' "$*" >&2; }
die() { local rc="$1"; shift; printf '[sign-witness-manifest] ERROR: %s\n' "$*" >&2; exit "$rc"; }

ENV_FILE=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_FILE="${2:?--env requires a path}"; shift 2 ;;
    --out) OUT="${2:?--out requires a path}"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
[ -n "$ENV_FILE" ] || die 2 "--env <customer.env> is required"
[ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ] || die 4 "cannot read $ENV_FILE"

# env_get <KEY> — last assignment wins (as in Compose); empty when absent.
env_get() {
  local key="$1" line val
  line="$(grep -E "^${key}=" "$ENV_FILE" | tail -1 || true)"
  val="${line#*=}"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  case "$val" in
    *'$'*|*'\'*|*'`'*) die 4 "$key in $ENV_FILE holds \$, a backslash or a backquote; set a plain value" ;;
  esac
  printf '%s' "$val"
}

ENV_DIR="$(cd "$(dirname "$ENV_FILE")" && pwd)"
if [ -z "$OUT" ]; then
  cert_dir="$(env_get SANDBOX_B_CERT_DIR)"
  case "$cert_dir" in
    '') cert_dir="$ENV_DIR/.certs" ;;
    /*) : ;;
    *) cert_dir="$ENV_DIR/${cert_dir#./}" ;;
  esac
  OUT="$cert_dir/witness-signed-manifest.json"
fi

registry="$(env_get LUCAIRN_IMAGE_REGISTRY)"; registry="${registry:-ghcr.io/declade}"
tag="$(env_get LUCAIRN_IMAGE_TAG)"; tag="${tag:-1.1.1}"
# Fix round 1 (review seat 4): the signed digest of this tag, never the tag.
KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
record="$KIT_ROOT/keys/image-digests-${tag}.txt"
digest="$(awk -v r="ghcr.io/declade/dsa-veil-witness:${tag}" '$1 == r { print $2 }' "$record" 2>/dev/null | tail -1)"
case "$digest" in
  sha256:[0-9a-f]*) [ "${#digest}" -eq 71 ] || digest="" ;;
  *) digest="" ;;
esac
[ -n "$digest" ] || die 3 "no signed digest for dsa-veil-witness:${tag} in $record; the signing tool runs only from the digest-pinned witness image"
IMAGE="${registry%/}/dsa-veil-witness@${digest}"

issuer="$(env_get LCR_ISSUER)"; issuer="${issuer:-$(env_get VEIL_ISSUER)}"; issuer="${issuer:-Lucairn Veil Witness}"
seed="$(env_get LCR_WITNESS_SIGNING_KEY)"; seed="${seed:-$(env_get VEIL_WITNESS_SIGNING_KEY)}"
case "$seed" in
  [0-9a-fA-F]*) [ "${#seed}" -eq 64 ] || die 4 "LCR_WITNESS_SIGNING_KEY must be 64 hex characters" ;;
  *) die 4 "LCR_WITNESS_SIGNING_KEY is missing or not hex in $ENV_FILE" ;;
esac
witness_pub="$(env_get LCR_WITNESS_PUBLIC_KEY)"; witness_pub="${witness_pub:-$(env_get VEIL_WITNESS_PUBLIC_KEY)}"
[ -n "$witness_pub" ] || die 4 "LCR_WITNESS_PUBLIC_KEY is empty in $ENV_FILE"

command -v docker >/dev/null 2>&1 || die 3 "docker is not installed or not on PATH"
docker info >/dev/null 2>&1 || die 3 "cannot reach the Docker daemon (is your user in the docker group?)"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "pulling $IMAGE (the signing tool ships inside it)"
  docker pull -q "$IMAGE" >/dev/null 2>&1 \
    || die 3 "image $IMAGE is not available: log in to the registry, or copy the image to your mirror with all its platforms so it keeps the signed digest (crane copy / skopeo copy --all / docker buildx imagetools create; a mirror holding only one platform serves another digest and is refused)"
fi

# Fix round 1 (review seat 13): retired keys in the existing manifest.
if [ -f "$OUT" ]; then
  python3 - "$OUT" <<'PYCHK' || die 4 "the existing manifest $OUT holds keys that are not active (retired keys) or cannot be read; this script would sign every key as active and drop them. Rotate with the manual ceremony (docs/KEY_CEREMONY_RUNBOOK.md § 6), or move the file aside if it belongs to keys this install no longer uses"
import base64, json, sys
blob = json.load(open(sys.argv[1]))
body = json.loads(base64.b64decode(blob["canonical_body_b64"]))
def states(node):
    if isinstance(node, dict):
        if "key_state" in node:
            yield node["key_state"]
        for v in node.values():
            yield from states(v)
    elif isinstance(node, list):
        for v in node:
            yield from states(v)
sys.exit(0 if all(s == "active" for s in states(body)) else 1)
PYCHK
fi

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# The roster, in the gateway's order (veil.go buildPublicKeyManifest).
: > "$WORK/roster.tsv"
add_row() { # <public key> <service_id> <key_id> <purpose>
  [ -n "$1" ] || return 0
  case "$1" in *[!0-9a-fA-F]*) die 4 "a public key for $3 is not hex" ;; esac
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$WORK/roster.tsv"
}
# Fix round 1 (review seat 12): a value env_get refuses (for example
# ${BRIDGE_PUB}, which Compose resolves and this script cannot) stops the
# script; it is never read as empty, which would drop that row from the
# signed roster while the gateway, reading the resolved value, expects it.
pick() { local v; v="$(env_get "$1")" || return 1; [ -n "$v" ] || { v="$(env_get "$2")" || return 1; }; printf '%s' "$v"; }
k_bridge="$(pick LCR_BRIDGE_PUBLIC_KEY VEIL_BRIDGE_PUBLIC_KEY)" || exit 4
k_sanitizer="$(pick LCR_SANITIZER_PUBLIC_KEY VEIL_SANITIZER_PUBLIC_KEY)" || exit 4
k_sandbox_b="$(pick LCR_SANDBOX_B_PUBLIC_KEY VEIL_SANDBOX_B_PUBLIC_KEY)" || exit 4
k_audit="$(pick LCR_AUDIT_PUBLIC_KEY VEIL_AUDIT_PUBLIC_KEY)" || exit 4
k_gw_manifest="$(pick LCR_GATEWAY_MANIFEST_PUBLIC_KEY VEIL_GATEWAY_MANIFEST_PUBLIC_KEY)" || exit 4
k_w_manifest="$(pick LCR_WITNESS_MANIFEST_PUBLIC_KEY VEIL_WITNESS_MANIFEST_PUBLIC_KEY)" || exit 4
add_row "$witness_pub" dsa-witness witness_v1 "Certificate signing"
add_row "$k_bridge" dsa-bridge bridge_v1 "Bridge claim signing"
add_row "$k_sanitizer" dsa-sanitizer sanitizer_v1 "Sanitizer claim signing"
add_row "$k_sandbox_b" dsa-ai sandbox_b_v1 "Inference claim signing"
add_row "$k_audit" dsa-audit audit_v1 "Audit claim signing"
add_row "$k_gw_manifest" dsa-gateway gateway_manifest_v1 "Manifest signing"
add_row "$k_w_manifest" dsa-witness witness_manifest_v1 "Manifest signing"

# keys.json (public values only).
{
  printf '['
  first=1
  while IFS="$(printf '\t')" read -r pub sid kid purpose; do
    [ "$first" = 1 ] || printf ','
    first=0
    printf '\n {"service_id":"%s","key_id":"%s","public_key":"%s","purpose":"%s","algorithm":"Ed25519","key_state":"active"}' \
      "$sid" "$kid" "$pub" "$purpose"
  done < "$WORK/roster.tsv"
  printf '\n]\n'
} > "$WORK/keys.json"
chmod 0644 "$WORK/keys.json"
chmod 0755 "$WORK"
rows="$(wc -l < "$WORK/roster.tsv" | tr -d ' ')"

# The seed as a private read-only file for the container (uid 0 inside a
# network-less container: the file is 0600 and owned by this user).
printf '%s' "$seed" > "$WORK/seed"
chmod 0600 "$WORK/seed"
seed=""

# Fix round 1 (review seat 14): created 0755 (not under umask 077), so the
# gateway (uid 10001) can traverse it to read the 0644 manifest.
( umask 022; mkdir -p "$(dirname "$OUT")" ) || die 4 "cannot create $(dirname "$OUT")"
if ! docker run --rm --network none --user 0 --entrypoint /bin/sh \
    -v "$WORK/keys.json:/keys.json:ro" \
    -v "$WORK/seed:/run/secrets/witness-signing-key-hex:ro" \
    "$IMAGE" \
    -ec 'exec sign-manifest --keys-json /keys.json --issuer "$1" --witness-signing-key-hex "$(cat /run/secrets/witness-signing-key-hex)" --witness-key-id witness_manifest_v1' \
    sign-manifest "$issuer" > "$WORK/blob.json" 2> "$WORK/sign.err"; then
  sed 's/[0-9a-fA-F]\{64,\}/<hex>/g' "$WORK/sign.err" >&2 || true
  die 5 "sign-manifest failed (image $IMAGE)"
fi
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["canonical_body_b64"] and d["witness_signature_hex"]' "$WORK/blob.json" 2>/dev/null \
  || die 5 "sign-manifest did not print a manifest blob"
cp "$WORK/blob.json" "$OUT.tmp.$$"
chmod 0644 "$OUT.tmp.$$"
[ ! -f "$OUT" ] || cp -p "$OUT" "$OUT.prev" || die 4 "cannot keep the previous manifest as $OUT.prev"
mv -f "$OUT.tmp.$$" "$OUT"
log "wrote $OUT ($rows roster entries, signed with the witness key; image $IMAGE)"
