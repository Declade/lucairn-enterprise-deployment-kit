#!/usr/bin/env python3
"""Render the Lucairn config pack for one gateway URL.

Reads config-pack/spec.json (the single source of truth for every key and
value) and config-pack/SETUP.md.tmpl, substitutes the gateway URL, and writes:

  managed-settings.json        Claude Code managed settings
  claude-desktop.mobileconfig  Claude Desktop (third-party mode), macOS profile
  claude-desktop.reg           Claude Desktop (third-party mode), Windows policy
  SETUP.md                     Install steps, credential options, firewall note

No output ever contains a Lucairn key. The Claude Desktop files carry the
placeholder REPLACE_WITH_YOUR_LUCAIRN_KEY in `inferenceGatewayApiKey`, with
`inferenceCredentialKind` = `static`. The pack has no Claude Desktop credential
helper option: the vendor documents that a helper's headers are "merged over"
the profile's static headers, "helper wins on conflict", so a helper could
switch the require header off (config-pack/README.md, "Left out on purpose").

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
# website's TypeScript port (src/lib/configPack/gatewayUrl.ts) implements the same
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
# it survives JSON encoding unchanged in meaning. The vendor documents that
# Claude Code sends the helper's output "as both the `X-Api-Key` and
# `Authorization: Bearer` headers": a key, never extra headers.
_KEY_HELPER_RE = re.compile(r"[A-Za-z0-9 _./:\\~+=,@-]{1,400}")
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

# Escapes a consumer of a pack file (or of a value inside it) may decode:
# backslash escapes as JSON, JavaScript, Python and printf know them, HTML/XML
# character references, and percent-encoding. A secret written in any of them
# is still a secret, so every scan runs over each decoding as well.
_BACKSLASH_ESCAPE_RE = re.compile(
    r"\\(u\{[0-9A-Fa-f]{1,6}\}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|x[0-9A-Fa-f]{2}|[0-7]{1,3}|.)", re.DOTALL
)
_CHAR_REF_RE = re.compile(r"&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});?")
_PERCENT_RE = re.compile(r"%([0-9A-Fa-f]{2})")
# The named references whose character can appear in a key shape, plus the five
# XML ones. The website's TypeScript port decodes the same set.
_NAMED_REFS = {
    "amp": "&", "lt": "<", "gt": ">", "quot": '"', "apos": "'",
    "lowbar": "_", "UnderBar": "_", "hyphen": "-", "dash": "-", "minus": "-",
}
_DECODE_ROUNDS = 4


def _from_code_point(cp: int) -> str:
    return chr(cp) if 0 <= cp <= 0x10FFFF and not 0xD800 <= cp <= 0xDFFF else "\ufffd"


def _decode_backslashes(value: str) -> str:
    def one(m: "re.Match[str]") -> str:
        esc = m.group(1)
        if esc.startswith("u{"):
            return _from_code_point(int(esc[2:-1], 16))
        if esc[0] in "uUx" and len(esc) > 1:
            return _from_code_point(int(esc[1:], 16))
        if esc[0] in "01234567":
            return _from_code_point(int(esc, 8))
        return esc

    return _BACKSLASH_ESCAPE_RE.sub(one, value)


def _decode_char_refs(value: str) -> str:
    def one(m: "re.Match[str]") -> str:
        ref = m.group(1)
        if ref.startswith(("#x", "#X")):
            return _from_code_point(int(ref[2:], 16))
        if ref.startswith("#"):
            return _from_code_point(int(ref[1:], 10))
        return _NAMED_REFS.get(ref, m.group(0))

    return _CHAR_REF_RE.sub(one, value)


def _decode_percent(value: str) -> str:
    return _PERCENT_RE.sub(lambda m: chr(int(m.group(1), 16)), value)


def decoded_variants(value: str) -> list[str]:
    """`value` as written, and as each decoder (and every combination of them,
    up to four rounds) would read it. The website port computes the same set."""
    seen = [value]
    frontier = [value]
    for _ in range(_DECODE_ROUNDS):
        nxt = []
        for v in frontier:
            for decode in (_decode_backslashes, _decode_char_refs, _decode_percent):
                d = decode(v)
                if d not in seen:
                    seen.append(d)
                    nxt.append(d)
        if not nxt:
            break
        frontier = nxt
    return seen


def secret_shape_in(value: str) -> str | None:
    """The pattern of the first secret shape found in `value` or in any of its
    decodings, or None. Callers name the pattern, never the value."""
    for variant in decoded_variants(value):
        for pat in SECRET_PATTERNS:
            if pat.search(variant):
                return pat.pattern
    return None


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


# --- Punycode (RFC 3492) -----------------------------------------------------
# A label that starts with `xn--` (any letter case) is decoded the way a WHATWG
# URL parser decodes it (UTS #46). Only a label that decodes cleanly, holds at
# least one non-ASCII letter, re-encodes to exactly itself and decodes to
# letters from a small fixed set (below) is accepted, so the pack never pins a
# host that browsers, Node or Claude Desktop would refuse or rewrite. The
# website port implements the same algorithm and the same set.
_PUNY_BASE, _PUNY_TMIN, _PUNY_TMAX, _PUNY_SKEW, _PUNY_DAMP = 36, 1, 26, 38, 700
_PUNY_INITIAL_BIAS, _PUNY_INITIAL_N, _PUNY_MAXINT = 72, 0x80, 0x7FFFFFFF


def _puny_adapt(delta: int, numpoints: int, first: bool) -> int:
    delta = delta // _PUNY_DAMP if first else delta // 2
    delta += delta // numpoints
    k = 0
    while delta > ((_PUNY_BASE - _PUNY_TMIN) * _PUNY_TMAX) // 2:
        delta //= _PUNY_BASE - _PUNY_TMIN
        k += _PUNY_BASE
    return k + ((_PUNY_BASE - _PUNY_TMIN + 1) * delta) // (delta + _PUNY_SKEW)


def _puny_threshold(k: int, bias: int) -> int:
    if k <= bias:
        return _PUNY_TMIN
    if k >= bias + _PUNY_TMAX:
        return _PUNY_TMAX
    return k - bias


def punycode_decode(encoded: str) -> list[int] | None:
    """RFC 3492 decoding of a lower-case ASCII string (the part after `xn--`).
    Returns the code points, or None on any error (bad digit, overflow, a
    basic or surrogate code point produced by the digits)."""
    b = encoded.rfind("-")
    output = [ord(c) for c in encoded[:b]] if b > 0 else []
    if any(c >= 0x80 for c in output):
        return None
    pos = b + 1 if b > 0 else 0
    n, i, bias = _PUNY_INITIAL_N, 0, _PUNY_INITIAL_BIAS
    while pos < len(encoded):
        oldi, w, k = i, 1, _PUNY_BASE
        while True:
            if pos >= len(encoded):
                return None
            c = encoded[pos]
            pos += 1
            if "a" <= c <= "z":
                digit = ord(c) - 0x61
            elif "0" <= c <= "9":
                digit = ord(c) - 0x30 + 26
            else:
                return None
            i += digit * w
            if i > _PUNY_MAXINT:
                return None
            t = _puny_threshold(k, bias)
            if digit < t:
                break
            w *= _PUNY_BASE - t
            if w > _PUNY_MAXINT:
                return None
            k += _PUNY_BASE
        size = len(output) + 1
        bias = _puny_adapt(i - oldi, size, oldi == 0)
        n += i // size
        i %= size
        if n > 0x10FFFF or n < 0x80 or 0xD800 <= n <= 0xDFFF:
            return None
        output.insert(i, n)
        i += 1
    return output


def punycode_encode(code_points: list[int]) -> str:
    """RFC 3492 encoding (lower-case digits), the inverse of punycode_decode."""
    out = [chr(c) for c in code_points if c < 0x80]
    b = h = len(out)
    if b:
        out.append("-")
    n, delta, bias = _PUNY_INITIAL_N, 0, _PUNY_INITIAL_BIAS
    while h < len(code_points):
        m = min(c for c in code_points if c >= n)
        delta += (m - n) * (h + 1)
        n = m
        for c in code_points:
            if c < n:
                delta += 1
            elif c == n:
                q, k = delta, _PUNY_BASE
                while True:
                    t = _puny_threshold(k, bias)
                    if q < t:
                        break
                    d = t + (q - t) % (_PUNY_BASE - t)
                    out.append(chr(d + 0x61) if d < 26 else chr(d - 26 + 0x30))
                    q = (q - t) // (_PUNY_BASE - t)
                    k += _PUNY_BASE
                out.append(chr(q + 0x61) if q < 26 else chr(q - 26 + 0x30))
                bias = _puny_adapt(delta, h + 1, h == b)
                delta = 0
                h += 1
        delta += 1
        n += 1
    return "".join(out)


def idn_letter_ok(cp: int) -> bool:
    """Code points a decoded `xn--` label may hold: ASCII lower-case letters,
    digits and hyphen, and the lower-case letters of Latin-1 Supplement and
    Latin Extended-A that UTS #46 keeps as they are (so `ĳ`, `ŀ`, `ŉ`, `ſ` and
    every upper-case letter are out; `ß` is in, as the WHATWG URL parser keeps
    it). Everything else is refused, even where a URL parser would accept it:
    a smaller set both renderers can agree on without Unicode tables."""
    if 0x61 <= cp <= 0x7A or 0x30 <= cp <= 0x39 or cp == 0x2D:
        return True
    if 0xDF <= cp <= 0xF6 or 0xF8 <= cp <= 0xFF:
        return True
    if 0x101 <= cp <= 0x137:
        return cp % 2 == 1 and cp != 0x133
    if cp == 0x138:
        return True
    if 0x13A <= cp <= 0x148:
        return cp % 2 == 0 and cp != 0x140
    if 0x14B <= cp <= 0x177:
        return cp % 2 == 1
    return cp in (0x17A, 0x17C, 0x17E)


def valid_ace_label(label: str) -> bool:
    """An `xn--` label (any letter case) a WHATWG URL parser keeps unchanged
    apart from letter case, within the letter set above."""
    rest = label.lower()[4:]
    decoded = punycode_decode(rest)
    if not decoded or all(c < 0x80 for c in decoded):
        return False
    if not all(idn_letter_ok(c) for c in decoded):
        return False
    return punycode_encode(decoded) == rest


def valid_host(host: str) -> bool:
    """A DNS host name of ASCII letters, digits and hyphens (punycode labels
    included when they decode cleanly, Unicode not), or a plain dotted-quad
    IPv4 address. No trailing dot, no empty label, at most 253 characters."""
    if not host or len(host) > _MAX_HOST_LEN:
        return False
    labels = host.split(".")
    if not all(_LABEL_RE.fullmatch(label) for label in labels):
        return False
    if any(label[:4].lower() == "xn--" and not valid_ace_label(label) for label in labels):
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
) -> list[tuple[str, str]]:
    pairs = [(k, _substitute(v, mapping)) for k, v in spec["claude_desktop"]["keys"]]
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
    """Refuse a key shape or the pack's own placeholder text, as written or in
    any decoding (a helper command can print `\\u006ccr_live_...` as a key)."""
    if secret_shape_in(value):
        raise PackError(f"{name} looks like it contains a key; keys never go into the pack ({_redacted(value)})")
    if any(t in variant for variant in decoded_variants(value) for t in _RESERVED_TEXT):
        raise PackError(f"{name} contains the pack's own placeholder text ({_redacted(value)})")


def validate_inputs(
    gateway: str,
    *,
    models: list[str] | None = None,
    egress_proxy: str | None = None,
    key_helper: str | None = None,
) -> dict:
    """Check every input before anything is rendered or written. Raises
    PackError naming the input and the rule, never the rejected value."""
    url = normalize_gateway_url(gateway)
    out: dict = {"gateway": url, "models": [], "egress_proxy": None, "key_helper": None}
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
) -> dict[str, bytes]:
    spec = spec or load_spec()
    v = validate_inputs(gateway, models=models, egress_proxy=egress_proxy, key_helper=key_helper)
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
    p.add_argument("--force", action="store_true", help="overwrite existing files in --output")
    p.add_argument("--print-golden", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--print-corpus", action="store_true", help=argparse.SUPPRESS)
    args, unknown = p.parse_known_args(argv)
    if unknown:
        # Name the options only: argparse's own message would repeat their
        # values, and errors never echo an input.
        names = sorted({u.split("=", 1)[0] for u in unknown if u.startswith("-")})
        hint = ""
        if any(n.startswith("--desktop-key-helper") for n in names):
            hint = (
                "; Claude Desktop credential helpers are not part of the pack (a helper's headers "
                "override the require header), see config-pack/README.md"
            )
        p.error(f"unknown option(s): {', '.join(names) or '<redacted positional argument>'}{hint}")
    return args


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
