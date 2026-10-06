#!/usr/bin/env bash
#
# T-1231 Slice 3, PR F - `lucairn evidence verify|list|export`.
#
# WHAT IS PINNED HERE, AND WHY EACH PIN EXISTS
# --------------------------------------------
# `evidence verify` is a wrapper around a tool whose exit code IS the verdict
# (0 VALID, 1 TAMPERED, 2 INCOMPLETE). A wrapper can go wrong in three ways
# that matter, and each has its own block below:
#
#   1. It can change the verdict. So the tool's exit code and stdout are
#      compared byte for byte for 0, 1 and 2, and every stop BEFORE the tool
#      runs must exit 3 - never 1 or 2, which a script would read as TAMPERED
#      or INCOMPLETE - and must leave stdout empty.
#   2. It can hand over the wrong keys. `--witness-key` alone makes the tool
#      answer INCOMPLETE, so the full argument list (witness key plus one
#      --service-key per claim signer, in a fixed order) is compared against
#      values that were computed independently of this script (Python
#      base64.b64encode over the same bytes), including a key with NUL bytes.
#   3. It can leak. The env file it reads holds private signing seeds next to
#      the public keys. No seed value, no admin key value and no public key
#      value may appear in anything the wrapper prints, and no seed or admin
#      key value may reach the tool's argument list.
#
# `evidence list|export` have no exporter binary yet: the pins are that they
# validate, stop with ONE sentence, write nothing, and - once a binary is
# there - hand over the admin key as a file PATH only.
#
# The delivery-bundle verbs (`lucairn bundle ...`) must not move: their usage
# lines and dispatch are pinned as literals.
#
# No network, no Docker, no real key. Every key below is a synthetic pattern.
# OPTIONAL end-to-end block (skipped unless both variables are set):
#   LUCAIRN_EVIDENCE_E2E_TOOL    a real lucairn-bundle-verify binary
#   LUCAIRN_EVIDENCE_E2E_CORPUS  output dir of the SDK's bundlecorpus tool

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUCAIRN="$ROOT/bin/lucairn"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

N=0
FAILS=0
pass() { N=$((N + 1)); printf '  ok: %s\n' "$1"; }
bad() { N=$((N + 1)); FAILS=$((FAILS + 1)); printf '  FAIL: %s -- %s\n' "$1" "$2" >&2; }
check() { # check NAME CONDITION-COMMAND...
  local name="$1"; shift
  if "$@"; then pass "$name"; else bad "$name" "condition failed: $*"; fi
}

OUT="$TMP/out"      # everything the CLI printed
LOGS="$TMP/logs"    # everything a stub tool was called with
ENVS="$TMP/envs"    # fixture env files (never scanned for leaks: they hold the seeds)
BIN="$TMP/bin"
mkdir -p "$OUT" "$LOGS" "$ENVS" "$BIN/path-tool" "$BIN/tripwire" "$BIN/other"

# --- synthetic key material ---------------------------------------------------
# Public keys (hex in the env file) and the standard base64 the tool must get.
PUB_WITNESS="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
B64_WITNESS="AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
PUB_BRIDGE="1111111111111111111111111111111111111111111111111111111111111111"
B64_BRIDGE="ERERERERERERERERERERERERERERERERERERERERERE="
PUB_SANITIZER="2222222222222222222222222222222222222222222222222222222222222222"
B64_SANITIZER="IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI="
PUB_SANDBOX_B="3333333333333333333333333333333333333333333333333333333333333333"
B64_SANDBOX_B="MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM="
PUB_AUDIT="4444444444444444444444444444444444444444444444444444444444444444"
B64_AUDIT="REREREREREREREREREREREREREREREREREREREREREQ="
# Upper-case hex on purpose: the env file may carry either case.
PUB_GATEWAY="FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
B64_GATEWAY="//////////////////////////////////////////8="
B64_EXTRA="VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVU="
# Private seeds that sit in the same file and must never travel or be printed.
SEED_WITNESS="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SEED_BRIDGE="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SEED_SANITIZER="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
SEED_SANDBOX_B="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
SEED_AUDIT="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
SEED_GATEWAY="9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a"
ADMIN_KEY_VALUE="synthetic-admin-key-value-not-a-real-credential"

write_env() { # write_env FILE
  cat > "$1" <<ENV
# synthetic fixture - not a real deployment
DSA_ENV=test
GATEWAY_PORT=18080
DSA_ADMIN_KEY=$ADMIN_KEY_VALUE
LCR_WITNESS_SIGNING_KEY=$SEED_WITNESS
LCR_BRIDGE_SIGNING_KEY=$SEED_BRIDGE
LCR_SANITIZER_SIGNING_KEY=$SEED_SANITIZER
LCR_SANDBOX_B_SIGNING_KEY=$SEED_SANDBOX_B
LCR_AUDIT_SIGNING_KEY=$SEED_AUDIT
LCR_GATEWAY_SIGNING_KEY=$SEED_GATEWAY
LCR_WITNESS_KEY_ID=witness_test_v1
LCR_WITNESS_PUBLIC_KEY=$PUB_WITNESS
LCR_BRIDGE_PUBLIC_KEY=$PUB_BRIDGE
LCR_SANITIZER_PUBLIC_KEY=$PUB_SANITIZER
LCR_SANDBOX_B_PUBLIC_KEY=$PUB_SANDBOX_B
LCR_AUDIT_PUBLIC_KEY=$PUB_AUDIT
LCR_GATEWAY_PUBLIC_KEY=$PUB_GATEWAY
ENV
}
GOOD_ENV="$ENVS/customer.env"
write_env "$GOOD_ENV"

