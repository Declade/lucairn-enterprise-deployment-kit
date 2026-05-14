/**
 * Lucairn quickstart — TypeScript / Node 20+.
 *
 * Sends a synthetic German medical PII prompt through gateway.lucairn.eu and
 * prints the redacted response together with the verifiable certificate URL.
 *
 * Run:
 *   export LUCAIRN_API_KEY=lcr_live_...
 *   export ANTHROPIC_API_KEY=sk-ant-...
 *   pnpm install
 *   pnpm exec tsc && node dist/quickstart.js
 *
 * Uses the built-in fetch (Node >= 18). The published `@lucairn/sdk` package
 * is not yet feature-complete for /v1/messages; raw fetch is the supported
 * path today and is exactly what the SDK will wrap when it ships.
 */

const GATEWAY_URL = process.env.LUCAIRN_GATEWAY_URL ?? "https://gateway.lucairn.eu";
const MODEL = process.env.LUCAIRN_MODEL ?? "claude-sonnet-4-6";

// Synthetic patient note. All identifiers are fake.
const PROMPT =
  "Bitte fasse den folgenden Patientenbefund auf Deutsch in 2 Sätzen zusammen.\n\n" +
  "Patientin: Anna Schmidt, geboren 12.03.1985, " +
  "IBAN DE89 3704 0044 0532 0130 00.\n" +
  "Diagnose: Hypertonie. Empfehlung: Tägliche Blutdruck-Messung, " +
  "Reduktion Salzkonsum, Beta-Blocker 50mg.";

interface ContentBlock {
  type: string;
  text?: string;
}

interface DSACompliance {
  request_id: string;
  veil_certificate_url?: string;
  veil_summary_url?: string;
  pii_in_ai?: boolean;
  identity_in_ai?: boolean;
  sanitizer_layers?: string[];
  redaction_count: number;
  latency_ms: number;
}

interface AnthropicResponse {
  content?: ContentBlock[];
  metadata?: { dsa_compliance?: DSACompliance };
}

async function main(): Promise<number> {
  const lucairnKey = process.env.LUCAIRN_API_KEY;
  const anthropicKey = process.env.ANTHROPIC_API_KEY;
  if (!lucairnKey || !anthropicKey) {
    process.stderr.write(
      "ERROR: set LUCAIRN_API_KEY and ANTHROPIC_API_KEY env vars before running.\n",
    );
    return 1;
  }

  const response = await fetch(`${GATEWAY_URL}/v1/messages`, {
    method: "POST",
    headers: {
      "x-api-key": lucairnKey,
      "X-Upstream-Key": anthropicKey,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 256,
      messages: [{ role: "user", content: PROMPT }],
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    process.stderr.write(`Gateway returned ${response.status}: ${text}\n`);
    return 1;
  }

  const payload = (await response.json()) as AnthropicResponse;
  const text = (payload.content ?? [])
    .filter((b) => b.type === "text" && typeof b.text === "string")
    .map((b) => b.text!)
    .join("\n");
  const compliance = payload.metadata?.dsa_compliance;

  console.log("── LLM response ────────────────────────────────────────");
  console.log(text || "(no text content)");
  console.log();
  console.log("── Compliance metadata ─────────────────────────────────");
  console.log(JSON.stringify(compliance ?? {}, null, 2));
  console.log();
  if (compliance?.veil_certificate_url) {
    const requestId = compliance.veil_certificate_url.split("/").pop() ?? "";
    console.log("── Verify the cert ─────────────────────────────────────");
    console.log(`Open: https://lucairn.eu/verify?cert=${requestId}`);
  }
  return 0;
}

main().then(
  (code) => process.exit(code),
  (err) => {
    process.stderr.write(`unhandled error: ${err}\n`);
    process.exit(1);
  },
);
