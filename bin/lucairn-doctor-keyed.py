#!/usr/bin/env python3
"""Run Lucairn's authenticated online doctor journey without exposing a key.

This helper is deliberately the sole reader of --key-file.  Its caller starts
it with an empty environment; this module neither reads proxy/CA settings from
the environment nor starts child processes.
"""

from __future__ import annotations

import argparse
import base64
import errno
import http.client
import json
import os
import re
import ssl
import stat
import sys
import time
from dataclasses import dataclass
from typing import List, Optional, Tuple
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


# Kit 2.0 (PRD row 2): a key minted for per-request BYOK (the mint default for
# Enterprise keys) carries no stored provider key, and this doctor holds no
# provider key either, so the gateway answers the keyed turn with exactly this
# refusal before any upstream call. On a managed-byok install (the hosted
# provider reached with the customer's own key) that is the install working as
# configured, not a fault, so it is a named skip. Only this exact answer
# qualifies: HTTP 400, the OpenAI-shaped error envelope the gateway writes on
# /v1/chat/completions (WriteOpenAIError), type invalid_request_error, code
# missing_upstream_key. Every other answer to the keyed turn still fails.
# K-E fix round 1 (review P2 on PR #162): the skip also needs the runtime mode
# bin/lucairn read from the install's runtime profile. A local-runtime install
# runs its own model and a split-remote install the Lucairn-provided remote
# Sandbox B; neither takes a provider key per request, so the same refusal
# there is a wrongly provisioned key and fails, naming that. An unknown mode
# fails as well.
BYOK_SKIP_MODES = frozenset({"managed-byok"})
BYOK_SKIP_LINES = (
    "keyed inference: skipped — per-request BYOK install, no provider key for the doctor; run one real turn to check it",
    "evidence: skipped (no keyed turn to read a certificate for)",
    "verification: skipped (no keyed turn to verify)",
)


def byok_refusal_failure(runtime_mode: Optional[str]) -> Optional[str]:
    """None when the per-request BYOK refusal is the named skip for this mode."""
    if runtime_mode in BYOK_SKIP_MODES:
        return None
    if isinstance(runtime_mode, str) and SAFE_TOKEN.fullmatch(runtime_mode):
        return (
            f"inference: failed (gateway refused the key with missing_upstream_key on a {runtime_mode} install: "
            "it was minted for per-request BYOK, which only a managed-byok install uses; "
            "mint the doctor key with --no-byok-per-request)"
        )
    return (
        "inference: failed (gateway refused the key with missing_upstream_key, and the doctor was not told "
        "this install's runtime mode, so the per-request BYOK skip does not apply)"
    )


def is_per_request_byok_refusal(code: int, body: bytes) -> bool:
    if code != 400:
        return False
    parsed = json_object(body)
    error = parsed.get("error") if parsed else None
    return (
        isinstance(error, dict)
        and error.get("type") == "invalid_request_error"
        and error.get("code") == "missing_upstream_key"
    )


# Kit 2.0 (PRD row 2; owner baseline 31 Oct: an L3-off certificate reads
# PARTIAL for the L3-coverage reason only, and that is accepted). The kit runs
# the L3 deep PII shield OFF by default, so the witness downgrades every
# certificate to COMPLETENESS_PARTIAL / VERDICT_PARTIAL: the sanitizer claim
# ran a live scan without "llm_pii_scan" in its signed layers_active (FAIL-02,
# veil-witness verifier/coverage.go L3CoverageDowngrade). VerificationResult
# has no reason field, so the causes are read from the same serialized fields
# and SIGNED claim payloads the witness derives the verdict from (verifier.go
# overall-verdict block; coverage.go; user_unredacted.go; inference_outcome.go;
# server/cert_server.go anchor rails + sealed-verdict ceiling). A PARTIAL
# passes ONLY when bin/lucairn reported L3 off for this install AND the
# L3-coverage downgrade is the sole cause. Any other cause, an unreadable
# field, or L3 configured on fails and names the cause.
L3_OFF_PARTIAL_LINE = "verdict partial: L3 off on this install (expected)"
L3_LAYER = "llm_pii_scan"
UNREDACTED_LAYER = "user_unredacted_segment"
# Layers that are not a live scan of this turn (coverage.go liveScanRan).
NOT_A_LIVE_SCAN = frozenset({"cache_replay", "sanitizer_internal_cache_replay", "secret_scan", UNREDACTED_LAYER})
SANITIZER_SERVICES = ("dsa-sanitizer", "dsa-sanitizer-streaming")
SAFE_TOKEN = re.compile(r"[A-Za-z0-9_.:=-]{1,64}")


