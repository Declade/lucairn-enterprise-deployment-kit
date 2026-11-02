#!/usr/bin/env bash
#
# Kit 2.0 Slice K-C (kit side) — the ServiceNow mode, OFF by default, opted in
# per API key by the customer admin (PRD Opus Advisor
# specs/2026-11/prd-2026-11-02-kit-2-0-new-core.md K4 + Locked rows 6/7,
# design-2026-11-02-kit-servicenow-opt-in.md, Fable ruling M1/M2/M3a; T-1441).
# The Helm half is in tests/test_servicenow_control_helm.py and
# tests/test_sanitizer_core_helm.sh.
#
# WHAT THIS PROVES (client-side `docker compose config` only — no daemon, no
# container, no cluster, no gateway; synthetic ids, keys and paths only)
#   A. The overlay alone: rendered with the base files it FAILS without the
#      switch, with empty bindings (`X=""` and `export X=`), and without the
#      instances/login/core address; it renders with the full set, and then
#      carries both operator values exactly as Compose read them (M1: no
#      hard-coded "true").
#   B. The opt-in decision (bin/lucairn status) on a PARSER-PARITY TABLE: for
#      every env-file form (export, quotes, CRLF, duplicates, inline comment,
#      commented-out, off-enum switch) the CLI's decision equals the decision
#      computed from what Compose itself reads, and the selected overlay hands
#      the gateway those same values. The table is checked to contain rows a
#      grep reader gets wrong.
#   C. `bin/lucairn up`: bindings without the switch -> refused with
#      session_config_invalid and nothing started; a bad binding list and a
#      bad control network are refused; opted in -> the overlay is selected and
#      the Python sanitizer's config copy is (re)built from the CURRENT base on
#      EVERY up (M3a); a loose login file is refused; a bound key id the
#      running gateway does not know is refused (counts only); an unreachable
#      admin API is a warning, not a stop.
#   D. A v1.9.7 customer.env (the released example) upgrades with the overlay
#      OFF: no probe run, the exact pre-K-C Compose arguments, core profile kit
#      (no LCR_PROFILE on the core), base files byte-identical to the pinned
#      OFF golden sources.
#   E. `bin/lucairn doctor --offline` RED-PROOF: green when opted in after
#      `up`; red on a base edited after the last up, a hand-edited copy, a
#      missing copy, bindings without the switch, LCR_PROFILE=kit-servicenow in
#      customer.env, a login file with mode 0644, and an overlay that mounts
#      control material into the model sidecar (mount-scope scan).
#   F. The mount/setting scope scan red-proof on mutated renders: login file in
#      the sanitizer, gateway leaf in the core, sanitizer leaf in the sidecar,
#      the CA operator folder anywhere, a sidecar alias, core dumps on, no
#      GOTRACEBACK, a non-kit profile while off, control material while off.
#   G. `bin/lucairn doctor` online against a stub engine + a stub admin API:
#      green; red on TWO running gateway containers, a typo'd key id, an
#      instance not unlocked, a control certificate under 14 days.
#   H. The value kit-servicenow is set only by the overlay (and the Helm
#      enabled branch): never in the base compose, customer.env.example or the
#      chart defaults.
#   I. A kit bundle of an opted-in install carries the overlay, the helper and
#      the bootstrap; bundle verify refuses one whose helper was removed.
#
# NON-COVERAGE (stated, not implied)
#   * No container runs: whether the gateway, the Python worker and the core
#     really complete a ticket redeem with these settings is criterion 7a
#     (kit compose stack + stub instance on the PC), not this suite.
#   * The admin API answers come from tests/lib/servicenow_admin_stub.py; the
#     gateway's real admin routes are DSA's (admin.go, servicenow_status.go).
#   * Ownership 10001:10001 of the login folder/file is asserted only on
#     Linux; this suite runs the macOS branch where the doctor states it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.customer.yml"
SELFHOSTED="$ROOT/docker-compose.self-hosted.yml"
OVERLAY="$ROOT/docker-compose.servicenow-control.yml"
HELPER="$ROOT/bin/lucairn-servicenow.py"

# The real path: the control bootstrap refuses symlinked parents (/var -> /private/var on macOS).
TMP="$(cd "$(mktemp -d)" && pwd -P)"
STUB_PID=""
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; if [ -n "${KEEP_TMP:-}" ]; then echo "kept: $TMP" >&2; else rm -rf "$TMP"; fi; }
trap cleanup EXIT
BASE_PATH="$PATH"

FAILS=0
N=0
pass() { N=$((N + 1)); echo "  ok   — $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "  FAIL — $1"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }

REAL_DOCKER="$(command -v docker 2>/dev/null || true)"
if [ -z "$REAL_DOCKER" ] || ! "$REAL_DOCKER" compose version >/dev/null 2>&1; then
  echo "ServiceNow opt-in tests: NOT RUN (docker compose CLI not installed; no daemon is needed)"
  exit 0
fi
python3 -c 'import yaml, cryptography' 2>/dev/null \
  || { echo "ServiceNow opt-in tests: FAIL — python3 with PyYAML and cryptography is required"; exit 1; }

# ── Tool shims ──────────────────────────────────────────────────────────────
# `docker compose ... config ...` goes to the REAL client (a render needs no
# daemon). Every other compose call is recorded, never executed; the engine
# questions of the online doctor are answered from STUB_* values.
SBIN="$TMP/bin"; mkdir -p "$SBIN"
cat > "$SBIN/docker" <<STUB
#!/bin/bash
a=" \$* "
if [ "\${1:-}" = compose ]; then
  for x in "\$@"; do [ "\$x" = config ] && { printf '%s\n' "\$*" >> "\${STUB_CONFIG_LOG:-/dev/null}"; exec "$REAL_DOCKER" "\$@"; }; done
  case "\$a" in
    *" version "*) exit 0 ;;
    *" ps -a "*) [ -n "\${STUB_PS:-}" ] && cat "\$STUB_PS"; exit 0 ;;
    *" exec -T postgres-sanitizer-core "*) echo "\${STUB_LEDGER_OUT:-7}"; exit 0 ;;
    *" logs --no-color sanitizer-core "*) [ -n "\${STUB_CORE_LOG:-}" ] && cat "\$STUB_CORE_LOG"; exit 0 ;;
    *" logs --no-color veil-witness "*) [ -n "\${STUB_WITNESS_LOG:-}" ] && cat "\$STUB_WITNESS_LOG"; exit 0 ;;
  esac
  printf '%s\n' "\$*" >> "\${STUB_LOG:-/dev/null}"
  exit 0
