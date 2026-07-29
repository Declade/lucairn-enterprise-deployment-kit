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

- **one server leaf** for the central witness (both ports),
- **one claim client leaf per device** that submits claims (§3.3), and
- **one certificate-hop client leaf per device**, `CN=gateway`, for that
  device's gateway container only (§3.4).

Per-device — not one shared client cert. A shared credential cannot be revoked
for one laptop without re-issuing for all of them, which in practice means it
never gets revoked at all.

**Two client leaves per device, not one, and they are not interchangeable.**
This is the single easiest thing to get wrong in this ceremony, so it is worth
stating before you run any of it:

| | claim hop | certificate hop |
|---|---|---|
| Port | `:50057` | `:50058` |
| Env family | `LCR_WITNESS_MTLS_*` | `WITNESS_MTLS_*` |
| Directory var | `LUCAIRN_WITNESS_CLIENT_CERT_DIR` | `LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR` |
| Mounted into | audit, id-bridge, sanitizer, gateway | **gateway only** |
| Subject CN | `lucairn-device-<name>` | `gateway` |
| Witness allowlist | `LCR_WITNESS_CLAIM_ALLOWED_PEERS` | `LCR_WITNESS_CERT_ALLOWED_PEERS` / `LCR_WITNESS_EXPORT_ALLOWED_PEERS` |

The reason they are separate is the whole point of §4.1. The witness authorises
per method — claim intake to the emitters, certificate reads and bulk export to
the gateway alone — and it can only distinguish callers that present different
certificates. Mount one key into four containers and those four containers are
one identity: whatever you grant the gateway you have granted the sanitizer,
which holds raw PII, and the export RPC returns placeholder→original maps. A
2026-07-28 review found exactly that shape in an earlier revision of this
runbook, where the device leaf served both hops; do not reintroduce it by
"simplifying" the two directories back into one.

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
# TWO SANs, because the two hops pin two different names and both are served by
# the same witness process:
#
#   dsa-veil-witness  the claim emitters (:50057) pin this.
#   witness           the gateway's certificate hop (:50058) pins this whenever
#                     WITNESS_MTLS_SERVER_NAME is unset — the gateway falls back
#                     to the literal "witness"
#                     (services/gateway/internal/clients/veil.go). Omit it and
#                     certificate retrieval fails a hostname check that reads
#                     like a broken certificate.
#
# Neither is a hostname check against the address you dial: the peer is verified
# by "holds a key for a leaf this CA issued bearing that SAN", which is what lets
# one certificate work regardless of the address each device reaches it on.
#
# One SERVER leaf for both ports is correct — they are one process and one
# identity. Do not generalise that to the CLIENT side (§3.3/§3.4).
openssl ecparam -name prime256v1 -genkey -noout -out witness-server.key
openssl req -new -key witness-server.key \
  -subj "/O=Lucairn/CN=dsa-veil-witness" \
  -out witness-server.csr
openssl x509 -req -in witness-server.csr -CA ca.pem -CAkey ca.key \
  -CAcreateserial -days 825 -sha256 \
  -extfile <(printf 'subjectAltName=DNS:dsa-veil-witness,DNS:witness\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\nbasicConstraints=CA:FALSE\n') \
  -out witness-server.pem

# --- 3.3 A CLAIM client leaf, once per device -----------------------
# This is the :50057 identity. Use a CN that identifies the device. It is what
# you will look for when you need to revoke.
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

# --- 3.4 A CERTIFICATE-HOP client leaf, once per device -------------
# This is the :50058 identity, and it is a DIFFERENT key from §3.3. It goes into
# a DIFFERENT directory and is mounted into the gateway container only.
#
# The CN must be exactly `gateway`. That string is not a convention you may
# rename: it is the witness's latched default certificate-RPC allowlist
# (services/veil-witness/internal/server/authz.go,
# `defaultLatchedCertPeers = []string{"gateway"}`), and it is the same CN the
# stock kit's own bootstrap-mtls-ca.sh mints for this hop.
#
# ⚠️⚠️ AND A PER-DEVICE subjectAltName ON TOP OF IT — TOB-002, 2026-07-28.
#
# The CN alone is FLEET-WIDE. Every device's cert-hop leaf carries the same
# `/O=Lucairn/CN=gateway`, so the witness's peerIdentities() returns exactly
# {"gateway"} for all of them (authz.go peerIdentities: CommonName, then the
# leaf's DNSNames). One identity for the whole fleet means
# LCR_WITNESS_EXPORT_CUSTOMER_MAP has exactly one possible key — and a map with
# one key cannot separate two tenants. At two devices or more (the pilot shape)
# any laptop operator can call ExportCertificates naming another consultant's
# customer_id and receive up to LCR_WITNESS_EXPORT_MAX_CERTS certificates, each
# carrying RedactionManifestBody, the placeholder->original PII map.
#
# The SAN is what makes each device distinguishable WITHOUT breaking the shared
# allowlist entry. Verified against the witness code, not assumed:
#
#   - peerIdentities() appends leaf.DNSNames only when MatchSANs is true, and
#     MatchSANs is LATCH-DERIVED: parsePeerIdentity("", latched) returns
#     `latched` (authz.go). With LCR_WITNESS_REQUIRE_MTLS=true — which §4
#     requires — SANs count. Setting LCR_WITNESS_PEER_IDENTITY=cn explicitly
#     turns them off again; do not.
#   - authorizePeer() admits the caller if ANY identity is on the list, and the
#     CommonName is still first in that slice, so the shared
#     LCR_WITNESS_CERT_ALLOWED_PEERS / LCR_WITNESS_EXPORT_ALLOWED_PEERS entry
#     `gateway` keeps admitting every device. Adding a SAN grants nothing new.
#   - authorizeCustomer() walks the SAME slice and requires EVERY identity that
#     has a map entry to allow the requested customer_id — an intersection, so
#     the narrowest mapping on the leaf wins. That is what makes the SAN the
#     effective binding key: map it, and the device's own entry governs. (Until
#     2026-07-28 this returned on the FIRST mapped identity, and since the CN is
#     shared its entry could only ever be the fleet-wide union — mapping
#     `gateway` then silently re-granted everything. See §4.1.)
#
# Use a name that cannot collide with a mesh service SAN. `lucairn-gateway-`
# prefixed with the device is the documented form.
#
# The KEY is per device even though the CN is not: the CN says "this caller is a
# gateway", the key says "this one", and the SAN says "this one" in a form the
# witness can act on. Never copy one device's gateway key to another device;
# §5.2's re-issuance is your only revocation and it is only tractable if each
# key exists in exactly one place.
openssl ecparam -name prime256v1 -genkey -noout -out "gateway-${DEVICE}.key"
openssl req -new -key "gateway-${DEVICE}.key" \
  -subj "/O=Lucairn/CN=gateway" \
  -out "gateway-${DEVICE}.csr"
