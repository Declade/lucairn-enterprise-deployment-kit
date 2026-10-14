#!/usr/bin/env bash
#
# tests/test_contrib_clients.sh — offline checks for contrib/clients/ (Hermes, OpenCode, OpenWork launchers).
#
# PRD: specs/2026-10/prd-2026-10-14-supported-clients-opencode-openwork-hermes.md (Slices 1–3 + review fix pass)
#
# No network, no real client: each launcher is run against a STUB client binary that
# reports what it received (argv, a few environment facts, never the key values), and the
# helper programs a launcher runs are wrapped by PROBES that log whether a key value is in
# their environment. Asserted:
#   1. shellcheck clean (fails closed when shellcheck is missing — a skipped lint reads as a pass)
#   2. no personal paths, no key-shaped strings in contrib/clients
#   3. Hermes recipe: web off, retries 1 / recovery 0, no lazy installs, file tools only
#   4. hermes.sh: fresh profile; keys ONLY in the client's environment (not in the config check, not in
#      any helper); stray keys and inherited internal names dropped; refusals for an altered profile
#      config (transport, keyless_fallback/keyless_rescue, retries, recovery, disabled toolsets,
#      platform toolsets), a key in .env, a bad gateway address (incl. user@host), a named work folder
#   5. opencode.sh: binary checked against the pin at every start (a tampered binary is refused);
#      env-only safety switches, gateway /v1, both keys only in the client, upstream key, work folder,
#      PWD, rule file referenced by BOTH configs, refusals for bad gateway addresses / named folders
#   6. openwork.sh: config writer and chat helper see no key, the host does; stray keys scrubbed; bad
#      gateway address refused before the host starts
#   7. openwork desktop.sh: git required, exact commit required, build steps without keys and the app
#      with them; `stop` signals only a process group it can prove is the app
#   8. openwork lib/config.mjs + key helper: keys on the gateway origin only (no user@, lookalike,
#      other port), never across a redirect (native fetch against two local servers)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/contrib/clients"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/contrib-clients-test.XXXXXX")"
EXTRA_CLEAN=""
KILL_PIDS=""
# shellcheck disable=SC2317,SC2329  # invoked via the EXIT trap
cleanup() {
  local p
  for p in $KILL_PIDS; do kill "$p" 2>/dev/null; kill -- "-$p" 2>/dev/null; done
  rm -rf "$TMP" $EXTRA_CLEAN
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
# t <description> <command…> — ok when the command succeeds
t() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { printf '%s\n' "$out" | grep -q -- "$1"; }
hasnt() { if printf '%s\n' "$out" | grep -q -- "$1"; then return 1; fi; return 0; }
# refused <message part> — launcher stopped with exit 2, the client never ran, and said why
refused() { [ "$rc" -eq 2 ] && hasnt '^ARGV:' && has "$1"; }

FAKE_LK="lcr_test_FAKEKEY_0123456789abcdef"
FAKE_UK="fake-upstream-key-0123456789abcdef"
ME="$(id -un)"
PY3="$(command -v python3 || true)"
NODE_REAL="$(command -v node || true)"
GREP_REAL="$(command -v grep)"
PROBE_LOG="$TMP/probe.log"
: > "$PROBE_LOG"

# ── 1. shellcheck ────────────────────────────────────────────────────────────
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x -P SCRIPTDIR -S style "$C"/lib/common.sh "$C"/*/*.sh; then ok "shellcheck clean"; else bad "shellcheck findings"; fi
else
  bad "shellcheck not installed (fails closed)"
fi

# ── 2. no personal paths / key-shaped strings ────────────────────────────────
if grep -rnE '/Users/[A-Za-z0-9._-]+' "$C" | grep -vE '/Users/Shared(/|$|[^A-Za-z])' ; then
  bad "a /Users/<name> path in contrib/clients"
else ok "no personal /Users paths"; fi
if grep -rnE 'lcr_live_[A-Za-z0-9]|sk-ant-[A-Za-z0-9]|/home/[a-z]+/' "$C"; then bad "key-shaped string or /home path"; else ok "no key-shaped strings"; fi

# ── 3. Hermes recipe ─────────────────────────────────────────────────────────
if [ -n "$PY3" ] && "$PY3" -c 'import yaml' 2>/dev/null; then
  if "$PY3" - "$C/hermes/config.yaml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
assert c["web"]["keyless_fallback"] is False, "keyless_fallback"
assert c["web"]["keyless_rescue"] is False, "keyless_rescue"
assert "web" in c["agent"]["disabled_toolsets"], "disabled_toolsets"
assert c["agent"]["api_max_retries"] == 1 and c["agent"]["auto_recovery_cycles"] == 0, "retries"
assert c["security"]["allow_lazy_installs"] is False, "lazy installs"
assert c["platform_toolsets"]["cli"] == ["file"], "toolsets"
assert c["auxiliary"]["title_generation"]["model_upgrade_enabled"] is False, "title"
p = c["providers"]["lucairn-anthropic"]
assert p["key_env"] == "LUCAIRN_API_KEY" and p["api"] == "${LUCAIRN_GATEWAY_URL}", "provider"
PY
  then ok "hermes recipe: web off, retries 1 / recovery 0, no lazy installs, file tools only, keys by env"; else bad "hermes recipe"; fi
else
  bad "python3 yaml missing (fails closed)"
fi

# ── probes and stubs ─────────────────────────────────────────────────────────
# make_probe <path> <label> <real program> — logs "<label> HAS_KEY=yes|no" (is either fake key value
# anywhere in its environment?), then runs the real program unchanged.
make_probe() {
  cat > "$1" <<PROBE
#!/bin/sh
if /usr/bin/env | "$GREP_REAL" -q -e "$FAKE_LK" -e "$FAKE_UK"; then k=yes; else k=no; fi
printf '%s HAS_KEY=%s\n' "$2" "\$k" >> "$PROBE_LOG"
exec "$3" "\$@"
PROBE
  chmod +x "$1"
}
# PATH probes: every common helper a launcher could run before it cleans its environment.
PB="$TMP/probe-bin"; mkdir -p "$PB"
for tool in id uname dirname basename mkdir cp mv tr date cat sed rm awk shasum sha256sum base64 sleep sort mktemp; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  if [ -n "$real" ]; then make_probe "$PB/$tool" "tool:$tool" "$real"; fi
done
probe_keys() { grep -c 'HAS_KEY=yes' "$PROBE_LOG" | tr -d ' '; }   # how many probed programs saw a key

# Stub client: prints argv and environment facts; never the key values themselves.
make_stub() {
  cat > "$1" <<STUB
#!/bin/sh
if /usr/bin/env | "$GREP_REAL" -q -e "$FAKE_LK" -e "$FAKE_UK"; then k=yes; else k=no; fi
printf '%s HAS_KEY=%s\n' "client:\${1:-}" "\$k" >> "$PROBE_LOG"
printf 'ARGV:%s\n' "\$*"
printf 'HAS_LK:%s\n' "\$([ "\${LUCAIRN_API_KEY:-}" = "$FAKE_LK" ] && echo yes || echo no)"
printf 'HAS_UK:%s\n' "\$([ "\${LUCAIRN_UPSTREAM_KEY:-}" = "$FAKE_UK" ] && echo yes || echo no)"
printf 'KEYVARS:%s\n' "\$(/usr/bin/env | while IFS= read -r l; do case "\$l" in (*="$FAKE_LK"|*="$FAKE_UK") printf '%s\n' "\${l%%=*}" ;; esac; done | sort | tr '\n' ' ')"
printf 'STRAY:%s\n' "\${ANTHROPIC_API_KEY:-none}"
printf 'LCK:%s\n' "\${LC_LUCAIRN_KEY:-none}"
printf 'HOME:%s\n' "\$HOME"
printf 'PWD:%s\n' "\$(pwd -P)"
printf 'BASE_URL:%s\n' "\${LUCAIRN_BASE_URL:-}"
printf 'GW:%s\n' "\${LUCAIRN_GATEWAY_URL:-}"
printf 'PROJ:%s\n' "\${OPENCODE_DISABLE_PROJECT_CONFIG:-}"
printf 'EXTSK:%s\n' "\${OPENCODE_DISABLE_EXTERNAL_SKILLS:-}"
printf 'RULES:%s\n' "\${LUCAIRN_RULES_FILE:-}"
STUB
  chmod +x "$1"
}
KEYVARS_OK="KEYVARS:LUCAIRN_API_KEY LUCAIRN_UPSTREAM_KEY "

# A neutral work folder (TMPDIR may hold the login name on some systems).
WORK="$TMP/neutral-work"
case "$(printf '%s' "$WORK" | tr '[:upper:]' '[:lower:]')" in
  *"$(printf '%s' "$ME" | tr '[:upper:]' '[:lower:]')"*)
    WORK="/var/tmp/contrib-clients-test-$$"; EXTRA_CLEAN="$WORK" ;;
esac
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd -P)"
NAMED_SUB="$TMP/x/$ME-project"                        # login name inside a longer component
NAMED_UP="$TMP/x/pre$(printf '%s' "$ME" | tr '[:lower:]' '[:upper:]')post"   # … in another letter case
BAD_GWS="http://localhost:8000@evil.example https://gw.example.test@evil.example ftp://gw.example.test http://127.0.0.1.evil.example"

# ── 4. hermes.sh ─────────────────────────────────────────────────────────────
HD="$TMP/hermes-install"; mkdir -p "$HD/.venv/bin"
make_stub "$HD/.venv/bin/hermes"
# The venv python of a real install has PyYAML; the system python3 stands in (absolute path: the launcher
# cleans PATH before the config check). The probe drops -I (it would hide a user-site PyYAML).
cat > "$HD/.venv/bin/python" <<PYSTUB
#!/bin/sh
if /usr/bin/env | "$GREP_REAL" -q -e "$FAKE_LK" -e "$FAKE_UK"; then k=yes; else k=no; fi
printf 'python-config-check HAS_KEY=%s\n' "\$k" >> "$PROBE_LOG"
if [ "\$1" = "-I" ]; then shift; fi
exec "$PY3" "\$@"
PYSTUB
chmod +x "$HD/.venv/bin/python"
HP="$TMP/hermes-profile"
run_h() { env PATH="$PB:$PATH" LUCAIRN_HERMES_DIR="$HD" LUCAIRN_HERMES_PROFILE="$HP" LUCAIRN_WORK_DIR="${W:-$WORK}" \
  LUCAIRN_API_KEY="$FAKE_LK" LUCAIRN_UPSTREAM_KEY="$FAKE_UK" ANTHROPIC_API_KEY=stray-should-vanish \
  ${XGW:+LUCAIRN_GATEWAY_URL="$XGW"} bash "$C/hermes/hermes.sh" "$@"; }
: > "$PROBE_LOG"
out="$(run_h -z "hello" 2>&1)"; rc=$?
t "hermes.sh fresh profile starts (rc=$rc)" [ "$rc" -eq 0 ]
t "recipe copied into the fresh profile" cmp -s "$C/hermes/config.yaml" "$HP/hermes-home/config.yaml"
t "placeholder rule in SOUL.md" grep -q "Lucairn privacy placeholders" "$HP/hermes-home/SOUL.md"
t "argv carries no key" has '^ARGV:-z hello$'
t "keys reach hermes via the environment" has '^HAS_LK:yes$'
t "provider key reaches hermes via the environment" has '^HAS_UK:yes$'
t "hermes: the keys are in exactly the two client variables" has "^$KEYVARS_OK\$"
t "stray provider key scrubbed" has '^STRAY:none$'
t "HOME is the profile's" has "^HOME:$HP/home\$"
t "hermes runs in the work folder (PWD)" has "^PWD:$WORK\$"
t "default gateway" has '^GW:https://gateway.lucairn.eu$'
t "key value not printed" hasnt "$FAKE_LK"
t "hermes: the config check (python) ran" grep -q '^python-config-check ' "$PROBE_LOG"
t "hermes: the config check saw no key" grep -q '^python-config-check HAS_KEY=no$' "$PROBE_LOG"
t "hermes: helper programs ran under probe" grep -q '^tool:' "$PROBE_LOG"
t "hermes: no helper program saw a key" [ "$(grep -v '^client:' "$PROBE_LOG" | grep -c 'HAS_KEY=yes' | tr -d ' ')" = 0 ]
t "hermes: its key-less first --version saw no key" grep -q '^client:--version HAS_KEY=no$' "$PROBE_LOG"

# inherited internal names (an exported LC_LUCAIRN_KEY …) neither crash the launcher nor reach the client
out="$(LC_LUCAIRN_KEY=inherited-x LC_UPSTREAM_KEY=inherited-y LC_USER=inherited-z LC_GW=https://evil.example \
  run_h -z hi 2>&1)"; rc=$?
t "hermes: inherited LC_* names do not break set -u (rc=$rc)" [ "$rc" -eq 0 ]
t "hermes: inherited LC_* names do not reach the client" has '^LCK:none$'
t "hermes: inherited LC_GW ignored" has '^GW:https://gateway.lucairn.eu$'

# profile config altered → refused (each guarded line)
hermes_refuses() {  # <sed expression> <expected message part>
  sed "$1" "$C/hermes/config.yaml" > "$HP/hermes-home/config.yaml"
  if cmp -s "$C/hermes/config.yaml" "$HP/hermes-home/config.yaml"; then return 1; fi   # the edit must change something
  out="$(run_h -z hi 2>&1)"; rc=$?
  refused "$2"
}
t "refuses a form-rewritten config (no transport)" hermes_refuses '/transport: anthropic_messages/d' 'transport must be anthropic_messages'
t "refuses keyless_fallback true" hermes_refuses 's/keyless_fallback: false/keyless_fallback: true/' 'keyless_fallback must be false'
t "refuses keyless_rescue true" hermes_refuses 's/keyless_rescue: false/keyless_rescue: true/' 'keyless_rescue must be false'
t "refuses api_max_retries 3" hermes_refuses 's/api_max_retries: 1 /api_max_retries: 3 /' 'api_max_retries must be 0 or 1'
t "refuses auto_recovery_cycles 2" hermes_refuses 's/auto_recovery_cycles: 0 /auto_recovery_cycles: 2 /' 'auto_recovery_cycles must be 0'
t "refuses disabled_toolsets without web" hermes_refuses 's/disabled_toolsets: \[web\]/disabled_toolsets: []/' 'disabled_toolsets must contain web'
t "refuses a wider cli toolset" hermes_refuses 's/cli: \[file\]/cli: [file, terminal]/' 'platform_toolsets.cli must be'
out="$(run_h --reset-config 2>&1)"; rc=$?
t "--reset-config restores the recipe" cmp -s "$C/hermes/config.yaml" "$HP/hermes-home/config.yaml"
printf 'HERMES_CUSTOM_LUCAIRN_ANTHROPIC_API_KEY=abc123typed\n' > "$HP/hermes-home/.env"
out="$(run_h -z hi 2>&1)"; rc=$?
t "refuses a key in the profile .env" refused 'holds a key in clear text'
rm -f "$HP/hermes-home/.env"
out="$(W="$TMP/x/$ME/proj" run_h -z hi 2>&1)"; rc=$?
t "refuses a work folder holding the login name" refused 'contains the account name'
out="$(W="$NAMED_SUB" run_h -z hi 2>&1)"; rc=$?
t "refuses a work folder with the login name inside a word ($ME-project)" refused 'contains the account name'
out="$(W="$NAMED_UP" run_h -z hi 2>&1)"; rc=$?
t "refuses a work folder with the login name in another letter case" refused 'contains the account name'
for g in $BAD_GWS; do
  out="$(XGW="$g" run_h -z hi 2>&1)"; rc=$?
  t "hermes refuses the gateway address $g and stops" refused 'LUCAIRN_GATEWAY_URL'
done

# ── 5. opencode.sh ───────────────────────────────────────────────────────────
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=darwin-arm64 ;; Darwin-x86_64) PLAT=darwin-x64 ;;
  Linux-aarch64|Linux-arm64) PLAT=linux-arm64 ;; *) PLAT=linux-x64 ;;
esac
# A copy of contrib/clients whose pin is the stub's hash (the real pins stay untouched).
CC="$TMP/cc"; cp -R "$C" "$CC"
OD="$TMP/opencode-install"; OBIN="$OD/node_modules/opencode-$PLAT/bin/opencode"; mkdir -p "${OBIN%/*}"
make_stub "$OBIN"
STUB_SHA="$( (shasum -a 256 "$OBIN" 2>/dev/null || sha256sum "$OBIN") | awk '{print $1}')"
printf '# shellcheck shell=bash\noc_pinned_sha256() { printf "%%s\\n" %s; }\n' "$STUB_SHA" > "$CC/opencode/pins.sh"
run_o() { env PATH="$PB:$PATH" LUCAIRN_OPENCODE_DIR="$OD" LUCAIRN_OPENCODE_PROFILE="$TMP/opencode-profile" LUCAIRN_WORK_DIR="${W:-$WORK}" \
  LUCAIRN_API_KEY="$FAKE_LK" LUCAIRN_UPSTREAM_KEY="$FAKE_UK" ANTHROPIC_API_KEY=stray-should-vanish \
  LUCAIRN_GATEWAY_URL="${XGW:-https://gw.example.test}" bash "$CC/opencode/opencode.sh" "$@"; }
: > "$PROBE_LOG"
out="$(run_o -- --version 2>&1)"; rc=$?
t "opencode.sh starts (rc=$rc)" [ "$rc" -eq 0 ]
t "opencode base URL = gateway /v1" has '^BASE_URL:https://gw.example.test/v1$'
t "env-only safety switches set" has '^PROJ:1$'
t "external skills switch set" has '^EXTSK:1$'
t "opencode: stray provider key scrubbed" has '^STRAY:none$'
t "opencode: key via environment" has '^HAS_LK:yes$'
t "opencode: provider (upstream) key via environment" has '^HAS_UK:yes$'
t "opencode: the keys are in exactly the two client variables" has "^$KEYVARS_OK\$"
t "opencode runs in the work folder (PWD)" has "^PWD:$WORK\$"
t "opencode: no helper program saw a key" [ "$(grep -v '^client:' "$PROBE_LOG" | grep -c 'HAS_KEY=yes' | tr -d ' ')" = 0 ]
rules="$(printf '%s\n' "$out" | sed -n 's/^RULES://p')"
t "opencode: placeholder rule file exists" [ -f "$rules" ]
rule_in_both() {
  local f
  for f in opencode.json opencode-work.json; do grep -q '{env:LUCAIRN_RULES_FILE}' "$C/opencode/config/$f" || return 1; done
}
t "BOTH configs reference the rule" rule_in_both
if grep -rqE '"(apiKey|X-Upstream-Key)": *"[^{]' "$C/opencode/config/"; then bad "a literal key in an opencode config"; else ok "opencode configs hold env references only"; fi
# a binary that is not the pinned build never starts (and never gets the keys)
cp "$OBIN" "$TMP/obin.keep"; printf '\n# tampered\n' >> "$OBIN"
: > "$PROBE_LOG"
out="$(run_o -- --version 2>&1)"; rc=$?
t "opencode refuses a tampered binary at launch" refused 'not the verified OpenCode'
t "opencode: the tampered binary never ran" [ "$(grep -c '^client:' "$PROBE_LOG" | tr -d ' ')" = 0 ]
cp "$TMP/obin.keep" "$OBIN"
out="$(W="$TMP/x/$ME/proj" run_o "hi" 2>&1)"; rc=$?
t "opencode refuses a named work folder" refused 'contains the account name'
out="$(W="$NAMED_SUB" run_o "hi" 2>&1)"; rc=$?
t "opencode refuses the login name inside a word" refused 'contains the account name'
for g in $BAD_GWS; do
  out="$(XGW="$g" run_o "hi" 2>&1)"; rc=$?
  t "opencode refuses the gateway address $g and stops" refused 'LUCAIRN_GATEWAY_URL'
done

# ── 6. openwork.sh (host + chat helper stubbed, the real config writer) ─────────
if [ -n "$NODE_REAL" ]; then
  OWD="$TMP/openwork-install"; mkdir -p "$OWD/node_modules/openwork-server/bin"; : > "$OWD/node_modules/openwork-server/bin/openwork-server.mjs"
  NSTUB="$TMP/node-stub"
  cat > "$NSTUB" <<NODESTUB
#!/bin/sh
if /usr/bin/env | "$GREP_REAL" -q -e "$FAKE_LK" -e "$FAKE_UK"; then k=yes; else k=no; fi
printf 'node:%s HAS_KEY=%s\n' "\${1##*/}" "\$k" >> "$PROBE_LOG"
case "\${1:-}" in
  */openwork-server.mjs)
    { printf 'HOST_KEYVARS:%s\n' "\$(/usr/bin/env | while IFS= read -r l; do case "\$l" in (*="$FAKE_LK"|*="$FAKE_UK") printf '%s\n' "\${l%%=*}" ;; esac; done | sort | tr '\n' ' ')"
      printf 'HOST_STRAY:%s\n' "\${ANTHROPIC_API_KEY:-none}"; printf 'HOST_PWD:%s\n' "\$(pwd -P)"; printf 'HOST_BASE:%s\n' "\${LUCAIRN_BASE_URL:-}"; } > "$TMP/ow-host.txt"
    echo "OpenWork web UI: http://127.0.0.1:9/stub"
    exec sleep 30 ;;
  */ask.mjs) printf 'ASK_STRAY:%s\n' "\${ANTHROPIC_API_KEY:-none}"; exit 0 ;;
  *) exec "$NODE_REAL" "\$@" ;;
