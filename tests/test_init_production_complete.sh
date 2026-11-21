#!/usr/bin/env bash
# test_init_production_complete.sh — kit 2.0.1 (T-1479, PRD
# prd-2026-11-21-kit-customer-install-fix.md slice 1): a production
# customer.env from bin/lucairn-init needs no hand edit before `up`.
#
#   1. the rendered production env (--dry-run) carries a random Sandbox B key,
#      the public-log and timestamp addresses, both manifest public keys, the
#      Sandbox B witness client triple, the WITNESS_MTLS_* lines, the mirror
#      registry and the seat-lane line; dev mode carries none of the
#      production-only lines; the seat lane needs managed-byok
#   2. scripts/bootstrap-sanitizer-core-mtls.sh issues Sandbox B's server and
#      witness client leaves from the deploy CA, also when added to an
#      existing tree (upgrade)
#   3. scripts/sign-witness-manifest.sh builds the roster by the gateway's
#      rule (seven slots, gateway order, never LCR_GATEWAY_PUBLIC_KEY), reads
#      quoted values, uses the image of LUCAIRN_IMAGE_REGISTRY, gives the
#      container no network and keeps the seed out of its argv (docker stub)
#   4. the compose files hand Sandbox B its leaf, default streaming on and
#      keep both passthrough flags and the as-sent copy off
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/test-helpers.sh
. "$ROOT/tests/lib/test-helpers.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
N=0
pass() { N=$((N + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

printf '{"license_key":"synthetic.payload","signing_key":"synthetic-signing-key"}\n' > "$TMP/license.json"

# ── 1. rendered env ─────────────────────────────────────────────────────────
# --dry-run writes nothing, so the two host steps are not skipped here: the
# rendered lines are those of a real install.
render() { env -u LUCAIRN_INIT_SKIP_WITNESS_STEPS "$ROOT/bin/lucairn-init" --confirm-no-registry-volume "$@" --output "$TMP/customer.env" --dry-run 2>"$TMP/init.err"; }
render --production --license "$TMP/license.json" --runtime-mode managed-byok \
  --image-registry registry.internal.example:5000/declade --claude-seat-lane > "$TMP/prod.env" \
  || { cat "$TMP/init.err" >&2; fail "production dry run"; }
val() { grep -E "^$1=" "$2" | tail -1 | cut -d= -f2-; }
P="$TMP/prod.env"
k="$(val LOCAL_SANDBOX_B_API_KEY "$P")"
[ "${#k}" -eq 64 ] && [ "$k" != "local-sandbox-b-key" ] || fail "LOCAL_SANDBOX_B_API_KEY is not a fresh 64-hex secret"
pass "production env: LOCAL_SANDBOX_B_API_KEY random (not the well-known fallback)"
[ "$(val LCR_REKOR_URL "$P")" = "https://rekor.sigstore.dev" ] && [ "$(val LCR_TSA_URL "$P")" = "https://freetsa.org/tsr" ] \
  || fail "LCR_REKOR_URL / LCR_TSA_URL missing"
pass "production env: LCR_REKOR_URL + LCR_TSA_URL (approved sub-processors)"
gm="$(val LCR_GATEWAY_MANIFEST_PUBLIC_KEY "$P")"; wm="$(val LCR_WITNESS_MANIFEST_PUBLIC_KEY "$P")"
[ "${#gm}" -eq 64 ] && [ "$wm" = "$(val LCR_WITNESS_PUBLIC_KEY "$P")" ] || fail "manifest public keys not written"
derived="$(printf '%s' "$(val LCR_MANIFEST_SIGNING_KEY "$P")" | bash "$ROOT/scripts/derive-veil-pubkey.sh" 2>/dev/null || true)"
if [ -n "$derived" ]; then
  [ "$derived" = "$gm" ] || fail "LCR_GATEWAY_MANIFEST_PUBLIC_KEY is not the public half of LCR_MANIFEST_SIGNING_KEY"
fi
pass "production env: LCR_GATEWAY_MANIFEST_PUBLIC_KEY = pub(LCR_MANIFEST_SIGNING_KEY), LCR_WITNESS_MANIFEST_PUBLIC_KEY = LCR_WITNESS_PUBLIC_KEY"
[ "$(val LCR_WITNESS_MTLS_SANDBOX_B_CA_BUNDLE_PATH "$P")" = "/etc/sandbox-b-tls/ca.crt" ] \
  && [ "$(val LCR_WITNESS_MTLS_SANDBOX_B_CLIENT_CERT_PATH "$P")" = "/etc/sandbox-b-tls/witness-client.crt" ] \
  && [ "$(val LCR_WITNESS_MTLS_SANDBOX_B_CLIENT_KEY_PATH "$P")" = "/etc/sandbox-b-tls/witness-client.key" ] \
  || fail "Sandbox B witness client triple missing"
pass "production env: Sandbox B witness client triple"
[ "$(val WITNESS_MTLS_SERVER_CERT_PATH "$P")" = "/etc/witness-mtls/witness-server.crt" ] \
  && [ "$(val LCR_WITNESS_MTLS_HOST_DIR "$P")" = "/etc/witness-mtls" ] || fail "WITNESS_MTLS_* lines not filled"
pass "env: WITNESS_MTLS_* lines filled for /etc/witness-mtls"
LUCAIRN_INIT_SKIP_WITNESS_STEPS=1 "$ROOT/bin/lucairn-init" --confirm-no-registry-volume --production --license "$TMP/license.json" \
  --runtime-mode managed-byok --output "$TMP/customer.env" --dry-run > "$TMP/skip.env" 2>/dev/null || fail "skip dry run"
[ -z "$(val WITNESS_MTLS_SERVER_CERT_PATH "$TMP/skip.env")" ] && [ -z "$(val LCR_WITNESS_MTLS_HOST_DIR "$TMP/skip.env")" ] \
  || fail "skipped witness step still names /etc/witness-mtls files"
pass "env: with the witness step skipped (tests) the WITNESS_MTLS_* lines stay empty"
[ "$(val LUCAIRN_IMAGE_REGISTRY "$P")" = "registry.internal.example:5000/declade" ] || fail "--image-registry not written"
[ "$(val LUCAIRN_CLAUDE_SEAT_LANE "$P")" = "true" ] && [ "$(val SANDBOX_B_UPSTREAM_BODY_STORE "$P")" = "false" ] || fail "seat lane / body store lines"
pass "env: --image-registry and --claude-seat-lane written, as-sent copy off"
[ "$(grep -c '^LCR_REKOR_URL=' "$P")" = 1 ] && [ "$(grep -c '^LOCAL_SANDBOX_B_API_KEY=' "$P")" = 1 ] || fail "duplicate keys"
pass "env: no duplicate keys for the new lines"

render --dev --runtime-mode managed-byok > "$TMP/dev.env" || { cat "$TMP/init.err" >&2; fail "dev dry run"; }
D="$TMP/dev.env"
! grep -qE '^(LCR_REKOR_URL|LCR_TSA_URL|LCR_WITNESS_MTLS_SANDBOX_B_CA_BUNDLE_PATH)=' "$D" || fail "dev env carries production-only lines"
[ "$(val LUCAIRN_CLAUDE_SEAT_LANE "$D")" = "false" ] || fail "seat lane must default off"
pass "dev env: no production-only lines, seat lane off by default"

if "$ROOT/bin/lucairn-init" --confirm-no-registry-volume --production --license "$TMP/license.json" \
     --runtime-mode split-remote --remote-endpoint https://x.example --remote-credentials /nonexistent \
     --claude-seat-lane --output "$TMP/c.env" --dry-run >/dev/null 2>"$TMP/seat.err"; then
  fail "--claude-seat-lane accepted outside managed-byok"
fi
grep -q "claude-seat-lane needs --runtime-mode managed-byok" "$TMP/seat.err" || fail "seat lane refusal message"
pass "--claude-seat-lane refused outside managed-byok"
if render --dev --runtime-mode managed-byok --claude-seat-lane >/dev/null; then
  fail "--claude-seat-lane accepted with --dev"
fi
grep -q "claude-seat-lane needs --production" "$TMP/init.err" || fail "seat lane dev refusal message"
pass "--claude-seat-lane refused outside production (dev links run without TLS)"

# ── 2. Sandbox B leaves ─────────────────────────────────────────────────────
C="$TMP/kit/.certs/sanitizer-core-mtls"
mkdir -p "$TMP/kit"
bash "$ROOT/scripts/bootstrap-sanitizer-core-mtls.sh" "$C" > "$TMP/boot.out" 2>&1 || { cat "$TMP/boot.out" >&2; fail "bootstrap"; }
for f in ca.crt dsa-sandbox-b.crt dsa-sandbox-b.key witness-client.crt witness-client.key; do
  [ -f "$C/sandbox-b/$f" ] || fail "sandbox-b/$f missing"
done
CA="$TMP/kit/.secrets/sanitizer-core-mtls-ca/ca.crt"
openssl verify -CAfile "$CA" -purpose sslserver "$C/sandbox-b/dsa-sandbox-b.crt" >/dev/null 2>&1 || fail "sandbox-b server leaf does not verify"
openssl x509 -in "$C/sandbox-b/dsa-sandbox-b.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:dsa-sandbox-b" || fail "SAN dsa-sandbox-b"
openssl verify -CAfile "$CA" -purpose sslclient "$C/sandbox-b/witness-client.crt" >/dev/null 2>&1 || fail "sandbox-b witness client leaf"
pass "bootstrap: Sandbox B server leaf (SAN dsa-sandbox-b) + witness client leaf, signed by the deploy CA"
rm -rf "$C/sandbox-b"
before="$(openssl x509 -in "$C/gateway/dsa-gateway.crt" -noout -fingerprint -sha256)"
bash "$ROOT/scripts/bootstrap-sanitizer-core-mtls.sh" "$C" > "$TMP/boot2.out" 2>&1 || { cat "$TMP/boot2.out" >&2; fail "bootstrap rerun"; }
[ -f "$C/sandbox-b/dsa-sandbox-b.crt" ] && [ "$before" = "$(openssl x509 -in "$C/gateway/dsa-gateway.crt" -noout -fingerprint -sha256)" ] \
  || fail "upgrade run did not add the Sandbox B pair without rotating the rest"
pass "bootstrap upgrade: existing tree gains the Sandbox B pair, other leaves unchanged"

# ── 3. sign-witness-manifest.sh roster (docker stub) ───────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  image) exit 0 ;;
  run)
    printf '%s\n' "$@" > "$STUB_DIR/argv"
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-v" ]; then
        src="${a%%:*}"; rest="${a#*:}"; dst="${rest%%:*}"
        [ "$dst" = "/keys.json" ] && cp "$src" "$STUB_DIR/keys.json"
        [ "$dst" = "/run/secrets/witness-signing-key-hex" ] && cp "$src" "$STUB_DIR/seed"
      fi
      prev="$a"
    done
    last=""; for a in "$@"; do last="$a"; done
    printf '%s' "$last" > "$STUB_DIR/issuer"
    printf '{"canonical_body_b64":"e30=","witness_signature_hex":"00","witness_signing_key_id":"witness_manifest_v1","witness_signing_algorithm":"Ed25519"}\n'
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/docker"
mkdir -p "$TMP/stub"
cp "$P" "$TMP/sign.env"
OUTB="$TMP/out/witness-signed-manifest.json"
PATH="$TMP/bin:$PATH" STUB_DIR="$TMP/stub" bash "$ROOT/scripts/sign-witness-manifest.sh" --env "$TMP/sign.env" --out "$OUTB" > "$TMP/sign.out" 2>&1 \
  || { cat "$TMP/sign.out" >&2; fail "sign-witness-manifest.sh"; }
[ -s "$OUTB" ] || fail "no blob written"
python3 - "$TMP/stub/keys.json" "$TMP/sign.env" <<'PY' || fail "roster does not follow the gateway's rule"
import json, sys
keys = json.load(open(sys.argv[1]))
env = {}
for line in open(sys.argv[2]):
    line = line.rstrip("\n")
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        env[k] = v
want = [("LCR_WITNESS_PUBLIC_KEY", "dsa-witness", "witness_v1"), ("LCR_BRIDGE_PUBLIC_KEY", "dsa-bridge", "bridge_v1"),
        ("LCR_SANITIZER_PUBLIC_KEY", "dsa-sanitizer", "sanitizer_v1"), ("LCR_SANDBOX_B_PUBLIC_KEY", "dsa-ai", "sandbox_b_v1"),
        ("LCR_AUDIT_PUBLIC_KEY", "dsa-audit", "audit_v1"), ("LCR_GATEWAY_MANIFEST_PUBLIC_KEY", "dsa-gateway", "gateway_manifest_v1"),
        ("LCR_WITNESS_MANIFEST_PUBLIC_KEY", "dsa-witness", "witness_manifest_v1")]
assert [(k["service_id"], k["key_id"], k["public_key"]) for k in keys] == [(s, i, env[e]) for e, s, i in want], keys
assert env["LCR_GATEWAY_PUBLIC_KEY"] not in [k["public_key"] for k in keys]
assert all(k["algorithm"] == "Ed25519" and k["key_state"] == "active" for k in keys)
PY
pass "sign-witness-manifest: 7 entries in the gateway's order, LCR_GATEWAY_PUBLIC_KEY not in it"
[ "$(cat "$TMP/stub/issuer")" = "Lucairn Veil Witness" ] || fail "issuer quotes not stripped"
grep -qx -- "--network" "$TMP/stub/argv" && grep -qx none "$TMP/stub/argv" || fail "container has a network"
WDIGEST="$(awk '$1 == "ghcr.io/declade/dsa-veil-witness:1.1.1" { print $2 }' "$ROOT/keys/image-digests-1.1.1.txt")"
grep -qx "registry.internal.example:5000/declade/dsa-veil-witness@$WDIGEST" "$TMP/stub/argv" \
  || fail "image not the signed digest from LUCAIRN_IMAGE_REGISTRY"
! grep -q 'dsa-veil-witness:1.1.1' "$TMP/stub/argv" || fail "a mutable tag reached docker run"
! grep -q "$(val LCR_WITNESS_SIGNING_KEY "$P")" "$TMP/stub/argv" || fail "witness seed in docker argv"
[ "$(cat "$TMP/stub/seed")" = "$(val LCR_WITNESS_SIGNING_KEY "$P")" ] || fail "seed file content"
pass "sign-witness-manifest: issuer unquoted, digest-pinned mirror image, --network none, seed only as a mounted file"
grep -v '^LCR_WITNESS_SIGNING_KEY=' "$P" > "$TMP/noseed.env"
if PATH="$TMP/bin:$PATH" STUB_DIR="$TMP/stub" bash "$ROOT/scripts/sign-witness-manifest.sh" --env "$TMP/noseed.env" --out "$TMP/x.json" >/dev/null 2>&1; then
  fail "signed without a witness seed"
fi
pass "sign-witness-manifest: refuses an env without the witness seed"

# Fix round 1 (review seat 12): a value the parser cannot read literally stops
# the script; it is never signed as an empty (missing) row.
sed 's/^LCR_BRIDGE_PUBLIC_KEY=.*/LCR_BRIDGE_PUBLIC_KEY=${BRIDGE_PUB}/' "$TMP/sign.env" > "$TMP/var.env"
rm -f "$TMP/var.json"
if PATH="$TMP/bin:$PATH" STUB_DIR="$TMP/stub" bash "$ROOT/scripts/sign-witness-manifest.sh" --env "$TMP/var.env" --out "$TMP/var.json" >/dev/null 2>"$TMP/var.err"; then
  fail "signed although LCR_BRIDGE_PUBLIC_KEY could not be read"
fi
[ ! -e "$TMP/var.json" ] && grep -q 'LCR_BRIDGE_PUBLIC_KEY' "$TMP/var.err" || fail "unreadable public key: no clear stop"
pass "sign-witness-manifest: a public key it cannot read literally (\${VAR}) stops it (no row dropped)"
# Fix round 1 (review seat 13): retired keys in the existing manifest.
python3 - "$OUTB" <<'PYR'
import base64, json, sys
body = [{"service_id": "dsa-witness", "key_id": "witness_v0", "public_key": "00", "purpose": "Certificate signing",
         "algorithm": "Ed25519", "key_state": "retired"}]
json.dump({"canonical_body_b64": base64.b64encode(json.dumps(body).encode()).decode(), "witness_signature_hex": "00"},
          open(sys.argv[1], "w"))
PYR
before_blob="$(cat "$OUTB")"
if PATH="$TMP/bin:$PATH" STUB_DIR="$TMP/stub" bash "$ROOT/scripts/sign-witness-manifest.sh" --env "$TMP/sign.env" --out "$OUTB" >/dev/null 2>"$TMP/ret.err"; then
  fail "overwrote a manifest that holds retired keys"
fi
[ "$(cat "$OUTB")" = "$before_blob" ] && grep -q 'manual ceremony' "$TMP/ret.err" || fail "retired-key refusal"
pass "sign-witness-manifest: refuses to overwrite a manifest with retired keys (points to the manual ceremony)"
# Fix round 1 (review seat 14): a new output folder is traversable (0755).
PATH="$TMP/bin:$PATH" STUB_DIR="$TMP/stub" bash "$ROOT/scripts/sign-witness-manifest.sh" --env "$TMP/sign.env" --out "$TMP/newdir/a/witness-signed-manifest.json" >/dev/null 2>&1 \
  || fail "sign into a new folder"
for d in "$TMP/newdir" "$TMP/newdir/a"; do
  [ "$(stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d")" = 755 ] || fail "$d is not 0755"
done
pass "sign-witness-manifest: output folders it creates are 0755 (gateway uid 10001 can traverse)"
# Fix round 1 (review seat 4): no signed digest for the tag = no signing.
sed 's/^LUCAIRN_IMAGE_TAG=.*/LUCAIRN_IMAGE_TAG=9.9.9/' "$TMP/sign.env" > "$TMP/tag.env"
if PATH="$TMP/bin:$PATH" STUB_DIR="$TMP/stub" bash "$ROOT/scripts/sign-witness-manifest.sh" --env "$TMP/tag.env" --out "$TMP/tag.json" >/dev/null 2>&1; then
  fail "signed with a tag that has no signed digest record"
fi
pass "sign-witness-manifest: refuses a tag without a signed digest record"

# ── 4. compose wiring ───────────────────────────────────────────────────────
SH="$ROOT/docker-compose.self-hosted.yml"; CU="$ROOT/docker-compose.customer.yml"
grep -q 'GRPC_TLS_CERT: "${SANDBOX_B_GRPC_TLS_CERT:-/etc/sandbox-b-tls/dsa-sandbox-b.crt}"' "$SH" \
  && grep -q '/sandbox-b:/etc/sandbox-b-tls:ro' "$SH" || fail "Sandbox B leaf not wired"
grep -q 'SANDBOX_B_OAUTH_PASSTHROUGH_ENABLED: "${LUCAIRN_CLAUDE_SEAT_LANE:-false}"' "$SH" \
  && grep -q 'GATEWAY_OAUTH_PASSTHROUGH_ENABLED: "${LUCAIRN_CLAUDE_SEAT_LANE:-false}"' "$CU" \
  && grep -q 'SANDBOX_B_UPSTREAM_BODY_STORE: "${SANDBOX_B_UPSTREAM_BODY_STORE:-false}"' "$SH" \
  && grep -q 'STREAMING_ENABLED: "${STREAMING_ENABLED:-true}"' "$CU" || fail "compose defaults"
pass "compose: Sandbox B leaf mounted, streaming default on, seat lane + as-sent copy default off"

# ── 5. full init (no --dry-run) with stubbed sudo / docker ──────────────────
# Fix round 1 (bug review N4, review seats 1, 5, 10, 16, 18): the host steps
# themselves, on a copy of the kit (the manifest lands in <kit>/.certs).
K="$TMP/kitcopy"; mkdir -p "$K"
(cd "$ROOT" && tar --exclude=.git -cf - .) | (cd "$K" && tar -xf -)
W="$TMP/witness-mtls"
SB="$TMP/sbin"; mkdir -p "$SB"
cat > "$SB/sudo" <<'STUB'
#!/usr/bin/env bash
# sudo stub: records every call; chown / find (the hand-over) are recorded
# only (the test is not root)
printf '%s\n' "$*" >> "$STUB_DIR/sudo.log"
case "$1" in chown|find) exit 0 ;; esac
exec "$@"
STUB
cat > "$SB/docker" <<'STUB'
#!/usr/bin/env bash
# docker stub: the witness image is "missing" while $STUB_DIR/no-image exists;
# run = the signing tool; everything else goes to the real docker CLI
# (compose config, volume ls).
case "$1" in
  image|pull) [ -e "$STUB_DIR/no-image" ] && exit 1; exit 0 ;;
  run) printf '{"canonical_body_b64":"W10=","witness_signature_hex":"00"}\n'; exit 0 ;;