openssl x509 -req -in "gateway-${DEVICE}.csr" -CA ca.pem -CAkey ca.key \
  -CAcreateserial -days 365 -sha256 \
  -extfile <(printf "subjectAltName=DNS:lucairn-gateway-${DEVICE}\nextendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\nbasicConstraints=CA:FALSE\n") \
  -out "gateway-${DEVICE}.pem"

# Confirm the leaf carries BOTH identities before you distribute it. A missing
# SAN here is silent: the device works, exports succeed, and the per-tenant
# separation you configured in §4.1 simply is not there.
openssl x509 -in "gateway-${DEVICE}.pem" -noout -subject -ext subjectAltName
# subject=O=Lucairn, CN=gateway            <- OpenSSL 3.x; 1.1.1 prints "O = Lucairn"
# X509v3 Subject Alternative Name:
#     DNS:lucairn-gateway-laptop-01
```

> **Note the `printf` quoting change.** The `-extfile` here is double-quoted so
> `${DEVICE}` expands; §3.2 and §3.3 use single quotes because they have nothing
> to expand. Single-quoting this one produces a leaf whose SAN is the literal
> `lucairn-gateway-${DEVICE}` — identical on every device, which is exactly the
> fleet-wide identity this step exists to end. The `openssl x509 ... -ext
> subjectAltName` check above catches it.

Distribute to each device, mode `0600` on the keys and `0700` on the
directories, **owned by UID/GID 10001**, into **two** directories:

> ⚠️ **Ownership is not optional, and modes alone will brick the install.**
> Every consumer (gateway, sanitizer, audit, id-bridge) runs as UID 10001 in
> its container, and these are bind mounts — the host's ownership is what the
> container sees, so a root-owned `0700` directory with a `0600` key inside is
> unreadable to all four. The witness-mTLS latch treats an unreadable
> credential as fatal, so the stack fails to boot rather than degrading. After
> copying the files to each device:
>
> ```bash
> sudo chown -R 10001:10001 "$LUCAIRN_WITNESS_CLIENT_CERT_DIR" \
>                           "$LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR"
> sudo chmod 0700 "$LUCAIRN_WITNESS_CLIENT_CERT_DIR" \
>                 "$LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR"
> sudo chmod 0600 "$LUCAIRN_WITNESS_CLIENT_CERT_DIR"/client.key \
>                 "$LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR"/client.key
> # verify the container's view, not the host's:
> docker compose run --rm --entrypoint sh lucairn-gateway -c \
>   'cat /etc/lucairn/witness-client/client.key >/dev/null && echo READABLE'
> ```
>
> If your platform pins a different container UID (rootless Docker with
> `userns-remap`, or a Kubernetes `runAsUser` override), chown to THAT id — the
> rule is "owned by the uid the containers actually run as", not the literal
> 10001. This applies to §10 device countersigning too, which signs with the
> first of these two credentials.

`LUCAIRN_WITNESS_CLIENT_CERT_DIR` — the claim hop, readable by audit,
id-bridge, sanitizer and gateway:

| File on the device | From the ceremony |
|---|---|
| `ca.pem` | `ca.pem` |
| `client.pem` | `client-<device>.pem` |
| `client.key` | `client-<device>.key` |

`LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR` — the certificate hop, mounted into
the gateway and nothing else:

| File on the device | From the ceremony |
|---|---|
| `ca.pem` | `ca.pem` (the same CA bundle; one CA, two leaves) |
| `client.pem` | `gateway-<device>.pem` |
| `client.key` | `gateway-<device>.key` |

The overlay wires the first through the **witness-scoped** variables
`LCR_WITNESS_MTLS_CA_BUNDLE_PATH` / `_CLIENT_CERT_PATH` / `_CLIENT_KEY_PATH`,
and the second through `WITNESS_MTLS_CA_BUNDLE_PATH` / `_CLIENT_CERT_PATH` /
`_CLIENT_KEY_PATH`. Both are set for you; the directories are not.

**Do not point both variables at one directory.** It is the shortcut this
ceremony exists to prevent. With one directory the gateway presents
`CN=lucairn-device-<name>` to `:50058`, which the witness's default allowlist
refuses — and the natural repair, adding that device CN to
`LCR_WITNESS_CERT_ALLOWED_PEERS` / `LCR_WITNESS_EXPORT_ALLOWED_PEERS`, hands the
same authority to every other container mounting that key, sanitizer included.
`tests/test_witness_central_profile.sh` asserts the rendered separation on both
the environment and the mounts, so a regression here fails the kit test suite
rather than a customer's audit.

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
#
# The bare identity `gateway` does NOT belong on this list. That is the §3.4
# certificate-hop CN; it never dials :50057, and listing it here would let the
# cert-hop leaf submit claims as well as read them, collapsing the separation
# §3.4 exists to create. The gateway's claim identity is its device CN, already
# above.
LCR_WITNESS_CLAIM_ALLOWED_PEERS=dsa-gateway,dsa-id-bridge,dsa-sanitizer,dsa-sandbox-b,dsa-reid-guard,dsa-audit,lucairn-device-laptop-01,lucairn-device-laptop-02

# Who may bulk-read certificates. LEAVE THIS ALONE. There is no supported
# reason to widen it in a witness-central deployment.
#
# The default under the latch is the identity `gateway` and nothing else — in
# particular NOT your device CNs. That is the property that matters: a laptop's
# CLAIM credential cannot read certificates, its own or anyone else's, because
# it is not on this list.
#
# 🛑 NEVER ADD A DEVICE CN HERE. If certificate retrieval or /verify is failing
# with PermissionDenied, the cause is a mis-provisioned device, not a too-narrow
# allowlist: the gateway is dialling :50058 with the §3.3 claim leaf instead of
# the §3.4 `CN=gateway` leaf. Fix it at the device by populating
# LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR. Adding `lucairn-device-laptop-01`
# here would appear to fix it and would in fact grant bulk export over the whole
# store to every container on that laptop that mounts the claim credential —
# audit, id-bridge and the sanitizer, which holds raw PII — because they all
# present the same certificate. The witness cannot tell them apart; that is what
# a shared credential means. See §3.4.
#
# The same applies to LCR_WITNESS_CERT_ALLOWED_PEERS (GetCertificate /
# VerifyCertificate), which shares this default set deliberately so the
# single-read RPCs are never wider than the bulk one.
#
# Note "admin" is allowed OFF-latch (the legacy ACL) and NOT under the latch. If
# you have tooling that exports as "admin", name it here deliberately.
#
# ⚠️⚠️ SETTING THIS — OR ANY OF THE OTHER FOUR :50058 CONTROLS — ON A WITNESS
# WHOSE WITNESS_MTLS_* DOES NOT RESOLVE IS A BOOT FAILURE, with or without the
# latch. The five are LCR_WITNESS_EXPORT_ALLOWED_PEERS,
# LCR_WITNESS_CERT_ALLOWED_PEERS, LCR_WITNESS_EXPORT_CUSTOMER_MAP,
# LCR_WITNESS_EXPORT_CUSTOMER_BINDING and LCR_WITNESS_EXPORT_MAX_CERTS
# (widened 2026-07-28; it used to fire only for the two allowlists).
#
# They all FAIL OPEN: the :50058 interceptors attach only inside the mTLS
# branch, so on an unconfigured cert port your control governs nothing while the
# port answers every caller — the permissive twin of the claim-port refusal, and
# the quieter of the two until now. A control the operator wrote down and the
# process cannot apply is worse than one they never wrote: it is believed.
#
# ✅ THE ONE EXCEPTION, and it is a neutral-value exception, not a name-based
# one: a control whose configured value is semantically IDENTICAL to leaving the
# variable unset still boots, because failing to attach it removes nothing.
# `..._BINDING=off` (no customer check at all), `..._MAX_CERTS=0` (no cap at
# all), and `..._CUSTOMER_MAP` while the binding is off (the witness never reads
# the map in that mode) are all exempt. The exception exists so this gate cannot
# BRICK a deployment that deliberately disabled a control — an operator who
# states their defaults must not be the one whose witness stops starting.
# `=audit`, `=enforce`, a positive cap, a map under either binding mode, and
# either allowlist all still refuse. The exemption reads the PARSED value, never
# the raw text, so `OFF` and ` off ` behave exactly like `off` and no future
# spelling widens it by accident.
#
# An INHERITED default still degrades with a warning; only an explicit value
# that asks for something stops boot, and unsetting the variable is the one-line
# escape. LCR_WITNESS_AUDIT_LOG_HMAC_KEY is the exception of a different kind
# and merely warns whatever you set it to: it affects a log field, not an access
# decision.
#
# §4's seven-variable server set satisfies this. If you are following that
# section you are already fine; this warning is for the deployment that copies
# §4.1 without §4.
# LCR_WITNESS_EXPORT_ALLOWED_PEERS=gateway,dsa-gateway

# Bind exporters to the tenants they may export. Format: peer=cust1|cust2,peer2=cust3
# A peer WITH an entry is refused any customer_id outside it. A peer WITHOUT one
# is governed by the binding mode below.
#
# ⚠️ REPLACE THE TENANT IDS WITH YOURS. This line and the binding below are a
# PAIR and must be edited together — see the warning under the binding.
#
# 🛑🛑 THE KEYS ARE THE PER-DEVICE SANs FROM §3.4, ONE ENTRY PER DEVICE.
# 🛑🛑 MAPPING THE BARE `gateway` CN IS AT BEST REDUNDANT, AND BEFORE
# 🛑🛑 2026-07-28 IT WAS A SILENT FLEET-WIDE GRANT.
#
# Why, mechanically (authz.go authorizeCustomer). A verified leaf carries
# several identities: under the latch the witness reads [CommonName, ...DNS
# SANs], which for a §3.4 leaf is `gateway` plus `lucairn-gateway-<device>`.
#
#   BEFORE round 4 the witness returned on the FIRST mapped identity. The CN is
#   shared fleet-wide, so its entry can only ever be the UNION of every device's
#   tenants — and a `gateway=...` line matched first for EVERY device, so the
#   per-device entries underneath it were never consulted. No error, no warning,
#   no log line: exports simply succeeded for tenants that device should not see.
#   The belt-and-braces config (map both) was the one that broke it.
#
#   NOW every MAPPED identity on the leaf must allow the requested customer_id —
#   an intersection, so the NARROWEST mapping wins and mapping the shared CN can
#   only ever tighten, never widen. Mapping `gateway` is therefore redundant
#   rather than dangerous. Map the SANs; leave the CN out.
#
# A peer with NO mapped identity at all still falls through to the binding mode
# below — unchanged, and it is the hosted-gateway case.
#
# The shared `gateway` entry in LCR_WITNESS_EXPORT_ALLOWED_PEERS above is
# unaffected either way: authorizePeer admits on ANY matching identity, so
# ADMISSION stays fleet-wide while TENANT SCOPE is per device. Two controls, two
# grains, deliberately.
#
# Two preconditions, both of which fail CLOSED rather than open:
#   - LCR_WITNESS_REQUIRE_MTLS=true (§4). SAN matching is latch-derived; off the
#     latch only the CN is read and every device is unmapped again.
#   - Do NOT set LCR_WITNESS_PEER_IDENTITY=cn. That forces CN-only matching, so
#     with the map below every device becomes unmapped and — under
#     BINDING=enforce — every export is refused. Loud, but a full outage.
LCR_WITNESS_EXPORT_CUSTOMER_MAP=lucairn-gateway-laptop-01=cust_acme,lucairn-gateway-laptop-02=cust_globex

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
[witness-export-audit] ts=... peer="gateway" peer_ids=gateway+lucairn-gateway-laptop-01 customer_ref=h:9f3c1ab27de40518 returned=42 capped=false outcome=ok duration_ms=118
```

