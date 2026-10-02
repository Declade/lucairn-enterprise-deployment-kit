#!/usr/bin/env python3
"""Validate a rendered Lucairn config pack (offline).

Checks, for the files in --dir (or a fresh render when --dir is omitted):

  1. Syntax: managed-settings.json is JSON with no duplicate keys; the
     .mobileconfig parses as a property list (and passes `plutil -lint` when
     plutil exists); the .reg file has the version-5 header, CRLF line endings,
     ASCII only, one policy key and well-formed "name"="value" lines.
  2. Docs keys: every key the pack writes appears in
     config-pack/docs-keys-snapshot.json (the vendor docs key lists, with the
     URL and date they were fetched).
  3. Contract: the gateway URL is the same in both tools; the require header is
     present in both; Claude Desktop values are all strings; JSON-in-string
     values parse; the .mobileconfig and .reg carry the same key/value set; no
     credential sits in a header map; no file contains a Lucairn or provider
     key.
  4. --golden: a default render for the spec's default gateway matches
     config-pack/golden-sha256.json byte for byte (the website renderer pins
     the same hashes).

Exit code 0 when every check passes, 1 otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import render as R  # noqa: E402

SNAPSHOT_PATH = HERE / "docs-keys-snapshot.json"
GOLDEN_PATH = HERE / "golden-sha256.json"

# Header names that carry credentials. None may appear in a static header map.
CREDENTIAL_HEADERS = {"authorization", "x-api-key", "x-dsa-key", "x-upstream-key", "proxy-authorization"}
# Shapes of real secrets that must never be in a rendered file.
SECRET_PATTERNS = [
    re.compile(r"lcr_live_[A-Za-z0-9]"),
    re.compile(r"\bdsa_[A-Za-z0-9]{8,}"),
    re.compile(r"sk-ant-[A-Za-z0-9]"),
    re.compile(r"\bsk-[A-Za-z0-9]{20,}"),
]
REG_HEADER = "Windows Registry Editor Version 5.00"
REG_LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"="((?:[^"\\]|\\.)*)"$')


class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.passes = 0

    def ok(self, cond: bool, what: str) -> None:
        if cond:
            self.passes += 1
        else:
            self.failures.append(what)
            print(f"FAIL: {what}")


def _no_dupes(pairs):
    keys = [k for k, _ in pairs]
    dupes = {k for k in keys if keys.count(k) > 1}
    if dupes:
        raise ValueError(f"duplicate JSON keys: {sorted(dupes)}")
    return dict(pairs)


def _reg_unescape(value: str) -> str:
    return re.sub(r"\\(.)", r"\1", value)


def snapshot_keys() -> dict[str, set[str]]:
    data = json.loads(SNAPSHOT_PATH.read_text(encoding="utf-8"))
    return {name: set(src["keys"]) for name, src in data["sources"].items()}


def claude_code_key_paths(settings: dict) -> list[str]:
    """Settings keys as the settings reference names them: top level, and the
    `permissions.*` children the reference documents as dotted names."""
    paths = []
    for key, value in settings.items():
        paths.append(key)
        if key == "permissions" and isinstance(value, dict):
            paths.extend(f"permissions.{child}" for child in value)
    return paths


def check_claude_code(rep: Report, path: Path, keys: dict, gateway: str, spec: dict) -> dict:
    raw = path.read_bytes()
    try:
        settings = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_dupes)
    except (ValueError, UnicodeDecodeError) as exc:
        rep.ok(False, f"{path.name}: not valid JSON ({exc})")
        return {}
    rep.ok(isinstance(settings, dict), f"{path.name}: top level is an object")
    for kp in claude_code_key_paths(settings):
        rep.ok(kp in keys["claude_code_settings"], f"{path.name}: key `{kp}` not in the settings-reference snapshot")
    env = settings.get("env", {})
    for var in env:
        rep.ok(var in keys["claude_code_env_vars"], f"{path.name}: env var `{var}` not in the env-vars snapshot")
        rep.ok(isinstance(env[var], str), f"{path.name}: env `{var}` must be a string")
    for plugin_id, cfg in settings.get("pluginConfigs", {}).items():
        rep.ok(plugin_id in keys["claude_code_mods_guard"], f"{path.name}: pluginConfigs id `{plugin_id}` not in the mods-admin snapshot")
        for opt in (cfg.get("options") or {}):
            rep.ok(opt in keys["claude_code_mods_guard"], f"{path.name}: guard option `{opt}` not in the mods-admin snapshot")
    rep.ok(env.get("ANTHROPIC_BASE_URL") == gateway, f"{path.name}: ANTHROPIC_BASE_URL is not {gateway}")
    rep.ok(settings.get("allowedProviders") == ["customEndpoint"], f"{path.name}: allowedProviders must be exactly [\"customEndpoint\"]")
    req = spec["require_header"]
    headers = [h.strip() for h in env.get("ANTHROPIC_CUSTOM_HEADERS", "").split("\n") if h.strip()]
    rep.ok(f"{req['name']}: {req['value']}" in headers, f"{path.name}: require header missing from ANTHROPIC_CUSTOM_HEADERS")
    for h in headers:
        name = h.split(":", 1)[0].strip().lower()
        rep.ok(name not in CREDENTIAL_HEADERS, f"{path.name}: credential header `{name}` in ANTHROPIC_CUSTOM_HEADERS")
    for forbidden in ("forceLoginMethod", "forceLoginOrgUUID", "forceLoginGatewayUrl", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"):
        rep.ok(forbidden not in settings and forbidden not in env, f"{path.name}: `{forbidden}` must not be set")
    rep.ok(settings.get("disableAutoMode") == "disable", f"{path.name}: disableAutoMode must be \"disable\"")
    rep.ok(env.get("CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS") == "1", f"{path.name}: CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS must be \"1\"")
    return settings


def check_mobileconfig(rep: Report, path: Path, keys: dict, spec: dict) -> dict:
    raw = path.read_bytes()
    try:
        plist = plistlib.loads(raw)
    except Exception as exc:  # plistlib raises several exception types
        rep.ok(False, f"{path.name}: not a valid property list ({exc})")
        return {}
    if shutil.which("plutil"):
        res = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
        rep.ok(res.returncode == 0, f"{path.name}: plutil -lint failed: {res.stdout.strip()} {res.stderr.strip()}")
    rep.ok(plist.get("PayloadType") == "Configuration", f"{path.name}: outer PayloadType must be Configuration")
    content = plist.get("PayloadContent") or []
    rep.ok(len(content) == 1, f"{path.name}: expected exactly one payload")
    if not content:
        return {}
    payload = content[0]
    rep.ok(payload.get("PayloadType") == "com.apple.ManagedClient.preferences", f"{path.name}: payload type must be com.apple.ManagedClient.preferences")
    domain = spec["claude_desktop"]["preference_domain"]
    forced = (payload.get("PayloadContent") or {}).get(domain, {}).get("Forced") or []
    rep.ok(len(forced) == 1, f"{path.name}: expected one Forced entry under {domain}")
    prefs = (forced[0] if forced else {}).get("mcx_preference_settings") or {}
    rep.ok(bool(prefs), f"{path.name}: no preference settings found")
    for key, value in prefs.items():
        rep.ok(key in keys["claude_desktop_config"], f"{path.name}: key `{key}` not in the Claude Desktop configuration snapshot")
        rep.ok(isinstance(value, str), f"{path.name}: `{key}` must be written as a string")
    return prefs


def check_reg(rep: Report, path: Path, keys: dict, spec: dict) -> dict:
    raw = path.read_bytes()
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        rep.ok(False, f"{path.name}: must be ASCII")
        return {}
    rep.ok("\n" not in text.replace("\r\n", ""), f"{path.name}: every line must end in CRLF")
    lines = text.split("\r\n")
    rep.ok(lines[0] == REG_HEADER, f"{path.name}: first line must be `{REG_HEADER}`")
    sections = [ln for ln in lines if ln.startswith("[")]
    rep.ok(sections == [f"[{spec['claude_desktop']['registry_key']}]"], f"{path.name}: expected exactly one key [{spec['claude_desktop']['registry_key']}]")
    values: dict[str, str] = {}
    in_section = False
    for ln in lines[1:]:
        if not ln or ln.startswith(";"):
            continue
        if ln.startswith("["):
            in_section = True
            continue
        m = REG_LINE.match(ln)
        rep.ok(bool(m) and in_section, f"{path.name}: malformed line {ln!r}")
        if m:
            name, value = _reg_unescape(m.group(1)), _reg_unescape(m.group(2))
            rep.ok(name not in values, f"{path.name}: duplicate value `{name}`")
            values[name] = value
    for name in values:
        rep.ok(name in keys["claude_desktop_config"], f"{path.name}: key `{name}` not in the Claude Desktop configuration snapshot")
    return values


def check_desktop_contract(rep: Report, prefs: dict, reg: dict, gateway: str, spec: dict) -> None:
    rep.ok(prefs == reg, ".mobileconfig and .reg must carry the same keys and values")
    rep.ok(prefs.get("inferenceProvider") == "gateway", "Claude Desktop: inferenceProvider must be gateway")
    rep.ok(prefs.get("inferenceGatewayBaseUrl") == gateway, f"Claude Desktop: inferenceGatewayBaseUrl is not {gateway}")
    rep.ok(prefs.get("inferenceGatewayAuthScheme") == "x-api-key", "Claude Desktop: auth scheme must be x-api-key (the header the gateway reads)")
    rep.ok(prefs.get("disableDeploymentModeChooser") == "true", "Claude Desktop: disableDeploymentModeChooser must be true")
    try:
        headers = json.loads(prefs.get("inferenceCustomHeaders", "null"))
    except ValueError:
        headers = None
    rep.ok(isinstance(headers, dict), "Claude Desktop: inferenceCustomHeaders must be a JSON object string")
    if isinstance(headers, dict):
        req = spec["require_header"]
        rep.ok(headers.get(req["name"]) == req["value"], "Claude Desktop: require header missing from inferenceCustomHeaders")
        for name in headers:
            rep.ok(name.lower() not in CREDENTIAL_HEADERS, f"Claude Desktop: credential header `{name}` in inferenceCustomHeaders")
    if "inferenceModels" in prefs:
        try:
            models = json.loads(prefs["inferenceModels"])
        except ValueError:
            models = None
        rep.ok(isinstance(models, list) and models and all(isinstance(m, str) for m in models), "Claude Desktop: inferenceModels must be a JSON array of model IDs")
    has_static = "inferenceGatewayApiKey" in prefs
    has_helper = "inferenceCredentialHelper" in prefs
    rep.ok(has_static != has_helper, "Claude Desktop: exactly one credential source (static key slot or helper)")
    if has_static:
        rep.ok(prefs["inferenceGatewayApiKey"] == spec["placeholders"]["lucairn_key_slot"], "Claude Desktop: the static key slot must hold the placeholder, never a key")
    for b in ("autoModeEnabled", "isLocalDevMcpEnabled", "isDesktopExtensionEnabled", "userPluginMarketplacesEnabled", "userPluginUploadsEnabled"):
        rep.ok(prefs.get(b) == "false", f"Claude Desktop: {b} must be false")


def check_no_secrets(rep: Report, files: dict[str, bytes]) -> None:
    for name, data in files.items():
        text = data.decode("utf-8", errors="replace")
        for pat in SECRET_PATTERNS:
            rep.ok(not pat.search(text), f"{name}: contains something shaped like a secret ({pat.pattern})")


def check_dir(directory: Path, gateway: str, spec: dict) -> Report:
    rep = Report()
    keys = snapshot_keys()
    url = R.normalize_gateway_url(gateway)
    names = spec["output_order"]
    for n in names:
        rep.ok((directory / n).is_file(), f"missing {n}")
    if rep.failures:
        return rep
    files = {n: (directory / n).read_bytes() for n in names}
    check_claude_code(rep, directory / spec["claude_code"]["filename"], keys, url, spec)
    prefs = check_mobileconfig(rep, directory / spec["claude_desktop"]["mobileconfig_filename"], keys, spec)
    reg = check_reg(rep, directory / spec["claude_desktop"]["reg_filename"], keys, spec)
    check_desktop_contract(rep, prefs, reg, url, spec)
    setup = files[spec["setup"]["filename"]].decode("utf-8")
    rep.ok("__LUCAIRN_" not in b"".join(files.values()).decode("utf-8"), "a placeholder was left unsubstituted")
    rep.ok(url in setup, "SETUP.md does not name the gateway")
    check_no_secrets(rep, files)
    return rep


def check_golden(spec: dict) -> Report:
    rep = Report()
    golden = json.loads(GOLDEN_PATH.read_text(encoding="utf-8"))
    rep.ok(golden.get("gateway") == spec["default_gateway_url"], "golden-sha256.json is for a different gateway than the spec default")
    rep.ok(golden.get("spec_sha256") == hashlib.sha256((HERE / "spec.json").read_bytes()).hexdigest(), "spec.json changed: regenerate golden-sha256.json (render.py --print-golden) and update the website copy")
    rep.ok(golden.get("setup_template_sha256") == hashlib.sha256((HERE / spec["setup"]["template"]).read_bytes()).hexdigest(), "SETUP.md.tmpl changed: regenerate golden-sha256.json and update the website copy")
    files = R.render(spec["default_gateway_url"], spec=spec)
    for name, data in files.items():
        rep.ok(golden.get("files", {}).get(name) == hashlib.sha256(data).hexdigest(), f"golden mismatch for {name}")
    return rep


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Validate a rendered Lucairn config pack.")
    p.add_argument("--dir", help="rendered pack directory (default: render into a temp dir)")
    p.add_argument("--gateway", help="gateway URL the pack was rendered for (default: the spec default)")
    p.add_argument("--golden", action="store_true", help="also compare a default render with golden-sha256.json")
    args = p.parse_args(argv)

    spec = R.load_spec()
    gateway = args.gateway or spec["default_gateway_url"]
    if args.dir:
        rep = check_dir(Path(args.dir), gateway, spec)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            R.write_pack(R.render(gateway, spec=spec), Path(tmp), force=True)
            rep = check_dir(Path(tmp), gateway, spec)
    if args.golden:
        g = check_golden(spec)
        rep.failures += g.failures
        rep.passes += g.passes
    if rep.failures:
        print(f"config-pack check: {len(rep.failures)} failure(s), {rep.passes} passed")
        return 1
    print(f"config-pack check: PASS ({rep.passes} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