fi
case "\$a" in
  " info "*) [ -n "\${STUB_MEM_BYTES:-}" ] && { echo "\$STUB_MEM_BYTES"; exit 0; }; exit 1 ;;
  " inspect "*) [ -n "\${STUB_NETMODE:-}" ] && { echo "\$STUB_NETMODE"; exit 0; }; exit 1 ;;
esac
exit 1
STUB
printf '#!/bin/sh\nprintf 000\n' > "$SBIN/curl"
for t in kubectl helm pg_isready docker-compose; do printf '#!/bin/sh\nexit 1\n' > "$SBIN/$t"; done
chmod 0755 "$SBIN"/*
export PATH="$SBIN:$BASE_PATH"

# ── A generated install (lucairn-init) + the synthetic opt-in material ──────
INST="$TMP/install"; mkdir -p "$INST"
ENVF="$INST/customer.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name fixture-local-model --model-file fixture.gguf --model-path . --output "$ENVF" --skip-doctor > "$TMP/init.out" 2>&1 \
  || { echo "ServiceNow opt-in tests: FAIL — lucairn-init: $(tail -3 "$TMP/init.out")"; exit 1; }
BASED="$TMP/base"; mkdir -p "$BASED"; cp -R "$INST/." "$BASED/"   # the generated install, mode OFF
sed -i.bak "s#^SANITIZER_CORE_MTLS_HOST_DIR=.*#SANITIZER_CORE_MTLS_HOST_DIR=$BASED/.certs/sanitizer-core-mtls#" "$BASED/customer.env" && rm -f "$BASED/customer.env.bak"
BASEENV="$BASED/customer.env"
SNC="$TMP/sn"; mkdir -p "$SNC/copy"
python3 "$ROOT/scripts/bootstrap-servicenow-control.py" "$SNC/certs" --workload-uid "$(id -u)" --workload-gid "$(id -g)" >/dev/null 2>&1 \
  || { echo "ServiceNow opt-in tests: FAIL — synthetic control bootstrap"; exit 1; }
mkdir -m 0700 "$SNC/login"
printf '{}\n' > "$SNC/login/login.json"; chmod 0400 "$SNC/login/login.json"
cp "$ROOT/config/default-sanitizer.yaml" "$SNC/base-sanitizer.yaml"
# The stub admin API accepts exactly the install's own (generated, synthetic) admin key.
grep '^DSA_ADMIN_KEY=' "$ENVF" | tail -1 | cut -d= -f2- > "$TMP/admin.key"
ADMIN_KEY="$(cat "$TMP/admin.key")"

# The admin API stub: two customers; key_a is bound, key_b exists, key_t does not.
STATE="$TMP/admin-state.json"
write_state() { # <keys json> <status json>
  printf '{"keys": %s, "status": %s}\n' "$1" "$2" > "$STATE"
}
STATUS_OK='{"mode":"on","instances":[{"index":1,"state":"unlocked","reason":null}],"control_cert_expires_in_days":300}'
write_state '{"cust_a":["key_a","key_b"]}' "$STATUS_OK"
python3 "$ROOT/tests/lib/servicenow_admin_stub.py" --port-file "$TMP/port" --state "$STATE" --admin-key-file "$TMP/admin.key" &
STUB_PID=$!
disown "$STUB_PID" 2>/dev/null || true   # no job-status line when cleanup stops it
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"

SN_LINES() { # the full opt-in set except the switch and the bindings
  cat <<EOF
GATEWAY_SERVICENOW_INSTANCES=[{"id":"inst1","base_url":"https://inst1.servicenow.invalid","customer_id":"cust_a"}]
SERVICENOW_CONTROL_SUBNET=172.30.251.0/29
SERVICENOW_CONTROL_GATEWAY_IP=172.30.251.2
SERVICENOW_CONTROL_SANITIZER_IP=172.30.251.3
SERVICENOW_CONTROL_CORE_IP=172.30.251.4
SERVICENOW_CONTROL_MATERIAL=$SNC/certs/material
SERVICENOW_CONTROL_SANITIZER_CONFIG=$SNC/copy/sanitizer.yaml
SANITIZER_CONFIG_FILE=$SNC/base-sanitizer.yaml
SERVICENOW_LOGIN_DIR=$SNC/login
GATEWAY_PORT=$PORT
EOF
}
ON_LINES='GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true
GATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1'
{ SN_LINES; printf '%s\n' "$ON_LINES"; } >> "$ENVF"

variant() { # <name> — a copy of the opted-in install dir (env + profile + certs)
  local d="$TMP/v-$1"
  rm -rf "$d"; mkdir -p "$d"; cp -R "$INST/." "$d/"
  sed -i.bak "s#^SANITIZER_CORE_MTLS_HOST_DIR=.*#SANITIZER_CORE_MTLS_HOST_DIR=$d/.certs/sanitizer-core-mtls#" "$d/customer.env" && rm -f "$d/customer.env.bak"
  printf '%s' "$d"
}
strip_sn() { # <env> — remove the switch and bindings lines (every form)
  grep -v -E '^[[:space:]]*(export[[:space:]]+)?#?[[:space:]]*GATEWAY_SERVICENOW_(INSTANCE_PATH_ENABLED|KEY_BINDINGS)' "$1" > "$1.tmp"; mv "$1.tmp" "$1"
}
cli() { # <verb> <env> [env assignments...] — stderr+stdout in $TMP/cli.out, compose calls in $TMP/stub.log
  local verb="$1" env_file="$2"; shift 2
  : > "$TMP/stub.log"; : > "$TMP/config.log"
  env STUB_LOG="$TMP/stub.log" STUB_CONFIG_LOG="$TMP/config.log" "$@" bash "$ROOT/bin/lucairn" "$verb" --env "$env_file" --compose "$COMPOSE" > "$TMP/cli.out" 2>&1
}
overlay_selected() { grep -Fq -- "-f $OVERLAY" "$TMP/stub.log"; }
render() { # <env> [files...] — base + self-hosted (+ more) render, JSON, real client
  local env_file="$1"; shift
  env -i PATH="$BASE_PATH" HOME="$HOME" "$REAL_DOCKER" compose --env-file "$env_file" -f "$COMPOSE" -f "$SELFHOSTED" "$@" config --format json 2>"$TMP/render.err"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "A. The overlay alone (M1: switch AND bindings, both forwarded with :?)"
ov_case() { # <name> <want ok|fail> <lines to append>
  local f="$TMP/ov-$1.env"
  cp "$BASEENV" "$f"; { SN_LINES; printf '%s\n' "$3"; } >> "$f"
  if render "$f" -f "$OVERLAY" > "$TMP/ov.json"; then got=ok; else got=fail; fi
  check_eq "overlay render: $1" "$2" "$got"
}
ov_case "no switch" fail 'GATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1'
ov_case "no bindings" fail 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true'
ov_case 'empty bindings X=""' fail 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true
GATEWAY_SERVICENOW_KEY_BINDINGS=""'
ov_case "empty bindings export X=" fail 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true
export GATEWAY_SERVICENOW_KEY_BINDINGS='
ov_case "full set" ok "$ON_LINES"
python3 - "$TMP/ov.json" > "$TMP/ov-check.txt" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["services"]
g = s["gateway"]["environment"]
def p(ok, msg): print(("ok " if ok else "FAIL ") + msg)
p(g["GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED"] == "true" and g["GATEWAY_SERVICENOW_KEY_BINDINGS"] == "key_a=inst1", "the gateway gets the switch and the bindings exactly as customer.env set them")
p(s["sanitizer-core"]["environment"]["LCR_PROFILE"] == "kit-servicenow", "the core runs LCR_PROFILE=kit-servicenow (set by the overlay)")
PY
while IFS= read -r line; do case "$line" in "ok "*) pass "${line#ok }" ;; *) fail "${line#FAIL }" ;; esac; done < "$TMP/ov-check.txt"
grep -q 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED: "true"' "$OVERLAY" && fail "the overlay still hard-codes the switch" || pass "the overlay hard-codes no switch value"
for need in GATEWAY_SERVICENOW_INSTANCES SERVICENOW_LOGIN_DIR SERVICENOW_CONTROL_CORE_IP; do
  f="$TMP/ov-no-$need.env"; cp "$BASEENV" "$f"; { SN_LINES | grep -v "^$need="; printf '%s\n' "$ON_LINES"; } >> "$f"
  if render "$f" -f "$OVERLAY" >/dev/null; then fail "overlay without $need renders"; else pass "overlay without $need is refused by Compose"; fi
done

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "B. Opt-in decision = Compose's own reading (parser-parity table)"
MINI="$TMP/mini.yml"
printf 'services:\n  m:\n    image: m\n    environment:\n      S: "${GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED:-}"\n      B: "${GATEWAY_SERVICENOW_KEY_BINDINGS:-}"\n' > "$MINI"
compose_view() { # <env> -> "S|B" as Compose reads them (independent of bin/lucairn)
  env -i PATH="$BASE_PATH" HOME="$HOME" "$REAL_DOCKER" compose --env-file "$1" -f "$MINI" config --format json 2>/dev/null \
    | python3 -c 'import json,sys; e=json.load(sys.stdin)["services"]["m"]["environment"]; print(e.get("S","") + "|" + e.get("B",""))'
}
grep_view() { # what a `grep ^KEY= | tail -1` reader would see
  local s b
  s="$(grep -E '^GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=' "$1" | tail -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
  b="$(grep -E '^GATEWAY_SERVICENOW_KEY_BINDINGS=' "$1" | tail -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
  printf '%s|%s' "$s" "$b"
}
reference() { # <S|B> -> off|on|invalid (the kit's rule: empty bindings = off, design § 3b)
  local s="${1%%|*}" b="${1#*|}"
  [ -z "$b" ] && { echo off; return; }
  if [ "$s" = true ]; then echo on; else echo invalid; fi
}
GREP_DIFFERS=0
parity() { # <name> <expected> <printf-format lines>
  local name="$1" want="$2" d cview decision gview
  d="$(variant "parity-$(printf '%s' "$name" | tr -c 'a-z0-9' '-')")"
  strip_sn "$d/customer.env"
  printf "$3" >> "$d/customer.env"
  cview="$(compose_view "$d/customer.env")"
  gview="$(grep_view "$d/customer.env")"
  cli status "$d/customer.env"
  if overlay_selected; then decision=on
  elif grep -q 'session_config_invalid' "$TMP/cli.out"; then decision=invalid
  else decision=off; fi
  if [ "$decision" = "$want" ] && [ "$(reference "$cview")" = "$want" ]; then
    pass "parity: $name -> $decision (Compose reads S/B as '$(printf '%s' "$cview" | tr '\r' '~')')"
  else
    fail "parity: $name -> cli $decision, Compose-reference $(reference "$cview"), want $want"
  fi
  [ "$(reference "$gview")" != "$want" ] && GREP_DIFFERS=$((GREP_DIFFERS + 1))
  if [ "$decision" = on ]; then
    render "$d/customer.env" -f "$OVERLAY" | python3 -c 'import json,sys; e=json.load(sys.stdin)["services"]["gateway"]["environment"]; print(e["GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED"] + "|" + e["GATEWAY_SERVICENOW_KEY_BINDINGS"])' > "$TMP/gw.view" 2>/dev/null
    check_eq "parity: $name — the selected overlay hands the gateway what was decided on" "$cview" "$(cat "$TMP/gw.view")"
  fi
}
parity "plain" on 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\nGATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n'
parity 'X="" bindings' off 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\nGATEWAY_SERVICENOW_KEY_BINDINGS=""\n'
parity "export X= bindings" off 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\nexport GATEWAY_SERVICENOW_KEY_BINDINGS=\n'
parity "export prefix on both" on 'export GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\nexport GATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n'
parity "CRLF line ends" on 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\r\nGATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\r\n'
parity "duplicate: set then emptied" off 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\nGATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\nGATEWAY_SERVICENOW_KEY_BINDINGS=\n'
parity "duplicate: emptied then set" on 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\nGATEWAY_SERVICENOW_KEY_BINDINGS=\nGATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n'
parity "duplicate switch: true then false" invalid 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\nGATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=false\nGATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n'
parity "inline comment after the switch" on 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true # opted in\nGATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n'
parity "single-quoted bindings" on "GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\nGATEWAY_SERVICENOW_KEY_BINDINGS='key_a=inst1'\n"
parity "bindings commented out" off 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\n# GATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n'
parity "bindings without the switch" invalid 'GATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n'
parity "bindings with switch=false" invalid 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=false\nGATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n'
parity "off-enum switch True" invalid 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=True\nGATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n'
parity "switch alone" off 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\n'
if [ "$GREP_DIFFERS" -ge 3 ]; then pass "the table holds $GREP_DIFFERS rows a grep reader decides wrongly (export / CRLF / inline comment ...)"; else fail "the table holds only $GREP_DIFFERS rows where a grep reader differs"; fi
d="$(variant shellenv)"; strip_sn "$d/customer.env"
cli status "$d/customer.env" GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true GATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1
overlay_selected && pass "the shell environment counts exactly as it does for Compose (opt-in from the environment selects the overlay)" || fail "opt-in from the environment"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "C. bin/lucairn up"
d="$(variant up-noswitch)"; strip_sn "$d/customer.env"; printf 'GATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n' >> "$d/customer.env"
if cli up "$d/customer.env"; then fail "up with bindings but no switch exited 0"
elif grep -q 'session_config_invalid' "$TMP/cli.out" && ! grep -q ' up -d' "$TMP/stub.log"; then pass "bindings without the switch: up refuses with session_config_invalid and starts nothing"
else fail "bindings without the switch: $(tail -2 "$TMP/cli.out")"; fi
grep -q 'key_a' "$TMP/cli.out" && fail "the refusal printed a key id" || pass "the refusal names no key id"
up_refused() { # <name> <dir> <fixed text>
  if cli up "$2/customer.env"; then fail "$1: up exited 0"
  elif grep -Fq "$3" "$TMP/cli.out" && ! grep -q ' up -d' "$TMP/stub.log"; then pass "$1: up refuses ($3)"
  else fail "$1: $(tail -2 "$TMP/cli.out" | tr '\n' ' ')"; fi
}
d="$(variant up-badbind)"; strip_sn "$d/customer.env"; printf 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\nGATEWAY_SERVICENOW_KEY_BINDINGS=key_a = inst1\n' >> "$d/customer.env"
up_refused "binding list with spaces" "$d" "session_config_invalid"
d="$(variant up-unbound)"; strip_sn "$d/customer.env"; printf 'GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\nGATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst9\n' >> "$d/customer.env"
up_refused "bound instance not configured" "$d" "session_config_invalid"
d="$(variant up-net)"; sed -i.bak 's/^SERVICENOW_CONTROL_CORE_IP=.*/SERVICENOW_CONTROL_CORE_IP=172.30.251.3/' "$d/customer.env"; rm -f "$d/customer.env.bak"
up_refused "core address equal to the sanitizer's" "$d" "control_network"
rm -f "$SNC/copy/sanitizer.yaml"
if cli up "$ENVF" && overlay_selected && grep -q ' up -d' "$TMP/stub.log"; then pass "opted in: up selects the overlay and starts"; else fail "opted in: up: $(tail -3 "$TMP/cli.out" | tr '\n' ' ')"; fi
grep -q 'bound keys exist (bound=1 missing=0 owners=1)' "$TMP/cli.out" && pass "up checked the bound key against the running gateway (counts only)" || fail "up keyed check line: $(grep -i 'bound key' "$TMP/cli.out")"
grep -q 'key_a\|cust_a\|inst1' "$TMP/cli.out" && fail "up printed an id" || pass "up printed no key, customer or instance id"
copy_matches() { python3 - "$HELPER" "$SNC/base-sanitizer.yaml" "$SNC/copy/sanitizer.yaml" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("h", sys.argv[1]); h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
want = h.build_config(open(sys.argv[2]).read(), "172.30.251.3", "base-sanitizer.yaml")
sys.exit(0 if open(sys.argv[3], "rb").read() == want else 1)
PY
}
copy_matches && pass "M3a: up built the config copy from the base" || fail "M3a: copy after the first up"
python3 -c 'import sys,yaml; b=yaml.safe_load(open(sys.argv[1]))["sanitizer"]["servicenow_instance_path"]; sys.exit(0 if b["enabled"] is True and b["control_wiring_released"] is True and b["control_bind_address"]=="172.30.251.3" else 1)' "$SNC/copy/sanitizer.yaml" \
  && pass "the copy switches the Python control worker on (enabled + control_wiring_released, its own address)" || fail "copy mode block"
