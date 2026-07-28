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

**The device runs no witness at all** (ratified 2026-07-28). An earlier revision
of this overlay left the local witness container up as a "retrieval-only"
surface whose signing key became inert rather than absent. That was reversed:
inert is not absent. A witness on the operator's machine cannot deliver
"evidence the operator cannot forge" by construction, and a key that is present
is a key that can be used. The device is a protection plane and a claim emitter.
It is not a notary.

One consequence you must action: `bin/lucairn init` still writes a witness
signing key into `customer.env` for every topology, and this overlay cannot
reach into that generator. Deleting it is a manual step — §9.

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
- **NTP running on every device.** The witness rejects claims whose timestamps
  fall outside a ±30s window (`witness_server.go:106-112`). On a LAN, where the
  witness and its emitters share a host clock, this is invisible. Across a WAN,
  on a laptop that sleeps and resumes, a drifted clock silently produces PARTIAL
  certificates for every turn — with no error an operator could connect to the
  cause. Verify with `timedatectl status` / `sntp -sS time.apple.com` before
  enabling.

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
# NOTE ON THE CN: pick something that identifies the device, but do NOT rely on
# it for attribution today — see §5.1. The claim port verifies the certificate
# CHAIN, not the CN, and nothing records which device submitted a claim.
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

Do **not** substitute the mesh-wide `DSA_MTLS_*` variables here. Two independent
reasons, and under `LCR_WITNESS_REQUIRE_MTLS=true` the code now refuses the
substitution outright:

1. **`DSA_MTLS_*` is process-wide.** Setting it so the gateway can reach a
   remote witness also switches that gateway's dials to audit, id-bridge and
   inference over to verified mTLS, against peers that are still local and still
   on the base install's transport. Those handshakes fail, and the resulting
   outage looks nothing like the change that caused it.
2. **The mesh CA is generated on the device.**
   `services/veil-witness/scripts/bootstrap-mtls-ca.sh` mints it per deploy and
   keeps the private key on that box — correct for a single-host mesh, wrong as
   the anchor for a WAN trust decision. Anchoring the witness hop on it would
   let a laptop-held CA vouch for the very authority the laptop's operator is
   not supposed to control: anything on that machine could mint a leaf bearing
   the pinned `dsa-veil-witness` SAN and impersonate the central witness to its
   own emitters, while the handshake still succeeded and the log still said TLS.

This holds even if you have run the full-mesh ceremony. The witness hop gets its
own credential, from the CA in §3.

### What the SAN pin does and does not guarantee

The emitters set `ServerName` (Go) / `grpc.ssl_target_name_override` (Python) to
`dsa-veil-witness` and verify it against `ca.pem`. This is **not** a hostname
check, and the distinction matters:

- **It guarantees** the peer holds the private key for a certificate issued by
  *your* CA bearing that SAN. Against a CA you control and that issues exactly
  one such leaf, this is a strong single-identity pin — stronger than hostname
  verification, which would accept any publicly-trusted certificate for a name.
- **It is not bound to the address you configured.** A wrong
  `LUCAIRN_CENTRAL_WITNESS_ADDR` fails only because the wrong host lacks the
  leaf. Redirect the traffic to any host that *does* hold it and the dial
  succeeds silently.
- **Every device accepts the same single identity**, so the server leaf is a
  fleet-wide skeleton key. Anyone who obtains it — a host backup, a compromised
  witness — can receive `redaction_manifest_body` from every device by winning a
  route or DNS race, with no per-device signal.
- **Its soundness is entirely a property of the CA, not of the pin.** Keep the
  CA key offline (§3), and treat a leaked server leaf as a full re-issuance
  event (§5).

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

Exact env set for the witness process — **all seven variables**:

```sh
# :50057 — claim intake
DSA_MTLS_CA_BUNDLE_PATH=/etc/lucairn/witness-server/ca.pem
DSA_MTLS_SERVER_CERT_PATH=/etc/lucairn/witness-server/server.pem
DSA_MTLS_SERVER_KEY_PATH=/etc/lucairn/witness-server/server.key

# :50058 — certificate retrieval. NOT optional. See below.
WITNESS_MTLS_CA_BUNDLE_PATH=/etc/lucairn/witness-server/ca.pem
WITNESS_MTLS_SERVER_CERT_PATH=/etc/lucairn/witness-server/server.pem
WITNESS_MTLS_SERVER_KEY_PATH=/etc/lucairn/witness-server/server.key

LCR_WITNESS_REQUIRE_MTLS=true
# ⚠️ STRICT VALUE GRAMMAR: `true` engages it, `false` (or empty) disengages it,
# and ANY OTHER VALUE STOPS THE PROCESS naming this variable. It is not a
# truthiness test — "1", "yes" and "ture" are configuration errors, not "off".
# Before 2026-07-28 they parsed as off, so a typo here put the claim hop in
# cleartext while your config file said the boundary was engaged.
```

`LCR_WITNESS_REQUIRE_MTLS=true` does three things on the witness:

1. **`:50057` refuses to serve** without a complete `DSA_MTLS_*` server triple,
   rather than silently listening in cleartext. A half-landed bind-mount becomes
   a loud startup failure instead of a quiet downgrade.
2. **`:50060` is suppressed.** That port registers the *same* claim service
   without TLS and starts whenever `GRPC_TLS_ENABLED=true` — which the kit
   defaults to — so without this it would remain a cleartext bypass for the port
   you just hardened.
3. **`:50058` refuses to serve** without a complete `WITNESS_MTLS_*` triple.

Point 3 is the one that is easy to get wrong, and it is why this section lists
seven variables rather than four.

### 4.1 Authorization — who may do what once the handshake succeeds

**The seven variables above are AUTHENTICATION. They are not authorization.**

`LCR_WITNESS_REQUIRE_MTLS` proves a caller holds a key whose leaf chains to your
CA. It says nothing about *which* caller. Every device you issue a leaf to, and
every service on the witness host that holds one, satisfies it equally — so
without the settings below, any device credential can call
`ExportCertificates` and stream out *any* customer's certificates, manifest
bodies included, by naming their `customer_id` in the request. The
`customer_id` is caller-supplied; before this it was the only thing scoping the
response.

Add these to the witness process:

```sh
# Who may submit claims. Setting this REPLACES the default — list every
# identity, not just the ones you are adding.
#
# Two granularities meet here and it is worth understanding why. The DSA mesh
# identifies a SERVICE (dsa-sanitizer, dsa-gateway, ...). §3.3 above issues one
# credential per DEVICE (lucairn-device-laptop-01), shared by that device's four
# emitter containers. Both are listed because both dial this port: the mesh SANs
# for any services co-located with the witness, the device CNs for your fleet.
#
# The device-level grain means a device's four emitters cannot be told apart by
# this control. That is a real limitation, not an oversight — see §8.
LCR_WITNESS_CLAIM_ALLOWED_PEERS=dsa-gateway,dsa-id-bridge,dsa-sanitizer,dsa-sandbox-b,dsa-reid-guard,dsa-audit,lucairn-device-laptop-01,lucairn-device-laptop-02

# Who may bulk-read certificates. LEAVE THIS ALONE unless you have a specific
# reason.
#
# The default under the latch is the gateway identity and nothing else — in
# particular NOT your device CNs. That is the property that matters: a laptop
# credential cannot read certificates, its own or anyone else's, because it is
# not on this list. Adding a device CN here hands that device a bulk-export
# primitive over the whole store.
#
# Note "admin" is allowed OFF-latch (the legacy ACL) and NOT under the latch. If
# you have tooling that exports as "admin", name it here deliberately.
#
# ⚠️ NAMING THIS ON A WITNESS WHOSE WITNESS_MTLS_* DOES NOT RESOLVE IS A BOOT
# FAILURE, with or without the latch. The :50058 ACL interceptors attach only
# inside the mTLS branch, so on an unconfigured cert port your allowlist would
# govern nothing while the port answered every caller — the permissive twin of
# the claim-port refusal, and the quieter of the two until now. An inherited
# default still degrades with a warning; only an explicit allowlist stops boot.
# LCR_WITNESS_EXPORT_ALLOWED_PEERS=gateway,dsa-gateway

# Bind exporters to the tenants they may export. Format: peer=cust1|cust2,peer2=cust3
# A peer WITH an entry is refused any customer_id outside it. A peer WITHOUT one
# is governed by the binding mode below.
#
# ⚠️ REPLACE THE TENANT IDS WITH YOURS. This line and the binding below are a
# PAIR and must be edited together — see the warning under the binding.
LCR_WITNESS_EXPORT_CUSTOMER_MAP=gateway=cust_acme|cust_globex

# What happens to an exporter that has NO map entry:
#   enforce  refuse
#   audit    allow, log it, count it
#   off      no customer check at all
#
# ⚠️ MANDATORY whenever the latch is on, or whenever you set a customer map.
# The witness REFUSES TO START until you state it, naming this variable.
#
# There used to be a default (`audit`) and it was wrong in the worst way: an
# authorised exporter could name ANY customer_id and receive that tenant's
# certificates, manifest bodies and all, with a log line as the only trace. The
# opposite default is also wrong — silently enforcing takes a multi-tenant
# hosted gateway offline on day one. So the choice is yours, explicitly:
#
#   - map every exporter above and set `enforce`  <- the witness-central answer
#   - `enforce` with no map, which denies every unmapped exporter
#   - `audit` or `off`, meaning "I accept that this credential can read every
#     tenant" — legitimate for a hosted multi-tenant gateway, nowhere else
#
# 🛑 `enforce` WITH THE MAP LEFT COMMENTED OUT BREAKS EVERY EXPORT, AND IT DOES
# NOT LOOK LIKE A CONFIGURATION ERROR. An earlier revision of this runbook did
# exactly that. The latched default export allowlist is the `gateway` identity;
# with no map entry the gateway is unmapped, `enforce` refuses it, and the
# refusal travels PermissionDenied -> ErrVeilUnavailable -> **HTTP 503
# "Lucairn Witness is temporarily unavailable", Retry-After: 30** — permanently,
# on a config mistake, labelled transient. Whoever debugs it will look at the
# witness process, which is healthy. Set both lines or neither.
LCR_WITNESS_EXPORT_CUSTOMER_BINDING=enforce

# Cap on one export stream. Default under the latch: 10000. 0 disables.
# Exceeding it FAILS the stream rather than truncating it — a truncated export
# that returned OK could not be told apart from a complete one.
# LCR_WITNESS_EXPORT_MAX_CERTS=10000
```

A malformed value in any of these stops the witness at boot with a message
naming the variable. That is deliberate: silently falling back to the default
would leave you believing a narrower list is in force than actually is.

**Every `ExportCertificates` call is now logged**, whether it succeeded or was
refused:

```
[witness-export-audit] ts=... peer="gateway" customer_id="cust_acme" returned=42 capped=false outcome=ok duration_ms=118
```

Caller, tenant, count, outcome, timing — and deliberately nothing else. No
certificate body, no placeholder, no original value: an audit trail that copies
the thing it audits is a second breach surface. Counters for the same events are
on the Prometheus surface (`witness_export_*`, `witness_claim_intake_denied_total`).

Read the startup log once after enabling. The witness prints its resolved
posture, and prints a loud warning when claim-intake authorization is NOT
enforced:

```
[witness-authz] latch=true export_peers=dsa-gateway,gateway export_customer_binding=audit export_max_certs=10000 identity=cn+dns-sans
[witness-authz] claim_peers=...
```