**`peer=` is the CommonName; `peer_ids=` is every identity on the verified
leaf**, joined with `+`. The two are not redundant. `peer=` stays the stable
first-wins key you grep and aggregate on, and the §3.4 ceremony makes it
`gateway` on every device — so on its own the record could say an export
happened and not say which machine did it. `peer_ids=` is the per-device half,
and it is the reason §3.4 mints a `subjectAltName`.

> **A device whose leaf was minted the OLD way renders `peer_ids=gateway`, with
> nothing after it.** That is how you discover a device was provisioned before
> the 2026-07-28 §3.4 change — re-issue its certificate-hop leaf with the SAN.
> It is also the state in which that device's `LCR_WITNESS_EXPORT_CUSTOMER_MAP`
> entry can never match, so under `enforce` its exports are refused: loud, but a
> full outage for that device until it is re-issued.

Caller, tenant, count, outcome, timing — and deliberately nothing else. No
certificate body, no placeholder, no original value: an audit trail that copies
the thing it audits is a second breach surface. Counters for the same events are
on the Prometheus surface (`witness_export_*`, `witness_claim_intake_denied_total`).

> ⚠️ **This is export attribution only.** The CLAIM path still records no
> device identity at all (§5.1) — `peer_ids=` exists on the `:50058` records
> because that port authenticates per method, and adding it to claim intake is
> separate work. Do not describe the product as having per-device evidence
> provenance on the strength of this line.