cmp -s "$ROOT/config/default-sanitizer.yaml" "$SNC/base-sanitizer.yaml" && pass "the base config was not rewritten" || fail "the base config changed"
printf '# operator edit after the opt-in\n' >> "$SNC/base-sanitizer.yaml"
python3 - "$SNC/base-sanitizer.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["sanitizer"].setdefault("servicenow_instance_path", {})["assertion_posture"] = "block"
open(p, "w").write(yaml.safe_dump(d, sort_keys=False))
PY
if cli up "$ENVF" && copy_matches; then pass "M3a: the NEXT up rebuilt the copy from the edited base"; else fail "M3a: rebuild on the next up"; fi
python3 -c 'import sys,yaml; sys.exit(0 if yaml.safe_load(open(sys.argv[1]))["sanitizer"]["servicenow_instance_path"]["assertion_posture"]=="block" else 1)' "$SNC/copy/sanitizer.yaml" \
  && pass "an operator mode setting in the base reaches the copy" || fail "operator setting kept"
chmod 0600 "$SNC/login/login.json"
cli up "$ENVF"; if grep -q 'login.json must have mode 0400' "$TMP/cli.out" && ! grep -q ' up -d' "$TMP/stub.log"; then pass "a login file with mode 0600 is refused (0400 required)"; else fail "loose login file: $(tail -1 "$TMP/cli.out")"; fi
chmod 0400 "$SNC/login/login.json"
chmod 0750 "$SNC/login"
cli up "$ENVF"; if grep -q 'SERVICENOW_LOGIN_DIR must have mode 0700' "$TMP/cli.out"; then pass "a login folder with mode 0750 is refused (0700 required)"; else fail "loose login folder"; fi
chmod 0700 "$SNC/login"
write_state '{"cust_a":["key_b"]}' "$STATUS_OK"
cli up "$ENVF"; if grep -q 'a bound key id does not exist' "$TMP/cli.out" && grep -q 'missing=1' "$TMP/cli.out" && ! grep -q ' up -d' "$TMP/stub.log"; then pass "a typo'd / unknown bound key id is refused before anything starts (counts only)"; else fail "unknown key id: $(tail -1 "$TMP/cli.out")"; fi
write_state '{}' "$STATUS_OK"
cli up "$ENVF"; if grep -q 'missing=1 owners=1' "$TMP/cli.out" && ! grep -q ' up -d' "$TMP/stub.log"; then pass "an owner the gateway does not know counts as missing keys"; else fail "unknown owner"; fi
write_state '{"cust_a":["key_a","key_b"]}' "$STATUS_OK"
d="$(variant up-unreach)"; sed -i.bak 's/^GATEWAY_PORT=.*/GATEWAY_PORT=1/' "$d/customer.env"; rm -f "$d/customer.env.bak"
if cli up "$d/customer.env" && grep -q 'bound key ids NOT checked' "$TMP/cli.out" && grep -q ' up -d' "$TMP/stub.log"; then pass "an unreachable admin API (gateway not running yet) is a warning, not a stop"; else fail "unreachable admin API: $(tail -2 "$TMP/cli.out" | tr '\n' ' ')"; fi