`:50058` is the certificate-**retrieval** port. It has its own credential family
and its own per-method CN ACL, and when `WITNESS_MTLS_*` is unset it *degrades
gracefully*: it logs a warning and serves with **no client authentication and no
ACL**. That is a defensible policy on a single box — the local service chain must
keep working if the CA bootstrap has not run — and a serious exposure on a
WAN-reachable fleet witness, because `GetCertificate` and `ExportCertificates`
return `VeilCertificate` protos carrying `SanitizerClaim.redaction_manifest_body`:
the placeholder→original map, for every device and every customer.
`ExportCertificates` gates only on a caller-supplied `customer_id` string, so
unauthenticated it is a bulk-dump primitive.

The pre-existing mitigation on record for that degradation is *"the port binds
127.0.0.1, so the threat is bounded"* — a single-host assumption that this
topology exists specifically to break. The witness now refuses to start rather
than serve that port open under the latch.

`GRPC_TLS_ENABLED=true` alone does **not** satisfy the latch on either port. On
that legacy path, with no certificate files configured, the witness presents a
self-signed leaf that clients accept without verification: encrypted, but
unauthenticated, so anything able to intercept the hop can terminate it.

### Ingress

Publish **`:50057` only.** Close `:50058` (certificate retrieval — see above),
`:50059` (unauthenticated health HTTP) and `:50060` at the firewall or by not
mapping them. Devices need the claim port and nothing else; certificates are read
from the central store's web surface.

If a device genuinely needs `:50058` (the option-(b) shape in the overlay), open
it to that device only and provision the `WITNESS_MTLS_*` **client** triple on it
— the CN ACL is what makes that port safe to expose, and it is only active when
the server triple above is set.

### Verifying the window before you leave it

Run these **in the witness's own namespace**. A host-level `ss` proves nothing
here: the kit maps no `ports:` for `veil-witness`, so a host check shows an empty
result whether or not the container is listening, and reads as a pass on a
witness where the latch was never applied.

```bash
# 1. :50057 came up and says TLS.
docker compose logs veil-witness | grep ':50057'
# expect exactly:  witness gRPC server on :50057 (TLS)

# 2. The plaintext bypass is NOT listening — checked INSIDE the container.
docker compose exec veil-witness sh -c 'ss -lnt || netstat -lnt' | grep -q ':50060' \
  && echo 'FAIL — :50060 still listening' \
  || echo 'OK — :50060 suppressed'

# 3. And it never started.
docker compose logs veil-witness | grep -q 'on :50060' \
  && echo 'FAIL — plain claim server started' \
  || echo 'OK — no :50060 server'

# 4. A plaintext client is refused on :50057 (must fail the handshake, not hang).
grpcurl -plaintext -max-time 5 <central-host>:50057 list 2>&1 \
  | grep -qiE 'tls|handshake|transport' \
  && echo 'OK — plaintext refused' \
  || echo 'FAIL — plaintext client was not refused'

# 5. :50058 refuses an anonymous caller. If this returns a certificate, STOP
#    and roll back: the PII originals map is being served unauthenticated.
grpcurl -plaintext -max-time 5 -d '{"request_id":"probe"}' \
  <central-host>:50058 dsa.veil.v1.VeilCertificateService/GetCertificate 2>&1 \
  | grep -qiE 'tls|handshake|unauthenticated|transport' \
  && echo 'OK — :50058 refused' \
  || echo 'FAIL — :50058 answered an anonymous caller'
```

Each of these can fail. That is the point — the earlier version of this section
contained a check that printed `OK` unconditionally, which is worse than no
check at all, because it closes the window with a false pass.

---

## 5. Revoking a device (phase 1)

### 5.1 What phase 1 does *not* give you

Read this before planning an incident response around it.

**The claim hop authenticates "a device in the fleet", never *which* device.**
`:50057` under the latch does `RequireAndVerifyClientCert` against the CA and
nothing more — any leaf that CA signed is accepted. Above the transport,
`SubmitClaim` authorises on the per-*service* Ed25519 key (`dsa-sanitizer`,
`dsa-bridge`, `dsa-ai`, `dsa-audit`, …), which is a role, not a device. Two
consequences:

- Those service signing keys are **fleet-shared** — every device is provisioned
  with the same ones — even though the TLS credential is per-device.
- The per-device TLS identity is **not bound to the claim it carries**. A device
  holding any valid credential can submit a well-formed claim for any
  `request_id`.

**The client CN is not recorded anywhere on the claim path.** The witness reads
it only on `:50058`'s ACL. So "look for the CN in the witness logs" is not an
available forensic step for claim submission, and a lost laptop cannot be shown
from the evidence store to have been used.

Per-device claim attribution is a Slice-2 item (it becomes strictly more
important once an offline outbox replays claims, not less). Do not describe the
current state to a customer as per-device evidence provenance.

### 5.2 Mechanisms available today

Phase 1 has no CRL. In order of preference:

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

## 5.3 Network posture on the device

The overlay grants no *new* Docker networking — it adds no `networks:` key, so
every service keeps the attachments it already had. But it does make an existing
capability load-bearing, and that is worth stating plainly to anyone reviewing
the deployment:

The sanitizer sits on `dsa-identity` (`internal: true`) **and** on
`dsa-witness-identity` (a plain bridge with outbound NAT). The compose comment on
`dsa-identity` describes network-layer exfil blocking as an enforced second layer
alongside the code-level air gap; for the sanitizer specifically, that was
already qualified by its second attachment. This topology is what turns that
unqualified leg into a continuously-used path to the public internet for the
container holding raw PII and the placeholder→original map.

Nothing here constrains that egress to the witness address. **Restrict it at the
host firewall** to the central witness host and port. If the sanitizer is ever
compromised, the network layer is otherwise not stopping exfiltration to an
arbitrary destination.

## 5.4 What a missing credential actually does — it differs by service

The failure modes are asymmetric, and knowing which is which is the difference
between a five-minute diagnosis and an hour:

| Service | Language | Behaviour when the credential is missing under the latch |
|---|---|---|
| gateway, audit, id-bridge | Go | **The process exits at startup.** The dial is constructed during boot and the refusal is fatal. |
| sanitizer, sandbox-b, reid-guard | Python | **The service keeps serving** and drops claims; the stub stays `None`. Certificates seal PARTIAL. |

So a laptop with a bad bind-mount does not degrade uniformly: the gateway dies —
which the consultant experiences as "Claude Code stopped working", with no
obvious connection to a witness credential — while the sanitizer silently
downgrades the evidence. Both are fail-closed in the sense that matters (nothing
is sent in cleartext), but only the Python half is the honest-PARTIAL behaviour
the rest of this document describes.

Pre-flight before enabling the latch on a device, which catches the common cause:

```bash
for svc in gateway audit id-bridge sanitizer; do
  docker compose exec "$svc" sh -c \
    'ls -l /etc/lucairn/witness-client/ca.pem \
           /etc/lucairn/witness-client/client.pem \
           /etc/lucairn/witness-client/client.key' \
    >/dev/null 2>&1 && echo "$svc OK" || echo "$svc MISSING CREDENTIAL FILES"
done
```

The compose `:?` guards catch an *unset variable*. They do not catch a variable
pointing at an empty or wrong directory, which is the failure this loop finds.

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
- **The generated witness signing key is still in `customer.env`** until you
  delete it (§9). The container no longer starts, so nothing uses the key — but
  "unused" is not "absent", and the PRD's criterion is absence. Making
  `bin/lucairn init` topology-aware so the key is never generated is a
  follow-up; today it is a documented manual step, which means it is a step
  someone will skip.
- **Claim-intake authorization is per DEVICE, not per service** (§4.1). One
  device credential is shared by that device's four emitter containers, so the
  allowlist cannot distinguish the sanitizer from the gateway on the same
  laptop. A compromised container on a device can submit claims as any of that
  device's emitters. Narrowing this needs per-service credentials on the device,
  which is Slice-4 PKI work.