esac
for d in $(type -ap docker); do [ "$d" = "$0" ] || exec "$d" "$@"; done
exit 1
STUB
cat > "$SB/python3" <<'STUB'
#!/usr/bin/env bash
# python3 stub: records the arguments of every call (seat 5)
printf '%s\n' "$*" >> "$STUB_DIR/python-argv.log"
for p in $(type -ap python3); do [ "$p" = "$0" ] || exec "$p" "$@"; done
exit 1
STUB
chmod +x "$SB/sudo" "$SB/docker" "$SB/python3"
FS="$TMP/fullstub"; mkdir -p "$FS"; : > "$FS/sudo.log"; : > "$FS/python-argv.log"
O="$TMP/full/customer.env"; mkdir -p "$TMP/full" "$K/.certs"
echo '{"old":"blob"}' > "$K/.certs/witness-signed-manifest.json"
full_init() {
  env -u LUCAIRN_INIT_SKIP_WITNESS_STEPS PATH="$SB:$PATH" STUB_DIR="$FS" LUCAIRN_INIT_TEST_WITNESS_MTLS_DIR="$W" \
    "$K/bin/lucairn-init" --confirm-no-registry-volume "$@" 2>>"$TMP/full.err"
}
touch "$FS/no-image"
rc=0; full_init --production --license "$TMP/license.json" --runtime-mode managed-byok --output "$O" >/dev/null || rc=$?
[ "$rc" = 10 ] || { tail -20 "$TMP/full.err" >&2; fail "image missing: init exit $rc, want 10"; }
stale=("$K"/.certs/witness-signed-manifest.json.stale-*)
[ -e "${stale[0]}" ] && [ ! -e "$K/.certs/witness-signed-manifest.json" ] \
  || fail "stale manifest not moved aside"