**`customer_ref` is a keyed pseudonym, not the `customer_id`.** Earlier builds
printed the caller-supplied tenant id verbatim; container logs are shipped to
whoever collects stdout, and those readers are not the people with witness-database
access, so the control meant to protect tenant identifiers was creating a second,
wider-read copy of them. It is now
`"h:" + HMAC-SHA256(key, customer_id)` truncated to 16 hex characters. An unkeyed
digest would not have helped — `cust_`-prefixed ids are enumerable and reverse in
minutes — so the key is what makes it one-way in practice.

To read the log you need to be able to correlate, and that has a configuration
consequence:

- **By default the key is random per witness process.** The pseudonym is safe with
  zero configuration, and the same tenant appears under a *different* `customer_ref`
  after every witness restart or on a second replica. Do not build alerting on the
  value's stability, and do not read two restarts' logs as two tenants.
- **Set `LCR_WITNESS_AUDIT_LOG_HMAC_KEY`** when you want a stable ref across
  restarts and replicas. The witness *enforces* a 16-byte minimum and refuses to
  start below it; 32 bytes or more is what you should actually use, and
  `openssl rand -hex 32` produces a suitable value. The value is used as RAW
  BYTES and is NOT hex-decoded — a 64-character hex string is therefore a
  64-byte key, not a 32-byte one. Store it somewhere your log readers
  cannot reach — anyone holding both the key and the log can re-derive the tenant
  ids, which is exactly the exposure the pseudonym removes.
- **To resolve one ref to one tenant**, recompute the HMAC over the candidate id
  with your configured key and compare. There is no reverse lookup, by design:

  ```sh
  printf '%s' 'cust_acme' | openssl dgst -sha256 -mac HMAC \
    -macopt "key:$LCR_WITNESS_AUDIT_LOG_HMAC_KEY" -r | cut -c1-16
  # compare against the h: value in the log line
  ```

The same `customer_ref` form appears on the DENY and UNBOUND lines, so a refused
export is correlatable to an allowed one **within the witness log** without
either line naming a tenant.

> 🛑 **`customer_ref` is LOG-ONLY. Do not grep a caller-side error for it** —
> it is not there, and looking for it is how an operator concludes the logs are
> broken. The gRPC `PermissionDenied` the caller receives carries a
> request-scoped **random** token instead:
>
> ```
> caller "gateway" is not authorised to export the requested customer_id —
>   correlate this refusal with the witness export-audit log using corr=4f1c8ab902de7761
> ```
>
> and the matching `[witness-export-audit] DENY ...` line prints the identical
> `corr=`. **To correlate a gateway-side refusal to the witness audit trail,
> grep `corr=`.**
>
> Why not the pseudonym: the status crosses a trust boundary — the gateway logs
> what it receives, and renders it to its own caller. Echoing
> `HMAC(auditKey, caller-supplied id)` there is a chosen-plaintext oracle that
> rebuilds the raw→pseudonym table the key exists to prevent, and it got worse
> once this runbook started recommending a *stable* key (below) and every device
> presents a `CN=gateway` leaf. The random token gives the operator the same
> single string to grep and gives the caller nothing about any id it did not
> already supply. `UNBOUND` is an allow, not a refusal, so no token is minted
> for it.

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

Publish **`:50057` broadly** and **`:50058` per device**. Close `:50059`
(unauthenticated health HTTP) and `:50060` at the firewall or by not mapping
them.