- **`customer_id` binding has no default under the latch** (changed 2026-07-28
  after an adversarial review). It used to default to `audit`, meaning an
  exporter with no `LCR_WITNESS_EXPORT_CUSTOMER_MAP` entry was allowed and
  merely recorded — so the shipped default of the control whose purpose is
  "customer_id bound to authenticated identity" authorised every tenant. The
  witness now refuses to start with the latch on, no map, and no explicit
  `LCR_WITNESS_EXPORT_CUSTOMER_BINDING`. `audit` and `off` remain available and
  remain a real exposure; choosing one is now a statement rather than an
  inheritance.
- **The device CN is not verified against anything but your CA.** Whoever holds
  the CA key can mint a leaf with any CN or SAN, including `dsa-gateway` — which
  would place it on the export allowlist. Protect the CA key accordingly; the
  authorization layer is exactly as strong as the issuance policy behind it.
- **Phase-1 revocation is re-issuance** (§5.2), and there is **no per-device
  claim attribution** (§5.1).
- **No rate limiting on `:50057`.** The claim server has message-size caps and
  keepalive policy but no per-peer rate limit or concurrency bound. On a LAN with
  four known emitters that is fine; as a fleet-facing WAN endpoint, any
  credential holder can drive unbounded claim writes. Put rate limiting in the
  ingress you place in front of it (§4 Ingress).
- **Failure is asymmetric across services** (§5.4): Go emitters exit at boot, the
  Python ones degrade silently to PARTIAL.

---

## 9. Retire the local signing key

Do this after your first successful witness-central turn is verified (§7), not
before — if you delete the key and the central path is not actually working, you
have removed your fallback and your evidence at the same time.

The overlay stops the witness container. It cannot stop `bin/lucairn init` from
having already written the key, because that generator runs before any topology
choice exists and this overlay has no reach into it.

**1. Confirm the central path is live.** §7 — the witness key id on a freshly
issued certificate must be the CENTRAL witness's. Do not proceed on "no errors
in the log"; a device that is silently sealing PARTIAL also has no errors.

**2. Confirm nothing local is signing.** The service must be absent from the
rendered configuration, not merely stopped:

```sh
docker compose -f docker-compose.customer.yml \
  -f contrib/witness-central/docker-compose.witness-central.yml \
  --env-file customer.env \
  --env-file contrib/witness-central/witness-central.env \
  config --services | grep -c '^veil-witness$'
# expect exactly: 0
```

**3. Delete the private key lines from `customer.env`:**

```
LCR_WITNESS_SIGNING_KEY=...
VEIL_WITNESS_SIGNING_KEY=...
```

**4. Repoint the PUBLIC key — do not delete it.** `LCR_WITNESS_PUBLIC_KEY` is
published by the gateway at `/.well-known/veil-keys.json`, where external SDK
verifiers fetch it to validate certificates. Set its value to the **central**
witness's public key. Leaving the old value there advertises a key that signed
nothing, and a verifier that trusts the discovery surface will reject every
certificate you now issue.

**5. Recreate the stack** and run one more turn through §7.

**6. Destroy the old key material** wherever else it exists — your secret
manager, any backup of `customer.env`, the terminal scrollback from the original
`init`. A retired signing key that still exists somewhere is a key that can
still sign a certificate that will verify.

### What you have NOT removed

`postgres-veil` and `migrate-veil` keep running. They hold no key and sign
nothing; they are left in place because `lucairn-dashboard` (profile
`dashboard`) reads the local certificate log through them, and removing them
would turn an honest empty result into a connection error.

Under witness-central that local certificate log is **empty** — certificates
live in the central store. Point the dashboard at the central witness
(`LUCAIRN_DASHBOARD_WITNESS_ENDPOINT`) or read certificates from the central
store's own surface. An empty cert browser here is not evidence of an empty
cert log.

Also: do **not** combine the `certification` profile with this overlay.
`cert-builder` declares `depends_on: veil-witness: condition: service_healthy`,
and recent Compose versions auto-activate a dependency's profile — which would
silently start the very witness you just removed.