NOPY="$TMP/nopy-bin"; mkdir -p "$NOPY"; cp "$SBIN/docker" "$NOPY/docker"
for tool in bash sed grep awk cat dirname basename mktemp rm cut tr head tail sort uniq paste env printf find stat id uname wc \
            shasum sha256sum perl openssl date ls chmod mv cp ln touch od xargs git; do
  p="$(command -v "$tool" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$NOPY/$tool"
done
: > "$TMP/stub.log"
if env -i HOME="$HOME" PATH="$NOPY" STUB_LOG="$TMP/stub.log" "$NOPY/bash" "$ROOT/bin/lucairn" up --env "$ENVF" --compose "$COMPOSE" > "$TMP/cli.out" 2>&1; then
  fail "up without python3 on an opted-in install exited 0"
elif grep -q 'could not be evaluated' "$TMP/cli.out" && ! grep -q ' up -d' "$TMP/stub.log"; then
  pass "an opt-in that cannot be evaluated (no python3) stops up — never a silent start without the overlay"
else
  fail "up without python3: $(tail -2 "$TMP/cli.out" | tr '\n' ' ')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "D. A v1.9.7 customer.env upgrades with the mode OFF"
GIT_ROOT="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$GIT_ROOT" ] && git -C "$ROOT" cat-file -e v1.9.7:customer.env.example 2>/dev/null; then
  git -C "$ROOT" show v1.9.7:customer.env.example > "$TMP/v197.example"
  ! grep -q 'GATEWAY_SERVICENOW_' "$TMP/v197.example" && pass "v1.9.7 customer.env.example names no ServiceNow setting" || fail "v1.9.7 example names ServiceNow settings"