`:50058` is not optional under this overlay: `LUCAIRN_CENTRAL_WITNESS_CERT_ADDR`
is required, because the device runs no local witness for the gateway's
`/verify` and `/summary` surfaces to fall back to. So the guidance is *narrow*,
not *closed* — allow it from the device addresses you have issued §3.4 leaves
to, and to nothing else. If your fleet reads certificates only from the central
store's own web surface and never through the local gateway, you may close it
entirely, but then the overlay's cert address points at a port your firewall
drops and `/verify` fails at request time; decide that deliberately rather than
discovering it.

Two controls make that port safe to expose at all, and both must hold:

1. The `WITNESS_MTLS_*` **server** triple in §4 above — without it the port
   serves with no client authentication and no ACL.
2. A `CN=gateway` **client** leaf on the device (§3.4) — the CN ACL is what
   distinguishes the gateway from every other container on that laptop, and it
   is the reason a laptop's claim credential cannot reach this port.

Neither is a substitute for the other.

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

**Partially amended by the device countersignature (§10).** When a claim carries
`device_countersign`, that one field IS bound to a specific device key, and the
witness records at intake whether that key was the authenticated mTLS peer. It
does not repair this section: the binding covers the request commitment on the
sanitizer claim only, the other three claims remain role-attributed, and any
party that declines to produce a countersignature falls straight back into
everything above. Read §10.6 before quoting either section at a customer.

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
# 1. The claim-hop credential, in all four emitters.
for svc in gateway audit id-bridge sanitizer; do
  docker compose exec "$svc" sh -c \
    'ls -l /etc/lucairn/witness-client/ca.pem \
           /etc/lucairn/witness-client/client.pem \
           /etc/lucairn/witness-client/client.key' \
    >/dev/null 2>&1 && echo "$svc claim-hop OK" || echo "$svc MISSING CLAIM CREDENTIAL FILES"
done

# 2. The certificate-hop credential, gateway only.
docker compose exec gateway sh -c \
  'ls -l /etc/lucairn/witness-gateway-client/ca.pem \
         /etc/lucairn/witness-gateway-client/client.pem \
         /etc/lucairn/witness-gateway-client/client.key' \
  >/dev/null 2>&1 && echo "gateway cert-hop OK" || echo "gateway MISSING CERT-HOP CREDENTIAL FILES"

# 3. It is the RIGHT leaf — CN=gateway, not the device CN. A device leaf here
#    renders as PermissionDenied on every certificate read, and the tempting
#    "fix" is the one §4.1 forbids.
docker compose exec gateway sh -c \
  'openssl x509 -noout -subject -in /etc/lucairn/witness-gateway-client/client.pem'
# expect a subject whose CN is exactly: gateway

# 4. The two hops are NOT the same key. Identical fingerprints mean the two
#    directories were pointed at one place, which is the shared-identity state
#    §3.4 exists to prevent.
docker compose exec gateway sh -c \
  'openssl x509 -noout -fingerprint -sha256 -in /etc/lucairn/witness-client/client.pem;
   openssl x509 -noout -fingerprint -sha256 -in /etc/lucairn/witness-gateway-client/client.pem'
# expect two DIFFERENT fingerprints

# 5. No non-gateway container can see the cert-hop leaf.
for svc in audit id-bridge sanitizer; do
  docker compose exec "$svc" sh -c 'ls /etc/lucairn/witness-gateway-client' >/dev/null 2>&1 \
    && echo "$svc FAIL — holds the gateway's cert-hop credential" \
    || echo "$svc OK — no cert-hop credential"