for f in ca.crt ca.key witness-server.crt gateway-client.crt sandbox-a-client.crt; do [ -f "$W/$f" ] || fail "witness folder lacks $f"; done
if [ "$(uname -s)" = "Linux" ]; then
  grep -q "^find $W ! -name ca.key -exec chown 10001:10001 " "$FS/sudo.log" && ! grep -q '^chown' "$FS/sudo.log" \
    || fail "witness folder hand-over must skip ca.key (no chown -R, no chown-back)"
fi
[ "$(val WITNESS_MTLS_CA_BUNDLE_PATH "$O")" = "$W/ca.crt" ] || fail "WITNESS_MTLS_* lines of the full init"
pass "full init: witness folder created, old manifest moved aside, exit 10 while the witness image is missing"
[ -s "$FS/python-argv.log" ] && ! grep -Eq "[0-9a-f]{64}" "$FS/python-argv.log" || fail "a 64-hex value reached python's arguments (or python never ran)"
pass "full init: no seed in a python process argument"
rc=0; full_init --production --license "$TMP/license.json" --runtime-mode managed-byok --output "$O" >/dev/null || rc=$?
[ "$rc" = 10 ] || fail "re-run with the image still missing: exit $rc, want 10 (never 0)"
pass "re-run (already initialized, manifest missing): exit 10, not 0"
rm -f "$FS/no-image"
rc=0; full_init --production --license "$TMP/license.json" --runtime-mode managed-byok --output "$O" >/dev/null || rc=$?
[ "$rc" = 0 ] && [ -s "$K/.certs/witness-signed-manifest.json" ] || fail "re-run with the image: exit $rc / no manifest"
grep -q 'completed the missing host steps: manifest' "$TMP/full.err" || fail "resume message"
pass "re-run with the image back: completes the manifest, exit 0"
rc=0; full_init --production --license "$TMP/license.json" --runtime-mode managed-byok --output "$O" >/dev/null || rc=$?
[ "$rc" = 0 ] && grep -q 'every host step is in place' "$TMP/full.err" || fail "complete re-run"
for flag in "--image-registry registry.other.example/declade" "--claude-seat-lane"; do
  rc=0
  # shellcheck disable=SC2086
  full_init --production --license "$TMP/license.json" --runtime-mode managed-byok $flag --output "$O" >/dev/null || rc=$?
  [ "$rc" != 0 ] || fail "re-run silently ignored $flag"