else
  echo "  NOT RUN — tag v1.9.7 is not in this checkout (the live checks below use the generated install)"
fi
d="$(variant v197)"; strip_sn "$d/customer.env"; grep -v -E '^(SERVICENOW_|GATEWAY_SERVICENOW_|SANITIZER_CONFIG_FILE=|GATEWAY_PORT=)' "$d/customer.env" > "$d/e" && mv "$d/e" "$d/customer.env"
cli status "$d/customer.env"
check_eq "upgrade: the exact pre-K-C Compose arguments (no overlay)" \
  "compose -f $COMPOSE -f $SELFHOSTED --profile llama-cpp --env-file $d/customer.env ps" "$(cat "$TMP/stub.log")"
[ ! -s "$TMP/config.log" ] && pass "upgrade: no Compose probe ran (no ServiceNow setting named)" || fail "upgrade: a probe ran: $(head -1 "$TMP/config.log")"
sed -n '/^# ── ServiceNow mode/,/^#   SERVICENOW_LOGIN_DIR/p' "$ROOT/customer.env.example" >> "$d/customer.env"
grep -q '^#   GATEWAY_SERVICENOW_KEY_BINDINGS=' "$d/customer.env" && cli status "$d/customer.env"
check_eq "the commented block of customer.env.example pasted in: still no overlay" \
  "compose -f $COMPOSE -f $SELFHOSTED --profile llama-cpp --env-file $d/customer.env ps" "$(cat "$TMP/stub.log")"
[ ! -s "$TMP/config.log" ] && pass "commented block: no Compose probe ran" || fail "commented block: a probe ran"
cli status "$ENVF"; grep -q 'lucairn-servicenow-probe.yml config --format json' "$TMP/config.log" && pass "an opted-in customer.env IS read through the Compose probe" || fail "the opted-in env was not probed: $(cat "$TMP/config.log")"
render "$d/customer.env" | python3 -c 'import json,sys; e=json.load(sys.stdin)["services"]["sanitizer-core"]["environment"]; sys.exit(0 if "LCR_PROFILE" not in e and not any(k.startswith("LCR_SERVICENOW_") for k in e) else 1)' \
  && pass "upgrade: the core gets no LCR_PROFILE (unset = kit) and no control client" || fail "upgrade: core profile"
