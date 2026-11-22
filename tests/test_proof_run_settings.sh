#!/usr/bin/env bash
# test_proof_run_settings.sh — kit 2.0.1 (T-1479, findings of the proof run of
# 2026-11-22 on a fresh server):
#
#   1. Compose: LCR_CLAIM_TIMEOUT reaches the witness; unset or empty = 330s
#      (it was hard-wired "30s"); a set value wins; no other service gets it.
#      The kit never sets LUCAIRN_REID_GUARD_REQUIRED (under it a
#      certificate-only chain always waits the full window, veil-witness
#      accumulator.go isExactCertOnlyTopology).
#   2. Compose: GATEWAY_TRUSTED_PROXY_SETS_REAL_IP reaches the gateway; unset
#      or empty = "" (the image default: not asserted); "true" passes through.
#   3. customer.env.example documents both settings.
#   4. INSTALL.md's trusted-proxy command keeps only valid addresses: on
#      Docker 29 a network without a gateway prints "invalid IP" (the proof
#      run's F-cidr-cmd); the documented filter drops it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

FIX="$ROOT/tests/fixtures/servicenow-control/off/synthetic.env.fixture"
render() {  # extra env file -> rendered project as JSON
  env -i PATH="$PATH" HOME="$HOME" docker compose --env-file "$FIX" --env-file "$1" \
    --project-directory "$ROOT" --project-name prs -f "$ROOT/docker-compose.customer.yml" \
    config --format json 2>"$TMP/compose.err"
}
value_of() {  # rendered JSON, service, variable -> value ("-" = absent)
  python3 -c '
import json, sys
env = json.load(open(sys.argv[1]))["services"][sys.argv[2]].get("environment") or {}
print(env.get(sys.argv[3], "-"))
' "$1" "$2" "$3"
}
holders_of() {  # rendered JSON, variable -> services that carry it
  python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))["services"]
print(" ".join(sorted(n for n, v in s.items() if sys.argv[2] in (v.get("environment") or {}))))
' "$1" "$2"
}

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  # ── 1. witness claim window ────────────────────────────────────────────────
  for case in "absent::330s" "empty:LCR_CLAIM_TIMEOUT=:330s" "set:LCR_CLAIM_TIMEOUT=600s:600s"; do
    name="${case%%:*}"; rest="${case#*:}"; line="${rest%%:*}"; want="${rest#*:}"
    printf '%s\n' "$line" > "$TMP/cw-$name.env"
    render "$TMP/cw-$name.env" > "$TMP/cw-$name.json" || { cat "$TMP/compose.err" >&2; fail "compose config (claim window $name)"; }
    got="$(value_of "$TMP/cw-$name.json" veil-witness LCR_CLAIM_TIMEOUT)"
    [ "$got" = "$want" ] || fail "witness LCR_CLAIM_TIMEOUT ($name): got '$got', want '$want'"
  done
  [ "$(holders_of "$TMP/cw-set.json" LCR_CLAIM_TIMEOUT)" = "veil-witness" ] || fail "LCR_CLAIM_TIMEOUT reaches services other than the witness"
  [ -z "$(holders_of "$TMP/cw-set.json" LUCAIRN_REID_GUARD_REQUIRED)" ] || fail "the kit must not set LUCAIRN_REID_GUARD_REQUIRED"
  pass "compose: witness LCR_CLAIM_TIMEOUT absent/empty -> 330s, 600s -> 600s, witness only; LUCAIRN_REID_GUARD_REQUIRED not set"

  # ── 2. trusted-proxy assertion ─────────────────────────────────────────────
  for case in "absent::" "empty:GATEWAY_TRUSTED_PROXY_SETS_REAL_IP=:" "set:GATEWAY_TRUSTED_PROXY_SETS_REAL_IP=true:true"; do
    name="${case%%:*}"; rest="${case#*:}"; line="${rest%%:*}"; want="${rest#*:}"
    printf '%s\n' "$line" > "$TMP/rip-$name.env"
    render "$TMP/rip-$name.env" > "$TMP/rip-$name.json" || { cat "$TMP/compose.err" >&2; fail "compose config (real ip $name)"; }
    got="$(value_of "$TMP/rip-$name.json" gateway GATEWAY_TRUSTED_PROXY_SETS_REAL_IP)"
    [ "$got" = "$want" ] || fail "gateway GATEWAY_TRUSTED_PROXY_SETS_REAL_IP ($name): got '$got', want '$want'"
  done
  pass "compose: gateway GATEWAY_TRUSTED_PROXY_SETS_REAL_IP absent/empty -> '' (not asserted), true -> true"