# An "evidence bundle" for the stub runs: the stub never opens it. The space in
# the name pins the quoting of the path on its way to the tool.
BUNDLE="$TMP/evidence bundle.zip"
printf 'PK-not-a-real-zip\n' > "$BUNDLE"

# --- stub tools -----------------------------------------------------------------
# One stub serves as verifier and exporter. It records every call, answers
# --version from STUB_VERSION_LINE and exits with STUB_EXIT.
make_stub() { # make_stub PATH
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'VERSION-CALL\n' >> "$STUB_LOG"
  printf '%s\n' "${STUB_VERSION_LINE-lucairn-bundle-verify 1.0.0}"
  exit 0
fi
printf 'RUN\n' >> "$STUB_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$STUB_LOG"; done
printf 'stub stdout line 1\n  certificates/a.json  witness-signature  PASS\nRESULT: stub (exit %s)\n' "${STUB_EXIT:-0}"
printf 'stub stderr line\n' >&2
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$1"
}
STUB_TOOL="$BIN/other/verify-stub"
make_stub "$STUB_TOOL"
make_stub "$BIN/path-tool/lucairn-bundle-verify"
STUB_EXPORTER="$BIN/other/export-stub"
make_stub "$STUB_EXPORTER"
cat > "$TMP/expected-stub-stdout-template" <<'EOF'
stub stdout line 1
  certificates/a.json  witness-signature  PASS
RESULT: stub (exit @RC@)
EOF

# Tripwire: this PR must not make a network call. Any of these being run leaves
# a sentinel behind, which the last check looks for.
for net in curl wget nc ssh; do
  cat > "$BIN/tripwire/$net" <<TRIP
#!/usr/bin/env bash
printf '%s\n' "$net \$*" >> "$TMP/network-sentinel"
exit 97
TRIP
  chmod +x "$BIN/tripwire/$net"
done

# A PATH with the system tools the CLI needs and NO verifier or exporter on it.
BASE_PATH="$BIN/tripwire:/usr/bin:/bin"

