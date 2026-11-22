#!/usr/bin/env bash
# test_name_model_threads.sh — kit 2.0.1 (T-1479, PRD
# prd-2026-11-21-kit-customer-install-fix.md slice 4, settings only): the name
# model in the sanitizer core's sidecar may use the host's CPU threads.
#
#   1. Compose: LUCAIRN_NAME_MODEL_THREADS reaches the sidecar as
#      OMP_NUM_THREADS, MKL_NUM_THREADS and TORCH_NUM_THREADS; unset or empty
#      = 2, the sidecar image's own value (an existing install keeps what it
#      had); no other service gets the three variables
#   2. bin/lucairn-init writes 8 only on a host with 8 or more threads (nproc
#      stubbed: 2, 4, 6, 8, 32 -> empty, empty, empty, 8, 8) and an empty line
#      when no count can be read
#   3. doctor's check_name_model_threads warns (never fails) below 8 host
#      threads, above the host's count and on a non-number; ok on 8 of 8
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
N=0
pass() { N=$((N + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# ── 1. rendered Compose project ─────────────────────────────────────────────
FIX="$ROOT/tests/fixtures/servicenow-control/off/synthetic.env.fixture"
render() {  # extra env file -> rendered project as JSON
  env -i PATH="$PATH" HOME="$HOME" docker compose --env-file "$FIX" --env-file "$1" \
    --project-directory "$ROOT" --project-name nmt -f "$ROOT/docker-compose.customer.yml" \
    config --format json 2>"$TMP/compose.err"
}
threads_of() {  # rendered JSON file, service -> "OMP MKL TORCH" ("- - -" = absent)
  python3 -c '
import json, sys
env = json.load(open(sys.argv[1]))["services"][sys.argv[2]].get("environment") or {}
print(" ".join(str(env.get(k, "-")) for k in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "TORCH_NUM_THREADS")))
' "$1" "$2"
}
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  for case in "set:LUCAIRN_NAME_MODEL_THREADS=8:8 8 8" "empty:LUCAIRN_NAME_MODEL_THREADS=:2 2 2" "absent::2 2 2"; do
    name="${case%%:*}"; rest="${case#*:}"; line="${rest%%:*}"; want="${rest#*:}"
    printf '%s\n' "$line" > "$TMP/$name.env"
    render "$TMP/$name.env" > "$TMP/$name.json" || { cat "$TMP/compose.err" >&2; fail "compose config ($name)"; }
    got="$(threads_of "$TMP/$name.json" sanitizer-core-sidecar)"
    [ "$got" = "$want" ] || fail "sidecar threads ($name): got '$got', want '$want'"
  done
  others="$(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))["services"]
print(" ".join(n for n, v in s.items() if n != "sanitizer-core-sidecar"
               and any(k in (v.get("environment") or {}) for k in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "TORCH_NUM_THREADS"))))
' "$TMP/set.json")"
  [ -z "$others" ] || fail "thread variables reach other services: $others"
  pass "compose: LUCAIRN_NAME_MODEL_THREADS=8 -> OMP/MKL/TORCH_NUM_THREADS=8 on the sidecar only; empty or absent -> 2 (the image's value)"
else
  echo "skip compose render: docker compose not available (NOT RUN)"
fi

# ── 2. bin/lucairn-init writes 8 only on a host with 8 or more threads ──────
printf '{"license_key":"synthetic.payload","signing_key":"synthetic-signing-key"}\n' > "$TMP/license.json"
SB="$TMP/stubs"; mkdir -p "$SB"
init_threads() {  # nproc answer ('' = nproc, getconf and sysctl all fail) -> written value
  rm -f "$SB"/*
  if [ -n "$1" ]; then
    printf '#!/bin/sh\necho %s\n' "$1" > "$SB/nproc"
  else
    for t in nproc getconf sysctl; do printf '#!/bin/sh\nexit 1\n' > "$SB/$t"; done
  fi
  chmod +x "$SB"/*
  PATH="$SB:$PATH" "$ROOT/bin/lucairn-init" --confirm-no-registry-volume --dev --runtime-mode managed-byok \
    --output "$TMP/customer.env" --dry-run 2>"$TMP/init.err" > "$TMP/init.env" \
    || { tail -3 "$TMP/init.err" >&2; fail "init dry run (nproc=$1)"; }
  [ "$(grep -c '^LUCAIRN_NAME_MODEL_THREADS=' "$TMP/init.env")" = 1 ] || fail "init writes LUCAIRN_NAME_MODEL_THREADS exactly once (nproc=$1)"
  grep -E '^LUCAIRN_NAME_MODEL_THREADS=' "$TMP/init.env" | cut -d= -f2-
}
for case in 2: 4: 6: 8:8 32:8; do
  got="$(init_threads "${case%%:*}")" || exit 1
  [ "$got" = "${case#*:}" ] || fail "init with ${case%%:*} host threads wrote '$got', want '${case#*:}'"
done
pass "init: host threads 2/4/6 -> empty (the image's 2); 8/32 -> LUCAIRN_NAME_MODEL_THREADS=8"
got="$(init_threads "")" || exit 1
[ -z "$got" ] || fail "init with no readable count wrote '$got', want empty"
pass "init: no readable thread count -> empty line (the image's 2)"
grep -q '^LUCAIRN_NAME_MODEL_THREADS=$' "$ROOT/customer.env.example" || fail "customer.env.example lacks LUCAIRN_NAME_MODEL_THREADS="
pass "customer.env.example carries LUCAIRN_NAME_MODEL_THREADS= (empty = 2)"

# ── 3. doctor: warn, never fail ─────────────────────────────────────────────
FN="$TMP/fn.sh"
{ sed -n '/^warn() {/,/^}/p; /^have() {/,/^}/p; /^env_value() {/,/^}/p' "$ROOT/bin/lucairn"
  sed -n '/^check_name_model_threads() {/,/^}/p' "$ROOT/bin/lucairn"; } > "$FN"
grep -q '^check_name_model_threads() {' "$FN" || fail "check_name_model_threads not found in bin/lucairn"
doctor_case() {  # setting, host threads, offline -> stdout+stderr, rc must be 0
  rm -f "$SB"/*
  printf '#!/bin/sh\necho %s\n' "$2" > "$SB/getconf"
  printf '#!/bin/sh\necho %s\n' "$2" > "$SB/docker"
  chmod +x "$SB"/*
  printf 'LUCAIRN_NAME_MODEL_THREADS=%s\n' "$1" > "$TMP/d.env"
  PATH="$SB:$PATH" bash -c '. "$1"; check_name_model_threads "$2" "$3"' _ "$FN" "$TMP/d.env" "$3" 2>&1 \
    || fail "doctor check returned non-zero (setting=$1 host=$2)"
}
out="$(doctor_case 8 8 0)"; case "$out" in "name model threads: ok (8 of 8 CPU threads, docker-engine)") ;; *) fail "8 of 8 online: $out" ;; esac
out="$(doctor_case 8 8 1)"; case "$out" in *"ok (8 of 8 CPU threads, host)"*) ;; *) fail "8 of 8 offline: $out" ;; esac
out="$(doctor_case 4 4 0)"; case "$out" in "warn: "*"below the documented minimum of 8"*) ;; *) fail "4-thread host: $out" ;; esac
out="$(doctor_case 8 4 0)"; case "$out" in "warn: "*"above this host's 4 CPU threads"*) ;; *) fail "setting above host: $out" ;; esac
out="$(doctor_case "" 4 0)"; case "$out" in "warn: "*"below the documented minimum of 8"*) ;; *) fail "unset on 4: $out" ;; esac
out="$(doctor_case abc 8 0)"; case "$out" in "warn: "*"not a positive whole number"*) ;; *) fail "non-number: $out" ;; esac
pass "doctor: ok on 8 of 8; warns (exit 0) below 8 host threads, above the host's count, on a non-number"

echo "name-model threads: $N checks ok"
