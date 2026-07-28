# `witness-central` runbook — remote witness over authenticated TLS

**Status:** phase 1 (manual CA). Slice 1 of the split-evidence-plane workstream
(PRD `prd-2026-07-28-split-evidence-plane.md`, board #206).

**Scope of this document:** how to provision the credentials the
`contrib/witness-central/` overlay needs, and what the enable step on the
central witness looks like. It is deliberately a *stub with exact commands*
rather than an automated tool — phase 1 issues a handful of certificates by
hand, and getting the trust boundary right matters more than getting it
scripted.

---

## 1. What this topology is for

In the stock kit the Veil Witness runs beside the services it certifies. The
operator of the machine therefore holds the signing key for evidence *about
their own machine's conduct*. For a demo that is fine. For a consultant laptop
handling a client's data it is not: the subject of the evidence controls the
trust anchor, and a laptop witness can never anchor to a TSA or Rekor
(`anchor_status` stays `pending` forever).

`witness-central` keeps the protection plane local — the gateway, the sanitizer
and its L1/L2/L3 shields, id-bridge, audit all still run on the device, and raw
PII still never leaves it *for the model path* — while claims travel to a
witness the operator does not control, which signs and anchors the
certificates.

### What crosses the network that did not before

Be explicit about this with anyone reviewing the deployment, because it is the
question a security reviewer will ask first:

| Claim | Emitter | Contains |
|---|---|---|
| `TOKEN_GENERATED` | id-bridge | pseudonym/token metadata |
| `PII_SANITIZED` | sanitizer | detection counts, manifest hash, **`redaction_manifest_body`** |
| `INFERENCE_COMPLETED` | sandbox-b / gateway | model + isolation-probe metadata |
| `EVENTS_RECORDED` | audit | audit-trail digest |

`redaction_manifest_body` is the placeholder→original map. It is the most
sensitive payload the product produces, and under this topology it is
transmitted to the central witness. That is the whole reason the claim hop is
mutual-TLS-with-a-pinned-CA rather than "TLS to a public endpoint", and the
reason the latch below is fail-closed.

This does not change what the *model* sees — the sanitizer still runs locally
and the LLM still receives only sanitized text.

---

## 2. Prerequisites

- A central witness already running and reachable on its claim port (`:50057`).
  For the Lucairn-hosted pilot this is the existing hosted witness; for a
  customer-run deployment it is their own instance on a server the consultant
  does not administer.
- Administrative access to that witness host for §4 (this is a **supervised
  window** — see §6).
- OpenSSL on whichever machine performs the CA ceremony.

---

## 3. Phase-1 CA ceremony (manual)

Phase 1 uses one CA, created once, kept offline, issuing:

- **one server leaf** for the central witness, and
- **one client leaf per device** that submits claims.

Per-device — not one shared client cert. A shared credential cannot be revoked
for one laptop without re-issuing for all of them, which in practice means it
never gets revoked at all.

Perform this on a machine that is **not** one of the claim-submitting devices.
The CA key must never be copied onto a laptop.

```bash
umask 077
mkdir -p lucairn-witness-ca && cd lucairn-witness-ca

# --- 3.1 The CA -----------------------------------------------------
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 1825 \
  -subj "/O=Lucairn/CN=lucairn-witness-ca" \
  -out ca.pem

# --- 3.2 The central witness's SERVER leaf --------------------------
# The SAN must be exactly dsa-veil-witness. The emitters pin that name and
# verify it against this CA; they do NOT verify the dialed hostname, which is
# what lets the same certificate work regardless of the address each device
# reaches the witness on.
openssl ecparam -name prime256v1 -genkey -noout -out witness-server.key
openssl req -new -key witness-server.key \
  -subj "/O=Lucairn/CN=dsa-veil-witness" \
  -out witness-server.csr
openssl x509 -req -in witness-server.csr -CA ca.pem -CAkey ca.key \
  -CAcreateserial -days 825 -sha256 \
  -extfile <(printf 'subjectAltName=DNS:dsa-veil-witness\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\nbasicConstraints=CA:FALSE\n') \
  -out witness-server.pem

# --- 3.3 A CLIENT leaf, once per device -----------------------------
# Use a CN that identifies the device. It is what you will look for when you
# need to revoke, and what the witness's logs will show.
DEVICE=laptop-01
openssl ecparam -name prime256v1 -genkey -noout -out "client-${DEVICE}.key"
openssl req -new -key "client-${DEVICE}.key" \
  -subj "/O=Lucairn/CN=lucairn-device-${DEVICE}" \
  -out "client-${DEVICE}.csr"
openssl x509 -req -in "client-${DEVICE}.csr" -CA ca.pem -CAkey ca.key \
  -CAcreateserial -days 365 -sha256 \
  -extfile <(printf 'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\nbasicConstraints=CA:FALSE\n') \
  -out "client-${DEVICE}.pem"
```

Distribute to each device, mode `0600`, into the directory named by
`LUCAIRN_WITNESS_CLIENT_CERT_DIR`:

| File on the device | From the ceremony |
|---|---|
| `ca.pem` | `ca.pem` |
| `client.pem` | `client-<device>.pem` |
| `client.key` | `client-<device>.key` |

The overlay wires these through the **witness-scoped** variables
`LCR_WITNESS_MTLS_CA_BUNDLE_PATH` / `_CLIENT_CERT_PATH` / `_CLIENT_KEY_PATH`.

Do **not** substitute the mesh-wide `DSA_MTLS_*` variables here unless you have
also run the full-mesh mTLS ceremony for the local services. `DSA_MTLS_*` is
process-wide: setting it so the gateway can reach a remote witness also switches
that gateway's dials to audit, id-bridge and inference over to verified mTLS,
against peers that are still local and still on the base install's transport.
Those handshakes fail, and the resulting outage looks nothing like the change
that caused it. The witness-scoped family exists precisely so one hop can move
without conscripting the rest.

(If you *have* run the full-mesh ceremony, leave the witness-scoped variables
unset — the mesh-wide credential is used for this hop too.)

Notes that matter:

- **`ca.pem` is the trust root, not a public root store.** Do not substitute a
  publicly-trusted certificate for the witness. Pinning to a CA you issued is
  what makes "only our witness" enforceable; against a public root store any
  certificate for any name from any public CA would satisfy the client.
- **Client-leaf lifetime is short on purpose** (365 days above; shorter is
  better). Phase 1 has no CRL or OCSP — expiry *is* the revocation mechanism.
  If a device is lost before its certificate expires, the only real remedy is
  §5.
- The CA is valid for 5 years; the ceremony to rotate it is a re-run of §3
  followed by a rolling redistribution, and should be planned before year 4.

---

## 4. Enabling it on the central witness

**This is a supervised window on the witness host — see §6.** The witness must
present its server leaf and require + verify client certificates, or the client
side's mutual authentication is one-way theatre.

Place the three files on the witness host (read-only to the container):

| File | Path in container |
|---|---|
| `ca.pem` | `/etc/lucairn/witness-server/ca.pem` |
| `witness-server.pem` | `/etc/lucairn/witness-server/server.pem` |
| `witness-server.key` | `/etc/lucairn/witness-server/server.key` |

Exact env set for the witness process:

```sh
DSA_MTLS_CA_BUNDLE_PATH=/etc/lucairn/witness-server/ca.pem
DSA_MTLS_SERVER_CERT_PATH=/etc/lucairn/witness-server/server.pem
DSA_MTLS_SERVER_KEY_PATH=/etc/lucairn/witness-server/server.key
LCR_WITNESS_REQUIRE_MTLS=true
```

`LCR_WITNESS_REQUIRE_MTLS=true` does two things on the witness:

1. It refuses to boot at all if the `DSA_MTLS_*` server triple is incomplete,
   rather than silently serving `:50057` in cleartext. A half-landed bind-mount
   becomes a loud startup failure instead of a quiet downgrade.
2. It **suppresses the `:50060` plaintext claim port**. That port registers the
   same claim service without TLS and is started whenever
   `GRPC_TLS_ENABLED=true` — which the kit defaults to — so without this it
   would remain a documented cleartext bypass for the port you just hardened.

`GRPC_TLS_ENABLED=true` alone does **not** satisfy the latch. On that legacy
path, with no certificate files configured, the witness presents a self-signed
leaf that clients accept without verification: encrypted, but unauthenticated,
so anything able to intercept the hop can terminate it.

### Verifying the window before you leave it

```bash
# 1. The witness came up and says TLS.
docker compose logs veil-witness | grep ':50057'
# expect:  witness gRPC server on :50057 (TLS)

# 2. The plaintext bypass is NOT listening.
ss -lntp | grep 50060 || echo 'OK — :50060 suppressed'

# 3. A plaintext client is refused.
#    (any gRPC client without a cert; the handshake must fail, not hang)
```

---

## 5. Revoking a device (phase 1)

Phase 1 has no CRL. The available mechanisms, in order of preference:

1. **Let the client leaf expire** — acceptable only for a decommissioned device
   you still control.
2. **Re-issue the CA and redistribute** — the real revocation. Repeat §3,
   redistribute `ca.pem` + fresh client leaves to every remaining device, then
   swap the witness's server leaf. Disruptive by design; keep the device count
   small enough that this stays feasible.
3. **Network-block the device** at the witness's ingress, as an immediate
   stop-gap while (2) is arranged.

Automated per-device revocation is a phase-2 item and is not in this slice.

---

## 6. Deployment posture

- **The central-witness enable step (§4) is a supervised window**, not an
  unattended change. It alters the transport contract for every device at once:
  a mistake in the server triple takes claim submission down fleet-wide, and
  every certificate issued during the gap seals `PARTIAL`.
- **Record a rollback tag for the witness image before the window** and know
  how to unset the four variables in §4. Unsetting them restores the previous
  behaviour exactly — the latch is inert when unset.
- **Roll the client side first, one device, and verify** (§7) before enabling
  the requirement on the witness. Client-side `LCR_WITNESS_REQUIRE_MTLS=true`
  against a not-yet-mTLS witness fails closed on that one device only, which is
  a cheap and reversible way to prove the credential is good.

---

## 7. Verifying a device is actually certifying centrally

The check that matters is the **witness key id on an issued certificate**, not
container state and not the absence of errors:

- Run one turn through the local stack.
- Fetch the resulting certificate.
- Confirm the witness key id is the CENTRAL witness's, not the local one.

A local witness container that is running but receiving nothing looks identical
to a healthy one. The key id is the only thing that distinguishes "certified
centrally" from "certified by the machine under test".

---

## 8. Known limits of this slice

Stated plainly so nobody deploys past them:

- **No offline queue.** While the central witness is unreachable, claims are not
  retried across a restart and are not journalled. Turns still complete and
  users are still protected, but affected certificates seal `PARTIAL`. Bounded
  retry is Slice 2; the tamper-evident offline journal and reconnect backfill
  are Slice 3.
- **The witness rejects claims outside a ±30s timestamp skew window.** Any
  meaningful offline queueing would be rejected on reconnect today. Slice 3 has
  to solve that server-side before offline operation is real.
- **The local witness still holds a signing key**, inert but present, because
  certificate retrieval has not been decoupled from it yet. The PRD's "laptop
  holds no signing key in the witness role" criterion is not met by this slice
  alone.
- **Phase-1 revocation is re-issuance** (§5).