esac
NODESTUB
  chmod +x "$NSTUB"
  run_ow() { env PATH="$PB:$PATH" LUCAIRN_NODE="$NSTUB" LUCAIRN_OPENWORK_DIR="$OWD" LUCAIRN_OPENWORK_PROFILE="$TMP/openwork-profile" \
    LUCAIRN_WORK_DIR="${W:-$WORK}" LUCAIRN_API_KEY="$FAKE_LK" LUCAIRN_UPSTREAM_KEY="$FAKE_UK" ANTHROPIC_API_KEY=stray-should-vanish \
    LUCAIRN_GATEWAY_URL="${XGW:-https://gw.example.test}" LUCAIRN_OPENWORK_PORT=18999 bash "$C/openwork/openwork.sh" "$@"; }
  : > "$PROBE_LOG"; rm -f "$TMP/ow-host.txt"
  out="$(run_ow ask "hello" 2>&1)"; rc=$?
  t "openwork.sh ask runs (rc=$rc)" [ "$rc" -eq 0 ]
  hostout="$(cat "$TMP/ow-host.txt" 2>/dev/null || true)"
  t "openwork: the host gets both keys, in exactly the two variables" [ "$(printf '%s\n' "$hostout" | sed -n 's/^HOST_KEYVARS://p')" = "LUCAIRN_API_KEY LUCAIRN_UPSTREAM_KEY " ]
  t "openwork: stray provider key scrubbed from the host" grep -q '^HOST_STRAY:none$' "$TMP/ow-host.txt"
  t "openwork: host runs in the work folder (PWD)" grep -q "^HOST_PWD:$WORK\$" "$TMP/ow-host.txt"
  t "openwork: host base URL = gateway /v1" grep -q '^HOST_BASE:https://gw.example.test/v1$' "$TMP/ow-host.txt"
  t "openwork: stray provider key scrubbed from the chat helper" has '^ASK_STRAY:none$'
  t "openwork: the config writer ran without a key" grep -q '^node:config.mjs HAS_KEY=no$' "$PROBE_LOG"
  t "openwork: the chat helper ran without a key" grep -q '^node:ask.mjs HAS_KEY=no$' "$PROBE_LOG"
  t "openwork: no helper program saw a key" [ "$(grep -v '^node:openwork-server.mjs' "$PROBE_LOG" | grep -c 'HAS_KEY=yes' | tr -d ' ')" = 0 ]
  t "openwork: written config holds no key" [ "$(grep -c -e "$FAKE_LK" -e "$FAKE_UK" "$TMP/openwork-profile/xdg/config/opencode/opencode.json" | tr -d ' ')" = 0 ]
  for g in $BAD_GWS; do
    rm -f "$TMP/ow-host.txt"
    out="$(XGW="$g" run_ow ask "hi" 2>&1)"; rc=$?
    t "openwork refuses the gateway address $g before the host starts" eval '[ "$rc" -eq 2 ] && [ ! -f "$TMP/ow-host.txt" ] && has LUCAIRN_GATEWAY_URL'
  done
  out="$(W="$NAMED_SUB" run_ow ask "hi" 2>&1)"; rc=$?
  t "openwork refuses the login name inside a word" eval '[ "$rc" -eq 2 ] && has "contains the account name"'
