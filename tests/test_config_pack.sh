#!/usr/bin/env bash
# Config pack (PRD 2026-10-02 regulated-buyer path v1, slice S5).
#
# Renders the Claude Code / Claude Desktop config pack through `bin/lucairn
# config-pack`, validates syntax and every key against the committed docs-key
# snapshot, pins the default render to config-pack/golden-sha256.json (the
# lucairn.eu account area pins the same hashes), and proves each check can
# fail: a misspelled key, a credential in a header map, a secret-shaped value,
# a broken .reg / .mobileconfig and a stale golden pin all turn the check red.
# Offline; needs python3 (plutil is used when present).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }
expect_ok() { local what="$1"; shift; if "$@" >"$TMP/out" 2>&1; then ok; else bad "$what"; sed 's/^/    /' "$TMP/out" >&2; fi; }
expect_fail() { local what="$1"; shift; if "$@" >"$TMP/out" 2>&1; then bad "$what (expected a failure)"; else ok; fi; }
expect_grep() { local what="$1" pattern="$2" file="$3"; if grep -q -- "$pattern" "$file"; then ok; else bad "$what"; fi; }
expect_no_grep() { local what="$1" pattern="$2" file="$3"; if grep -q -- "$pattern" "$file"; then bad "$what"; else ok; fi; }

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

GW="https://gateway.lucairn.eu"

# 1. Default render through the CLI, then the full offline check + golden pin.
expect_ok "default render" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/default"
for f in managed-settings.json claude-desktop.mobileconfig claude-desktop.reg SETUP.md; do
  [ -f "$TMP/default/$f" ] && ok || bad "default render missing $f"
done
expect_ok "check --golden" python3 "$ROOT/config-pack/check.py" --dir "$TMP/default" --gateway "$GW" --golden
expect_grep "CC base URL pinned" '"ANTHROPIC_BASE_URL": "https://gateway.lucairn.eu"' "$TMP/default/managed-settings.json"
expect_grep "CC require header" 'x-lucairn-require-added-parts-sanitized: 1' "$TMP/default/managed-settings.json"
expect_grep "CC git instructions off" '"CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS": "1"' "$TMP/default/managed-settings.json"
expect_grep "CC auto mode off" '"disableAutoMode": "disable"' "$TMP/default/managed-settings.json"
expect_no_grep "CC has no apiKeyHelper by default" 'apiKeyHelper' "$TMP/default/managed-settings.json"
expect_grep "Desktop key slot is a placeholder" 'REPLACE_WITH_YOUR_LUCAIRN_KEY' "$TMP/default/claude-desktop.mobileconfig"
expect_no_grep "no Lucairn key in any file" 'lcr_live_' "$TMP/default/managed-settings.json"
if command -v plutil >/dev/null 2>&1; then
  expect_ok "plutil -lint" plutil -lint "$TMP/default/claude-desktop.mobileconfig"
fi

# 2. Overwrite protection, and a self-hosted gateway with a port and path.
expect_fail "refuses to overwrite without --force" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/default"
expect_ok "self-hosted gateway URL" "$ROOT/bin/lucairn" config-pack --gateway "https://llm.corp.example:8443/lucairn/" --output "$TMP/selfhosted"
expect_grep "trailing slash dropped" '"ANTHROPIC_BASE_URL": "https://llm.corp.example:8443/lucairn"' "$TMP/selfhosted/managed-settings.json"
expect_grep "SETUP names the host" 'llm.corp.example:8443' "$TMP/selfhosted/SETUP.md"

# 3. Optional inputs: helpers replace the static key slot; models and proxy added.
expect_ok "render with options" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/opts" \
  --models "model-a,model-b" --egress-proxy "http://proxy.corp.example:3128" \
  --key-helper "/usr/local/bin/lucairn-key" \
  --desktop-key-helper "/usr/local/bin/lucairn-key" \
  --desktop-key-helper-windows 'C:\Program Files\Lucairn\lucairn-key.exe'
expect_grep "CC apiKeyHelper set" '"apiKeyHelper": "/usr/local/bin/lucairn-key"' "$TMP/opts/managed-settings.json"
expect_no_grep "helper removes the static key slot" 'inferenceGatewayApiKey' "$TMP/opts/claude-desktop.mobileconfig"
expect_grep "helper kind" '"inferenceCredentialKind"="helper-script"' "$TMP/opts/claude-desktop.reg"
expect_grep "windows helper escaped" '"inferenceCredentialHelperWindows"="C:\\\\Program Files\\\\Lucairn\\\\lucairn-key.exe"' "$TMP/opts/claude-desktop.reg"
expect_grep "models JSON string" '"inferenceModels"="\[\\"model-a\\",\\"model-b\\"\]"' "$TMP/opts/claude-desktop.reg"
expect_grep "egress proxy" '<string>http://proxy.corp.example:3128</string>' "$TMP/opts/claude-desktop.mobileconfig"
expect_fail "windows helper alone is refused" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/opts2" \
  --desktop-key-helper-windows 'C:\x\y.exe'

# 4. Gateway URLs the pack must refuse.
for bad_url in "http://gateway.example.com" "https://user@gateway.example.com" "https://gateway.example.com/?a=b" \
  "https://gateway.example.com/#x" 'https://gateway.example.com/"' "https://gate way.example.com" \
  "https://a..b" "https://.example.com" "https://gateway.example.com:99999" "https://gateway.example.com:0" \
  "https://-" "https://a-.example.com" "" "gateway.example.com" \
  "$(printf 'https://gateway.example.com\n/x')"; do
  expect_fail "refuses gateway [$bad_url]" "$ROOT/bin/lucairn" config-pack --gateway "$bad_url" --output "$TMP/badurl"
