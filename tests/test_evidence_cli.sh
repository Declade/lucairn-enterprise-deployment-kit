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
#      compared byte for byte for 0, 1, 2 and one other code, and every stop
#      BEFORE the tool runs must exit 3 - never 0, 1 or 2, which a script
#      would read as VALID, TAMPERED or INCOMPLETE - and must leave stdout
#      empty. "Every stop" includes the ones nobody wrote a message for: a
#      closed stderr, a helper program that fails, --help in the middle of a
#      verification call.
#   2. It can hand over the wrong keys. `--witness-key` alone makes the tool
#      answer INCOMPLETE, so the full argument list (witness key plus one
#      --service-key per claim signer, in a fixed order) is compared against
#      values that were computed independently of this script (Python
#      base64.b64encode over the same bytes), including a key with NUL bytes.
#   3. It can leak. The env file it reads holds private signing seeds next to
#      the public keys. No seed value, no admin key value and no public key
#      value may appear in anything the wrapper prints - a Bash trace
#      (bash -x) included - and no seed or admin key value may reach the
#      tool's argument list or any child's environment, whichever line it was
#      pasted into: the six public slots, the key id, or (list/export) the
#      gateway port. Two reviews in a row found one more line that the
#      comparison had not been wired to, so the pin is now on the
#      construction: every read of the env file goes through one gate, and a
#      static check counts the call sites.
#
# Three more ways to turn "no verdict" into a verdict, each with a block:
# a minimum-version check that a failing helper program can flip to "new
# enough"; a tool file the shell cannot start (Bash 3.2 with errexit on
# reports that as 1, the code for TAMPERED); --help in the middle of a list
# or export call ending in 0.
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
# Not 1111...: bin/lucairn itself carries that pattern as a test constant
# (DOCTOR_HELM_RENDER_TEST_SIGNING_KEY), which a Bash trace prints.
PUB_BRIDGE="1212121212121212121212121212121212121212121212121212121212121212"
B64_BRIDGE="EhISEhISEhISEhISEhISEhISEhISEhISEhISEhISEhI="
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

