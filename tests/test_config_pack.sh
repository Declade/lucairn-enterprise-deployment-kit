#!/usr/bin/env bash
# Config pack (PRD 2026-10-02 regulated-buyer path v1, slice S5).
#
# Renders the Claude Code / Claude Desktop config pack through `bin/lucairn
# config-pack`, validates syntax and every key against the committed docs-key
# snapshot, pins the default render to config-pack/golden-sha256.json and the
# hostile-but-accepted URL corpus to config-pack/parity-corpus.json (the
# lucairn.eu account area pins the same hashes), and proves each check can
# fail: misspelled keys, weakened policy values (read denies, locks, mods
# option nesting/type, telemetry, version floor, require header), credentials
# in header maps, secret-shaped inputs and values, duplicate keys in every
# format, broken .reg / .mobileconfig files, a tampered pack under --golden,
# user-writable helper paths and bad proxy URLs all turn the check red.
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
expect_fail_msg() { local what="$1" msg="$2"; shift 2; if "$@" >"$TMP/out" 2>&1; then bad "$what (expected a failure)"; elif grep -qF -- "$msg" "$TMP/out"; then ok; else bad "$what (failed, but not with: $msg)"; sed 's/^/    /' "$TMP/out" >&2; fi; }
expect_grep() { local what="$1" pattern="$2" file="$3"; if grep -q -- "$pattern" "$file"; then ok; else bad "$what"; fi; }
expect_no_grep() { local what="$1" pattern="$2" file="$3"; if grep -q -- "$pattern" "$file"; then bad "$what"; else ok; fi; }

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

GW="https://gateway.lucairn.eu"

# 1. Default render through the CLI, then the full offline check + golden pin.
expect_ok "default render" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/default"
for f in managed-settings.json claude-desktop.mobileconfig claude-desktop.reg SETUP.md; do
  [ -f "$TMP/default/$f" ] && ok || bad "default render missing $f"
done
expect_ok "check --golden --corpus" python3 "$ROOT/config-pack/check.py" --dir "$TMP/default" --gateway "$GW" --golden --corpus
expect_grep "CC version floor" '"requiredMinimumVersion": "2.1.285"' "$TMP/default/managed-settings.json"
expect_grep "CC root-anchored .env deny" '"Read(//\*\*/.env)"' "$TMP/default/managed-settings.json"
expect_no_grep "no cwd-relative credential deny" '"Read(\*\*/' "$TMP/default/managed-settings.json"
expect_grep "SETUP firewall names port 443" 'TCP port 443 (HTTPS)' "$TMP/default/SETUP.md"
expect_no_grep "SETUP no longer calls the version floor optional" 'you can add `"requiredMinimumVersion"' "$TMP/default/SETUP.md"
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
expect_grep "SETUP firewall renders the effective port" '`llm.corp.example`, TCP port 8443 (HTTPS)' "$TMP/selfhosted/SETUP.md"
expect_no_grep "SETUP firewall does not claim port 443 for a custom port" 'TCP port 443' "$TMP/selfhosted/SETUP.md"
expect_ok "explicit :443 accepted" "$ROOT/bin/lucairn" config-pack --gateway "https://gw.example.com:443/" --output "$TMP/p443"
expect_grep "explicit :443 dropped" '"ANTHROPIC_BASE_URL": "https://gw.example.com"' "$TMP/p443/managed-settings.json"

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
expect_ok "check accepts the options pack" python3 "$ROOT/config-pack/check.py" --dir "$TMP/opts" --gateway "$GW"
expect_fail "windows helper alone is refused" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/opts2" \
  --desktop-key-helper-windows 'C:\Program Files\Lucairn\k.exe'
[ ! -e "$TMP/opts2" ] && ok || bad "a refused option still wrote files"

# 3b. Claude Desktop helper paths: only absolute paths under roots that only
#     administrators can write (a helper's headers win over the profile's).
for bad_helper in "~/bin/lucairn-key" "bin/lucairn-key" "./lucairn-key" "/Users/alice/lucairn-key" \
  "/home/alice/lucairn-key" "/tmp/lucairn-key" "/opt/../Users/alice/lucairn-key" "/opt/./lucairn-key" \
  "/opt//lucairn-key" "/opt/" "/opt/homebrew/bin/lucairn-key" "/usr/local/Homebrew/bin/k" \
  '/opt/lucairn"key' "/Library/Lucairn/key\\x" "$(printf '/opt/lucairn\nkey')"; do
  expect_fail "refuses desktop helper [$bad_helper]" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/badhelper" \
    --desktop-key-helper "$bad_helper"
