#!/usr/bin/env python3
# FOR LUCAIRN'S OWN TEST INSTALLS ONLY; NOT A CUSTOMER LICENCE.
#
# Writes a synthetic platform licence file (license.json) for
# `bin/lucairn-init --production --license <file>` on a throwaway test server.
# A customer receives a real licence from Lucairn with the contract
# (INSTALL.md, fast path, "You need from Lucairn"); this helper is not part of
# the customer path and is not documented there.
#
# Format (gateway images 1.1.1, services/gateway/internal/license/license.go,
# GenerateKey :37 / ValidateKey :51 / sign :146 in DSA tag v1.1.1):
#   license_key = base64url(json(License)) "." base64url(HMAC-SHA256(payload, signing_key))
#   (base64url without padding; the HMAC key is the signing_key string's bytes)
# The gateway refuses to start on a wrong signature or an expired licence
# (cmd/server/main.go:629-632); this helper writes a fresh random signing key,
# so the pair is only valid together.
#
# No entitlement token (Ed25519) is written: the install then runs
# "unregistered (Enterprise features locked; core pipeline runs)", as in the
# proof runs of 21 and 22 Nov 2026.
#
# Usage: make_test_license.py --out license.json [--days 30] [--customer-id ID]
#                             [--customer-name NAME] [--tier enterprise]
# Prints only the path and the expiry date, never the key values.
# Python 3 standard library only.
import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
from datetime import datetime, timedelta, timezone

TIER_DEFAULTS = {
    # Mirrors DefaultLicense in license.go:110 (images 1.1.1).
    "free": dict(monthly_request_limit=500, managed_ai=True, max_api_keys=1,
                 sanitizer_config_access="default", audit_export_enabled=False),
    "pro": dict(monthly_request_limit=50000, managed_ai=False, max_api_keys=5,
                sanitizer_config_access="managed", audit_export_enabled=True),
    "enterprise": dict(monthly_request_limit=0, managed_ai=False, max_api_keys=0,
                       sanitizer_config_access="self-service", audit_export_enabled=True),
}


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def rfc3339(t: datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def make(days: int, customer_id: str, customer_name: str, tier: str, now: datetime):
    signing_key = secrets.token_hex(32)
    claims = {
        "customer_id": customer_id,
        "customer_name": customer_name,
        "tier": tier,
        "expires_at": rfc3339(now + timedelta(days=days)),
        **TIER_DEFAULTS[tier],
        "issued_at": rfc3339(now),
        "license_id": "test-" + secrets.token_hex(8),
    }
    payload = b64url(json.dumps(claims, separators=(",", ":")).encode("utf-8"))
    sig = hmac.new(signing_key.encode("utf-8"), payload.encode("ascii"), hashlib.sha256).digest()
    return {"license_key": payload + "." + b64url(sig), "signing_key": signing_key}, claims["expires_at"]


def main(argv):
    p = argparse.ArgumentParser(description="Synthetic licence for Lucairn's own test installs only; not a customer licence.")
    p.add_argument("--out", required=True)
    p.add_argument("--days", type=int, default=30)
    p.add_argument("--customer-id", default="lucairn_test_install")
    p.add_argument("--customer-name", default="Lucairn test install (not a customer)")
    p.add_argument("--tier", choices=sorted(TIER_DEFAULTS), default="enterprise")
    a = p.parse_args(argv)
    if a.days < 1 or a.days > 90:
        p.error("--days must be 1..90 (test licences are short-lived)")
    lic, expires = make(a.days, a.customer_id, a.customer_name, a.tier, datetime.now(timezone.utc).replace(microsecond=0))
    # O_EXCL: never overwrite an existing file (it might be a real licence).
    fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(lic, f)
        f.write("\n")
    os.chmod(a.out, 0o600)
    print("wrote %s (mode 0600; test licence, expires %s; not a customer licence)" % (a.out, expires))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