# run_cmd NAME STDERR-MODE [VAR=VALUE ...] -- COMMAND...
# Runs COMMAND with a clean tool environment; writes $OUT/NAME.{out,err,rc} and
# the stub's call log to $LOGS/NAME.log. STDERR-MODE is "file" (captured) or
# "closed" (the command is started with file descriptor 2 closed, as in
# `lucairn ... 2>&-`; NAME.err is then an empty file).
run_cmd() {
  local name="$1" stderr_mode="$2"; shift 2
  local -a envs
  envs=("PATH=$BASE_PATH" "STUB_LOG=$LOGS/$name.log")
  while [ "$1" != "--" ]; do envs[${#envs[@]}]="$1"; shift; done
  shift
  : > "$LOGS/$name.log"
  local rc=0
  if [ "$stderr_mode" = "closed" ]; then
    : > "$OUT/$name.err"
    env -u LUCAIRN_BUNDLE_VERIFY -u LUCAIRN_BUNDLE_EXPORT -u STUB_EXIT -u STUB_VERSION_LINE \
      "${envs[@]}" "$@" > "$OUT/$name.out" 2>&- || rc=$?
  else
    env -u LUCAIRN_BUNDLE_VERIFY -u LUCAIRN_BUNDLE_EXPORT -u STUB_EXIT -u STUB_VERSION_LINE \
      "${envs[@]}" "$@" > "$OUT/$name.out" 2> "$OUT/$name.err" || rc=$?
  fi
  printf '%s\n' "$rc" > "$OUT/$name.rc"
}
# run NAME [VAR=VALUE ...] -- CLI-ARGS...          the CLI, stderr captured
# run_stderr_closed NAME [VAR=VALUE ...] -- CLI-ARGS...   the CLI with 2>&-
# run_traced NAME [VAR=VALUE ...] -- CLI-ARGS...   the CLI under `bash -x`;
#                                                  NAME.err holds the trace
run_variant() { # run_variant STDERR-MODE PREFIX-WORDS NAME [VAR=VALUE ...] -- CLI-ARGS...
  local stderr_mode="$1" prefix="$2" name="$3"; shift 3
  local -a head
  head=("$name" "$stderr_mode")
  while [ "$1" != "--" ]; do head[${#head[@]}]="$1"; shift; done
  shift
  # shellcheck disable=SC2086  # prefix is a fixed word list ("" or "bash -x")
  run_cmd "${head[@]}" -- $prefix "$LUCAIRN" "$@"
}
run() { run_variant file "" "$@"; }
run_stderr_closed() { run_variant closed "" "$@"; }
run_traced() { run_variant file "bash -x" "$@"; }
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
for code in 0 1 2 7; do
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

echo "evidence verify - no way out before the tool starts can look like a verdict"
# stderr closed (lucairn ... 2>&-): the wrapper's own messages cannot be
# written. A stop must still be 3, and a good run must still reach the tool.
run_stderr_closed closed-missing-bundle -- evidence verify "$TMP/nope.zip" --env "$GOOD_ENV" --tool "$STUB_TOOL"
check "stderr closed, bundle missing -> exit 3 (1 would read as TAMPERED)" [ "$(rc_of closed-missing-bundle)" = "3" ]
check "stderr closed, bundle missing -> tool not started, stdout empty" bash -c '[ ! -s "$1" ] && [ ! -s "$2" ]' _ "$LOGS/closed-missing-bundle.log" "$OUT/closed-missing-bundle.out"
for code in 0 2; do
  run_stderr_closed "closed-good-$code" "STUB_EXIT=$code" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
  check "stderr closed, good run -> the tool's exit code $code" [ "$(rc_of "closed-good-$code")" = "$code" ]
  check "stderr closed, good run (exit $code) -> the tool WAS started, with the full argument list" cmp -s "$TMP/expected-argv" "$LOGS/closed-good-$code.log"
  check "stderr closed, good run (exit $code) -> stdout is the tool's" cmp -s "$TMP/expected-stdout-$code" "$OUT/closed-good-$code.out"
done
run_stderr_closed closed-unversioned "STUB_VERSION_LINE=lucairn-bundle-verify dev" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --allow-unversioned-tool
check "stderr closed, the unversioned-tool warning cannot stop the run" bash -c '[ "$(cat "$1")" = "0" ] && grep -qx RUN "$2"' _ "$OUT/closed-unversioned.rc" "$LOGS/closed-unversioned.log"

# A helper program the wrapper needs fails under `set -e`. No message was
# written for this case on purpose: it pins the EXIT trap, which turns every
# exit before the tool into 3.
mkdir -p "$BIN/failing-base64"
printf '#!/bin/sh\nexit 1\n' > "$BIN/failing-base64/base64"
chmod +x "$BIN/failing-base64/base64"
run helper-fails "PATH=$BIN/failing-base64:$BASE_PATH" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict helper-fails "a failing base64 on PATH -> exit 3, tool not run" "stopped before the verifier was run"
run_stderr_closed helper-fails-closed "PATH=$BIN/failing-base64:$BASE_PATH" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
check "a failing base64 with stderr closed -> exit 3" bash -c '[ "$(cat "$1")" = "3" ] && [ ! -s "$2" ]' _ "$OUT/helper-fails-closed.rc" "$LOGS/helper-fails-closed.log"

# A failure in the lines of the CLI that run before the verb is even looked at
# (here: a sibling helper that fails to load). The control run shows that this
# kit copy really does fail that early, with 1, for another verb.
BROKEN_KIT="$TMP/broken-kit"
mkdir -p "$BROKEN_KIT/bin"
cp "$LUCAIRN" "$BROKEN_KIT/bin/lucairn"
printf 'return 1\n' > "$BROKEN_KIT/bin/runtime-profile-lib.sh"
run_cmd early-failure file -- "$BROKEN_KIT/bin/lucairn" evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
check "a failure before the verb is dispatched -> exit 3, tool not run" bash -c '[ "$(cat "$1")" = "3" ] && [ ! -s "$2" ] && [ ! -s "$3" ]' _ "$OUT/early-failure.rc" "$LOGS/early-failure.log" "$OUT/early-failure.out"
run_cmd early-failure-control file -- "$BROKEN_KIT/bin/lucairn" evidence list
check "control: the same broken kit exits 1 for another verb (the early guard is for evidence verify only)" [ "$(rc_of early-failure-control)" = "1" ]

# --help is its own request. Inside a verification call it must not be a way
# to exit 0 without the tool having run.
run verify-help -- evidence verify --help
check "evidence verify --help on its own exits 0" [ "$(rc_of verify-help)" = "0" ]
check "evidence verify --help on its own prints the usage" grep -qF 'Evidence bundles are NOT delivery bundles' "$OUT/verify-help.out"
run verify-help-short -- evidence verify -h
check "evidence verify -h on its own exits 0" [ "$(rc_of verify-help-short)" = "0" ]
run verify-help-last -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --help
no_verdict verify-help-last "--help after a full verification call -> exit 3, tool not run" "only answered on its own"
run verify-help-first -- evidence verify --help "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
no_verdict verify-help-first "--help before a full verification call -> exit 3, tool not run" "only answered on its own"
run verify-help-short-mixed -- evidence verify "$BUNDLE" -h
no_verdict verify-help-short-mixed "-h next to a bundle path -> exit 3" "only answered on its own"

echo "evidence verify - arguments the tool would answer 2 for are stopped here"
n=0
for bad in "yesterday" "2026-11-01" "2026-11-01 00:00:00Z" "2026-11-01T00:00:00" "2026-11-01T00:00:00+02:00" \
  "2026-13-01T00:00:00Z" "2026-00-10T00:00:00Z" "2026-02-30T00:00:00Z" "2027-02-29T00:00:00Z" "2100-02-29T00:00:00Z" \
  "2026-04-31T00:00:00Z" "2026-11-00T00:00:00Z" "2026-11-01T24:00:00Z" "2026-11-01T00:60:00Z" "2026-11-01T00:00:60Z" \
  "2026-11-01t00:00:00z" "2026-11-01T00:00:00.Z" "2026-11-01T00:00:00.1234567890Z" "2026-11-01T00:00:00Z;x" " 2026-11-01T00:00:00Z" ""; do
  n=$((n + 1))
  run "binding-bad-$n" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --require-binding-after "$bad"
  no_verdict "binding-bad-$n" "--require-binding-after '$bad' -> exit 3, tool not run" "RFC 3339 time in UTC"
done
n=0
for good in "2026-11-01T00:00:00Z" "2028-02-29T23:59:59.123456789Z" "2000-02-29T00:00:00Z" "2026-08-09T08:09:09Z" "2026-12-31T23:59:59.5Z"; do
  n=$((n + 1))
  run "binding-good-$n" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --require-binding-after "$good"
  check "--require-binding-after '$good' reaches the tool unchanged" bash -c '[ "$(cat "$1")" = "0" ] && grep -qxF -- "$3" "$2"' _ "$OUT/binding-good-$n.rc" "$LOGS/binding-good-$n.log" "$good"
done
run tsa-absent -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --tsa-root "$TMP/no-such-root.pem"
no_verdict tsa-absent "--tsa-root file that does not exist -> exit 3, tool not run" "--tsa-root file not found or not readable"
run rekor-absent -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --rekor-key "$TMP/no-such-key.pem"
no_verdict rekor-absent "--rekor-key file that does not exist -> exit 3, tool not run" "--rekor-key file not found or not readable"
run rekor-directory -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --rekor-key "$TMP"
no_verdict rekor-directory "--rekor-key that is a directory -> exit 3, tool not run" "--rekor-key file not found or not readable"
if [ "$(id -u)" != "0" ]; then
  printf 'x\n' > "$TMP/unreadable.pem"
  chmod 000 "$TMP/unreadable.pem"
  run tsa-unreadable -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --tsa-root "$TMP/unreadable.pem"
  no_verdict tsa-unreadable "--tsa-root file that cannot be read -> exit 3, tool not run" "--tsa-root file not found or not readable"
  chmod 600 "$TMP/unreadable.pem"
fi

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

# ... and the seed of ANOTHER key: every public slot is compared with every
# *_SIGNING_KEY value of the file, not only with its own.
seed_refused() { # seed_refused RUN-NAME LABEL PUBLIC-VAR SIGNING-VAR SEED-VALUE
  if [ "$(rc_of "$1")" = "3" ] && out_empty "$1" && [ ! -s "$LOGS/$1.log" ] \
    && err_has "$1" "private signing seed" && err_has "$1" "$3" && err_has "$1" "$4" \
    && ! grep -qiF -- "$5" "$OUT/$1.out" "$OUT/$1.err" "$LOGS/$1.log"; then
    pass "$2"
  else
    bad "$2" "rc=$(rc_of "$1") tool-log-bytes=$(wc -c < "$LOGS/$1.log" | tr -d ' ') stderr-lines=$(wc -l < "$OUT/$1.err" | tr -d ' ')"
  fi
}
mutate seed-cross LCR_BRIDGE_PUBLIC_KEY "$SEED_AUDIT"
run key-seed-cross -- evidence verify "$BUNDLE" --env "$ENVS/seed-cross.env" --tool "$STUB_TOOL"
seed_refused key-seed-cross "LCR_BRIDGE_PUBLIC_KEY holding the value of LCR_AUDIT_SIGNING_KEY -> exit 3, tool never started, value nowhere" \
  LCR_BRIDGE_PUBLIC_KEY LCR_AUDIT_SIGNING_KEY "$SEED_AUDIT"
mutate seed-cross-witness LCR_WITNESS_PUBLIC_KEY "$SEED_GATEWAY"
run key-seed-cross-witness -- evidence verify "$BUNDLE" --env "$ENVS/seed-cross-witness.env" --tool "$STUB_TOOL"
seed_refused key-seed-cross-witness "the witness slot holding the gateway seed -> refused" \
  LCR_WITNESS_PUBLIC_KEY LCR_GATEWAY_SIGNING_KEY "$SEED_GATEWAY"
mutate seed-cross-upper LCR_GATEWAY_PUBLIC_KEY "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
run key-seed-cross-upper -- evidence verify "$BUNDLE" --env "$ENVS/seed-cross-upper.env" --tool "$STUB_TOOL"
seed_refused key-seed-cross-upper "another key's seed in a public slot is caught regardless of hex case" \
  LCR_GATEWAY_PUBLIC_KEY LCR_BRIDGE_SIGNING_KEY "$SEED_BRIDGE"
# The legacy name of a signing key.
SEED_LEGACY="5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c"
{ sed -e '/^LCR_GATEWAY_SIGNING_KEY=/d' -e "s|^LCR_SANITIZER_PUBLIC_KEY=.*|LCR_SANITIZER_PUBLIC_KEY=$SEED_LEGACY|" "$GOOD_ENV"
  printf 'VEIL_GATEWAY_SIGNING_KEY=%s\n' "$SEED_LEGACY"; } > "$ENVS/seed-legacy.env"
run key-seed-legacy -- evidence verify "$BUNDLE" --env "$ENVS/seed-legacy.env" --tool "$STUB_TOOL"
seed_refused key-seed-legacy "a legacy VEIL_*_SIGNING_KEY value in a public slot -> refused" \
  LCR_SANITIZER_PUBLIC_KEY VEIL_GATEWAY_SIGNING_KEY "$SEED_LEGACY"
# A signing key the wrapper has no table row for.
SEED_OTHER="6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d"
{ sed "s|^LCR_AUDIT_PUBLIC_KEY=.*|LCR_AUDIT_PUBLIC_KEY=$SEED_OTHER|" "$GOOD_ENV"
  printf 'LCR_MANIFEST_SIGNING_KEY=%s\n' "$SEED_OTHER"; } > "$ENVS/seed-other.env"
run key-seed-other -- evidence verify "$BUNDLE" --env "$ENVS/seed-other.env" --tool "$STUB_TOOL"
seed_refused key-seed-other "a *_SIGNING_KEY the wrapper has no row for (manifest) in a public slot -> refused" \
  LCR_AUDIT_PUBLIC_KEY LCR_MANIFEST_SIGNING_KEY "$SEED_OTHER"
# The seed line written the ways an env file gets written by hand: export,
# quotes, a trailing comment, upper-case hex, no newline at the end of the file.
SEED_QUOTED="7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e"
{ sed "s|^LCR_SANDBOX_B_PUBLIC_KEY=.*|LCR_SANDBOX_B_PUBLIC_KEY=$SEED_QUOTED|" "$GOOD_ENV"
  printf 'export LCR_EXTRA_SIGNING_KEY = "%s"  # rotated in' "7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E7E"; } > "$ENVS/seed-quoted.env"
run key-seed-quoted -- evidence verify "$BUNDLE" --env "$ENVS/seed-quoted.env" --tool "$STUB_TOOL"
seed_refused key-seed-quoted "export / quotes / trailing comment / no final newline do not hide a seed" \
  LCR_SANDBOX_B_PUBLIC_KEY LCR_EXTRA_SIGNING_KEY "$SEED_QUOTED"
# A retired seed left in the file as a comment.
SEED_RETIRED="8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f"
{ sed "s|^LCR_BRIDGE_PUBLIC_KEY=.*|LCR_BRIDGE_PUBLIC_KEY=$SEED_RETIRED|" "$GOOD_ENV"
  printf '# LCR_BRIDGE_SIGNING_KEY=%s\n' "$SEED_RETIRED"; } > "$ENVS/seed-retired.env"
run key-seed-retired -- evidence verify "$BUNDLE" --env "$ENVS/seed-retired.env" --tool "$STUB_TOOL"
seed_refused key-seed-retired "a commented-out *_SIGNING_KEY line still counts" \
  LCR_BRIDGE_PUBLIC_KEY LCR_BRIDGE_SIGNING_KEY "$SEED_RETIRED"
# Not over-eager: a public value that also sits on lines that are NOT signing
# keys (a *_SIGNING_KEY_ID line, a note, a second public slot) is passed on.
{ cat "$GOOD_ENV"
  printf 'LCR_MANIFEST_SIGNING_KEY_ID=%s\n' "$PUB_AUDIT"
  printf 'LCR_NOTE_ABOUT_SIGNING_KEYS=%s\n' "$PUB_BRIDGE"
  printf '# the sanitizer public key is %s\n' "$PUB_SANITIZER"; } > "$ENVS/not-seeds.env"
run key-not-seeds -- evidence verify "$BUNDLE" --env "$ENVS/not-seeds.env" --tool "$STUB_TOOL"
check "a public value on a line that is not a *_SIGNING_KEY is still passed (same argument list)" cmp -s "$TMP/expected-argv" "$LOGS/key-not-seeds.log"

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

echo "evidence verify - EVERY value taken from the env file passes the one gate (key id included)"
# The key id is printed on stderr and is part of --witness-key. It is read from
# the same file as the seeds, so it gets the same refusal as a public slot.
value_nowhere() { # value_nowhere RUN-NAME VALUE : not in stdout, stderr/trace or the tool's log
  ! grep -qiF -- "$2" "$OUT/$1.out" "$OUT/$1.err" "$LOGS/$1.log"
}
slot_env() { # slot_env NAME VAR VALUE [EXTRA-LINE] -> $ENVS/NAME.env
  { sed "s|^$2=.*|$2=$3|" "$GOOD_ENV"; [ -z "${4:-}" ] || printf '%s\n' "$4"; } > "$ENVS/$1.env"
}
# The exact report: LCR_AUDIT_SIGNING_KEY=S and LCR_WITNESS_KEY_ID=S.
slot_env keyid-seed LCR_WITNESS_KEY_ID "$SEED_AUDIT"
run keyid-seed -- evidence verify "$BUNDLE" --env "$ENVS/keyid-seed.env" --tool "$STUB_TOOL"
seed_refused keyid-seed "LCR_WITNESS_KEY_ID holding the value of LCR_AUDIT_SIGNING_KEY -> exit 3, tool never started, value nowhere" \
  LCR_WITNESS_KEY_ID LCR_AUDIT_SIGNING_KEY "$SEED_AUDIT"
run_traced keyid-seed-traced -- evidence verify "$BUNDLE" --env "$ENVS/keyid-seed.env" --tool "$STUB_TOOL"
check "... the same under bash -x: exit 3, the value in no trace, tool never started" \
  bash -c '[ "$(cat "$1.rc")" = "3" ] && [ ! -s "$2" ] && ! grep -qiF -- "$3" "$1.err" "$1.out"' _ "$OUT/keyid-seed-traced" "$LOGS/keyid-seed-traced.log" "$SEED_AUDIT"
{ grep -v '^LCR_WITNESS_KEY_ID=' "$GOOD_ENV"; printf 'VEIL_WITNESS_KEY_ID=%s\n' "$SEED_AUDIT"; } > "$ENVS/keyid-seed-legacy.env"
run keyid-seed-legacy -- evidence verify "$BUNDLE" --env "$ENVS/keyid-seed-legacy.env" --tool "$STUB_TOOL"
seed_refused keyid-seed-legacy "the legacy VEIL_WITNESS_KEY_ID line holding a seed -> refused the same way" \
  LCR_WITNESS_KEY_ID LCR_AUDIT_SIGNING_KEY "$SEED_AUDIT"
slot_env keyid-seed-upper LCR_WITNESS_KEY_ID "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
run keyid-seed-upper -- evidence verify "$BUNDLE" --env "$ENVS/keyid-seed-upper.env" --tool "$STUB_TOOL"
seed_refused keyid-seed-upper "a seed in the key id is caught regardless of hex case" \
  LCR_WITNESS_KEY_ID LCR_BRIDGE_SIGNING_KEY "$SEED_BRIDGE"
slot_env keyid-seed-prefixed LCR_WITNESS_KEY_ID "witness-$SEED_GATEWAY"
run keyid-seed-prefixed -- evidence verify "$BUNDLE" --env "$ENVS/keyid-seed-prefixed.env" --tool "$STUB_TOOL"
seed_refused keyid-seed-prefixed "a key id with a seed inside it (label + seed) -> refused" \
  LCR_WITNESS_KEY_ID LCR_GATEWAY_SIGNING_KEY "$SEED_GATEWAY"
# Equality counts at any length: a short value on a *_SIGNING_KEY line.
SHORT_SIGNING_VALUE="synth-short-1"   # under 16 characters: only the exact comparison can catch it
slot_env keyid-short LCR_WITNESS_KEY_ID "$SHORT_SIGNING_VALUE" "LCR_DEMO_SIGNING_KEY=$SHORT_SIGNING_VALUE"
run keyid-short -- evidence verify "$BUNDLE" --env "$ENVS/keyid-short.env" --tool "$STUB_TOOL"
seed_refused keyid-short "a key id equal to a SHORT *_SIGNING_KEY value -> refused (equality at any length)" \
  LCR_WITNESS_KEY_ID LCR_DEMO_SIGNING_KEY "$SHORT_SIGNING_VALUE"

# The shape rule: it holds even where there is no signing line to compare with.
SEED_UNLISTED="3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b"
key_id_refused() { # key_id_refused RUN-NAME LABEL NEEDLE VALUE
  if [ "$(rc_of "$1")" = "3" ] && out_empty "$1" && [ ! -s "$LOGS/$1.log" ] \
    && err_has "$1" "LCR_WITNESS_KEY_ID" && err_has "$1" "$3" && err_has "$1" "no verdict" && value_nowhere "$1" "$4"; then
    pass "$2"
  else
    bad "$2" "rc=$(rc_of "$1") tool-log-bytes=$(wc -c < "$LOGS/$1.log" | tr -d ' ') stderr-lines=$(wc -l < "$OUT/$1.err" | tr -d ' ')"
  fi
}
sed "s|^LCR_WITNESS_KEY_ID=.*|LCR_WITNESS_KEY_ID=$SEED_UNLISTED|" "$ENVS/public-only.env" > "$ENVS/keyid-shape.env"
run keyid-shape -- evidence verify "$BUNDLE" --env "$ENVS/keyid-shape.env" --tool "$STUB_TOOL"
key_id_refused keyid-shape "a 64-hex key id in a file WITHOUT signing lines -> exit 3 by shape, value nowhere" "shape of a key" "$SEED_UNLISTED"
run_traced keyid-shape-traced -- evidence verify "$BUNDLE" --env "$ENVS/keyid-shape.env" --tool "$STUB_TOOL"
check "... the same under bash -x: exit 3, the value in no trace" \
  bash -c '[ "$(cat "$1.rc")" = "3" ] && ! grep -qiF -- "$2" "$1.err" "$1.out"' _ "$OUT/keyid-shape-traced" "$SEED_UNLISTED"
sed "s|^LCR_WITNESS_KEY_ID=.*|LCR_WITNESS_KEY_ID=id_${SEED_UNLISTED}_v1|" "$ENVS/public-only.env" > "$ENVS/keyid-shape-inside.env"
run keyid-shape-inside -- evidence verify "$BUNDLE" --env "$ENVS/keyid-shape-inside.env" --tool "$STUB_TOOL"
key_id_refused keyid-shape-inside "64 hex digits in a row INSIDE a key id -> exit 3 by shape" "shape of a key" "$SEED_UNLISTED"
# 128 hex characters: a seed followed by its public key.
sed "s|^LCR_WITNESS_KEY_ID=.*|LCR_WITNESS_KEY_ID=${SEED_UNLISTED}${SEED_UNLISTED}|" "$ENVS/public-only.env" > "$ENVS/keyid-shape-128.env"
run keyid-shape-128 -- evidence verify "$BUNDLE" --env "$ENVS/keyid-shape-128.env" --tool "$STUB_TOOL"
key_id_refused keyid-shape-128 "a 128-hex key id -> exit 3 by shape" "shape of a key" "$SEED_UNLISTED"
# The standard base64 of 32 bytes always ends in "=": outside the label alphabet.
B64_UNLISTED="Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs="
sed "s|^LCR_WITNESS_KEY_ID=.*|LCR_WITNESS_KEY_ID=$B64_UNLISTED|" "$ENVS/public-only.env" > "$ENVS/keyid-base64.env"
run keyid-base64 -- evidence verify "$BUNDLE" --env "$ENVS/keyid-base64.env" --tool "$STUB_TOOL"
key_id_refused keyid-base64 "the standard base64 of a key as key id -> exit 3, value nowhere" "characters outside" "$B64_UNLISTED"
sed "s|^LCR_WITNESS_KEY_ID=.*|LCR_WITNESS_KEY_ID=REPLACE_ME_key_id|" "$ENVS/public-only.env" > "$ENVS/keyid-placeholder.env"
run keyid-placeholder -- evidence verify "$BUNDLE" --env "$ENVS/keyid-placeholder.env" --tool "$STUB_TOOL"
key_id_refused keyid-placeholder "a REPLACE_ME key id -> exit 3" "still the REPLACE_ME placeholder" "REPLACE_ME_key_id"
LONG_ID="$(printf 'w%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43)"
slot_env keyid-long LCR_WITNESS_KEY_ID "${LONG_ID}${LONG_ID}${LONG_ID}"
run keyid-long -- evidence verify "$BUNDLE" --env "$ENVS/keyid-long.env" --tool "$STUB_TOOL"
key_id_refused keyid-long "a key id longer than 128 characters -> exit 3, not echoed" "longer than 128" "${LONG_ID}${LONG_ID}${LONG_ID}"
# Not over-eager: ordinary labels pass, also ones that happen to be a short
# part of a seed (the letter a) or carry some hex.
n=0
for good_id in "a" "witness_v1" "witness_dev_v1" "witness-2026-10.v2_DEADBEEF" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde"; do
  n=$((n + 1))
  slot_env "keyid-good-$n" LCR_WITNESS_KEY_ID "$good_id"
  run "keyid-good-$n" -- evidence verify "$BUNDLE" --env "$ENVS/keyid-good-$n.env" --tool "$STUB_TOOL"
  check "key id '$(printf '%s' "$good_id" | cut -c1-30)' is passed on as it is" bash -c '[ "$(cat "$1")" = "0" ] && grep -qxF -- "$3" "$2"' _ "$OUT/keyid-good-$n.rc" "$LOGS/keyid-good-$n.log" "$good_id=$B64_WITNESS"
done

# One uniform matrix over all seven lines the wrapper reads: the value of a
# signing key it has no row for, in each of them, plain and under bash -x.
SEED_MATRIX="4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c"
for var in LCR_WITNESS_KEY_ID LCR_WITNESS_PUBLIC_KEY LCR_BRIDGE_PUBLIC_KEY LCR_SANITIZER_PUBLIC_KEY LCR_SANDBOX_B_PUBLIC_KEY LCR_AUDIT_PUBLIC_KEY LCR_GATEWAY_PUBLIC_KEY; do
  slot_env "slot-$var" "$var" "$SEED_MATRIX" "LCR_MANIFEST_SIGNING_KEY=$SEED_MATRIX"
  run "slot-$var" -- evidence verify "$BUNDLE" --env "$ENVS/slot-$var.env" --tool "$STUB_TOOL"
  seed_refused "slot-$var" "$var holding a *_SIGNING_KEY value -> exit 3, tool never started, value nowhere" \
    "$var" LCR_MANIFEST_SIGNING_KEY "$SEED_MATRIX"
  run_traced "slot-traced-$var" -- evidence verify "$BUNDLE" --env "$ENVS/slot-$var.env" --tool "$STUB_TOOL"
  check "$var holding a *_SIGNING_KEY value, bash -x -> exit 3, value in no trace, tool never started" \
    bash -c '[ "$(cat "$1.rc")" = "3" ] && [ ! -s "$2" ] && ! grep -qiF -- "$3" "$1.err" "$1.out"' _ "$OUT/slot-traced-$var" "$LOGS/slot-traced-$var.log" "$SEED_MATRIX"
done
# The NAME of a signing line comes from the file too. One that could itself
# be carrying key material is not repeated in the message.
NAME_KEYLIKE="9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b9b"
slot_env name-keylike LCR_AUDIT_PUBLIC_KEY "$SEED_MATRIX" "${NAME_KEYLIKE}_SIGNING_KEY=$SEED_MATRIX"
run name-keylike -- evidence verify "$BUNDLE" --env "$ENVS/name-keylike.env" --tool "$STUB_TOOL"
check "a key-shaped NAME of a signing line is not echoed (the refusal still names the public line)" \
  bash -c '[ "$(cat "$1.rc")" = "3" ] && grep -qF "another *_SIGNING_KEY line" "$1.err" && grep -qF LCR_AUDIT_PUBLIC_KEY "$1.err" && ! grep -qiF -- "$2" "$1.err" "$1.out" && ! grep -qiF -- "$3" "$1.err" "$1.out"' \
  _ "$OUT/name-keylike" "$NAME_KEYLIKE" "$SEED_MATRIX"
# Each half of that rule on its own: a short name with 16 hex digits in a row,
# and a long name (over 64 characters) without any.
NAME_HEXRUN="K_9b9b9b9b9b9b9b9b9b9b"
slot_env name-hexrun LCR_AUDIT_PUBLIC_KEY "$SEED_MATRIX" "${NAME_HEXRUN}_SIGNING_KEY=$SEED_MATRIX"
run name-hexrun -- evidence verify "$BUNDLE" --env "$ENVS/name-hexrun.env" --tool "$STUB_TOOL"
check "a signing-line NAME with 16+ hex digits in a row is not echoed" \
  bash -c '[ "$(cat "$1.rc")" = "3" ] && grep -qF "another *_SIGNING_KEY line" "$1.err" && ! grep -qiF -- "$2" "$1.err" "$1.out"' _ "$OUT/name-hexrun" "$NAME_HEXRUN"
NAME_LONG="ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ_ZZ"
slot_env name-long LCR_AUDIT_PUBLIC_KEY "$SEED_MATRIX" "${NAME_LONG}_SIGNING_KEY=$SEED_MATRIX"
run name-long -- evidence verify "$BUNDLE" --env "$ENVS/name-long.env" --tool "$STUB_TOOL"
check "a signing-line NAME longer than 64 characters is not echoed" \
  bash -c '[ "$(cat "$1.rc")" = "3" ] && grep -qF "another *_SIGNING_KEY line" "$1.err" && ! grep -qiF -- "$2" "$1.err" "$1.out"' _ "$OUT/name-long" "$NAME_LONG"
# By construction: inside the evidence block the env readers are called from
# the gate and from nowhere else, and the env file is opened in one place.
awk '/^# lucairn evidence - EVIDENCE bundles/{on=1} /^main\(\) \{/{on=0} on' "$LUCAIRN" > "$TMP/evidence-block-gate.sh"
awk '/^evidence_env_value_untraced\(\) \{/{on=1} on{print} on && /^\}/{on=0}' "$TMP/evidence-block-gate.sh" > "$TMP/evidence-gate-fn.sh"
count_calls() { grep -Ec '(^|[^A-Za-z_])(env_value|env_value_with_legacy)[[:space:]]+"' "$1" || true; }
check "the gate function was found" [ "$(wc -l < "$TMP/evidence-gate-fn.sh" | tr -d ' ')" -gt 20 ]
check "the env readers are called in the gate (2 call sites) and nowhere else in the evidence block" \
  bash -c '[ "$1" = "2" ] && [ "$2" = "2" ]' _ "$(count_calls "$TMP/evidence-gate-fn.sh")" "$(count_calls "$TMP/evidence-block-gate.sh")"
check "the env file is opened for reading in exactly one place of the evidence block (the seed collection)" \
  [ "$(grep -c '< "\$env' "$TMP/evidence-block-gate.sh")" = "1" ]
check "the evidence block never sources a file" bash -c '! grep -Eq "(^|[;&|[:space:]])(source|\.)[[:space:]]+\"?\\$" "$1"' _ "$TMP/evidence-block-gate.sh"

# The tool call is made with errexit off. That is load-bearing: Bash 3.2 with
# errexit on reports a file it could not start as 1 (TAMPERED), not 126/127.
check "the verifier is called with errexit off, and its status is read on the next line" \
  bash -c 'awk "prev2 == \"  set +e\" && prev1 == \"  \\\"\\\$tool\\\" \\\"\\\${tool_args[@]}\\\" -- \\\"\\\$bundle\\\"\" && \$0 == \"  rc=\\\$?\" {ok=1} {prev2=prev1; prev1=\$0} END{exit ok?0:1}" "$1"' _ "$TMP/evidence-block-gate.sh"

echo "evidence verify - no seed in the environment of any program the wrapper starts"
# Nothing in the evidence block is exported. `bash -a` (allexport) exports
# every variable all the same, locals included; the wrapper starts no program
# while a plain variable holds a seed, so even then no child can see one.
ENVDUMPS="$TMP/envdumps"
mkdir -p "$ENVDUMPS" "$BIN/env-spy"
for helper in grep sed tail tr base64; do
  real_helper="$(PATH="/usr/bin:/bin" command -v "$helper")"
  cat > "$BIN/env-spy/$helper" <<SPY
#!/bin/sh
env >> "\$SPY_ENV_DIR/helpers.env"
printf '%s\\n' "$helper" "\$@" >> "\$SPY_ENV_DIR/helpers.argv"
exec "$real_helper" "\$@"
SPY
  chmod +x "$BIN/env-spy/$helper"
done
cat > "$BIN/other/env-spy-tool" <<'STUB'
#!/usr/bin/env bash
env >> "$SPY_ENV_DIR/tool.env"
if [ "${1:-}" = "--version" ]; then
  printf 'lucairn-bundle-verify 1.0.0\n'
  exit 0
fi
printf 'RUN\n' >> "$STUB_LOG"
exit 0
STUB
chmod +x "$BIN/other/env-spy-tool"
run env-spy "PATH=$BIN/env-spy:$BASE_PATH" "SPY_ENV_DIR=$ENVDUMPS" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$BIN/other/env-spy-tool"
check "with spying helpers the run still works" bash -c '[ "$(cat "$1")" = "0" ] && grep -qx RUN "$2"' _ "$OUT/env-spy.rc" "$LOGS/env-spy.log"
run_variant file "bash -a" env-spy-allexport "PATH=$BIN/env-spy:$BASE_PATH" "SPY_ENV_DIR=$ENVDUMPS" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$BIN/other/env-spy-tool"
check "under bash -a the run still works" bash -c '[ "$(cat "$1")" = "0" ] && grep -qx RUN "$2"' _ "$OUT/env-spy-allexport.rc" "$LOGS/env-spy-allexport.log"
check "positive control: the helpers and the tool were spied on, and allexport really exported script variables" \
  bash -c '[ -s "$1/helpers.env" ] && [ -s "$1/tool.env" ] && grep -q "^LUCAIRN_EVIDENCE_VERIFY_TOOL=" "$1/helpers.env" && grep -q "^LUCAIRN_EVIDENCE_VERIFY_TOOL=" "$1/tool.env"' _ "$ENVDUMPS"
env_shown=""
for value in "$SEED_WITNESS" "$SEED_BRIDGE" "$SEED_SANITIZER" "$SEED_SANDBOX_B" "$SEED_AUDIT" "$SEED_GATEWAY" "$ADMIN_KEY_VALUE"; do
  if grep -rqiF -- "$value" "$ENVDUMPS"; then env_shown="$env_shown x"; fi
done
check "no signing seed and no admin key value in the environment of any helper or of the tool (plain and bash -a)" [ -z "$env_shown" ]
# What the helpers are CALLED with: variable names and the file path. Every
# value travels on a pipe, so not even a public key is on a helper's command
# line (the process list shows command lines).
argv_shown=""
for value in "$PUB_WITNESS" "$PUB_BRIDGE" "$PUB_SANITIZER" "$PUB_SANDBOX_B" "$PUB_AUDIT" "$PUB_GATEWAY" \
  "$B64_WITNESS" "$B64_BRIDGE" "$B64_SANITIZER" "$B64_SANDBOX_B" "$B64_AUDIT" "$B64_GATEWAY" "witness_test_v1"; do
  if grep -qiF -- "$value" "$ENVDUMPS/helpers.argv"; then argv_shown="$argv_shown x"; fi
done
check "positive control: the helpers' command lines were recorded (grep was asked for a variable by name)" grep -qF 'LCR_WITNESS_PUBLIC_KEY=' "$ENVDUMPS/helpers.argv"
check "no value from the env file on the command line of any helper program (seeds: see the check above; here the public ones)" [ -z "$argv_shown" ]
# No file is written by the evidence block: no temp file, no here-string (Bash
# backs those with a temp file), no redirect to a path.
check "the evidence block writes no file (no mktemp, no here-string, no tee, no redirect to a path)" \
  bash -c '! grep -Eq "mktemp|<<<|(^|[[:space:]|])tee[[:space:]]" "$1" && ! grep -E "[^<&0-9]>>?[[:space:]]*[^&[:space:]>]" "$1" | grep -v "^[[:space:]]*#" | grep -qv "2>/dev/null"' _ "$TMP/evidence-block-gate.sh"

echo "evidence verify - the minimum version check fails closed"
# A helper that fails must never turn "too old" into "new enough". `cut` is
# the one the first version of this check went through.
for helper in cut head sed tr grep tail; do
  mkdir -p "$BIN/failing-$helper"
  printf '#!/bin/sh\nexit 1\n' > "$BIN/failing-$helper/$helper"
  chmod +x "$BIN/failing-$helper/$helper"
  run "old-tool-failing-$helper" "PATH=$BIN/failing-$helper:$BASE_PATH" "STUB_VERSION_LINE=lucairn-bundle-verify 0.9.9" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
  check "a too-old tool with a failing '$helper' on PATH -> exit 3, tool not run" \
    bash -c '[ "$(cat "$1")" = "3" ] && ! grep -qx RUN "$2" && [ ! -s "$3" ]' _ "$OUT/old-tool-failing-$helper.rc" "$LOGS/old-tool-failing-$helper.log" "$OUT/old-tool-failing-$helper.out"
done
no_verdict old-tool-failing-cut "a too-old tool with a failing cut -> the message still says which version" "is version 0.9.9"
n=0
for unreadable in "1.0" "1" "0.9" "1.0.0.1" "1.0.0abc" "1.0.x" "1..0" "1.0." "1.0.0-" "1000000000.0.0" "1.0.00000000001"; do
  n=$((n + 1))
  run "version-unreadable-$n" "STUB_VERSION_LINE=lucairn-bundle-verify $unreadable" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
  no_verdict "version-unreadable-$n" "tool version '$unreadable' is not MAJOR.MINOR.PATCH -> exit 3, tool not run" "cannot read"
  run "version-unreadable-flag-$n" "STUB_VERSION_LINE=lucairn-bundle-verify $unreadable" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --allow-unversioned-tool
  no_verdict "version-unreadable-flag-$n" "... and --allow-unversioned-tool does not wave a numbered version '$unreadable' through" "cannot read"
done
n=0
for older in "0.9.9" "0.99.99" "0.0.0" "1.0.0-rc1" "1.0.0-rc1+build7" "00.9.9"; do
  n=$((n + 1))
  run "version-older-$n" "STUB_VERSION_LINE=lucairn-bundle-verify $older" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL" --allow-unversioned-tool
  no_verdict "version-older-$n" "tool version '$older' is older than 1.0.0 -> exit 3 (also with --allow-unversioned-tool)" "needs 1.0.0 or newer"
done
n=0
for newer in "1.0.0" "1.0.1" "1.10.0" "1.08.09" "2.0.0-rc1" "1.0.0+build5" "10.0.0" "v1.0.0"; do
  n=$((n + 1))
  run "version-ok-$n" "STUB_VERSION_LINE=lucairn-bundle-verify $newer" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
  check "tool version '$newer' is 1.0.0 or newer -> the tool runs" bash -c '[ "$(cat "$1")" = "0" ] && grep -qx RUN "$2"' _ "$OUT/version-ok-$n.rc" "$LOGS/version-ok-$n.log"
done

echo "evidence verify - a tool the shell cannot start is no verdict"
# The tool answers --version and is then gone (or no longer executable): the
# shell's 127 / 126 must not come back as if the verifier had returned them.
make_vanishing_stub() { # make_vanishing_stub PATH ACTION-ON-ITSELF
  cat > "$1" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf 'VERSION-CALL\n' >> "\$STUB_LOG"
  printf 'lucairn-bundle-verify 1.0.0\n'
  $2 "\$0"
  exit 0
fi
printf 'RUN\n' >> "\$STUB_LOG"
printf 'RESULT: stub\n'
exit 0
STUB
  chmod +x "$1"
}
not_startable() { # not_startable RUN-NAME LABEL
  if [ "$(rc_of "$1")" = "3" ] && out_empty "$1" && tool_not_run "$1" && grep -qx 'VERSION-CALL' "$LOGS/$1.log" \
    && err_has "$1" "could not be run" && err_has "$1" "no verdict"; then
    pass "$2"
  else
    bad "$2" "rc=$(rc_of "$1") stderr=$(tr '\n' '|' < "$OUT/$1.err" | cut -c1-300)"
  fi
}
make_vanishing_stub "$BIN/other/vanishing-tool" "rm -f"
run tool-vanished -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$BIN/other/vanishing-tool"
not_startable tool-vanished "the tool file disappears after --version (shell: 127) -> exit 3"
make_vanishing_stub "$BIN/other/unexecutable-tool" "chmod 644"
run tool-unexecutable -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$BIN/other/unexecutable-tool"
not_startable tool-unexecutable "the tool file loses its execute bit after --version (shell: 126) -> exit 3"
# The file is still there and still executable, but can no longer be started
# (its interpreter does not exist): the look right before the call passes and
# the shell's own 126/127 has to be caught. Under Bash 3.2 with errexit on,
# this is the case that came back as 1 - TAMPERED.
cat > "$BIN/other/swapped-tool" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'VERSION-CALL\n' >> "$STUB_LOG"
  printf 'lucairn-bundle-verify 1.0.0\n'
  printf '#!/nonexistent/interpreter-for-this-test\n' > "$0.new"
  chmod +x "$0.new"
  mv -f "$0.new" "$0"
  exit 0
fi
printf 'RUN\n' >> "$STUB_LOG"
exit 0
STUB
chmod +x "$BIN/other/swapped-tool"
run tool-swapped -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$BIN/other/swapped-tool"
not_startable tool-swapped "the tool file can no longer be started at the call itself (shell: 126/127) -> exit 3, never 1"
check "... and the message names the shell's code" grep -Eq 'the shell answered 12[67]' "$OUT/tool-swapped.err"
make_vanishing_stub "$BIN/other/vanishing-tool" "rm -f"
run_stderr_closed tool-vanished-closed -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$BIN/other/vanishing-tool"
check "the tool file disappears, stderr closed -> still exit 3, stdout empty" bash -c '[ "$(cat "$1")" = "3" ] && [ ! -s "$2" ]' _ "$OUT/tool-vanished-closed.rc" "$OUT/tool-vanished-closed.out"
for code in 126 127; do
  run "tool-says-$code" "STUB_EXIT=$code" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
  check "a program behind --tool that exits $code itself -> 3 (the verifier never returns $code)" \
    bash -c '[ "$(cat "$1.rc")" = "3" ] && grep -qF "never returns '"$code"'" "$1.err" && grep -qF "no verdict" "$1.err"' _ "$OUT/tool-says-$code"
done
# 3 is passed through like any other code of the program behind --tool: the
# wrapper does not claim a stop of its own then.
run tool-says-3 "STUB_EXIT=3" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
sed "s/@RC@/3/" "$TMP/expected-stub-stdout-template" > "$TMP/expected-stdout-3"
check "a program behind --tool that exits 3 itself: 3 comes back, with its stdout, and the wrapper adds no 'no verdict' line" \
  bash -c '[ "$(cat "$1.rc")" = "3" ] && cmp -s "$2" "$1.out" && ! grep -qF "no verdict" "$1.err"' _ "$OUT/tool-says-3" "$TMP/expected-stdout-3"
run tool-says-137 "STUB_EXIT=137" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
check "any other code (137) comes back unchanged" [ "$(rc_of tool-says-137)" = "137" ]

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

echo "evidence list / export - the one value they take from the env file passes the same gate"
# GATEWAY_PORT becomes part of the exporter's --gateway-url argument.
slot_env port-seed GATEWAY_PORT "$SEED_MATRIX" "LCR_MANIFEST_SIGNING_KEY=$SEED_MATRIX"
port_refused() { # port_refused RUN-NAME LABEL VALUE
  if [ "$(rc_of "$1")" = "1" ] && out_empty "$1" && [ ! -s "$LOGS/$1.log" ] && err_has "$1" "private signing seed" \
    && err_has "$1" "GATEWAY_PORT" && err_has "$1" "LCR_MANIFEST_SIGNING_KEY" && value_nowhere "$1" "$3"; then
    pass "$2"
  else
    bad "$2" "rc=$(rc_of "$1") tool-log-bytes=$(wc -c < "$LOGS/$1.log" | tr -d ' ') stderr-lines=$(wc -l < "$OUT/$1.err" | tr -d ' ')"
  fi
}
for verb in list export; do
  if [ "$verb" = "export" ]; then verb_args="--conversation c1 --output $EXPORT_DIR"; else verb_args=""; fi
  # shellcheck disable=SC2086  # verb_args is a fixed word list
  run "$verb-port-seed" "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence "$verb" --env "$ENVS/port-seed.env" --customer-id cust_demo --admin-key-file "$KEYFILE" $verb_args
  port_refused "$verb-port-seed" "$verb: GATEWAY_PORT holding a *_SIGNING_KEY value -> exit 1, exporter never started, value nowhere" "$SEED_MATRIX"
  # shellcheck disable=SC2086
  run_traced "$verb-port-seed-traced" "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence "$verb" --env "$ENVS/port-seed.env" --customer-id cust_demo --admin-key-file "$KEYFILE" $verb_args
  check "$verb: the same under bash -x -> exit 1, the value in no trace, exporter never started" \
    bash -c '[ "$(cat "$1.rc")" = "1" ] && [ ! -s "$2" ] && ! grep -qiF -- "$3" "$1.err" "$1.out"' _ "$OUT/$verb-port-seed-traced" "$LOGS/$verb-port-seed-traced.log" "$SEED_MATRIX"
done
# Equality at any length: a port number that a signing line also holds.
{ cat "$GOOD_ENV"; printf 'LCR_ODD_SIGNING_KEY=18080\n'; } > "$ENVS/port-equal.env"
run list-port-equal "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence list --env "$ENVS/port-equal.env" --customer-id cust_demo --admin-key-file "$KEYFILE"
check "list: a GATEWAY_PORT equal to a *_SIGNING_KEY value never reaches the exporter's arguments" \
  bash -c '[ "$(cat "$1.rc")" = "1" ] && [ ! -s "$2" ] && grep -qF LCR_ODD_SIGNING_KEY "$1.err"' _ "$OUT/list-port-equal" "$LOGS/list-port-equal.log"
# bash -x on a good list call: the seeds of the file are in no trace, and
# tracing is back on after the read (this verb goes on after it).
run_traced list-traced "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence list --env "$GOOD_ENV" --customer-id cust_demo --admin-key-file "$KEYFILE"
check "bash -x evidence list: works, same hand-over" bash -c '[ "$(cat "$1")" = "0" ] && grep -qxF "http://127.0.0.1:18080" "$2"' _ "$OUT/list-traced.rc" "$LOGS/list-traced.log"
check "bash -x evidence list: tracing is suspended for the read and resumes after it" \
  bash -c 'grep -q "^+* set +x\$" "$1" && awk "/^\\+* set \\+x\$/{seen=1; next} seen && /^\\+* port=18080\$/{found=1} END{exit found?0:1}" "$1"' _ "$OUT/list-traced.err"
list_trace_shown=""
for value in "$SEED_WITNESS" "$SEED_BRIDGE" "$SEED_SANITIZER" "$SEED_SANDBOX_B" "$SEED_AUDIT" "$SEED_GATEWAY" "$ADMIN_KEY_VALUE"; do
  if grep -qiF -- "$value" "$OUT/list-traced.err" "$OUT/list-traced.out"; then list_trace_shown="$list_trace_shown x"; fi
done
check "bash -x evidence list: no signing seed and no admin key value in the trace" [ -z "$list_trace_shown" ]

echo "evidence list / export / evidence - help is answered only on its own"
for verb in list export; do
  run "$verb-help" -- evidence "$verb" --help
  check "evidence $verb --help on its own exits 0 and prints the usage" bash -c '[ "$(cat "$1.rc")" = "0" ] && grep -qF "Evidence bundles are NOT delivery bundles" "$1.out"' _ "$OUT/$verb-help"
  run "$verb-help-short" -- evidence "$verb" -h
  check "evidence $verb -h on its own exits 0" [ "$(rc_of "$verb-help-short")" = "0" ]
  # No exporter anywhere: before this rule the mixed call below ended in 0.
  run "$verb-help-mixed" -- evidence "$verb" --env "$GOOD_ENV" --customer-id cust_demo --admin-key-file "$KEYFILE" --help
  fails_with "$verb-help-mixed" "evidence $verb ... --help (exporter absent) -> exit 1, not 0" "only answered on its own"
  run "$verb-help-first" -- evidence "$verb" --help --customer-id cust_demo
  fails_with "$verb-help-first" "evidence $verb --help ... (help first) -> exit 1" "only answered on its own"
  run "$verb-help-short-mixed" -- evidence "$verb" --customer-id cust_demo -h
  fails_with "$verb-help-short-mixed" "evidence $verb ... -h -> exit 1" "only answered on its own"
  run "$verb-help-exporter" "LUCAIRN_BUNDLE_EXPORT=$STUB_EXPORTER" -- evidence "$verb" --env "$GOOD_ENV" --customer-id cust_demo --admin-key-file "$KEYFILE" --help
  fails_with "$verb-help-exporter" "evidence $verb ... --help with an exporter installed -> exit 1, exporter not run" "only answered on its own"
done
run evidence-help -- evidence --help
check "lucairn evidence --help on its own exits 0 and prints the usage" bash -c '[ "$(cat "$1.rc")" = "0" ] && grep -qF "Evidence bundles are NOT delivery bundles" "$1.out"' _ "$OUT/evidence-help"
run evidence-help-short -- evidence -h
check "lucairn evidence -h on its own exits 0" [ "$(rc_of evidence-help-short)" = "0" ]
run evidence-help-verify -- evidence --help verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
fails_with evidence-help-verify "lucairn evidence --help verify ... -> exit 1, tool not run (not 0)" "only answered on its own"
run evidence-help-list -- evidence -h list --customer-id cust_demo
fails_with evidence-help-list "lucairn evidence -h list ... -> exit 1" "only answered on its own"
run evidence-empty-verb -- evidence "" verify "$BUNDLE"
fails_with evidence-empty-verb "lucairn evidence '' verify ... -> exit 1" "only answered on its own"

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

echo "evidence verify - a Bash trace (bash -x) shows no key"
run_traced traced -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
check "bash -x: the run works and the tool gets the same argument list" bash -c '[ "$(cat "$1")" = "0" ] && cmp -s "$2" "$3"' _ "$OUT/traced.rc" "$TMP/expected-argv" "$LOGS/traced.log"
check "bash -x: positive control, the trace is there up to the key handling" bash -c 'grep -q "^+* evidence_verify " "$1" && grep -q "^+* set +x\$" "$1"' _ "$OUT/traced.err"
# The documented behaviour: tracing goes off before the file is read and
# STAYS off until the wrapper exits (the tool call carries the public keys).
check "bash -x: nothing is traced after tracing went off, up to the exit (the tool's own stderr still arrives)" \
  bash -c 'awk "/^\\+* set \\+x\$/{seen=1; next} seen && /^\\++ /{late++} END{exit (seen && !late)?0:1}" "$1" && grep -qx "stub stderr line" "$1"' _ "$OUT/traced.err"
run_traced traced-seed -- evidence verify "$BUNDLE" --env "$ENVS/seed-cross.env" --tool "$STUB_TOOL"
check "bash -x: the seed refusal is still exit 3" [ "$(rc_of traced-seed)" = "3" ]
run_traced traced-helper "PATH=$BIN/failing-base64:$BASE_PATH" -- evidence verify "$BUNDLE" --env "$GOOD_ENV" --tool "$STUB_TOOL"
check "bash -x: a failing helper is still exit 3" [ "$(rc_of traced-helper)" = "3" ]
traced_shown=""
for value in "$SEED_WITNESS" "$SEED_BRIDGE" "$SEED_SANITIZER" "$SEED_SANDBOX_B" "$SEED_AUDIT" "$SEED_GATEWAY" \
  "$PUB_WITNESS" "$PUB_BRIDGE" "$PUB_SANITIZER" "$PUB_SANDBOX_B" "$PUB_AUDIT" "$PUB_GATEWAY" \
  "$B64_WITNESS" "$B64_BRIDGE" "$B64_SANITIZER" "$B64_SANDBOX_B" "$B64_AUDIT" "$B64_GATEWAY" "$ADMIN_KEY_VALUE"; do
  for traced_run in traced traced-seed traced-helper; do
    if grep -qiF -- "$value" "$OUT/$traced_run.err" "$OUT/$traced_run.out"; then traced_shown="$traced_shown $traced_run"; fi
  done
done
check "bash -x: no key value from the env file in any trace (seeds, public hex, base64)" [ -z "$traced_shown" ]
# The escaped byte form the wrapper builds on the way to base64 (\x11\x11...).
check "bash -x: no key in escaped-byte form in any trace" bash -c '! grep -qF "x12\\x12\\x12" "$1" && ! grep -qF "xaa\\xaa" "$1"' _ "$OUT/traced.err"

echo "nothing private leaves the env file; no network"
# Everything the CLI printed and everything a stub was called with, across all
# runs above. The fixture env files are outside both directories.
leaks=""
for secret in "$SEED_WITNESS" "$SEED_BRIDGE" "$SEED_SANITIZER" "$SEED_SANDBOX_B" "$SEED_AUDIT" "$SEED_GATEWAY" \
  "$SEED_LEGACY" "$SEED_OTHER" "$SEED_QUOTED" "$SEED_RETIRED" "$SEED_UNLISTED" "$SEED_MATRIX" \
  "$B64_UNLISTED" "$NAME_KEYLIKE" "$SHORT_SIGNING_VALUE" "$ADMIN_KEY_VALUE"; do
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
  '--service-key dsa-sanitizer-streaming' 'keys/lucairn-cosign.pub' 'which ships with a later release' 'No verdict' \
  'a value from the `--env` file that the same file also holds on a' 'gives the wrapper nothing' \
  'visible in the process list' 'the tool rejected its arguments' 'witness_dev_v1' \
  'wrapper does not take `--witness-key` yet' 'not given the gateway public key' 'only when it is the sole' \
  'comes through one function' '64 or more hex digits in a row' 'tracing stays off until' \
  'does not do for any outcome' '`126` and `127` are the shell' 'not as proof that no program ran' \
  'does not read as' '(exit `1`), for these two'; do
  check "OPS.md evidence section states: $phrase" grep -qF -- "$phrase" "$TMP/ops-section.md"
done
check "OPS.md evidence section makes no assurance claim it cannot back" bash -c '! grep -Eiq "SOC ?2|ISO ?27001|ISO ?42001|HIPAA|PCI|end-to-end|E2E|encrypted at rest|penetration|red team|regular audits|court|legally binding|tamper-proof" "$1"' _ "$TMP/ops-section.md"
# The sentence this PR first shipped claimed more than the code does.
check "OPS.md no longer claims that no signing key can reach a command line" bash -c '! grep -qF "value is put on a command line" "$1" && ! grep -qF "Only public keys are used" "$1"' _ "$TMP/ops-section.md"
check "the usage text states the same limit as OPS.md" grep -qF 'A file with public lines only gives nothing' "$OUT/evidence-bare.out"
# Exit 3 is "no verdict", not "the tool never ran": a program behind --tool
# that exits 3 itself is passed through. No text may say more than that.
check "no text says that 3 means the tool was not run" \
  bash -c '! grep -qF "stopped before the tool ran" "$1" "$2" "$3" "$4" && ! grep -qF "means the tool was not run" "$1" "$2" "$3" "$4"' \
  _ "$TMP/ops-section.md" "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$OUT/evidence-bare.out"
check "the usage text: the tool never returns 3, and 126/127 come back as 3" \
  bash -c 'grep -qF "never returns 3" "$1" && grep -qF "126 and 127" "$1"' _ "$OUT/evidence-bare.out"
check "the usage text: tracing stays off until the wrapper exits" grep -qF 'stays off until the wrapper exits' "$OUT/evidence-bare.out"
check "the usage text: help only on its own for list and export too" grep -qF 'it is a usage error (exit 1)' "$OUT/evidence-bare.out"
check "README: 3 means there is no verdict" grep -qF 'means there is no' "$ROOT/README.md"
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