done
for bad_win in 'C:\Users\alice\lucairn-key.exe' 'C:/Program Files/Lucairn/k.exe' 'D:\Program Files\Lucairn\k.exe' \
  'C:\Program Files\..\Users\alice\k.exe' 'C:\Program Files\Lucairn.\k.exe' 'C:\Program Files\Lucairn \k.exe' \
  'C:\PROGRA~1\Lucairn\k.exe' 'C:\Program Files\Lucairn\k.exe::$DATA' 'Program Files\k.exe' 'C:\Program Files\\k.exe'; do
  expect_fail "refuses windows helper [$bad_win]" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/badhelper" \
    --desktop-key-helper "/Library/Lucairn/lucairn-key" --desktop-key-helper-windows "$bad_win"
done
expect_ok "accepts helpers under the admin roots" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/helperok" \
  --desktop-key-helper "/Library/Application Support/Lucairn/lucairn-key" \
  --desktop-key-helper-windows 'C:\Program Files (x86)\Lucairn\lucairn-key.exe'
[ ! -e "$TMP/badhelper" ] && ok || bad "a refused helper still wrote files"
"$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/badhelper" --desktop-key-helper "/Users/alice/very-private-helper-name" >"$TMP/helper.out" 2>&1 || true
expect_no_grep "refused helper path is not echoed" 'very-private-helper-name' "$TMP/helper.out"
expect_grep "refusal names the redacted length" '<redacted>, 37 characters' "$TMP/helper.out"

# 3c. Proxy URLs: valid host name, port 1-65535, no user info or path.
for bad_proxy in "http://a..b:99999" "http://proxy.corp.example:0" "http://proxy.corp.example:08080" \
  "http://proxy.corp.example:65536" "http://user:pw@proxy.corp.example:8080" "socks5://proxy.corp.example:1080" \
  "http://proxy.corp.example:3128/path" "http://proxy.corp.example.:3128" "ftp://proxy.corp.example" \
  "http://-proxy:3128" "http://1.2.3:3128" "http://proxy corp:3128"; do
  expect_fail "refuses proxy [$bad_proxy]" "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/badproxy" \
    --egress-proxy "$bad_proxy"
done
[ ! -e "$TMP/badproxy" ] && ok || bad "a refused proxy still wrote files"

# 3d. Secret-shaped inputs are refused before anything is written, and the
#     value is never echoed.
for flag_value in "--key-helper=printf lcr_live_abcdefghij" "--models=sk-ant-api03-abcdefghij" \
  "--gateway=https://gw.example.com/lcr_live_abcdefghij"; do
  rm -rf "$TMP/secretin"
  if "$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/secretin" "$flag_value" >"$TMP/secret.out" 2>&1; then
    bad "secret-shaped input accepted [${flag_value%%=*}]"
  else
    ok
  fi
  [ ! -e "$TMP/secretin" ] && ok || bad "secret-shaped input still wrote files [${flag_value%%=*}]"
  expect_no_grep "secret-shaped input not echoed [${flag_value%%=*}]" 'abcdefghij' "$TMP/secret.out"
done
"$ROOT/bin/lucairn" config-pack --gateway "$GW" --output "$TMP/badmodel" --models 'model-one,private"value' >"$TMP/model.out" 2>&1 || true
expect_no_grep "refused model id is not echoed" 'private' "$TMP/model.out"
expect_fail_msg "red-proof: .reg escaping refuses CR/LF on its own" "refusing to write a control" \
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import render; render._reg_escape("a\r\nb")' "$ROOT/config-pack"
expect_fail_msg "red-proof: .mobileconfig refuses a control character on its own" "refusing to write a control" \
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import render as R; s=R.load_spec(); R.render_mobileconfig(s, {}, [("k", "a\nb")])' "$ROOT/config-pack"
expect_fail_msg "red-proof: empty Desktop settings are refused" "no Claude Desktop settings" \
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import render as R; s=R.load_spec(); R.render_mobileconfig(s, {}, [])' "$ROOT/config-pack"