else
  bad "node missing (fails closed)"
fi

# ── 7. openwork desktop.sh: source check, keys, stop ownership ────────────────
DPROF="$TMP/desktop-profile"; DST="$DPROF/desktop"; mkdir -p "$DST"
UNAME_REAL="$(command -v uname)"
DSTUB="$TMP/desktop-bin"; mkdir -p "$DSTUB"   # uname says Darwin (the launcher is macOS-only; the checks run anywhere)
printf '#!/bin/sh\nif [ "$1" = -s ]; then echo Darwin; else exec "%s" "$@"; fi\n' "$UNAME_REAL" > "$DSTUB/uname"; chmod +x "$DSTUB/uname"
NOGIT="$TMP/no-git-bin"; mkdir -p "$NOGIT"   # every program of /usr/bin and /bin except git
for f in /usr/bin/* /bin/*; do
  n="${f##*/}"
  if [ "$n" != git ] && [ ! -e "$NOGIT/$n" ]; then ln -s "$f" "$NOGIT/$n"; fi
done
cp "$DSTUB/uname" "$NOGIT/uname.tmp"; rm -f "$NOGIT/uname"; mv "$NOGIT/uname.tmp" "$NOGIT/uname"
if [ -n "$NODE_REAL" ] && command -v git >/dev/null 2>&1 && [ -n "$PY3" ]; then
  # A fake OpenWork checkout, tagged v0.18.58 (= a moved tag: not the recorded commit).
  SRC="$TMP/owsrc"; mkdir -p "$SRC/apps/desktop/scripts" "$SRC/node_modules"
  printf '{"name":"fake"}\n' > "$SRC/package.json"; : > "$SRC/apps/desktop/scripts/prepare-sidecar.mjs"
  printf 'node_modules\n' > "$SRC/.gitignore"
  ( cd "$SRC" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m fake && git tag v0.18.58 )
  FAKE_HEAD="$(git -C "$SRC" rev-parse HEAD)"
  NPROBE="$TMP/node-probe"; make_probe "$NPROBE" "dnode" "$NODE_REAL"
  # node probe labels by script name
  sed -i.bak "s|printf '%s HAS_KEY=%s\\\\n' \"dnode\"|printf '%s HAS_KEY=%s\\\\n' \"dnode:\${1##*/}\"|" "$NPROBE"; rm -f "$NPROBE.bak"
  PNPM_STUB="$TMP/pnpm-stub"
  cat > "$PNPM_STUB" <<PNPMSTUB
