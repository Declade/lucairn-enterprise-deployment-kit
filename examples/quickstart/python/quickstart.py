"""Lucairn quickstart — Python.

Sends a synthetic German medical PII prompt through gateway.lucairn.eu and
prints the redacted response together with the verifiable certificate URL.

Run:
    export LUCAIRN_API_KEY=lcr_live_...
    export ANTHROPIC_API_KEY=sk-ant-...
    pip install -r requirements.txt
    python quickstart.py
"""
from __future__ import annotations

import json
import os
import sys

import httpx

GATEWAY_URL = os.environ.get("LUCAIRN_GATEWAY_URL", "https://gateway.lucairn.eu")
MODEL = os.environ.get("LUCAIRN_MODEL", "claude-sonnet-4-6")

# Synthetic patient note. All identifiers are fake.
PROMPT = (
    "Bitte fasse den folgenden Patientenbefund auf Deutsch in 2 Sätzen zusammen.\n\n"
    "Patientin: Anna Schmidt, geboren 12.03.1985, "
    "IBAN DE89 3704 0044 0532 0130 00.\n"
    "Diagnose: Hypertonie. Empfehlung: Tägliche Blutdruck-Messung, "
    "Reduktion Salzkonsum, Beta-Blocker 50mg."
)


def main() -> int:
    lucairn_key = os.environ.get("LUCAIRN_API_KEY")
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    if not lucairn_key or not anthropic_key:
        sys.stderr.write(
            "ERROR: set LUCAIRN_API_KEY and ANTHROPIC_API_KEY env vars before "
            "running.\n"
        )
        return 1

    headers = {
        "x-api-key": lucairn_key,
        "X-Upstream-Key": anthropic_key,
        "content-type": "application/json",
    }
    body = {
        "model": MODEL,
        "max_tokens": 256,
        "messages": [{"role": "user", "content": PROMPT}],
    }

    response = httpx.post(
        f"{GATEWAY_URL}/v1/messages",
        headers=headers,
        json=body,
        timeout=60.0,
    )
    if response.status_code != 200:
        sys.stderr.write(
            f"Gateway returned {response.status_code}: {response.text}\n"
        )
        return 1

    payload = response.json()
    content_blocks = payload.get("content", [])
    text = "\n".join(b.get("text", "") for b in content_blocks if b.get("type") == "text")
    compliance = (payload.get("metadata") or {}).get("dsa_compliance", {})

    print("── LLM response ────────────────────────────────────────")
    print(text or "(no text content)")
    print()
    print("── Compliance metadata ─────────────────────────────────")
    print(json.dumps(compliance, indent=2, ensure_ascii=False))
    print()
    cert_url = compliance.get("veil_certificate_url")
    if cert_url:
        request_id = cert_url.rsplit("/", 1)[-1]
        verify_url = f"https://lucairn.eu/verify?cert={request_id}"
        print("── Verify the cert ─────────────────────────────────────")
        print(f"Open: {verify_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