# 4. Gateway URLs the pack must refuse.
for bad_url in "http://gateway.example.com" "https://user@gateway.example.com" "https://gateway.example.com/?a=b" \
  "https://gateway.example.com/#x" 'https://gateway.example.com/"' "https://gate way.example.com" \
  "https://a..b" "https://.example.com" "https://gateway.example.com:99999" "https://gateway.example.com:0" \
  "https://-" "https://a-.example.com" "" "gateway.example.com" \
  "$(printf 'https://gateway.example.com\n/x')" "https://gateway.example.com:0443" "https://gateway.example.com/a/../b" \
  "https://gateway.example.com." 'https://gateway.example.com\x' "https://gateway.example.com/%2e%2e/" \
  "$(printf 'https://b\303\274cher.example')" "https://0x7f.1" "$(printf '\302\240https://gateway.example.com')"; do
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
elif mode == "deny-removed":
    cc["permissions"]["deny"].remove("Read(//**/.env)")
elif mode == "deny-cwd-relative":
    d = cc["permissions"]["deny"]
    d[d.index("Read(//**/.env)")] = "Read(**/.env)"
elif mode == "read-block-off":
    cc["permissions"]["blockReadsOutsideWorkingDirectories"] = False
elif mode == "default-mode-bypass":
    cc["permissions"]["defaultMode"] = "bypassPermissions"
elif mode == "hooks-lock-off":
    cc["allowManagedHooksOnly"] = False
elif mode == "mcp-lock-off":
    cc["allowManagedMcpServersOnly"] = False
elif mode == "mcp-lock-removed":
    del cc["allowManagedMcpServersOnly"]
elif mode == "sideload-lock-string":
    cc["disableSideloadFlags"] = "true"
elif mode == "mods-string-false":
    cc["pluginConfigs"]["cc-plugin-sec-default@builtin"]["options"]["allowManagedModsOnly"] = "false"
elif mode == "mods-string-true":
    cc["pluginConfigs"]["cc-plugin-sec-default@builtin"]["options"]["allowManagedModsOnly"] = "true"
elif mode == "mods-wrong-nesting":
    cc["pluginConfigs"]["cc-plugin-sec-default@builtin"] = {"allowManagedModsOnly": True}
elif mode == "telemetry-removed":
    del cc["env"]["DISABLE_TELEMETRY"]
elif mode == "telemetry-zero":
    cc["env"]["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "0"
elif mode == "auto-memory-on":
    cc["autoMemoryEnabled"] = True
elif mode == "require-header-conflict":
    cc["env"]["ANTHROPIC_CUSTOM_HEADERS"] += "\nx-lucairn-require-added-parts-sanitized: 0"
elif mode == "require-header-twice":
    cc["env"]["ANTHROPIC_CUSTOM_HEADERS"] += "\nX-Lucairn-Require-Added-Parts-Sanitized: 1"
elif mode == "require-header-value":
    cc["env"]["ANTHROPIC_CUSTOM_HEADERS"] = "x-lucairn-require-added-parts-sanitized: true"
elif mode == "version-floor-removed":
    del cc["requiredMinimumVersion"]
elif mode == "version-floor-low":
    cc["requiredMinimumVersion"] = "2.1.200"
elif mode == "version-floor-invalid":
    cc["requiredMinimumVersion"] = "latest"
elif mode == "providers-widened":
    cc["allowedProviders"] = ["customEndpoint", "anthropic"]
elif mode == "desktop-header-conflict":
    keys[[k for k, _ in keys].index("inferenceCustomHeaders")][1]["X-Lucairn-Require-Added-Parts-Sanitized"] = "0"
elif mode == "desktop-header-value":
    keys[[k for k, _ in keys].index("inferenceCustomHeaders")][1]["x-lucairn-require-added-parts-sanitized"] = "0"
elif mode == "desktop-telemetry-on":
    keys[[k for k, _ in keys].index("disableNonessentialTelemetry")][1] = False
elif mode == "desktop-chooser-removed":
    del keys[[k for k, _ in keys].index("disableDeploymentModeChooser")]
elif mode == "desktop-skills-on":
    keys[[k for k, _ in keys].index("skillCreationEnabled")][1] = True
else:
    raise SystemExit("unknown mode " + mode)
json.dump(spec, open(path, "w"), indent=2)
PY
}
for mode in cc-misspelled cc-env-misspelled cc-permissions-misspelled desktop-misspelled desktop-credential-header \
  cc-credential-header secret-value no-require-header guard-option-misspelled \
  deny-removed deny-cwd-relative read-block-off default-mode-bypass hooks-lock-off mcp-lock-off mcp-lock-removed \
  sideload-lock-string mods-string-false mods-string-true mods-wrong-nesting telemetry-removed telemetry-zero \
  auto-memory-on require-header-conflict require-header-twice require-header-value version-floor-removed \
  version-floor-low version-floor-invalid providers-widened desktop-header-conflict desktop-header-value \
  desktop-telemetry-on desktop-chooser-removed desktop-skills-on; do
  dir="$(mutant "$mode")"
  edit_spec "$dir/spec.json" "$mode"
  expect_fail "red-proof: $mode is caught" python3 "$dir/check.py"
