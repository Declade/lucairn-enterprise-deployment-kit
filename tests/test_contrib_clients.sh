#!/usr/bin/env bash
#
# tests/test_contrib_clients.sh — offline checks for contrib/clients/ (Hermes, OpenCode, OpenWork launchers).
#
# PRD: specs/2026-10/prd-2026-10-14-supported-clients-opencode-openwork-hermes.md (Slice 1)
#
# No network, no real client: each launcher is run against a STUB client binary that
# reports what it received (argv, a few environment variables). Asserted:
#   1. shellcheck clean (fails closed when shellcheck is missing — a skipped lint reads as a pass)
#   2. no personal paths, no key-shaped strings in contrib/clients
#   3. Hermes recipe: web search off (keyless_fallback false + web in disabled_toolsets), no lazy installs
#   4. hermes.sh: fresh profile gets the recipe + placeholder rule; stray provider keys are scrubbed; keys
#      reach the client via the environment, never argv; refusals for a form-rewritten config, a key in
#      .env, keyless_fallback true, and a work folder holding the login name
#   5. opencode.sh: env-only safety switches set, gateway /v1 base URL, scrubbed env, work-folder refusal
#   6. openwork lib/config.mjs: no key and no {env:} key reference in the written config, key helper +
#      both instruction files present, tool allow-list; key helper adds keys for the gateway origin ONLY
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/contrib/clients"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/contrib-clients-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

FAKE_LK="lcr_test_FAKEKEY_0123456789abcdef"
FAKE_UK="fake-upstream-key-0123456789abcdef"

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
if python3 -c 'import yaml' 2>/dev/null; then
  if python3 - "$C/hermes/config.yaml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
assert c["web"]["keyless_fallback"] is False, "keyless_fallback"
assert c["web"]["keyless_rescue"] is False, "keyless_rescue"
assert "web" in c["agent"]["disabled_toolsets"], "disabled_toolsets"
assert c["security"]["allow_lazy_installs"] is False, "lazy installs"
assert c["platform_toolsets"]["cli"] == ["file"], "toolsets"
assert c["auxiliary"]["title_generation"]["model_upgrade_enabled"] is False, "title"
p = c["providers"]["lucairn-anthropic"]
assert p["key_env"] == "LUCAIRN_API_KEY" and p["api"] == "${LUCAIRN_GATEWAY_URL}", "provider"
PY
  then ok "hermes recipe: web off, no lazy installs, file tools only, keys by env"; else bad "hermes recipe"; fi
else
  bad "python3 yaml missing (fails closed)"
fi

# ── stub client ──────────────────────────────────────────────────────────────
# Prints its argv and selected environment facts; never the key values themselves.
make_stub() {
  cat > "$1" <<'STUB'
#!/bin/sh
printf 'ARGV:%s\n' "$*"
printf 'HAS_LK:%s\n' "$([ "${LUCAIRN_API_KEY:-}" = "lcr_test_FAKEKEY_0123456789abcdef" ] && echo yes || echo no)"
printf 'HAS_UK:%s\n' "$([ "${LUCAIRN_UPSTREAM_KEY:-}" = "fake-upstream-key-0123456789abcdef" ] && echo yes || echo no)"
printf 'STRAY:%s\n' "${ANTHROPIC_API_KEY:-none}"
printf 'HOME:%s\n' "$HOME"
printf 'PWD:%s\n' "$(pwd -P)"
printf 'BASE_URL:%s\n' "${LUCAIRN_BASE_URL:-}"
printf 'GW:%s\n' "${LUCAIRN_GATEWAY_URL:-}"
printf 'PROJ:%s\n' "${OPENCODE_DISABLE_PROJECT_CONFIG:-}"
printf 'EXTSK:%s\n' "${OPENCODE_DISABLE_EXTERNAL_SKILLS:-}"
printf 'RULES:%s\n' "${LUCAIRN_RULES_FILE:-}"
STUB
  chmod +x "$1"
}
WORK="$TMP/neutral-work"   # TMPDIR paths may hold the login name on some systems; checked below
case "$WORK/" in *"/$(id -un)/"*) WORK="/var/tmp/contrib-clients-test-$$"; mkdir -p "$WORK"; trap 'rm -rf "$TMP" "$WORK"' EXIT ;; esac