def shown(value: object) -> str:
    """A server-supplied token, printed only when it is a plain short name."""
    return value if isinstance(value, str) and SAFE_TOKEN.fullmatch(value) else "unrecognised"


def l3_config_cause(value: Optional[str]) -> Optional[str]:
    if value == "off":
        return None
    if isinstance(value, str) and value.startswith("on:shell:") and SAFE_TOKEN.fullmatch(value[9:]):
        return (
            f"L3 is configured on for this install ({value[9:]}, exported in this shell: "
            "Docker Compose uses it over customer.env)"
        )
    if isinstance(value, str) and value.startswith("on:") and SAFE_TOKEN.fullmatch(value[3:]):
        return f"L3 is configured on for this install ({value[3:]})"
    if isinstance(value, str) and value.startswith("unknown:") and SAFE_TOKEN.fullmatch(value[8:]):
        return f"the doctor could not read this install's L3 settings through Docker Compose ({value[8:]})"
    return "the doctor was not told whether L3 is off on this install"


def verdict_component_causes(verification: dict, prefix: str = "") -> List[str]:
    causes = []
    for field in ("signatures_valid", "data_visibility_consistent", "isolation_verified", "temporal_consistent"):
        if verification.get(field) is not True:
            causes.append(f"{prefix}{field} is not true")
    missing = verification.get("missing_services")
    if not isinstance(missing, list) or not all(isinstance(item, str) for item in missing):
        causes.append(f"{prefix}missing_services is unreadable")
    elif missing:
        causes.append(f"{prefix}missing services: {', '.join(shown(item) for item in sorted(missing))}")
    # Only "valid" answers the ordering question (veil.proto temporal_order_status).
    if verification.get("temporal_order_status") != "valid":
        causes.append(f"{prefix}claim order {shown(verification.get('temporal_order_status'))}")
    if verification.get("completeness") != "COMPLETENESS_PARTIAL":
        causes.append(f"{prefix}completeness {shown(verification.get('completeness'))}, so L3 coverage is not the cause")
    anchors = verification.get("anchor_verifications", [])
    if not isinstance(anchors, list) or not all(isinstance(item, dict) for item in anchors):
        causes.append(f"{prefix}anchor_verifications is unreadable")
    else:
        for anchor in anchors:
            if anchor.get("outcome") == "ANCHOR_VERIFY_OUTCOME_FAILED":
                causes.append(f"{prefix}anchor {shown(anchor.get('rail'))} failed")
    return causes


def signed_claim_payload(claim: object) -> Optional[dict]:
    raw = claim.get("canonical_payload") if isinstance(claim, dict) else None
    if not isinstance(raw, str) or not raw:
        return None
    try:
        parsed = json.loads(base64.b64decode(raw, validate=True).decode("utf-8"))
    except ValueError:
        return None
    payload = parsed.get("payload") if isinstance(parsed, dict) else None
    return payload if isinstance(payload, dict) else None


def is_live_scan(layers: List[str]) -> bool:
    shallow = "secret_scan" in layers
    return any(layer not in NOT_A_LIVE_SCAN and not (shallow and layer == "known_entity_matching") for layer in layers)


def claim_chain_causes(certificate: dict) -> List[str]:
    claims = certificate.get("claims")
    if not isinstance(claims, list) or not claims:
        return ["certificate claims are unreadable"]
    causes = []
    sanitizer_seen = live_scan = False
    for claim in claims:
        service = claim.get("service_id") if isinstance(claim, dict) else None
        payload = signed_claim_payload(claim)
        if payload is None:
            causes.append(f"signed payload of claim {shown(service)} is unreadable")
            continue
        if "inference_outcome" in payload:
            causes.append(f"inference did not finish (claim {shown(service)})")
        if service not in SANITIZER_SERVICES:
            continue
        layers = payload.get("layers_active")
        if not isinstance(layers, list) or not all(isinstance(layer, str) for layer in layers):
            causes.append(f"layers_active of claim {shown(service)} is unreadable")
            continue
        if L3_LAYER in layers:
            causes.append(f"{L3_LAYER} present, so L3 coverage is not the cause")
        if UNREDACTED_LAYER in layers:
            causes.append("a message was sent unredacted")
        if service != "dsa-sanitizer":
            continue
        sanitizer_seen = True
        found = payload.get("pii_entities_found")
        if (
            not [layer for layer in layers if layer != UNREDACTED_LAYER]
            and isinstance(found, (int, float))
            and not isinstance(found, bool)
            and found > 0
        ):
            causes.append("redactions attributed to no layer")
        live_scan = live_scan or is_live_scan(layers)
    if not sanitizer_seen:
        causes.append("no sanitizer claim")
    elif not live_scan:
        causes.append("no live scan on this request, so L3 coverage is not the cause")
    return causes


