#!/usr/bin/env python3
"""Validate a rendered Lucairn config pack (offline).

Checks, for the files in --dir (or a fresh render when --dir is omitted):

  1. Syntax: managed-settings.json is JSON with no duplicate keys at any
     level; the .mobileconfig parses as a property list, has no duplicate key
     in any <dict> (read from the raw XML, because plistlib and plutil keep
     the last duplicate silently) and passes `plutil -lint` when plutil
     exists; the .reg file has the version-5 header, CRLF line endings, ASCII
     only, one policy key, strict escaping and no duplicate value name
     (registry names are case-insensitive).
  2. Docs keys: every key the pack writes appears in
     config-pack/docs-keys-snapshot.json (the vendor docs key lists, with the
     URL and date they were fetched).
  3. Policy values: the settings that make the pack worth deploying are
     present, correctly nested and set to the right value and type (see
     CLAUDE_CODE_POLICY / DESKTOP_POLICY below). These are written out here
     on purpose instead of being read from spec.json, so an edit to spec.json
     that weakens the pack fails this check.
  4. Contract: the gateway URL is the same in both tools; every custom header
     has an RFC 7230 token as its name and a clean value, and the require
     header is present exactly once with value 1 in both tools; the
     .mobileconfig and .reg carry the same key/value set; no credential sits
     in a header map; Claude Desktop's only credential source is the static
     key slot (`inferenceCredentialKind` = `static`, no credential helper);
     no file contains a Lucairn or provider key, as written or after decoding
     escapes (JSON and backslash escapes, XML/HTML character references,
     percent-encoding, nested JSON strings); the firewall note names the
     gateway host and port on one complete line.
  5. --golden: the supplied files (or, without --dir, a default render) match
     config-pack/golden-sha256.json byte for byte (the website renderer pins
     the same hashes).
  6. --corpus: every gateway URL in config-pack/parity-corpus.json is still
     accepted with the pinned normalised value and file hashes, or still
     refused (the website renderer checks the same corpus).

Exit code 0 when every check passes, 1 otherwise. Failure messages name the
file and the key, never a value that might be a secret.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import render as R  # noqa: E402

SNAPSHOT_PATH = HERE / "docs-keys-snapshot.json"
GOLDEN_PATH = HERE / "golden-sha256.json"

# Header names that carry credentials. None may appear in a static header map.
CREDENTIAL_HEADERS = {"authorization", "x-api-key", "x-dsa-key", "x-upstream-key", "proxy-authorization"}
SECRET_PATTERNS = R.SECRET_PATTERNS
REG_HEADER = "Windows Registry Editor Version 5.00"
# .reg strings know two escapes only: \\ and \".
REG_LINE = re.compile(r'"((?:[^"\\]|\\[\\"])*)"="((?:[^"\\]|\\[\\"])*)"')
REQUIRE_HEADER = ("x-lucairn-require-added-parts-sanitized", "1")
# RFC 7230 section 3.2.6 token: a header name, nothing around it.
HEADER_NAME = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+")
# RFC 7230 field-value without obs-text: visible ASCII, inner spaces and tabs,
# no leading or trailing whitespace (that is optional whitespace around it).
HEADER_VALUE = re.compile(r"(?:[\x21-\x7e](?:[\x20\x21-\x7e\t]*[\x21-\x7e])?)?")
# Claude Desktop's only credential source in this pack.
STATIC_CREDENTIAL_KIND = "static"

# --- Policy: what a deployable pack must say (independent of spec.json) -----

# Credential-file read denies. Root-anchored (`//`) or home-anchored (`~/`)
# so they hold in every working directory, including folders added with
# --add-dir; a plain `**/.env` only covers the primary working directory.
REQUIRED_READ_DENIES = [
    "Read(~/.ssh/**)",
    "Read(~/.aws/**)",
    "Read(~/.azure/**)",
    "Read(~/.config/gcloud/**)",
    "Read(~/.kube/**)",
    "Read(~/.gnupg/**)",
    "Read(~/.docker/config.json)",
    "Read(~/.netrc)",
    "Read(~/.git-credentials)",
    "Read(~/.npmrc)",
    "Read(~/.pypirc)",
    "Read(//**/.env)",
    "Read(//**/.env.*)",
    "Read(//**/*.pem)",
    "Read(//**/*.key)",
    "Read(//**/*.p12)",
    "Read(//**/*.pfx)",
]
REQUIRED_ENV = {
    "CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS": "1",
    "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_FEEDBACK_COMMAND": "1",
}
# key -> exact JSON value (type included: True is not "true").
CLAUDE_CODE_POLICY = {
    "allowedProviders": ["customEndpoint"],
    "includeGitInstructions": False,
    "autoMemoryEnabled": False,
    "skipWebFetchPreflight": True,
    "disableClaudeAiConnectors": True,
    "disableAutoMode": "disable",
    "useAutoModeDuringPlan": False,
    "allowManagedHooksOnly": True,
    "allowManagedMcpServersOnly": True,
    "disableSideloadFlags": True,
    "parentSettingsBehavior": "merge",
}
PERMISSIONS_POLICY = {
    "defaultMode": "default",
    "blockReadsOutsideWorkingDirectories": True,
}
MODS_GUARD_PLUGIN = "cc-plugin-sec-default@builtin"
MODS_GUARD_OPTION = "allowManagedModsOnly"
# Claude Desktop reads every value as a string.
DESKTOP_POLICY = {
    "inferenceProvider": "gateway",
    "inferenceGatewayAuthScheme": "x-api-key",
    "inferenceCredentialKind": STATIC_CREDENTIAL_KIND,
    "disableDeploymentModeChooser": "true",
    "autoModeEnabled": "false",
    "blockReadsOutsideWorkingDirectories": "true",
    "skipWebFetchPreflight": "true",
    "isLocalDevMcpEnabled": "false",
    "isDesktopExtensionEnabled": "false",
    "userPluginMarketplacesEnabled": "false",
    "userPluginUploadsEnabled": "false",
    "skillCreationEnabled": "false",
    "disableEssentialTelemetry": "true",
    "disableNonessentialTelemetry": "true",
    "disableNonessentialServices": "true",
    "updateViaUpdatesHost": "true",
}
_VERSION_RE = re.compile(r"([0-9]+)\.([0-9]+)\.([0-9]+)")


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


def _strict_json(text: str):
    return json.loads(text, object_pairs_hook=_no_dupes)


def _reg_unescape(value: str) -> str:
    return re.sub(r"\\([\\\"])", r"\1", value)


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


def _version_tuple(value) -> tuple[int, int, int] | None:
    if not isinstance(value, str):
        return None
    m = _VERSION_RE.fullmatch(value)
    return tuple(int(g) for g in m.groups()) if m else None  # type: ignore[return-value]


def check_require_header_lines(rep: Report, where: str, raw) -> None:
    """ANTHROPIC_CUSTOM_HEADERS: `Name: Value` lines. Every line must be a
    header a client can send as written: the name an RFC 7230 token with
    nothing around it, the value visible ASCII (optional whitespace after the
    colon). Only then is the require header counted: exactly once, value 1;
    no credential header."""
    if not isinstance(raw, str):
        rep.ok(False, f"{where}: ANTHROPIC_CUSTOM_HEADERS must be a string")
        return
    name_want, value_want = REQUIRE_HEADER
    hits = []
    for number, line in enumerate(raw.split("\n"), start=1):
        if line == "":
            continue
        name, colon, value = line.partition(":")
        value = value.strip(" \t")
        well_formed = bool(colon) and bool(HEADER_NAME.fullmatch(name)) and bool(HEADER_VALUE.fullmatch(value))
        rep.ok(
            well_formed,
            f"{where}: ANTHROPIC_CUSTOM_HEADERS line {number} is not `Name: Value` with an RFC 7230 header name and a visible-ASCII value",
        )
        if not well_formed:
            continue
        rep.ok(name.lower() not in CREDENTIAL_HEADERS, f"{where}: credential header `{name}` in ANTHROPIC_CUSTOM_HEADERS")
        if name.lower() == name_want:
            hits.append(value)
    rep.ok(len(hits) == 1, f"{where}: require header must appear exactly once in ANTHROPIC_CUSTOM_HEADERS (found {len(hits)})")
    rep.ok(all(v == value_want for v in hits), f"{where}: require header value must be exactly {value_want}")


def check_require_header_map(rep: Report, where: str, raw) -> None:
    """Claude Desktop inferenceCustomHeaders: a JSON object string with no
    duplicate key; every name an RFC 7230 token with nothing around it and
    every value a visible-ASCII string; the require header exactly once (names
    compared without case) with value "1"; no credential header."""
    try:
        headers = _strict_json(raw) if isinstance(raw, str) else None
    except ValueError:
        headers = None
    rep.ok(isinstance(headers, dict), f"{where}: inferenceCustomHeaders must be a JSON object string without duplicate keys")
    if not isinstance(headers, dict):
        return
    name_want, value_want = REQUIRE_HEADER
    valid = {}
    for name, value in headers.items():
        ok = bool(HEADER_NAME.fullmatch(name)) and isinstance(value, str) and bool(HEADER_VALUE.fullmatch(value))
        rep.ok(ok, f"{where}: inferenceCustomHeaders entry `{name if HEADER_NAME.fullmatch(name) else '<invalid name>'}` is not an RFC 7230 header name with a visible-ASCII string value")
        if ok:
            valid[name] = value
    hits = [v for k, v in valid.items() if k.lower() == name_want]
    rep.ok(len(hits) == 1, f"{where}: require header must appear exactly once in inferenceCustomHeaders (found {len(hits)})")
    rep.ok(all(v == value_want for v in hits), f"{where}: require header value must be exactly \"{value_want}\"")
    for name in valid:
        rep.ok(name.lower() not in CREDENTIAL_HEADERS, f"{where}: credential header `{name}` in inferenceCustomHeaders")


def check_claude_code(rep: Report, path: Path, keys: dict, gateway: str) -> dict:
    raw = path.read_bytes()
    try:
        settings = _strict_json(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        rep.ok(False, f"{path.name}: not valid JSON or has duplicate keys ({type(exc).__name__})")
        return {}
    if not isinstance(settings, dict):
        rep.ok(False, f"{path.name}: top level must be an object")
        return {}
    for kp in claude_code_key_paths(settings):
        rep.ok(kp in keys["claude_code_settings"], f"{path.name}: key `{kp}` not in the settings-reference snapshot")

    env = settings.get("env")
    rep.ok(isinstance(env, dict), f"{path.name}: `env` must be an object")
    env = env if isinstance(env, dict) else {}
    for var in env:
        rep.ok(var in keys["claude_code_env_vars"], f"{path.name}: env var `{var}` not in the env-vars snapshot")
        rep.ok(isinstance(env[var], str), f"{path.name}: env `{var}` must be a string")
    rep.ok(env.get("ANTHROPIC_BASE_URL") == gateway, f"{path.name}: env.ANTHROPIC_BASE_URL is not {gateway}")
    for var, want in REQUIRED_ENV.items():
        rep.ok(env.get(var) == want, f"{path.name}: env.{var} must be \"{want}\"")
    check_require_header_lines(rep, path.name, env.get("ANTHROPIC_CUSTOM_HEADERS"))

    for key, want in CLAUDE_CODE_POLICY.items():
        got = settings.get(key)
        rep.ok(type(got) is type(want) and got == want, f"{path.name}: `{key}` must be {json.dumps(want)}")
    floor = _version_tuple(R.REQUIRED_MINIMUM_VERSION)
    got_version = _version_tuple(settings.get("requiredMinimumVersion"))
    rep.ok(
        got_version is not None and floor is not None and got_version >= floor,
        f"{path.name}: `requiredMinimumVersion` must be a version string of at least {R.REQUIRED_MINIMUM_VERSION} "
        "(allowedProviders needs it; Claude Code ignores an invalid value)",
    )
    for key in ("allowedMcpServers", "strictKnownMarketplaces"):
        rep.ok(isinstance(settings.get(key), list), f"{path.name}: `{key}` must be a list (empty unless you list your own)")

    perms = settings.get("permissions")
    rep.ok(isinstance(perms, dict), f"{path.name}: `permissions` must be an object")
    perms = perms if isinstance(perms, dict) else {}
    for key, want in PERMISSIONS_POLICY.items():
        got = perms.get(key)
        rep.ok(type(got) is type(want) and got == want, f"{path.name}: `permissions.{key}` must be {json.dumps(want)}")
    deny = perms.get("deny")
    rep.ok(isinstance(deny, list) and all(isinstance(d, str) for d in deny), f"{path.name}: `permissions.deny` must be a list of rules")
    deny = deny if isinstance(deny, list) else []
    for rule in REQUIRED_READ_DENIES:
        rep.ok(rule in deny, f"{path.name}: `permissions.deny` is missing {rule}")

    plugin_configs = settings.get("pluginConfigs")
    rep.ok(isinstance(plugin_configs, dict), f"{path.name}: `pluginConfigs` must be an object")
    plugin_configs = plugin_configs if isinstance(plugin_configs, dict) else {}
    for plugin_id, cfg in plugin_configs.items():
        rep.ok(plugin_id in keys["claude_code_mods_guard"], f"{path.name}: pluginConfigs id `{plugin_id}` not in the mods-admin snapshot")
        options = cfg.get("options") if isinstance(cfg, dict) else None
        for opt in (options if isinstance(options, dict) else {}):
            rep.ok(opt in keys["claude_code_mods_guard"], f"{path.name}: guard option `{opt}` not in the mods-admin snapshot")
    guard = plugin_configs.get(MODS_GUARD_PLUGIN)
    options = guard.get("options") if isinstance(guard, dict) else None
    rep.ok(
        isinstance(options, dict) and options.get(MODS_GUARD_OPTION) is True,
        f"{path.name}: pluginConfigs.\"{MODS_GUARD_PLUGIN}\".options.{MODS_GUARD_OPTION} must be true (boolean)",
    )

    for forbidden in ("forceLoginMethod", "forceLoginOrgUUID", "forceLoginGatewayUrl"):
        rep.ok(forbidden not in settings, f"{path.name}: `{forbidden}` must not be set")
    for forbidden in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"):
        rep.ok(forbidden not in env and forbidden not in settings, f"{path.name}: `{forbidden}` must not be set")
    return settings


def _xml_dict_duplicates(raw: bytes) -> list[str]:
    """Keys that appear twice in one <dict> of a property list, read from the
    raw XML (plistlib and plutil keep the last one without a word)."""
    root = ET.fromstring(raw)
    dupes = []
    for d in root.iter("dict"):
        seen: set[str] = set()
        for child in d:
            if child.tag != "key":
                continue
            name = child.text or ""
            if name in seen:
                dupes.append(name)
            seen.add(name)
    return dupes


def check_mobileconfig(rep: Report, path: Path, keys: dict, spec: dict) -> dict:
    raw = path.read_bytes()
    rep.ok(b"<!ENTITY" not in raw, f"{path.name}: entity declarations are not allowed")
    try:
        dupes = _xml_dict_duplicates(raw)
        plist = plistlib.loads(raw)
    except Exception as exc:  # plistlib / ElementTree raise several exception types
        rep.ok(False, f"{path.name}: not a valid property list ({type(exc).__name__})")
        return {}
    rep.ok(not dupes, f"{path.name}: duplicate keys in one <dict>: {sorted(set(dupes))}")
    if shutil.which("plutil"):
        res = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
        rep.ok(res.returncode == 0, f"{path.name}: plutil -lint failed")
    if not isinstance(plist, dict):
        rep.ok(False, f"{path.name}: top level must be a dictionary")
        return {}
    rep.ok(plist.get("PayloadType") == "Configuration", f"{path.name}: outer PayloadType must be Configuration")
    content = plist.get("PayloadContent")
    if not (isinstance(content, list) and len(content) == 1 and isinstance(content[0], dict)):
        rep.ok(False, f"{path.name}: outer PayloadContent must hold exactly one payload dictionary")
        return {}
    payload = content[0]
    rep.ok(payload.get("PayloadType") == "com.apple.ManagedClient.preferences", f"{path.name}: payload type must be com.apple.ManagedClient.preferences")
    domain = spec["claude_desktop"]["preference_domain"]
    inner = payload.get("PayloadContent")
    if not (isinstance(inner, dict) and list(inner) == [domain] and isinstance(inner[domain], dict)):
        rep.ok(False, f"{path.name}: payload PayloadContent must hold exactly the {domain} domain")
        return {}
    forced = inner[domain].get("Forced")
    if not (isinstance(forced, list) and len(forced) == 1 and isinstance(forced[0], dict)):
        rep.ok(False, f"{path.name}: expected exactly one Forced entry under {domain}")
        return {}
    prefs = forced[0].get("mcx_preference_settings")
    if not (isinstance(prefs, dict) and prefs):
        rep.ok(False, f"{path.name}: mcx_preference_settings is missing or empty")
        return {}
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
    rep.ok("\n" not in text.replace("\r\n", "") and "\r" not in text.replace("\r\n", ""), f"{path.name}: every line must end in CRLF")
    lines = text.split("\r\n")
    rep.ok(lines[0] == REG_HEADER, f"{path.name}: first line must be `{REG_HEADER}`")
    sections = [ln for ln in lines if ln.startswith("[")]
    rep.ok(sections == [f"[{spec['claude_desktop']['registry_key']}]"], f"{path.name}: expected exactly one key [{spec['claude_desktop']['registry_key']}]")
    values: dict[str, str] = {}
    seen_lower: set[str] = set()
    in_section = False
    for number, ln in enumerate(lines[1:], start=2):
        if not ln or ln.startswith(";"):
            continue
        if ln.startswith("["):
            in_section = True
            continue
        m = REG_LINE.fullmatch(ln)
        rep.ok(bool(m) and in_section, f"{path.name}: malformed line {number}")
        if m:
            name, value = _reg_unescape(m.group(1)), _reg_unescape(m.group(2))
            rep.ok(name.lower() not in seen_lower, f"{path.name}: duplicate value `{name}` (registry names ignore case)")
            seen_lower.add(name.lower())
            values[name] = value
    if not values:
        rep.ok(False, f"{path.name}: no values under the policy key")
    for name in values:
        rep.ok(name in keys["claude_desktop_config"], f"{path.name}: key `{name}` not in the Claude Desktop configuration snapshot")
    return values


def check_desktop_contract(rep: Report, prefs: dict, reg: dict, gateway: str, spec: dict) -> None:
    rep.ok(prefs == reg, ".mobileconfig and .reg must carry the same keys and values")
    for key, want in DESKTOP_POLICY.items():
        rep.ok(prefs.get(key) == want, f"Claude Desktop: `{key}` must be \"{want}\"")
    rep.ok(prefs.get("inferenceGatewayBaseUrl") == gateway, f"Claude Desktop: inferenceGatewayBaseUrl is not {gateway}")
    check_require_header_map(rep, "Claude Desktop", prefs.get("inferenceCustomHeaders"))
    if "inferenceModels" in prefs:
        try:
            models = _strict_json(prefs["inferenceModels"])
        except ValueError:
            models = None
        rep.ok(isinstance(models, list) and models and all(isinstance(m, str) for m in models), "Claude Desktop: inferenceModels must be a JSON array of model IDs")
    if "egressProxyUrl" in prefs:
        try:
            ok = R.normalize_proxy_url(prefs["egressProxyUrl"]) == prefs["egressProxyUrl"]
        except R.PackError:
            ok = False
        rep.ok(ok, "Claude Desktop: egressProxyUrl must be http(s)://host[:port] with a valid host name and port")
    # One credential source: the static key slot. A credential helper is
    # refused outright: the vendor documents that the headers a helper prints
    # are "merged over" inferenceCustomHeaders, "helper wins on conflict", so a
    # helper could turn the require header off.
    helpers = sorted(k for k in prefs if k.lower().startswith("inferencecredentialhelper"))
    rep.ok(not helpers, f"Claude Desktop: credential helper keys are not allowed in the pack: {helpers}")
    rep.ok("inferenceGatewayApiKey" in prefs, "Claude Desktop: the static key slot inferenceGatewayApiKey is missing")
    rep.ok(
        prefs.get("inferenceGatewayApiKey") == spec["placeholders"]["lucairn_key_slot"],
        "Claude Desktop: the static key slot must hold the placeholder, never a key",
    )
    # DESKTOP_POLICY already pins inferenceCredentialKind to "static"; say it
    # again in terms of the source so a policy edit can't loosen both at once.
    rep.ok(
        prefs.get("inferenceCredentialKind") == STATIC_CREDENTIAL_KIND,
        "Claude Desktop: inferenceCredentialKind must be \"static\", the kind of the static key slot the pack configures",
    )


def _strings(value, depth: int = 0):
    """Every string in a parsed document, keys included; for a string that is
    itself a JSON document (inferenceCustomHeaders, inferenceModels), the
    strings inside it as well."""
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="replace")
    if isinstance(value, str):
        yield value
        stripped = value.strip()
        if depth < 4 and stripped[:1] in ("{", "[", '"'):
            try:
                inner = json.loads(stripped)
            except ValueError:
                return
            if inner != value:
                yield from _strings(inner, depth + 1)
    elif isinstance(value, dict):
        for k, v in value.items():
            yield from _strings(k, depth)
            yield from _strings(v, depth)
    elif isinstance(value, (list, tuple)):
        for v in value:
            yield from _strings(v, depth)


def _decoded_strings(name: str, data: bytes) -> list[str]:
    """The strings a consumer of the file reads: the JSON or property-list
    values after the format's own decoding (JSON escapes, XML character
    references), the .reg values after unescaping, and the whole text."""
    text = data.decode("utf-8", errors="replace")
    out = [text, html.unescape(text)]
    try:
        if name.endswith(".json"):
            out.extend(_strings(json.loads(text)))
        elif name.endswith(".mobileconfig"):
            out.extend(_strings(plistlib.loads(data)))
        elif name.endswith(".reg"):
            for ln in text.split("\r\n"):
                m = REG_LINE.fullmatch(ln)
                if m:
                    out.extend((_reg_unescape(m.group(1)), _reg_unescape(m.group(2))))
    except Exception:  # syntax is reported by the format checks
        pass
    return out


def check_no_secrets(rep: Report, files: dict[str, bytes]) -> None:
    """No file holds a key shape, as written or as any decoding reads it."""
    for name, data in files.items():
        found = None
        for value in _decoded_strings(name, data):
            found = R.secret_shape_in(value)
            if found:
                break
        rep.ok(found is None, f"{name}: contains something shaped like a secret ({found}), as written or after decoding escapes")


def read_dir(directory: Path, spec: dict) -> dict[str, bytes] | None:
    names = spec["output_order"]
    if not all((directory / n).is_file() for n in names):
        return None
    return {n: (directory / n).read_bytes() for n in names}


def check_dir(directory: Path, gateway: str, spec: dict) -> Report:
    rep = Report()
    keys = snapshot_keys()
    url = R.normalize_gateway_url(gateway)
    names = spec["output_order"]
    for n in names:
        rep.ok((directory / n).is_file(), f"missing {n}")
    if rep.failures:
        return rep
    files = read_dir(directory, spec) or {}
    check_claude_code(rep, directory / spec["claude_code"]["filename"], keys, url)
    prefs = check_mobileconfig(rep, directory / spec["claude_desktop"]["mobileconfig_filename"], keys, spec)
    reg = check_reg(rep, directory / spec["claude_desktop"]["reg_filename"], keys, spec)
    check_desktop_contract(rep, prefs, reg, url, spec)
    try:
        setup = files[spec["setup"]["filename"]].decode("utf-8")
    except UnicodeDecodeError:
        setup = ""
        rep.ok(False, "SETUP.md must be UTF-8")
    rep.ok(all(b"__LUCAIRN_" not in data for data in files.values()), "a placeholder was left unsubstituted")
    rep.ok(url in setup, "SETUP.md does not name the gateway")
    firewall_line = f"- **Allow** from user devices: `{R.gateway_host(url)}`, TCP port {R.gateway_port(url)} (HTTPS)."
    rep.ok(
        setup.splitlines().count(firewall_line) == 1,
        "SETUP.md firewall note does not name the gateway's host and port on one complete line",
    )
    check_no_secrets(rep, files)
    return rep


def check_golden(spec: dict, files: dict[str, bytes] | None = None) -> Report:
    """Compare `files` (the supplied pack) or, when None, a fresh default
    render with golden-sha256.json."""
    rep = Report()
    golden = json.loads(GOLDEN_PATH.read_text(encoding="utf-8"))
    rep.ok(golden.get("gateway") == spec["default_gateway_url"], "golden-sha256.json is for a different gateway than the spec default")
    rep.ok(golden.get("spec_sha256") == hashlib.sha256((HERE / "spec.json").read_bytes()).hexdigest(), "spec.json changed: regenerate golden-sha256.json (render.py --print-golden) and update the website copy")
    rep.ok(golden.get("setup_template_sha256") == hashlib.sha256((HERE / spec["setup"]["template"]).read_bytes()).hexdigest(), "SETUP.md.tmpl changed: regenerate golden-sha256.json and update the website copy")
    if files is None:
        files = R.render(spec["default_gateway_url"], spec=spec)
    for name in spec["output_order"]:
        data = files.get(name)
        rep.ok(data is not None and golden.get("files", {}).get(name) == hashlib.sha256(data).hexdigest(), f"golden mismatch for {name}")
    return rep


def check_corpus(spec: dict) -> Report:
    """parity-corpus.json: accepted gateway URLs keep their normalised value
    and file hashes; refused ones stay refused."""
    rep = Report()
    corpus = json.loads(R.CORPUS_PATH.read_text(encoding="utf-8"))
    rep.ok(len(corpus.get("accepted", [])) >= 10 and len(corpus.get("refused", [])) >= 30, "parity-corpus.json looks truncated")
    for case in corpus.get("accepted", []):
        try:
            normalized = R.normalize_gateway_url(case["input"])
            files = R.render(case["input"], spec=spec)
        except R.PackError:
            rep.ok(False, f"corpus: accepted case is refused: {case['why']}")
            continue
        rep.ok(normalized == case["normalized"], f"corpus: normalised value changed: {case['why']}")
        rep.ok(R.normalize_gateway_url(normalized) == normalized, f"corpus: normalising twice changes the value: {case['why']}")
        for name, data in files.items():
            rep.ok(case["files"].get(name) == hashlib.sha256(data).hexdigest(), f"corpus: {name} changed: {case['why']}")
    for case in corpus.get("refused", []):
        try:
            R.render(case["input"], spec=spec)
            accepted = True
        except R.PackError:
            accepted = False
        rep.ok(not accepted, f"corpus: refused case is accepted: {case['why']}")
    return rep


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Validate a rendered Lucairn config pack.")
    p.add_argument("--dir", help="rendered pack directory (default: render into a temp dir)")
    p.add_argument("--gateway", help="gateway URL the pack was rendered for (default: the spec default)")
    p.add_argument("--golden", action="store_true", help="also compare the files with golden-sha256.json (the files in --dir when given)")
    p.add_argument("--corpus", action="store_true", help="also check parity-corpus.json")
    args = p.parse_args(argv)

    spec = R.load_spec()
    gateway = args.gateway or spec["default_gateway_url"]
    supplied = None
    if args.dir:
        rep = check_dir(Path(args.dir), gateway, spec)
        supplied = read_dir(Path(args.dir), spec) or {}
    else:
        with tempfile.TemporaryDirectory() as tmp:
            R.write_pack(R.render(gateway, spec=spec), Path(tmp), force=True)
            rep = check_dir(Path(tmp), gateway, spec)
    extra = []
    if args.golden:
        if args.dir and R.normalize_gateway_url(gateway) != spec["default_gateway_url"]:
            rep.ok(False, "--golden pins the default gateway only; this pack is for another gateway")
        else:
            extra.append(check_golden(spec, supplied))
    if args.corpus:
        extra.append(check_corpus(spec))
    for g in extra:
        rep.failures += g.failures
        rep.passes += g.passes
    if rep.failures:
        print(f"config-pack check: {len(rep.failures)} failure(s), {rep.passes} passed")
        return 1
    print(f"config-pack check: PASS ({rep.passes} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