#!/bin/sh
if /usr/bin/env | "$GREP_REAL" -q -e "$FAKE_LK" -e "$FAKE_UK"; then k=yes; else k=no; fi
printf 'pnpm:%s HAS_KEY=%s\n' "\$*" "\$k" >> "$PROBE_LOG"
case "\$*" in
  "-w dev:ui") exec "$PY3" -m http.server "\$PORT" --bind 127.0.0.1 ;;
  dev) exec sleep 60 ;;
  *) exit 0 ;;
esac
PNPMSTUB
  chmod +x "$PNPM_STUB"
  BUN_STUB="$TMP/bun-stub"; printf '#!/bin/sh\nexit 0\n' > "$BUN_STUB"; chmod +x "$BUN_STUB"
  run_d() { env PATH="${DPATH:-$DSTUB:$PATH}" OPENWORK_SRC="$SRC" LUCAIRN_OPENWORK_PROFILE="$DPROF" LUCAIRN_WORK_DIR="$WORK" \
    LUCAIRN_NODE="$NPROBE" LUCAIRN_PNPM="$PNPM_STUB" LUCAIRN_BUN="$BUN_STUB" LUCAIRN_OPENWORK_DEBUG_PORT=19899 \
    LUCAIRN_API_KEY="$FAKE_LK" LUCAIRN_UPSTREAM_KEY="$FAKE_UK" bash "${DSCRIPT:-$C/openwork/desktop.sh}" "$@"; }
  : > "$PROBE_LOG"
  out="$(DPATH="$NOGIT" run_d 2>&1)"; rc=$?
  t "desktop refuses to start without git" eval '[ "$rc" -eq 2 ] && has "git not found" && ! grep -q "^pnpm:" "$PROBE_LOG"'
  : > "$PROBE_LOG"
  out="$(run_d 2>&1)"; rc=$?
  t "desktop refuses a checkout that is not the recorded commit (moved tag)" eval '[ "$rc" -eq 2 ] && has "verified build" && ! grep -q "^pnpm:" "$PROBE_LOG"'
  # changed tracked file → refused (copy whose recorded commit is the fake checkout's)
  sed "s/^COMMIT=\"[0-9a-f]*\"/COMMIT=\"$FAKE_HEAD\"/" "$C/openwork/desktop.sh" > "$CC/openwork/desktop.sh"
  printf '{"name":"changed"}\n' > "$SRC/package.json"
  : > "$PROBE_LOG"
  out="$(DSCRIPT="$CC/openwork/desktop.sh" run_d 2>&1)"; rc=$?
  t "desktop refuses changed tracked files" eval '[ "$rc" -eq 2 ] && has "changed tracked files" && ! grep -q "^pnpm:" "$PROBE_LOG"'
  git -C "$SRC" checkout -q -- package.json
  # the right commit: build steps + interface server without keys, the app with them, then `stop`
  : > "$PROBE_LOG"
  DSCRIPT="$CC/openwork/desktop.sh" run_d > "$TMP/desktop-run.out" 2>&1 &
  DPID=$!; KILL_PIDS="$KILL_PIDS $DPID"
  for _ in $(seq 1 80); do if grep -q '^pnpm:dev ' "$PROBE_LOG"; then break; fi; sleep 0.5; done
  t "desktop: the app (pnpm dev) started" grep -q '^pnpm:dev ' "$PROBE_LOG"
  t "desktop: the app got the keys" grep -q '^pnpm:dev HAS_KEY=yes$' "$PROBE_LOG"
  t "desktop: build steps ran" grep -q '^pnpm:--filter openwork-server build ' "$PROBE_LOG"
  t "desktop: the sidecar step ran" grep -q '^dnode:prepare-sidecar.mjs ' "$PROBE_LOG"
  t "desktop: the interface dev server ran" grep -q '^pnpm:-w dev:ui ' "$PROBE_LOG"
  t "desktop: nothing but the app saw a key" [ "$(grep -v '^pnpm:dev ' "$PROBE_LOG" | grep -c 'HAS_KEY=yes' | tr -d ' ')" = 0 ]
  PGRP="$(head -n 1 "$DST/desktop.pgid" 2>/dev/null || true)"
  out="$(DSCRIPT="$CC/openwork/desktop.sh" run_d stop 2>&1)"; rc=$?
  gone=1; if [ -n "$PGRP" ] && kill -0 -- "-$PGRP" 2>/dev/null; then gone=0; fi
  t "desktop stop ends the app's own process group" eval '[ -n "$PGRP" ] && [ "$gone" = 1 ]'
  for _ in $(seq 1 40); do kill -0 "$DPID" 2>/dev/null || break; sleep 0.5; done
  kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
  # stop never signals a saved id it cannot prove is the app
  perl -e 'setpgrp(0,0); exec @ARGV' sleep 60 & VICTIM=$!; KILL_PIDS="$KILL_PIDS $VICTIM"
  sleep 0.5
  printf '%s\n' "$VICTIM" > "$DST/desktop.pgid"
  out="$(run_d stop 2>&1)"; rc=$?
  t "desktop stop leaves an unverified saved group alone (old one-line record)" kill -0 "$VICTIM"
  printf '%s\nMon Jan  1 00:00:00 2001\n%s\n' "$VICTIM" "$SRC" > "$DST/desktop.pgid"
  out="$(run_d stop 2>&1)"; rc=$?
  t "desktop stop leaves a group whose start time differs alone" kill -0 "$VICTIM"
  printf '%s\n' "$VICTIM" > "$DST/watcher.pid"
  out="$(run_d stop 2>&1)"; rc=$?
  t "desktop stop leaves an unverified saved watcher alone" kill -0 "$VICTIM"
  printf '%s\n%s\n%s\n' "$VICTIM" "$(ps -o lstart= -p "$VICTIM")" "$SRC" > "$DST/desktop.pgid"
  out="$(run_d stop 2>&1)"; rc=$?
  sleep 0.5
  t "desktop stop ends a group it can prove is its own" eval '! kill -0 "$VICTIM" 2>/dev/null'
  kill "$VICTIM" 2>/dev/null; wait "$VICTIM" 2>/dev/null