def partial_verdict_causes(verification: dict, certificate: Optional[dict], l3_config: Optional[str]) -> List[str]:
    """Every cause of a VERDICT_PARTIAL other than L3 coverage on an L3-off install."""
    causes = []
    l3_cause = l3_config_cause(l3_config)
    if l3_cause:
        causes.append(l3_cause)
    causes += verdict_component_causes(verification)
    if certificate is None:
        causes.append("certificate is unreadable")
    else:
        # /verify never reports better than the sealed verdict (cert_server.go
        # sealed-verdict ceiling), so a sealed PARTIAL must be explained too.
        sealed = certificate.get("verification")
        sealed_verdict = sealed.get("overall_verdict") if isinstance(sealed, dict) else None
        if sealed_verdict == "VERDICT_PARTIAL":
            causes += verdict_component_causes(sealed, "sealed ")
        elif sealed_verdict != "VERDICT_VERIFIED":
            causes.append(f"sealed verdict {shown(sealed_verdict)}")
        causes += claim_chain_causes(certificate)
    return list(dict.fromkeys(causes))


def run_journey(
    key_file: str,
    gateway_url: str,
    model: str,
    proxy_url: Optional[str],
    ca_file: Optional[str],
    l3_config: Optional[str] = None,
    runtime_mode: Optional[str] = None,
) -> None:
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
    if is_per_request_byok_refusal(code, body):
        failure = byok_refusal_failure(runtime_mode)
        if failure:
            fail(failure)
        for line in BYOK_SKIP_LINES:
            print(line)
        return
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
    certificate: Optional[dict] = None
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
        certificate = json_object(body)
        if not certificate:
            fail("evidence: failed (certificate response is malformed)")
        break
    else:
        fail("evidence: failed (certificate was not ready after 12 attempts)")
    print("evidence: ok (certificate received)")

    code, body = client.request("POST", "/api/v1/veil/verify", {"request_id": request_id})
    if code != 200:
        fail(f"verification: failed (verify endpoint returned HTTP {code if code is not None else 0})")
    verification = json_object(body)
    verdict = verification.get("overall_verdict") if verification else None
    if not verification or not (
        verification.get("signatures_valid") is True
        and verdict in ("VERDICT_VERIFIED", "VERDICT_PARTIAL")
    ):
        fail("verification: failed (response is malformed or witness signature is not verified)")
    if verdict == "VERDICT_PARTIAL":
        causes = partial_verdict_causes(verification, certificate, l3_config)
        if causes:
            fail(f"verification: failed (verdict partial: {'; '.join(causes)})")
    print("verification: ok (witness signature: verified; anchors: not checked)")
    if verdict == "VERDICT_PARTIAL":
        print(L3_OFF_PARTIAL_LINE)
    print("doctor: ok")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--gateway-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--proxy", help="explicit HTTP CONNECT/forward proxy; environment is ignored")
    parser.add_argument("--ca-file", help="explicit private CA bundle for an HTTPS gateway")
    parser.add_argument(
        "--l3-config",
        help='"off", or "on:<setting name>" for the install\'s L3 shield; absent = unknown (a partial verdict fails)',
    )
    parser.add_argument(
        "--runtime-mode",
        help="the install's recorded runtime mode; the per-request BYOK skip applies to managed-byok only",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    if sys.version_info < MINIMUM_PYTHON:
        print("configuration: failed (online doctor requires Python 3.8+)", file=sys.stderr)
        return 1
    try:
        args = parse_args(argv)
        run_journey(
            args.key_file, args.gateway_url, args.model, args.proxy, args.ca_file, args.l3_config, args.runtime_mode
        )
    except DoctorFailure as exc:
        print(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