done

# A pack that fails its own check is never written: render a weakened spec
# through that copy's renderer and confirm nothing reached --output.
dir="$(mutant prewrite)"
edit_spec "$dir/spec.json" deny-removed
expect_fail "weakened pack is refused by render.py" python3 "$dir/render.py" --gateway "$GW" --output "$TMP/prewrite"
[ ! -e "$TMP/prewrite" ] && ok || bad "a pack that failed its check was still written"

# Corpus: a changed hash, or a refused URL that became accepted, turns
# --corpus red.
dir="$(mutant corpus-hash)"
python3 -c 'import json, sys; p = sys.argv[1]; c = json.load(open(p)); c["accepted"][2]["files"]["SETUP.md"] = "0" * 64; json.dump(c, open(p, "w"), indent=2)' "$dir/parity-corpus.json"
expect_fail_msg "red-proof: corpus hash drift is caught" "corpus: SETUP.md changed" python3 "$dir/check.py" --corpus
dir="$(mutant corpus-refused)"
python3 -c 'import json, sys; p = sys.argv[1]; c = json.load(open(p)); c["refused"].append({"why": "planted: a valid URL marked refused", "input": "https://planted.example.com"}); json.dump(c, open(p, "w"), indent=2)' "$dir/parity-corpus.json"
expect_fail_msg "red-proof: corpus accept/refuse drift is caught" "refused case is accepted: planted" python3 "$dir/check.py" --corpus

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

# --golden hashes the SUPPLIED files: an edit that every other check accepts
# (an extra line in SETUP.md) must fail it.
cp -R "$TMP/default" "$TMP/tamper"
printf '\nAn extra line.\n' >> "$TMP/tamper/SETUP.md"
expect_ok "tampered SETUP.md passes the content checks" python3 "$ROOT/config-pack/check.py" --dir "$TMP/tamper" --gateway "$GW"
expect_fail_msg "red-proof: --dir --golden hashes the supplied files" "golden mismatch for SETUP.md" \
  python3 "$ROOT/config-pack/check.py" --dir "$TMP/tamper" --gateway "$GW" --golden
expect_fail_msg "red-proof: --golden refuses a non-default gateway pack" "pins the default gateway only" \
  python3 "$ROOT/config-pack/check.py" --dir "$TMP/selfhosted" --gateway "https://llm.corp.example:8443/lucairn" --golden

# Duplicate keys, each with the SAME value so only the duplicate check sees it.
mutate_file() {
  # mutate_file FILE PYTHON-EXPRESSION-OVER-d (text, newlines kept as-is)
  python3 -c 'import sys; p, expr = sys.argv[1], sys.argv[2]; d = open(p, newline="").read(); n = eval(expr); assert n != d, "mutation did not apply"; open(p, "w", newline="").write(n)' "$1" "$2"
}
cp -R "$TMP/default" "$TMP/dupe-plist"
mutate_file "$TMP/dupe-plist/claude-desktop.mobileconfig" \
  'd.replace("<key>autoModeEnabled</key>\n", "<key>autoModeEnabled</key>\n\t\t\t\t\t\t\t\t<string>false</string>\n\t\t\t\t\t\t\t\t<key>autoModeEnabled</key>\n", 1)'
expect_fail_msg "red-proof: duplicate plist key is caught (raw XML)" "duplicate keys in one <dict>" \
  python3 "$ROOT/config-pack/check.py" --dir "$TMP/dupe-plist" --gateway "$GW"