else
  bad "node, git or python3 missing (desktop checks fail closed)"
fi

# ── 8. openwork config writer + key helper ───────────────────────────────────
if [ -n "$NODE_REAL" ]; then
  cfg="$TMP/ow.json"
  if node "$C/openwork/lib/config.mjs" "$cfg" "$C/openwork/plugin" files model=claude-sonnet-5-5 >/dev/null 2>&1 && node - "$cfg" <<'JS'
const fs = require("fs"); const c = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); const s = JSON.stringify(c);
const must = (x, m) => { if (!x) { console.error(m); process.exit(1); } };
must(!/\{env:LUCAIRN_(API|UPSTREAM)_KEY\}/.test(s), "key env reference in config");
must(c.provider.lucairn.options.apiKey.startsWith("not-a-key"), "apiKey placeholder");
must(c.enabled_providers.join() === "lucairn", "enabled_providers");
must(c.agent.title.disable === true, "title");
must(c.permission["*"] === "deny" && c.permission.read === "allow" && c.permission.edit === "allow" && !c.permission.bash, "permissions");
must(c.plugin.some((p) => p.endsWith("/lucairn-keys-from-env.js")), "key helper");
must(c.instructions.length === 2 && c.instructions.every((f) => fs.existsSync(f)), "instruction files");
JS
  then ok "openwork config: no key, key helper, rules, allow-list"; else bad "openwork config"; fi
  if node "$C/openwork/lib/config.mjs" "$TMP/ow2.json" "$C/openwork/plugin" model=gpt-x >/dev/null 2>&1; then bad "unknown model accepted"; else ok "unknown model refused"; fi
  if LUCAIRN_BASE_URL=https://gw.example.test/v1 LUCAIRN_API_KEY="$FAKE_LK" LUCAIRN_UPSTREAM_KEY="$FAKE_UK" \
     node --input-type=module -e '
