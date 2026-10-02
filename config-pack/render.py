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

The lucairn.eu account area renders the default output (gateway URL only) with
a TypeScript port of this file; config-pack/golden-sha256.json pins that
output byte for byte so the two renderers cannot drift apart unnoticed.

Python 3.8+, standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape as _xml_escape

HERE = Path(__file__).resolve().parent
SPEC_PATH = HERE / "spec.json"

# https only, host[:port], optional path made of URL-safe characters, no
# userinfo, query or fragment. The narrow alphabet means the value needs no
# escaping in any of the four output formats. The website's TypeScript port
# (src/lib/configPack/render.ts) uses these exact two patterns.
_GATEWAY_RE = re.compile(
    r"^https://(?P<host>[A-Za-z0-9.-]+)(?::(?P<port>[0-9]{1,5}))?(?P<path>/[A-Za-z0-9._~/-]*)?$"
)
_HOST_RE = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
)
_PROXY_RE = re.compile(r"^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$")
_MODEL_RE = re.compile(r"^[A-Za-z0-9._:/@\[\]-]{1,200}$")
# An executable path or command line: printable ASCII without quotes, so it
# survives JSON, plist and .reg encoding unchanged in meaning.
_HELPER_RE = re.compile(r"^[A-Za-z0-9 _./:\\~+=,@-]{1,400}$")


class PackError(ValueError):
    """Invalid input to the renderer."""


def load_spec(path: Path = SPEC_PATH) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def normalize_gateway_url(raw: str) -> str:
    value = (raw or "").strip()
    m = _GATEWAY_RE.match(value)
    if not m:
        raise PackError(
            "gateway URL must look like https://gateway.example.com (https, a host name, "
            "optional port and path; no user info, query or fragment)"
        )
    if not _HOST_RE.match(m.group("host")):
        raise PackError("gateway URL has an invalid host name")
    if m.group("port") is not None and not 1 <= int(m.group("port")) <= 65535:
        raise PackError("gateway URL has an invalid port")
    return value.rstrip("/")


def gateway_host(url: str) -> str:
    """host[:port] exactly as written (no case folding)."""
    return url[len("https://"):].split("/", 1)[0]


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


def _reg_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


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
    desk = spec["claude_desktop"]
    prof = _substitute(desk["profile"], mapping)
    domain = desk["preference_domain"]
    x = _xml_escape
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
    desk = spec["claude_desktop"]
    lines = [
        "Windows Registry Editor Version 5.00",
        "",
        "; Lucairn gateway settings for Claude Desktop (third-party inference mode).",
        f"; Gateway: {gateway_url}",
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


def _check_optional(name: str, value: str | None, pattern: re.Pattern) -> str | None:
    if value is None:
        return None
    value = value.strip()
    if not value:
        return None
    if not pattern.match(value):
        raise PackError(f"{name} contains characters the pack does not accept: {value!r}")
    return value


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
    url = normalize_gateway_url(gateway)
    egress_proxy = _check_optional("--egress-proxy", egress_proxy, _PROXY_RE)
    key_helper = _check_optional("--key-helper", key_helper, _HELPER_RE)
    desktop_key_helper = _check_optional("--desktop-key-helper", desktop_key_helper, _HELPER_RE)
    desktop_key_helper_windows = _check_optional(
        "--desktop-key-helper-windows", desktop_key_helper_windows, _HELPER_RE
    )
    clean_models = []
    for m in models or []:
        m = m.strip()
        if not m:
            continue
        if not _MODEL_RE.match(m):
            raise PackError(f"model id contains characters the pack does not accept: {m!r}")
        clean_models.append(m)

    ph = spec["placeholders"]
    mapping = {ph["gateway_url"]: url, ph["gateway_host"]: gateway_host(url)}

    cc = build_claude_code(spec, mapping, key_helper)
    pairs = build_desktop_pairs(
        spec,
        mapping,
        models=clean_models or None,
        egress_proxy=egress_proxy,
        desktop_key_helper=desktop_key_helper,
        desktop_key_helper_windows=desktop_key_helper_windows,
    )
    files = {
        spec["claude_code"]["filename"]: json.dumps(cc, indent=2, ensure_ascii=True) + "\n",
        spec["claude_desktop"]["mobileconfig_filename"]: render_mobileconfig(spec, mapping, pairs),
        spec["claude_desktop"]["reg_filename"]: render_reg(spec, url, pairs),
        spec["setup"]["filename"]: render_setup(spec, mapping),
    }
    return {name: files[name].encode("utf-8") for name in spec["output_order"]}


def write_pack(files: dict[str, bytes], output: Path, force: bool) -> None:
    output.mkdir(parents=True, exist_ok=True)
    clashes = [n for n in files if (output / n).exists()]
    if clashes and not force:
        raise PackError(f"refusing to overwrite {', '.join(clashes)} in {output} (pass --force)")
    for name, data in files.items():
        target = output / name
        tmp = output / f".{name}.tmp-{os.getpid()}"
        tmp.write_bytes(data)
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
    p.add_argument("--desktop-key-helper", help="absolute path of a Claude Desktop credential helper (macOS/Linux)")
    p.add_argument("--desktop-key-helper-windows", help="absolute path of the Claude Desktop credential helper on Windows")
    p.add_argument("--force", action="store_true", help="overwrite existing files in --output")
    p.add_argument("--print-golden", action="store_true", help=argparse.SUPPRESS)
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        files = render(
            args.gateway,
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
            import hashlib

            spec = load_spec()
            doc = {
                "_comment": (
                    "Byte-for-byte pin of the default render. The lucairn.eu account area "
                    "carries the same values; change both together."
                ),
                "gateway": normalize_gateway_url(args.gateway),
                "spec_sha256": hashlib.sha256(SPEC_PATH.read_bytes()).hexdigest(),
                "setup_template_sha256": hashlib.sha256(
                    (HERE / spec["setup"]["template"]).read_bytes()
                ).hexdigest(),
                "files": {n: hashlib.sha256(d).hexdigest() for n, d in files.items()},
            }
            print(json.dumps(doc, indent=2))
            return 0
        if not args.output:
            raise PackError("--output is required")
        write_pack(files, Path(args.output), args.force)
    except PackError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    for name in files:
        print(f"wrote {Path(args.output) / name}")

    # Validate what was just written: syntax of all three formats, every key
    # against the committed docs-key snapshot, and the no-secret rules.
    sys.path.insert(0, str(HERE))
    import check as _check  # noqa: E402 - local module, imported lazily

    report = _check.check_dir(Path(args.output), args.gateway, load_spec())
    if report.failures:
        print(f"error: the rendered pack failed {len(report.failures)} check(s); do not deploy it", file=sys.stderr)
        return 1
    print(f"checked: {report.passes} checks passed (syntax, docs key names, no secrets)")
    print(f"next: read {Path(args.output) / 'SETUP.md'} before deploying (credential and model list)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