done
pass "re-run: a complete install exits 0; --image-registry / --claude-seat-lane that differ are refused, not ignored"
rm -rf "$W"; : > "$W"   # a file where the folder belongs: the witness step fails
rc=0; full_init --production --license "$TMP/license.json" --runtime-mode managed-byok --output "$O" >/dev/null || rc=$?
[ "$rc" = 9 ] || fail "witness folder cannot be created: exit $rc, want 9"
rm -f "$W"
rc=0; full_init --production --license "$TMP/license.json" --runtime-mode managed-byok --output "$O" >/dev/null || rc=$?
[ "$rc" = 0 ] && [ -f "$W/witness-server.crt" ] || fail "re-run after exit 9: exit $rc"
pass "exit 9 when the witness folder fails; the same command afterwards completes it"
mv "$TMP/full/.certs/sanitizer-core-mtls/sandbox-b" "$TMP/sb-aside"
rc=0; full_init --production --license "$TMP/license.json" --runtime-mode managed-byok --output "$O" >/dev/null || rc=$?
[ "$rc" = 0 ] && [ -f "$TMP/full/.certs/sanitizer-core-mtls/sandbox-b/dsa-sandbox-b.crt" ] || fail "re-run did not issue the Sandbox B leaves"
pass "re-run on a tree without the Sandbox B leaves (kit 2.0.0) issues them"
# --dev: no witness folder step, no sudo (review seat 18)
: > "$FS/sudo.log"
rc=0; full_init --dev --runtime-mode managed-byok --output "$TMP/dev/customer.env" >/dev/null || rc=$?
[ "$rc" = 0 ] || { tail -5 "$TMP/full.err" >&2; fail "dev init exit $rc"; }
! grep -q 'bootstrap-mtls-ca' "$FS/sudo.log" && [ -z "$(val WITNESS_MTLS_CA_BUNDLE_PATH "$TMP/dev/customer.env")" ] \
  || fail "dev init ran the witness folder step"