const seen = [];
globalThis.fetch = async (input, init) => { seen.push({ url: String(input), h: new Headers(init?.headers), redirect: init?.redirect }); return new Response("{}"); };
const { LucairnKeysFromEnv } = await import(process.argv[1]);
await LucairnKeysFromEnv();
const urls = ["https://gw.example.test/v1/messages", "https://other.example.test/v1/messages",
  "https://gw.example.test@evil.example/v1/messages", "https://evil.example@gw.example.test/v1/messages",
  "https://gw.example.test.evil.example/v1/messages", "https://gw.example.test:444/v1/messages", "http://gw.example.test/v1/messages"];
for (const u of urls) await fetch(u, { headers: { "x-api-key": "not-a-key" } });
const [g, ...others] = seen;
const keyed = (r) => r.h.get("x-api-key") === process.env.LUCAIRN_API_KEY || r.h.get("x-upstream-key") === process.env.LUCAIRN_UPSTREAM_KEY;
const gwOk = g.h.get("x-api-key") === process.env.LUCAIRN_API_KEY && g.h.get("x-upstream-key") === process.env.LUCAIRN_UPSTREAM_KEY && g.redirect === "error";
const bad = others.filter(keyed).map((r) => r.url);
if (bad.length) console.error("keys sent to: " + bad.join(", "));
process.exit(gwOk && !bad.length ? 0 : 1);' "$C/openwork/plugin/lucairn-keys-from-env.js"; then
    ok "key helper: keys on the gateway origin only (no user@, lookalike, other port or scheme), redirects forbidden"
  else bad "key helper headers"; fi
  if LUCAIRN_API_KEY="$FAKE_LK" LUCAIRN_UPSTREAM_KEY="$FAKE_UK" node --input-type=module -e '