python3 - "$ROOT" <<'PY' && pass "upgrade: the base compose files are byte-identical to the pinned OFF golden sources" || fail "upgrade: base files changed"
import hashlib, json, os, sys
root = sys.argv[1]
base = json.load(open(os.path.join(root, "tests/fixtures/servicenow-control/off/baseline.json")))["sha256"]
sys.exit(0 if all(hashlib.sha256(open(os.path.join(root, f), "rb").read()).hexdigest() == h for f, h in base.items()) else 1)
PY

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "E. bin/lucairn doctor --offline RED-PROOF"
cli up "$ENVF" >/dev/null 2>&1
doctor_offline() { # <env> [compose]
  bash "$ROOT/bin/lucairn" doctor --env "$1" --compose "${2:-$COMPOSE}" --offline --skip-image-check > "$TMP/doc.out" 2>&1
}
if doctor_offline "$ENVF"; then pass "GREEN: offline doctor passes on the opted-in install after up"; else fail "GREEN: $(grep -E 'failed' "$TMP/doc.out" | head -3 | tr '\n' ' ')"; fi
for line in "ServiceNow mode: opted in (1 bound key(s) on 1 instance(s)" "ServiceNow mode: sanitizer config copy ok" "ServiceNow mode: stored login ok" "ServiceNow mode: mount and setting scope ok (expected on)" "sanitizer core profile: kit-servicenow"; do
  grep -Fq "$line" "$TMP/doc.out" && pass "GREEN line: $line" || fail "GREEN line: $line"