# ── 4. hermes.sh ─────────────────────────────────────────────────────────────
HD="$TMP/hermes-install"; mkdir -p "$HD/.venv/bin"
make_stub "$HD/.venv/bin/hermes"
# The venv python of a real install has PyYAML; here the system python3 stands in. hermes.sh calls it
# with -I (isolated), which would hide a user-site PyYAML, so the stand-in drops that one flag.
printf '#!/bin/sh\n[ "$1" = "-I" ] && shift\nexec python3 "$@"\n' > "$HD/.venv/bin/python"; chmod +x "$HD/.venv/bin/python"
HP="$TMP/hermes-profile"
run_h() { env LUCAIRN_HERMES_DIR="$HD" LUCAIRN_HERMES_PROFILE="$HP" LUCAIRN_WORK_DIR="${W:-$WORK}" \
  LUCAIRN_API_KEY="$FAKE_LK" LUCAIRN_UPSTREAM_KEY="$FAKE_UK" ANTHROPIC_API_KEY=stray-should-vanish \
  bash "$C/hermes/hermes.sh" "$@"; }
out="$(run_h -z "hello" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "hermes.sh fresh profile starts" || bad "hermes.sh fresh profile rc=$rc: $out"
cmp -s "$C/hermes/config.yaml" "$HP/hermes-home/config.yaml" && ok "recipe copied into the fresh profile" || bad "recipe not copied"
grep -q "Lucairn privacy placeholders" "$HP/hermes-home/SOUL.md" && ok "placeholder rule in SOUL.md" || bad "placeholder rule missing"
printf '%s\n' "$out" | grep -q '^ARGV:-z hello$' && ok "argv carries no key" || bad "unexpected argv"
printf '%s\n' "$out" | grep -q '^HAS_LK:yes$' && printf '%s\n' "$out" | grep -q '^HAS_UK:yes$' && ok "keys reach hermes via the environment" || bad "keys missing in env"
printf '%s\n' "$out" | grep -q '^STRAY:none$' && ok "stray provider key scrubbed" || bad "stray ANTHROPIC_API_KEY reached hermes"
printf '%s\n' "$out" | grep -q "^HOME:$HP/home$" && ok "HOME is the profile's" || bad "HOME not redirected"
printf '%s\n' "$out" | grep -q '^GW:https://gateway.lucairn.eu$' && ok "default gateway" || bad "gateway url"
if printf '%s' "$out" | grep -q "$FAKE_LK"; then bad "key value printed"; else ok "key value not printed"; fi

sed '/transport: anthropic_messages/d' "$C/hermes/config.yaml" > "$HP/hermes-home/config.yaml"
out="$(run_h -z hi 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q '^ARGV:' && printf '%s' "$out" | grep -q 'transport must be anthropic_messages' && ok "refuses a form-rewritten config (no transport)" || bad "accepted a rewritten config (rc=$rc)"
sed 's/keyless_fallback: false/keyless_fallback: true/' "$C/hermes/config.yaml" > "$HP/hermes-home/config.yaml"
out="$(run_h -z hi 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q '^ARGV:' && printf '%s' "$out" | grep -q 'keyless_fallback must be false' && ok "refuses keyless_fallback true" || bad "accepted keyless_fallback true (rc=$rc)"
run_h --reset-config >/dev/null 2>&1 && cmp -s "$C/hermes/config.yaml" "$HP/hermes-home/config.yaml" && ok "--reset-config restores the recipe" || bad "--reset-config"
printf 'HERMES_CUSTOM_LUCAIRN_ANTHROPIC_API_KEY=abc123typed\n' > "$HP/hermes-home/.env"
out="$(run_h -z hi 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q '^ARGV:' && printf '%s' "$out" | grep -q 'holds a key in clear text' && ok "refuses a key in the profile .env" || bad "accepted a key in .env (rc=$rc)"
rm -f "$HP/hermes-home/.env"
out="$(W="$TMP/x/$(id -un)/proj" run_h -z hi 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q '^ARGV:' && printf '%s' "$out" | grep -q 'contains the account name' && ok "refuses a work folder holding the login name" || bad "accepted a named work folder (rc=$rc)"