import http from "node:http";
const got = [];
const other = http.createServer((req, res) => { got.push(req.headers); res.end("{}"); });
await new Promise((r) => other.listen(0, "127.0.0.1", r));
const gw = http.createServer((req, res) => { res.writeHead(307, { location: `http://127.0.0.1:${other.address().port}/steal` }); res.end(); });
await new Promise((r) => gw.listen(0, "127.0.0.1", r));
process.env.LUCAIRN_BASE_URL = `http://127.0.0.1:${gw.address().port}/v1`;
const { LucairnKeysFromEnv } = await import(process.argv[1]);
await LucairnKeysFromEnv();
let failed = false;
try { await fetch(`http://127.0.0.1:${gw.address().port}/v1/messages`, { method: "POST", body: "{}" }); } catch { failed = true; }
const leaked = got.some((h) => h["x-api-key"] || h["x-upstream-key"]);
if (leaked) console.error("the redirect target received a key");
process.exit(!leaked && failed ? 0 : 1);' "$C/openwork/plugin/lucairn-keys-from-env.js"; then
    ok "key helper: a redirect to another origin gets no key (request fails closed)"
  else bad "key helper: keys followed a redirect"; fi
else
  bad "node missing (fails closed)"
fi

[ "$fails" -eq 0 ] || { printf '%s check(s) failed\n' "$fails"; exit 1; }
printf 'all contrib/clients checks passed\n'