done
if doctor_offline "$BASEENV"; then grep -Fq "ServiceNow mode: off (default" "$TMP/doc.out" && grep -Fq "mount and setting scope ok (expected off)" "$TMP/doc.out" && pass "GREEN: the default install reports the mode off and a clean scope" || fail "default install lines"; else fail "default install doctor red: $(grep failed "$TMP/doc.out" | head -2)"; fi
expect_red() { # <name> <env> <fixed text> [compose]
  if doctor_offline "$2" "${4:-}"; then fail "$1 — doctor stayed green"
  elif grep -Fq "$3" "$TMP/doc.out"; then pass "$1 — doctor red with: $3"
  else fail "$1 — red without '$3': $(grep -i 'servicenow\|profile' "$TMP/doc.out" | grep -i fail | head -2 | tr '\n' ' ')"; fi
}
cp "$SNC/base-sanitizer.yaml" "$TMP/base.keep"
printf '# edited after the last up\n' >> "$SNC/base-sanitizer.yaml"
expect_red "RED base config edited after the last up" "$ENVF" "does not match a rebuild of the current base"
cp "$TMP/base.keep" "$SNC/base-sanitizer.yaml"
cp "$SNC/copy/sanitizer.yaml" "$TMP/copy.keep"; chmod u+w "$SNC/copy/sanitizer.yaml"
printf '  extra: hand-edit\n' >> "$SNC/copy/sanitizer.yaml"
expect_red "RED copy edited by hand" "$ENVF" "does not match a rebuild of the current base"
rm -f "$SNC/copy/sanitizer.yaml"
expect_red "RED copy missing" "$ENVF" "copy is missing; run bin/lucairn up"
cp "$TMP/copy.keep" "$SNC/copy/sanitizer.yaml"
chmod 0644 "$SNC/login/login.json"
expect_red "RED login file 0644" "$ENVF" "login.json must have mode 0400"
chmod 0400 "$SNC/login/login.json"
d="$(variant doc-noswitch)"; strip_sn "$d/customer.env"; printf 'GATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n' >> "$d/customer.env"
expect_red "RED bindings without the switch" "$d/customer.env" "ServiceNow mode: failed (session_config_invalid"
d="$(variant doc-profile)"; printf 'LCR_PROFILE=kit-servicenow\n' >> "$d/customer.env"
expect_red "RED LCR_PROFILE=kit-servicenow in customer.env" "$d/customer.env" "set only by the ServiceNow opt-in overlay, never in customer.env"
K="$TMP/kit-mutant"; mkdir -p "$K"
cp "$COMPOSE" "$SELFHOSTED" "$ROOT/docker-compose.self-hosted-byok.yml" "$K/"
cp -R "$ROOT/scripts" "$ROOT/config" "$ROOT/migrations" "$K/"   # what the doctor checks beside the compose file
python3 - "$OVERLAY" "$K/docker-compose.servicenow-control.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = '        ipv4_address: "${SERVICENOW_CONTROL_CORE_IP:?explicit private interface required}"\n'
assert s.count(old) == 1
s = s.replace(old, old + '    volumes:\n      - type: bind\n        source: "${SERVICENOW_CONTROL_MATERIAL:?x}/sanitizer"\n        target: /run/secrets/servicenow-control/sanitizer\n        read_only: true\n')
open(sys.argv[2], "w").write(s)
PY
expect_red "RED an overlay that mounts the sanitizer leaf into the model sidecar" "$ENVF" "sanitizer-core-sidecar mounts ServiceNow material it must not hold" "$K/docker-compose.customer.yml"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "F. Mount/setting scope scan on mutated renders"
render "$ENVF" -f "$OVERLAY" > "$TMP/on.json" || fail "on render: $(head -2 "$TMP/render.err")"
render "$BASEENV" > "$TMP/off.json" || fail "off render"
SCAN_ARGS=(--material "$SNC/certs/material" --login-dir "$SNC/login" --copy "$SNC/copy/sanitizer.yaml" --core-ip 172.30.251.4)
python3 "$HELPER" scan --expect on "${SCAN_ARGS[@]}" < "$TMP/on.json" > "$TMP/scan.out" && pass "scan: the real ON render is in scope" || fail "scan ON: $(cat "$TMP/scan.out")"
python3 "$HELPER" scan --expect off < "$TMP/off.json" > "$TMP/scan.out" && pass "scan: the real OFF render is in scope" || fail "scan OFF: $(cat "$TMP/scan.out")"
mutate_scan() { # <name> <expect> <python mutation of `s` (services)> <fixed FAIL text>
  python3 - "$TMP/$2.json" "$TMP/mut.json" "$SNC/certs/material" "$SNC/login" <<PY
import json, sys
doc = json.load(open(sys.argv[1])); s = doc["services"]; M, L = sys.argv[3], sys.argv[4]
def bind(src, tgt): return {"type": "bind", "source": src, "target": tgt, "read_only": True}
$3
json.dump(doc, open(sys.argv[2], "w"))
PY
  if python3 "$HELPER" scan --expect "$2" "${SCAN_ARGS[@]}" < "$TMP/mut.json" > "$TMP/scan.out"; then fail "scan mutant $1 stayed in scope"
  elif grep -Fq "$4" "$TMP/scan.out"; then pass "scan mutant $1 — $4"
  else fail "scan mutant $1 — other reason: $(cat "$TMP/scan.out" | tr '\n' ' ')"; fi
}
mutate_scan "login file in the sanitizer" on 's["sanitizer"]["volumes"].append(bind(L, "/run/secrets/servicenow-login"))' "sanitizer mounts ServiceNow material it must not hold"
mutate_scan "gateway leaf in the core" on 's["sanitizer-core"]["volumes"].append(bind(M + "/gateway", "/run/secrets/servicenow-control/gateway"))' "sanitizer-core mounts ServiceNow material it must not hold"
mutate_scan "sanitizer leaf in the sidecar" on 's["sanitizer-core-sidecar"]["volumes"] = [bind(M + "/sanitizer", "/x")]' "sanitizer-core-sidecar mounts ServiceNow material it must not hold"
mutate_scan "CA operator folder in the gateway" on 's["gateway"]["volumes"].append(bind(M + "/operator", "/ca"))' "gateway mounts ServiceNow material it must not hold"
mutate_scan "a writable control mount" on '[m.update(read_only=False) for m in s["gateway"]["volumes"] if m["target"] == "/run/secrets/servicenow-login"]' "not a read-only bind"
mutate_scan "a sidecar alias" on 's["sanitizer-core-sidecar"]["networks"]["servicenow-control"]["aliases"] = ["core.servicenow-control"]' "without an alias"
mutate_scan "core dumps on the core" on 's["sanitizer-core"].pop("ulimits")' "sanitizer-core may write core dumps"
mutate_scan "no GOTRACEBACK on the core" on 's["sanitizer-core"]["environment"].pop("GOTRACEBACK")' "sanitizer-core does not set GOTRACEBACK=none"
mutate_scan "core profile kit while on" on 's["sanitizer-core"]["environment"]["LCR_PROFILE"] = "kit"' "does not run LCR_PROFILE=kit-servicenow"
mutate_scan "control client on the sanitizer" on 's["sanitizer"]["environment"]["LCR_SERVICENOW_CONTROL_PEER_URL"] = "x"' "sanitizer carries the core's ServiceNow control client"
mutate_scan "hosted profile while off" off 's["sanitizer-core"]["environment"]["LCR_PROFILE"] = "hosted"' "profile other than kit while the mode is off"
mutate_scan "control material while off" off 's["gateway"]["volumes"].append(bind(M + "/gateway", "/run/secrets/servicenow-control/gateway"))' "while the mode is off"
mutate_scan "gateway settings while off" off 's["gateway"]["environment"]["GATEWAY_SERVICENOW_KEY_BINDINGS"] = "k=i"' "carries ServiceNow settings while the mode is off"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "G. bin/lucairn doctor online (stub engine + stub admin API)"
printf '%s\n' 'lcr_live_synthetic_k_c_doctor_fixture_key' > "$TMP/customer.key"; chmod 600 "$TMP/customer.key"
SIDE_ID="5ide000000000000000000000000000000000000000000000000000000000001"
cat > "$TMP/ps.ok" <<EOF
gateway|9a7e000000000000000000000000000000000000000000000000000000000004|running|healthy
postgres-sanitizer-core|9f00000000000000000000000000000000000000000000000000000000000003|running|healthy
sanitizer-core-sidecar|$SIDE_ID|running|healthy
sanitizer-core|c0re000000000000000000000000000000000000000000000000000000000002|running|healthy
EOF
{ cat "$TMP/ps.ok"; echo "gateway|9a7e000000000000000000000000000000000000000000000000000000000005|running|healthy"; } > "$TMP/ps.two"
printf '%s\n' '2026/11/02 08:00:00 evidence: witness transport mode=mtls addr="veil-witness:50057"' > "$TMP/core.log"
printf '%s\n' 'veil-claim-arrival request_id=r1 service_id=dsa-sanitizer' > "$TMP/witness.log"
online() { # [env assignments...]
  env STUB_MEM_BYTES=34359738368 STUB_PS="$TMP/ps.ok" STUB_NETMODE="container:$SIDE_ID" STUB_CORE_LOG="$TMP/core.log" \
    STUB_WITNESS_LOG="$TMP/witness.log" STUB_LEDGER_OUT=7 "$@" \
    bash "$ROOT/bin/lucairn" doctor --env "$ENVF" --compose "$COMPOSE" --customer-key-file "$TMP/customer.key" --skip-image-check > "$TMP/online.out" 2>&1
  ONLINE_RC=$?
}
online_red() { # <name> <fixed text> [env...]
  local name="$1" text="$2"; shift 2
  online "$@"
  if [ "$ONLINE_RC" -ne 0 ] && grep -Fq "$text" "$TMP/online.out" && ! grep -q 'gateway healthz:' "$TMP/online.out"; then pass "$name — doctor red and stopped: $text"
  else fail "$name — rc $ONLINE_RC: $(grep 'ServiceNow mode' "$TMP/online.out" | tail -4 | tr '\n' ' ')"; fi
}
online
for line in "ServiceNow mode: bound keys exist (bound=1 missing=0 owners=1)" "ServiceNow mode: gateway status ok (mode=on instances=1 unlocked=1 cert_days=300" "ServiceNow mode: one gateway serves the mode"; do
  grep -Fq "$line" "$TMP/online.out" && pass "GREEN online line: $line" || fail "GREEN online line: $line — $(grep 'ServiceNow mode' "$TMP/online.out" | tail -5 | tr '\n' ' ')"