# run NAME [VAR=VALUE ...] -- CLI-ARGS...
# Runs the CLI with a clean tool environment; writes $OUT/NAME.{out,err,rc} and
# the stub's call log to $LOGS/NAME.log.
run() {
  local name="$1"; shift
  local -a envs
  envs=("PATH=$BASE_PATH" "STUB_LOG=$LOGS/$name.log")
  while [ "$1" != "--" ]; do envs[${#envs[@]}]="$1"; shift; done
  shift
  : > "$LOGS/$name.log"
  local rc=0
  env -u LUCAIRN_BUNDLE_VERIFY -u LUCAIRN_BUNDLE_EXPORT -u STUB_EXIT -u STUB_VERSION_LINE \
    "${envs[@]}" "$LUCAIRN" "$@" > "$OUT/$name.out" 2> "$OUT/$name.err" || rc=$?
  printf '%s\n' "$rc" > "$OUT/$name.rc"
}
rc_of() { cat "$OUT/$1.rc"; }
err_has() { grep -qF -- "$2" "$OUT/$1.err"; }
out_empty() { [ ! -s "$OUT/$1.out" ]; }
tool_not_run() { ! grep -qx 'RUN' "$LOGS/$1.log"; }
# A stop before the tool ran: exit 3, nothing on stdout, the tool never started.
no_verdict() { # no_verdict RUN-NAME LABEL NEEDLE
  if [ "$(rc_of "$1")" = "3" ] && out_empty "$1" && tool_not_run "$1" && err_has "$1" "$3" && err_has "$1" "no verdict"; then
    pass "$2"
  else
    bad "$2" "rc=$(rc_of "$1") stderr=$(tr '\n' '|' < "$OUT/$1.err" | cut -c1-300)"
  fi
}

echo "evidence verify - the tool: missing, wrong, too old, unversioned"
run tool-missing -- evidence verify "$BUNDLE" --env "$GOOD_ENV"
no_verdict tool-missing "tool missing -> exit 3, names the tool" "lucairn-bundle-verify was not found"
check "tool missing -> says where to get it" err_has tool-missing "https://github.com/Declade/lucairn-sdks/releases/tag/bundle-verify-v1.0.0"
check "tool missing -> states the minimum version" err_has tool-missing "version 1.0.0 or newer"
check "tool missing -> says the kit does not download it" err_has tool-missing "does not ship or download"

run tool-flag-absent -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$TMP/no-such-tool"
no_verdict tool-flag-absent "--tool pointing nowhere -> exit 3" "not found or not executable"

run tool-too-old "STUB_VERSION_LINE=lucairn-bundle-verify 0.9.9" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict tool-too-old "tool older than the minimum -> exit 3" "is version 0.9.9"
check "tool too old -> names the minimum" err_has tool-too-old "needs 1.0.0 or newer"
check "tool too old -> only --version was called" grep -qx 'VERSION-CALL' "$LOGS/tool-too-old.log"

run tool-prerelease "STUB_VERSION_LINE=lucairn-bundle-verify 1.0.0-rc1" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict tool-prerelease "a 1.0.0 prerelease is older than 1.0.0 -> exit 3" "is version 1.0.0-rc1"

run tool-newer "STUB_VERSION_LINE=lucairn-bundle-verify v1.2.0" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
check "newer tool (with a v prefix) runs" [ "$(rc_of tool-newer)" = "0" ]

run tool-other-program "STUB_VERSION_LINE=some-other-tool 9.9.9" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict tool-other-program "a program that is not the verifier -> exit 3" "did not answer --version"

run tool-dev "STUB_VERSION_LINE=lucairn-bundle-verify dev" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict tool-dev "source build (version dev) refused by default" "not a release version"
run tool-dev-allowed "STUB_VERSION_LINE=lucairn-bundle-verify dev" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --allow-unversioned-tool
check "source build runs with --allow-unversioned-tool" [ "$(rc_of tool-dev-allowed)" = "0" ]
check "source build -> warning on stderr" err_has tool-dev-allowed "could not be checked"

run tool-garbage-version "STUB_VERSION_LINE=lucairn-bundle-verify 1.0.0;rm" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict tool-garbage-version "unreadable version string -> exit 3, not echoed" "cannot read"
check "unreadable version string is not echoed" bash -c '! grep -qF ";rm" "$1"' _ "$OUT/tool-garbage-version.err"

echo "evidence verify - where the tool is looked for"
run find-path "PATH=$BIN/path-tool:$BASE_PATH" -- evidence verify "$BUNDLE" --env "$GOOD_ENV"
check "tool found on PATH" err_has find-path "tool $BIN/path-tool/lucairn-bundle-verify"
run find-env "PATH=$BIN/path-tool:$BASE_PATH" "LUCAIRN_BUNDLE_VERIFY=$STUB_TOOL" -- evidence verify "$BUNDLE" --env "$GOOD_ENV"
check "LUCAIRN_BUNDLE_VERIFY beats PATH" err_has find-env "tool $STUB_TOOL"
run find-flag "PATH=$BIN/path-tool:$BASE_PATH" "LUCAIRN_BUNDLE_VERIFY=$TMP/no-such-tool" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
check "--tool beats the environment variable" err_has find-flag "tool $STUB_TOOL"

cp "$STUB_TOOL" "$TMP/bare-tool"
(cd "$TMP" && run find-bare -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool bare-tool)
check "--tool with a bare file name means that file in the current directory" [ "$(rc_of find-bare)" = "0" ]
check "... and never a same-named program on PATH" err_has find-bare "tool ./bare-tool"

echo "evidence verify - exit code and output pass through unchanged"
for code in 0 1 2; do
  run "pass-$code" "STUB_EXIT=$code" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
  check "tool exit $code comes back as $code" [ "$(rc_of "pass-$code")" = "$code" ]
  sed "s/@RC@/$code/" "$TMP/expected-stub-stdout-template" > "$TMP/expected-stdout-$code"
  check "tool exit $code: stdout is byte-identical to the tool's" cmp -s "$TMP/expected-stdout-$code" "$OUT/pass-$code.out"
  check "tool exit $code: the tool's stderr line arrives unchanged" grep -qx 'stub stderr line' "$OUT/pass-$code.err"
done
run pass-json "STUB_EXIT=0" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --json
check "--json: the wrapper adds nothing to stdout" cmp -s "$TMP/expected-stdout-0" "$OUT/pass-json.out"

echo "evidence verify - the keys that reach the tool"
cat > "$TMP/expected-argv" <<EOF
VERSION-CALL
RUN
--witness-key
witness_test_v1=$B64_WITNESS
--service-key
dsa-bridge=$B64_BRIDGE
--service-key
dsa-sanitizer=$B64_SANITIZER
--service-key
dsa-sanitizer-streaming=$B64_SANITIZER
--service-key
dsa-ai=$B64_SANDBOX_B
--service-key
dsa-audit=$B64_AUDIT
--service-key
dsa-gateway=$B64_GATEWAY
--
$BUNDLE
EOF
if cmp -s "$TMP/expected-argv" "$LOGS/pass-0.log"; then
  pass "argument list: witness key + all six service keys, then -- and the bundle path"
else
  bad "argument list: witness key + all six service keys, then -- and the bundle path" "$(diff "$TMP/expected-argv" "$LOGS/pass-0.log" | head -20 | tr '\n' '|')"
fi
check "a --witness-key alone is never what the tool gets" [ "$(grep -c -x -- '--service-key' "$LOGS/pass-0.log")" = "6" ]
check "stderr names the lines used" err_has pass-0 "dsa-ai (LCR_SANDBOX_B_PUBLIC_KEY)"
check "stderr says which key id" err_has pass-0 "witness key id witness_test_v1"

run pass-flags -- evidence verify --env "$GOOD_ENV" --tool "$STUB_TOOL" --json --require-anchors \
  --tsa-root "$GOOD_ENV" --rekor-key "$GOOD_ENV" --require-binding-after 2026-11-01T00:00:00Z \
  --service-key "dsa-reid-guard=$B64_EXTRA" -- "$BUNDLE"
{
  sed -n '1,16p' "$TMP/expected-argv"
  printf '%s\n' --service-key "dsa-reid-guard=$B64_EXTRA" --json --require-anchors \
    --tsa-root "$GOOD_ENV" --rekor-key "$GOOD_ENV" --require-binding-after 2026-11-01T00:00:00Z -- "$BUNDLE"
} > "$TMP/expected-argv-flags"
if cmp -s "$TMP/expected-argv-flags" "$LOGS/pass-flags.log"; then
  pass "pass-through flags and an extra --service-key arrive after the env keys"
else
  bad "pass-through flags and an extra --service-key arrive after the env keys" "$(diff "$TMP/expected-argv-flags" "$LOGS/pass-flags.log" | head -20 | tr '\n' '|')"
fi

run extra-replaces -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --service-key "dsa-bridge=$B64_EXTRA"
no_verdict extra-replaces "--service-key cannot replace a key that comes from --env" "cannot be replaced here"
run extra-malformed -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --service-key "dsa-x=tooshort"
no_verdict extra-malformed "--service-key with a malformed value -> exit 3" "standard base64 of 32 bytes"
run extra-noequals -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --service-key "dsa-x"
no_verdict extra-noequals "--service-key without = -> exit 3" "must be SERVICE=BASE64"
run witness-flag -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --witness-key "x=$B64_EXTRA"
no_verdict witness-flag "--witness-key is refused (the key comes from --env)" "comes from --env"

echo "evidence verify - the key file: missing, incomplete, malformed"
run env-missing-flag -- evidence verify "$BUNDLE" --tool "$STUB_TOOL"
no_verdict env-missing-flag "no --env -> exit 3" "--env FILE is required"
run env-absent -- evidence verify "$BUNDLE" --env "$ENVS/no-such.env" --tool "$STUB_TOOL"
no_verdict env-absent "--env file does not exist -> exit 3" "key file not found or not readable"

for var in LCR_WITNESS_PUBLIC_KEY LCR_BRIDGE_PUBLIC_KEY LCR_SANITIZER_PUBLIC_KEY LCR_SANDBOX_B_PUBLIC_KEY LCR_AUDIT_PUBLIC_KEY LCR_GATEWAY_PUBLIC_KEY; do
  grep -v "^${var}=" "$GOOD_ENV" > "$ENVS/without-$var.env"
  run "missing-$var" -- evidence verify "$BUNDLE" --env "$ENVS/without-$var.env" --tool "$STUB_TOOL"
  no_verdict "missing-$var" "$var missing -> exit 3, tool not run" "$var is not set"
done

mutate() { # mutate NAME VAR NEW-VALUE -> $ENVS/NAME.env
  sed "s|^$2=.*|$2=$3|" "$GOOD_ENV" > "$ENVS/$1.env"
}
mutate short LCR_AUDIT_PUBLIC_KEY 4444
run key-short -- evidence verify "$BUNDLE" --env "$ENVS/short.env" --tool "$STUB_TOOL"
no_verdict key-short "public key too short -> exit 3" "has 4 characters"
mutate nonhex LCR_BRIDGE_PUBLIC_KEY "zz11111111111111111111111111111111111111111111111111111111111111"
run key-nonhex -- evidence verify "$BUNDLE" --env "$ENVS/nonhex.env" --tool "$STUB_TOOL"
no_verdict key-nonhex "public key not hex -> exit 3" "is not a public key"
mutate placeholder LCR_GATEWAY_PUBLIC_KEY "REPLACE_ME_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run key-placeholder -- evidence verify "$BUNDLE" --env "$ENVS/placeholder.env" --tool "$STUB_TOOL"
no_verdict key-placeholder "REPLACE_ME placeholder -> exit 3" "still the REPLACE_ME placeholder"
mutate base64key LCR_SANITIZER_PUBLIC_KEY "$B64_SANITIZER"
run key-base64 -- evidence verify "$BUNDLE" --env "$ENVS/base64key.env" --tool "$STUB_TOOL"
no_verdict key-base64 "base64 where hex is expected -> exit 3" "is not a public key"
mutate keyid LCR_WITNESS_KEY_ID "witness=v1 x"
run keyid-bad -- evidence verify "$BUNDLE" --env "$ENVS/keyid.env" --tool "$STUB_TOOL"
no_verdict keyid-bad "key id with = or space -> exit 3" "LCR_WITNESS_KEY_ID"

# The private seed pasted into the public slot: must stop, and the value must
# not be put on a command line or printed.
mutate seed-as-public LCR_WITNESS_PUBLIC_KEY "$SEED_WITNESS"
run key-seed -- evidence verify "$BUNDLE" --env "$ENVS/seed-as-public.env" --tool "$STUB_TOOL"
no_verdict key-seed "public slot holding the private seed -> exit 3, tool not run" "private signing seed"
mutate seed-as-public-upper LCR_SANDBOX_B_PUBLIC_KEY "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
run key-seed-upper -- evidence verify "$BUNDLE" --env "$ENVS/seed-as-public-upper.env" --tool "$STUB_TOOL"
no_verdict key-seed-upper "seed in the public slot is caught regardless of hex case" "private signing seed"

# Accepted variants.
grep -v '^LCR_WITNESS_KEY_ID=' "$GOOD_ENV" > "$ENVS/no-keyid.env"
run keyid-default -- evidence verify "$BUNDLE" --env "$ENVS/no-keyid.env" --tool "$STUB_TOOL"
check "no LCR_WITNESS_KEY_ID -> witness_v1" grep -qx "witness_v1=$B64_WITNESS" "$LOGS/keyid-default.log"
check "the default key id is announced" err_has keyid-default "(default; LCR_WITNESS_KEY_ID is not set)"
sed -e 's/^LCR_\([A-Z_]*\)_PUBLIC_KEY=/VEIL_\1_PUBLIC_KEY=/' -e 's/^LCR_WITNESS_KEY_ID=/VEIL_WITNESS_KEY_ID=/' "$GOOD_ENV" > "$ENVS/legacy.env"
run legacy-names -- evidence verify "$BUNDLE" --env "$ENVS/legacy.env" --tool "$STUB_TOOL"
check "legacy VEIL_* names give the same argument list" cmp -s "$TMP/expected-argv" "$LOGS/legacy-names.log"
awk '{ printf "%s\r\n", $0 }' "$GOOD_ENV" > "$ENVS/crlf.env"
run crlf -- evidence verify "$BUNDLE" --env "$ENVS/crlf.env" --tool "$STUB_TOOL"
check "CRLF line endings give the same argument list" cmp -s "$TMP/expected-argv" "$LOGS/crlf.log"
grep -E '^(LCR|VEIL)_(WITNESS_KEY_ID|(WITNESS|BRIDGE|SANITIZER|SANDBOX_B|AUDIT|GATEWAY)_PUBLIC_KEY)=' "$GOOD_ENV" > "$ENVS/public-only.env"
check "the documented public-only extract holds no signing key" bash -c '! grep -q SIGNING "$1" && [ "$(wc -l < "$1" | tr -d " ")" = "7" ]' _ "$ENVS/public-only.env"
run public-only -- evidence verify "$BUNDLE" --env "$ENVS/public-only.env" --tool "$STUB_TOOL"
check "the public-only extract gives the same argument list" cmp -s "$TMP/expected-argv" "$LOGS/public-only.log"

echo "evidence verify - the bundle argument, and the delivery-bundle mix-up"
run no-bundle -- evidence verify --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict no-bundle "no bundle path -> exit 3" "no evidence bundle given"
run two-bundles -- evidence verify "$BUNDLE" "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict two-bundles "two bundle paths -> exit 3" "exactly one evidence bundle"
run bundle-absent -- evidence verify "$TMP/nope.zip" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict bundle-absent "bundle file does not exist -> exit 3" "evidence bundle not found"
printf 'x' > "$TMP/lucairn-customer-bundle-acme-20260101T000000Z.tar.gz"
run delivery-path -- evidence verify "$TMP/lucairn-customer-bundle-acme-20260101T000000Z.tar.gz" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict delivery-path "a delivery bundle path is refused" "looks like a customer delivery bundle"
check "... and points at lucairn bundle verify" err_has delivery-path "lucairn bundle verify --bundle"
run delivery-flag -- evidence verify --bundle "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict delivery-flag "--bundle (the delivery-bundle flag) is refused" "delivery-bundle flag"
run unknown-flag -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --online
no_verdict unknown-flag "unknown flag -> exit 3" "unknown argument: --online"
run verify-help -- evidence verify --help
check "evidence verify --help exits 0" [ "$(rc_of verify-help)" = "0" ]

echo "evidence list / export - validation, no exporter, hand-over"
KEYFILE="$TMP/admin.key"
printf '%s\n' "$ADMIN_KEY_VALUE" > "$KEYFILE"
chmod 600 "$KEYFILE"
EXPORT_DIR="$TMP/export-out"
fails_with() { # fails_with RUN-NAME LABEL NEEDLE : exit 1, nothing on stdout
  if [ "$(rc_of "$1")" = "1" ] && out_empty "$1" && tool_not_run "$1" && err_has "$1" "$3"; then
    pass "$2"
  else
    bad "$2" "rc=$(rc_of "$1") stderr=$(tr '\n' '|' < "$OUT/$1.err" | cut -c1-300)"
  fi
}

run export-no-exporter -- evidence export --env "$GOOD_ENV" --customer-id cust_demo --conversation conv_abc123 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-no-exporter "export without the exporter -> non-zero" "needs the exporter lucairn-bundle-export, which ships with a later release"
check "export without the exporter -> exactly one line" [ "$(wc -l < "$OUT/export-no-exporter.err" | tr -d ' ')" = "1" ]
check "export without the exporter -> nothing written" [ ! -e "$EXPORT_DIR" ]
run list-no-exporter -- evidence list --env "$GOOD_ENV" --customer-id cust_demo --admin-key-file "$KEYFILE"
fails_with list-no-exporter "list without the exporter -> non-zero" "needs the exporter lucairn-bundle-export, which ships with a later release"
check "list without the exporter -> exactly one line" [ "$(wc -l < "$OUT/list-no-exporter.err" | tr -d ' ')" = "1" ]

run export-no-customer "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$GOOD_ENV" --conversation c1 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-no-customer "export: --customer-id required" "--customer-id is required"
run export-no-conversation "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$GOOD_ENV" --customer-id cust_demo --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-no-conversation "export: --conversation required" "--conversation is required"
run export-no-output "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$GOOD_ENV" --customer-id cust_demo --conversation c1 --admin-key-file "$KEYFILE"
fails_with export-no-output "export: --output required" "--output DIR is required"
run export-bad-id "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$GOOD_ENV" --customer-id 'cust/../x' --conversation c1 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-bad-id "export: customer id with a slash refused" "--customer-id may only contain"
run export-bad-conv "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$GOOD_ENV" --customer-id cust_demo --conversation 'c1?x=1' --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-bad-conv "export: conversation id with a query refused" "--conversation may only contain"
run export-no-keyfile "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$GOOD_ENV" --customer-id cust_demo --conversation c1 --output "$EXPORT_DIR"
fails_with export-no-keyfile "export: --admin-key-file required" "--admin-key-file PATH is required"
run export-inline-key "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$GOOD_ENV" --customer-id cust_demo --conversation c1 --admin-key "$ADMIN_KEY_VALUE" --output "$EXPORT_DIR"
fails_with export-inline-key "export: --admin-key VALUE is refused" "there is no --admin-key VALUE form"
check "... and the refused value is not echoed" bash -c '! grep -qF "$2" "$1"' _ "$OUT/export-inline-key.err" "$ADMIN_KEY_VALUE"

OPEN_KEYFILE="$TMP/admin-open.key"
printf '%s\n' "$ADMIN_KEY_VALUE" > "$OPEN_KEYFILE"
chmod 644 "$OPEN_KEYFILE"
run export-open-keyfile "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$GOOD_ENV" --customer-id cust_demo --conversation c1 --admin-key-file "$OPEN_KEYFILE" --output "$EXPORT_DIR"
fails_with export-open-keyfile "export: group/world-readable admin key file refused" "readable by its owner only"
ln -s "$KEYFILE" "$TMP/admin-link.key"
run export-link-keyfile "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$GOOD_ENV" --customer-id cust_demo --conversation c1 --admin-key-file "$TMP/admin-link.key" --output "$EXPORT_DIR"
fails_with export-link-keyfile "export: symlinked admin key file refused" "not a symbolic link"
: > "$TMP/admin-empty.key"; chmod 600 "$TMP/admin-empty.key"
run export-empty-keyfile "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$GOOD_ENV" --customer-id cust_demo --conversation c1 --admin-key-file "$TMP/admin-empty.key" --output "$EXPORT_DIR"
fails_with export-empty-keyfile "export: empty admin key file refused" "is empty"

run export-http-remote "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --gateway-url http://gateway.internal.example:8080 --customer-id cust_demo --conversation c1 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-http-remote "export: plain http to another host refused" "plain http to another host"
run export-url-path "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --gateway-url 'https://gateway.example.com/api?x=1' --customer-id cust_demo --conversation c1 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-url-path "export: gateway URL with a path or query refused" "plain http(s)://host[:port] URL"
run export-url-user "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --gateway-url 'https://user@gateway.example.com' --customer-id cust_demo --conversation c1 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-url-user "export: gateway URL with user info refused" "plain http(s)://host[:port] URL"
run export-url-fakeport "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --gateway-url 'http://localhost:8080.evil.example' --customer-id cust_demo --conversation c1 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-url-fakeport "export: a host hidden behind a loopback-looking port is refused" "plain http(s)://host[:port] URL"
run export-url-lookalike "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --gateway-url 'http://127.0.0.1.evil.example:8080' --customer-id cust_demo --conversation c1 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-url-lookalike "export: a loopback look-alike host over http is refused" "plain http to another host"
run export-no-gateway "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --customer-id cust_demo --conversation c1 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-no-gateway "export: neither --env nor --gateway-url" "give --env customer.env"
sed 's/^GATEWAY_PORT=.*/GATEWAY_PORT=80a/' "$GOOD_ENV" > "$ENVS/badport.env"
run export-bad-port "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --env "$ENVS/badport.env" --customer-id cust_demo --conversation c1 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR"
fails_with export-bad-port "export: GATEWAY_PORT that is not a number refused" "not a port number"
run export-delivery-flag "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --customer-slug acme
fails_with export-delivery-flag "export: a delivery-bundle flag is refused with a pointer" "is a delivery-bundle flag"
run list-conversation "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence list --env "$GOOD_ENV" --customer-id cust_demo --admin-key-file "$KEYFILE" --conversation c1
fails_with list-conversation "list: --conversation belongs to export" "belongs to evidence export"
run list-bad-since "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence list --env "$GOOD_ENV" --customer-id cust_demo --admin-key-file "$KEYFILE" --since yesterday
fails_with list-bad-since "list: --since that is not a date refused" "must be YYYY-MM-DD or an RFC 3339 time"
run export-unknown "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence export --frobnicate
fails_with export-unknown "export: unknown flag" "unknown evidence export argument"

# With an exporter present: what it is handed, and that its exit code returns.
run export-handover "STUB_EXIT=7" -- evidence export --env "$GOOD_ENV" --customer-id cust_demo --conversation conv_abc123 --admin-key-file "$KEYFILE" --output "$EXPORT_DIR" --exporter "$STUB_EXPORTER"
cat > "$TMP/expected-export-argv" <<EOF
RUN
export
--gateway-url
http://127.0.0.1:18080
--customer-id
cust_demo
--conversation-id
conv_abc123
--admin-key-file
$KEYFILE
--output
$EXPORT_DIR
EOF
check "export hand-over: argument list (gateway from GATEWAY_PORT, key as a PATH)" cmp -s "$TMP/expected-export-argv" "$LOGS/export-handover.log"
check "export hand-over: the exporter's exit code comes back" [ "$(rc_of export-handover)" = "7" ]
check "export hand-over: the wrapper did not create the output directory itself" [ ! -e "$EXPORT_DIR" ]
run list-handover "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence list --gateway-url https://gateway.example.com/ --customer-id cust_demo --admin-key-file "$KEYFILE" --since 2026-10-01 --until 2026-10-07T12:00:00Z
cat > "$TMP/expected-list-argv" <<EOF
RUN
list
--gateway-url
https://gateway.example.com
--customer-id
cust_demo
--admin-key-file
$KEYFILE
--since
2026-10-01
--until
2026-10-07T12:00:00Z
EOF
check "list hand-over: argument list (https gateway, time window)" cmp -s "$TMP/expected-list-argv" "$LOGS/list-handover.log"
check "list hand-over: exit 0 comes back" [ "$(rc_of list-handover)" = "0" ]
run list-loopback "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence list --gateway-url http://localhost:8080 --customer-id cust_demo --admin-key-file "$KEYFILE"
check "list: plain http to this host is accepted" [ "$(rc_of list-loopback)" = "0" ]
run list-loopback6 "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence list --gateway-url 'http://[::1]:8080' --customer-id cust_demo --admin-key-file "$KEYFILE"
check "list: plain http to the IPv6 loopback is accepted" [ "$(rc_of list-loopback6)" = "0" ]

echo "evidence - dispatch and help"
run evidence-bare -- evidence
check "lucairn evidence prints its help, exit 0" [ "$(rc_of evidence-bare)" = "0" ]
check "evidence help says it is not the delivery bundle" grep -qF 'Evidence bundles are NOT delivery bundles' "$OUT/evidence-bare.out"
check "evidence help lists the four exit codes" bash -c 'grep -q "0  VALID" "$1" && grep -q "1  TAMPERED" "$1" && grep -q "2  INCOMPLETE" "$1" && grep -q "3  no verdict" "$1"' _ "$OUT/evidence-bare.out"
run evidence-bogus -- evidence frobnicate
check "unknown evidence subcommand -> exit 1" [ "$(rc_of evidence-bogus)" = "1" ]
check "unknown evidence subcommand points at lucairn bundle for delivery bundles" err_has evidence-bogus "lucairn bundle create|prepare|verify"

echo "delivery-bundle verbs are untouched"
run help -- --help
for line in \
  '  lucairn bundle create --customer-slug acme --models-dir ./models --model-manifest model-manifest.yaml --env customer.env --image-tar images.tar [--customer-data-dir ./customer-data]' \
  '  lucairn bundle prepare --customer-slug acme --staging-dir /secure/staging/acme [--output dist/customer-bundles]' \
  '  lucairn bundle verify --bundle dist/customer-bundles/lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz' \
  '  bundle          Create, prepare, or verify per-customer delivery bundles.'; do
  check "usage keeps the line: $(printf '%s' "$line" | cut -c1-48)..." grep -qxF -- "$line" "$OUT/help.out"
done
check "usage advertises the evidence verb" grep -qF '  lucairn evidence verify bundle.zip --env customer.env' "$OUT/help.out"
check "usage says evidence is not the delivery bundle" grep -qF 'EVIDENCE bundles - not the delivery bundles of `lucairn bundle`.' "$OUT/help.out"
run bundle-bare -- bundle
run bundle-help -- bundle --help
check "lucairn bundle (no subcommand) still prints the main usage" cmp -s "$OUT/help.out" "$OUT/bundle-bare.out"
check "lucairn bundle --help still prints the main usage" cmp -s "$OUT/help.out" "$OUT/bundle-help.out"
run bundle-bogus -- bundle frobnicate
check "lucairn bundle: unknown subcommand message unchanged" grep -qxF 'error: unknown bundle subcommand: frobnicate' "$OUT/bundle-bogus.err"
run bundle-export -- bundle export
check "lucairn bundle export does not exist (export lives under evidence)" grep -qxF 'error: unknown bundle subcommand: export' "$OUT/bundle-export.err"
run bundle-verify-zip -- bundle verify --bundle "$BUNDLE"
check "lucairn bundle verify does not accept an evidence zip as valid" [ "$(rc_of bundle-verify-zip)" != "0" ]

echo "nothing private leaves the env file; no network"
# Everything the CLI printed and everything a stub was called with, across all
# runs above. The fixture env files are outside both directories.
leaks=""
for secret in "$SEED_WITNESS" "$SEED_BRIDGE" "$SEED_SANITIZER" "$SEED_SANDBOX_B" "$SEED_AUDIT" "$SEED_GATEWAY" "$ADMIN_KEY_VALUE"; do
  if grep -rqiF -- "$secret" "$OUT" "$LOGS"; then
    leaks="$leaks $(grep -rliF -- "$secret" "$OUT" "$LOGS" | head -3 | tr '\n' ' ')"
  fi
done
if [ -z "$leaks" ]; then
  pass "no signing seed and no admin key value in any output or any tool argument list"
else
  bad "no signing seed and no admin key value in any output or any tool argument list" "found in:$leaks"
fi
check "no *_SIGNING_KEY name ever reaches a tool" bash -c '! grep -rq "SIGNING_KEY" "$1"' _ "$LOGS"
shown=""
for value in "$PUB_WITNESS" "$PUB_BRIDGE" "$PUB_SANITIZER" "$PUB_SANDBOX_B" "$PUB_AUDIT" "$PUB_GATEWAY" \
  "$B64_WITNESS" "$B64_BRIDGE" "$B64_SANITIZER" "$B64_SANDBOX_B" "$B64_AUDIT" "$B64_GATEWAY" "$B64_EXTRA"; do
  if grep -rqiF -- "$value" "$OUT"; then shown="$shown x"; fi
done
check "the wrapper prints no key value, public ones included" [ -z "$shown" ]
check "positive control: the public keys did reach the tool" grep -rqF -- "$B64_WITNESS" "$LOGS"
check "no network tool was started by any run" [ ! -e "$TMP/network-sentinel" ]
# Static twin of the tripwire: the evidence block names no network client.
awk '/^# lucairn evidence - EVIDENCE bundles/{on=1} /^main\(\) \{/{on=0} on' "$LUCAIRN" > "$TMP/evidence-block.sh"
check "the evidence block was found in bin/lucairn" [ "$(wc -l < "$TMP/evidence-block.sh" | tr -d ' ')" -gt 100 ]
check "the evidence block calls no network client" bash -c '! grep -Eq "(^|[^A-Za-z_-])(curl|wget|nc|ssh|scp)[[:space:]]" "$1"' _ "$TMP/evidence-block.sh"
check "the evidence block never opens the admin key file" bash -c '! grep -Eq "((^|[^A-Za-z_-])(cat|head|tail|read|source)[[:space:]][^|;]*|<[[:space:]]*\"?[$])admin_key_file" "$1"' _ "$TMP/evidence-block.sh"

echo "repository hygiene and docs"
check ".gitignore ignores customer.env.bak-*" grep -qxF 'customer.env.bak-*' "$ROOT/.gitignore"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  check "git agrees: a dated env backup is ignored" git -C "$ROOT" check-ignore -q customer.env.bak-20990101
  check "git agrees: customer.env.example is still tracked material" bash -c '! git -C "$1" check-ignore -q customer.env.example' _ "$ROOT"
fi
awk '/^## Verify an evidence bundle \(self-hosted\)/{on=1; next} /^## /{on=0} on' "$ROOT/OPS.md" > "$TMP/ops-section.md"
check "OPS.md has the evidence section" [ "$(wc -l < "$TMP/ops-section.md" | tr -d ' ')" -gt 30 ]
for phrase in 'SKIPPED(not anchored)' 'not a certification or legal opinion' 'LCR_SANDBOX_B_PUBLIC_KEY' \
  '--service-key dsa-sanitizer-streaming' 'keys/lucairn-cosign.pub' 'which ships with a later release' 'No verdict'; do
  check "OPS.md evidence section states: $phrase" grep -qF -- "$phrase" "$TMP/ops-section.md"
done
check "OPS.md evidence section makes no assurance claim it cannot back" bash -c '! grep -Eiq "SOC ?2|ISO ?27001|ISO ?42001|HIPAA|PCI|end-to-end|E2E|encrypted at rest|penetration|red team|regular audits|court|legally binding|tamper-proof" "$1"' _ "$TMP/ops-section.md"
check "README points at the OPS.md section" grep -qF 'Verify an evidence bundle (self-hosted)' "$ROOT/README.md"

# --- optional: one real run against the released tool -------------------------
if [ -n "${LUCAIRN_EVIDENCE_E2E_TOOL:-}" ] && [ -n "${LUCAIRN_EVIDENCE_E2E_CORPUS:-}" ]; then
  echo "end to end: the real lucairn-bundle-verify on the SDK's synthetic corpus"
  CORPUS="$LUCAIRN_EVIDENCE_E2E_CORPUS"
  # The corpus world's public keys arrive as base64 in flags.txt; the wrapper
  # wants them the way a kit env file holds them (hex).
  b64_to_hex() { printf '%s' "$1" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n'; }
  flag_value() { awk -v id="$1" 'index($0, id "=") == 1 { print substr($0, length(id) + 2) }' "$CORPUS/flags.txt"; }
  # The corpus world signs with a witness, a bridge and a sanitizer key only.
  # The tool refuses a pinned key that is not a valid curve point (the claim
  # steps then read SKIPPED, which blocks VALID), so the three signers the
  # corpus does not use are filled with a real key from the same world rather
  # than with the patterned bytes used for the stub runs above.
  CORPUS_SANITIZER_HEX="$(b64_to_hex "$(flag_value dsa-sanitizer)")"
  cat > "$ENVS/corpus.env" <<ENV
LCR_WITNESS_KEY_ID=witness_synthetic_v1
LCR_WITNESS_PUBLIC_KEY=$(b64_to_hex "$(flag_value witness_synthetic_v1)")
LCR_BRIDGE_PUBLIC_KEY=$(b64_to_hex "$(flag_value dsa-bridge)")
LCR_SANITIZER_PUBLIC_KEY=$CORPUS_SANITIZER_HEX
LCR_SANDBOX_B_PUBLIC_KEY=$CORPUS_SANITIZER_HEX
LCR_AUDIT_PUBLIC_KEY=$CORPUS_SANITIZER_HEX
LCR_GATEWAY_PUBLIC_KEY=$CORPUS_SANITIZER_HEX
ENV
  e2e() { # e2e NAME CASE [extra args]
    local name="$1" case_zip="$2"; shift 2
    run "$name" -- evidence verify "$CORPUS/cases/$case_zip.zip" --env "$ENVS/corpus.env" --tool "$LUCAIRN_EVIDENCE_E2E_TOOL" \
      --tsa-root "$CORPUS/trust/tsa-root.pem" --rekor-key "$CORPUS/trust/rekor.pem" "$@"
  }
  e2e e2e-clean 00-clean --require-anchors
  check "real tool, clean bundle, anchors required -> VALID (0)" [ "$(rc_of e2e-clean)" = "0" ]
  check "real tool prints its own verdict line" grep -qF 'RESULT: VALID (exit 0)' "$OUT/e2e-clean.out"
  e2e e2e-tampered 01-cert-byte-flip --require-anchors
  check "real tool, one flipped certificate byte -> TAMPERED (1)" [ "$(rc_of e2e-tampered)" = "1" ]
  e2e e2e-stripped F2-anchors-and-status-stripped-all
  check "real tool, anchors stripped, self-hosted default -> VALID (0) with SKIPPED(not anchored)" \
    bash -c '[ "$(cat "$1.rc")" = "0" ] && grep -qF "SKIPPED(not anchored)" "$1.out"' _ "$OUT/e2e-stripped"
  e2e e2e-stripped-required F2-anchors-and-status-stripped-all --require-anchors
  check "real tool, anchors stripped, --require-anchors -> INCOMPLETE (2)" [ "$(rc_of e2e-stripped-required)" = "2" ]
  grep -v '^LCR_BRIDGE_PUBLIC_KEY=' "$ENVS/corpus.env" > "$ENVS/corpus-wrong.env"
  printf 'LCR_BRIDGE_PUBLIC_KEY=%s\n' "$CORPUS_SANITIZER_HEX" >> "$ENVS/corpus-wrong.env"
  run e2e-wrong-key -- evidence verify "$CORPUS/cases/00-clean.zip" --env "$ENVS/corpus-wrong.env" --tool "$LUCAIRN_EVIDENCE_E2E_TOOL" \
    --tsa-root "$CORPUS/trust/tsa-root.pem" --rekor-key "$CORPUS/trust/rekor.pem"
  check "real tool, a service key that is not the signer's -> not VALID" [ "$(rc_of e2e-wrong-key)" != "0" ]
else
  echo "end to end: skipped (set LUCAIRN_EVIDENCE_E2E_TOOL and LUCAIRN_EVIDENCE_E2E_CORPUS to run it)"
fi

printf '\n%d checks, %d failures\n' "$N" "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
