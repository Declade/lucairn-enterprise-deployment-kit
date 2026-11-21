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
grep -qx "registry.internal.example:5000/declade/dsa-veil-witness:1.1.1" "$TMP/stub/argv" || fail "image not from LUCAIRN_IMAGE_REGISTRY"
! grep -q "$(val LCR_WITNESS_SIGNING_KEY "$P")" "$TMP/stub/argv" || fail "witness seed in docker argv"
[ "$(cat "$TMP/stub/seed")" = "$(val LCR_WITNESS_SIGNING_KEY "$P")" ] || fail "seed file content"
pass "sign-witness-manifest: issuer unquoted, mirror image, --network none, seed only as a mounted file"
grep -v '^LCR_WITNESS_SIGNING_KEY=' "$P" > "$TMP/noseed.env"
if PATH="$TMP/bin:$PATH" STUB_DIR="$TMP/stub" bash "$ROOT/scripts/sign-witness-manifest.sh" --env "$TMP/noseed.env" --out "$TMP/x.json" >/dev/null 2>&1; then
  fail "signed without a witness seed"
fi
pass "sign-witness-manifest: refuses an env without the witness seed"

# ── 4. compose wiring ───────────────────────────────────────────────────────
SH="$ROOT/docker-compose.self-hosted.yml"; CU="$ROOT/docker-compose.customer.yml"
grep -q 'GRPC_TLS_CERT: "${SANDBOX_B_GRPC_TLS_CERT:-/etc/sandbox-b-tls/dsa-sandbox-b.crt}"' "$SH" \
  && grep -q '/sandbox-b:/etc/sandbox-b-tls:ro' "$SH" || fail "Sandbox B leaf not wired"
grep -q 'SANDBOX_B_OAUTH_PASSTHROUGH_ENABLED: "${LUCAIRN_CLAUDE_SEAT_LANE:-false}"' "$SH" \
  && grep -q 'GATEWAY_OAUTH_PASSTHROUGH_ENABLED: "${LUCAIRN_CLAUDE_SEAT_LANE:-false}"' "$CU" \
  && grep -q 'SANDBOX_B_UPSTREAM_BODY_STORE: "${SANDBOX_B_UPSTREAM_BODY_STORE:-false}"' "$SH" \
  && grep -q 'STREAMING_ENABLED: "${STREAMING_ENABLED:-true}"' "$CU" || fail "compose defaults"
pass "compose: Sandbox B leaf mounted, streaming default on, seat lane + as-sent copy default off"

echo "init production completeness: $N checks ok"