done
[ ! -e "$TMP/badurl" ] && ok || bad "a refused URL still wrote files"
"$ROOT/bin/lucairn" config-pack --gateway "https://gateway.example.com:99999" --output "$TMP/badurl" >"$TMP/port.out" 2>&1 || true
expect_grep "bad port gives the clean error" 'error: gateway URL has an invalid port' "$TMP/port.out"
expect_no_grep "bad port gives no traceback" 'Traceback' "$TMP/port.out"
expect_fail "refuses a model id with a quote" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/badmodel" --models 'a",b'

# 5. Red-proofs: each check must be able to fail. Mutate a private copy of the
#    pack sources, then run that copy's checker.
mutant() {
  local name="$1"
  rm -rf "$TMP/m-$name"
  cp -R "$ROOT/config-pack" "$TMP/m-$name"
  echo "$TMP/m-$name"
}
edit_spec() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
spec = json.load(open(path))
cc = spec["claude_code"]["managed_settings"]
keys = spec["claude_desktop"]["keys"]
if mode == "cc-misspelled":
    cc["skipWebFetchPrefligh"] = cc.pop("skipWebFetchPreflight")
elif mode == "cc-env-misspelled":
    cc["env"]["CLAUDE_CODE_DISABLE_GIT_INSTRUCTION"] = cc["env"].pop("CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS")
elif mode == "cc-permissions-misspelled":
    cc["permissions"]["blockReadsOutsideWorkingDirectory"] = cc["permissions"].pop("blockReadsOutsideWorkingDirectories")
elif mode == "desktop-misspelled":
    keys[[k for k, _ in keys].index("disableDeploymentModeChooser")][0] = "disableDeploymentModeChoser"
elif mode == "desktop-credential-header":
    keys[[k for k, _ in keys].index("inferenceCustomHeaders")][1]["x-api-key"] = "placeholder"
elif mode == "cc-credential-header":
    cc["env"]["ANTHROPIC_CUSTOM_HEADERS"] += "\nX-DSA-Key: placeholder"
elif mode == "secret-value":
    keys[[k for k, _ in keys].index("inferenceGatewayApiKey")][1] = "lcr_live_" + "a" * 24
elif mode == "no-require-header":
    cc["env"]["ANTHROPIC_CUSTOM_HEADERS"] = "x-tenant: acme"
elif mode == "guard-option-misspelled":
    cc["pluginConfigs"]["cc-plugin-sec-default@builtin"]["options"] = {"allowManagedModOnly": True}
else:
    raise SystemExit("unknown mode " + mode)
json.dump(spec, open(path, "w"), indent=2)
PY
}
for mode in cc-misspelled cc-env-misspelled cc-permissions-misspelled desktop-misspelled desktop-credential-header \
  cc-credential-header secret-value no-require-header guard-option-misspelled; do
  dir="$(mutant "$mode")"
  edit_spec "$dir/spec.json" "$mode"
  expect_fail "red-proof: $mode is caught" python3 "$dir/check.py"
done

# A stale golden pin (template edited without regenerating) must fail --golden.
dir="$(mutant golden)"
printf '\nedited\n' >> "$dir/SETUP.md.tmpl"
expect_fail "red-proof: stale golden pin is caught" python3 "$dir/check.py" --golden

# Broken output files must fail the directory check.
cp -R "$TMP/default" "$TMP/lf"
python3 -c "import sys; p=sys.argv[1]; d=open(p,'rb').read().replace(b'\r\n', b'\n'); open(p,'wb').write(d)" "$TMP/lf/claude-desktop.reg"
expect_fail "red-proof: LF-only .reg is caught" python3 "$ROOT/config-pack/check.py" --dir "$TMP/lf" --gateway "$GW"
cp -R "$TMP/default" "$TMP/trunc"
head -c 400 "$TMP/default/claude-desktop.mobileconfig" > "$TMP/trunc/claude-desktop.mobileconfig"
expect_fail "red-proof: truncated .mobileconfig is caught" python3 "$ROOT/config-pack/check.py" --dir "$TMP/trunc" --gateway "$GW"
cp -R "$TMP/default" "$TMP/drift"
python3 -c "import sys; p=sys.argv[1]; d=open(p,newline='').read().replace('\"autoModeEnabled\"=\"false\"','\"autoModeEnabled\"=\"true\"'); open(p,'w',newline='').write(d)" "$TMP/drift/claude-desktop.reg"
expect_fail "red-proof: .reg/.mobileconfig drift is caught" python3 "$ROOT/config-pack/check.py" --dir "$TMP/drift" --gateway "$GW"
cp -R "$TMP/default" "$TMP/dupe"
python3 -c "import sys; p=sys.argv[1]; d=open(p).read().replace('{\n  \"env\"', '{\n  \"allowedProviders\": [\"anthropic\"],\n  \"env\"',1); open(p,'w').write(d)" "$TMP/dupe/managed-settings.json"
expect_fail "red-proof: duplicate JSON key is caught" python3 "$ROOT/config-pack/check.py" --dir "$TMP/dupe" --gateway "$GW"
expect_fail "red-proof: wrong gateway is caught" python3 "$ROOT/config-pack/check.py" --dir "$TMP/default" --gateway "https://other.example.com"

echo "config-pack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
