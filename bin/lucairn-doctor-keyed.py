#!/usr/bin/env python3
"""Run Lucairn's authenticated online doctor journey without exposing a key.

This helper is deliberately the sole reader of --key-file.  Its caller starts
it with an empty environment; this module neither reads proxy/CA settings from
the environment nor starts child processes.
"""

from __future__ import annotations

import argparse
import errno
import http.client
import json
import os
import ssl
import stat
import sys
import time
from dataclasses import dataclass
from typing import Optional, Tuple
from urllib.parse import quote, urlsplit, urlunsplit


MINIMUM_PYTHON: Tuple[int, int] = (3, 8)
MAX_KEY_BYTES = 4096
MAX_RESPONSE_BYTES = 1024 * 1024
ALLOWED_KEY_BYTES = frozenset(
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-"
)


class DoctorFailure(Exception):
    """An expected, key-free customer-facing doctor failure."""


def fail(message: str) -> None:
    raise DoctorFailure(message)


def customer_key_failure(detail: str) -> None:
    fail(f"configuration: failed ({detail})")


def read_customer_key(path: str) -> bytes:
    """Open once without following links, then validate bytes from that FD."""
    try:
        entry = os.lstat(path)
    except OSError:
        customer_key_failure("customer key file is not an existing regular file")
    if stat.S_ISLNK(entry.st_mode):
        customer_key_failure("customer key file is not an existing regular file")

    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if not nofollow:
        # Supported Lucairn hosts have O_NOFOLLOW.  Do not silently weaken the
        # symlink guarantee on an exotic Python/platform combination.
        customer_key_failure("customer key file cannot be opened safely")
    flags = os.O_RDONLY | os.O_CLOEXEC | nofollow
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOENT, errno.ENOTDIR):
            customer_key_failure("customer key file is not an existing regular file")
        customer_key_failure("customer key file is not readable")

    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            customer_key_failure("customer key file is not an existing regular file")
        if stat.S_IMODE(metadata.st_mode) != 0o600:
            customer_key_failure("customer key file must have mode 0600")

        parts = []
        size = 0
        while True:
            chunk = os.read(fd, min(4096, MAX_KEY_BYTES + 1 - size))
            if not chunk:
                break
            parts.append(chunk)
            size += len(chunk)
            if size > MAX_KEY_BYTES:
                customer_key_failure("customer key file is malformed")
        raw = b"".join(parts)
    except OSError:
        customer_key_failure("customer key file is not readable")
    finally:
        os.close(fd)

    if not raw:
        customer_key_failure("customer key file is empty")
    # A conventional final LF is permitted.  Every other LF, CR, NUL, high
    # byte, or unlisted ASCII byte is rejected by the byte grammar below.
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    if not raw or not raw.startswith((b"dsa_", b"lcr_live_")):
        customer_key_failure("customer key file is malformed")
    prefix_length = 4 if raw.startswith(b"dsa_") else len(b"lcr_live_")
    if len(raw) == prefix_length or any(byte not in ALLOWED_KEY_BYTES for byte in raw):
        customer_key_failure("customer key file is malformed")
    return raw


@dataclass(frozen=True)
class Proxy:
    host: str
    port: int


@dataclass(frozen=True)
class Gateway:
    scheme: str
    host: str
    port: int
    base_path: str

    @classmethod
    def from_url(cls, value: str) -> "Gateway":
        try:
            parsed = urlsplit(value)
        except ValueError:
            customer_key_failure("GATEWAY_BASE_URL is invalid for online doctor")
        if (
            parsed.scheme not in ("http", "https")
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
        ):
            customer_key_failure("GATEWAY_BASE_URL is invalid for online doctor")
        try:
            port = parsed.port or (443 if parsed.scheme == "https" else 80)
        except ValueError:
            customer_key_failure("GATEWAY_BASE_URL is invalid for online doctor")
        return cls(parsed.scheme, parsed.hostname, port, parsed.path.rstrip("/"))

    def endpoint(self, suffix: str) -> str:
        return f"{self.base_path}{suffix}" or "/"

    def absolute_endpoint(self, suffix: str) -> str:
        netloc = self.host
        default_port = 443 if self.scheme == "https" else 80
        if self.port != default_port:
            netloc = f"{netloc}:{self.port}"
        return urlunsplit((self.scheme, netloc, self.endpoint(suffix), "", ""))


