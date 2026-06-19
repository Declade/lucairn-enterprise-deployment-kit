# Key Ceremony Runbook

**Audience:** Lucairn installation engineer running the signing-key ceremony for a new customer self-hosted deployment.
**Last updated:** 2026-06-19
**Scope:** Generation, distribution, rotation, and revocation of Ed25519 signing keys used by the Lucairn attestation protocol, for customers running the `lucairn-enterprise-deployment-kit`.

> **No DSA source tree required.** Every tool referenced here ships inside the pinned
> `dsa-veil-witness:0.5.4` image (`/usr/local/bin/sign-manifest`). The ceremony is
> turnkey via `docker run --entrypoint sign-manifest` — no Go toolchain, no build-from-source.

---

## Table of Contents

1. [Key Inventory](#1-key-inventory)
2. [Roles and Access](#2-roles-and-access)
3. [Key Generation](#3-key-generation)
4. [Key Distribution](#4-key-distribution)
5. [Public Key Registration](#5-public-key-registration)
6. [Producing the witness-signed manifest blob](#6-producing-the-witness-signed-manifest-blob)
7. [Verification](#7-verification)
8. [Key Rotation](#8-key-rotation)
9. [Key Revocation (Emergency)](#9-key-revocation-emergency)
10. [Docker Compose path](#10-docker-compose-path)
11. [Kubernetes / Helm path](#11-kubernetes--helm-path)

---

## 1. Key Inventory

Each Lucairn attestation-protocol participant holds an Ed25519 key pair. Private keys (seeds) are 32 bytes, stored as 64-character hex strings.

| Key Name | Service | Purpose | Env Var (Private) | Env Var (Public) |
|---|---|---|---|---|
| Witness Signing Key | veil-witness | Signs assembled certificates | `LCR_WITNESS_SIGNING_KEY` | `LCR_WITNESS_PUBLIC_KEY` |
| Bridge Claim Key | id-bridge | Signs bridge claims | `LCR_BRIDGE_SIGNING_KEY` | `LCR_BRIDGE_PUBLIC_KEY` |
| Sanitizer Claim Key | sanitizer | Signs PII-sanitized claims | `LCR_SANITIZER_SIGNING_KEY` | `LCR_SANITIZER_PUBLIC_KEY` |
| Sandbox B Claim Key | sandbox-b | Signs inference claims | `LCR_SANDBOX_B_SIGNING_KEY` / env: `LCR_SANDBOX_B_SIGNING_KEY` | `LCR_SANDBOX_B_PUBLIC_KEY` |
| Audit Claim Key | audit | Signs audit-recorded claims | `LCR_AUDIT_SIGNING_KEY` | `LCR_AUDIT_PUBLIC_KEY` |
| Gateway Claim Key | gateway | Signs gateway claims | `LCR_GATEWAY_SIGNING_KEY` | `LCR_GATEWAY_PUBLIC_KEY` |
| Manifest Signing Key (gateway) | gateway | Co-signs `/.well-known/veil-keys.json`; gateway-side "alive + healthy" signature | `LCR_MANIFEST_SIGNING_KEY` | `LCR_GATEWAY_MANIFEST_PUBLIC_KEY` |
| Manifest Signing Key (witness) | veil-witness | Pre-signs `/.well-known/veil-keys.json` at ceremony via `sign-manifest --witness-signing-key-hex`; deployed as a blob | **`LCR_WITNESS_SIGNING_KEY` (no separate key — same seed as "Witness Signing Key" above)** | `LCR_WITNESS_MANIFEST_PUBLIC_KEY` (= `LCR_WITNESS_PUBLIC_KEY`) |

> **Legacy env-var names:** the 0.5.x images accept `VEIL_*_SIGNING_KEY` / `VEIL_*_PUBLIC_KEY` as a fallback (envcompat shim). New installs MUST use the `LCR_*` canonical names above.

**Important:** The Witness needs the **public keys** of every claim-signing service to verify signatures. The gateway needs the Witness public key (`LCR_WITNESS_PUBLIC_KEY`) to verify the witness-signed manifest blob at boot. No service ever needs another service's private key.

### Lucairn-held keys (NOT on the customer cluster)

| Key | Purpose | Where the private key lives |
|---|---|---|
| License Signing Key | Signs customer deployment-entitlement licenses (Ed25519 offline license) | Lucairn vault — **never shipped to any customer cluster** |
| Image Signing Key | cosign-signs every published container image + SBOM attestation | Lucairn issuer host (`/home/deploy/.lucairn-cosign/`, mode-600) — **never shipped to any customer cluster** |

Customers receive only the **public** image signing key (`keys/lucairn-cosign.pub`) and the **signed license token** (`LUCAIRN_LICENSE_KEY`) + its public verification key (`LUCAIRN_LICENSE_PUBLIC_KEY`). They never receive the private seeds.

---

## 2. Roles and Access

| Role | Can Generate | Can Distribute | Can Rotate | Can Revoke |
|---|:---:|:---:|:---:|:---:|
| Security Officer | Yes | Yes | Yes | Yes |
| Deployment Engineer | No | Yes (from Vault/HSM) | Yes (with SO approval) | No |
| Developer | Dev keys only | Dev env only | Dev env only | No |
| DPO / Auditor | No | No | No | No (can request) |

**Principle:** Key generation happens offline or in Vault. No private key is ever generated on a production cluster node.

---

## 3. Key Generation

### 3.1 Generate a single key pair (OpenSSL — recommended for production)

```bash
# Generate a 32-byte random seed (private key material)
openssl rand -hex 32
# Example output: a1b2c3d4e5f6...  (64 hex characters)
```

Store this as the private key seed. The Lucairn services derive the full Ed25519 key pair from this seed internally.

### 3.2 Derive the public key from a seed

The kit ships a helper that uses `python3-cryptography` (already required by the bootstrap pipeline) and keeps the seed off the process argument list:

```bash
# From the kit root — stdin form (preferred, no seed in ps output)
printf '%s' "$SEED_HEX" | ./scripts/derive-veil-pubkey.sh
```

The script falls back to `pynacl` only when `cryptography` is unavailable. Do **not** use a raw PyNaCl `python3 -c` one-liner — it requires `pynacl` explicitly (fails on hosts with only `python3-cryptography`) and embeds the private seed in the process argument list, visible via `ps auxww` for the duration of the call.

### 3.3 Generate a full key set in one ceremony session

The ceremony generates **seven** key pairs: one per claim-signing service plus **one** dedicated gateway manifest key (`LCR_MANIFEST_SIGNING_KEY`). There is **no** separate "witness manifest" seed — the two manifest public keys that appear in `keys.json` are simply the **public halves of existing signing seeds**:

> **Two different "sevens":** this section uses "seven" to mean **6 claim seeds + 1 manifest seed = 7 key PAIRS/seeds generated**. Section §6 also says "seven entries" in `keys.json` — that "seven" means **5 claim public keys + 2 manifest public keys = 7 manifest ENTRIES**. The counts are different sets and are intentionally not the same number.

| Env var set on gateway | Derived from | Source |
|---|---|---|
| `LCR_GATEWAY_MANIFEST_PUBLIC_KEY` | `LCR_MANIFEST_SIGNING_KEY` | gateway source `veil.go:202`, wired at `server/main.go:1278` |
| `LCR_WITNESS_MANIFEST_PUBLIC_KEY` | `LCR_WITNESS_SIGNING_KEY` | `sign-manifest` tool signs the blob with this seed (`main.go:92,138`); gateway verifies via `LCR_WITNESS_PUBLIC_KEY` = same public key (`veil.go:290,301`) |

> **Why this matters:** `sign-manifest --witness-signing-key-hex` takes the **witness signing seed** (`LCR_WITNESS_SIGNING_KEY`). The gateway verifies the blob signature against `LCR_WITNESS_PUBLIC_KEY` = `pub(LCR_WITNESS_SIGNING_KEY)`. If you derive `LCR_WITNESS_MANIFEST_PUBLIC_KEY` from a **different** seed, the published `witness_manifest_v1` entry in `/.well-known/veil-keys.json` will not match the key that actually signed the blob, and any relying party that re-verifies the blob signature against the manifest will fail.

```bash
#!/usr/bin/env bash
set -euo pipefail

# SERVICES list: 6 claim-signing keys + 1 dedicated gateway manifest key.
# The witness manifest public key is NOT a new keypair — it is derived from
# the existing WITNESS signing seed (see table above).
SERVICES=("WITNESS" "BRIDGE" "SANITIZER" "SANDBOX_B" "AUDIT" "GATEWAY" "GATEWAY_MANIFEST")

declare -A SEEDS  # save seeds so we can re-use the WITNESS seed below

for svc in "${SERVICES[@]}"; do
  SEED=$(openssl rand -hex 32)
  SEEDS[$svc]="$SEED"
  # Use the bundled helper (cryptography-first, no seed in argv/ps):
  PUBKEY=$(printf '%s' "$SEED" | ./scripts/derive-veil-pubkey.sh)
  echo "=== $svc ==="
  case "$svc" in
    GATEWAY_MANIFEST)
      echo "  LCR_MANIFEST_SIGNING_KEY (private):  $SEED"
      echo "  LCR_GATEWAY_MANIFEST_PUBLIC_KEY:      $PUBKEY"
      ;;
    *)
      echo "  LCR_${svc}_SIGNING_KEY (private): $SEED"
      echo "  LCR_${svc}_PUBLIC_KEY:            $PUBKEY"
      ;;
  esac
  echo ""
done

# Derive the WITNESS manifest public key from the WITNESS signing seed —
# not a new seed. sign-manifest signs the blob with LCR_WITNESS_SIGNING_KEY;
# the gateway verifies it against LCR_WITNESS_PUBLIC_KEY (same key).
echo "=== WITNESS_MANIFEST_PUBLIC_KEY (derived from WITNESS seed — no new seed) ==="
WITNESS_MANIFEST_PUB=$(printf '%s' "${SEEDS[WITNESS]}" | ./scripts/derive-veil-pubkey.sh)
echo "  LCR_WITNESS_MANIFEST_PUBLIC_KEY: $WITNESS_MANIFEST_PUB"
echo "  (same value as LCR_WITNESS_PUBLIC_KEY above — confirm they match)"
echo ""
```

**Store the output securely immediately.** Do not pipe to a file on a shared filesystem. Use Vault, a password manager, or encrypted storage.

---

## 4. Key Distribution

### 4.1 Where private keys go

| Key | Destination Service | Env Var |
|---|---|---|
| Witness seed | veil-witness | `LCR_WITNESS_SIGNING_KEY` |
| Bridge seed | id-bridge | `LCR_BRIDGE_SIGNING_KEY` |
| Sanitizer seed | sanitizer | `LCR_SANITIZER_SIGNING_KEY` |
| Sandbox B seed | sandbox-b | `LCR_SANDBOX_B_SIGNING_KEY` |
| Audit seed | audit | `LCR_AUDIT_SIGNING_KEY` |
| Gateway claim seed | gateway | `LCR_GATEWAY_SIGNING_KEY` |
| Manifest signing seed | gateway | `LCR_MANIFEST_SIGNING_KEY` |

### 4.2 Where public keys go

All claim-signing public keys go to the **Witness** so it can verify claim signatures:

| Env Var on Witness | Contains public key of |
|---|---|
| `LCR_BRIDGE_PUBLIC_KEY` | id-bridge |
| `LCR_SANITIZER_PUBLIC_KEY` | sanitizer |
| `LCR_SANDBOX_B_PUBLIC_KEY` | sandbox-b |
| `LCR_AUDIT_PUBLIC_KEY` | audit |

The **Gateway** also reads public keys for the `/.well-known/veil-keys.json` manifest:

| Env Var on Gateway | Contains public key of |
|---|---|
| `LCR_WITNESS_PUBLIC_KEY` | veil-witness |
| `LCR_BRIDGE_PUBLIC_KEY` | id-bridge |
| `LCR_SANITIZER_PUBLIC_KEY` | sanitizer |
| `LCR_SANDBOX_B_PUBLIC_KEY` | sandbox-b |
| `LCR_AUDIT_PUBLIC_KEY` | audit |
| `LCR_GATEWAY_PUBLIC_KEY` | gateway claim key — **consumed by the WITNESS** to verify gateway claims; also served by the gateway in `/.well-known/veil-keys.json` |
| `LCR_GATEWAY_MANIFEST_PUBLIC_KEY` | gateway manifest-signing key |
| `LCR_WITNESS_MANIFEST_PUBLIC_KEY` | witness manifest-signing key |

The five claim-signing public keys and `LCR_WITNESS_PUBLIC_KEY` are wired for you by `bin/lucairn-init` (both `--dev` and `--production` modes).

> **`bin/lucairn-init` does NOT populate `LCR_GATEWAY_MANIFEST_PUBLIC_KEY` or `LCR_WITNESS_MANIFEST_PUBLIC_KEY`** — it emits both as empty strings (`bin/lucairn-init:548-549`). You must derive and fill them manually from the correct signing seeds as part of the ceremony (§ 3.3 / § 3.2):
>
> ```bash
> # After lucairn-init has written customer.env, fill the two manifest pubkeys:
> LCR_GATEWAY_MANIFEST_PUBLIC_KEY=$(printf '%s' "$LCR_MANIFEST_SIGNING_KEY" | ./scripts/derive-veil-pubkey.sh)
> LCR_WITNESS_MANIFEST_PUBLIC_KEY=$(printf '%s' "$LCR_WITNESS_SIGNING_KEY"  | ./scripts/derive-veil-pubkey.sh)
> # Then write both lines into customer.env and proceed to § 6.
> ```
>
> Without these two values set, the gateway serves a `keys` array with only 5 entries and the Runtime Invariant Harness #3 self-check will degrade to FAIL. The blob verification at boot still passes (the missing entries are simply absent from `verifyEnvKeysMatchBlobActive`), but the published manifest is incomplete.

In a **manual** ceremony, fill each value in `customer.env` by hand after deriving the public keys from the seeds.

---

## 5. Public Key Registration

The Witness loads public keys at startup from environment variables. There is no runtime API. To register a new key:

1. Set the corresponding `LCR_*_PUBLIC_KEY` env var on the Witness.
2. Restart the Witness service.
3. The Witness parses the hex public key and uses it for signature verification immediately on restart.

---

## 6. Producing the witness-signed manifest blob

The gateway serves `/.well-known/veil-keys.json` — a signed manifest of all service public keys. In **production** (`DSA_ENV=production`) the gateway **refuses to start** if the witness-signed manifest blob is missing (it `log.Fatal`s at boot). You must produce and deploy the blob **before first production boot**.

The blob is produced once, at your **ceremony host** (the machine holding the witness signing seed), using the `sign-manifest` tool that ships inside the pinned image.

### 6.1 Assemble the keys.json roster

The `keys.json` roster must contain an entry for **every non-empty `LCR_*_PUBLIC_KEY` env var** the gateway will be configured with. The gateway's `verifyEnvKeysMatchBlobActive` boot check (gateway source `veil.go:322-369`) derives the same list from env at startup and rejects any signed blob whose active-key subset does not byte-match — causing a boot-loop.

The full roster for a standard install has **seven entries**: five claim-signing keys, plus the two manifest-signing public keys (`gateway_manifest_v1` and `witness_manifest_v1`). Start from `docs/example-keys.json` and substitute your real derived public keys:

```json
[
  { "service_id": "dsa-witness",   "key_id": "witness_v1",          "public_key": "<LCR_WITNESS_PUBLIC_KEY>",          "purpose": "Certificate signing",    "algorithm": "Ed25519", "key_state": "active" },
  { "service_id": "dsa-bridge",    "key_id": "bridge_v1",           "public_key": "<LCR_BRIDGE_PUBLIC_KEY>",           "purpose": "Bridge claim signing",   "algorithm": "Ed25519", "key_state": "active" },
  { "service_id": "dsa-sanitizer", "key_id": "sanitizer_v1",        "public_key": "<LCR_SANITIZER_PUBLIC_KEY>",        "purpose": "Sanitizer claim signing","algorithm": "Ed25519", "key_state": "active" },
  { "service_id": "dsa-ai",        "key_id": "sandbox_b_v1",        "public_key": "<LCR_SANDBOX_B_PUBLIC_KEY>",        "purpose": "Inference claim signing","algorithm": "Ed25519", "key_state": "active" },
  { "service_id": "dsa-audit",     "key_id": "audit_v1",            "public_key": "<LCR_AUDIT_PUBLIC_KEY>",            "purpose": "Audit claim signing",    "algorithm": "Ed25519", "key_state": "active" },
  { "service_id": "dsa-gateway",   "key_id": "gateway_manifest_v1", "public_key": "<LCR_GATEWAY_MANIFEST_PUBLIC_KEY>", "purpose": "Manifest signing",       "algorithm": "Ed25519", "key_state": "active" },
  { "service_id": "dsa-witness",   "key_id": "witness_manifest_v1", "public_key": "<LCR_WITNESS_MANIFEST_PUBLIC_KEY>", "purpose": "Manifest signing",       "algorithm": "Ed25519", "key_state": "active" }
]
```

> **Schema:** each entry requires `service_id` / `key_id` / `public_key` / `purpose` / `algorithm` / `key_state`. See `docs/example-keys.json` for a committed template with the correct field names.
>
> **Rule:** include an entry for every public key you set in `customer.env`. If you add or omit a key, regenerate the blob — a mismatch causes a boot-loop with a descriptive error.

### 6.2 Run sign-manifest (no Go toolchain needed)

The `sign-manifest` tool is embedded in `dsa-veil-witness:0.5.4` at `/usr/local/bin/sign-manifest`. Invoke it with `docker run --entrypoint`:

```bash
# On the ceremony host, with the witness seed available.
# LCR_ISSUER must match the value you set in customer.env (default: "Lucairn Veil Witness").
docker run --rm \
  --entrypoint sign-manifest \
  -v "$PWD/keys.json:/keys.json:ro" \
  ghcr.io/declade/dsa-veil-witness:0.5.4 \
  --keys-json /keys.json \
  --issuer "${LCR_ISSUER:-Lucairn Veil Witness}" \
  --witness-signing-key-hex "$LCR_WITNESS_SIGNING_KEY" \
  --witness-key-id witness_manifest_v1 \
  > witness-signed-manifest.json
```

**Flags** (run `docker run --rm --entrypoint sign-manifest ghcr.io/declade/dsa-veil-witness:0.5.4 -h` to confirm against your pin):
- `--keys-json` (required) — path to the keys.json roster inside the container
- `--issuer` (required) — must match `LCR_ISSUER` on the gateway
- `--witness-signing-key-hex` (required) — Ed25519 witness seed, 64 hex chars
- `--witness-key-id` (default: `witness_manifest_v1`)
- `--version` (default: `1`)
- `--protocol-versions` (default: `1,2`)
- `--signed-at` (RFC3339; empty uses current UTC)

The witness seed only ever enters the container as a flag value on the ceremony host — it never leaves that machine.

### 6.3 Deploy the blob to the gateway host

```bash
# Compose path: place the blob in the HOST directory that is bind-mounted into
# the gateway container at /certs.  In docker-compose.customer.yml line 773:
#   ${SANDBOX_B_CERT_DIR:-./.certs}:/certs:ro
# The default host source is ./.certs (relative to the kit root on the gateway
# host).  If you set SANDBOX_B_CERT_DIR in customer.env, use that path instead.
#
# Copy to the HOST bind source — NOT to /certs (that is the container path):
scp witness-signed-manifest.json \
  gateway-host:"${SANDBOX_B_CERT_DIR:-./.certs}/witness-signed-manifest.json"

# Then recreate the gateway so it re-reads + re-verifies the blob at boot.
# Use the canonical overlay set for your install (see OPS.md § Deploy).
docker compose -f docker-compose.customer.yml --env-file customer.env \
  up -d --no-deps --force-recreate gateway
```

### 6.4 When to regenerate the blob

Regenerate and redeploy whenever:
- Any public key changes (rotation, new service, key retirement).
- `LCR_ISSUER` value changes.
- A key is retired — add it to the blob's `keys` array with `key_state: "retired"`.

**Env/blob coherence:** the gateway cross-checks that its `LCR_*_PUBLIC_KEY` env vars byte-match the blob's active-key subset. If you rotate env vars without regenerating the blob (or vice versa), the gateway refuses to start with a descriptive error. Do not bypass this check.

---

## 7. Verification

After any ceremony or rotation, run these checks:

### 7.1 Check the manifest endpoint

```bash
curl -s http://localhost:8080/.well-known/veil-keys.json | jq '.keys | length'
# Expected: 7 for a standard install (witness, bridge, sanitizer, sandbox-b,
# audit, gateway_manifest_v1, witness_manifest_v1). Fewer indicates that
# LCR_GATEWAY_MANIFEST_PUBLIC_KEY or LCR_WITNESS_MANIFEST_PUBLIC_KEY are unset.
```

### 7.2 Submit a test request and verify the certificate

```bash
# The gateway embeds the request ID at metadata.dsa_compliance.request_id
# (anthropic_types.go:dsaCompliance struct), not at the top-level .request_id.
# Also available at metadata.dsa_compliance.veil_certificate_url.
RESPONSE=$(curl -s -X POST http://localhost:8080/v1/messages \
  -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":20,"messages":[{"role":"user","content":"Hi"}]}')

REQUEST_ID=$(printf '%s' "$RESPONSE" | jq -r '.metadata.dsa_compliance.request_id // empty')

sleep 5

curl -s "http://localhost:8080/api/v1/veil/certificate/$REQUEST_ID" \
  -H "x-api-key: $API_KEY" | jq '.verification'
```

Expected: `"overall_verdict": "VERDICT_VERIFIED"`.

### 7.3 Verify a specific key pair matches

```bash
# Use the bundled helper (cryptography-first, seed stays off argv/ps):
ACTUAL_PUB=$(printf '%s' "$PRIVATE_SEED" | ./scripts/derive-veil-pubkey.sh)
if [ "$ACTUAL_PUB" = "$PUBLIC_KEY" ]; then
  echo "MATCH"
else
  echo "MISMATCH: expected $PUBLIC_KEY, got $ACTUAL_PUB"
fi
```

### 7.4 Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `signatures_valid: false` | Public key on Witness does not match the private key on the claiming service | Re-derive public key from seed; update Witness env var; restart Witness |
| `completeness: PARTIAL` | One or more services not emitting claims | Check that `LCR_*_SIGNING_KEY` is set correctly on the affected service |
| `/.well-known/veil-keys.json` returns empty `keys` array | Gateway missing `LCR_*_PUBLIC_KEY` env vars | Set the public-key env vars on the gateway and restart |
| Gateway `log.Fatal` at boot: `witness-signed manifest missing` | Blob not deployed before production boot | Run § 6.2–6.3 ceremony steps, restart gateway |
| `key seed must be 32 bytes` in logs | Hex string is wrong length (not 64 chars) | Regenerate with `openssl rand -hex 32` |

---

## 8. Key Rotation

### 8.1 Planned rotation (zero-downtime)

The protocol is advisory (never blocks inference), so a brief window of unverifiable claims is acceptable but should be minimised.

**Procedure:**

1. Generate new key pair (§ 3.1 + § 3.2).
2. Set the new public key on the Witness; restart the Witness.
3. Verify the Witness is healthy.
4. Set the new private key on the service; restart the service.
5. Regenerate and redeploy the witness-signed manifest blob (§ 6.2–6.3).
6. Update the gateway manifest env vars; restart the gateway.
7. Run verification checks (§ 7).
8. Retire the old key material from secrets storage.

### 8.2 Rotation schedule

| Key | Recommended Rotation | Rationale |
|---|---|---|
| Witness Signing Key | Annually | High-value key; signs all certificates |
| Claim Signing Keys (bridge, sanitizer, sandbox-b, audit, gateway) | Every 6 months | Standard signing-key rotation |
| Manifest Signing Key (gateway) | Annually | Gateway-local signature; rotate independently of the witness key |
| Manifest Signing Key (witness) | Co-rotate with Witness Signing Key | The witness manifest public key IS the witness signing public key — rotating `LCR_WITNESS_SIGNING_KEY` automatically rotates the manifest entry; re-issue the blob with the new seed |

---

## 9. Key Revocation (Emergency)

If a private key is compromised:

### 9.1 Immediate response (target: < 15 minutes)

```bash
# 1. Identify the compromised service
COMPROMISED_SVC="id-bridge"  # example

# 2. Generate replacement key pair immediately
NEW_SEED=$(openssl rand -hex 32)
# Use the bundled helper (cryptography-first, seed stays off argv/ps):
NEW_PUBKEY=$(printf '%s' "$NEW_SEED" | ./scripts/derive-veil-pubkey.sh)

# 3. Update Witness with new public key; restart Witness
#    (update customer.env or Vault/ESO, then restart the veil-witness container)

# 4. Deploy new private key to the compromised service; restart it

# 5. Regenerate and redeploy the witness-signed manifest (§ 6.2–6.3)

# 6. Run verification checks (§ 7)
```

> **Note:** inference continues while the Witness is restarting. The attestation protocol is advisory — it never blocks the data pipeline. A brief window of unverifiable claims is acceptable for emergency rotation; complete the swap promptly.

### 9.2 Post-incident

1. **Audit trail review:** query the witness database for certificates issued during the compromise window — they may carry forged claims from the compromised service.
2. **Customer notification:** if customer-facing certificates were issued with the compromised key, notify affected parties per your incident response plan.
3. **Secrets cleanup:** remove the old key material from all secrets backends.
4. **Root cause analysis:** document how the key was compromised and update access controls.

### 9.3 Witness key compromise

If the Witness signing key is compromised, all certificates signed during the compromise window are suspect.

1. Stop the Witness immediately (`docker compose stop veil-witness` or scale to 0 in Kubernetes).
2. Generate a new Witness key pair (§ 3.1 + § 3.2).
3. Update all secrets backends with the new seed + public key.
4. Regenerate the witness-signed manifest blob (§ 6.2) with the new seed.
5. Restart the Witness with the new key; redeploy the blob to the gateway (§ 6.3).
6. Issue an advisory about affected certificates.

---

## 10. Docker Compose path

Keys are passed via environment variables in `customer.env` (generated by `bin/lucairn-init`). The `customer.env.example` template shows every required `LCR_*` var.

**Development / evaluation:** run `bin/lucairn-init --dev` — it generates a full key set automatically and writes a doctor-passing `customer.env` in seconds. No manual ceremony needed.

**Production:** run `bin/lucairn-init --production --license license-bundle.json` (or fill `customer.env` by hand following this runbook), then produce and deploy the witness-signed manifest blob (§ 6) before starting the stack.

---

## 11. Kubernetes / Helm path

Production Helm installs use the External Secrets Operator (ESO) to sync secrets from a backend (Vault, AWS Secrets Manager, or Azure Key Vault) into Kubernetes Secrets. The chart supports three backends via `secrets.backend`:

- `vault` — HashiCorp Vault (recommended)
- `aws` — AWS Secrets Manager
- `azure` — Azure Key Vault
- `k8s-native` — plain Kubernetes Secrets (dev/staging only)

See `charts/lucairn/charts/*/templates/externalsecret.yaml` for the per-service `ExternalSecret` definitions and `docs/CUSTOMER_HELM_RUNBOOK.md` for the full Helm ceremony runbook.

For the production Helm posture (`grpcTlsEnabled=true`, `dsaEnv=production`), see `charts/lucairn/values-prod.yaml` and `scripts/bootstrap-grpc-certs.sh` in the kit's Helm production posture.

---

## Appendix: Quick Reference

```
GENERATE:      openssl rand -hex 32
DERIVE PUB:    printf '%s' "$SEED_HEX" | ./scripts/derive-veil-pubkey.sh
VERIFY PAIR:   compare derived public key with stored public key
SIGN MANIFEST: docker run --rm --entrypoint sign-manifest \
                 -v "$PWD/keys.json:/keys.json:ro" \
                 ghcr.io/declade/dsa-veil-witness:0.5.4 \
                 --keys-json /keys.json --issuer "Lucairn Veil Witness" \
                 --witness-signing-key-hex "$LCR_WITNESS_SIGNING_KEY" \
                 --witness-key-id witness_manifest_v1 > witness-signed-manifest.json
CHECK SETUP:   curl -s http://gateway:8080/.well-known/veil-keys.json | jq '.keys | length'
TEST E2E:      bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
```
