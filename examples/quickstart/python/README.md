# Lucairn quickstart — Python

A single-file example. Sends a synthetic German medical-PII prompt through the
Lucairn gateway, prints the LLM's response, and prints the verifiable
certificate URL.

## 3 steps

```bash
# 1. Set env vars
export LUCAIRN_API_KEY=lcr_live_...        # from https://lucairn.eu/account
export ANTHROPIC_API_KEY=sk-ant-...        # your Anthropic key (BYOK)

# 2. Install deps
pip install -r requirements.txt

# 3. Run
python quickstart.py
```

## Example output (illustrative)

Exact text, `request_id`, sanitizer layer set, and latency will differ on every run — this is the shape, not the literal output.

```
── LLM response ────────────────────────────────────────
[PERSON_1] (geboren am [DATE_1]) leidet an Hypertonie. Empfohlen werden
tägliche Blutdruck-Messungen, eine Reduktion des Salzkonsums sowie die
Einnahme eines Beta-Blockers (50 mg).

── Compliance metadata ─────────────────────────────────
{
  "request_id": "req_01HXYZ...",
  "veil_certificate_url": "https://gateway.lucairn.eu/api/v1/veil/certificate/req_01HXYZ...",
  "veil_summary_url":     "https://gateway.lucairn.eu/api/v1/veil/certificate/req_01HXYZ.../summary",
  "pii_in_ai": false,
  "identity_in_ai": false,
  "sanitizer_layers": ["known_entity_matching", "presidio_ner"],
  "redaction_count": 3,
  "latency_ms": 1842
}

── Verify the cert ─────────────────────────────────────
Open: https://lucairn.eu/verify?cert=req_01HXYZ...
```

The LLM never sees `Anna Schmidt`, `12.03.1985`, or the IBAN — only
`[PERSON_1]`, `[DATE_1]`, and `[IBAN_1]`. The placeholders that appear in the
response are exactly what the LLM was given.

## What this demonstrates

- **Sanitization.** The synthetic patient name, date of birth, and IBAN are
  redacted before the prompt reaches Anthropic.
- **Audit trail.** Every response carries a `dsa_compliance` block with a
  signed certificate URL.
- **BYOK.** Your Anthropic key is forwarded through the gateway via
  `X-Upstream-Key`. Lucairn does not store it.

## Notes

- Streaming and tool-calls are not surfaced in this quickstart — see the
  capability matrix at <https://lucairn.eu/developer> for what's wired today
  vs. what's on the roadmap.
- Override the gateway URL for self-hosted deployments via
  `LUCAIRN_GATEWAY_URL`. Override the model with `LUCAIRN_MODEL`.