def parse_proxy(value: Optional[str]) -> Optional[Proxy]:
    if not value:
        return None
    try:
        parsed = urlsplit(value)
    except ValueError:
        customer_key_failure("online doctor proxy must be an http:// URL")
    if (
        parsed.scheme != "http"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        customer_key_failure("online doctor proxy must be an http:// URL")
    try:
        port = parsed.port or 80
    except ValueError:
        customer_key_failure("online doctor proxy must be an http:// URL")
    return Proxy(parsed.hostname, port)


class AuthenticatedClient:
    """In-process HTTP client: no curl child, no proxy/CA environment lookup."""

    def __init__(self, gateway: Gateway, key: bytes, proxy: Optional[Proxy], ca_file: Optional[str]):
        self.gateway = gateway
        self.api_key = key.decode("ascii")
        self.proxy = proxy
        self.context: Optional[ssl.SSLContext] = None
        if gateway.scheme == "https":
            self.context = ssl.create_default_context()
            if ca_file:
                try:
                    self.context.load_verify_locations(cafile=ca_file)
                except (OSError, ssl.SSLError):
                    customer_key_failure("online doctor private CA file is not readable")

    def request(self, method: str, suffix: str, payload: Optional[dict] = None) -> Tuple[Optional[int], bytes]:
        endpoint = self.gateway.endpoint(suffix)
        target = endpoint
        connection: http.client.HTTPConnection
        if self.proxy:
            if self.gateway.scheme == "https":
                connection = http.client.HTTPSConnection(
                    self.proxy.host, self.proxy.port, timeout=5, context=self.context
                )
                connection.set_tunnel(self.gateway.host, self.gateway.port)
            else:
                connection = http.client.HTTPConnection(self.proxy.host, self.proxy.port, timeout=5)
                target = self.gateway.absolute_endpoint(suffix)
        elif self.gateway.scheme == "https":
            connection = http.client.HTTPSConnection(
                self.gateway.host, self.gateway.port, timeout=5, context=self.context
            )
        else:
            connection = http.client.HTTPConnection(self.gateway.host, self.gateway.port, timeout=5)

        body = None
        headers = {"x-api-key": self.api_key}
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            connection.request(method, target, body=body, headers=headers)
            response = connection.getresponse()
            response_body = response.read(MAX_RESPONSE_BYTES + 1)
            if len(response_body) > MAX_RESPONSE_BYTES:
                return response.status, b""
            return response.status, response_body
        except (OSError, http.client.HTTPException, ssl.SSLError):
            return None, b""
        finally:
            connection.close()


def json_object(body: bytes) -> Optional[dict]:
    try:
        parsed = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return parsed if isinstance(parsed, dict) else None


def run_journey(key_file: str, gateway_url: str, model: str, proxy_url: Optional[str], ca_file: Optional[str]) -> None:
    key = read_customer_key(key_file)
    gateway = Gateway.from_url(gateway_url)
    client = AuthenticatedClient(gateway, key, parse_proxy(proxy_url), ca_file)
    request_payload = {
        "model": model,
        "messages": [{"role": "user", "content": "Respond with the word ready."}],
        "max_tokens": 8,
    }
    code, body = client.request("POST", "/v1/chat/completions", request_payload)
    if code is None:
        fail("runtime: failed (gateway not started)")
    if not 200 <= code < 300:
        fail(f"inference: failed (gateway returned HTTP {code})")
    inference = json_object(body)
    request_id = None
    if inference:
        metadata = inference.get("metadata")
        if isinstance(metadata, dict):
            compliance = metadata.get("dsa_compliance")
            if isinstance(compliance, dict):
                candidate = compliance.get("request_id")
                if isinstance(candidate, str) and candidate:
                    request_id = candidate
    if not request_id:
        fail("inference: failed (response is malformed or missing metadata.dsa_compliance.request_id)")
    print("inference: ok (authenticated)")

    encoded_request_id = quote(request_id, safe="")
    for attempt in range(1, 13):
        code, body = client.request("GET", f"/api/v1/veil/certificate/{encoded_request_id}")
        if code == 202:
            if attempt < 12:
                time.sleep(3)
            continue
        if code is None:
            fail("evidence: failed (certificate endpoint unavailable)")
        if code != 200:
            fail(f"evidence: failed (certificate endpoint returned HTTP {code})")
        if not json_object(body):
            fail("evidence: failed (certificate response is malformed)")
        break
    else:
        fail("evidence: failed (certificate was not ready after 12 attempts)")
    print("evidence: ok (certificate received)")

    code, body = client.request("POST", "/api/v1/veil/verify", {"request_id": request_id})
    if code != 200:
        fail(f"verification: failed (verify endpoint returned HTTP {code if code is not None else 0})")
    verification = json_object(body)
    if not verification or not (
        verification.get("signatures_valid") is True
        and verification.get("overall_verdict") == "VERDICT_VERIFIED"
    ):
        fail("verification: failed (response is malformed or witness signature is not verified)")
    print("verification: ok (witness signature: verified; anchors: not checked)")
    print("doctor: ok")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--gateway-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--proxy", help="explicit HTTP CONNECT/forward proxy; environment is ignored")
    parser.add_argument("--ca-file", help="explicit private CA bundle for an HTTPS gateway")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    if sys.version_info < MINIMUM_PYTHON:
        print("configuration: failed (online doctor requires Python 3.8+)", file=sys.stderr)
        return 1
    try:
        args = parse_args(argv)
        run_journey(args.key_file, args.gateway_url, args.model, args.proxy, args.ca_file)
    except DoctorFailure as exc:
        print(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