cp -R "$TMP/default" "$TMP/dupe-nested"
mutate_file "$TMP/dupe-nested/managed-settings.json" \
  'd.replace("\"defaultMode\": \"default\",", "\"defaultMode\": \"default\",\n    \"defaultMode\": \"default\",", 1)'
expect_fail_msg "red-proof: nested duplicate JSON key is caught" "duplicate keys" \
  python3 "$ROOT/config-pack/check.py" --dir "$TMP/dupe-nested" --gateway "$GW"
cp -R "$TMP/default" "$TMP/dupe-reg"
mutate_file "$TMP/dupe-reg/claude-desktop.reg" \
  'd.replace("\"autoModeEnabled\"=\"false\"\r\n", "\"autoModeEnabled\"=\"false\"\r\n\"AutoModeEnabled\"=\"false\"\r\n", 1)'
expect_fail_msg "red-proof: case-variant duplicate .reg value is caught" "registry names ignore case" \
  python3 "$ROOT/config-pack/check.py" --dir "$TMP/dupe-reg" --gateway "$GW"
cp -R "$TMP/default" "$TMP/reg-escape"
mutate_file "$TMP/reg-escape/claude-desktop.reg" \
  'd.replace("\"inferenceProvider\"=\"gateway\"", "\"inferenceProvider\"=\"gate\\way\"", 1)'
expect_fail_msg "red-proof: an unknown .reg escape is malformed" "malformed line" \
  python3 "$ROOT/config-pack/check.py" --dir "$TMP/reg-escape" --gateway "$GW"
cp -R "$TMP/default" "$TMP/reg-cr"
mutate_file "$TMP/reg-cr/claude-desktop.reg" \
  'd.replace("\"inferenceProvider\"=\"gateway\"\r\n", "\"inferenceProvider\"=\"gate\rway\"\r\n", 1)'
expect_fail_msg "red-proof: a bare CR inside a .reg line is caught" "every line must end in CRLF" \
  python3 "$ROOT/config-pack/check.py" --dir "$TMP/reg-cr" --gateway "$GW"

# Empty payloads are hard failures.
for which in outer inner; do
  cp -R "$TMP/default" "$TMP/empty-$which"
  python3 -c 'import plistlib, sys
p, which = sys.argv[1], sys.argv[2]
d = plistlib.loads(open(p, "rb").read())
if which == "outer":
    d["PayloadContent"] = []
else:
    d["PayloadContent"][0]["PayloadContent"] = {}
open(p, "wb").write(plistlib.dumps(d))' "$TMP/empty-$which/claude-desktop.mobileconfig" "$which"
  expect_fail_msg "red-proof: empty $which PayloadContent is caught" "PayloadContent must hold exactly" \
    python3 "$ROOT/config-pack/check.py" --dir "$TMP/empty-$which" --gateway "$GW"
done

# A hand-edited pack: helper moved to a user folder, proxy port out of range,
# firewall port changed.
cp -R "$TMP/opts" "$TMP/userhelper"
for f in claude-desktop.mobileconfig claude-desktop.reg; do
  mutate_file "$TMP/userhelper/$f" 'd.replace("/usr/local/bin/lucairn-key", "/Users/alice/lucairn-key")'
done
expect_fail_msg "red-proof: user-writable helper in a pack is caught" "inferenceCredentialHelper must be an absolute path" \
  python3 "$ROOT/config-pack/check.py" --dir "$TMP/userhelper" --gateway "$GW"
cp -R "$TMP/opts" "$TMP/badport"
for f in claude-desktop.mobileconfig claude-desktop.reg; do
  mutate_file "$TMP/badport/$f" 'd.replace("proxy.corp.example:3128", "proxy.corp.example:99999")'
done
expect_fail_msg "red-proof: bad proxy port in a pack is caught" "egressProxyUrl must be" \
  python3 "$ROOT/config-pack/check.py" --dir "$TMP/badport" --gateway "$GW"
cp -R "$TMP/default" "$TMP/firewall"
mutate_file "$TMP/firewall/SETUP.md" 'd.replace("TCP port 443", "TCP port 8443")'
expect_fail_msg "red-proof: SETUP firewall port drift is caught" "firewall note does not name" \
  python3 "$ROOT/config-pack/check.py" --dir "$TMP/firewall" --gateway "$GW"

echo "config-pack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