pass "dev init: no witness folder step, no sudo for it, WITNESS_MTLS_* lines empty (as before kit 2.0.1)"
# a failed random draw for LOCAL_SANDBOX_B_API_KEY stops init (review seat 16):
# the 8th `openssl rand -hex 32` of a managed-byok init (6 pair seeds + the
# manifest seed come first).
cat > "$SB/openssl" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "rand -hex 32" ]; then
  n=$(( $(cat "$STUB_DIR/rand.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/rand.n"
  [ "$n" = 8 ] && exit 1
fi
for o in $(type -ap openssl); do [ "$o" = "$0" ] || exec "$o" "$@"; done
exit 1
STUB
chmod +x "$SB/openssl"; rm -f "$FS/rand.n"
rc=0; full_init --production --license "$TMP/license.json" --runtime-mode managed-byok --output "$TMP/rand/customer.env" >/dev/null || rc=$?
rm -f "$SB/openssl"
[ "$rc" = 3 ] && [ ! -e "$TMP/rand/customer.env" ] && grep -q 'LOCAL_SANDBOX_B_API_KEY' "$TMP/full.err" || fail "failed draw: exit $rc"
pass "a failed draw for LOCAL_SANDBOX_B_API_KEY stops init before customer.env is written"
grep -q 'lucairn-mint-customer .*--tier enterprise --no-byok-per-request' "$TMP/full.err" || fail "mint hint without --no-byok-per-request"
pass "init's first-key command for a local Sandbox B mints without byok_per_request (no 400 missing_upstream_key)"
mint_byok() { LUCAIRN_ADMIN_KEY=synthetic-admin "$ROOT/bin/lucairn-mint-customer" --dry-run --name "Acme GmbH" --email ops@acme.example --tier enterprise "$@" 2>&1 | grep -c '"byok_per_request": false'; }
[ "$(mint_byok --no-byok-per-request)" = 1 ] && [ "$(mint_byok)" = 0 ] || fail "mint payload byok_per_request"
grep -q -- '--tier enterprise --no-byok-per-request > ~/lucairn-first.key' "$ROOT/INSTALL.md" || fail "fast path mint command"
pass "fast-path mint command sends byok_per_request=false (Enterprise default is true; gateway 400 not run live)"

# ── 6. bootstrap-mtls-ca.sh without ca.key (review seat 11) ─────────────────
B="$TMP/wca"; bash "$ROOT/scripts/bootstrap-mtls-ca.sh" "$B" >/dev/null 2>&1 || fail "witness CA bootstrap"
mv "$B/ca.key" "$TMP/ca.key.offline"; crt_before="$(cat "$B/ca.crt")"
bash "$ROOT/scripts/bootstrap-mtls-ca.sh" "$B" >/dev/null 2>&1 || fail "complete folder without ca.key"
[ "$(cat "$B/ca.crt")" = "$crt_before" ] && [ ! -e "$B/ca.key" ] || fail "CA replaced"
rm -f "$B/gateway-client.key" "$B/gateway-client.crt"
if bash "$ROOT/scripts/bootstrap-mtls-ca.sh" "$B" >/dev/null 2>"$TMP/wca.err"; then fail "new CA minted over old leaves"; fi
[ "$(cat "$B/ca.crt")" = "$crt_before" ] && grep -q 'ca.key is missing' "$TMP/wca.err" || fail "refusal message / ca.crt changed"
pass "bootstrap-mtls-ca: ca.key kept offline = nothing issued when complete, a clear refusal when a leaf is missing"

# ── 7. offline doctor: when the seat lane counts as a provider (seat 15) ────
FN="$TMP/byok-fn.sh"
{ sed -n '/^env_value() {/,/^}/p' "$ROOT/bin/lucairn"; sed -n '/^check_byok_overlay() {/,/^}/p' "$ROOT/bin/lucairn"
  echo 'runtime_profile_selected_compose_file() { echo docker-compose.self-hosted-byok.yml; }'; } > "$FN"
byok_check() { printf '%s\n' "$@" > "$TMP/byok.env"; bash -c '. "$1"; check_byok_overlay "$2"' _ "$FN" "$TMP/byok.env" >/dev/null; }
byok_check LUCAIRN_CLAUDE_SEAT_LANE=true LUCAIRN_LLM_EGRESS_ALLOWLIST=api.anthropic.com,api.openai.com || fail "seat lane + Anthropic allowed"
if byok_check LUCAIRN_CLAUDE_SEAT_LANE=true LUCAIRN_LLM_EGRESS_ALLOWLIST=api.openai.com; then fail "seat lane counted although Anthropic is not allowed"; fi
if byok_check LUCAIRN_CLAUDE_SEAT_LANE=true LUCAIRN_LLM_EGRESS_ALLOWLIST=api.anthropic.com SANDBOX_B_REMOTE_ENDPOINT=https://x.example; then
  fail "seat lane counted for a remote Sandbox B"
fi
if byok_check LUCAIRN_CLAUDE_SEAT_LANE=false LUCAIRN_LLM_EGRESS_ALLOWLIST=api.anthropic.com; then fail "no key, no seat lane: passed"; fi
pass "offline doctor: the seat lane is a provider only for a local Sandbox B whose allowlist names api.anthropic.com"

echo "init production completeness: $N checks ok"
