#!/usr/bin/env python3
"""Render the Lucairn config pack for one gateway URL.

Reads config-pack/spec.json (the single source of truth for every key and
value) and config-pack/SETUP.md.tmpl, substitutes the gateway URL, and writes:

  managed-settings.json        Claude Code managed settings
  claude-desktop.mobileconfig  Claude Desktop (third-party mode), macOS profile
  claude-desktop.reg           Claude Desktop (third-party mode), Windows policy
  SETUP.md                     Install steps, credential options, firewall note

No output ever contains a Lucairn key. The Claude Desktop files carry the
placeholder REPLACE_WITH_YOUR_LUCAIRN_KEY in `inferenceGatewayApiKey` unless a
credential helper path is given, in which case that slot is removed.

Every input is validated (shape, secret patterns, reserved placeholder text)
before anything is rendered; the rendered files are then checked in a private
temporary directory, and only a pack that passes is written to --output.
Errors name the input and the rule, never the rejected value.

The lucairn.eu account area renders the gateway-URL-only output with a
TypeScript port of this file; config-pack/golden-sha256.json pins the default
render and config-pack/parity-corpus.json pins hostile-but-accepted gateway
URLs (and the refused ones), byte for byte, so the two renderers cannot drift
apart unnoticed.

Python 3.8+, standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from xml.sax.saxutils import escape as _xml_escape

HERE = Path(__file__).resolve().parent
SPEC_PATH = HERE / "spec.json"
CORPUS_PATH = HERE / "parity-corpus.json"

# ---------------------------------------------------------------------------
# Input rules. config-pack/README.md ("Input rules") documents them once; the
# website's TypeScript port (src/lib/configPack/render.ts) implements the same
# rules, and config-pack/parity-corpus.json pins both renderers to the same
# accept/refuse decision and the same output bytes for hostile-but-accepted
# inputs.
# ---------------------------------------------------------------------------

# Only these characters are trimmed from the ends of an input (a pasted value
# often carries a space or a line break). Every other whitespace or control
# character is refused, wherever it sits.
_BOUNDARY_WS = " \t\r\n"
# https only, host[:port], optional path from a narrow ASCII alphabet; no
# userinfo, query, fragment, percent-encoding or backslash. Matched with
# fullmatch, never search/match.
_GATEWAY_RE = re.compile(
    r"https://(?P<host>[A-Za-z0-9.-]+)(?::(?P<port>[0-9]+))?(?P<path>/[A-Za-z0-9._~/-]*)?"
)
_PROXY_RE = re.compile(r"(?P<scheme>https?)://(?P<host>[A-Za-z0-9.-]+)(?::(?P<port>[0-9]+))?/?")
_LABEL_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?")
# A final label that URL parsers read as a number (decimal or 0x hex) turns
# the whole host into an IPv4 address; only a plain dotted quad is accepted.
_NUMERIC_LABEL_RE = re.compile(r"[0-9]+|0[xX][0-9A-Fa-f]*")
_IPV4_PART_RE = re.compile(r"0|[1-9][0-9]{0,2}")
_PORT_RE = re.compile(r"[1-9][0-9]{0,4}")
_MAX_HOST_LEN = 253
_MODEL_RE = re.compile(r"[A-Za-z0-9._:/@\[\]-]{1,200}")
# Claude Code apiKeyHelper: a command line, printable ASCII without quotes, so
# it survives JSON encoding unchanged in meaning.
_KEY_HELPER_RE = re.compile(r"[A-Za-z0-9 _./:\\~+=,@-]{1,400}")
# Claude Desktop credential helper: an absolute path to an executable under a
# root that only administrators can write. A helper may also print request
# headers, and the vendor documents that those win over the profile's static
# headers, so a user-writable helper could switch the require header off.
_POSIX_HELPER_RE = re.compile(r"/[A-Za-z0-9 _./+@,=-]{1,399}")
_POSIX_HELPER_ROOTS = ("/Library/", "/usr/local/", "/opt/")
# Package-manager trees below those roots that are owned by a user account.
_POSIX_HELPER_REFUSED = ("/opt/homebrew/", "/usr/local/Homebrew/", "/usr/local/Cellar/")
_WINDOWS_HELPER_RE = re.compile(r"[Cc]:\\[A-Za-z0-9 _.\\()+@,=-]{1,397}")
_WINDOWS_HELPER_ROOTS = ("c:\\program files\\", "c:\\program files (x86)\\")
# Text that must never appear in an input: the renderer's own placeholders.
_RESERVED_TEXT = ("__LUCAIRN_", "REPLACE_WITH_YOUR_LUCAIRN_KEY")
# Shapes of real secrets. Inputs that match are refused before anything is
# written; check.py refuses rendered files that match.
SECRET_PATTERNS = [
    re.compile(r"lcr_live_[A-Za-z0-9]"),
    re.compile(r"\bdsa_[A-Za-z0-9]{8,}"),
    re.compile(r"sk-ant-[A-Za-z0-9]"),
    re.compile(r"\bsk-[A-Za-z0-9]{20,}"),
]
REQUIRED_MINIMUM_VERSION = "2.1.285"


class PackError(ValueError):
    """Invalid input to the renderer."""


def load_spec(path: Path = SPEC_PATH) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _redacted(value: str) -> str:
    """How an input is named in an error: never the value itself."""
    return f"<redacted>, {len(value)} characters"


def strip_boundary(raw: str | None) -> str:
    return (raw or "").strip(_BOUNDARY_WS)


def valid_host(host: str) -> bool:
    """A DNS host name of ASCII letters, digits and hyphens (punycode labels
    included, Unicode not), or a plain dotted-quad IPv4 address. No trailing
    dot, no empty label, at most 253 characters."""
    if not host or len(host) > _MAX_HOST_LEN:
        return False
    labels = host.split(".")
    if not all(_LABEL_RE.fullmatch(label) for label in labels):
        return False
    if _NUMERIC_LABEL_RE.fullmatch(labels[-1]):
        return len(labels) == 4 and all(
            _IPV4_PART_RE.fullmatch(p) and int(p) <= 255 for p in labels
        )
    return True


def valid_port(port: str) -> bool:
    """1-65535, written without leading zeros."""
    return bool(_PORT_RE.fullmatch(port)) and int(port) <= 65535


def normalize_gateway_url(raw: str) -> str:
    """The gateway URL as both tools will see it: boundary whitespace trimmed,
    an explicit :443 dropped, trailing slashes dropped. Raises PackError for
    anything outside the accepted shape (README, "Input rules")."""
    value = strip_boundary(raw)
    m = _GATEWAY_RE.fullmatch(value)
    if not m:
        raise PackError(
            "gateway URL must look like https://gateway.example.com (https, a host name, "
            "optional port and path; no user info, query, fragment, percent-encoding, "
            "backslash, space or non-ASCII character)"
        )
    host, port, path = m.group("host"), m.group("port"), m.group("path") or ""
    if not valid_host(host):
        raise PackError("gateway URL has an invalid host name")
    if port is not None and not valid_port(port):
        raise PackError("gateway URL has an invalid port (1-65535, no leading zeros)")
    path = path.rstrip("/")
    if path and any(seg in ("", ".", "..") for seg in path[1:].split("/")):
        raise PackError("gateway URL path has an empty, '.' or '..' segment")
    port_part = f":{port}" if port is not None and port != "443" else ""
    return f"https://{host}{port_part}{path}"


def gateway_host(url: str) -> str:
    """Host name of a normalised gateway URL (no port, no case folding)."""
    return url[len("https://"):].split("/", 1)[0].split(":", 1)[0]


def gateway_port(url: str) -> str:
    """The port the tools connect to: the explicit one, else 443."""
    hostport = url[len("https://"):].split("/", 1)[0]
    return hostport.split(":", 1)[1] if ":" in hostport else "443"


def normalize_proxy_url(raw: str) -> str:
    """Claude Desktop egressProxyUrl: http:// or https://, a valid host name,
    an optional port 1-65535, nothing else (the vendor rejects user:pass@)."""
    value = strip_boundary(raw)
    m = _PROXY_RE.fullmatch(value)
    if not m:
        raise PackError(
            "--egress-proxy must look like http://proxy.example.com:3128 (http or https, a host "
            f"name, optional port; no user info or path) ({_redacted(value)})"
        )
    if not valid_host(m.group("host")):
        raise PackError(f"--egress-proxy has an invalid host name ({_redacted(value)})")
    port = m.group("port")
    if port is not None and not valid_port(port):
        raise PackError(f"--egress-proxy has an invalid port (1-65535, no leading zeros) ({_redacted(value)})")
    port_part = f":{port}" if port is not None else ""
    return f"{m.group('scheme')}://{m.group('host')}{port_part}"


def _path_segments_ok(segments: list[str]) -> bool:
    return all(seg and seg not in (".", "..") for seg in segments)


def posix_helper_problem(path: str) -> str | None:
    """Why a macOS/Linux Claude Desktop credential helper path is refused, or
    None when it is an absolute path under an administrator-controlled root."""
    if not _POSIX_HELPER_RE.fullmatch(path):
        return "must be an absolute path (no ~, quotes, backslashes or control characters)"
    if not path.startswith(_POSIX_HELPER_ROOTS) or path.startswith(_POSIX_HELPER_REFUSED):
        return "must sit under " + ", ".join(_POSIX_HELPER_ROOTS) + " (not a home folder or a user-owned package tree)"
    if not _path_segments_ok(path[1:].split("/")):
        return "must not contain empty, '.' or '..' segments"
    return None


def windows_helper_problem(path: str) -> str | None:
    """Why a Windows Claude Desktop credential helper path is refused, or None
    when it is an absolute path under C:\\Program Files."""
    if not _WINDOWS_HELPER_RE.fullmatch(path):
        return "must be an absolute C:\\ path with backslashes (no ~, quotes, forward slashes or control characters)"
    if not path.lower().startswith(_WINDOWS_HELPER_ROOTS):
        return "must sit under C:\\Program Files\\ or C:\\Program Files (x86)\\"
    segments = path[3:].split("\\")
    # Windows drops trailing dots and spaces from a path segment, so "..." or
    # "x. " would not mean what it says.
    if not _path_segments_ok(segments) or any(seg.endswith((".", " ")) for seg in segments):
        return "must not contain empty segments or segments ending in a dot or space"
    return None


def _substitute(value, mapping: dict):
    if isinstance(value, str):
        for needle, repl in mapping.items():
            value = value.replace(needle, repl)
        return value
    if isinstance(value, list):
        return [_substitute(v, mapping) for v in value]
    if isinstance(value, dict):
        return {k: _substitute(v, mapping) for k, v in value.items()}
    return value


def desktop_value_string(value) -> str:
    """Claude Desktop reads every managed value as a string (booleans as
    "true"/"false", arrays and objects as JSON documents)."""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (dict, list)):
        return json.dumps(value, separators=(",", ":"), ensure_ascii=True)
    if isinstance(value, str):
        return value
    raise PackError(f"unsupported Claude Desktop value type: {type(value).__name__}")


def _plain_ascii(value: str, where: str) -> str:
    """Refuse control characters (CR and LF included) and non-ASCII before a
    value is written into the .reg or .mobileconfig, independent of the input
    rules that should already have kept them out."""
    if any(ord(c) < 0x20 or ord(c) > 0x7E for c in value):
        raise PackError(f"{where}: refusing to write a control or non-ASCII character")
    return value


def _reg_escape(value: str) -> str:
    """.reg string escaping: only backslash and double quote have escapes."""
    return _plain_ascii(value, ".reg").replace("\\", "\\\\").replace('"', '\\"')


def build_claude_code(spec: dict, mapping: dict, key_helper: str | None) -> dict:
    settings = _substitute(spec["claude_code"]["managed_settings"], mapping)
    if key_helper:
        settings["apiKeyHelper"] = key_helper
    return settings


def build_desktop_pairs(
    spec: dict,
    mapping: dict,
    *,
    models: list[str] | None,
    egress_proxy: str | None,
    desktop_key_helper: str | None,
    desktop_key_helper_windows: str | None,
) -> list[tuple[str, str]]:
    pairs = [(k, _substitute(v, mapping)) for k, v in spec["claude_desktop"]["keys"]]
    if desktop_key_helper_windows and not desktop_key_helper:
        raise PackError("--desktop-key-helper-windows needs --desktop-key-helper (the macOS path) as well")
    if desktop_key_helper:
        # A helper replaces the static key slot; the vendor docs say the helper
        # wins over static fields, and leaving a placeholder next to it only
        # invites someone to fill it in.
        pairs = [(k, v) for k, v in pairs if k != "inferenceGatewayApiKey"]
        pairs.append(("inferenceCredentialKind", "helper-script"))
        pairs.append(("inferenceCredentialHelper", desktop_key_helper))
        if desktop_key_helper_windows:
            pairs.append(("inferenceCredentialHelperWindows", desktop_key_helper_windows))
    if models:
        pairs.append(("inferenceModels", list(models)))
    if egress_proxy:
        pairs.append(("egressProxyUrl", egress_proxy))
    return [(k, desktop_value_string(v)) for k, v in pairs]


def render_mobileconfig(spec: dict, mapping: dict, pairs: list[tuple[str, str]]) -> str:
    if not pairs:
        raise PackError("refusing to write a .mobileconfig with no Claude Desktop settings")
    desk = spec["claude_desktop"]
    prof = _substitute(desk["profile"], mapping)
    domain = desk["preference_domain"]

    def x(value: str) -> str:
        return _xml_escape(_plain_ascii(value, ".mobileconfig"))

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        "\t<key>PayloadDisplayName</key>",
        f"\t<string>{x(prof['display_name'])}</string>",
        "\t<key>PayloadDescription</key>",
        f"\t<string>{x(prof['description'])}</string>",
        "\t<key>PayloadIdentifier</key>",
        f"\t<string>{x(prof['identifier'])}</string>",
        "\t<key>PayloadScope</key>",
        "\t<string>System</string>",
        "\t<key>PayloadType</key>",
        "\t<string>Configuration</string>",
        "\t<key>PayloadUUID</key>",
        f"\t<string>{x(prof['uuid'])}</string>",
        "\t<key>PayloadVersion</key>",
        "\t<integer>1</integer>",
        "\t<key>PayloadContent</key>",
        "\t<array>",
        "\t\t<dict>",
        "\t\t\t<key>PayloadDisplayName</key>",
        f"\t\t\t<string>{x(prof['display_name'])}</string>",
        "\t\t\t<key>PayloadIdentifier</key>",
        f"\t\t\t<string>{x(prof['identifier'])}.{x(prof['payload_uuid'])}</string>",
        "\t\t\t<key>PayloadType</key>",
        "\t\t\t<string>com.apple.ManagedClient.preferences</string>",
        "\t\t\t<key>PayloadUUID</key>",
        f"\t\t\t<string>{x(prof['payload_uuid'])}</string>",
        "\t\t\t<key>PayloadVersion</key>",
        "\t\t\t<integer>1</integer>",
        "\t\t\t<key>PayloadContent</key>",
        "\t\t\t<dict>",
        f"\t\t\t\t<key>{x(domain)}</key>",
        "\t\t\t\t<dict>",
        "\t\t\t\t\t<key>Forced</key>",
        "\t\t\t\t\t<array>",
        "\t\t\t\t\t\t<dict>",
        "\t\t\t\t\t\t\t<key>mcx_preference_settings</key>",
        "\t\t\t\t\t\t\t<dict>",
    ]
    for key, value in pairs:
        lines.append(f"\t\t\t\t\t\t\t\t<key>{x(key)}</key>")
        lines.append(f"\t\t\t\t\t\t\t\t<string>{x(value)}</string>")
    lines += [
        "\t\t\t\t\t\t\t</dict>",
        "\t\t\t\t\t\t</dict>",
        "\t\t\t\t\t</array>",
        "\t\t\t\t</dict>",
        "\t\t\t</dict>",
        "\t\t</dict>",
        "\t</array>",
        "</dict>",
        "</plist>",
    ]
    return "\n".join(lines) + "\n"


def render_reg(spec: dict, gateway_url: str, pairs: list[tuple[str, str]]) -> str:
    if not pairs:
        raise PackError("refusing to write a .reg with no Claude Desktop settings")
    desk = spec["claude_desktop"]
    lines = [
        "Windows Registry Editor Version 5.00",
        "",
        "; Lucairn gateway settings for Claude Desktop (third-party inference mode).",
        f"; Gateway: {_plain_ascii(gateway_url, '.reg')}",
        "; Every value is REG_SZ, directly under the policy key. See SETUP.md before importing.",
        "",
        f"[{desk['registry_key']}]",
    ]
    for key, value in pairs:
        lines.append(f'"{_reg_escape(key)}"="{_reg_escape(value)}"')
    lines.append("")
    return "\r\n".join(lines) + "\r\n"


def render_setup(spec: dict, mapping: dict) -> str:
    template = (HERE / spec["setup"]["template"]).read_text(encoding="utf-8")
    return _substitute(template, mapping)


def _optional(value: str | None) -> str | None:
    value = strip_boundary(value)
    return value or None


def _refuse_secrets_and_placeholders(name: str, value: str) -> None:
    for pat in SECRET_PATTERNS:
        if pat.search(value):
            raise PackError(f"{name} looks like it contains a key; keys never go into the pack ({_redacted(value)})")
    if any(t in value for t in _RESERVED_TEXT):
        raise PackError(f"{name} contains the pack's own placeholder text ({_redacted(value)})")


def validate_inputs(
    gateway: str,
    *,
    models: list[str] | None = None,
    egress_proxy: str | None = None,
    key_helper: str | None = None,
    desktop_key_helper: str | None = None,
    desktop_key_helper_windows: str | None = None,
) -> dict:
    """Check every input before anything is rendered or written. Raises
    PackError naming the input and the rule, never the rejected value."""
    url = normalize_gateway_url(gateway)
    out: dict = {"gateway": url, "models": [], "egress_proxy": None, "key_helper": None,
                 "desktop_key_helper": None, "desktop_key_helper_windows": None}
    _refuse_secrets_and_placeholders("gateway URL", url)

    proxy = _optional(egress_proxy)
    if proxy is not None:
        out["egress_proxy"] = normalize_proxy_url(proxy)
        _refuse_secrets_and_placeholders("--egress-proxy", out["egress_proxy"])

    helper = _optional(key_helper)
    if helper is not None:
        if not _KEY_HELPER_RE.fullmatch(helper):
            raise PackError(f"--key-helper contains characters the pack does not accept ({_redacted(helper)})")
        _refuse_secrets_and_placeholders("--key-helper", helper)
        out["key_helper"] = helper

    dk = _optional(desktop_key_helper)
    dkw = _optional(desktop_key_helper_windows)
    if dkw is not None and dk is None:
        raise PackError("--desktop-key-helper-windows needs --desktop-key-helper (the macOS/Linux path) as well")
    if dk is not None:
        problem = posix_helper_problem(dk)
        if problem:
            raise PackError(f"--desktop-key-helper {problem} ({_redacted(dk)})")
        _refuse_secrets_and_placeholders("--desktop-key-helper", dk)
        out["desktop_key_helper"] = dk
    if dkw is not None:
        problem = windows_helper_problem(dkw)
        if problem:
            raise PackError(f"--desktop-key-helper-windows {problem} ({_redacted(dkw)})")
        _refuse_secrets_and_placeholders("--desktop-key-helper-windows", dkw)
        out["desktop_key_helper_windows"] = dkw

    for raw in models or []:
        m = strip_boundary(raw)
        if not m:
            continue
        if not _MODEL_RE.fullmatch(m):
            raise PackError(f"a --models entry contains characters the pack does not accept ({_redacted(m)})")
        _refuse_secrets_and_placeholders("a --models entry", m)
        out["models"].append(m)
    return out


def render(
    gateway: str,
    *,
    spec: dict | None = None,
    models: list[str] | None = None,
    egress_proxy: str | None = None,
    key_helper: str | None = None,
    desktop_key_helper: str | None = None,
    desktop_key_helper_windows: str | None = None,
) -> dict[str, bytes]:
    spec = spec or load_spec()
    v = validate_inputs(
        gateway,
        models=models,
        egress_proxy=egress_proxy,
        key_helper=key_helper,
        desktop_key_helper=desktop_key_helper,
        desktop_key_helper_windows=desktop_key_helper_windows,
    )
    url = v["gateway"]
    ph = spec["placeholders"]
    mapping = {
        ph["gateway_url"]: url,
        ph["gateway_host"]: gateway_host(url),
        ph["gateway_port"]: gateway_port(url),
    }

    cc = build_claude_code(spec, mapping, v["key_helper"])
    pairs = build_desktop_pairs(
        spec,
        mapping,
        models=v["models"] or None,
        egress_proxy=v["egress_proxy"],
        desktop_key_helper=v["desktop_key_helper"],
        desktop_key_helper_windows=v["desktop_key_helper_windows"],
    )
    files = {
        spec["claude_code"]["filename"]: json.dumps(cc, indent=2, ensure_ascii=True) + "\n",
        spec["claude_desktop"]["mobileconfig_filename"]: render_mobileconfig(spec, mapping, pairs),
        spec["claude_desktop"]["reg_filename"]: render_reg(spec, url, pairs),
        spec["setup"]["filename"]: render_setup(spec, mapping),
    }
    return {name: files[name].encode("utf-8") for name in spec["output_order"]}


def write_pack(files: dict[str, bytes], output: Path, force: bool) -> None:
    """Write all files or none: every file is staged next to its target first,
    and only when all four are staged are they moved into place."""
    clashes = [n for n in files if (output / n).exists()]
    if clashes and not force:
        raise PackError(f"refusing to overwrite {', '.join(clashes)} in {output} (pass --force)")
    created_dir = not output.exists()
    output.mkdir(parents=True, exist_ok=True)
    staged: list[tuple[Path, Path]] = []
    try:
        for name, data in files.items():
            tmp = output / f".{name}.tmp-{os.getpid()}"
            staged.append((tmp, output / name))
            tmp.write_bytes(data)
    except OSError:
        for tmp, _ in staged:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass
        if created_dir:
            try:
                output.rmdir()
            except OSError:
                pass
        raise
    for tmp, target in staged:
        os.replace(tmp, target)


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="lucairn config-pack",
        description="Render Claude Code / Claude Desktop settings that route through a Lucairn gateway.",
    )
    p.add_argument("--gateway", required=True, help="gateway base URL, e.g. https://gateway.lucairn.eu")
    p.add_argument("--output", help="directory to write the pack into (required unless --print-golden)")
    p.add_argument("--models", help="comma-separated full model IDs for Claude Desktop's picker (inferenceModels)")
    p.add_argument("--egress-proxy", help="HTTP proxy URL for Claude Desktop (egressProxyUrl, MDM only)")
    p.add_argument("--key-helper", help="Claude Code apiKeyHelper command that prints the user's Lucairn key")
    p.add_argument(
        "--desktop-key-helper",
        help="absolute path of a Claude Desktop credential helper (macOS/Linux), under /Library/, /usr/local/ or /opt/",
    )
    p.add_argument(
        "--desktop-key-helper-windows",
        help="absolute path of the Claude Desktop credential helper on Windows, under C:\\Program Files\\",
    )
    p.add_argument("--force", action="store_true", help="overwrite existing files in --output")
    p.add_argument("--print-golden", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--print-corpus", action="store_true", help=argparse.SUPPRESS)
    return p.parse_args(argv)


def golden_doc(spec: dict, gateway: str, files: dict[str, bytes]) -> dict:
    """Content of config-pack/golden-sha256.json for this render."""
    import hashlib

    return {
        "_comment": (
            "Byte-for-byte pin of the default render. The lucairn.eu account area "
            "carries the same values; change both together."
        ),
        "gateway": normalize_gateway_url(gateway),
        "spec_sha256": hashlib.sha256(SPEC_PATH.read_bytes()).hexdigest(),
        "setup_template_sha256": hashlib.sha256((HERE / spec["setup"]["template"]).read_bytes()).hexdigest(),
        "files": {n: hashlib.sha256(d).hexdigest() for n, d in files.items()},
    }


def corpus_doc(spec: dict) -> dict:
    """Recompute config-pack/parity-corpus.json from its own inputs: the
    normalised URL and file hashes for every accepted gateway, and a check
    that every refused one is still refused."""
    import hashlib

    corpus = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))
    accepted = []
    for case in corpus["accepted"]:
        files = render(case["input"], spec=spec)
        accepted.append({
            "why": case["why"],
            "input": case["input"],
            "normalized": normalize_gateway_url(case["input"]),
            "files": {n: hashlib.sha256(d).hexdigest() for n, d in files.items()},
        })
    for case in corpus["refused"]:
        try:
            render(case["input"], spec=spec)
        except PackError:
            continue
        raise PackError(f"corpus case marked refused is accepted: {case['why']}")
    return {"_comment": corpus["_comment"], "accepted": accepted, "refused": corpus["refused"]}


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    spec = load_spec()
    try:
        if args.print_corpus:
            # Maintainer aid: regenerate parity-corpus.json (hashes only; the
            # inputs and the accept/refuse decision are edited by hand).
            print(json.dumps(corpus_doc(spec), indent=2, ensure_ascii=True))
            return 0
        files = render(
            args.gateway,
            spec=spec,
            models=args.models.split(",") if args.models else None,
            egress_proxy=args.egress_proxy,
            key_helper=args.key_helper,
            desktop_key_helper=args.desktop_key_helper,
            desktop_key_helper_windows=args.desktop_key_helper_windows,
        )
        if args.print_golden:
            # Maintainer aid: the content of config-pack/golden-sha256.json for
            # this gateway (only meaningful for the spec's default gateway with
            # no optional flags, which is what the website renders).
            print(json.dumps(golden_doc(spec, args.gateway, files), indent=2))
            return 0
        if not args.output:
            raise PackError("--output is required")
    except PackError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    # Check the rendered files (syntax, every key against the committed
    # docs-key snapshot, the policy values, no secrets) in a private temporary
    # directory BEFORE anything reaches --output: a pack that fails is never
    # written.
    sys.path.insert(0, str(HERE))
    import check as _check  # noqa: E402 - local module, imported lazily

    staging = Path(tempfile.mkdtemp(prefix="lucairn-config-pack-"))
    try:
        write_pack(files, staging, force=True)
        report = _check.check_dir(staging, args.gateway, spec)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    if report.failures:
        print(
            f"error: the rendered pack failed {len(report.failures)} check(s); nothing was written",
            file=sys.stderr,
        )
        return 1
    try:
        write_pack(files, Path(args.output), args.force)
    except (PackError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    for name in files:
        print(f"wrote {Path(args.output) / name}")
    print(f"checked: {report.passes} checks passed (syntax, docs key names, policy values, no secrets)")
    print(f"next: read {Path(args.output) / 'SETUP.md'} before deploying (credential and model list)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