else
  echo "skip compose render: docker compose not available (NOT RUN)"
fi

# ── 3. customer.env.example ──────────────────────────────────────────────────
for key in LCR_CLAIM_TIMEOUT GATEWAY_TRUSTED_PROXY_SETS_REAL_IP; do
  [ "$(grep -c "^$key=$" "$ROOT/customer.env.example")" = 1 ] || fail "customer.env.example: exactly one empty $key= line"
done
pass "customer.env.example: LCR_CLAIM_TIMEOUT= and GATEWAY_TRUSTED_PROXY_SETS_REAL_IP= documented, empty"

# ── 4. the documented trusted-proxy filter ───────────────────────────────────
# The filter line of INSTALL.md (§ "Reverse proxy") is read from the file and
# fed what `docker inspect` printed on Docker 29.1.3 in the proof run.
filter="$(grep -E "^  \\| grep -E '\\^\\[0-9\\]" "$ROOT/INSTALL.md" | head -1 | sed 's/^  | //')"
[ -n "$filter" ] || fail "INSTALL.md: trusted-proxy filter line not found"
got="$(printf 'invalid IP\ninvalid IP\n172.24.0.1\ninvalid IP\n\n172.29.0.1\n' | bash -c "$filter")"
[ "$got" = "172.24.0.1/32,172.29.0.1/32" ] || fail "trusted-proxy filter: got '$got'"
pass "INSTALL.md: trusted-proxy filter keeps 172.24.0.1/32,172.29.0.1/32 and drops 'invalid IP' and empty lines"

# ── 5. init's closing hint matches the fast path (F-init-hint) ───────────────
printf '{"license_key":"synthetic.payload","signing_key":"synthetic-signing-key"}\n' > "$TMP/license.json"
LUCAIRN_INIT_SKIP_WITNESS_STEPS=1 "$ROOT/bin/lucairn-init" --confirm-no-registry-volume --dev --runtime-mode managed-byok \
  --output "$TMP/customer.env" --skip-doctor </dev/null >/dev/null 2>"$TMP/init.err" \
  || { tail -5 "$TMP/init.err" >&2; fail "init run"; }
step4="$(grep -E '^   bin/lucairn-mint-customer --raw-key-only ' "$ROOT/INSTALL.md" | head -1 | sed 's/^   //')"
[ -n "$step4" ] || fail "INSTALL.md: fast path step 4 mint line not found"
grep -Fxq "  $step4" "$TMP/init.err" || fail "init's closing hint does not print the fast path's step 4 mint command"
grep -Fq 'install -m 0600 /dev/null ~/lucairn-first.key' "$TMP/init.err" || fail "init's closing hint lacks the mode-0600 key file"
! grep -Eq 'mint-customer --name|At compose-up time, additionally load' "$TMP/init.err" \
  || fail "init still prints the old mint hint or the hand-added compose file"
grep -Fq 'bin/lucairn up loads docker-compose.self-hosted-byok.yml itself' "$TMP/init.err" || fail "init's BYOK note does not say bin/lucairn up loads the overlay"
pass "init: closing hint prints the fast path's step 4 (--raw-key-only into a 0600 file); bin/lucairn up loads the BYOK overlay itself"

echo "proof run settings tests: ok"