# ── 5. opencode.sh ───────────────────────────────────────────────────────────
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=darwin-arm64 ;; Darwin-x86_64) PLAT=darwin-x64 ;;
  Linux-aarch64|Linux-arm64) PLAT=linux-arm64 ;; *) PLAT=linux-x64 ;;
esac
OD="$TMP/opencode-install"; mkdir -p "$OD/node_modules/opencode-$PLAT/bin"
make_stub "$OD/node_modules/opencode-$PLAT/bin/opencode"
run_o() { env LUCAIRN_OPENCODE_DIR="$OD" LUCAIRN_OPENCODE_PROFILE="$TMP/opencode-profile" LUCAIRN_WORK_DIR="${W:-$WORK}" \
  LUCAIRN_API_KEY="$FAKE_LK" LUCAIRN_UPSTREAM_KEY="$FAKE_UK" ANTHROPIC_API_KEY=stray-should-vanish \
  LUCAIRN_GATEWAY_URL=https://gw.example.test bash "$C/opencode/opencode.sh" "$@"; }
out="$(run_o -- --version 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "opencode.sh starts" || bad "opencode.sh rc=$rc: $out"
printf '%s\n' "$out" | grep -q '^BASE_URL:https://gw.example.test/v1$' && ok "opencode base URL = gateway /v1" || bad "opencode base URL"
printf '%s\n' "$out" | grep -q '^PROJ:1$' && printf '%s\n' "$out" | grep -q '^EXTSK:1$' && ok "env-only safety switches set" || bad "safety switches"
printf '%s\n' "$out" | grep -q '^STRAY:none$' && ok "opencode: stray provider key scrubbed" || bad "opencode: stray key reached"
printf '%s\n' "$out" | grep -q '^HAS_LK:yes$' && ok "opencode: key via environment" || bad "opencode: key missing"
rules="$(printf '%s\n' "$out" | sed -n 's/^RULES://p')"; [ -f "$rules" ] && ok "opencode: placeholder rule file exists" || bad "opencode: rule file '$rules'"
grep -q '{env:LUCAIRN_RULES_FILE}' "$C/opencode/config/opencode.json" "$C/opencode/config/opencode-work.json" && ok "configs reference the rule" || bad "configs miss the rule"
out="$(W="$TMP/x/$(id -un)/proj" run_o "hi" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q '^ARGV:' && printf '%s' "$out" | grep -q 'contains the account name' && ok "opencode refuses a named work folder" || bad "opencode accepted a named work folder (rc=$rc)"
if grep -rqE '"(apiKey|X-Upstream-Key)": *"[^{]' "$C/opencode/config/"; then bad "a literal key in an opencode config"; else ok "opencode configs hold env references only"; fi

# ── 6. openwork config writer + key helper ───────────────────────────────────
if command -v node >/dev/null 2>&1; then
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
  node "$C/openwork/lib/config.mjs" "$TMP/ow2.json" "$C/openwork/plugin" model=gpt-x >/dev/null 2>&1 && bad "unknown model accepted" || ok "unknown model refused"
  if LUCAIRN_BASE_URL=https://gw.example.test/v1 LUCAIRN_API_KEY="$FAKE_LK" LUCAIRN_UPSTREAM_KEY="$FAKE_UK" \
     node --input-type=module -e '
const seen = [];
globalThis.fetch = async (input, init) => { seen.push({ url: String(input), h: new Headers(init?.headers) }); return new Response("{}"); };
const { LucairnKeysFromEnv } = await import(process.argv[1]);
await LucairnKeysFromEnv();
await fetch("https://gw.example.test/v1/messages", { headers: { "x-api-key": "not-a-key" } });
await fetch("https://other.example.test/v1/messages", {});
const [g, o] = seen;
const okk = g.h.get("x-api-key") === process.env.LUCAIRN_API_KEY && g.h.get("x-upstream-key") === process.env.LUCAIRN_UPSTREAM_KEY
  && !o.h.get("x-api-key") && !o.h.get("x-upstream-key");
process.exit(okk ? 0 : 1);' "$C/openwork/plugin/lucairn-keys-from-env.js"; then
    ok "key helper: keys on the gateway origin only"
  else bad "key helper headers"; fi
else
  bad "node missing (fails closed)"
fi

[ "$fails" -eq 0 ] || { printf '%s check(s) failed\n' "$fails"; exit 1; }
printf 'all contrib/clients checks passed\n'