done
```

The compose `:?` guards catch an *unset variable*. They do not catch a variable
pointing at an empty or wrong directory, nor two variables pointing at the same
directory — which is what checks 3, 4 and 5 find. Check 5 is the one that
matters most: it is the difference between "the gateway is authorised" and
"everything on this laptop is authorised".

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

## 7b. Full on-prem: provisioning the sandbox-b credential yourself

**Read this if you run `-f docker-compose.customer.yml -f
docker-compose.self-hosted.yml` — the full on-prem set INSTALL.md documents —
together with this overlay.** If you run the customer compose alone, skip it:
`sandbox-b` is not in your project.

`sandbox-b` is the AI plane's claim emitter and it is defined **only** in
`docker-compose.self-hosted.yml`. This overlay cannot reach it. It cannot add a
`sandbox-b:` block either, because the overlay is also applied *without*
`docker-compose.self-hosted.yml`, and an override block for a service the
project does not define would create a new imageless service and break that
topology outright.

Two consequences, and the second is the one that bites:

1. **Its address is already handled.** `LCR_WITNESS_ADDR` in
   `docker-compose.self-hosted.yml` reads `${LUCAIRN_CENTRAL_WITNESS_ADDR:-veil-witness:50057}`,
   so setting `LUCAIRN_CENTRAL_WITNESS_ADDR` repoints sandbox-b along with the
   other four emitters. Nothing for you to do.
2. **Its mTLS credential is not.** `LCR_WITNESS_MTLS_SANDBOX_B_*` and the
   device-wide `LCR_WITNESS_MTLS_*` fallback both resolve to the **empty
   string** by default, and no witness client-credential directory is mounted
   into the container. With `LCR_WITNESS_REQUIRE_MTLS=true` this leaves
   sandbox-b holding the latch with nothing to satisfy it. **That must fail
   loud at boot** — not degrade to a cleartext dial, and not seal `PARTIAL`
   certificates quietly. Provision it, or do not latch that install.

**The named operator step.** Using the §3.3 claim leaf already issued for this
device (one device, one claim identity — do not mint a second):

1. Add a read-only bind mount of the claim-credential directory to the
   `sandbox-b` service in `docker-compose.self-hosted.yml`, or in an overlay of
   your own applied after it:

   ```yaml
   services:
     sandbox-b:
       volumes:
         - /opt/lucairn/certs/witness-client:/etc/lucairn/witness-client:ro
   ```

2. Set the sandbox-b-scoped triple in `customer.env`:

   ```sh
   LCR_WITNESS_MTLS_SANDBOX_B_CA_BUNDLE_PATH=/etc/lucairn/witness-client/ca.pem
   LCR_WITNESS_MTLS_SANDBOX_B_CLIENT_CERT_PATH=/etc/lucairn/witness-client/client.pem
   LCR_WITNESS_MTLS_SANDBOX_B_CLIENT_KEY_PATH=/etc/lucairn/witness-client/client.key
   ```

3. Verify with a render before you start anything:

   ```sh
   docker compose -f docker-compose.customer.yml \
     -f docker-compose.self-hosted.yml \
     -f contrib/witness-central/docker-compose.witness-central.yml \
     --env-file customer.env \
     --env-file contrib/witness-central/witness-central.env \
     config --format json \
   | jq '.services["sandbox-b"] | {env: .environment, vols: .volumes}'
   ```

   All three paths must be non-empty **and** the mount must be present. Either
   half alone is a broken deployment: paths without the mount is a
   file-not-found at boot; the mount without the paths is a credential sitting
   in a container that does not use it.

> 🛑 **The kit ships no default bind mount here, deliberately.** A bind mount of
> a host path that does not exist is materialised by Docker as an **empty
> directory**, not an error. A shipped default would convert "no credential"
> into "a mount that looks present and reads empty" — which is the exact class
> of failure the `:50058` transport gate was rewritten to catch. You provision
> the directory; the compose file does not guess at it.

---

## 7c. The dev-only profile — what activating it costs

`--profile witness-local-dev-only` starts the local `veil-witness` container
again. **It restores self-signed evidence**: the operator's own machine signs
the certificates that attest to that operator's conduct, the signing key sits on
that machine, and the certificates reach no TSA and no Rekor, so
`anchor_status` stays `pending` forever. It is for **offline demos only** and is
never a pilot or production topology.

The same warning is attached to the service as a label so it appears in
`docker compose config` and `docker inspect` for anyone who activates the
profile — see `eu.lucairn.witness.local-profile.warning` in
`contrib/witness-central/docker-compose.witness-central.yml`. (Compose omits
profiled-out services from the default render entirely, so the label is visible
exactly when the profile is on, which is when it matters.)

**If you reached this flag while trying to make a compose error go away, stop.**
The two errors it "fixes" both have a correct repair:

| Symptom | Correct fix |
|---|---|
| `service "cert-builder" depends on undefined service "veil-witness"` — you combined `--profile certification` with this overlay | Do not. `cert-builder` drives a witness rather than dialling one, so it genuinely needs a local witness process. Run the certification profile on the stock topology, without this overlay. |
| `service "sandbox-b" depends on undefined service "veil-witness"` | Already fixed: `sandbox-b`'s edge is `required: false` in `docker-compose.self-hosted.yml`. If you still see this, your `docker-compose.self-hosted.yml` predates 2026-07-28 — update the kit rather than activating the profile. |

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

  This limit is bounded to the CLAIM hop on purpose. The certificate hop —
  the one that reads certificates and bulk-exports placeholder→original maps —
  is separated today (§3.4): its `CN=gateway` leaf lives in its own directory
  and is mounted into the gateway alone, so the RPCs that *disclose* PII are
  authorised at per-service grain even though the RPCs that *submit* claims are
  not. The asymmetry is deliberate: submitting a claim as the wrong emitter on
  your own device forges evidence about that device, while reading certificates
  as the gateway discloses every tenant's originals. Do not "simplify" the two
  credential directories back into one; the kit test suite asserts they are
  distinct and that only the gateway mounts the second.
- **The certificate-hop CN is a role, not a device — the SAN is the device.**
  Every device's gateway leaf carries `CN=gateway`, because that is what the
  ACL matches, so the ACL alone cannot tell one laptop's gateway from another's.
  §3.4 therefore adds a per-device `subjectAltName`, which the witness reads
  under the latch and which `LCR_WITNESS_EXPORT_CUSTOMER_MAP` keys on (§4.1) —
  that is what makes the tenant binding per device rather than fleet-wide.
  Export records DO carry it: `peer_ids=` on every `[witness-export-audit]`
  line lists the full identity set (§4). What it still does **not** buy you:
  the CLAIM path records no device identity at all (§5.1), and revocation is
  still §5.2 re-issuance. A device with no SAN
  — because it predates this change, or because `-extfile` was single-quoted —
  falls back to the fleet-wide identity **silently**; re-check it with the
  `openssl x509 -ext subjectAltName` command in §3.4 rather than assuming.
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
- **Phase-1 revocation is re-issuance** (§5.2), and there is **no general
  per-device claim attribution** (§5.1) — the device countersignature (§10)
  binds one field on one claim to a device key and does not generalise past it.
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

---

## 10. Customer-device countersignature

*PRD: Opus Advisor `specs/2026-07/prd-2026-07-28-cert-anchor-hardening-wave1.md`
(Slice 4). Requires the matching DSA change (`pkg/devicesign`).*

### 10.1 What it is

Splitting the witness off the device (§1) removes the operator of a machine as
the notary of their own conduct. It does not, by itself, put anything in a
certificate that the **central** operator could not have written alone: every
claim is signed with a fleet-shared service key, the certificate is signed with
the witness key, and under this topology both of those live on the central side.

The countersignature closes that. At the gateway's ingress — before parsing,
before classification, before any sanitizer hop — the device hashes the **exact
raw request bytes** it received and signs a commitment to them with its own
private key. The signature travels on the `dsa-sanitizer` claim and ends up in
the certificate.

What that buys, stated exactly: **for a certificate that carries a
countersignature whose key you independently recognise as your own device's,
the central witness operator, alone, can no longer manufacture or alter the
request CONTENT that certificate records.** They never held the device's
private key, so they cannot produce a countersignature for bytes your device
never sent, and they cannot change a commitment without the signature failing.

Both qualifiers in that sentence are doing work, and neither is a formality:

- **"that carries a countersignature"** — the operator can still issue a
  certificate with the field simply absent. Absence is recorded honestly (§10.4)
  and a presented-but-unusable object is recorded as malformed rather than
  vanishing, so you can *detect* this; nothing *prevents* it. A device that
  should be countersigning and produces a run of uncountersigned certificates is
  the signal to investigate.
- **"whose key you independently recognise"** — the certificate carries the
  signing key, not a proof that the key is yours. An operator could insert a
  self-consistent key of their own and every internal check would pass. Peer
  binding at the witness (matching the signing key to the mTLS peer) is
  currently **log-only and does not appear in the certificate**. Verification
  therefore depends on you comparing the SPKI in the certificate against the
  device leaf your own CA ceremony issued — the recipe in §10.5. Skip that
  comparison and this guarantee is not established.

What it does **not** buy, stated just as exactly — and read this list before
repeating the sentence above to anyone:

- **CONTENT, NOT CONTEXT.** The signature covers the request id and the hash of
  the raw bytes, and nothing else — no timestamp, no certificate id, no
  conversation, and none of the sanitizer's own outputs. So a countersignature
  can be lifted verbatim out of one certificate and attached to another: the
  link between it and the rest of the certificate is the sanitizer's own
  signature, whose verifying key the witness operator configures. **When** you
  sent it, in which conversation, under which certificate, and with what
  redaction outcome are not protected. Binding those is a follow-up change to
  the signed message; it is not in this slice.
- **No time, no revocation.** Nothing checks the device leaf's validity dates,
  and the signed message carries no timestamp, so a countersignature made with
  an expired or since-re-issued credential still verifies forever. Revocation
  (§5.2) stops the credential from opening new connections; it cannot reach
  back into signatures already made.
- It says nothing about whether the device is honest. A compromised device
  signs whatever it is told to sign.
- It is not custody proof, in two senses. Your CA ceremony machine (§3.3)
  generates the device key before distributing it, so whoever runs that ceremony
  can retain a copy — under this topology that party is **you**, not Lucairn,
  which is the whole reason the guarantee holds. And on the device itself the
  overlay mounts this credential into **four** containers (gateway, sanitizer,
  id-bridge, audit), so code execution in any one of them — including the
  sanitizer, which handles raw PII — can produce countersignatures in your name.
- **The commitment is an unsalted hash of your raw request.** Anyone who obtains
  a certificate obtains an offline oracle for that request's exact bytes. For a
  templated automation with one variable field (a case id, a patient number),
  holding the certificate and the template makes that field a dictionary attack.
  Salting cannot fix this without destroying the third-party verifiability in
  §10.5. Accepted residual — and *not* the same exposure class as the existing
  `token_hash`, which hashes a random secret no dictionary can reach.
- It covers the **request**. The response, and everything the model did with
  the request, are not countersigned by anything.

### 10.2 Setup: no NEW step — but §3.3's ownership rule is load-bearing here

No new key, ceremony step or variable is added. That is the reason the design
was chosen over a dedicated signing key. It does mean this feature inherits
§3.3's ownership requirement completely: the credential must be owned by the
UID the containers run as (10001 by default), or the signer has nothing to read
and the stack does not boot. Verify with the in-container `cat` check in §3.3
before assuming a device is countersigning.

The signer reads the credential §3.3 already provisions:

```
LCR_WITNESS_MTLS_CA_BUNDLE_PATH    /etc/lucairn/witness-client/ca.pem
LCR_WITNESS_MTLS_CLIENT_CERT_PATH  /etc/lucairn/witness-client/client.pem
LCR_WITNESS_MTLS_CLIENT_KEY_PATH   /etc/lucairn/witness-client/client.key
```

No new key, no new ceremony step, no new variable.

⚠️ **The witness-scoped family is REQUIRED — the mesh-wide `DSA_MTLS_*` triple
is deliberately not accepted here**, even though it is a perfectly good
credential for the claim *dial*. `DSA_MTLS_*` is a per-**service** key issued by
whoever operates the deployment. Signing with it would attribute the operator's
own key to your device and the witness would then record that at maximum
confidence — the exact inverse of what this feature is for. So a deployment with
only `DSA_MTLS_*` set logs `not enabled` and issues certificates with no
countersignature, which is the honest outcome. A **partial** `LCR_WITNESS_MTLS_*`
triple is also refused, for the same reason the claim dial refuses it.

If §3.3 was performed and the overlay is applied, the gateway countersigns —
subject to the `FAILED` case below. Confirm from the gateway's startup log
rather than assuming; the three states are distinguishable on purpose:

```sh
docker compose ... logs gateway | grep -i 'device countersignature'
# ACTIVE:      device countersignature ACTIVE: LCR_WITNESS_MTLS_* key <hex> (alg ecdsa-p256-sha256) ...
# not enabled: no credential configured — expected on a stock install
# FAILED:      credential configured but unusable — read the reason on the line
```

`FAILED` does **not** stop the gateway. Requests are protected exactly as
before; only the extra evidence is missing. That is intentional: refusing to
serve would trade the guarantee that protects the customer for the one that
merely records it.

⚠️ **`FAILED` is a narrow state — do not read it as "any bad credential lands
here."** Most ways a credential can be wrong (a partial `LCR_WITNESS_MTLS_*`
triple, an unreadable file, bad CA material, a cert and key that do not match)
are caught earlier, when the witness emitter initialises, and those **stop
gateway boot** instead. In practice only a credential that loads fine for TLS
but cannot sign a countersignature — an RSA leaf, today — reaches this state.
So: stack up but `FAILED` in the log means "usable for the dial, unusable for
signing"; stack refusing to boot is the more common credential symptom, and
§3.3's ownership rule is the most common cause of it.

Key types: the §3.3 ceremony issues `prime256v1`, which is supported
(`ecdsa-p256-sha256`), as is Ed25519 (what the DSA `bootstrap-mtls-ca.sh`
issues). An **RSA** device leaf is not part of the wire contract and logs
`FAILED` at boot.

### 10.3 What lands in the certificate

Inside the `dsa-sanitizer` claim's signed `canonical_payload`, under
`device_countersign`:

| Field | Meaning |
| --- | --- |
| `v` | Wire version (`1`). |
| `commitment_alg` / `request_commitment` | `sha256`, hex, over the raw request bytes as received. |
| `signature_alg` / `signature` | `ecdsa-p256-sha256` or `ed25519`; base64 (ECDSA is ASN.1 DER). |
| `device_key_id` | `sha256` over the DER SPKI of the device public key. |
| `device_public_key` | Base64 DER SPKI — makes verification self-contained. |

The signed bytes are a domain-separated, length-framed message binding the
`request_id` to the commitment, so a genuine countersignature cannot be moved
onto a different request.

Two things this does **not** change, and both are load-bearing:

- **No signable bytes move.** The witness signable map stays v2 = 7 keys and
  v3 = 13 keys. This is claim-scoped additive metadata, exactly like
  `redaction_manifest_hash` and `tms_manifest_hash`. Every SDK verifier in the
  field keeps verifying certificates issued before and after this change.
- **The device CN is not published.** `device_key_id` is a hash, not your
  machine name. The CN you chose in §3.3 stays out of the claim.

### 10.4 Honest absence — read before filing a bug

**A request without a countersignature proceeds normally, and its certificate
simply lacks the fields. It never blocks a request, and neither does an invalid
one.** Absence is a rendered state, not a failure:

- A **stock** install (no witness-central ceremony) has no device identity and
  never countersigns. Its certificates are the same shape as every certificate
  issued before this feature existed.
- The hosted lane has no device identity either.
- A certificate that predates this change has no fields to show.
- **Some request paths are out of scope in this slice** and produce
  uncountersigned claims even on a fully-provisioned device: Sensitive Mode's
  `/seal-cert` input-shield flow, the sanitizer's cumulative *streaming*
  claim, and the anonymous `/api/v1/scan` preview (which carries no pipeline
  request id, so a countersignature could not be bound to anything). The four
  chat transports — `/v1/messages`, `/v1/chat/completions`, the MCP endpoint
  and `/api/v1/proxy/messages` — are covered.
- A **malformed** countersignature (wrong wire version, undefined algorithm,
  over-long field) is dropped by the sanitizer and therefore also renders as
  absent. The reason is written to the sanitizer log — grep
  `device_countersign dropped` before concluding a device never countersigned.
  This is the one place where absence and "something was wrong" overlap; a
  wrong *signature* is not affected and still renders as the third state below.

Three outcomes, three distinct meanings — do not let a reader collapse them:

| In the certificate | Means |
| --- | --- |
| no `device_countersign` key | This device did not countersign. Normal. |
| present, verifies | The device that holds that key committed to those exact bytes. |
| present, does not verify | **Something is wrong.** The claim is still accepted and stored verbatim so the discrepancy survives — investigate; do not treat it as absence. |

### 10.5 Verifying one yourself

The central witness checks each countersignature at claim intake and logs the
outcome (`witness_device_countersign_total`, labels `status` and
`peer_binding`). Do not stop there: **that verdict comes from the party the
countersignature exists to constrain.** Its value to you is operational, not
evidentiary.

The evidentiary property is that the claim carries the commitment, the
signature and the public key verbatim, so you can re-run the check yourself,
offline, at any time, without asking the operator for anything:

1. Take `device_public_key` from the claim, base64-decode it, and confirm
   `sha256` of those bytes equals `device_key_id`.
2. Confirm that public key is one you issued — compare against the leaves from
   your §3.3 ceremony:
   `openssl x509 -in client-<device>.pem -pubkey -noout | openssl pkey -pubin -outform DER | shasum -a 256`
3. Rebuild the signed message: the ASCII prefix `lucairn-device-countersign-v1`,
   then a big-endian `uint32` length followed by the claim's `request_id`, then
   a big-endian `uint32` length followed by the 32 raw bytes of
   `request_commitment`.
4. Verify `signature` over that message (ECDSA-P256 verifies over its `sha256`;
   Ed25519 verifies over the message directly).
5. If you still hold the original request bytes, confirm `sha256` of them equals
   `request_commitment`. This is the step that makes it evidence about *content*
   rather than about a hash — Lucairn cannot perform it for you, because Lucairn
   does not hold your raw request.

No SDK implements this recipe yet. "Anyone can re-check it" today means by hand,
from the steps above — the bytes are all present in the certificate, but no
shipped tool walks them for you.

The one check that is **not** reproducible later is the peer binding: at intake
the witness could see which mTLS-authenticated device opened the connection and
confirm it was the same key. Once the connection closes that fact exists only in
the witness log line — which is **operator-held and therefore not evidence you
can rely on**; treat it as triage, not proof.

⚠️ A peer binding that is *not* `verified` is also not an accusation. It only
verifies where the countersigning service and the claim-submitting service
present the same leaf — the gateway signs and the sanitizer submits, which is
one shared credential under this overlay but two different ones under any
per-service mTLS mesh. On such a deployment every healthy request reports the
binding as unverified, which is why it is not reported as invalid.

### 10.6 Effect on §5.1

§5.1 says the claim hop authenticates "a device in the fleet, never *which*
device", and that the per-device TLS identity is not bound to the claim it
carries. That remains true of the **transport**, and it remains true of every
claim that carries no countersignature — which a hostile device can always
choose.

What changed is narrower and worth stating without inflation: when a
countersignature IS present, the claim carries a device-bound signature over the
request commitment, and the witness additionally records whether that key was
the mTLS peer on the connection. That is per-device attribution **of the
request commitment on the sanitizer claim**, opt-out-able by any party that
declines to produce one. It is not general per-device claim provenance, it does
not make the other three claims attributable, and it is not a revocation
mechanism (§5.2 is still re-issuance).