done
if grep -q 'ServiceNow mode: failed' "$TMP/online.out"; then fail "GREEN online: a ServiceNow check failed"; else pass "GREEN online: no ServiceNow check failed"; fi
{ grep -Fq "$ADMIN_KEY" "$TMP/online.out" || grep -q 'lcr_live_synthetic_k_c' "$TMP/online.out"; } && fail "a key leaked into the doctor output" || pass "no admin or customer key in the doctor output"
online_red "RED two running gateway containers" "2 running gateway containers" STUB_PS="$TMP/ps.two"
write_state '{"cust_a":["key_b"]}' "$STATUS_OK"
online_red "RED typo'd bound key id" "a bound key id does not exist under its instance's owner"
write_state '{"cust_a":["key_a"]}' '{"mode":"on","instances":[{"index":1,"state":"locked","reason":"login_rejected"}],"control_cert_expires_in_days":300}'
online_red "RED instance not unlocked" "unlocked=0 cert_days=300 reasons=login_rejected"
write_state '{"cust_a":["key_a"]}' '{"mode":"on","instances":[{"index":1,"state":"unlocked","reason":null}],"control_cert_expires_in_days":9}'
online_red "RED control certificate under 14 days" "cert_days=9"
write_state '{"cust_a":["key_a"]}' '{"mode":"off","instances":[]}'
online_red "RED gateway not recreated after the opt-in (status off)" "mode=off"
write_state '{"cust_a":["key_a","key_b"]}' "$STATUS_OK"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "H. kit-servicenow is set only by the opt-in overlay / Helm enabled branch"
grep -q 'kit-servicenow' "$COMPOSE" "$SELFHOSTED" "$ROOT/docker-compose.self-hosted-byok.yml" && fail "a base compose file names kit-servicenow" || pass "no base compose file names kit-servicenow"
grep -Eq '^[[:space:]]*#?[[:space:]]*LCR_PROFILE=kit-servicenow' "$ROOT/customer.env.example" && fail "customer.env.example carries LCR_PROFILE=kit-servicenow" || pass "customer.env.example carries no LCR_PROFILE value"
grep -rq 'kit-servicenow' "$ROOT/charts/lucairn/values.yaml" "$ROOT/charts/lucairn/charts/sanitizer-core/values.yaml" "$ROOT/customer-values.yaml.example" && fail "a chart default names kit-servicenow" || pass "no chart default names kit-servicenow"
check_eq "the overlay sets kit-servicenow exactly once, as a literal on the core" "1" "$(grep -c '^      LCR_PROFILE: kit-servicenow$' "$OVERLAY")"
grep -q '"kit-servicenow"{{ else }}"kit"{{ end }}' "$ROOT/charts/lucairn/charts/sanitizer-core/templates/deployment.yaml" \
  && pass "Helm renders kit-servicenow only on the servicenowControl branch" || fail "Helm profile branch"

grep -q 'mode is refused in this release\|ServiceNow mode is refused\|mode itself is not$' "$ROOT/INSTALL.md" "$ROOT/customer.env.example" \
  && fail "INSTALL.md / customer.env.example still say the mode is not available" || pass "B7: INSTALL.md and customer.env.example no longer say the mode is unavailable"
grep -q '^## ServiceNow mode (off by default)$' "$ROOT/INSTALL.md" && pass "INSTALL.md has the admin guide section" || fail "INSTALL.md admin guide section"
grep -q 'SN_UPDATE_SET="servicenow-directory/lucairn-directory-update-set.xml"' "$ROOT/scripts/release-kit.sh" \
  && pass "release-kit.sh refuses a release without the directory app's update-set export" || fail "release gate for the update set"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "I. Bundles of an opted-in install"
MD="$TMP/models"; mkdir -p "$MD"; printf 'fixture model bytes\n' > "$MD/fixture.gguf"
if command -v sha256sum >/dev/null 2>&1; then MS="$(sha256sum "$MD/fixture.gguf" | awk '{print $1}')"; else MS="$(shasum -a 256 "$MD/fixture.gguf" | awk '{print $1}')"; fi
cat > "$TMP/model-manifest.yaml" <<YAML
model:
  name: fixture-local-model
  format: gguf
  runtime: llama-cpp
  files:
    - path: fixture.gguf
      sha256: $MS
  context_window: 8192
  gpu_required: false
  min_vram_gb: 0
  license: customer-owned
  checksum_policy: sha256-required
YAML
if bash "$ROOT/bin/lucairn" bundle create --customer-slug kc-optin --models-dir "$MD" --model-manifest "$TMP/model-manifest.yaml" \
     --env "$ENVF" --output "$TMP/bundles" > "$TMP/bundle.out" 2>&1; then
  B="$(find "$TMP/bundles" -maxdepth 1 -type d -name 'lucairn-customer-bundle-kc-optin-*' | head -1)"
  [ -f "$B/install/docker-compose.servicenow-control.yml" ] && [ -x "$B/bin/lucairn-servicenow.py" ] && [ -x "$B/scripts/bootstrap-servicenow-control.py" ] \
    && pass "the bundle carries the overlay, the opt-in helper and the control bootstrap" || fail "bundle contents"
  bash "$ROOT/bin/lucairn" bundle verify --bundle "$B" > "$TMP/verify.out" 2>&1 && pass "bundle verify: ok" || fail "bundle verify: $(tail -2 "$TMP/verify.out")"
  rm -f "$B/bin/lucairn-servicenow.py"
  if bash "$ROOT/bin/lucairn" bundle verify --bundle "$B" > "$TMP/verify.out" 2>&1; then fail "bundle verify accepted a bundle without the opt-in helper"
  else grep -q 'ServiceNow opt-in helper' "$TMP/verify.out" && pass "bundle verify refuses an opted-in bundle without the helper" || fail "verify reason: $(tail -1 "$TMP/verify.out")"; fi
else
  fail "bundle create: $(tail -3 "$TMP/bundle.out" | tr '\n' ' ')"
fi
d="$(variant bundle-invalid)"; strip_sn "$d/customer.env"; printf 'GATEWAY_SERVICENOW_KEY_BINDINGS=key_a=inst1\n' >> "$d/customer.env"
if bash "$ROOT/bin/lucairn" bundle create --customer-slug kc-bad --models-dir "$MD" --model-manifest "$TMP/model-manifest.yaml" \
     --env "$d/customer.env" --output "$TMP/bundles-bad" > "$TMP/bundle.out" 2>&1; then fail "bundle create packed bindings without the switch"
else grep -q 'session_config_invalid' "$TMP/bundle.out" && pass "bundle create refuses bindings without the switch" || fail "bundle refusal: $(tail -1 "$TMP/bundle.out")"; fi

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "ServiceNow opt-in (K-C): ok ($N checks)"
  exit 0
fi
echo "ServiceNow opt-in (K-C): $FAILS of $N checks FAILED" >&2
exit 1
