# INSTALL

Goal: a competent platform engineer should complete a standard install in about 3 hours without a vendor call.

## Doctor lifecycle

Use `doctor --offline` only as the configuration preflight; it requires no
customer key, model, listener, runtime, or network and ends with `doctor:
preflight ok (offline)`. For Helm values-only preflight, the terminal line is
`doctor: preflight ok (values-only)`. Then start the recorded topology, wait
for health/readiness, mint the first customer key to a regular mode-0600 file,
and run online doctor with `--customer-key-file`. Supply `--model` for
split-remote or managed-BYOK; local-runtime uses only its single recorded S1
inventory name. Online `doctor: ok` proves authenticated inference, certificate
receipt, and witness-signature verification; anchors are explicitly not checked.

## Release notes

> The canonical changelog is [`CHANGELOG.md`](CHANGELOG.md). Security advisories
> are published at <https://lucairn.eu/security>; the disclosure process and
> contact are in [`SECURITY.md`](SECURITY.md).

### kit 2.0.0 / chart 2.0.0 (images 1.1.0) — the hosted service's sanitizer core

**Upgrade from 1.9.7:** follow § [Upgrade from kit 1.9.7 to 2.0.0](#upgrade-from-kit-197-to-200)
— images `0.5.5` → `1.1.0`, four new services (the core's registry database,
model sidecar, core and migration step), new `customer.env` settings, the
runtime profile re-recorded, the registry migration as its own step. No 1.x
schema change. The host needs at least 16 GB RAM for Docker and Docker Engine
26.0.0 or newer. The ServiceNow mode stays off. Every third-party image
(`postgres`, `redis`, `migrate`, `alpine`, …) is now pulled by the digest
`image-manifest.yaml` records. The third-party notices for the models and data
the images redistribute are in `licenses/NOTICE` (licence texts beside it). Read
`CHANGELOG.md` `[2.0.0]` → "Stated limits".

### kit 1.9.7 / chart 1.9.7 (2026-10-28, images 0.5.5) — QI engine off by default

**Upgrade from 1.9.6:** no image, schema or ceiling change — keep
`LUCAIRN_IMAGE_TAG=0.5.5` / `global.imageTag: "0.5.5"`. The quasi-identifier
(QI) engine now ships off (T-1433): on kit defaults the `0.5.5` sanitizer
replaced every user message with `[NUMERIC]`, because its field classifier
matched "age" inside the field name `user_message_<n>`. **An existing install
keeps its own value.** Compose: set `QI_ENGINE_ENABLED=false` in
`customer.env` (or delete the line), then `bin/lucairn up --env customer.env`.
Helm: a plain `helm upgrade` picks up `"false"` unless your own values set it;
with `--reuse-values` use `--reset-then-reuse-values` (Helm 3.14 or newer) or
`--set-string sandbox-a.sanitizer.qiEngineEnabled=false`, then
`kubectl -n dsa-identity rollout restart deployment/sandbox-a`. To keep the QI
engine on (only for requests with structured fields such as `age`,
`zip_code`, `birth_date`), set `QI_ENGINE_ENABLED=true` /
`sandbox-a.sanitizer.qiEngineEnabled: "true"`; on the `0.5.5` image that
brings the `[NUMERIC]` replacement back for chat traffic. The `postgres:16-alpine` and
`redis:7-alpine` images are re-pinned to the digests upstream publishes today.
Read `CHANGELOG.md` `[1.9.7]` → "Stated limits".

### kit 1.9.6 / chart 1.9.6 (2026-10-04, images 0.5.5) — audit claim-delivery retention

**Upgrade from 1.9.5:** no image, schema or ceiling change — keep
`LUCAIRN_IMAGE_TAG=0.5.5` / `global.imageTag: "0.5.5"`. The upgrade adds a
retention sweep for the audit table `audit_claim_deliveries` (T-1219; closes
the 1.9.5 known gap). Once a day it blanks the signed claim bytes and the
output-scan summary of rows whose witness delivery finished more than 30 days
ago. Rows are kept, not deleted. Helm adds a CronJob in the audit namespace;
Compose adds the service `audit-claim-delivery-retention`, which `bin/lucairn
up` starts. Its first run clears the backlog accumulated since 1.9.5. Change
the period with `audit.claimDeliveryRetention.retention` (e.g. `30d` — whole
days with a `d` suffix) / `LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS` (whole
days, at least 1), or set
`…enabled` / `…_ENABLED` to `false` **before upgrading** to keep the 1.9.5
behaviour. With an external audit Postgres nothing is scheduled; OPS.md
§ "Audit claim-delivery retention" has the SQL to run yourself.

### v0.5.5 / chart 1.9.5 (2026-10-04) — sanitizer roster 36 (attribution leak closed), T-1102 gateway key separation

**Read `CHANGELOG.md` `[1.9.5]` → "Read first" before upgrading.** Two steps
are order-sensitive:

1. **T-1102:** the 0.5.5 gateway refuses to boot while it holds a `dsa-ai` or
   sandbox-B signing key. On Helm set `gateway.secrets.values.veilAISigningKey`
   to `""` **before** `helm upgrade`. On Compose the shipped gateway service
   receives none of those keys (keep `LCR_SANDBOX_B_SIGNING_KEY` in
   `customer.env` — sandbox B needs it).
2. **Database migrations:** the audit ceiling rises 6 → 7 — the migration Job
   creates one new table, `audit_claim_deliveries`, which the 0.5.5 audit
   service needs (it holds no raw text; no deletion path in 1.9.5 — the
   retention sweep ships in 1.9.6, T-1219). Remove
   any `LUCAIRN_MIGRATE_TARGET_AUDIT=6` override from `customer.env` (Helm:
   any `audit.migrations.targetVersion: 6` in your values) — below 7 every
   completed request fails with 503. Other
   ceilings unchanged (veil-witness 10 · id-bridge 4 · sandbox-a 8); see the
   changelog's migration review.

**Upgrade from v0.5.4:** pull the new images (`LUCAIRN_IMAGE_TAG=0.5.5` in
`customer.env`; or `global.imageTag: "0.5.5"` in Helm values). The 12 `dsa-*`
images are republished + cosign-signed + Rekor-logged at `0.5.5`
(`bin/lucairn verify-images --tag 0.5.5`). `dsa-pii-ml` stays `0.5.1`
(independent cadence) and `lucairn-dashboard` stays `0.8.2`.

**What changed for the sanitizer:** the shipped roster grows from 34 to 36
recognizers — `attribution_person` (closes the ServiceNow `"Reviewed by
<Name>"` leak) and `labeled_id` (digit runs next to an ID label). Restart the
sanitizer so it loads the new config (Helm: `kubectl -n <namespace> rollout
restart deployment/sandbox-a`; Compose: `docker compose up -d
--force-recreate sanitizer`). A Compose install with its OWN sanitizer config
must add the two names itself.

### v0.5.4 / chart 1.9.4 (2026-06-19) — per-key MCP tool-scope enforcement + B2 website tool_allowlist

**Upgrade from v0.5.3:** pull the new images (`LUCAIRN_IMAGE_TAG=0.5.4` in
`customer.env`; or `global.imageTag: "0.5.4"` in Helm values). No database
migration required on the gateway/DSA stack (Supabase `api_keys.tool_allowlist`
migration applies to the hosted control-plane only; self-hosted kit is unaffected).
The 12 `dsa-*` images are republished + cosign-signed + Rekor-logged at `0.5.4`
(`bin/lucairn verify-images --tag 0.5.4` → 13/13). `dsa-pii-ml` stays `0.5.1`
(independent cadence) and `lucairn-dashboard` stays `0.8.2`.

**What changed:**

- **Per-key MCP tool-scope enforcement (gateway):** the gateway now reads a
  `tool_allowlist` field from the customer profile (synced via `ControlAPISync`)
  and enforces it server-side on every `/api/v1/mcp` request — only MCP data-source
  tools in the allowlist are forwarded to the model; all other `mcp__*` tools are
  stripped. Empty allowlist (default) is byte-identical to pre-0.5.4 behaviour
  (INERT until configured). Controlled via the admin UI `ToolAllowlistForm` or
  the `/api/admin/keys/:id/tool-allowlist` route. Ships in DSA PR #303.
- **Approach B scoping:** only MCP data-source tools (`mcp__*` prefixed) are
  stripped by the allowlist; non-MCP tools (Claude Code built-ins, custom tools)
  are always passed through — zero-maintenance, no built-in catalog to maintain.

### v0.5.3 / chart 1.9.3 (2026-06-16) — Lucairn anti-tamper (INERT until pin-baked) + S1–S6 security remediations

**Upgrade from v0.5.2:** pull the new images (`LUCAIRN_IMAGE_TAG=0.5.3` in
`customer.env`; or `global.imageTag: "0.5.3"` in Helm values). No database
migration required. The 12 `dsa-*` images are republished + cosign-signed +
Rekor-logged at `0.5.3` (`bin/lucairn verify-images --tag 0.5.3` → 13/13).
`dsa-pii-ml` stays `0.5.1` (independent cadence) and `lucairn-dashboard` stays
`0.8.2`.

**What changed:**

- **Deployment-entitlement anti-tamper (INERT on stock images):** 0.5.3 carries
  the anti-tamper coupling from Lucairn PRs #291/#292 — fail-closed boot on a
  missing/forged entitlement; `POST /api/v1/register` disabled (`403
  registration_disabled`); `DSA_ENV=development` enforcement bypass closed;
  `customer_id` coupling (`403 entitlement_mismatch`). **The stock GHCR images
  ship `PinnedPublicKeyHex=""` and are fully INERT for anti-tamper.** Setting
  `LUCAIRN_LICENSE_KEY` + `LUCAIRN_LICENSE_PUBLIC_KEY` on a stock image gives
  feature-gating only — no fail-closed boot, no key↔entitlement coupling,
  `/api/v1/register` stays open, `DSA_ENV=development` still bypasses.
  Enforcement activates only on a Lucairn-built pin-baked gateway image (built
  with the Ed25519 public key baked into `PinnedPublicKeyHex` via `-ldflags -X`).

- **S1–S6 security remediations:** six security-audit findings remediated across
  the `dsa-*` service images (see the [Lucairn security advisories](https://lucairn.eu/security)
  and [`SECURITY.md`](SECURITY.md) for full detail).

### v0.5.2 / chart 1.9.2 (2026-06-15) — A6 LOCATION stop-list + turnkey sign-manifest

**Upgrade from v0.5.1:** pull the new images (`LUCAIRN_IMAGE_TAG=0.5.2` in
`customer.env`; or `global.imageTag: "0.5.2"` in Helm values). No database
migration required. The sanitizer container restart is the only operational
step. The 12 `dsa-*` images are republished + cosign-signed + Rekor-logged at
`0.5.2` (`bin/lucairn verify-images --tag 0.5.2` → 13/13). `dsa-pii-ml` stays
`0.5.1` (independent cadence) and `lucairn-dashboard` stays `0.8.2`.

**What changed:**

- **A6 strict LOCATION stop-list (no recall loss):** A second, distinct L2
  mechanism — spaCy's *own* English NER (`SpacyRecognizer`) — still mis-tagged
  common English words like `West`/`Loop`/`For` as LOCATION in messy
  ITSM/ServiceNow prose, even after the 0.5.1 `de_places` en-exclusion. Fix: a
  new whole-token-exact LOCATION stop-list (`config/safe-terms-strict-location.txt`)
  drops a detection ONLY when it is a single LOCATION-typed token from spaCy's
  own NER that exactly matches a listed term. Multi-word places ("West Berlin"),
  longer tokens ("Westminster"), PERSON-tagged "West", and L1 identity surnames
  all stay redacted — recall-safe by construction (`marc`/`grep`/`may` are
  deliberately excluded as real-name risks). Bundled in the kit
  (`config/safe-terms-strict-location.txt`), mounted into the sanitizer
  container, and wired in `config/default-sanitizer.yaml`, the ITSM starter
  template, and the Helm sanitizer ConfigMap.

- **`sign-manifest` is now turnkey:** The `dsa-veil-witness:0.5.2` image ships
  the `sign-manifest` tool at `/usr/local/bin/sign-manifest`. The production
  key-ceremony step (INSTALL § 4b) now uses
  `docker run --entrypoint sign-manifest ghcr.io/declade/dsa-veil-witness:0.5.2 …`
  — no Go toolchain, no build-from-source, no dev-mode fallback. Closes
  BLOCKER-3.

### v0.5.1 / chart 1.9.1 (2026-06-14) — L1+L2 over-redaction fix

**Upgrade from v0.5.0:** pull the new images (`LUCAIRN_IMAGE_TAG=0.5.1` in
`customer.env`; or `global.imageTag: "0.5.1"` in Helm values). No database
migration required. The sanitizer container restart is the only operational
step.

**What changed:**

- **Strict product-vocabulary safe list (no recall loss):** The hosted L1+L2
  sanitizer (Presidio/spaCy) mis-tagged system/product vocabulary as PERSON on
  ITSM and ServiceNow payloads — `Claude` appeared as `[PERSON_4]` 81× in a
  single session; `signable` appeared as `[PERSON_2]`. Root cause: spaCy's
  English NER tagged these at PERSON@0.85 confidence. Fix: a new
  *strict whole-span-exact* safe list (`config/safe-terms-strict.txt`) — a
  Presidio detection is suppressed ONLY when the entire detected span equals a
  safe term. Multi-token spans like "Claude Müller" are **NOT** suppressed;
  the surname still redacts. Recall on real PII is unchanged (hard gate:
  100% recall on the conv-3cde524c adversarial fixture).
  Terms: `Claude / Opus / Sonnet / Haiku / Anthropic / Lucairn / Codex / Veil /
  signable / Remedy`.

- **German place-name de_places en-exclusion:** The German place-name
  recognizer (`de_places`) no longer fires on English-language input. Baked
  into the sanitizer image; no config change required.

Both fixes are delivered in the `0.5.1` sanitizer image.

> **Where the strict safe list lives now (T-576).** It used to be wired through
> `presidio.strict_safe_terms_file: /config/safe-terms-strict.txt`. The
> sanitizer **retired that key on 2026-07-25 and now refuses to boot on it** —
> leaving it set CrashLoopBackOffs the sanitizer, `sandbox-a` never becomes
> Ready, and the gateway restart-loops behind it. The same ten terms now live
> inline under `sanitizer.redaction_policy.stop_terms` with `surface:
> l1_strict` in `config/default-sanitizer.yaml`, `starter-templates/itsm/config.yaml`
> and the Helm `sanitizer-config` ConfigMap. Semantics are unchanged. To add
> your own strict terms: edit that block, or set the Helm value
> `sandbox-a.sanitizer.strictSafeTerms`. **Never put a real given name or
> surname on that list — it would stop being redacted.**

## Step 0 — Registry access (REQUIRED before any docker pull)

> **Do this before any other step.** The 12 Lucairn `dsa-*` images live in the
> **private** `ghcr.io/declade/*` registry. A self-minted GitHub PAT alone is
> NOT sufficient — Lucairn must also GRANT package-pull access to the GitHub
> account that owns the PAT. Without this grant every `docker pull` / `docker
> compose up` will fail with `denied: permission_denied`.

**How to get access:**

1. Email **support@lucairn.eu** with your GitHub username.
2. Wait for Lucairn to confirm registry access (typically within one business day).
3. Only then proceed to mint a PAT and run `docker login` (§ "Registry Authentication" below).

If you intend to mirror images to your own internal registry instead, this prerequisite is moot — skip to § "Mirroring images to a private registry".

> **Base images also need outbound access.** In addition to `ghcr.io`, the stack
> pulls public base images from Docker Hub (`registry-1.docker.io`,
> `auth.docker.io`, `production.cloudflare.docker.com`):
> `postgres:16-alpine`, `redis:7-alpine`, `alpine:3.20`,
> `migrate/migrate:v4.17.0`, `ollama/ollama`. A host that allowlists only
> `ghcr.io` will authenticate successfully but fail `docker compose up` when
> Docker attempts these pulls. **`LUCAIRN_IMAGE_REGISTRY` does NOT redirect
> base-image pulls** — it only prefixes the 12 Lucairn `dsa-*` images. To block
> direct Docker Hub access, configure a **registry pull-through mirror** for
> `registry-1.docker.io` on your infrastructure; alternatively, manually mirror
> the specific tags above and edit the `image:` lines in the compose files.
> Since kit 2.0 every one of these references carries the digest
> `image-manifest.yaml` records (`postgres:16-alpine@sha256:…`): Docker pulls
> exactly those bytes, so a mirror must serve the same image (same digest), and
> an edited `image:` line keeps the `@sha256:…` part.

## Dev local-runtime quickstart (model required)

```
git clone https://github.com/Declade/lucairn-enterprise-deployment-kit && cd lucairn-enterprise-deployment-kit
# Step 0: Lucairn must GRANT your GitHub account registry access BEFORE this step.
# See § "Step 0 — Registry access" above. One-time per host:
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
# Lucairn does not ship model weights. Obtain a compatible GGUF under your
# license/provenance process, then stage it at this exact filename.
mkdir -p models
cp /secure/models/customer-model-q4.gguf models/customer-model-q4.gguf
./bin/lucairn-init --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name customer-model --model-file customer-model-q4.gguf --model-path .
# Recommended: bin/lucairn up --env customer.env (runs the registry migration
# below first, then starts the recorded topology). With plain Compose, migrate
# first — the sanitizer core refuses to start on an unmigrated registry:
docker compose -f docker-compose.customer.yml -f docker-compose.self-hosted.yml --env-file customer.env \
  --profile sanitizer-core-migrate run --rm migrate-sanitizer-core
docker compose -f docker-compose.customer.yml -f docker-compose.self-hosted.yml --env-file customer.env --profile llama-cpp up -d
```

This path is runnable only after the required model is staged. Lucairn does
not distribute model weights. `bin/lucairn-init --dev --runtime-mode local-runtime --local-runtime llama-cpp` writes a fully-populated `customer.env` and its non-secret
`customer.env.runtime-profile.yaml` sidecar plus the recorded non-secret
`customer.env.image-manifest.yaml` snapshot (5 Ed25519 keypairs, hex32 service
secrets, postgres passwords, sensible dev-mode defaults) and runs its offline
doctor preflight against them before exiting. Keep all three artifacts
together: `customer.env` and its two sidecars.
Use `bin/lucairn-mint-customer` once the stack is healthy to provision your
first customer.

The `docker login` step requires Lucairn to have granted package-pull access
to the GitHub account that owns the PAT (see § "Step 0" above). First-time
setup walkthrough is in § "Registry Authentication" below. Skip the ghcr.io
`docker login` step ONLY when you are mirroring
images to a private registry — set `LUCAIRN_IMAGE_REGISTRY` to the mirror
prefix. If your private mirror requires authentication, run `docker login
<your-mirror-host>` instead (same `--password-stdin < ~/.<registry>-token`
pattern as the ghcr.io flow above).

For production deployment with a Lucairn-issued license, see "Choose A
Deployment Mode" below and use `./bin/lucairn-init --production --runtime-mode
<mode> --license <path>`. For managed-LLM mode (BYOK Anthropic, OpenAI,
etc.) use `--runtime-mode managed-byok` and populate the provider key before
`docker compose up`. The
`bin/lucairn-init --help` lists every flag.

Run this enterprise kit from supported Linux or macOS operator shells, using
Docker Compose or Kubernetes. It does not install a Windows end-user client;
that client-install surface is WP5.

## Lucairn Enterprise v1.0 deployment topology

**v1.0 ships single-replica gateway.** Each Helm install runs one gateway
pod with a persistent volume mounted at `/etc/dsa/keystore`. API keys
persist across pod restarts via the PVC. Pilot customers handling
<500 req/sec are easily served by a single pod.

**Horizontal scaling is roadmapped for v2.0.** The chart includes the
`postgres-gateway` subchart for v2.0 multi-replica HA, but it is disabled
by default and not exercised in v1.0. Operators should NOT set
`gateway.replicaCount > 1` or `postgres-gateway.enabled: true` until v2.0
ships — the umbrella validator fails-fast on the mixed case (one flag on,
one off).

Back up the keystore PVC (`kubectl get pvc -n dsa-edge | grep keystore`)
on the schedule appropriate for your operational policy. The PVC has
`helm.sh/resource-policy: keep` so `helm uninstall` preserves keystore
data (matching the existing `postgres-gateway-data` PVC pattern carried
forward for v2.0).

### Node drain in v1.0 (single-replica services)

Because the request-path services run a single replica in v1.0, the chart
intentionally renders **no PodDisruptionBudget** for them. A PDB with
`minAvailable: 1` on a one-pod workload would make `kubectl drain` hang
forever — the drain can never evict the only pod without violating the
budget. So `kubectl drain` works normally, but expect a brief gap on the
drained service while Kubernetes reschedules the pod onto another node:

```bash
# Drain a node for maintenance (single-replica services see brief downtime).
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# After maintenance:
kubectl uncordon <node>
```

To minimise the gap, schedule node maintenance during a low-traffic window,
and pre-warm a replacement node so rescheduling is fast. Each service also
runs a `preStop` drain delay (default 5s, `gracefulShutdown.preStopSleepSeconds`
in the subchart values) so in-flight requests complete before the pod exits
during the reschedule.

When v2.0 unlocks 2+ replicas, the PDB auto-renders with `maxUnavailable: 1`,
which lets `kubectl drain` evict one pod at a time while keeping the service
available throughout.

## Phase 7 ML PII scanners (Piiranha + GLiNER, pii-ml sidecar)

The kit includes a dedicated `pii-ml` gRPC sidecar service that runs the
Phase 7 ML PII scanners — `iiiorg/piiranha-v1-detect-personal-information`
(a fine-tuned transformer NER for personal data) plus
`urchade/gliner_multi-v2.1` (a zero-shot NER for German + English PII).
The sidecar was extracted from the sanitizer monolith at the PR #240
production-path follow-up after the original in-process eager-load
exhausted gunicorn worker memory on the pilot box.

### Architecture summary

- The `pii-ml` deployment ships in the `dsa-identity` namespace alongside
  `sandbox-a` + `sanitizer`. It exposes a gRPC service on port `50056` and
  an HTTP `/healthz` + `/readyz` probe on port `8088`.
- The sanitizer dials the sidecar via the in-cluster Service DNS
  `pii-ml.dsa-identity.svc.cluster.local:50056` whenever a request
  reaches Phase 7. A circuit breaker (3 consecutive failures, 30s
  half-open) gracefully degrades to L1+L2 if the sidecar is unavailable.
- The sidecar eager-loads both models at boot. `/readyz` returns 200 ONLY
  after both models are loaded — the readyz gate is fail-CLOSED, so a
  failed model load keeps the sidecar out of the Service endpoint set
  and traffic never reaches it.
- HF model weight downloads (~1.6GB one-time) happen at first boot.
  Default config uses an `emptyDir` HF cache that re-downloads weights per
  pod start; override to a PVC for cross-restart persistence
  (recommended for air-gapped sites — see
  `OPS.md` § "pii-ml sidecar — HF cache PVC").

### Default-OFF as of chart v1.7.1 — Phase 7 ML suspended

> **Product change (chart v1.7.1, 2026-06-10):** the Phase 7 ML PII layer
> (Piiranha + GLiNER) is **DISABLED by default** for fresh enterprise
> installs. The ML sidecar saturates CPU and overloads on large prompts
> (~147KB routed Claude Code turns), which induced ~90s/turn latency and
> a fail-closed refusal on the reference pilot. The **deterministic layers
> (known-entity matching + Presidio L1/L2) remain active**, so PII is still
> redacted and certs are still anchored — only the optional ML augmentation
> layer is suspended. This is reversible (see "Re-enabling Phase 7" below).

Phase 7 activation requires flipping BOTH gates ON (both default OFF as of
v1.7.1):

1. `pii-ml.enabled: true` — deploys the sidecar (**default off** as of v1.7.1)
2. `sandbox-a.sanitizer.piiranha.enabled: true` AND
   `sandbox-a.sanitizer.gliner.enabled: true` — sanitizer dials the
   sidecar on Phase 7 scans (default off)

The half-enabled combos are non-fatal but documented misconfigurations:

- Sidecar deployed, sanitizer layers off → wasted resources, Phase 7
  layers never fire.
- Sidecar disabled, sanitizer layers on → sanitizer dials a nonexistent
  service every Phase 7 scan; the circuit breaker opens within 3
  requests and Phase 7 stays dormant (functional but log-noisy).

With BOTH gates off (the v1.7.1 default), the sidecar does not deploy, the
sanitizer never dials it, and the sanitizer starts happily with no pii-ml
sidecar present.

### Re-enabling Phase 7

Set `pii-ml.enabled: true` AND
`sandbox-a.sanitizer.piiranha.enabled: true` AND
`sandbox-a.sanitizer.gliner.enabled: true` in your `customer-values.yaml`.
The sidecar renders, the sanitizer dials it on Phase 7 scans, and the ML
augmentation layer fires on top of the deterministic L1+L2 layers. Note
the [memory requirements](#memory-requirements) (4Gi for the sidecar) and
the first-boot HF weight download (~1.6GB) before re-enabling.

For the Compose deploy path, the `pii-ml` sidecar service is gated behind
the `phase7` Compose profile (so a default `docker compose up` does not
start it). Re-enable Phase 7 by (1) setting `sanitizer.piiranha.enabled:
true` + `sanitizer.gliner.enabled: true` in your
`config/default-sanitizer.yaml`, then (2) bringing the stack up with the
profile active:

```bash
# On a running install the registry is already migrated; on a fresh one run the
# migrate-sanitizer-core step first (§ "Sanitizer core (kit 2.0, Compose)" step 3).
docker compose --profile phase7 \
  -f docker-compose.customer.yml --env-file customer.env up -d
```

Note the 4Gi sidecar memory requirement and the ~1.6GB first-boot HF
weight download (3–8 minutes cold-cache) before re-enabling.

### HuggingFace model revision pins

The chart pins three HF revision SHAs (Piiranha primary, GLiNER primary,
GLiNER fallback) via `pii-ml.hfRevisions.{piiranha,gliner,glinerFallback}`.
These are LOAD-BEARING — changing them silently swaps the model behavior
and can cascade into per-layer F1 / over-redaction regressions. The
defaults match the SHAs baked into the `dsa-pii-ml` image's
`image-manifest.yaml` entry. Override only if you mirror HF weights into
a private bucket AND verify the same SHAs are present.

**On image upgrade:** when you bump the `dsa-pii-ml` image tag to a new
release, check `image-manifest.yaml` § `services.dsa-pii-ml` for the new
recorded `image_tag` AND verify the HF SHAs in `pii-ml.hfRevisions` still
match the values baked into the new image. A SHA mismatch on a kit
upgrade will silently re-download model weights at a different revision
on first cold-cache boot.

### Managed-container-runtime caveat (ACA / ECS / Cloud Run)

The sanitizer has **no startup dependency on pii-ml on any path** — there
is no `depends_on: pii-ml` on the Compose `sanitizer` service and no
readiness gate against the sidecar on the Helm `sandbox-a` Deployment — so
the sanitizer always starts independently regardless of runtime. While the
`pii-ml` sidecar is still cold-loading its models (3-8 minutes on a fresh
cold cache), the sanitizer is already up and serving: its `pii_ml_client`
circuit breaker opens within 3 failed scans and Phase 7 ML stays dormant
(functional but log-noisy) until the sidecar's `/readyz` flips to 200,
while the deterministic L1+L2 layers run the whole time.

Managed container runtimes — Azure Container Apps (ACA), AWS ECS, GCP
Cloud Run — that run pii-ml as a co-located sidecar should plan for that
cold-load window. Operators deploying Phase 7 on managed runtimes should
EITHER:

- Pre-stage the HF weight cache (see `OPS.md` § "pii-ml sidecar — HF cache
  PVC", or bake the weights into a derived image) so the sidecar reaches
  `/readyz` 200 quickly and the fail-open window stays short, OR
- Disable Phase 7 entirely (`pii-ml.enabled: false` +
  `sandbox-a.sanitizer.piiranha.enabled: false` +
  `sandbox-a.sanitizer.gliner.enabled: false`) and manage Phase 7
  separately as a dedicated sidecar deployment in their runtime's
  preferred model.

### Memory requirements

The sidecar's resource limits default to `4Gi` memory + `2 CPU`. Plan
your node sizing accordingly. The sanitizer's own compose-default memory
ceiling is `4Gi` (T-210, raised from `2Gi`: idle RSS with models loaded
is already ~1.3Gi, and a real-sized Claude Code payload pushed a worker
past the 2Gi cgroup cap and got it SIGKILLed). The 6Gi box-local override
needed pre-PR #240 to fit both models in the sanitizer container is no
longer required.

### Dev / debug knob: `LUCAIRN_PII_ML_ALLOW_LAZY_NOT_READY`

`pii-ml.allowLazyNotReady: false` is the production default. Flipping it
on lets the sidecar accept gRPC scans before models finish loading (it
returns `scan_status=inference_error` per call instead of blocking OR
fail-OPEN). This is a dev-loop debug aid — NEVER set it on in
production: it disables the fail-CLOSED readyz gate that PR #240's review
round 1 locked in.

### Verifying Phase 7 is active

After deploying the chart with Phase 7 enabled, the demo prompt should
return both `piiranha_pii` AND `gliner_ner` in the sanitized response's
`layers_active` field. If either is missing, check:

- Sidecar pod logs (`kubectl logs -n dsa-identity deploy/pii-ml`) for
  model load failures.
- Sanitizer pod logs for circuit-breaker-open warnings on the pii-ml
  client.
- The Helm-rendered `sanitizer-config` ConfigMap's `piiranha.enabled` +
  `gliner.enabled` keys — they must both be `true`.

## Migration from earlier kit versions (Stage 3 env rename)

Starting with the Stage 3 gateway rebrand, the canonical env-var names for
the runtime-config keys listed below changed from `VEIL_*` to `LCR_*` (for
example, `VEIL_WITNESS_SIGNING_KEY` is now `LCR_WITNESS_SIGNING_KEY`).
`bin/lucairn-init` emits the new canonical names; `bin/lucairn doctor`
accepts either form during the deprecation window.

**The DSA gateway / sanitizer / veil-witness images built on or after the
Stage 3 rename (2026-06-02) read each setting under its `LCR_*` name first
and fall back to the legacy `VEIL_*` name when `LCR_*` is unset.** The
doctor and the kit's `docker-compose.customer.yml` BOTH apply the same
dual-name fallback, so pre-Stage-3 customer.env files keep validating and
keep booting against the new kit without modification — provided you
upgrade the kit (compose + doctor) and the images together.

### ⚠️ The fallback is ONE-DIRECTIONAL — read this before bumping an image tag

The `VEIL_*` fallback lives **inside the image**. That means it protects
exactly one direction:

| You have | Against | Result |
|---|---|---|
| Old `VEIL_*` names in customer.env / operator Secrets | A **current** image | ✅ Works — the image falls back to the legacy name. |
| New `LCR_*` names from a current kit | An **image built before 2026-06-02** | ❌ **Does not work** — that image has never heard of `LCR_*`. |

An image that predates the rename reads `VEIL_DB_URL` directly and aborts
at boot if it is unset. A rename-aware image cannot be conjured by a chart;
the fallback code has to already be in the binary.

**Measured, not assumed.** In the 2026-08-04 clean-room rehearsal,
`helm upgrade --set global.imageTag=latest` CrashLooped the `veil-witness`
pod with:

```
required environment variable VEIL_DB_URL is not set
```

That exact string is the pre-rename error message. A rename-aware image
fails with `required environment variable LCR_DB_URL (or legacy
VEIL_DB_URL) is not set` instead — so the message itself proves the
`:latest` tag was an image built before the rename.

**What the kit does about it:**

1. The Helm chart now emits **both** `LCR_DB_URL` and `VEIL_DB_URL` on the
   witness pod, from the same secret key. On a pinned image this is inert
   (envcompat takes the canonical name and never consults the legacy one).
2. `bin/lucairn doctor --values <your-values.yaml>` now warns when
   `global.imageTag` differs from the tag pinned in `image-manifest.yaml`
   — run it **before** every `helm upgrade`.

**What the kit does NOT claim.** Emitting both DB-URL names does not make
an arbitrary tag installable. A pre-rename image also requires
`VEIL_BRIDGE_PUBLIC_KEY` and `VEIL_SANITIZER_PUBLIC_KEY`, which this chart
supplies through an `envFrom` ConfigMap whose keys are `LCR_*`-named. **Only
the tags recorded in `image-manifest.yaml` are validated against this chart.
`:latest` is not one of them — do not deploy it.** Pin `global.imageTag` to
the manifest value and bump it only together with a kit release.

**You must NOT mix a new-kit compose with a customer.env that still uses
VEIL_X names AND a docker-compose override that strict-substitutes the
LCR_X names with no fallback.** If you have stacked overlays that do their
own substitution, either keep using your existing pre-Stage-3 compose
files OR apply the migration sed below so both layers agree on the
canonical LCR_X names. The optional migration recipe below is the cleanest
path forward.

### Stage 3 postgres-namespace carve-out

Two env vars KEEP the `VEIL_` prefix because they are postgres role / database
names, not Lucairn signing-key names:

- `POSTGRES_VEIL_PASSWORD` — superuser password for the `veil` postgres database.
- `VEIL_APP_PASSWORD` — password for the restricted `veil_app` SQL role created
  by `000002_restrict_veil_role.up.sql` migration.

Renaming these env vars would cascade into `scripts/render-migrations.sh`,
`charts/lucairn/charts/veil-witness/templates/migration-job.yaml`, and the
SQL migration's role-name bake-in step without architectural benefit.

### Optional migration to canonical names

The migration is OPTIONAL; the legacy fallback is supported throughout the
0.5.x release series. To migrate at your own pace, run the targeted
allow-list sed below — it renames ONLY the keys whose canonical name
changed, leaving the two postgres-namespace carve-outs alone:

```bash
# Docker-compose customers — rename ALL renameable signing/public/runtime
# keys in customer.env. (POSTGRES_VEIL_PASSWORD and VEIL_APP_PASSWORD stay.)
# Covers the full Stage-3 dual-name surface: 7 signing keys (audit/bridge/
# sanitizer/witness/gateway/manifest/sandbox-b) + 7 public keys (witness/
# bridge/sanitizer/audit/gateway/sandbox-b/gateway-manifest) + 10 runtime-
# config keys (enabled/issuer/manifest-key-id/witness-key-id/witness-signed-
# manifest-path/witness-mtls-host-dir/witness-manifest-public-key/tsa-url/
# rekor-url/dev-mode).
sed -i -E 's/^VEIL_(AUDIT|BRIDGE|SANITIZER|WITNESS|GATEWAY|MANIFEST|SANDBOX_B)_SIGNING_KEY=/LCR_\1_SIGNING_KEY=/' customer.env
sed -i -E 's/^VEIL_(WITNESS|BRIDGE|SANITIZER|AUDIT|GATEWAY|SANDBOX_B|GATEWAY_MANIFEST)_PUBLIC_KEY=/LCR_\1_PUBLIC_KEY=/' customer.env
sed -i -E 's/^VEIL_(ENABLED|ISSUER|MANIFEST_SIGNING_KEY_ID|WITNESS_KEY_ID|WITNESS_SIGNED_MANIFEST_PATH|WITNESS_MTLS_HOST_DIR|WITNESS_MANIFEST_PUBLIC_KEY|TSA_URL|REKOR_URL|DEV_MODE)=/LCR_\1=/' customer.env

# Kubernetes customers — the chart's customer-values.yaml schema is
# unchanged (chart-internal value keys are camelCase, e.g. veilSigningKey).
# The chart templates emit the renamed env-var names into pods automatically.
# A `helm upgrade` is sufficient to pick up the new env names on the next pod
# restart — no values-file changes required:
helm upgrade lucairn charts/lucairn -f customer-values.yaml -n lucairn
```

After the optional migration, run `./bin/lucairn doctor --offline` (Docker Compose) to
confirm the rename did not break any required-key check. On Kubernetes the chart
ships no test hook that validates the env rename (`helm test lucairn` only runs
the optional dashboard `/healthz` probe, and only when the dashboard subchart is
enabled) — instead re-run `helm template` / `helm upgrade` and confirm the
gateway and witness pods reach Ready, since they fail-closed at boot on a missing
required key.

## Pre-Requisites

For Docker Compose:

- Linux host with **Docker Engine 26.0.0 or newer** (25.0.5+ / 23.0.11+ on
  those lines; 24.x has no fix) and **Docker Compose v2.20.0 or newer**. Older
  engines forward DNS from `internal: true` networks (CVE-2024-29018); the
  online `bin/lucairn doctor` fails on them.

  > ⚠️ **v2.20.0 is a hard floor, not a recommendation** (raised 2026-07-28;
  > this line previously said only "Docker Compose v2"). `docker-compose.self-hosted.yml`
  > declares `depends_on.veil-witness.required: false` on `sandbox-b`, and
  > `required:` was added to the Compose Spec in v2.20.0. Older clients do **not**
  > ignore the unknown key — they refuse the file outright:
  >
  > ```
  > validating docker-compose.self-hosted.yml:
  >   services.sandbox-b.depends_on.veil-witness Additional property required is not allowed
  > ```
  >
  > Measured on v2.19.1 (fails) vs v2.20.0 and v2.20.3 (both fine). It fails
  > loudly and at config time, and it affects the **stock** full on-prem set —
  > not only the `witness-central` topology. Check with `docker compose version`
  > before installing; `lucairn doctor` does not yet enforce this floor.
- **16 GB RAM recommended** for the default topology with the L3 deep PII
  shield enabled (Phase 7 ML PII scanners **disabled by default** as of chart
  v1.7.1 — see § "Phase 7 ML PII scanners"). This covers the deterministic
  L1+L2 layers plus the sandbox-a + sanitizer + ollama-identity + gateway +
  witness + audit + id-bridge baseline **with the `qwen2.5:7b` L3 model
  resident in `ollama-identity` (~5 GB)**. **~8 GB is feasible with L3 disabled**
  (`LUCAIRN_L3_AVAILABILITY_POSTURE=degrade`, the kit default for all install
  paths): the `ollama-identity` container still runs but loads no model, so it
  idles at a few hundred MB and the L1+L2 stack fits in ~8 GB. **20 GB RAM** is required
  only when Phase 7 is explicitly re-enabled — the `pii-ml` sidecar runs
  Piiranha + GLiNER and reserves up to 4 GB for the container on top of the
  L3-on baseline. 4 vCPU is sufficient for any of these topologies at
  single-tenant pilot load.
- **Kit 2.0 (new sanitizer core): 16 GB RAM minimum** for the Docker host, on
  top of which the L3 model needs about 5 GB more when it is loaded. The core's
  model sidecar alone is capped at 6.5 GB; `bin/lucairn doctor` fails below
  15,000 MiB of Docker-engine memory. See § "Sanitizer core (kit 2.0, Compose)"
  (Helm: § "Sanitizer core (kit 2.0, Helm)").
- TLS-terminating reverse proxy such as Caddy, Nginx, Traefik, or an enterprise ingress proxy.
- Outbound HTTPS to the image registries used during `docker compose up` / `docker pull`:
  - `ghcr.io` — the 12 Lucairn `dsa-*` images are in the private `ghcr.io/declade/*` namespace (authentication required; see § "Step 0 — Registry access" above and § "Registry Authentication" below). **Lucairn must grant your GitHub account package-pull access before `docker login` will work** — see § "Step 0".
  - `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` — public base images (`postgres:16-alpine`, `redis:7-alpine`, `alpine:3.20`, `migrate/migrate:v4.17.0`, `ollama/ollama`) are pulled from Docker Hub. A host that allowlists only `ghcr.io` will pass GHCR auth but fail on these pulls. **`LUCAIRN_IMAGE_REGISTRY` does not redirect these pulls** — it only prefixes the 12 Lucairn `dsa-*` images (e.g. `dsa-gateway`, `dsa-sandbox-a`, `dsa-audit`, and the other nine `ghcr.io/declade/*` images). The base images are hardcoded in the compose files and are not registry-templated. If direct Docker Hub access is prohibited, the standard approach is to configure a **registry pull-through mirror / cache** for `registry-1.docker.io` on your infrastructure; alternatively, manually mirror the specific image tags listed above and edit the `image:` lines in the compose files.
- Outbound HTTPS to Lucairn-provided remote Sandbox B endpoint if using split deployment.
- Python 3 with the `cryptography` library (>=2.6) OR `pynacl`. Required by
  `bin/lucairn-init` and `scripts/derive-veil-pubkey.sh` for Ed25519 keypair
  generation. On Ubuntu 22.04 LTS the apt-installed `python3-cryptography`
  package (3.4.8) is sufficient: `sudo apt install python3-cryptography`.
  Newer distros come with it preinstalled. If neither package is available,
  `pip install pynacl` is the smallest alternative.
- `bin/lucairn support-bundle` uses Python 3's standard library (as
  `bin/lucairn bundle` does) to compare the raw and decoded content of the
  files it collects against every known secret; without it the bundle is
  refused.
- **Online keyed doctor additionally requires Python 3.8 or later.** Its
  shipped helper uses only the Python standard library, so it needs neither
  `cryptography` nor network/PyPI access. This requirement applies only to
  post-start `doctor --customer-key-file`; offline and values-only doctor do
  not invoke Python and remain usable on air-gapped preflight hosts.

For Kubernetes:

- Kubernetes 1.28 or newer.
- Helm 3.13 or newer.
- Ingress controller with TLS.
- **A NetworkPolicy-enforcing CNI (Calico or Cilium) for the Veil isolation
  control — a separate production control from the Helm mTLS transport gate.**
  The Veil isolation invariant (AI plane can never reach the identity plane) is
  enforced by the chart's NetworkPolicies; a CNI that does not enforce them
  (e.g. `kindnet`, the default on a stock `kind` cluster) leaves those objects
  inert. Do not infer isolation from Pod readiness or mTLS acceptance. The stock
  Kind/kindnet mTLS harness can reach Ready, but proves only mTLS transport and
  projected-leaf identity; it gives no NetworkPolicy-enforcement evidence. For
  production, operators must separately deploy and verify a
  NetworkPolicy-enforcing CNI such as Calico or Cilium before relying on Veil
  isolation; for a `kind` pilot create the cluster with `disableDefaultCNI:
  true` and install Calico. See the Helm runbook
  (`docs/CUSTOMER_HELM_RUNBOOK.md` § Prereqs) for the exact recipe. Cilium is
  preferred for DNS controls and WireGuard encryption.
- Secret manager integration, or permission to create Kubernetes native secrets.

## Registry Authentication

### Prerequisite — Lucairn-issued GHCR access

The default Lucairn images live in the private `ghcr.io/declade/*` registry.
A self-minted GitHub PAT with `read:packages` scope is NOT sufficient; the
GitHub account that owns the PAT must also have been GRANTED package-pull
access by Lucairn. Contact support@lucairn.eu with the GitHub username you
will use for the install BEFORE attempting any `docker pull` / `docker login`
step below — Lucairn provisions access typically within one business day.

If your install runs purely from a private internal registry mirror, this
prerequisite is moot — see "Mirroring images to a private registry" below.

### Login walkthrough

The Lucairn-default GHCR images (`ghcr.io/declade/dsa-*` and
`ghcr.io/declade/lucairn-dashboard`) are currently **private** — a GitHub
personal-access token (PAT) with `read:packages` scope is required to pull
them, AND the GitHub account that owns the PAT must have been granted
package-pull access per the prerequisite above. Authenticate against
ghcr.io once before running `docker compose up` or `docker pull`:

```bash
# 1. Mint a GitHub PAT (Settings → Developer settings → Personal access
#    tokens → Tokens (classic)) with the `read:packages` scope and write
#    the value to a 0600 file. Using a 0600 file (instead of pasting the
#    PAT directly into a `docker login` command) keeps the PAT out of
#    your shell history.
umask 077
cat > ~/.ghcr-token <<'EOF'
github_pat_xxxxxxxxxxxxxxxxxxxxxxxxx
EOF
chmod 600 ~/.ghcr-token   # belt-and-suspenders

# 2. Log Docker into ghcr.io via stdin from the file.
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
```

The login cookie persists in `~/.docker/config.json` until you `docker
logout ghcr.io` or the PAT expires. Customers running on an air-gapped
host or behind a private mirror that uses different credentials should
`docker login` against the mirror instead and set `LUCAIRN_IMAGE_REGISTRY`
in `customer.env` to the mirror prefix.

Lucairn does NOT provision per-customer GHCR credentials at handoff time
— the customer's own GitHub account or service-account PAT is sufficient.
If your organization blocks GitHub access entirely, request a sealed
customer bundle (with `images/lucairn-images.tar` for `docker load`); see
`docs/CUSTOMER_BUNDLE.md`.

### Verify image signatures (supply-chain provenance)

Every published Lucairn image is cosign-signed (by digest) and logged to the
Sigstore Rekor public transparency log. Before deploying **and before every
upgrade** (see OPS.md § "Upgrade", step 3 — verification is a mandatory step
in the documented upgrade runbook, not optional), verify the release image
set against the kit-bundled public key (`keys/lucairn-cosign.pub`) and the
per-release signed-digest record (`keys/image-digests-<tag>.txt`).
**Coverage is not uniform — read this before treating a PASS as
"everything":** the 12 `dsa-*` services are fully verified at your chosen
`--tag`; `lucairn-dashboard` is verified ONLY at its hardcoded pinned
default tag (currently `0.8.2`) — if you have overridden
`LUCAIRN_DASHBOARD_IMAGE_TAG`, a PASS says nothing about the tag you
actually deploy; **`dsa-pii-ml`** (the Phase 7 ML PII sidecar) has no digest
record in this kit at all and is never checked, at any tag or option — it
ships on an independent cadence. See OPS.md § "Verify image signatures" for
the full breakdown. You need `cosign` (>= v2.0) and a digest resolver
(`docker buildx`, `crane`, or `skopeo`) on PATH:

```bash
bin/lucairn verify-images --tag 0.5.5
# or a single image, by its signed digest (from keys/image-digests-0.5.5.txt):
cosign verify --key keys/lucairn-cosign.pub \
  ghcr.io/declade/dsa-gateway@sha256:<digest-from-the-record-file>
```

`verify-images` fails if any tag was re-pointed away from its signed digest, so
a verified set is bound to the exact bytes Lucairn signed. See
**OPS.md → "Verify image signatures"** for the full recipe (including how to
pin cosign itself by checksum) and the key-custody model.

#### Fetch the SBOM (Software Bill of Materials)

Each published image also ships a per-image **SPDX-JSON SBOM**, attached as a
cosign-signed SPDX attestation logged to the Sigstore Rekor public transparency
log (signed by the same Image Signing Key — no extra key or vendor). Fetch +
verify it, and inspect exactly what is in each image:

```bash
bin/lucairn sbom ghcr.io/declade/dsa-gateway:0.5.5
# save the raw verified SBOM:
bin/lucairn sbom ghcr.io/declade/dsa-gateway:0.5.5 --download dsa-gateway-0.5.5.spdx.json
# or with raw cosign:
cosign verify-attestation --type spdxjson \
  --key keys/lucairn-cosign.pub ghcr.io/declade/dsa-gateway:0.5.5
```

See **OPS.md → "Fetch + verify the Software Bill of Materials (SBOM)"** for the
full recipe.

## Choose A Deployment Mode

Before running `docker compose up`, decide which inference-side topology the
deployment uses. The two modes differ in whether Sandbox B (the
inference-isolation boundary that calls the LLM upstream) runs on the
customer's own host or on Lucairn-hosted infrastructure.

| Mode | Sandbox B runs on | Compose overlays | Required Lucairn-provisioned values | Outbound network from customer host |
|---|---|---|---|---|
| **Self-hosted inference (local model)** | Customer's host (local container plus model runtime) | `docker-compose.customer.yml` plus `docker-compose.self-hosted.yml` | `DSA_LICENSE_KEY`, `DSA_LICENSE_SIGNING_KEY` only | None to Lucairn at request time. Model runtime fetched once at install. |
| **Self-hosted inference (managed LLM / BYOK)** | Customer's host (local container; LLM call goes out to operator-declared FQDNs) | `docker-compose.customer.yml` plus `docker-compose.self-hosted.yml` plus `docker-compose.self-hosted-byok.yml` | Same as self-hosted local-model **plus** `LUCAIRN_LLM_EGRESS_ALLOWLIST` and provider key(s) (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …) | HTTPS to operator-declared LLM FQDNs only. Sandbox A / ID Bridge / Sanitizer / Audit / Witness stay on internal-only networks. |
| **Split deployment** | Lucairn-hosted | `docker-compose.customer.yml` only | All of the self-hosted list **plus** a Lucairn-issued `--remote-credentials` file (one remote API key + 64-hex remote public key), `SANDBOX_B_REMOTE_ENDPOINT`, optional mTLS material (`SANDBOX_B_CLIENT_CERT` etc.) | HTTPS to Lucairn-provided endpoint per request. Endpoint and license alone are not usable. |

Pick **self-hosted inference (local model)** when:

- Compliance forbids per-request egress to *any* external endpoint.
- The customer wants a fully on-premise deploy (sandbox / proof-of-value /
  air-gapped or DMZ-only network) and owns GPU/CPU model runtime
  operations.
- Development, simulation, or acceptance-test environments. The
  `docker-compose.self-hosted.yml` overlay is always the right starting point
  on a laptop or single-host VM.

Pick **self-hosted inference (managed LLM / BYOK)** when:

- The customer wants Sandbox A / Sanitizer / ID Bridge / Audit / Witness to
  run on-premise (so identity data never leaves their network), but is OK
  with the LLM call itself going to a managed cloud provider (Anthropic,
  OpenAI, Mistral, Gemini, Azure OpenAI, AWS Bedrock, internal LLM
  gateway).
- The compliance team will enforce the FQDN allowlist at their existing
  network policy layer (host firewall + DNS allowlist, Cilium
  NetworkPolicy with `toFQDNs:`, or a transparent forward proxy). See the
  "Self-hosted with managed LLM (BYOK)" section below for the
  responsibility split between the kit and the operator.

Pick **split deployment** when:

- Production traffic and the customer has signed the standard Lucairn
  inference-tenancy contract that provides the remote Sandbox B endpoint.
- The customer does not want to own model runtime operations (GPU
  procurement, model updates, weight licensing) or manage their own
  upstream-LLM contracts.

If neither column matches the customer's profile, contact Lucairn before
proceeding. Mixing modes is not supported.

`lucairn-init` requires an explicit `--runtime-mode`: `split-remote` (also
accepted as `split/remote`, with `--remote-endpoint https://...` **and**
`--remote-credentials /secure/lucairn-issued-remote-credentials.env`),
`managed-byok`, or `local-runtime --local-runtime <name>`. It writes the
non-secret canonical state files beside the env file as
`customer.env.runtime-profile.yaml` and
`customer.env.image-manifest.yaml`; the profile records the mode, ordered
overlays, and a hash-bound init-time image-manifest snapshot. A
fresh local-runtime inventory is `operator-declared` and
`required-not-verified`: it names the required path but does not claim that a
model file has been supplied or checked.
`doctor`, support bundles, backup, and restore consume this state. Existing
installations without the file remain supported as legacy installs. To adopt
one, run init with the exact matching explicit mode and
`--adopt-runtime-profile`; it preserves every existing setting and secret,
then atomically adds only `LUCAIRN_RUNTIME_PROFILE_REQUIRED=1` together with
the sidecar. Mismatches fail before mutation.

For an S1-generated install, both sidecars are required beside `customer.env`.
If its runtime marker remains in the env but either the profile or recorded
image-manifest snapshot is deleted, replaced, malformed, or symlinked, the
tools fail closed instead of guessing an overlay set or using the mutable kit
manifest. Only a genuinely pre-S1 env
with no profile marker follows the legacy path, and it remains legacy until an
operator explicitly adopts it.

### Recorded Compose lifecycle (S1)

For an S1 install, do not reconstruct `docker compose -f` arguments manually.
Use the profile-bound wrappers, each with `--env customer.env` and optionally
`--compose /path/to/docker-compose.customer.yml` when the base file is not in
the kit root:

```bash
bin/lucairn up --env customer.env         # registry migration first, then up -d
bin/lucairn status --env customer.env
bin/lucairn logs --env customer.env --tail 200 --service gateway
bin/lucairn pull --env customer.env       # profile-bound upgrade fetch
bin/lucairn down --env customer.env       # never removes volumes
```

`bin/lucairn up` first runs the sanitizer core's capped registry migration
(`migrate-sanitizer-core`, § "Sanitizer core (kit 2.0, Compose)" step 3) — a
no-op when the registry is at this release's ceiling — and starts nothing if
it fails. A plain `docker compose ... up -d` does not run it.

They fail before Docker for missing or invalid marker-bearing state. Pre-S1
state retains its documented one-base-file legacy path. Exact release rollback,
rollback history, and restore proof are WP4 S4 scope and are not provided by S1.

Before minting your first customer, complete the witness mTLS bootstrap in
§ "Witness mTLS" below (`scripts/bootstrap-mtls-ca.sh`). As of the T-12
witness image, certificate reads on `:50058` — including `bin/lucairn
doctor`'s certificate-receipt check — refuse every caller until you do.

### Init lock recovery

`lucairn-init` serializes writes in `.lucairn-init.lock` beside the selected
output. A live recorded owner is never displaced. After a host crash, a lock
whose recorded PID is provably dead is recovered automatically; a missing or
corrupt owner is retained for a 30-second grace period before recovery to
protect the short creator crash gap. A symlink or non-directory lock is unsafe
and fails closed. If recovery reports a still-live owner, wait for that init
run rather than deleting the lock manually.

For a new split deployment, use `lucairn-init --runtime-mode split-remote
--remote-endpoint https://... --remote-credentials <Lucairn-issued-file>`;
endpoint plus a license is not sufficient. The credential file has exactly
`sandbox_b_api_key=<opaque key>` and `sandbox_b_public_key=<64 hex>` lines;
the remote Sandbox B signing seed remains on Lucairn infrastructure. Do not start by copying only
`customer.env.example`, which creates an implicit legacy install. The bare
template remains only for the clearly labeled advanced/pre-S1 manual path
below. To adopt such an existing env without rewriting secrets, use the exact
matching explicit mode with `--adopt-runtime-profile`.

For local-runtime, init records the operator-declared model name, file, and
path. It does not claim the model is present or usable. When preparing a
bundle, those fields must agree with `models/model-manifest.yaml` and the
canonical bundle `MODEL_PATH` is `.` (the delivered `models/` tree mounts at
`/models`); direct non-bundle installs may use another safe relative path. The bundle
preparation gate performs the later model-manifest/file validation. Model names
use 1–128 ASCII characters matching `[A-Za-z0-9][A-Za-z0-9._:-]*`; model files
use the stricter single-basename grammar
`[A-Za-z0-9][A-Za-z0-9._-]*` (no slashes, absolute paths, `.`/`..`, or
symlinks). The bundle reader rejects duplicate or unknown manifest structure.

### Deployment license (Enterprise features)

The gateway enforces a self-hosted deployment entitlement license that gates
Enterprise-only features (e.g. the custom-trained L3 PII shield) with a
grace-then-degrade expiry. It is verified entirely offline (no phone-home), so
air-gapped installs work. Lucairn issues you two values:

- `LUCAIRN_LICENSE_KEY` — the signed license token.
- `LUCAIRN_LICENSE_PUBLIC_KEY` — the verification public key.

`bin/lucairn-init --production --runtime-mode <mode> --license <bundle>`
populates both automatically when you include the mode-compatible required
flags and carry them in the license bundle (see below); otherwise set them in `customer.env`
(Compose) or under `gateway.secrets.values` (Helm — see
`customer-values.yaml.example`). Leave them EMPTY for sandbox/dev: in
`DSA_ENV=development` the gateway warns-not-enforces; in production an empty
license runs in unregistered mode (Enterprise features locked, **core PII
pipeline still runs**). After expiry, a 14-day grace window
(`LUCAIRN_LICENSE_GRACE_DAYS`) keeps everything working with loud warnings
before Enterprise features degrade. The core compliance pipeline is never
broken over licensing. See OPS.md → "Deployment license" for status checks +
renewal.

> **Caveat — anti-tamper is pin-gated; the env vars alone do not enforce it.**
> The two env vars above always drive Enterprise **feature-gating** (the
> grace-then-degrade lifecycle) on any image — that is the stock behavior. The
> hardened **anti-tamper coupling** (fail-closed boot on a missing/forged
> entitlement; `POST /api/v1/register` disabled → `403 registration_disabled`;
> `DSA_ENV=development` bypass closed; key↔entitlement `customer_id` coupling →
> `403 entitlement_mismatch`) is a single switch that is active **only** on a
> **pin-baked release gateway image** — one Lucairn built with the Ed25519
> public key baked into the binary's `PinnedPublicKeyHex` via `-ldflags -X`.
> **Stock / committed / GHCR images ship `PinnedPublicKeyHex=""` and are fully
> INERT for anti-tamper:** setting `LUCAIRN_LICENSE_KEY` +
> `LUCAIRN_LICENSE_PUBLIC_KEY` on a stock image gives you feature-gating but
> **no** anti-tamper effect. The pin-baked image is built by Lucairn (the
> operator); a self-building customer needs the gateway Dockerfile's
> `ARG LUCAIRN_LICENSE_PUBLIC_KEY_HEX` (in dual-sandbox-architecture) and should
> contact Lucairn for the pin-bake build recipe.

#### Combined `--license` bundle (HMAC + Ed25519 entitlement)

The `--license` file passed to a production init run can carry **both**
licenses in one bundle. Production init also requires an explicit
`--runtime-mode` plus its compatible required flags. Four fields:

```json
{
  "license_key":            "<HMAC platform-tier license>   (REQUIRED)",
  "signing_key":            "<HMAC platform-tier signing key> (REQUIRED)",
  "entitlement_token":      "<Ed25519 deployment entitlement token> (OPTIONAL)",
  "entitlement_public_key": "<Ed25519 verification public key, hex64> (OPTIONAL)"
}
```

(An `entitlement_grace_days` integer field is also accepted; it overrides the
default 14-day grace.) The line-based form is equivalent:
`license_key=…` / `signing_key=…` / `entitlement_token=…` /
`entitlement_public_key=…`, one per line.

`bin/lucairn-init --production --runtime-mode <mode> --license <bundle>`
(with mode-compatible required flags) writes `DSA_LICENSE_KEY` +
`DSA_LICENSE_SIGNING_KEY` from the first two fields **and** `LUCAIRN_LICENSE_KEY`
+ `LUCAIRN_LICENSE_PUBLIC_KEY` (+ `LUCAIRN_LICENSE_GRACE_DAYS`) from the
entitlement fields. A bundle that carries only `license_key` + `signing_key`
still works — the entitlement vars stay empty (unregistered/INERT). `bin/lucairn
doctor` emits an `entitlement:` line and **warns** (does not fail) if exactly one
of `LUCAIRN_LICENSE_KEY` / `LUCAIRN_LICENSE_PUBLIC_KEY` is set.

> Lucairn-side (issuing the deployment entitlement): `bin/lucairn license issue --license-id … --customer-id … --customer-name … --valid-until YYYY-MM-DD --features l3_custom_shield --signing-key-hex <seed>`. The private signing seed stays in the Lucairn vault and never ships to the customer. The resulting token becomes `entitlement_token` in the bundle (→ `LUCAIRN_LICENSE_KEY`); the matching public key (from `bin/lucairn license gen-key`) becomes `entitlement_public_key` (→ `LUCAIRN_LICENSE_PUBLIC_KEY`).
>
> `license issue` / `verify` / `gen-key` shell out to the DSA `license-sign` tool (so the signed bytes match the gateway verifier). Set **`LUCAIRN_LICENSE_SIGN_BIN`** to point at a prebuilt `license-sign` binary; otherwise the wrapper uses `license-sign` on `PATH`, then `go run` from `DSA_REPO` (the dual-sandbox-architecture clone). With none of the three available the command fails cleanly (exit 1) with an actionable pointer.
>
> **`--customer-id` auto-fill:** the entitlement is coupled to the customer's gateway keystore `customer_id` — a mismatch returns `403 entitlement_mismatch`. If you mint the customer with `bin/lucairn-mint-customer` first, the derived `customer_id` is persisted to a kit-local `.lucairn-customer-id` file (mode 0600), and `bin/lucairn license issue` auto-fills `--customer-id` from it when you do not pass one explicitly. An explicit `--customer-id` always wins. (Single-customer / last-write-wins: a new mint overwrites the recorded id.)

## Advanced / pre-S1 manual Docker Compose install

New installs must use the explicit `lucairn-init` flow above so that
`customer.env.runtime-profile.yaml` and `customer.env.image-manifest.yaml` are
created beside `customer.env`. This
manual template path is retained only for a pre-S1 installation or a deliberate
manual ceremony. It is a legacy install until the operator adopts an explicit,
matching profile with `--adopt-runtime-profile`.

1. Unpack the release bundle.

```bash
tar -xzf lucairn-enterprise-deployment-kit-1.9.7.tar.gz
cd lucairn-enterprise-deployment-kit
```

2. Create the customer env file.

```bash
cp customer.env.example customer.env
chmod 600 customer.env
```

3. Authenticate against the image registry.

The Lucairn-default GHCR images are private. Lucairn must first grant your
GitHub account package-pull access — see § "Registry Authentication"
above for the prerequisite contact-flow and the full PAT-based login
walkthrough. The short version (read the PAT from a 0600 file so it
never appears in your shell history):

```bash
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
```

If the customer uses an internal registry mirror, `docker login` against
the mirror credentials instead and set `LUCAIRN_IMAGE_REGISTRY` in
`customer.env` to the mirror prefix.

4. Replace every `REPLACE_*` value in `customer.env`.

Generate random values:

```bash
openssl rand -hex 32       # 32-byte random as 64 hex chars (signing keys, tokens)
openssl rand -base64 32    # 32-byte random as base64           (GATEWAY_KEYSTORE_KEY)
```

**WARNING — DO NOT use `openssl rand -hex 32` for `LCR_*_PUBLIC_KEY` slots.**
The public key MUST be derived from the corresponding private key (the
`LCR_*_SIGNING_KEY` of the same service). Filling the public-key slots
with independently-generated random hex yields a key that does NOT match
the signing key, and every certificate claim the service signs will be silently
rejected by the witness verifier — the stack will look healthy but no
certificates will validate.

### 4a. Generate Ed25519 signing keypairs

Operator-generated keypairs (always required). All slots use the canonical
`LCR_*` prefix as of Stage 3; pre-Stage-3 customer.env files using the
legacy `VEIL_*` prefix continue to work (see § Migration above).

| Signing-key slot              | Public-key slot              |
|-------------------------------|------------------------------|
| `LCR_AUDIT_SIGNING_KEY`       | `LCR_AUDIT_PUBLIC_KEY`       |
| `LCR_BRIDGE_SIGNING_KEY`      | `LCR_BRIDGE_PUBLIC_KEY`      |
| `LCR_SANITIZER_SIGNING_KEY`   | `LCR_SANITIZER_PUBLIC_KEY`   |
| `LCR_WITNESS_SIGNING_KEY`     | `LCR_WITNESS_PUBLIC_KEY`     |
| `LCR_GATEWAY_SIGNING_KEY`     | `LCR_GATEWAY_PUBLIC_KEY`     |

For self-hosted-inference modes (`docker-compose.self-hosted.yml` or
the BYOK overlay), also generate the Sandbox B pair locally — sandbox-b
runs on the customer host in those modes, signs `CLAIM_TYPE_INFERENCE_GENERATED`
with `LCR_SANDBOX_B_SIGNING_KEY` at boot, and the witness verifies
those claims against `LCR_SANDBOX_B_PUBLIC_KEY`:

| Signing-key slot              | Public-key slot              | Modes        |
|-------------------------------|------------------------------|--------------|
| `LCR_SANDBOX_B_SIGNING_KEY`  | `LCR_SANDBOX_B_PUBLIC_KEY`  | self-hosted (local model or BYOK) |

In **split deployment** the Sandbox B signing key lives on the
Lucairn-hosted Sandbox B fleet; Lucairn issues the matching public key
during onboarding. Do not regenerate `LCR_SANDBOX_B_PUBLIC_KEY` in
split-deployment mode — use whatever value Lucairn provides.

For each pair generate the signing-key seed with `openssl rand -hex 32`,
then derive the matching public key using the bundled helper at
`scripts/derive-veil-pubkey.sh`. Bash one-liner — fills both slots for
one service in two lines of output you can paste into `customer.env`:

```bash
SEED=$(openssl rand -hex 32)
echo "LCR_AUDIT_SIGNING_KEY=$SEED"
echo "LCR_AUDIT_PUBLIC_KEY=$(printf '%s' "$SEED" | scripts/derive-veil-pubkey.sh)"
```

Repeat for `BRIDGE`, `SANITIZER`, `WITNESS`, `GATEWAY`, and (for
self-hosted modes) `SANDBOX_B`.

`LCR_MANIFEST_SIGNING_KEY` (no matching `_PUBLIC_KEY` slot) is the
manifest-only signing key and only needs the `openssl rand -hex 32`
step.

The helper requires Python 3 with the `cryptography` package (preferred)
or `pynacl`. Both are pure-Python wheels; install with
`pip install cryptography` if either is missing.

### 4a-bis. Generate the opaque service secrets (hex32)

These are not signing keypairs — they are opaque shared secrets and HMAC keys.
Generate each independently with `openssl rand -hex 32` (no derivation step):

| Secret slot                  | Generate with        | Notes |
|------------------------------|----------------------|-------|
| `DSA_SERVICE_TOKEN`          | `openssl rand -hex 32` | Inter-service auth token. |
| `DSA_BRIDGE_ENCRYPTION_KEY`  | `openssl rand -hex 32` | id-bridge payload encryption. |
| `SANDBOX_A_ENCRYPTION_KEY`   | `openssl rand -hex 32` | sandbox-a at-rest encryption. |
| `BRIDGE_MASTER_KEY`          | `openssl rand -hex 32` | id-bridge master key. |
| `DSA_ADMIN_KEY`              | `openssl rand -hex 32` | Gateway admin bearer (mint/admin APIs). |
| `CANARY_HMAC_KEY`            | `openssl rand -hex 32` | **Required for `DSA_ENV=production`.** The sanitizer signs its canary-token tripwires with this HMAC key and **refuses to boot without it** when `DSA_ENV=production`. `bin/lucairn-init` auto-generates it, so an init-driven install is fine; a **manual-path** customer filling `customer.env` by hand MUST set it or the sanitizer crash-loops at boot. |

`GATEWAY_KEYSTORE_KEY` is the exception: generate it as base64-32-bytes
(`openssl rand -base64 32`), not hex — `bin/lucairn doctor` decodes it and
checks the byte count is exactly 32.

### 4b. Produce the witness-signed manifest (production only)

> **Production-only — skip in dev mode.** This step is required ONLY when you
> install with `DSA_ENV=production`. A `DSA_ENV=development` install does NOT
> need the blob: the gateway tolerates its absence and falls back to the legacy
> single-sig path. `bin/lucairn doctor` enforces this asymmetry — it FAILS a
> production install whose manifest blob is missing, and SKIPS the check in dev.

When `DSA_ENV=production`, the gateway **`log.Fatal`s at boot** if the
witness-signed manifest blob is missing or unreadable. The blob — a base64-encoded,
witness-signed copy of the published `/.well-known/veil-keys.json` key roster —
must exist at `LCR_WITNESS_SIGNED_MANIFEST_PATH` (kit default
`/certs/witness-signed-manifest.json`) **before first production boot**, or the
stack boot-loops rather than starts.

The blob is produced at your **key-ceremony host** (the machine holding the
witness signing seed) with the `sign-manifest` tool. The full ceremony —
assembling the `keys.json` roster from your derived public keys, issuer, and
protocol versions — is documented in **OPS.md § "witness-signed manifest"** and
the **Key Ceremony Runbook** (`docs/KEY_CEREMONY_RUNBOOK.md` § 6 "Producing the
witness-signed manifest blob"). The invocation is:

The `sign-manifest` tool ships **inside the pinned
`dsa-veil-witness:0.5.5@sha256:2314d971d0cbccdbb63e6d5547a93c82ed634f8cafb0d5fd0bc55d6957d4f5ac`
image** (`/usr/local/bin/sign-manifest`), so the ceremony is turnkey on the
ceremony host — no Go toolchain, no build-from-source, no dev-mode fallback.
Use this canonical command; it keeps the witness seed out of the host Docker
argv and process list:

```bash
# On the ceremony host, with the witness seed available. keys.json is the
# per-service key roster (service_id / key_id / public_key / purpose /
# algorithm / key_state — the shape the gateway's buildPublicKeyManifest emits).
# The private temporary seed file is mounted read-only and removed on every
# exit. The single-quoted in-container command expands it only inside /bin/sh.
umask 077
seed_file="$(mktemp "${TMPDIR:-/tmp}/lucairn-witness-signing-key.XXXXXX")"
chmod 0600 "$seed_file"
trap 'rm -f "$seed_file"' EXIT HUP INT TERM
printf '%s' "$LCR_WITNESS_SIGNING_KEY" > "$seed_file"
docker run --rm \
  --entrypoint /bin/sh \
  -v "$PWD/keys.json:/keys.json:ro" \
  -v "$seed_file:/run/secrets/witness-signing-key-hex:ro" \
  ghcr.io/declade/dsa-veil-witness:0.5.5@sha256:2314d971d0cbccdbb63e6d5547a93c82ed634f8cafb0d5fd0bc55d6957d4f5ac \
  -ec 'exec sign-manifest --keys-json /keys.json --issuer "$1" --witness-signing-key-hex "$(cat /run/secrets/witness-signing-key-hex)" --witness-key-id witness_manifest_v1' \
  sign-manifest "$LCR_ISSUER" \
  > witness-signed-manifest.json

# Then mount/copy witness-signed-manifest.json to the gateway host at the path
# in LCR_WITNESS_SIGNED_MANIFEST_PATH (Compose: bind-mount into /certs/;
# Helm: the chart mounts gateway.secrets — see OPS.md).
```

> **Flags** (run `docker run --rm --entrypoint sign-manifest
> ghcr.io/declade/dsa-veil-witness:0.5.5@sha256:2314d971d0cbccdbb63e6d5547a93c82ed634f8cafb0d5fd0bc55d6957d4f5ac -h`
> to confirm against your pin):
> `--keys-json` (required), `--issuer` (required; matches `LCR_ISSUER` / legacy
> `VEIL_ISSUER` at the gateway), `--witness-signing-key-hex` (required; the
> Ed25519 witness seed, hex 32 bytes), `--witness-key-id` (default
> `witness_manifest_v1`), `--version` (default `1`), `--protocol-versions`
> (default `1,2`), `--signed-at` (RFC3339; empty uses current UTC). The witness
> seed is read from the private read-only mount only by the in-container shell;
> it never appears in host Docker argv or leaves that machine. Keep `bin/lucairn doctor`'s `check_manifest_blob`
> pre-flight (it FAILS a production install whose manifest blob is missing) as
> the gate that this step ran before first production boot.
>
> **(Was a known limitation through 0.5.1: `sign-manifest` was not shipped in
> the image and had to be built from source on the ceremony host, or the install
> run in dev mode. The 0.5.2 `dsa-veil-witness` image shipped the tool — the
> `docker run` path above replaces both workarounds. Closes BLOCKER-3.)**

5. Run offline validation before network checks.

```bash
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
```

6. Start the stack. The online full doctor is a post-start customer-path
validation: mint a customer key into an existing regular mode-0600 file and
run it only after health and readiness. For `split-remote` and
`managed-byok`, include `--model <selected-model>`; local-runtime uses its
recorded model and must not receive `--model`. It requires Python 3.8+; if it
is unavailable, online doctor fails closed with its prerequisite message while
the offline preflight remains available.

For **split deployment** (`bin/lucairn up --env customer.env` does both steps):

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env \
  --profile sanitizer-core-migrate run --rm migrate-sanitizer-core
docker compose -f docker-compose.customer.yml --env-file customer.env up -d
```

> **Default path: no pii-ml dependency.** As of chart v1.7.1 the Phase 7 ML
> PII sidecar (`pii-ml`) is **disabled by default** and is gated behind the
> `phase7` Compose profile, so a plain `up -d` does NOT start it and the
> `sanitizer` service has **no `pii-ml` dependency** — it starts independently
> and `/readyz` returns 200 in seconds. The deterministic L1+L2 layers run
> regardless. See § "Phase 7 ML PII scanners" to re-enable.
>
> **First-boot pii-ml delay (only with `--profile phase7`).** When you bring
> the stack up with the `phase7` profile active, the `pii-ml` sidecar deploys
> and downloads ~1.6GB of HuggingFace model weights on first cold-cache boot.
> On the Compose path the sanitizer does **NOT** block on the sidecar at
> startup — it has no `depends_on: pii-ml` (see `docker-compose.customer.yml`,
> the `sanitizer` service depends only on `sandbox-a`), so the sanitizer
> starts independently in seconds and dials `pii-ml` lazily at request time
> (and only when the sanitizer-side `piiranha`/`gliner` flags are also
> enabled). Expect the sidecar's own `/readyz` to take **3-8 minutes** to
> return 200 the FIRST time you run `--profile phase7 up -d`; during that
> window the sanitizer is **not** stuck or unhealthy — Phase 7 scans
> fail-OPEN (circuit-open degrade) and the deterministic L1+L2 layers still
> run, so PII is still redacted and certs are still anchored. Subsequent
> restarts hit the named volume cache and the sidecar loads in seconds.
> Stream the load progress with `docker compose --profile phase7 logs -f
> pii-ml`; see TROUBLESHOOTING.md § "pii-ml Sidecar Slow to Become Ready
> After Enabling Phase 7" if the load stalls.

For **self-hosted inference**, load the self-hosted overlay so the local
Sandbox B container + model runtime profile come up alongside the customer
stack (`bin/lucairn up --env customer.env` does both steps; with plain Compose,
migrate first — the sanitizer core refuses to start on an unmigrated registry):

```bash
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  --env-file customer.env \
  --profile sanitizer-core-migrate \
  run --rm migrate-sanitizer-core
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  --env-file customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" \
  up -d
```

If you omit the self-hosted overlay on a self-hosted-inference install, the
gateway will start but `/readyz` will return 503 because the placeholder
`SANDBOX_B_REMOTE_ENDPOINT=https://inference.lucairn.example` is unreachable.
See `TROUBLESHOOTING.md` § "`/healthz` Returns 200 But `/readyz` Returns 503".

**Pre-stage the L3 deep PII-shield model.** The self-hosted overlay runs a
dedicated, always-on `ollama-identity` container for the sanitizer's level-3
deep PII shield (`qwen2.5:7b`, matching `config/default-sanitizer.yaml`'s
`model:`). It lives on its own identity-only network (the sanitizer reaches it
via the `ollama` network alias) and is isolated from the AI-plane inference
runtime to preserve the split-knowledge invariant. That network is
`internal: true` — it has **no egress** — so `ollama-identity` itself cannot
reach the model registry, and `docker compose exec ollama-identity ollama pull`
would run the pull *inside* that egress-less network namespace and fail.

Stage the model once, air-gap-preserving: bring the stack up (which creates the
identity model-store volume), then run a **throwaway** egress-enabled ollama
container that writes the model into that same named volume. The always-on
`ollama-identity` then serves the cached model with no egress of its own.

```bash
# 1. Find the identity model-store volume (created when the stack first came up):
docker volume ls -q | grep ollama-identity-model-store

# 2. Stage qwen2.5:7b into it via a one-time throwaway ollama that DOES have
#    egress (the running ollama-identity is on an internal-only net and cannot
#    pull). The ollama image's entrypoint is `ollama`, so override it to run a
#    shell. Use the recorded, digest-pinned image (image-manifest.yaml →
#    pii_plane.ollama-identity):
docker run --rm --entrypoint sh \
  -v <ollama-identity-model-store-volume-name>:/root/.ollama \
  ollama/ollama:0.6.2@sha256:74a0929e1e082a09e4fdeef8594b8f4537f661366a04080e600c90ea9f712721 \
  -c 'ollama serve >/dev/null 2>&1 & sleep 5 && ollama pull qwen2.5:7b'

# 3. Restart ollama-identity so it loads the freshly staged model from the volume:
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  --env-file customer.env \
  restart ollama-identity
```

The running `ollama-identity` keeps **no egress** (`internal: true`); only the
one-time throwaway staging container in step 2 has egress, and it exits as soon
as the pull completes. This procedure is validated on a fresh install.

**Out-of-the-box default — continue-mode (L1+L2 only), honest certificate.**
Both `lucairn-init` and the bare `customer.env.example` (manual
`cp customer.env.example customer.env` path) set
`LUCAIRN_L3_AVAILABILITY_POSTURE=degrade` for every deployment path. With this
default the stack runs continue-mode: the sanitizer applies the
L1 (deterministic regex/dictionary) + L2 (sandbox-a) PII layers, the L3 shield
is treated as optional, and the verification certificate is downgraded to
**`COMPLETENESS_PARTIAL`** (the witness omits `llm_pii_scan` from
`layers_active`). The gateway does **not** return `503 l3_scrubber_unavailable`
— requests complete immediately even though the `qwen2.5:7b` model has not yet
been staged.

The pre-stage procedure above is the **optional** path to **re-enable L3
fail-closed** mode. To activate it after staging the model:

1. Complete the throwaway-pull staging procedure above.
2. Set `LUCAIRN_L3_AVAILABILITY_POSTURE=reject` in `customer.env`.
3. Restart the stack (`docker compose … up -d`).

With `LUCAIRN_L3_AVAILABILITY_POSTURE=reject` the sanitizer is fail-CLOSED: the
gateway returns `503 l3_scrubber_unavailable` if the L3 shield is unreachable
rather than degrading to L1+L2 silently. The certificate completeness becomes
`COMPLETENESS_FULL` once the model is loaded and all four claim layers are
active. Provision the full 16 GB RAM before enabling this mode (see
§ Pre-Requisites).

> **What `COMPLETENESS_FULL` certifies:** the L3 (AI-based) scan covered
> everything it is required to cover — every text segment subject to L3
> scanning received an L3 verdict. Content that is exempt from L3 by design
> (code blocks handled by the dedicated shallow scanners, platform-trusted
> fields, and empty fields) is covered by its own scanning layers and does
> not need an L3 verdict for FULL. Identical values can reuse a single
> verdict instead of being rescanned, through two separate mechanisms —
> within a request via duplicate-leaf dedupe, and across requests via the
> sanitize cache (`SANITIZE_CACHE_ENABLED`). Both are version-scoped: this
> kit pins sanitizer `0.5.5` (`image-manifest.yaml`), built from DSA main
> `f70d0fe8` or later, whose source carries both within-request dedupe
> (T-546) and the fix that makes cache-replay reuse fully reflected in
> certificate coverage (T-409). Sanitizer `0.5.4` and older predate both; on
> those, enabling `SANITIZE_CACHE_ENABLED` is not recommended. That is a
> coverage guarantee, not a per-byte-freshly-scanned guarantee.

> **`LUCAIRN_L3_REQUIRED` IS RETIRED — it is now two independent flags, and
> they do NOT have to agree (board T-393 / T-385).**
>
> The retired flag welded together two unrelated questions that are answered by
> two different services, so no single value could express the combination most
> installs actually want. Each question now has its own flag:
>
> | Question | Service | Flag | Values | Default |
> |---|---|---|---|---|
> | What happens to a **request** when L3 is unavailable? | sanitizer | `LUCAIRN_L3_AVAILABILITY_POSTURE` | `degrade` \| `reject` | `degrade` |
> | What does the **certificate** claim when L3 did not run? | veil-witness | `LUCAIRN_L3_COMPLETENESS_POSTURE` | `partial` (only on Helm — see below) | `partial` |
>
> Neither service reads the other's flag, and neither can downgrade the other's
> answer, so there is no "both sides must agree" rule any more — that rule was
> the retired flag's defect, not a property of the system.
>
> **⚑ On HELM, certificates change from `COMPLETENESS_FULL` to
> `COMPLETENESS_PARTIAL` on upgrade, on purpose.** Nothing about the scrubbing
> changed. The chart shipped `global.l3Required: false` and rendered it onto the
> veil-witness pod, so Helm installs certified `COMPLETENESS_FULL` for requests
> the deep PII shield never saw. The certificate now states which layers
> actually ran.
>
> **⛔ `LUCAIRN_L3_COMPLETENESS_POSTURE=full` is not available on Helm (board
> T-385, 2026-08-04).** It was briefly offered as an explicit opt-in to
> reproduce the old over-claiming wording; the kit no longer offers it, on
> principle — a signed certificate must never be configurable to state that a
> scan ran when it did not. `helm template --set
> global.l3CompletenessPosture=full` now fails the render. The veil-witness
> image's own parsing of `full` is untouched (a separate, not-yet-scheduled
> retirement), so setting the raw `LUCAIRN_L3_COMPLETENESS_POSTURE=full`
> environment variable directly on a non-Helm path is not itself blocked by
> this change — but the kit no longer documents or offers that as a supported
> path on any install method. The only way to earn a FULL certificate is to
> actually run the L3 shield.
>
> **Compose installs are unaffected on this point** — the Compose files never
> set the variable on the `veil-witness` service, only on the sanitizer, so the
> witness already downgraded and those certificates already read
> `COMPLETENESS_PARTIAL`.
>
> **⚠️ SELF-HOSTED COMPOSE: the overlay's fail-closed default is gone.**
> `docker-compose.self-hosted.yml` used to default `LUCAIRN_L3_REQUIRED=true`,
> so a hand-rolled `customer.env` with no L3 line inherited fail-closed. It now
> supplies **no** posture, so that env inherits the sanitizer image's `degrade`
> instead. This is deliberate: the obvious migration (defaulting the new key to
> `reject`) would have overridden the `LUCAIRN_L3_REQUIRED=false` that
> `lucairn-init` and `customer.env.example` have written **for all install
> paths** since 2026-06 — skipping the boot refusal and fail-closing against a
> `qwen2.5:7b` model this kit does not stage by default, i.e. `503` on every
> request after nothing but an upgrade. **If you want fail-closed on a
> self-hosted install, set `LUCAIRN_L3_AVAILABILITY_POSTURE=reject` in
> `customer.env` explicitly**, after staging the model. Coverage loss stays
> visible either way: the veil-witness certifies `COMPLETENESS_PARTIAL` when L3
> did not run, and no availability posture can suppress that.
>
> On the split Compose path and on Helm, request availability is unchanged.
>
> **Helm:** the chart sets **neither** flag, so both service images apply their
> own defaults (`degrade` + `partial`). To change one, set
> `global.l3AvailabilityPosture` (rendered onto the `sandbox-a` sanitizer
> container) or `global.l3CompletenessPosture` (rendered onto the `veil-witness`
> pod). Each variable is rendered **only** when its key is present — an unset
> key is how you say "use the image default", and it is why a stock
> `helm template` shows no `LUCAIRN_L3_*` env at all. To require L3, set
> `--set global.l3AvailabilityPosture=reject` after staging the GPU L3 shield
> (`--set sandbox-a.sanitizer.llmScanEnabled=true`).
>
> **Migration — delete the retired flag, do not leave it set.** Both services
> REFUSE TO START when they see `LUCAIRN_L3_REQUIRED` beside an unset
> replacement, rather than silently resolving to a posture you did not choose.
> On Compose, set the posture in `customer.env` and delete the old line
> (`bin/lucairn doctor` warns while it is still there). On Helm, the chart
> `fail`s the render with the same migration message if `global.l3Required` is
> present without both replacements — set both, then delete `global.l3Required`.
> One key cannot express `degrade` + `partial` anyway: the two services derive
> **opposite** postures from the same retired value.
>
> **Migration (chart 1.9.4+, still enforced):** the older per-subchart overrides
> `sandbox-a.sanitizer.l3Required` and `veil-witness.config.l3Required` are
> **REMOVED** and the chart `fail`s the render when either is present. Delete
> them from your values file.

### Self-hosted with managed LLM (BYOK Anthropic, OpenAI, etc.)

When the customer wants the Lucairn control + identity plane on-premise but
is OK with the LLM call itself going to a managed cloud provider (Anthropic,
OpenAI, Mistral, Gemini, Azure OpenAI, AWS Bedrock, internal LLM gateway),
initialize `managed-byok`, set at least one provider key, and run doctor before
loading the BYOK overlay on top of the customer + self-hosted overlays. Init
intentionally leaves provider keys empty and skips doctor; a fresh BYOK env is
not doctor-passing.

```bash
bin/lucairn-init --production --runtime-mode managed-byok \
  --license license-bundle.json --output customer.env
# Set ANTHROPIC_API_KEY, OPENAI_API_KEY, MISTRAL_API_KEY, or GEMINI_API_KEY
# in customer.env, then verify before Compose:
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
```

Then use the recorded topology (`up` runs the sanitizer core's registry
migration first):

```bash
bin/lucairn up --env customer.env
```

In `customer.env`, uncomment and populate the managed-LLM block:

```
LUCAIRN_LLM_EGRESS_ALLOWLIST=api.anthropic.com,api.openai.com
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
```

What the overlay does:

- Adds a new non-internal bridge network `dsa-egress` and joins **only
  Sandbox B** to it. Sandbox A, ID Bridge, Sanitizer, Audit, Witness, and
  all Postgres instances stay on their internal-only networks.
- Wires the provider API keys into Sandbox B so it can register the
  matching adapters (Anthropic, OpenAI, Mistral, Gemini). Unset providers
  are simply not wired; only adapters with a key present register.
- Fails fast at `docker compose config` time if
  `LUCAIRN_LLM_EGRESS_ALLOWLIST` is empty.

What the overlay does **NOT** do (operator responsibility):

- It does **not** enforce FQDN-level egress restrictions on the
  `dsa-egress` network. The Docker bridge driver does not support FQDN
  policy. Enforcing the allowlist is the operator's responsibility and
  belongs in the operator's existing network policy layer. Pick whichever
  matches the customer's stack:
  - Host firewall (iptables / nftables) + a DNS allowlist (dnsmasq /
    Pi-hole / Unbound forwarding only the declared FQDNs).
  - Cilium NetworkPolicy with FQDN selector (`toFQDNs:`) — the
    production-grade option for Kubernetes / k3s deployments.
  - Transparent forward proxy (squid, mitmproxy in transparent mode,
    tinyproxy) with an FQDN allowlist; route Sandbox B's egress through
    the proxy via `HTTPS_PROXY` env.

The compliance team should sign off on the chosen enforcement layer **and**
the contents of `LUCAIRN_LLM_EGRESS_ALLOWLIST` before this overlay is
loaded in production. Declaring the intended allowlist keeps the operator
intent close to the running compose state; `bin/lucairn doctor` surfaces
that the BYOK overlay is in effect so the compliance team can audit it.

Smoke-verify outbound reach from inside Sandbox B (a 401 from the LLM
provider is the expected pass — name resolution + TCP both worked, only
the dummy API key was rejected):

```bash
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted-byok.yml \
  --env-file customer.env \
  exec sandbox-b \
  curl -sS -o /dev/null -w "%{http_code}\n" \
  https://api.anthropic.com/v1/messages
# Expect: 401  (NOT 0 / NXDOMAIN / connection refused)
```

8. Confirm health.

```bash
curl -fsS http://127.0.0.1:8085/healthz
curl -fsS http://127.0.0.1:8085/readyz
```

9. Put the gateway behind TLS.

Terminate HTTPS at the customer reverse proxy and forward to `127.0.0.1:8080`. If the proxy is local or containerized, set `GATEWAY_TRUSTED_PROXY_CIDRS` to the proxy source CIDRs and rerun `bin/lucairn doctor --offline`.

> **Before you continue: provision witness mTLS.** As of the T-12 witness
> image, `:50058` certificate reads — including the gateway's own
> retrieval and the online doctor certificate-receipt check in the next
> step — refuse every caller with `Unauthenticated` until you complete the
> Compose bootstrap in § "Witness mTLS" above (`scripts/bootstrap-mtls-ca.sh`).
> Skipping it does not stop the stack from starting or from passing
> `/healthz`/`/readyz` in step 8 — it surfaces here, as a refused
> certificate read.

10. Mint your first customer, save the one-time key to a mode-0600 file, then
run the online full doctor.

```bash
export LUCAIRN_ADMIN_KEY="$(grep '^DSA_ADMIN_KEY=' customer.env | cut -d= -f2-)"

umask 077
./bin/lucairn-mint-customer \
  --raw-key-only \
  --name "Acme GmbH" \
  --email "ops@acme.de" \
  --tier enterprise > customer.key
chmod 600 customer.key

bin/lucairn doctor \
  --env customer.env \
  --compose docker-compose.customer.yml \
  --customer-key-file customer.key
```

`--raw-key-only` prints exactly the one-time raw API key plus a final newline
to stdout; its status/banner output goes to stderr, so the redirect above is
the canonical capture path and keeps the key out of argv. For `split-remote` or
`managed-byok`, append `--model <selected-model>` to the online doctor command;
local-runtime uses its recorded model and must not receive `--model`. See
`./bin/lucairn-mint-customer --help` for all flags including `--byok-per-request`,
`--managed-ai`, `--provider-key`, `--dry-run`, `--verbose`, and `--tool-scope`.

### Online doctor enterprise network settings

The keyed doctor helper starts with an empty environment and deliberately does
not inherit `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `SSL_CERT_FILE`, or curl
configuration. For an enterprise forward proxy, pass the explicit
`--customer-key-proxy http://proxy.example:8080` flag. For a private-CA HTTPS
gateway, additionally pass `--customer-key-ca-file /secure/pki/gateway-ca.pem`.
These map only to the helper's explicit `--proxy` and `--ca-file` inputs; do
not invoke the helper directly as an operator workflow.
The proxy must be an unauthenticated `http://` forward/CONNECT proxy; keep any
proxy credentials in the proxy's host-level authentication mechanism rather
than in doctor arguments. These flags are used only for the online keyed
journey and do not change offline/values-only doctor.

## Scoping MCP tools per engagement

Operators can restrict which MCP data-source servers a key is allowed to
call at mint time using the `--tool-scope` flag. This implements per-engagement
least-privilege MCP tool scoping: the gateway forwards only the specified
servers' tools to the model and drops all other MCP data-source tools.

**Requires gateway image 0.5.4+.** This flag has no effect on gateway 0.5.3
or earlier — the field is silently ignored by those images.

### Minting a scoped key

```bash
export LUCAIRN_ADMIN_KEY="$(grep '^DSA_ADMIN_KEY=' customer.env | cut -d= -f2-)"

./bin/lucairn-mint-customer \
  --name "Jonas Köhler / Example Insurance" \
  --email "jonas.koehler@example-insurance.de" \
  --tier enterprise \
  --tool-scope servicenow
```

To scope to multiple servers, pass a comma-separated list:

```bash
./bin/lucairn-mint-customer \
  --name "Fatima Al-Hassan / Acme Corp" \
  --email "fatima.alhassan@acme.example" \
  --tier enterprise \
  --tool-scope "servicenow,jira"
```

### Semantics

- **Empty or omitted** (no `--tool-scope`): no scoping applied — all MCP
  tools are forwarded to the model. This is the default and is byte-identical
  to pre-0.5.4 behaviour.
- **Set to one or more server names**: only those servers' MCP tools are
  forwarded. All other MCP data-source (`mcp__*`) tools are dropped before
  the request reaches the model. Non-MCP tools (built-in Claude Code tools,
  custom non-`mcp__` tools) are always forwarded regardless of scope.
- **Scope is mint-time only (v1)**: to change an existing key's scope,
  re-mint a new key with the desired `--tool-scope` and revoke the old one.
  There is no in-place update for tool scope in v1.

### Dry-run validation

Use `--dry-run` to inspect the resolved payload before firing:

```bash
./bin/lucairn-mint-customer --dry-run \
  --name "Test Engagement" \
  --email "ops@test.example" \
  --tier enterprise \
  --tool-scope servicenow
```

The dry-run output shows `tool_allowlist` in the POST body when the flag is
set, and omits it entirely when not set.

## Kubernetes Install

**IMPORTANT: Run steps 1-6 in the SAME shell session.** Step 1 exports
`DOCKER_CONFIG` to a temporary directory; step 4 (`helm template`) and
step 5 (`helm upgrade --install ... --set-file ...`) both read it. If
your session ends between steps (laptop sleeps, tmux detaches, terminal
closes, ssh disconnects), repeat step 1 from scratch — the temp dir
from the prior session may have been cleaned up by the OS or by
`rm -rf "$DOCKER_CONFIG"` in step 6.

1. Stage the registry credentials.

   The Lucairn-default GHCR images are private — Kubernetes pods need a
   `dockerconfigjson` payload to pull them, AND the GitHub account that
   owns the PAT must have been granted package-pull access by Lucairn
   (see § "Registry Authentication" → "Prerequisite — Lucairn-issued
   GHCR access" above). Mint a GitHub PAT with the `read:packages` scope
   (or reuse the one from the Compose path § "Registry Authentication").
   If you have not yet saved the PAT to a 0600 file, do that first so
   the value never appears in your shell history:

```bash
umask 077
cat > ~/.ghcr-token <<'EOF'
github_pat_xxxxxxxxxxxxxxxxxxxxxxxxx
EOF
chmod 600 ~/.ghcr-token   # belt-and-suspenders
```

   The chart now renders the per-namespace `lucairn-registry` Secret as
   a normal release-owned resource (one Secret per `dsa-*` namespace).
   The operator only needs to produce a single `dockerconfigjson` file
   and pass it to `helm install` via `--set-file
   global.imagePullDockerConfigJson=...`. Helm re-renders the Secret on
   every install + upgrade, so the previous two-phase manual
   `kubectl create secret` loop is no longer needed.

Kubernetes pull Secrets require a `dockerconfigjson` payload containing a
base64 `auth` entry. On hosts where Docker uses `credsStore`/`credHelpers`
(Docker Desktop, hardened workstations), `docker login` writes the
credential to the OS keychain and stores only helper metadata in
`config.json` — that metadata is not usable by Kubernetes (pods fail with
`ImagePullBackOff`).

> **⚠️ Corrected 2026-08-05 — `DOCKER_CONFIG=$(mktemp -d)` alone is NOT
> enough.** This guide previously told you to point `DOCKER_CONFIG` at a
> fresh temp dir and run `docker login`, on the theory that a brand-new
> config would have no credential helper. The 2026-08-04 clean-room
> rehearsal disproved that: on Docker Desktop 29.6.1 / macOS, `docker login`
> **still wrote `"credsStore": "osxkeychain"` into the fresh config**,
> producing `{"auths":{"ghcr.io":{}}}` — an entry with no `auth` field, i.e.
> exactly the unusable payload the trick was supposed to prevent. (The likely
> mechanism is helper auto-selection from `PATH`, but the observation — not
> the explanation — is what this correction rests on.)

Build the `dockerconfigjson` payload **explicitly** instead. This does not
depend on Docker CLI behaviour at all, so it works identically on Docker
Desktop, on a hardened workstation, and in CI:

```bash
# 1. Isolated config dir — never touch the operator's ~/.docker/config.json.
DOCKER_CONFIG=$(mktemp -d)
export DOCKER_CONFIG
chmod 700 "$DOCKER_CONFIG"

# 2. Write the auth entry directly. `base64 | tr -d '\n'` is required:
#    GNU base64 wraps at 76 columns and a wrapped value corrupts the token.
#    The PAT is read from the 0600 file, never from argv or shell history.
GHCR_USER=<your-github-username>
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' \
  "$(printf '%s:%s' "$GHCR_USER" "$(tr -d '\n' < ~/.ghcr-token)" \
     | base64 | tr -d '\n')" \
  > "$DOCKER_CONFIG/config.json"
chmod 600 "$DOCKER_CONFIG/config.json"

# 3. VERIFY before you install — this is the step whose absence let the old
#    recipe fail silently all the way to ImagePullBackOff. It must print
#    "pull secret: ok".
python3 - "$DOCKER_CONFIG/config.json" <<'PY'
import base64, json, sys
cfg = json.load(open(sys.argv[1]))
if "credsStore" in cfg or "credHelpers" in cfg:
    sys.exit("FAIL: config.json still references a credential helper; "
             "Kubernetes cannot use it.")
auth = cfg.get("auths", {}).get("ghcr.io", {}).get("auth")
if not auth:
    sys.exit("FAIL: no base64 auth entry for ghcr.io.")
if ":" not in base64.b64decode(auth).decode():
    sys.exit("FAIL: auth entry is not a base64 'user:token' pair.")
print("pull secret: ok")
PY
```

KEEP the path — the `helm install` step below reads it via `--set-file`.
Do NOT copy the file contents into `customer-values.yaml`; that would leak
the registry PAT into version control. Delete the directory when the
install finishes (step 6 already does this).

<details>
<summary>If you prefer <code>docker login</code></summary>

You may still use `docker login`, but you **must** disable the credential
helper for the isolated config *before* logging in, and you must keep the
verification step above — it is what turns a silent failure into a loud one:

```bash
DOCKER_CONFIG=$(mktemp -d)
export DOCKER_CONFIG
# Pre-seed an explicitly empty credsStore as a hint to the CLI. Whether it
# suppresses helper auto-selection is version-dependent and UNVERIFIED here,
# so the verification in step 3 above is what you actually rely on.
printf '{"auths":{},"credsStore":""}\n' > "$DOCKER_CONFIG/config.json"
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
```

If the verification step reports a helper is still referenced, fall back to
the explicit construction above — it has no such dependency.

</details>

If the customer mirrors the images into a private registry, swap
`docker login ghcr.io` for `docker login <your-mirror-host>` against
the mirror's credentials, then set `global.imageRegistry` in
`customer-values.yaml` to the mirror prefix. The same isolated
`$DOCKER_CONFIG` + `--set-file` recipe works for any registry.

2. Prepare values.

Two options:

   **Option A — automated (recommended for dev / pilot installs)**:

```bash
bash scripts/render-values.sh customer-values.yaml
```

   `scripts/render-values.sh` copies `customer-values.yaml.example`,
   fills every `REPLACE_*` placeholder with a correctly-shaped random
   value, derives every `LCR_*_PUBLIC_KEY` from its matching
   `LCR_*_SIGNING_KEY` seed (via `scripts/derive-veil-pubkey.sh`), and
   substitutes a SINGLE shared `dsaServiceToken` across all subcharts.
   The output is a ready-to-install `customer-values.yaml`.

   **Option B — manual**:

```bash
cp customer-values.yaml.example customer-values.yaml
```

   then replace every `REPLACE_*` value by hand. Prefer Option A unless
   you need fine-grained control over individual values. **WARNING — DO
   NOT use `openssl rand -hex 32` to generate `LCR_*_PUBLIC_KEY`
   slots.** The public key MUST be derived from the corresponding
   signing key seed via `scripts/derive-veil-pubkey.sh`; independent
   random hex yields a key that does NOT match the seed and every
   claim the service signs is silently rejected by the witness
   verifier with `UNAUTHENTICATED: invalid signature`.

3. Confirm the values file is complete and sane. Prefer an external
   secret manager for production. The gateway's keystore is persisted
   on a PVC in v1.0 (chart v1.4.0+) — see § "Lucairn Enterprise v1.0
   deployment topology" above. The postgres-gateway subchart for v2.0
   multi-replica HA is default-disabled — see § "v2.0 roadmap
   (postgres-gateway keystore)" below for the opt-in recipe.

4. Build chart dependencies and render once.

```bash
helm dependency build charts/lucairn
helm template lucairn charts/lucairn \
  -f customer-values.yaml \
  --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json" \
  --namespace lucairn \
  >/tmp/lucairn-rendered.yaml
```

5. Install. This runs the namespace pre-install hooks, creates every
   `dsa-*` namespace, AND renders the per-namespace `lucairn-registry`
   pull Secret in a single Helm transaction. Pods pull images without
   any manual `kubectl create secret` step.

```bash
helm upgrade --install lucairn charts/lucairn \
  -f customer-values.yaml \
  --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json" \
  --namespace lucairn \
  --create-namespace \
  --wait=false
```

6. Clean up the isolated Docker config.

```bash
rm -rf "$DOCKER_CONFIG"
unset DOCKER_CONFIG
```

7. Watch rollout.

```bash
kubectl get pods -A -l app.kubernetes.io/part-of=dsa
kubectl rollout status deployment/gateway -n dsa-edge
```

   Database-migration Jobs are named with the Helm release revision as a
   suffix — e.g. `audit-migrate-r1`, `id-bridge-migrate-r1`,
   `sandbox-a-migrate-r1`, `veil-witness-migrate-r1` on the first
   install; `*-migrate-r2` on the first `helm upgrade`, and so on. Each
   release creates a NEW Job resource because Kubernetes treats Job
   `spec.template` as immutable for existing resources; versioned names
   sidestep the immutability constraint. Old Jobs stay in the cluster as
   audit history but do not block subsequent upgrades. To clean up an
   older release's migration Job once the new one has succeeded:

```bash
# Replace <chart>, <namespace>, and <N> as appropriate.
kubectl delete job <chart>-migrate-r<N> -n <namespace>
# e.g. kubectl delete job audit-migrate-r1 -n dsa-audit
kubectl get jobs -n dsa-audit
kubectl get jobs -n dsa-bridge
kubectl get jobs -n dsa-ai
kubectl get jobs -n dsa-witness
```

## Production secrets: External Secrets Operator (ESO)

By default the chart materialises every secret (signing seeds, the gateway
keystore key, Postgres + app-role passwords, the admin/service tokens) as a
Kubernetes `Secret` via `global.secrets.backend: k8s-native`. **A Kubernetes
Secret is base64-ENCODED, not encrypted.** Anyone with `get secret` RBAC in
the namespace can read every value, and — unless your cluster operator has
enabled etcd encryption-at-rest — the values sit in etcd in cleartext.

For production we recommend storing these secrets in a real secrets manager
and letting the [External Secrets Operator](https://external-secrets.io/)
(ESO) sync them into the namespace at runtime. The chart already ships
`ExternalSecret` + `ClusterSecretStore` templates for three backends —
HashiCorp Vault, AWS Secrets Manager, and Azure Key Vault. Selecting any of
them flips the chart from inline `Secret` objects to ESO-managed
`ExternalSecret` objects automatically.

**Prerequisite:** install the External Secrets Operator in the cluster
(`helm repo add external-secrets https://charts.external-secrets.io && helm
install external-secrets external-secrets/external-secrets -n
external-secrets --create-namespace`) and provision a `ClusterSecretStore`
auth path (Vault Kubernetes auth role / AWS IRSA service account / Azure
workload identity).

### HashiCorp Vault

```yaml
# customer-values.yaml  (merged via -f)
global:
  secrets:
    backend: vault
    vault:
      endpoint: "https://vault.internal:8200"
      role: dsa            # Vault Kubernetes-auth role bound to the namespace SA
      mountPath: dsa       # KV v2 mount the Lucairn secrets live under
```

### AWS Secrets Manager

```yaml
global:
  secrets:
    backend: aws
    aws:
      region: eu-central-1
      # ClusterSecretStore references this exact, pre-created ServiceAccount.
      # It is one ESO identity, not one account per application namespace.
      serviceAccount:
        name: eso-service-account
        namespace: external-secrets
```

The chart does not create this ServiceAccount or its AWS annotation. Before
installing the production overlay, configure the exact reference above with an
IRSA role that can read the six configured Secrets Manager entries:

```bash
kubectl -n external-secrets create serviceaccount eso-service-account \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets annotate serviceaccount eso-service-account \
  eks.amazonaws.com/role-arn='arn:aws:iam::<acct>:role/lucairn-eso' --overwrite
```

Do not put AWS access keys or the role ARN in Helm values.

### Azure Key Vault

```yaml
global:
  secrets:
    backend: azure
    azure:
      keyVaultName: lucairn-prod-kv
      tenantId: "<azure-tenant-id>"   # ManagedIdentity auth
```

When `backend` is any value other than `k8s-native`, the chart renders an
`ExternalSecret` per service that pulls each key (e.g. `gateway-keystore-key`,
`postgres-veil-password`, `veil-witness-signing-key`) from the configured
store. Populate those keys in your secrets manager BEFORE `helm install` — an
unresolved `ExternalSecret` leaves the target `Secret` empty and the
dependent pod crash-loops at boot. `bin/lucairn doctor` emits an INFO
reminder when it detects a Kubernetes context still on the default
`k8s-native` backend.

**App-role passwords are conditional.** The `app_password` property on the
audit and veil-witness secrets (synced as `AUDIT_APP_PASSWORD` /
`VEIL_APP_PASSWORD`) is consumed only by the bundled-Postgres migrate Job,
which bakes the restricted `audit_app` / `veil_app` runtime roles. It is
synced **only when `postgresql.enabled: true`** for that subchart. For
external Postgres (`postgresql.enabled: false`) there is no migrate Job, so
you do not need to populate `app_password` in your secrets manager — the
`ExternalSecret` does not request it.

**External Postgres + runtime least-privilege.** With external Postgres the
chart has a single DSN slot per service: the runtime connects via
`external.databaseUrl` (mapped to `DATABASE_URL_APP`). Because there is no
bundled migrate Job to create a restricted role, **you own role choice**.
Run schema migrations out-of-band with a superuser (or migration-only) role,
then set `external.databaseUrl` to a **restricted runtime-role DSN**
(`veil_app` for veil-witness, the append-only `audit_app` for audit) so the
running pods never hold superuser. Supplying a superuser DSN here works but
forfeits least-privilege at runtime.

If you must stay on `k8s-native` (smaller pilots, air-gapped clusters), at
minimum enable [etcd encryption-at-rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
and restrict `get secret` RBAC to the Lucairn service accounts only.

## v1.0 gateway keystore (file-keystore on PVC)

v1.0 ships a single-replica gateway. Its keystore is persisted on a
PersistentVolumeClaim named `gateway-keystore` in the `dsa-edge`
namespace, mounted into the gateway pod at `/etc/dsa/keystore`
(`gateway.keystorePath`). The container's root filesystem stays
read-only — only the keystore mount is writable.

**Reclaim policy = Retain.** The PVC carries `helm.sh/resource-policy:
keep`. Running `helm uninstall lucairn` removes the gateway workload but
preserves the keystore PVC, so a subsequent re-install picks up the same
set of customer API keys. To intentionally drop the keystore (scratch
re-install, decommission, etc.), the operator runs:

```bash
kubectl delete pvc gateway-keystore -n dsa-edge
```

**Backup.** The keystore file is small (typically <100KB). A periodic
`kubectl cp` of `/etc/dsa/keystore/` out of the gateway pod into the
customer's existing backup pipeline is sufficient:

```bash
GATEWAY_POD=$(kubectl get pod -n dsa-edge -l app.kubernetes.io/name=gateway -o jsonpath='{.items[0].metadata.name}')
kubectl cp -n dsa-edge "$GATEWAY_POD":/etc/dsa/keystore "./gateway-keystore.$(date -u +%Y%m%dT%H%M%SZ)"
```

**Why single-replica in v1.0.** The file-keystore is a RWO PVC (single
writer). HPA stays off (`gateway.hpa.enabled: false`) and
`gateway.replicaCount: 1` — multiple gateway pods cannot share the same
RWO PVC, and the gateway's in-memory key state is not shared across
replicas under the v1.0 architecture. Pilot customers handling
<500 req/sec are easily served by a single pod.

## v2.0 roadmap (postgres-gateway keystore)

The chart includes a `postgres-gateway` subchart that is the v2.0 path
for multi-replica gateway HA. **It is disabled by default** and not
exercised in v1.0. Do NOT enable it on a v1.0 install — the umbrella
validator fails-fast on the mixed configuration (one paired flag on,
one off).

When v2.0 ships, the opt-in recipe in `customer-values.yaml` will be:

```yaml
postgres-gateway:
  enabled: true
  postgresql:
    storageSize: 5Gi
  secrets:
    values:
      postgresPassword: "REPLACE_WITH_POSTGRES_GATEWAY_PASSWORD"

gateway:
  replicaCount: 2     # or higher
  keystorePath: ""    # clear so GATEWAY_KEYSTORE_PATH is NOT emitted
  keystore:
    persistence:
      enabled: false  # v2.0 uses Postgres-backed keystore, not PVC
  postgresKeystore:
    enabled: true
  hpa:
    enabled: true     # safe under Postgres-backed keystore
```

The gateway enforces that `GATEWAY_KEYSTORE_PATH` and
`GATEWAY_KEYSTORE_DSN` are mutually exclusive at boot — emitting both
crash-loops the pod. The umbrella `gatewayPostgresKeystoreSubchartMismatch`
validator catches the mixed case before render. Both flags must be ON
together (v2.0 opt-in) or OFF together (v1.0 default).

**v2.0 backup** (forward-looking, when the subchart is opt-in enabled):

```bash
kubectl exec -n dsa-edge statefulset/postgres-gateway -- \
  pg_dump --no-owner --no-acl -U gateway gateway_keystore \
  > gateway_keystore.$(date -u +%Y%m%dT%H%M%SZ).sql
```

The v2.0 postgres-gateway PVC (`postgres-gateway-data`) also carries
`helm.sh/resource-policy: keep`, mirroring the v1.0 `gateway-keystore`
PVC reclaim semantics.

Note: The `gateway-keystore` PVC (v1.0) and `postgres-gateway-data` PVC
(v2.0 when enabled) are the ONLY PVCs in the kit with the Retain
annotation. The `audit`, `id-bridge`, and `veil-witness` subchart PVCs
do NOT carry this annotation — a `helm uninstall` will delete them. If
you intend to preserve audit cert history, identity tokens, or witness
signatures across an uninstall, back up those databases first with
`pg_dump` against each.

## Enterprise full-mesh mTLS (required production topology)

The supported production topology is gateway, audit, ID Bridge, Sandbox A with
its sanitizer, Sandbox B, and Veil Witness. It uses the verified
`DSA_MTLS_*` runtime contract on every mesh gRPC/HTTPS link. The Witness claim
port (`:50057`) belongs to that mesh; certificate retrieval (`:50058`) retains
its explicit `WITNESS_MTLS_*` runtime path, wired from the same operator-owned
gateway and Witness leaves.

Helm does not create a CA, a certificate, or a private key. Before installation,
your PKI must create one namespaced Secret per identity. Each Secret projects
only these three keys: `ca.crt`, `tls.crt`, and `tls.key`. The leaf must contain
the stated DNS SAN and be valid under the shared `ca.crt`.

| Identity | Namespace | Secret | Required DNS SAN |
| --- | --- | --- | --- |
| Gateway | `dsa-edge` | `lucairn-mtls-gateway` | `dsa-gateway` |
| Audit | `dsa-audit` | `lucairn-mtls-audit` | `dsa-audit` |
| ID Bridge | `dsa-bridge` | `lucairn-mtls-id-bridge` | `dsa-id-bridge` |
| Sandbox A | `dsa-identity` | `lucairn-mtls-sandbox-a` | `dsa-sandbox-a` |
| Sanitizer | `dsa-identity` | `lucairn-mtls-sanitizer` | `dsa-sanitizer` |
| Sandbox B | `dsa-ai` | `lucairn-mtls-sandbox-b` | `dsa-sandbox-b` |
| Veil Witness | `dsa-witness` | `lucairn-mtls-veil-witness` | `dsa-veil-witness` |

### Clean-cluster namespace create or intentional Helm adoption

Before creating any operator-owned mTLS or signed-manifest Secret below, run
this block on a clean cluster. Helm would otherwise create the namespaces only
after those namespaced Secrets are needed. The block is idempotent, but for an
already existing namespace it is safe **only** when you intentionally adopt
that namespace for the `lucairn` release in the `lucairn` release namespace.
Do not run it to silently claim ownership of an arbitrary existing namespace.

```bash
for namespace in dsa-edge dsa-audit dsa-bridge dsa-identity dsa-ai dsa-witness; do
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$namespace" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace "$namespace" meta.helm.sh/release-name=lucairn --overwrite
  kubectl annotate namespace "$namespace" meta.helm.sh/release-namespace=lucairn --overwrite
done
```

For every row, create the Secret from PKI output; this command contains only
file references and never places material in Helm values or Git:

```bash
kubectl -n <namespace> create secret generic <secret-name> \
  --from-file=ca.crt=/secure/pki/ca.crt \
  --from-file=tls.crt=/secure/pki/<identity>.crt \
  --from-file=tls.key=/secure/pki/<identity>.key
```

### Witness-signed manifest Secret (required when Veil is enabled)

Before the first production gateway boot, complete the witness key ceremony in
`docs/KEY_CEREMONY_RUNBOOK.md` §6. That ceremony creates a cryptographically
valid `witness-signed-manifest.json` from the public-key roster and the witness
signing seed **outside the cluster**. Helm must receive only that completed
signed output; never place the witness seed, `keys.json`, or an unsigned
placeholder in a values file or Git.

Create the dedicated gateway-namespace Secret from the signed output before
Helm runs. The atomic form is safe for a regenerated manifest during key
rotation:

```bash
kubectl -n dsa-edge create secret generic lucairn-witness-signed-manifest \
  --from-file=witness-signed-manifest.json=/secure/ceremony/witness-signed-manifest.json \
  --dry-run=client -o yaml | kubectl apply -f -
```

`values-prod.yaml` references that Secret through this names-only contract:

```yaml
gateway:
  veilWitnessSignedManifestPath: /certs/witness-signed-manifest.json
  witnessSignedManifest:
    existingSecret: lucairn-witness-signed-manifest
    secretKey: witness-signed-manifest.json
    mountPath: /certs
    fileName: witness-signed-manifest.json
```

If you choose different names, put the complete block in a names-only overlay.
In production with `gateway.veilEnabled=true`,
Helm fails before install if any field is absent or if
`veilWitnessSignedManifestPath` is not exactly `mountPath/fileName`. This Secret
is separate from the readiness-bundle contract; it projects exactly one file,
read-only, at the gateway path that verifies the witness signature at startup.

Use `charts/lucairn/values-prod.yaml` with an operator-controlled site overlay
as the supported production profile. The base file enables `global.mtls`, fixes
operator-owned Secret names, selects Vault, and sets the Vault KV v2 mount
(`dsa`) plus relative remote keys for Gateway, Audit, ID Bridge, Sandbox A,
Sandbox B, and Veil Witness. Its Vault endpoint is intentionally empty, so
`values-prod.yaml` alone fails closed. Copy
`charts/lucairn/values-prod-site.example.yaml` to a protected site location and
set its non-secret Vault endpoint (and any non-secret provider/remote routing
choices). Populate every listed remote reference in that External Secrets
backend before Helm runs. Do not layer development/pilot
`customer-values.yaml`, pass an API key with `--set`, or put application-secret
bytes in any values file. A credential rotation changes the backend values
first, then follows the coordinated application/database/service rollout; Helm
values remain names and paths only.

Vault is the concrete default. To use AWS or Azure instead, change both
`global.secrets.backend` and **every** enabled child’s `secrets.backend` to the
same provider, then supply that child’s `secrets.aws.name` or
`secrets.azure.name`. A global backend alone is not sufficient: each child
ExternalSecret intentionally reads its own explicit backend and remote name.

### Registry authentication is outside Helm

Never pass a Docker config, `dockerconfigjson`, or registry token through Helm:
that would retain it in release history. `values-prod.yaml` deliberately leaves
`global.imagePullSecrets: []` and `global.skipPullSecretGuard: false`, so it
fails closed for its private registry. For Secret-based registry auth, ensure a
pre-created pull Secret exists in every mandatory workload namespace and set
`global.imagePullSecrets` to its name in a names-only site overlay (the checked-in
site example uses `lucairn-registry`). The chart adds that reference directly to
chart-specific workload PodSpecs. Create the pull Secret with `kubectl` after
namespace adoption and before Helm; Helm never creates or copies its credential
bytes.

Leave `global.imagePullSecrets` empty only when actual node-level registry auth
or registry workload identity is configured outside Helm. Only then set
`global.skipPullSecretGuard=true` in that private site overlay to suppress the
private-registry guard.

Before install, set the site-overlay path and run the Helm-only preflight with
the ordered production values. A green render alone is not an accepted
deployment, so write it to `/dev/null`.

```bash
SITE_OVERLAY=/secure/operator/lucairn-production-site.yaml

bin/lucairn doctor \
  --values charts/lucairn/values-prod.yaml \
  --values "$SITE_OVERLAY" \
  --offline
helm template lucairn charts/lucairn \
  -f charts/lucairn/values-prod.yaml \
  -f "$SITE_OVERLAY" \
  >/dev/null
```

Then install and wait for every workload; run the handshake battery before
declaring success:

```bash
helm upgrade --install lucairn charts/lucairn \
  -f charts/lucairn/values-prod.yaml \
  -f "$SITE_OVERLAY" \
  --namespace lucairn --create-namespace --wait --timeout 12m

# Isolated, destructive-to-its-own-Kind-cluster acceptance only:
scripts/test-enterprise-mtls-kind.sh
```

The harness creates ephemeral CA/leaves and six mode-0600 private application
environment files under a mode-0700 owned private state directory. They contain
fresh signing seeds, their derived public keys, database/cache credentials,
shared service/canary tokens, and the gateway keystore key; they are never
printed or committed. The seven mTLS identity Secrets remain independently pre-created,
mirroring the operator/PKI production contract. The harness creates a unique
valid witness-signed manifest from that same coherent disposable key set and
creates `lucairn-witness-signed-manifest` in `dsa-edge` before Helm. It does not
write the ceremony `keys.json`, witness seed, or signed output into the
worktree. It then creates a unique Kind cluster, installs only the mandatory
mesh plus its required service
databases/caches (not Admin, observability, or Sandbox-B Ollama/model pull),
performs positive handshakes and wrong-CA, wrong-SAN, no-client, expired-leaf,
and partial-Secret negatives, rotates the Audit leaf, and tears down its owned
state. The five non-Witness supporting positives run from a repository-built,
no-base (`FROM scratch`) local probe image containing only the generated static
TLS helper; it is built for the actual Kind node platform, loaded by the
harness with `imagePullPolicy: Never`, and removed with the owned local tag and
archive. This disposable helper image is not a product/release artifact and is
not covered by the normal rendered-image preloader. The two Witness checks run
a temporary verified-TLS helper in the actual gateway Pod using that Pod's
projected leaf identity. The same temporary helper invokes
the gateway health handler locally over loopback, then is deleted after that
evidence battery. Its cleanup always attempts temporary helper removal, owned
cluster deletion, local probe-image removal, and private state removal. A
failed owned-cluster deletion makes the gate fail and prints only the cluster
name plus its exact retry command. Because this harness uses stock Kind/kindnet, it proves only
the actual Pod's projected-leaf transport identity; it does not prove
NetworkPolicy enforcement or per-link caller authorization. The Witness checks
prove transport handshakes only; they do not claim to invoke gateway application
Witness RPC methods. mTLS proves CA membership authentication and exact server
identity, while authorization remains a separate NetworkPolicy and application
control. It preloads every rendered product image before Helm and requires a
functioning container runtime, but no registry credential is supplied to Helm.
It does not use a production or customer context.

### Kind acceptance evidence ledger

The terminal `PASS: coverage class=...` lines use these exact meanings. A
workload-originated transport handshake executes from the named actual workload
Pod with its read-only projected leaf and expected server SAN; it is not
relabeled as an application request. The local-probe positives retained by the
harness are supporting local-probe evidence for negative, fingerprint, and
rotation logic—not the acceptance mechanism. The two application-layer
calls below are representative only.

| Mandatory edge | Acceptance class | Initiating projected leaf | Expected server SAN |
| --- | --- | --- | --- |
| Gateway → Audit | workload-originated transport handshake | Actual Gateway Pod / Gateway | `dsa-audit` |
| Gateway → ID Bridge | workload-originated transport handshake | Actual Gateway Pod / Gateway | `dsa-id-bridge` |
| Gateway → Sandbox A | workload-originated transport handshake; representative application-layer gateway gRPC identity | Actual Gateway Pod / Gateway | `dsa-sandbox-a` |
| Gateway → Sandbox B | workload-originated transport handshake | Actual Gateway Pod / Gateway | `dsa-sandbox-b` |
| Gateway → Sanitizer | workload-originated transport handshake; representative application-layer gateway→sanitizer HTTPS | Actual Gateway Pod / Gateway | `dsa-sanitizer` |
| Gateway → Veil Witness `:50057` | workload-originated transport handshake | Actual Gateway Pod / Gateway | `dsa-veil-witness` |
| Gateway → Veil Witness `:50058` | workload-originated transport handshake | Actual Gateway Pod / Gateway | `dsa-veil-witness` |
| Audit → Veil Witness `:50057` | workload-originated transport handshake | Actual Audit Pod / Audit | `dsa-veil-witness` |
| ID Bridge → Veil Witness `:50057` | workload-originated transport handshake | Actual ID Bridge Pod / ID Bridge | `dsa-veil-witness` |
| Sanitizer → Veil Witness `:50057` | workload-originated transport handshake | Actual Sandbox A Pod / Sanitizer sidecar | `dsa-veil-witness` |
| Sandbox B → Veil Witness `:50057` | workload-originated transport handshake | Actual Sandbox B Pod / Sandbox B | `dsa-veil-witness` |

Residual risk: a non-representative application client could be misconfigured
despite transport success. Exhaustive per-edge application verification is
deferred to a separately grilled and locked runtime workstream; this Helm-only
package must not add per-edge application RPC code to simulate it.

### Rotation and incident replacement

1. Issue a replacement leaf with the same required SAN and the same active CA.
2. Replace only the affected identity Secret atomically (`kubectl create secret
   generic ... --dry-run=client -o yaml | kubectl apply -f -`); do not put the
   leaf in Helm values.
3. Restart only that workload and wait for readiness, for example
   `kubectl -n dsa-audit rollout restart deployment/audit` followed by
   `kubectl -n dsa-audit rollout status deployment/audit --timeout=6m`.
4. Re-run the positive handshake battery and retain the new certificate
   fingerprint in the operator change record.

Replacing a leaf changes what the server presents after its restart; it is not
certificate revocation. A valid old leaf signed by the same CA remains
cryptographically valid until expiry because the pinned DSA transport has no
CRL/OCSP or per-link client-SAN ACL. For immediate incident invalidation,
perform a coordinated CA rotation for every affected identity. The harness
separately proves an expired leaf is rejected.

## Witness mTLS (legacy Compose compatibility)

> **Required for working certificate reads (T-12, 2026-08-03).** The
> veil-witness cert RPC port (:50058) now attaches its ACL on every code
> path, including the default no-mTLS Compose posture. With no client
> certificate presented, `GetCertificate`/`ExportCertificates` refuse every
> caller — **including the gateway itself** — with `Unauthenticated`. A kit
> install that skips the bootstrap below will boot and pass
> `/healthz`/`/readyz` normally, but every certificate lookup (the
> gateway's own retrieval, the dashboard's certs surface, and `bin/lucairn
> doctor`'s certificate-receipt check) will refuse until you complete it.
> This is deliberate hardening — a caller-supplied `customer_id` was the
> only scoping on `redaction_manifest_body`, the placeholder→original PII
> map, so an unauthenticated port was a disclosure — **not** a broken
> install. Kit installs inherit it automatically on the next
> `dsa-veil-witness` image pull, so run the bootstrap below BEFORE minting
> your first customer / running online doctor (§ "Advanced / pre-S1 manual
> Docker Compose install" step 10, or before `bin/lucairn up` on an S1
> install).

### Compose path

Do this **before the first `bin/lucairn up`**. `up` bind-mounts
`LCR_WITNESS_MTLS_HOST_DIR` (default `./.certs/witness-mtls`) into the witness
and the gateway; when that folder does not exist yet, Docker creates it as
`root`, and the bootstrap below then fails with `Operation not permitted`
(measured on a Linux host, kit 2.0 rehearsal 2026-11-04). If that happened,
remove the empty folder (`sudo rmdir ./.certs/witness-mtls`) and continue.

1. Run the bootstrap CA script to generate a deploy-local CA + server cert
   for the witness + a client cert for the gateway. Use the folder
   `/etc/witness-mtls` on the host: the containers read the same path, and
   `bin/lucairn doctor` checks the `WITNESS_MTLS_*` paths below on the host,
   so any other host folder makes the doctor report `certs: missing …`:

   ```bash
   sudo scripts/bootstrap-mtls-ca.sh /etc/witness-mtls
   ```

   **Linux Docker host:** the witness, the gateway and Sandbox A run as uid
   10001, and the script leaves the folder `0700` and the keys `0600` owned by
   the user who ran it. Hand the folder to uid 10001 and let other users
   traverse it (the keys stay `0600`), or the witness logs `failed to load
   witness mTLS server cert … permission denied` and serves `:50058` without
   client authentication while every healthcheck stays green:

   ```bash
   sudo chown -R 10001:10001 /etc/witness-mtls
   sudo chmod 0755 /etc/witness-mtls
   ```

   (macOS with Docker Desktop maps file ownership; the `chown` is not needed
   there.) Stated limit: the script writes the CA private key (`ca.key`) into
   the same folder, which both containers mount; move it to an offline place
   after the bootstrap if you do not need to issue more client certificates.

2. Set in `customer.env` (lucairn-init writes these keys empty; fill them in,
   do not add a second copy of a key):

   ```bash
   LCR_WITNESS_MTLS_HOST_DIR=/etc/witness-mtls
   WITNESS_MTLS_CA_BUNDLE_PATH=/etc/witness-mtls/ca.crt
   WITNESS_MTLS_SERVER_CERT_PATH=/etc/witness-mtls/witness-server.crt
   WITNESS_MTLS_SERVER_KEY_PATH=/etc/witness-mtls/witness-server.key
   WITNESS_MTLS_GATEWAY_CLIENT_CERT_PATH=/etc/witness-mtls/gateway-client.crt
   WITNESS_MTLS_GATEWAY_CLIENT_KEY_PATH=/etc/witness-mtls/gateway-client.key
   WITNESS_MTLS_SERVER_NAME=witness
   ```

3. Start (or, on a running install, recreate) the stack with the recorded
   topology — `bin/lucairn up` recreates the witness and the gateway because
   their settings changed:

   ```bash
   bin/lucairn up --env customer.env
   ```

   On a pre-S1 install without the wrappers, pass the env file and your overlay
   set: `docker compose -f docker-compose.customer.yml [-f <overlay> …]
   --env-file customer.env up -d --no-deps --force-recreate veil-witness gateway`.

   Check: the witness logs `certificate gRPC server: mTLS REQUIRED + per-method
   ACL active` and the gateway logs `evidence admission gate ACTIVE`.

If any of the three server-side paths (`WITNESS_MTLS_CA_BUNDLE_PATH`,
`WITNESS_MTLS_SERVER_CERT_PATH`, `WITNESS_MTLS_SERVER_KEY_PATH`) are unset,
the witness logs a warning and its transport degrades — but the per-method
ACL is attached regardless and does not degrade with it. Claim intake
(`:50057`, from bridge, sanitizer, and audit) is a separate port and keeps
flowing unaffected; only certificate **reads** on `:50058` refuse while the
operator completes the CA bootstrap above.

### Kubernetes (Helm) compatibility path

This legacy per-child configuration is for non-production compatibility only.
Do not combine it with `global.mtls.enabled=true`; the production validator
rejects that ambiguous state. Use the enterprise full-mesh contract above for
all production Helm installs.

1. Generate certs (or use your PKI) and create Kubernetes Secrets:

   ```bash
   # Witness namespace secret (server cert + CA bundle)
   kubectl create secret generic witness-mtls-server-certs \
     --namespace dsa-witness \
     --from-file=ca.crt=./certs/ca.crt \
     --from-file=server.crt=./certs/witness-server.crt \
     --from-file=server.key=./certs/witness-server.key

   # Gateway namespace secret (client cert + CA bundle)
   kubectl create secret generic gateway-witness-mtls-certs \
     --namespace dsa-edge \
     --from-file=ca.crt=./certs/ca.crt \
     --from-file=gateway-client.crt=./certs/gateway-client.crt \
     --from-file=gateway-client.key=./certs/gateway-client.key
   ```

2. Add to your `customer-values.yaml`:

   ```yaml
   veil-witness:
     witnessMtls:
       serverSecret: witness-mtls-server-certs

   gateway:
     witnessMtls:
       clientSecret: gateway-witness-mtls-certs
   ```

3. Upgrade:

   ```bash
   helm upgrade lucairn charts/lucairn -f customer-values.yaml
   ```

---

## Upgrade from kit 1.9.7 to 2.0.0

What changes: every `dsa-*` image moves from `0.5.5` to `1.1.0`; four services
are new (the registry database `postgres-sanitizer-core` with its own volume
`pg-sanitizer-core-data`, the model sidecar, the Go core and the migration step
`migrate-sanitizer-core`); the Anthropic route (`/v1/messages`) runs through the
core with the final check enforced. The 1.x databases keep their schema (the
migration ceilings stay veil-witness 10 · audit 7 · id-bridge 4 · sandbox-a 8),
so no 1.x row is rewritten. The ServiceNow mode stays **off**: nothing in this
upgrade turns it on (§ "ServiceNow mode (off by default)" is a separate,
per-key opt-in). Read `CHANGELOG.md` `[2.0.0]` first.

### Compose (an install made with `bin/lucairn-init`)

Run every command from the install's kit directory. **Keep that directory's
name:** it is the Compose project name, and the new release finds your volumes
by it.

0. **Host.** At least 16 GB RAM for Docker, Docker Engine 26.0.0 or newer
   (25.0.5+ / 23.0.11+ on those lines; CVE-2024-29018), about 6 GB free disk
   for the two new images, `openssl` and `sudo` (Linux).
1. **Back up, with the 1.9.7 stack running.**
   - The databases: OPS.md § "Backups" → "Compose path — backup" (`audit`,
     `bridge`, `veil`).
   - The install's state files, into a private folder:
     ```bash
     BK="backups/kit-1.9.7-$(date -u +%Y%m%dT%H%M%SZ)"
     mkdir -p "$BK" && chmod 700 "$BK"
     cp -p customer.env customer.env.runtime-profile.yaml customer.env.image-manifest.yaml "$BK/"
     ```
   - Write down the runtime mode: `grep '^runtime_mode:' customer.env.runtime-profile.yaml`.
2. **Stop** (volumes stay): `bin/lucairn down --env customer.env`
3. **Replace the kit files with 2.0.0 in the same directory** — a git checkout:
   `git fetch --tags && git checkout v2.0.0`; a release tarball: verify it
   (`docs/RELEASING.md`), then extract it over the directory. `customer.env`,
   its two sidecar files, `.certs/`, `.secrets/` and `models/` are not part of
   the release and stay as they are.
4. **Add the kit 2.0 settings to `customer.env`.** Change the image tag, then
   append the core's two secrets and its image pins (the digests come from the
   release's `image-manifest.yaml`). No key may appear twice in the file:
   ```bash
   sed -i.bak 's/^LUCAIRN_IMAGE_TAG=.*/LUCAIRN_IMAGE_TAG=1.1.0/' customer.env && rm -f customer.env.bak
   mdigest() { awk -v s="    $1:" '$0==s{f=1;next} f&&/^    [a-z]/{exit} f&&/^      digest:/{gsub(/[" ]/,"");sub("digest:","");print;exit}' image-manifest.yaml; }
   {
     echo "DSA_SANITIZER_CORE_REGISTRY_KEY=$(openssl rand -hex 32)"
     echo "POSTGRES_SANITIZER_CORE_PASSWORD=$(openssl rand -hex 24)"
     echo "LUCAIRN_SANITIZER_CORE_IMAGE_TAG=1.1.0"
     echo "LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=$(mdigest dsa-sanitizer-core)"
     echo "LUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST=$(mdigest dsa-sanitizer-core-sidecar)"
   } >> customer.env
   grep -c -E '^LUCAIRN_SANITIZER_CORE_(SIDECAR_)?IMAGE_DIGEST=sha256:[0-9a-f]{64}$' customer.env   # must print 2
   ```
   **Development install only** (`GRPC_TLS_ENABLED=false`: the core then dials
   the local witness in plaintext, like every other development emitter) —
   also append the three empty witness-leaf lines:
   ```bash
   printf 'LCR_WITNESS_MTLS_SANITIZER_CORE_CA_BUNDLE_PATH=\nLCR_WITNESS_MTLS_SANITIZER_CORE_CLIENT_CERT_PATH=\nLCR_WITNESS_MTLS_SANITIZER_CORE_CLIENT_KEY_PATH=\n' >> customer.env
   ```
   Keep the database password free of space, `$ ' " \ `` ` and `#`
   (`openssl rand -hex` is). Optional keys (`SANITIZER_CORE_MTLS_HOST_DIR`,
   `SANITIZER_CORE_REGISTRY_DSN_FILE`, `SANDBOX_B_MESSAGES_JSON_MAX_BYTES`) may
   stay unset: the defaults are the folders below and 4 MiB.
5. **Re-record the runtime profile for 2.0.0.** The 1.9.7 profile pins
   tag `0.5.5` and the 1.9.7 image manifest; every `bin/lucairn` command refuses
   the new tag until the profile is recorded again. Move the two sidecar files
   out (they are in the backup), drop the profile marker, and let
   `bin/lucairn-init` adopt the env with the SAME mode flags you installed with
   (`--production --license <bundle>` or `--dev`, plus your `--runtime-mode`
   and its flags):
   ```bash
   mkdir -p "$BK/replaced" && mv customer.env.runtime-profile.yaml customer.env.image-manifest.yaml "$BK/replaced/"
   sed -i.bak '/^LUCAIRN_RUNTIME_PROFILE_REQUIRED=1$/d' customer.env && rm -f customer.env.bak
   bin/lucairn-init --dev --runtime-mode managed-byok --image-tag 1.1.0 \
     --adopt-runtime-profile --output customer.env      # your own mode flags here
   ```
   The adoption keeps every existing value and secret, appends the marker,
   writes the 2.0.0 profile and image snapshot, creates the core's mTLS
   material (on Linux through `sudo`: the keys must belong to uid 10001) and
   writes the registry DSN file.
6. **Offline check:** `bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline`
   — fix every line it fails (it names every missing kit 2.0 setting).
7. **Verify the image signatures, then pull:** OPS.md § "Upgrade" step 3
   (`bin/lucairn verify-images …`), then `bin/lucairn pull --env customer.env`.
8. **Create the registry (explicit step):** the new database is empty; apply the
   core's migrations 0001–0007 before anything else starts:
   ```bash
   docker compose -f docker-compose.customer.yml --env-file customer.env \
     --profile sanitizer-core-migrate run --rm migrate-sanitizer-core
   ```
   It stops at the reviewed ceiling (7) and never migrates down. (`bin/lucairn
   up` runs the same step again first; at the ceiling it changes nothing.)
9. **Start:** `bin/lucairn up --env customer.env` (registry database → sidecar
   → core → gateway; the sidecar loads its models in 1–5 minutes).
10. **Check:** the online doctor (`--customer-key-file`, § "Doctor lifecycle"),
    a first request, and that your data is all there — for example the audit
    trail: `docker compose -f docker-compose.customer.yml --env-file customer.env exec -T postgres-audit psql -U dsa -d audit -Atc 'SELECT count(*) FROM audit_events'`
    gives at least the count before the upgrade.

### Helm

1. Back up: OPS.md § "Backups" → "Helm path — backup".
2. Add the core's credentials (§ "Sanitizer core (kit 2.0, Helm)" step 1) and
   create its two mTLS Secrets (step 2) before the upgrade.
3. Set `global.imageTag: "1.1.0"` (the 2.0.0 chart carries the core pair's
   signed digests) and run `helm upgrade lucairn charts/lucairn -n lucairn -f customer-values.yaml`.
   The registry migration runs as the Job `sanitizer-core-migrate-r<revision>`;
   the core Pod waits in `Init` until it completed.
4. Check: `bin/lucairn doctor --values customer-values.yaml`, then with
   `DOCTOR_KUBE_LIVE=1`.

### Rollback to 1.9.7

Kit 2.0.0 changes no 1.x database schema, so the 1.9.7 images read the same
databases: no restore is needed for a rollback (restore a backup only if the
data itself was damaged).

- **Compose:**
  1. `bin/lucairn down --env customer.env` (removes the 2.0 containers, keeps
     every volume).
  2. Put the 1.9.7 kit files back (`git checkout v1.9.7`, or the 1.9.7
     tarball) in the same directory.
  3. Restore the three state files from the backup:
     `cp -p "$BK/customer.env" "$BK/customer.env.runtime-profile.yaml" "$BK/customer.env.image-manifest.yaml" .`
  4. `bin/lucairn up --env customer.env`.
  5. The registry volume (`<directory name>_pg-sanitizer-core-data`) is not
     used by 1.9.7. It holds sealed conversation state of at most the last
     24 hours; delete it when you do not return to 2.0 soon:
     `docker volume rm <directory name>_pg-sanitizer-core-data`.
- **Helm:** `helm rollback lucairn <revision> -n lucairn` (`helm history
  lucairn -n lucairn` lists them). The registry PVC is kept; delete it as
  above when you do not return to 2.0.

## Sanitizer core (kit 2.0, Compose)

Kit 2.0 runs the same sanitizer as the hosted Lucairn service: a Go **sanitizer
core**, its **model sidecar** (spaCy + GLiNER) and the core's **registry
database**. The gateway sends the Anthropic route (`/v1/messages`) through the
core with the final check (Gate) enforced — both ON by default, as on the hosted
service. The existing Python `sanitizer` service stays: it still serves the
OpenAI, MCP and proxy routes.

| Service | What it is |
|---|---|
| `postgres-sanitizer-core` | The core's registry database (own volume, internal network only). |
| `sanitizer-core-sidecar` | The model sidecar. It owns the network namespace the core runs in; its scan endpoint listens on loopback only. Memory cap 6.5 GB. |
| `sanitizer-core` | The Go core, joined to the sidecar's namespace. Gateway → core is verified mTLS; core → witness is verified TLS with the core's own client certificate. Memory cap 1 GB. |
| `migrate-sanitizer-core` | The registry migration step. Profile-gated: a plain `docker compose up` never runs it; `bin/lucairn up` runs it first, every time. |

### Host requirements

- **16 GB RAM minimum** for the Docker host (or Docker Desktop VM). The sidecar
  alone is capped at 6.5 GB and peaks near 5.6 GB; the core adds up to 1 GB.
  `bin/lucairn doctor` (without `--offline`) **fails** when the Docker engine
  reports less than 15,000 MiB, and — on a Linux host, while the sidecar runs —
  when less than 1,500 MiB is still available. With `--offline` it only warns
  (it may be running on another machine). Add about 5 GB more when the L3 shield
  model is loaded.
- About 6 GB more disk: the sidecar image is a 2 GB download and unpacks to 5.4 GB
  (measured on the 1.1.0 release candidate, linux/amd64).
- **Docker Engine 26.0.0 or newer** (on the 25.x line 25.0.5+, on the 23.x line
  23.0.11+; the 24.x line has no fix). Older engines forward DNS queries from
  `internal: true` networks to the host's resolvers (CVE-2024-29018), which
  defeats the internal networks the core and the identity plane rely on.
  `bin/lucairn doctor` (without `--offline`) fails on an older engine.

### 1. Secrets and image pins (`customer.env`)

`bin/lucairn-init` generates both secrets, writes the image variables and the
registry DSN file (step 2b). By hand:

```bash
DSA_SANITIZER_CORE_REGISTRY_KEY=$(openssl rand -hex 32)    # seals every registry row; keep it stable
POSTGRES_SANITIZER_CORE_PASSWORD=$(openssl rand -hex 24)   # no space, $ ' " \ ` or #
LUCAIRN_SANITIZER_CORE_IMAGE_TAG=1.1.0                     # ONE tag for core + sidecar
LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=                       # release-filled; set both digests or neither
LUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST=
```

The core and the sidecar are one pair from one release: the core refuses to
start against a sidecar from another build. Do not set `LCR_PROFILE` in
`customer.env`: the core runs the kit profile, and the ServiceNow mode is off
until an admin opts in per key — see
[ServiceNow mode (off by default)](#servicenow-mode-off-by-default).

The core's witness hop follows `GRPC_TLS_ENABLED`, the switch that makes the
local witness serve TLS on its claim port. With `true` (the default, and
required with `DSA_ENV=production`) the core dials it with verified mTLS and
its kit client leaf. A `--dev` install runs a plaintext mesh
(`GRPC_TLS_ENABLED=false`: sandbox-b has no TLS leaf in development), and
`bin/lucairn-init --dev` writes these three lines empty, so the core dials the
development witness in plaintext as well:

```bash
LCR_WITNESS_MTLS_SANITIZER_CORE_CA_BUNDLE_PATH=
LCR_WITNESS_MTLS_SANITIZER_CORE_CLIENT_CERT_PATH=
LCR_WITNESS_MTLS_SANITIZER_CORE_CLIENT_KEY_PATH=
```

Change the switch and those three lines together. `bin/lucairn doctor` fails
when they disagree: a core dialing mTLS to a plaintext witness drops every
claim while the turns still succeed, and a latched core without its leaf does
not start.

### 2. mTLS material (once)

```bash
sudo scripts/bootstrap-sanitizer-core-mtls.sh        # writes .certs/sanitizer-core-mtls/ + .secrets/sanitizer-core-mtls-ca/
```

It creates a deploy-local CA and four leaves, each in the directory of the one
container that mounts it. The CA (`ca.key`, `ca.crt`) lives in
`.secrets/sanitizer-core-mtls-ca/` (root-only, `0700`), outside `.certs/`: the
gateway mounts the whole `.certs/` at `/certs`, so nothing under it may hold
the CA private key. For a cert directory of your own, the CA goes to the
sibling `<dir>-ca` (or pass a folder as the second argument and set
`SANITIZER_CORE_MTLS_CA_DIR` to it in `customer.env`); `bin/lucairn doctor`
fails while the CA sits inside a mounted folder. A CA that an earlier 2.0
pre-release left in `.certs/sanitizer-core-mtls/ca/` is moved on the next run.
Folders the script creates under `sudo` (`.certs/`, `.secrets/`) are handed
back to your user, and `.certs/` stays `0755`, so the gateway (uid 10001) can
read `/certs/witness-signed-manifest.json` and you can copy that file in
without `sudo`; the doctor fails on Linux while uid 10001 cannot traverse
`.certs/` or read the manifest.

| File | Used by | Purpose |
|---|---|---|
| `sanitizer-core/dsa-sanitizer-core.{crt,key}` | core | server leaf for the gateway hop (SAN `dsa-sanitizer-core`) |
| `sanitizer-core/witness-client.{crt,key}` | core | client leaf for the witness hop (SAN `dsa-sanitizer`) |
| `gateway/dsa-gateway.{crt,key}` | gateway | client leaf for the core hop (SAN `dsa-gateway`; the core refuses any other) |
| `veil-witness/dsa-veil-witness.{crt,key}` | witness | server leaf on the claim port (SAN `dsa-veil-witness`, which the core pins) |

Run it as root on Linux: it hands the service directories to uid 10001, the user
every Lucairn image runs as (a `0600` key owned by another uid is unreadable in
the container, and the witness and the core refuse to start). On Linux an
ordinary user is refused before anything is written; `bin/lucairn-init` runs
this one step through `sudo` for you (it may ask for your password). Only if the
image user maps to your own uid — Docker Desktop for Linux, or a
user-namespace-remapped daemon whose mapping lands on it — declare that with
`LUCAIRN_CONTAINER_UID=$(id -u)` (in the shell for the script, in `customer.env`
for `bin/lucairn doctor`), and no root is needed. On macOS (Docker Desktop maps
file ownership) an ordinary user is fine. `bin/lucairn doctor` fails on Linux
when a key belongs to another uid than the containers'. A re-run reuses every
existing file; to rotate a leaf, delete it, re-run, and
recreate the container that mounts it. If you keep the material elsewhere, pass
the directory to the script and set `SANITIZER_CORE_MTLS_HOST_DIR` to it.

### 2a. Renewing a leaf, rotating the CA

The leaves are valid 365 days (`LEAF_DAYS`); `bin/lucairn doctor` fails 30 days
before one expires. The CA is valid 3650 days (`CA_DAYS`).

- **Renew one leaf** (or replace a leaked one): delete its `.crt` and `.key`
  pair, re-run the script with the same arguments as the first time, then
  recreate the ONE container that mounts it — `sanitizer-core` for the two
  `sanitizer-core/` leaves, `gateway` for `gateway/dsa-gateway.*`,
  `veil-witness` for `veil-witness/dsa-veil-witness.*`:
  `docker compose ... up -d --no-deps --force-recreate <service>`. A restart is
  not enough for the core's DSN file and is not guaranteed for the certificates;
  recreate.
- **Rotate the CA** (CA key exposed, or before the CA expires): every leaf must
  move to the new CA at once — the core pins the witness name and verifies the
  gateway's client leaf against its CA copy, so a mixed state drops every claim
  or refuses every turn.
  1. Move the old CA out of the way (keep it until step 4 succeeded):
     `sudo mv .secrets/sanitizer-core-mtls-ca .secrets/sanitizer-core-mtls-ca.old`
     (your own CA folder: the folder you passed as the second argument or set
     as `SANITIZER_CORE_MTLS_CA_DIR`).
  2. Delete the three service folders of the cert directory (they hold the
     leaves and the CA copies):
     `sudo rm -rf .certs/sanitizer-core-mtls/sanitizer-core .certs/sanitizer-core-mtls/gateway .certs/sanitizer-core-mtls/veil-witness`
  3. Re-run `sudo scripts/bootstrap-sanitizer-core-mtls.sh` with the same
     arguments: a new CA and four new leaves.
  4. Recreate the three containers together:
     `docker compose ... up -d --no-deps --force-recreate sanitizer-core gateway veil-witness`,
     then run `bin/lucairn doctor` (online): the core's witness transport and no
     `DROPPED` claim. Then delete the `.old` CA folder.
- **A CA folder of your own and re-runs:** the script reads the CA folder only
  from its second argument or from `SANITIZER_CORE_MTLS_CA_DIR` in ITS OWN
  environment — never from `customer.env` (the doctor reads it from there).
  `sudo` drops exported variables, so pass it as the second argument (or
  `sudo SANITIZER_CORE_MTLS_CA_DIR=/your/ca scripts/bootstrap-sanitizer-core-mtls.sh <cert dir>`)
  on every re-run. Forgotten, the script looks in the default CA folder, finds
  leaves without a CA there and refuses (`… exists but the CA does not …`);
  nothing is written.
- **Helm:** after steps 1–3 (run as your own user, see § "Sanitizer core (kit
  2.0, Helm)" step 2), replace both Secrets and restart both workloads:
  `kubectl -n dsa-identity create secret generic sanitizer-core-mtls --from-file=<dir>/sanitizer-core/ --dry-run=client -o yaml | kubectl apply -f -`,
  the same for `gateway-sanitizer-core-mtls` in `dsa-edge` from `<dir>/gateway/`,
  then `kubectl -n dsa-identity rollout restart deployment/sanitizer-core` and
  `kubectl -n dsa-edge rollout restart deployment/gateway`.

### 2b. Registry DSN file (once, and after every password change)

```bash
scripts/write-sanitizer-core-registry-dsn.sh --env-file customer.env
#   -> .secrets/sanitizer-core/registry-dsn   (mode 0444 in a 0700 directory)
```

`bin/lucairn-init` runs this for you and records the path in `customer.env`
(`SANITIZER_CORE_REGISTRY_DSN_FILE`). The script (like `bin/lucairn doctor` and
`bin/lucairn support-bundle`) reads `customer.env` THROUGH Docker Compose
(`docker compose config`, client side, no daemon needed), so it sees exactly the
values Compose hands the containers — quotes, escapes, `${...}` references and a
variable exported in your shell included. Without Docker Compose on the machine
it refuses rather than guess; a variable exported in your shell with a value
other than `customer.env`'s is refused too (unset it). For an env file with another name it
writes `.secrets/sanitizer-core/<name>.registry-dsn`, so two env files in one
directory never share the file of another's password.

The core needs a connection string (DSN) for its registry database, and that
string holds the database password. The core is never given it on its command
line: process arguments are readable by every local user of the Docker host
(`ps`). The compose file mounts this one file read-only into the core and starts
it with `--registry-dsn-file /run/secrets/sanitizer-core/registry-dsn`.

- The file holds one line, `postgres://dsa:<password>@postgres-sanitizer-core:5432/sanitizer_core?sslmode=<POSTGRES_SSLMODE>`.
  The script percent-encodes the password (an `@` becomes `%40`), because the
  core reads a file only in this URL form and refuses anything else at boot.
- Who can read it: the file is `0444` inside a `0700` directory. The directory
  keeps other host users out. The core (uid 10001) can read the file whichever
  user ran the script, with no `chown`, because only the single file is mounted.
- Elsewhere: set `SANITIZER_CORE_REGISTRY_DSN_FILE` in `customer.env` (or pass
  the path to the script). Keep the same rule: the directory must not be open
  to group or others.
- After changing `POSTGRES_SANITIZER_CORE_PASSWORD` or `POSTGRES_SSLMODE`: re-run
  the script, then **recreate** the core. A restart is not enough, because the
  container keeps the file it was created with:
  `docker compose ... up -d --no-deps --force-recreate sanitizer-core`.
  Postgres applies `POSTGRES_PASSWORD` only when its volume is first created; to
  rotate the password of an existing registry, change it in the database too
  (`ALTER ROLE dsa PASSWORD ...`).
- If the file is missing, `up` fails (the mount refuses to create it), and
  `bin/lucairn doctor` names the fix.

### 3. Registry migrations (install and every upgrade)

`bin/lucairn up` runs this step for you before it starts anything, every time
(a no-op when the registry is at the ceiling), and stops if it fails. With
plain `docker compose ... up -d`, run it yourself first:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env \
  --profile sanitizer-core-migrate run --rm migrate-sanitizer-core
```

The step applies `migrations/sanitizer-core/` (byte copies of the core's own
migrations, checked against `SHA256SUMS`) in one transaction, up to the ceiling
this kit release reviewed (`CEILING_SANITIZER_CORE` in
`scripts/migration-ceilings.conf`). It never migrates down. Until it has run, the
core refuses to start and the gateway, which waits for a healthy core, does not
start either.

### 4. Start, and the one recreate rule

`bin/lucairn up --env customer.env` runs step 3, then starts everything in
order: registry database → sidecar (model load takes 1–5 minutes) → core →
gateway.

> ⚠️ **After every sidecar recreate, recreate the core.** A sidecar *restart*
> (crash, memory-cap kill, `docker restart`) is followed by the core on its own
> within about 30 seconds. A sidecar *recreate* (new image, changed definition,
> `up --force-recreate`) makes a new container, and the core stays joined to the
> old one's network until you run
> `docker compose ... up -d --no-deps --force-recreate sanitizer-core`.
> The online doctor detects this state.

### 5. What `bin/lucairn doctor` checks

Offline and online: both secrets (presence, format, placeholders), the registry
DSN file (no `--dsn` in any compose file of the install; the file present, a
regular file of at most 8 KiB, readable by the core's uid 10001 on Linux, not
open to other host users, a `postgres://` URL equal to the one `customer.env`
gives — values are never printed), the profile,
the gateway switches, the witness hop (`GRPC_TLS_ENABLED` and the core's client
leaf agree; production requires `true`), every certificate
(chain, purpose, pinned SAN, SHA-256 signature, 30-day expiry, key permissions,
and on Linux the key owner = the containers' uid; the key/certificate pairing
when the key is readable), the image pair against
`image-manifest.yaml`, and host memory. Online additionally: the Docker Engine
version (CVE-2024-29018 floor), the rendered Compose
configuration of the core (kit profile — `kit-servicenow` with the ServiceNow
opt-in — witness hop matching the witness it dials, namespace, no `--dsn`,
`--registry-dsn-file` pointing at a mounted path),
the three containers (running and healthy), the core's namespace join, the
migration ledger against the ceiling, and the core's log — witness transport
`mtls` (plaintext only on a development install with `GRPC_TLS_ENABLED=false`)
and no `DROPPED` claim. The online check does not send a turn; a real turn and its
certificate (sanitizer claim from the core) are the install rehearsal's proof.

`bin/lucairn support-bundle` never collects the DSN file. Before it writes the
archive it checks every collected file for every secret value Docker Compose
knows for this install — the secret-named `customer.env` values as Compose reads
them and as it interpolates them from your shell, the secret-named values it
hands any container, URL passwords, and the DSN and its password (each whole
value, with LF and CRLF line breaks, and each 12+ byte line of a multi-line
value). It compares the raw bytes, the DECODED content — each YAML file parsed
by Docker Compose's own YAML parser, the env file by Compose's env-file parser
(whole and line by line), JSON by Python's `json` — and every line of every file
with its string escapes undone (`\uXXXX`, `\xHH`, octal, `\n`, `\"`, `\\` …),
whether or not the line parses (with Compose's `$$` escape and percent encoding
undone too). If one is found, it removes the bundle and writes nothing.

It never guesses past what it cannot decode exactly: it refuses, naming the file
(and the line, where there is one) and the construct, when a YAML file carries a
tag (`!reset`, `!override`, `!!binary`, …) or a duplicate key; when `customer.env`
assigns a variable twice, has a value spanning lines, two assignments on one line,
or a value that changes when `$` is taken literally (an interpolation, `\$`, an
octal `\0…` escape in double quotes); when a JSON file has a duplicate member;
when a log or other text line has an escape that cannot be unescaped (`\u`
without four hex digits, a lone surrogate); and when a secret is shorter than 12
characters (it cannot be searched for without matching unrelated text). YAML
merge keys (`<<`) and anchors are decoded with nothing lost and are accepted. It
refuses too without Docker Compose, without Python 3, or when Compose cannot
render your install's project (for example a required variable is missing) —
the scan is never skipped and never runs on a partial list of secrets. Remove
the named construct and run it again.

**Support bundle — stated limits.** The scan is a safety net, not a guarantee:
**review the bundle before you send it.** It does not catch:

- the same variable assigned twice on ONE line of an env file (two
  assignments written one after the other on the same line): only the last
  value is checked;
- a secret whose value looks like a file path (it starts with `/`, `./`, `../`
  or `~/`): no search pattern is made for it;
- log text escaped more than three levels deep (a string inside a string inside
  a string inside a string): it is not fully decoded;
- an escape sequence inside a log line whose backslash is itself
  percent-encoded (`%5C`): it is percent-decoded for the comparison only and
  not unescaped again;
- a secret split over two log lines with other text between its parts;
- encodings other than the ones above (base64, shell quoting, HTML entities).

The core listens only on its gateway link (`--listen=sanitizer-core:8790`, a
name only that network carries), not on the witness or registry links of the
same network namespace. With the witness-central overlay the core's namespace
still has no route off the host: the core dials a small relay container
(`sanitizer-core-witness-relay`, from the sidecar image) on its internal witness
link, and only the relay can reach `LUCAIRN_CENTRAL_WITNESS_ADDR` — one address,
plain TCP; the core's mTLS session runs end to end through it. Both sides use
the relay's alias `sanitizer-core-witness-relay-link`, which only the internal
witness link carries (the service name is on the egress link too, where Docker's
resolver would answer it first).

### Upgrading a kit 1.x Compose install

Follow § [Upgrade from kit 1.9.7 to 2.0.0](#upgrade-from-kit-197-to-200) — it
adds the core's settings, re-records the runtime profile, creates the mTLS
material and the DSN file, and runs the registry migration as its own step.
The core's registry is a new database (volume `pg-sanitizer-core-data`), so
nothing of 1.x is migrated into it.

**Registry retention:** the core deletes a registry conversation (with its
sealed original values) once its 24-hour expiry has passed by more than
210 seconds, on a sweep every 10 minutes (log line `registry-sweep result=…`);
tombstones of deleted conversations are kept 24 hours. The sweep cannot be
switched off.

## Sanitizer core (kit 2.0, Helm)

The Helm chart carries the same new sanitizer core as the Compose path, in the
`sanitizer-core` sub-chart (identity namespace, beside Sandbox A). It is ON by
default — the same as the hosted service — through two switches that must agree:
`sanitizer-core.enabled` deploys it, `global.sanitizerCore.enabled` tells the
gateway and the NetworkPolicies about it. The chart refuses a render where they
differ.

| Resource (namespace `dsa-identity`) | What it is |
|---|---|
| Deployment `sanitizer-core` | ONE Pod with two containers: `sidecar` (the model sidecar, loopback 127.0.0.1:8765 only) and `core` (the Go core, verified mTLS on :8790). A Pod is one shared network namespace — the hosted layout, with no network path to the sidecar at all. Strategy `Recreate`: one core at a time. |
| StatefulSet / Service / PVC `postgres-sanitizer-core` | The registry database (digest-pinned `postgres:16-alpine`, PVC kept on `helm uninstall`). |
| Job `sanitizer-core-migrate-r<revision>` | The capped registry migration 0001–0007 (see step 3). |
| NetworkPolicies `edge-sanitizer-core-egress`, `identity-sanitizer-core-ingress`, `identity-sanitizer-core-egress`, `identity-sanitizer-core-registry` | Only the gateway Pod reaches the core (:8790); the core reaches only its registry (:5432), the witness claim port (:50057) and the cluster resolver Pods on :53 (`k8s-app=kube-dns`; set `global.clusterDNS.podLabels` if yours differ) — with `global.dnsRestriction=true` (Cilium) that port-53 rule is left out and the core resolves only the cluster names its Cilium policy `dns-restrict-identity-sanitizer-core` allows (a plain port-53 grant would override that allowlist); only the core and the migration Job reach the registry; the registry has no egress, DNS included (both are carved out of the namespace's `allow-dns`). |

**Images by signed digest only.** The core and its sidecar start only from the
two digests the kit release records in `image-manifest.yaml`
(`image_digests.signed_artifacts`); a released kit's chart carries them in
`sanitizer-core.image.digest` / `sanitizer-core.sidecar.image.digest`. The
render refuses an empty, malformed or placeholder digest, and
`bin/lucairn doctor --values` fails on tag-only images and on a pair other than
the manifest's.

**Passwords as files, not in Pod specs.** The registry database reads its
password from a mounted file (`POSTGRES_PASSWORD_FILE`); the migration Job and
the core's `wait-for-migration` init container build a `0600` libpq password
file (`PGPASSFILE`) from the mounted Secret file, and the migration runner
connects with that file (no `PGPASSWORD` in its environment). Stated limit: on
EVERY start, the official `postgres` image's entrypoint itself reads the file
into `POSTGRES_PASSWORD` (exported), so its own helper processes inherit it
(`id`, the `mkdir`/`chmod` of the data directories, the re-exec as the
`postgres` user) before it checks whether a database exists; on the first boot
of an empty registry volume its initialisation processes (initdb, the temporary
server, psql) get it as well, with `PGPASSWORD`. All of this stays inside that
container, and the entrypoint clears both (`unset` of every `POSTGRES_*`
variable) before it starts the real server. The kit accepts this rather than
initialise with `POSTGRES_HOST_AUTH_METHOD=trust`, which would leave a database
without a password if that first boot were interrupted. An external registry DB
(`sanitizer-core.postgresql.enabled=false`) is supported by the live doctor: it
then checks the migration Job and the core's readiness, not a bundled
StatefulSet.

### Node requirements

The sidecar requests 6 GiB and is limited to 6.5 GiB (it peaks near 5.6 GB with
GLiNER and both spaCy models); the core is limited to 1 GiB. Plan **one node in
the identity zone with at least 8 GiB allocatable beyond Sandbox A's pods**, or
the Pod stays `Pending`. An OOM kill at the limit makes the Pod NotReady and the
gateway's Anthropic requests fail closed until the models have reloaded
(1–5 minutes). Add about 6 GB of image storage on that node (the sidecar image unpacks to 5.4 GB).

### 1. Credentials

`k8s-native` backend (development): set both values, or let
`scripts/render-values.sh` generate them from `customer-values.yaml.example`:

```yaml
sanitizer-core:
  secrets:
    values:
      registryKey: "<openssl rand -hex 32>"       # 64 hex; seals every registry row; keep it stable
      postgresPassword: "<openssl rand -hex 24>"  # URL-safe characters only
```

External Secrets backend (required in production): store `registry_key`,
`password` and `registry_dsn` at `sanitizer-core.secrets.<backend>` (default
path `sanitizer-core`), where `registry_dsn` is
`postgres://dsa:<password>@postgres-sanitizer-core:5432/sanitizer_core?sslmode=disable`
with the same password. The core reads the DSN as a **file**
(`--registry-dsn-file`); the password never appears on its command line.
The core accepts only this `postgres://` (or `postgresql://`) URL form from a
file and refuses `key=value` text at boot. A password with characters other
than `A-Z a-z 0-9 . _ ~ -` must be percent-encoded in `registry_dsn` only, not
in `password`: `/ ? # @ : %` and a space become `%2F %3F %23 %40 %3A %25 %20`.
On the `k8s-native` backend the chart builds the URL itself, so there the
password, the DB user and the database name must be URL-safe as they are; the
render refuses anything else.

### 2. mTLS Secrets (once, before `helm install`)

The gateway → core hop is verified mTLS on its own deploy CA — the same tree the
Compose path uses. Helm never generates key material; create the two Secrets
from the bootstrap script's output:

```bash
LUCAIRN_CONTAINER_UID="$(id -u)" scripts/bootstrap-sanitizer-core-mtls.sh /secure/sanitizer-core-mtls
kubectl -n dsa-identity create secret generic sanitizer-core-mtls \
  --from-file=/secure/sanitizer-core-mtls/sanitizer-core/
kubectl -n dsa-edge create secret generic gateway-sanitizer-core-mtls \
  --from-file=/secure/sanitizer-core-mtls/gateway/
```

Run the script as your own user here (not as root): `kubectl` must be able to
read the keys, and their owner inside the Pod comes from the chart (`fsGroup`
10001, mode 0440). On Linux the script refuses an ordinary user unless
`LUCAIRN_CONTAINER_UID` names that user's own uid (the Compose rule: keys for
a container must belong to the container's uid); for Helm the files only feed
`kubectl create secret`, so `LUCAIRN_CONTAINER_UID="$(id -u)"` is the right
declaration on every OS. Keep the directory private; delete it once the Secrets exist
if your PKI keeps the CA elsewhere. Only the core's server leaf (SAN
`dsa-sanitizer-core`) and the gateway's client leaf (SAN `dsa-gateway`) are
projected, each with the CA certificate; the CA (key and certificate) is
written to the sibling folder `/secure/sanitizer-core-mtls-ca/` and never
becomes a Secret. To use your own PKI instead, issue the two
leaves with those SANs from one CA and point `sanitizer-core.mtls.*Key` /
`gateway.sanitizerCore.mtls.*Key` at your Secret's key names.

The core → witness claim hop needs no extra Secret. With `global.mtls.enabled=true`
(the production profile) the core sends its claims with the `sanitizer` mesh
leaf (`global.mtls.secrets.sanitizer`) over latched mTLS
(`LCR_WITNESS_REQUIRE_MTLS=true`) — the hosted service once lost every claim at
the handshake without that latch. In development (no mesh) the development
witness serves its claim port in plaintext like every other development emitter,
and the core logs a warning on every boot.

### 3. Registry migration

The chart runs the registry migration as a Job on every `helm install` and
`helm upgrade` (`sanitizer-core-migrate-r<revision>`): the kit's capped runner
(`migrate-sanitizer-core.sh`, byte copy in the chart) applies the
`SHA256SUMS`-checked migrations in one transaction, up to this release's reviewed
ceiling of 7, never down. The core never migrates on its own boot; its Pod waits
in `Init` (`wait-for-migration`) until the ledger has reached
`sanitizer-core.migrations.targetVersion`. A Job that runs again on an
up-to-date registry does nothing.

### 4. Check it

```bash
bin/lucairn doctor --values customer-values.yaml                     # the rendered contract
DOCTOR_KUBE_LIVE=1 bin/lucairn doctor --values customer-values.yaml  # + the running release (kubectl context)
```

The render check covers: core + sidecar in one Pod, no `--dsn` argument in any
container, the DSN file, the sidecar limit ≥ 6500 MiB, `LCR_PROFILE=kit` set as a
literal in the core's `env:` (so no Secret attached through `envFrom` can change
it), the
latched witness hop in production, the gateway's switch set and mTLS client, the
migration Job against the ceiling, and the four NetworkPolicies. With
`DOCTOR_KUBE_LIVE=1` it also checks, in the current kubectl context, that both
mTLS Secrets exist, the Deployment and the registry are Ready, the latest
migration Job completed, and the core's log shows its witness transport (`mtls`
in production) and no `DROPPED` claim. NetworkPolicy presence is not proof that
your CNI enforces it.

**Stated limits (this release):** the registry database is not in the backup
CronJobs yet (it holds only the last 24 hours of sealed conversation state; the
core deletes expired conversations itself, as on the Compose path). If you move
the identity namespace, also update `gateway.sanitizerCore.url` (it names
`dsa-identity`).

## ServiceNow mode (off by default)

Kit 2.0 ships the hosted service's **ServiceNow mode**: for API keys that your
admin binds to your ServiceNow instance, the sanitizer recognises the people of
that instance through keyed fingerprints that a small app on **your own
instance** publishes. The fingerprints and their key stay in your environment;
nothing of this goes to Lucairn.

**It is off by default.** A fresh install and every upgrade from 1.9.x run
without it: `bin/lucairn` never writes the settings below, and with no key bound
the overlay `docker-compose.servicenow-control.yml` is not used at all.

### How the opt-in works

The mode is on only when `customer.env` sets **both**
`GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true` **and** a non-empty
`GATEWAY_SERVICENOW_KEY_BINDINGS`. `bin/lucairn` reads these through Docker
Compose itself (so `export`, quotes, CRLF line ends and repeated lines count
exactly as Compose counts them) and then adds the overlay to every command.

- Bindings without the switch: `bin/lucairn up` refuses with
  `session_config_invalid` and starts nothing. The gateway would refuse the same
  configuration.
- The switch without bindings: the mode stays off (the doctor tells you).
- Empty bindings + `bin/lucairn up` = off again.

### The directory app (on your ServiceNow instance)

**Where it is.** The kit ships the app's update set at
`servicenow-directory/lucairn-directory-update-set.xml` — scoped app
`x_1620539_lucdir`, "Lucairn Directory Fingerprints", version 0.2.0. A bundle
made by `bin/lucairn bundle create` for an opted-in `customer.env` carries the
same folder. Next to the file:

- `servicenow-directory/scheduled_job.js` and `companion_job.js` — the scripts
  of the app's two scheduled jobs (step 3; the update set does not carry the
  jobs).
- `servicenow-directory/PROVENANCE` — where the files come from: the app's
  repository `Declade/lucairn-servicenow-directory`, the commit, the path of
  the update set there (`update_set/x_1620539_lucdir.xml`, built from the
  app's source by `tools/build_update_set.py`) and the sha256 of every file in
  the folder. Check them yourself with `shasum -a 256` (or `sha256sum`).
  `bin/lucairn doctor` (mode on), `bin/lucairn bundle verify` and the kit's
  release script refuse a file whose sha256 differs from this record.
- `servicenow-directory/LICENSE` — the app's licence: Business Source License
  1.1 with the same parameters as this kit.
- `servicenow-directory/README.md` — a short summary of the steps below.

**It stays off on both sides until you switch it on.** The import leaves the
app's switch `x_1620539_lucdir.enabled` at `false` and its lists and
`instance_id` empty; the fingerprint key is not in the file (the app's first
build makes it on your instance, and it stays in your environment). The kit's
mode stays off until step 3 of "Turn it on" below binds a key.

**Import and check** (as the instance's admin):

1. Take `servicenow-directory/lucairn-directory-update-set.xml` from the kit.
2. On your instance: *Retrieved Update Sets → Import Update Set from XML*,
   preview, commit. The file holds 85 update records: the application, the
   role `x_1620539_lucdir.reader`, seven tables with their columns (they
   arrive empty — the key table's row is data, not part of an update set),
   eight properties, six script includes, three business rules and the REST
   API with its four operations. Whether the import carries the script
   includes' "Accessible from" setting is checked in step 4.
3. The two **scheduled jobs** are not in the update set. Create them by hand
   in the application (*Scheduled Script Execution*):
   - name "Lucairn directory: publish fingerprints", *Periodically*, repeat
     interval 15 minutes, script = the text of
     `servicenow-directory/scheduled_job.js`;
   - name "Lucairn directory: publish companion", *Periodically*, repeat
     interval 1 minute, active, script = the text of
     `servicenow-directory/companion_job.js`. It stays inert until you switch
     the app's companion (the field map) on with its own switch
     `x_1620539_lucdir.companion_enabled`, which is optional, off after the
     import and not needed for the kit's mode.
4. **Check the key table before switching on.** In *Scripts – Background*,
   **with the scope selector set to `x_1620539_lucdir`** (in scope `global`
   the platform refuses the call):

   ```
   gs.info(JSON.stringify(new x_1620539_lucdir.LucairnDirectoryPublisher().keyStoreCheck()))
   ```

   It must print `"closed":true`. Then, as an account **without any role**
   (identity type *Machine*),
   `GET /api/now/stats/x_1620539_lucdir_keystore?sysparm_count=true` must
   answer **403**. If it answers a count, or `closed` is `false`, do not switch
   the app on (the app itself refuses to store or release a key while `closed`
   is `false`).
5. **Measure before switching on** (two checks the app cannot make itself):
   - signed in to the browser as a user without any role, open
     `x_1620539_lucdir_keystore.list`, the same with a filter on `key_value`,
     and a list export: no row, no count. If a row or a count shows, do not
     switch on.
   - list who, other than an admin, can become the reader: who may grant the
     role `x_1620539_lucdir.reader` and who may impersonate the account of
     step 6. Each of them can fetch the key. Restrict it to the people you
     intend.
6. **Create the reader account** the Lucairn install uses: identity type
   *Machine*, *Web service access only*, the role `x_1620539_lucdir.reader`
   and nothing else it does not need. Its login becomes the stored
   `login.json` (step 4 of "Turn it on").
7. Set `x_1620539_lucdir.enabled` to `true`. Wait for the fingerprint job
   (every 15 minutes) or run it once with *Execute Now*: the first run makes
   the key on your instance and publishes generation 1.
8. **Confirm:** `GET /api/x_1620539_lucdir/directory/bundle` as the reader
   account answers 200 with a `generation` of 1 or more. As an admin, in the
   same scope:
   `gs.info(JSON.stringify(new x_1620539_lucdir.LucairnDirectoryPublisher().status()))`
   shows the generations and how many users were read.

To switch the app off, set `x_1620539_lucdir.enabled` to `false`.

**Stated limit (this file):** the update set was loaded and previewed on the
app's test instance, which already has the app installed: 0 problems, all 85
records "update / commit". A commit from this file was not run there, and no
import on a second instance has been run, so none of the steps above has been
run on an instance that did not have the app before. Step 5 was not measured
by Lucairn (its test accounts are web-service only).

### Turn it on (customer admin)

1. **Install the directory app on your instance** and confirm it publishes —
   "The directory app (on your ServiceNow instance)" above, steps 1 to 8.
2. **Find the key id to bind.** The customer id is in `.lucairn-customer-id`
   (written by `bin/lucairn-mint-customer`). List its keys with your admin key:

   ```bash
   printf 'X-Admin-Key: %s\n' "$DSA_ADMIN_KEY" | curl -s -H @- \
     "http://127.0.0.1:${GATEWAY_PORT:-8080}/api/v1/admin/customers/<customer_id>/keys"
   ```

   The header goes to curl on standard input (`-H @-`), never on its command
   line, where any local user could read the admin key in the process list
   (`printf` is a shell builtin). Copy the `key_id` of each key that should use
   the mode.
3. **Set the operator settings in `customer.env`** (the same names as the hosted
   service; see the commented block in `customer.env.example`):

   ```bash
   GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true
   GATEWAY_SERVICENOW_KEY_BINDINGS=<key_id>=<instance_id>          # comma-separated, no spaces
   GATEWAY_SERVICENOW_INSTANCES=[{"id":"<instance_id>","base_url":"https://<instance>.service-now.com","customer_id":"<customer_id>"}]
   SERVICENOW_CONTROL_SUBNET=10.251.251.0/29                         # a private /29 (or wider) of your choice
   SERVICENOW_CONTROL_GATEWAY_IP=10.251.251.2
   SERVICENOW_CONTROL_SANITIZER_IP=10.251.251.3
   SERVICENOW_CONTROL_CORE_IP=10.251.251.4
   SERVICENOW_CONTROL_MATERIAL=/srv/lucairn/servicenow-control/material
   SERVICENOW_CONTROL_SANITIZER_CONFIG=/srv/lucairn/servicenow-control/sanitizer.yaml
   SERVICENOW_LOGIN_DIR=/srv/lucairn/servicenow-login
   ```

   **The control subnet must not overlap any Docker network on the host.**
   Docker gives every network it creates without a fixed subnet (the kit's own
   networks, about 23) a subnet from its default address pools, `172.17.0.0/16` to
   `172.31.0.0/16` (one /16 each) and `192.168.0.0/16` (in /20 steps); a control subnet inside
   one of them fails at `up` with "Pool overlaps". The example
   `10.251.251.0/29` lies outside both pools; pick any free private /29 that is
   also not routed on your site (and outside your engine's own
   `default-address-pools`, if `/etc/docker/daemon.json` sets them). `bin/lucairn
   up` checks the subnet against the existing Docker networks first and refuses
   an overlap, naming the network; inside the default pools it warns.
   `customer_id` must be the owner of the bound key. One instance belongs to one
   customer. Do **not** set `LCR_PROFILE`: the overlay sets the core's opt-in
   value itself. The switch must be exactly `true`: with any other value
   (`false`, a typo, `TRUE`) the overlay does not render — Docker Compose
   refuses it ("depends on undefined service servicenow-switch-…") before
   anything starts.
4. **Place the stored login** of the machine account from step 1 (as root):

   ```bash
   install -d -m 0700 -o 10001 -g 10001 /srv/lucairn/servicenow-login
   install -m 0400 -o 10001 -g 10001 login.json /srv/lucairn/servicenow-login/login.json
   ```

   The folder holds `login.json` and nothing else; folder `0700`, file `0400`,
   both owned by `10001:10001` (the gateway's user). It is mounted read-only into
   the gateway only.
5. **Create the control certificates** (deploy-local CA, a gateway leaf and a
   sanitizer leaf; the CA key never leaves `material/operator`):

   ```bash
   sudo python3 scripts/bootstrap-servicenow-control.py /srv/lucairn/servicenow-control
   ```

   The gateway mounts `material/gateway`; the Python sanitizer and the new core
   mount `material/sanitizer`; the model sidecar mounts nothing of it.
6. **Start:** `bin/lucairn up --env customer.env`. Before Compose starts
   anything, `up` rebuilds the Python sanitizer's config copy
   (`SERVICENOW_CONTROL_SANITIZER_CONFIG`) from your current base config
   (`SANITIZER_CONFIG_FILE`, default `config/default-sanitizer.yaml`) on every
   run, and checks the login folder. When the rebuilt copy differs from the
   file on disk, `up` writes it and, after starting the stack, **recreates the
   Python sanitizer** (`up -d --no-deps --force-recreate sanitizer`): the
   sanitizer bind-mounts that one file and keeps reading the version its
   container was created with until it is recreated (a plain `up -d` does not
   recreate it). An unchanged copy is left as it is. While the gateway
   container is running, `up` also checks that every bound key id exists under
   its instance's owner (counts only); a key id that does not exist stops
   `up`. Before the first start (no gateway container running) it skips that
   check with a warning: the admin key is only ever sent to a running gateway,
   never to whatever else might listen on `127.0.0.1:GATEWAY_PORT`. `up` needs `python3` with PyYAML
   (`apt install python3-yaml` or `python3 -m pip install pyyaml`) for the copy.
   Run `up` (and the doctor below) **as root** (`sudo`): the login folder is
   `0700` and owned by `10001`, so no other account can look inside it, and a
   login check that cannot see `login.json` refuses (it never passes
   unchecked).
7. **Check:** `bin/lucairn doctor --env customer.env --customer-key-file …`,
   plus `--model <selected-model>` on a `managed-byok` or `split-remote` install
   (the online doctor refuses to start without it there; a `local-runtime`
   install reads the model from its runtime profile). Offline and online it checks the copy against a rebuild of the base, the
   login custody, and that the login file and the control material reach only
   their services; online also that the running sanitizer reads the current
   copy (the hash of the file inside the container), the bound key ids, the
   gateway's admin status (`GET /api/v1/admin/servicenow/status`: mode `on`,
   every instance `unlocked`, control certificate valid ≥ 14 days) and exactly
   **one running** gateway container. It sends the admin key only while that
   container runs; with none running it fails and names the cause.

**Turn it off:** empty `GATEWAY_SERVICENOW_KEY_BINDINGS` and run `bin/lucairn up`.
**Rotate a bound key:** bind the new key id, `up`, then revoke the old key.

### Stated limits

- **A mistyped key id runs the generic path.** The gateway enters the mode only
  for a key id it finds in the bindings. `bin/lucairn up` and the doctor check
  every bound id against the running gateway (counts only); while the gateway
  is not running, `up` warns and does not stop — run the doctor afterwards and
  compare the admin status's bound count with yours.
- **One sanitizer leaf, two users.** The Python sanitizer and the new core
  present the same `material/sanitizer` client certificate to the gateway's
  control listener. Both are the gateway's sanitizer peers with the same right
  (redeem a single-use ticket the gateway minted); the ticket, not the
  certificate, carries the request.
- **The Python `/v1/sanitize` routes serve the v1.0 mode path.** The gateway
  routes that still go to the Python sanitizer's `/v1/sanitize` — OpenAI
  (`/v1/chat/completions`), MCP (`/mcp`) and the native proxy
  (`/api/v1/proxy/messages`) — use that service's 1.0 ServiceNow path for a
  bound key, not the new core's. The Anthropic route (`/v1/messages`) uses the
  core.
- **One gateway.** The session manager lives in one gateway process: the
  overlay pins one gateway container (fixed name, `scale: 1`); the doctor fails
  on a second one. Helm: `replicaCount: 1`, no HPA (render guard) and the
  doctor's live replica count.
- **Helm:** the chart's ServiceNow switch (`global.servicenowControl.enabled`)
  is still held: an enabled production render fails on purpose. The core's
  side (`LCR_PROFILE=kit-servicenow`, the control client, the core → gateway
  NetworkPolicy) is in the chart; the gateway's bindings, stored login and
  ledger volume follow in a later kit slice. Use Compose for the mode until then.
- **Two known Helm ServiceNow defects, to fix before the hold is lifted.**
  Both are latent while the Helm ServiceNow render is held:
  1. With `global.dnsRestriction=true` (Cilium), the core's DNS policy
     `dns-restrict-identity-sanitizer-core` has no entry for
     `gateway-servicenow-control.<edge namespace>.svc.cluster.local`, the
     control peer the core calls, so the core could not resolve it.
  2. The ServiceNow DNS policies (`servicenow-gateway-dns`,
     `servicenow-sandbox-a-dns` in `_servicenow-control.tpl`) select the
     cluster resolver by the hard-coded label `k8s-app: kube-dns` and ignore
     `global.clusterDNS.podLabels`, so on a cluster whose resolver Pods carry
     other labels those Pods could not resolve anything.

### Kit 2.0 — further stated limits (final reads, 2026-11-03)

- **Migration ceilings: witness 10, audit 7.** Kit 2.0.0 keeps the 1.x
  ceilings (veil-witness 10 · audit 7 · id-bridge 4 · sandbox-a 8; the hosted
  Lucairn service runs witness 10 and audit 6). At ceiling 10 the 2.0.0 witness
  logs `durability reduced` at start, the same as on the hosted service: it has
  no certificate persistence outbox and no decoder-expiry columns and writes
  each certificate directly, so a witness crash between accepting and storing a
  certificate can lose that one certificate. The newer migrations (veil-witness
  0011–0014, audit 0008) come with a later kit release.
- **Third-party notices:** kit 2.0.0 ships them in the kit (`licenses/NOTICE`
  and the licence texts in `licenses/`, also in every customer bundle); the
  images carry `NOTICE` from 2.0.1.
- **Doctor, per-request BYOK keys:** a key minted for per-request BYOK (the
  mint default) carries no stored provider key, and the online doctor holds
  none, so its keyed step reports `keyed inference: skipped — per-request BYOK
  install, no provider key for the doctor; run one real turn to check it` (no
  certificate or verification check). Check that journey with one real request
  that carries the provider key.

- **Adopting an existing `customer.env`:** `bin/lucairn-init` in adopt mode
  reads `SANITIZER_CORE_MTLS_HOST_DIR` with a plain text match (the last line
  that starts with `SANITIZER_CORE_MTLS_HOST_DIR=`), not the way Docker Compose
  reads the file: a quoted value, an `export SANITIZER_CORE_MTLS_HOST_DIR=…`
  line (not matched at all) and an inline ` # comment` (taken as part of the
  path) are misread. Write that line plain: `SANITIZER_CORE_MTLS_HOST_DIR=/path`,
  unquoted, no `export`, no comment on the same line.
- **Doctor claim checks read container logs.** After Docker rotates or prunes
  the logs, a state in which the core dropped claims earlier can pass the
  check; the release rehearsal's real turn is the proof of arrival. The other
  direction is a false FAIL: the core logs its witness transport line
  (`evidence: witness transport mode=…`) once, at boot. Once that line has
  rotated out of the logs, the online doctor (Compose: "the core's log shows no
  witness transport line"; Helm live: the same text under "sanitizer core
  (live)") fails a healthy core. Recreating the core writes the line again.
- **Helm migration Job:** each `helm install` / `helm upgrade` creates
  `sanitizer-core-migrate-r<revision>` and removes the previous revision's Job
  (it carries no hook or keep annotation). Do not delete the CURRENT Job by
  hand: the live doctor reads it, and without it fails with "no
  sanitizer-core-migrate Job found" until the next `helm upgrade` creates one.
- **`bundle verify` checks the ServiceNow update set against the bundle's own
  `PROVENANCE` record:** that proves the files were not changed inside the
  bundle (integrity), not who made the bundle.
- **Support bundle:** its secret scan does not cover secrets that live only in
  files (`login.json`, the mTLS keys); no collector reads those files today.

## Sanitizer content cache (Redis — default ON)

The sanitizer ships with a dedicated Redis content-address cache
(`redis-sanitizer-cache`) that remembers redaction results for identical
input segments. Cache hits skip the Presidio L1/L2 scanner pipeline
entirely, cutting per-cached-segment latency from ~500ms to <50ms.

The cache is **fail-open**: when Redis is unavailable (pod restart,
OOMKill, network blip) the sanitizer falls back to computing fresh per
request — no 500 errors, no cert failures.

### Compose path

`redis-sanitizer-cache` ships in `docker-compose.customer.yml` and starts
automatically with the default stack. No extra steps required.

To disable (fall back to per-worker in-process LRU):

```bash
# In customer.env
SANITIZER_CACHE_BACKEND=memory
```

### Kubernetes (Helm) path

`sanitizerCache.enabled` controls whether the **bundled** `redis-sanitizer-cache`
StatefulSet is deployed. It is independent of `sanitizerCache.backend`, which
controls which cache backend the sanitizer process uses.

Enabled by default (`sandbox-a.sanitizerCache.enabled: true`). To fall back to
per-worker in-process LRU (no Redis at all):

```yaml
sandbox-a:
  sanitizerCache:
    enabled: false   # disables bundled StatefulSet
    backend: "memory"
```

To point at an **external** Redis (skip the bundled StatefulSet, use your own):

```yaml
sandbox-a:
  sanitizerCache:
    enabled: false        # disables the bundled StatefulSet
    backend: "redis"      # sanitizer still uses Redis — just not the bundled one
    redisUrl: "redis://my-redis.infra.svc.cluster.local:6379/2"
```

---

## Sanitizer streaming state (Redis — default ON)

**This section only matters if you serve Anthropic-SSE streaming responses
through Lucairn (i.e. your application uses the streaming path).**

The sanitizer runs N=4 gunicorn workers. For a streaming response, the gateway
POSTs each SSE chunk (`content_block_delta`) as an **independent** HTTP request
that gunicorn load-balances arbitrarily. Without a shared backend, each chunk
may land on a different worker whose `PlaceholderRegistry` is empty — the
registry drift causes alignment-bail fail-closed on the very next chunk (~88%
FAIL-CLOSED observed on the Lucairn pilot before this fix — DSA PR #267).

The streaming state backend shares the **same `redis-sanitizer-cache` Redis**
as the content cache (`sandbox-a.sanitizerCache`), using a distinct
`tms:stream:*` / `tms:streamlock:*` / `tms:streammut:*` key prefix so the two
never collide with each other or with the DP-budget namespace on the other
Redis instance.

### Cert-integrity constraint: marker TTL must exceed state TTL

`sandbox-a.sanitizerStreamState.mutationMarkerTtlSeconds` (default 600) MUST
be **strictly greater** than `sanitizerStreamState.ttlSeconds` (default 300).
Default (unset) marker TTL = `max(2 × ttlSeconds, ttlSeconds + 60)`. If you
set it explicitly and it is ≤ `ttlSeconds`, the sanitizer clamps it up to
`ttlSeconds + 60` at boot and logs a warning. The mutation marker outlives
the stream state so the gateway can detect mid-stream fresh-state resets that
would produce a cert with renumbered placeholders (cert-integrity violation).
Raise both TTLs proportionally when serving very long streaming responses.

### Compose path

The streaming state backend is wired automatically in `docker-compose.customer.yml`
(all four `SANITIZER_STREAM_STATE_*` vars are set with safe defaults pointing at the
same `redis-sanitizer-cache` service as the content cache).
No extra steps required.

To fall back to the per-worker in-process store (emergency revert — accepts
streaming FAIL-CLOSED risk), add to `customer.env`:

```bash
# In customer.env
SANITIZER_STREAM_STATE_BACKEND=memory
```

### Kubernetes (Helm) path

`sandbox-a.sanitizerStreamState.backend` defaults to `"redis"` and points at
the same bundled `redis-sanitizer-cache` StatefulSet as the content cache.
No extra steps required on a default install.

To fall back to the per-worker in-process store (emergency revert):

```yaml
sandbox-a:
  sanitizerStreamState:
    backend: "memory"   # WARNING: causes ~88% streaming FAIL-CLOSED under gunicorn
```

To point at an **external** Redis (when `sanitizerCache.enabled=false`):

```yaml
sandbox-a:
  sanitizerStreamState:
    backend: "redis"
    redisUrl: "redis://my-redis.infra.svc.cluster.local:6379/0"  # must match sanitizerCache.redisUrl
    ttlSeconds: 300
    mutationMarkerTtlSeconds: 600  # MUST be strictly > ttlSeconds
```

---

## Support Bundle

If installation fails, generate a bundle:

```bash
bin/lucairn support-bundle --env customer.env --compose docker-compose.customer.yml
```

Review the archive before emailing it to Lucairn support.

## Customer Bundle Install

Use this path when Lucairn has prepared a customer-specific bundle. The trusted
packaging/handoff station verifies the exact tarball before sending it. On the
clean customer host, S1 requires a separately supplied SHA256 checksum through
the approved authenticated handoff channel before raw extraction; it does not
yet provide completed publisher authentication.

1. Compare the tarball's digest with the separately supplied handoff checksum
   before extracting anything. Do not use `bin/lucairn` copied from inside the
   unverified archive for this gate.

```bash
shasum -a 256 lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
```

Match the printed digest byte-for-byte to the value received through that
channel. Stop if it differs.

2. Only after that checksum gate, extract the bundle and verify its internal
   layout/checksum contract.

```bash
tar -xzf lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
cd lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ
bin/lucairn bundle verify --bundle .
```

This post-extraction check is not a replacement for the separately supplied
checksum gate above.

3. Follow the image-delivery section in the generated `INSTALL-CUSTOMER.md`.

Archive delivery names the archive to load only after the bundle check. Registry
delivery requires registry authentication and must not run `docker load`.
Directory delivery must use the authenticated handoff instructions for the
actual files under `images/`; it must not assume an archive exists.

3b. Kit 2.0 bundles: create the sanitizer core's mTLS material and registry DSN
   file on this host (neither travels in the bundle; `install/customer.env`
   already names `install/.certs/sanitizer-core-mtls` and
   `install/.secrets/sanitizer-core/registry-dsn`). `install/customer.env`
   itself travels in the bundle as-is, with its passwords
   (`POSTGRES_SANITIZER_CORE_PASSWORD` and the others): protect the bundle like
   the env file. `bin/lucairn up` later runs the capped registry migration
   itself.

```bash
sudo scripts/bootstrap-sanitizer-core-mtls.sh "$PWD/install/.certs/sanitizer-core-mtls"
scripts/write-sanitizer-core-registry-dsn.sh --env-file install/customer.env --compose install/docker-compose.customer.yml
```

4. Run pre-flight checks.

```bash
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml --offline --skip-image-check
```

5. Start the mode recorded for this bundle.

Use the exact mode-specific Compose command in the generated
`INSTALL-CUSTOMER.md` at the bundle root. S1 bundles include
`install/customer.env.runtime-profile.yaml` and the recorded
`install/customer.env.image-manifest.yaml`; split bundles intentionally omit
self-hosted overlays, and managed-BYOK bundles require their BYOK overlay.
There is no single fixed Compose command that is correct for every bundle.

6. Confirm health.

```bash
curl -fsS http://127.0.0.1:8085/healthz
curl -fsS http://127.0.0.1:8085/readyz
```

## Clean-Host Rehearsal

Before sending a first customer bundle, repeat the customer-bundle path on a clean Linux host or VM that has no repo checkout, no local Docker images, and no copied secrets except the exact handoff bundle (plus the GitHub PAT used to authenticate against ghcr.io, or the matching private-mirror credentials if the customer mirrors the images). Record the transcript against `docs/CLEAN_HOST_REHEARSAL.md`.

## Enable the Lucairn dashboard (optional)

The Lucairn Enterprise Dashboard is an opt-in operator UI that ships
alongside the core stack. It is **not required to operate the kit** — every
day-2 task can still be driven from `bin/lucairn` and Grafana. Operators
who want a first-party UI for cert workflows, server health, audit log
inspection, compliance PDF export, and API key management can enable it.

Bundled in this kit version: dashboard auth + shell foundation +
optional OIDC SSO + cert browser, cert inspector, audit-defensibility-grade
live validator, server health overview, embedded Grafana dashboards,
API key management, audit log browser, AND compliance PDF export.
The v1.0-dashboard arc is feature-complete.

### Compose path

1. Set the dashboard env vars in `customer.env` (uncomment the
   `LUCAIRN_DASHBOARD_*` block at the end of `customer.env.example` and
   populate `LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD` with a 12+ character
   secret you generated locally via `openssl rand -base64 24`).
2. Run `bin/lucairn doctor --offline` — the dashboard pre-flight check exits with a
   clear error if the bootstrap password is missing or too short.
3. Start the dashboard container alongside the core stack:

   ```bash
   docker compose \
     -f docker-compose.customer.yml \
     --env-file customer.env \
     --profile dashboard \
     up -d lucairn-dashboard
   ```

   (Add `-f docker-compose.self-hosted.yml` only when running a
   self-hosted-inference install; add `-f docker-compose.self-hosted-byok.yml`
   when running with the BYOK overlay. Split-deployment customers should
   use only `docker-compose.customer.yml` as shown above.)

4. Confirm health: `curl -fsS http://127.0.0.1:8443/healthz` returns
   `{"status":"ok","version":"..."}`. The container binds only to
   loopback; front it with your TLS-terminating reverse proxy (Caddy /
   Nginx / Traefik) before exposing it externally.

5. First login: open `https://<your-front-proxy>/login`, enter the
   bootstrap email + the password you set in step 1.

### Kubernetes path

1. Set `dashboard.enabled: true` in your `customer-values.yaml` (or
   `--set dashboard.enabled=true` on the install command).
2. Apply (same `$DOCKER_CONFIG`-staged session as § "Kubernetes
   Install"):

   ```bash
   helm upgrade --install lucairn charts/lucairn \
     -f customer-values.yaml \
     --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json" \
     --namespace lucairn --create-namespace
   ```

3. Retrieve the bootstrap password (Helm-generated random 32-char):

   ```bash
   kubectl -n lucairn get secret lucairn-dashboard-bootstrap-admin \
     -o jsonpath='{.data.password}' | base64 -d
   ```

4. Port-forward + login:

   ```bash
   kubectl -n lucairn port-forward svc/lucairn-dashboard 8443:8443
   ```

   Open `http://localhost:8443/login`. The dashboard container serves
   plain HTTP on port 8443 internally; TLS termination is handled by
   your ingress (Kubernetes Ingress, kube-proxy, or the Compose-path
   Caddy/nginx fronting), not by the dashboard binary. The default
   email is `admin@lucairn.local` (override with
   `dashboard.bootstrapAdmin.email`).

5. Run the dashboard-specific doctor check via the kit CLI:

   ```bash
   DOCTOR_INCLUDE_DASHBOARD=1 bin/lucairn doctor \
     --env customer.env \
     --compose docker-compose.customer.yml --offline
   ```

### Rotating the bootstrap password

See `OPS.md` § "Dashboard: bootstrap admin + rotate credentials".

### Optional: enable OIDC SSO

OIDC single sign-on is opt-in. When enabled, the dashboard renders a
"Sign in with SSO" button on `/login` next to the local-admin form.
Local-admin sign-in continues to work for bootstrap + IdP-outage
scenarios — there is no way to disable it in this release.

Group → role mapping (LOCKED):

- User in the admin group → `RoleAdmin` (full access).
- User in the viewer group → `RoleViewer` (read-only).
- User in BOTH groups → `RoleAdmin` wins.
- User in NEITHER group → rejected with HTTP 401. Customers must
  explicitly authorize identities at the IdP. The dashboard does NOT
  auto-grant viewer to arbitrary directory users.

#### Compose path

1. Populate the `LUCAIRN_DASHBOARD_OIDC_*` block in `customer.env`. At
   minimum set `LUCAIRN_DASHBOARD_OIDC_ENABLED=true` and the issuer URL,
   client ID, client secret, admin group, viewer group, and public URL.
2. Recreate the dashboard container:

   ```bash
   docker compose \
     -f docker-compose.customer.yml \
     --env-file customer.env \
     --profile dashboard \
     up -d --force-recreate lucairn-dashboard
   ```

3. Verify: open `https://<your-front-proxy>/login`. The "Sign in with
   SSO" button should appear below the local form. Click it; you are
   redirected to the IdP, complete the sign-in, and land on
   `/dashboard`.

The dashboard runs OIDC discovery against the issuer URL at startup. If
the IdP is unreachable, the container fails-fast — the readiness probe
flips to unready and the operator sees the discovery error in the
container logs. This is the locked failure mode (no silently-broken
SSO).

#### Kubernetes path

1. Pre-create the OIDC client_secret Secret in the lucairn namespace:

   ```bash
   # The value goes on kubectl's standard input, never on its command line
   # (any local user can read a process's argument list; printf is a builtin).
   printf '%s' '<your-idp-client-secret>' \
     | kubectl -n lucairn create secret generic lucairn-dashboard-oidc \
       --from-file=client-secret=/dev/stdin
   ```

2. Add the OIDC block to your `customer-values.yaml`:

   ```yaml
   dashboard:
     enabled: true
     oidc:
       enabled: true
       issuerURL: "https://idp.example.com/realms/lucairn"
       clientID: "lucairn-dashboard"
       clientSecretRef:
         name: lucairn-dashboard-oidc
         key: client-secret
       adminGroup: lucairn-admins
       viewerGroup: lucairn-viewers
       groupsClaim: groups        # optional; default "groups"
       publicURL: "https://dashboard.customer.example"
       # callbackURL: ""           # pin explicitly when the registered URL differs
   ```

3. Apply (same `$DOCKER_CONFIG`-staged session as § "Kubernetes
   Install"):

   ```bash
   helm upgrade --install lucairn charts/lucairn \
     -f customer-values.yaml \
     --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json" \
     --namespace lucairn --create-namespace
   ```

4. Confirm the rollout: `kubectl -n lucairn rollout status deploy/lucairn-dashboard`
   completes within 60s once OIDC discovery succeeds. The OIDC button is
   live as soon as the pod is Ready.

#### Rotating the OIDC client secret

See `OPS.md` § "Dashboard: rotating the OIDC client secret".

### Audit DB + Witness wiring (cert browser + inspector)

The cert browser, cert inspector, and audit-defensibility-grade live
validator are OPT-IN. When the audit DB and witness gRPC endpoint are
unset, the cert pages render a "not configured" explainer and the rest
of the dashboard (auth + shell + OIDC) keeps working. To enable the
cert surface, pre-create a read-only Postgres role + (Kubernetes only)
a Secret holding the libpq URL, then point the dashboard at it.

Locked posture:

- Dashboard never writes to the audit DB.
- The DB user holds SELECT on `veil_certificates` ONLY. No INSERT,
  UPDATE, DELETE, DDL.
- Both admin and viewer roles can browse + re-verify certs.
  (Cert-browser role differentiation is reserved for a future kit
  release; the `/keys` API key management surface is admin-only in
  this release.)
- Bulk re-verify caps each job at 100 certs and rate-limits the
  witness gRPC channel to 10 calls per second.

#### Pre-create the read-only Postgres role

Run as the audit DB owner (the kit's `dsa` superuser via Compose, or
your DBA via Kubernetes):

```sql
CREATE ROLE lucairn_dashboard_ro WITH LOGIN PASSWORD '<generate>';
GRANT CONNECT ON DATABASE dsa TO lucairn_dashboard_ro;
GRANT USAGE ON SCHEMA public TO lucairn_dashboard_ro;
GRANT SELECT ON veil_certificates TO lucairn_dashboard_ro;
```

#### Compose path

1. Add the cert browser env block to `customer.env` (the
   `LUCAIRN_DASHBOARD_AUDIT_DB_URL` + `LUCAIRN_DASHBOARD_WITNESS_ENDPOINT`
   block at the end of `customer.env.example`):

   ```bash
   LUCAIRN_DASHBOARD_AUDIT_DB_URL=postgres://lucairn_dashboard_ro:<password>@postgres-bridge:5432/dsa?sslmode=require
   LUCAIRN_DASHBOARD_WITNESS_ENDPOINT=veil-witness:50058
   ```

2. Run `bin/lucairn doctor --offline` — the new `dashboard certs:` pre-flight
   check exits with a clear error if the DB URL scheme is wrong, the
   witness endpoint is missing a port, or only one of the pair is set.

3. Recreate the dashboard container:

   ```bash
   docker compose \
     -f docker-compose.customer.yml \
     --env-file customer.env \
     --profile dashboard \
     up -d --force-recreate lucairn-dashboard
   ```

4. Verify: open `https://<your-front-proxy>/certs`. The browser lists
   the certs that match the empty filter (most recent first).

#### Kubernetes path

1. Pre-create the audit DB Secret:

   ```bash
   # The connection string carries the password, so it goes on kubectl's
   # standard input, never on its command line (any local user can read a
   # process's argument list; printf is a builtin).
   printf '%s' 'postgres://lucairn_dashboard_ro:<password>@postgres-bridge:5432/dsa?sslmode=verify-full' \
     | kubectl -n lucairn create secret generic lucairn-dashboard-audit-db \
       --from-file=connection-string=/dev/stdin
   ```

2. Wire the cert surface in `customer-values.yaml`:

   ```yaml
   dashboard:
     enabled: true
     auditDB:
       connectionStringRef:
         name: lucairn-dashboard-audit-db
         key: connection-string
     witness:
       endpoint: "veil-witness.dsa-witness.svc.cluster.local:50058"
   ```

3. Apply (same `$DOCKER_CONFIG`-staged session as § "Kubernetes
   Install"):

   ```bash
   helm upgrade --install lucairn charts/lucairn \
     -f customer-values.yaml \
     --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json" \
     --namespace lucairn
   ```

4. Confirm the rollout: `kubectl -n lucairn rollout status deploy/lucairn-dashboard`.
   Cert browser is live as soon as the pod is Ready.

#### Rotating the audit DB credentials

See `OPS.md` § "Dashboard: rotating audit DB credentials".

### Enable server health + Grafana embedding

The dashboard's `/health` surface is ALWAYS-ON by default — it polls
the 12 standard kit services every 10 seconds and renders a card
grid with per-service status pills (Healthy / Degraded / Down /
Polling…). Operators who want a custom service list set
`LUCAIRN_DASHBOARD_HEALTH_SERVICES` (or the matching Helm value)
to a comma-separated `name=url` spec; see
`apps/dashboard/internal/health/services.go` for the bundled
default + URL syntax (`http://`, `https://`, `tcp://`).

Embedded Grafana panels are OPT-IN. When enabled, the dashboard
signs a fresh HS256 JWT (60-second TTL) per panel-render request
and the iframe authenticates via the documented Grafana
[`auth.jwt`] mechanism (`auth_token` URL-login query parameter).
The SAME shared secret is consumed by both the dashboard pod
(via `LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET`) and the Grafana pod
(mounted as `/etc/grafana/jwt/shared-secret` + read via
`GF_AUTH_JWT_KEY_FILE`).

> **Both sides must be flipped together.** Setting
> `dashboard.grafana.endpoint` (or `LUCAIRN_DASHBOARD_GRAFANA_URL`)
> WITHOUT also enabling `observability.grafana.auth.jwt.enabled` on
> the Helm path (or configuring `[auth.jwt]` in Grafana on the
> Compose path) causes the embedded iframe to land on Grafana's
> login screen instead of authenticating via the signed JWT. The
> Helm path catches this at render time with a `fail` template
> guard. The Compose path is
> validated by `bin/lucairn doctor`'s `dashboard grafana:` probe
> + the soft `/api/datasources/proxy/*` reachability check.

#### Compose path

1. Add the server health + Grafana block to `customer.env`:

   ```bash
   LUCAIRN_DASHBOARD_GRAFANA_URL=https://grafana.lucairn.local
   LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET=$(openssl rand -hex 24)  # 48-char hex
   LUCAIRN_DASHBOARD_GRAFANA_PANEL_GATEWAY_THROUGHPUT_UID=<uid>
   LUCAIRN_DASHBOARD_GRAFANA_PANEL_SANITIZER_HIT_RATES_UID=<uid>
   LUCAIRN_DASHBOARD_GRAFANA_PANEL_WITNESS_VERIFY_RATE_UID=<uid>
   LUCAIRN_DASHBOARD_GRAFANA_PANEL_AUDIT_LOG_VOLUME_UID=<uid>
   ```

   Panel UIDs come from Grafana → Edit Dashboard → Share → UID.
   Empty UIDs render a "panel not configured" placeholder in the
   side drawer without breaking the rest of `/health`.

2. Configure Grafana with `[auth.jwt]`. A minimal `grafana.ini`
   block (mount as a ConfigMap or set via env vars):

   ```ini
   [security]
   allow_embedding = true

   [auth.jwt]
   enabled = true
   url_login = true
   key_file = /etc/grafana/jwt/shared-secret
   username_claim = email
   email_claim = email
   auto_sign_up = true
   expect_claims = {"iss": "lucairn-dashboard", "aud": "grafana"}
   ```

   Mount the same shared secret as a single-line file at
   `/etc/grafana/jwt/shared-secret`.

3. Run `bin/lucairn doctor --offline` — the new `dashboard grafana:` pre-flight
   surfaces invalid URL schemes, sub-32-character secrets, and
   reachability problems.

4. Recreate the dashboard container:

   ```bash
   docker compose -f docker-compose.customer.yml \
     --env-file customer.env --profile dashboard \
     up -d --force-recreate lucairn-dashboard
   ```

5. Verify: open `/health` while logged in. Click any service card →
   side drawer opens → embedded Grafana panel renders without a
   Grafana login screen.

#### Kubernetes path

1. (Optional — recommended) Set `dashboard.grafana.jwt.secretName`
   empty so Helm generates a 48-char shared secret in a Secret
   named `lucairn-dashboard-grafana-jwt`. The `lookup` pattern in
   the template preserves the value across `helm upgrade`.

   The dashboard sub-chart auto-renders the SAME Secret in BOTH the
   dashboard namespace (`dashboard.namespace`, default `lucairn`)
   AND the observability namespace (`global.observabilityNamespace`,
   default `dsa-observability`). K8s Secrets are namespace-scoped,
   so without the cross-namespace mirror the Grafana pod would
   crashloop with `CreateContainerConfigError: secret
   "lucairn-dashboard-grafana-jwt" not found`. Customers running a
   non-default observability namespace MUST set
   `global.observabilityNamespace` to match. Operators who supply
   their own Secret (set `dashboard.grafana.jwt.secretName`) take
   over the cross-namespace duplication themselves.

2. Wire Grafana embedding + the observability sub-chart's JWT mode
   in `customer-values.yaml`:

   ```yaml
   dashboard:
     enabled: true
     grafana:
       endpoint: "https://grafana.lucairn.local"
       panels:
         gatewayThroughputUID: "<uid>"
         sanitizerHitRatesUID: "<uid>"
         witnessVerifyRateUID: "<uid>"
         auditLogVolumeUID: "<uid>"

   observability:
     enabled: true
     grafana:
       auth:
         jwt:
           enabled: true
           secretRef:
             # Match the dashboard sub-chart's auto-generated Secret name.
             name: lucairn-dashboard-grafana-jwt
             key: shared-secret
   ```

3. Apply (same `$DOCKER_CONFIG`-staged session as § "Kubernetes
   Install"):

   ```bash
   helm upgrade --install lucairn charts/lucairn \
     -f customer-values.yaml \
     --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json" \
     --namespace lucairn
   ```

4. Confirm both rollouts: `kubectl -n lucairn rollout status
   deploy/lucairn-dashboard` + `kubectl -n dsa-observability
   rollout status deploy/grafana`.

5. Verify same as Compose step 5 above.

#### Rotating the Grafana JWT shared secret

See `OPS.md` § "Rotating the Grafana JWT shared secret".

### Enable API key management

The dashboard's `/keys` surface lets an admin operator mint,
rotate, revoke, and bulk-revoke `lcr_live_*` API keys against the
gateway's existing admin HTTP API. The endpoint lives on the same
gateway listener as the data plane (mounted under
`/api/v1/admin/`) and is authenticated with the gateway's
`DSA_ADMIN_KEY` constant-time-compared bearer token.

> **`/keys` is admin-only.** Viewers reach the route only via direct
> URL typing and receive a `404 Not Found` (the dashboard's
> `RequireRole` middleware deliberately returns 404 rather than 403
> to avoid disclosing route existence to non-admin sessions; see
> `apps/dashboard/internal/auth/middleware.go`). Plaintext keys
> are shown ONCE on the post-mint modal with
> `Cache-Control: no-store + Pragma: no-cache + Referrer-Policy:
> no-referrer` headers so the value never enters intermediary caches,
> browser back-button history, or referrer logs.

#### Compose path

1. Add the API key management block to `customer.env`:

   ```bash
   LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL=http://gateway:8080
   LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN=<your DSA_ADMIN_KEY value>
   ```

   The dashboard container resolves `http://gateway:8080` via the
   compose DNS network — no host-side ingress is required.

2. Run `bin/lucairn doctor --offline` — the new `dashboard keys:` pre-flight
   surfaces invalid URL schemes, placeholder tokens, gateway
   unreachability, and admin-token rejection (`401`).

3. Recreate the dashboard container:

   ```bash
   docker compose -f docker-compose.customer.yml \
     --env-file customer.env --profile dashboard \
     up -d --force-recreate lucairn-dashboard
   ```

4. Verify: log into the dashboard as admin → click the
   "API keys" sidebar entry → mint a test key → copy the plaintext
   from the modal → exchange the key against the gateway with
   `printf 'X-API-Key: %s\n' '<minted-key>' | curl -H @- https://<gateway-host>/v1/messages …`
   (the header goes on curl's standard input, never on its command line —
   any local user can read a process's argument list).

#### Kubernetes path

1. Pre-create the Secret carrying the admin token. The Secret name +
   key the dashboard sub-chart consumes are
   `lucairn-dashboard-gateway-admin` + `admin-token` by default;
   override via `dashboard.gateway.adminTokenSecretRef.{name,key}`.

   ```bash
   # $DSA_ADMIN_KEY holds the gateway's DSA_ADMIN_KEY value. The token goes
   # on kubectl's standard input, never on its command line (any local user
   # can read a process's argument list; printf is a shell builtin).
   printf '%s' "$DSA_ADMIN_KEY" \
     | kubectl -n lucairn create secret generic lucairn-dashboard-gateway-admin \
       --from-file=admin-token=/dev/stdin
   ```

2. Wire `dashboard.gateway.*` in `customer-values.yaml`:

   ```yaml
   dashboard:
     enabled: true
     gateway:
       adminURL: "http://gateway.lucairn.svc.cluster.local:8080"
       adminTokenSecretRef:
         name: lucairn-dashboard-gateway-admin
         key: admin-token
   ```

   The umbrella chart's render-time validator catches the half-wired
   case (URL set, secretRef.name empty) at `helm install/upgrade`
   time so the dashboard pod never boots into a 401-rain state.

3. Apply (same `$DOCKER_CONFIG`-staged session as § "Kubernetes
   Install"):

   ```bash
   helm upgrade --install lucairn charts/lucairn \
     -f customer-values.yaml \
     --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json" \
     --namespace lucairn
   ```

4. Confirm the rollout + the new env vars are injected:

   ```bash
   kubectl -n lucairn rollout status deploy/lucairn-dashboard
   kubectl -n lucairn exec deploy/lucairn-dashboard -- env | \
     grep LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL
   ```

5. Verify same as Compose step 4 above.

#### Bootstrapping the first customer

If the gateway keystore has zero customers, the `/keys` page renders
an empty-state pointing here. Mint your first customer via the
kit's helper:

```bash
export LUCAIRN_ADMIN_KEY="$(grep '^DSA_ADMIN_KEY=' customer.env | cut -d= -f2-)"
./bin/lucairn-mint-customer --name "Acme GmbH" --email "ops@acme.de" --tier enterprise
```

Reload `/keys` and the new customer appears in the auto-detected
selector (single-customer installs hide the selector entirely).

#### Rotating the gateway admin token

See `OPS.md` § "Rotating the gateway admin token".

### Enable audit log browser

The dashboard's `/audit` surface is OPT-IN. When enabled, both viewer
and admin roles can filter / page / save filters / export the audit
event stream from the customer-side `postgres-audit` instance. PII is
redacted in the default render; an admin can "Reveal raw" per event,
which emits a paired `audit.reveal_raw` event into the same audit log.

**IMPORTANT**: this connection points at `postgres-audit` (the audit
EVENT log), NOT `postgres-bridge` (the cert log that
`LUCAIRN_DASHBOARD_AUDIT_DB_URL` configures for the cert browser).
The two are independent databases with independent Postgres roles.
The dashboard reads both at runtime through DISTINCT env vars:

- `LUCAIRN_DASHBOARD_AUDIT_DB_URL`     → cert browser
- `LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL` → audit log browser

#### Saved-filter table migration (required for per-user dropdowns)

The audit-log browser persists per-user filter dropdowns in a new
`dashboard_saved_filters` table. Apply the migration BEFORE enabling
the surface (or after, if you don't mind the surface rendering an
"apply the migration" banner until you do):

```bash
# Runs psql inside the postgres-audit container via `docker compose exec`.
# Auths over the container's local Unix socket — no password is needed
# (the rotated POSTGRES_PASSWORD from customer.env is ONLY consumed for
# network connections; container-local exec is socket-trusted). The
# `dsa` superuser is the container default (POSTGRES_USER=dsa). Stack
# must be up (`docker compose up -d`) so postgres-audit is running.
docker compose \
  -f docker-compose.customer.yml \
  --env-file customer.env \
  exec -T postgres-audit \
  psql -U dsa -d audit \
  < apps/dashboard/migrations/000001_create_saved_filters.up.sql
```

The migration grants INSERT/SELECT/UPDATE/DELETE on the new table to
the existing `audit_app` role (the same role the dashboard connects
as for reading `audit_events`). Operators uncomfortable widening the
role can instead pre-create a separate `dashboard_app` role with
grants on `dashboard_saved_filters` only and wire its connection
string via `LUCAIRN_DASHBOARD_AUDIT_LOG_SAVED_FILTERS_DB_URL`.

#### Compose path

Edit `customer.env`:

```bash
LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL=postgres://audit_app:CHANGE_ME@postgres-audit:5432/audit?sslmode=disable
# Optional — separate role for saved filters:
# LUCAIRN_DASHBOARD_AUDIT_LOG_SAVED_FILTERS_DB_URL=postgres://dashboard_app:...@postgres-audit:5432/audit
```

Restart the dashboard container:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env --profile dashboard up -d --force-recreate lucairn-dashboard
```

Verify `bin/lucairn doctor --offline` returns green for `dashboard audit-log`:

```bash
./bin/lucairn doctor --offline
```

#### Kubernetes path

Pre-create the Secret holding the libpq connection string:

```bash
# The URL carries the password, so it goes on kubectl's standard input, never
# on its command line (any local user can read a process's argument list).
printf '%s' 'postgres://audit_app:REAL_PASSWORD@postgres-audit:5432/audit?sslmode=disable' \
  | kubectl -n lucairn create secret generic lucairn-dashboard-audit-log \
    --from-file=url=/dev/stdin
```

Then update `customer-values.yaml`:

```yaml
dashboard:
  enabled: true
  audit:
    auditLogDBConnectionStringRef:
      name: lucairn-dashboard-audit-log
      key: url
```

Apply (same `$DOCKER_CONFIG`-staged session as § "Kubernetes Install"):

```bash
helm upgrade --install lucairn ./charts/lucairn \
  -f customer-values.yaml \
  --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json"
```

#### Rotating the audit log DB credentials

See `OPS.md` § "Rotating the audit log DB credentials".

#### Reveal raw audit event payload

The admin "Reveal raw" button on the `/audit/{event_id}` detail page
returns the unredacted payload AND emits a paired
`audit.reveal_raw` event into the same `audit_events` table. The
event payload identifies the operator who clicked, the target event,
the target's source service, and the target's `request_id`. This
closes the compliance loop — auditors can answer "who unmasked
event X" by filtering for `event_type=audit.reveal_raw` with the
target_event_id matching.

The CSV export endpoint also supports `?reveal=true` for admins. The
endpoint emits an `audit.csv_export_with_reveal` event BEFORE the
stream begins so the audit trail captures bulk reveals even if the
client disconnects mid-stream.

### Compliance PDF export

The dashboard's `/compliance` surface is ADMIN-ONLY and ALWAYS-ON
when the dashboard is enabled. There is NO opt-in env var. An admin
picks a date range + a customer name, clicks Generate PDF, and the
dashboard streams a PDF download. The PDF carries:

- Cover page: customer name, date range, kit version, dashboard
  version, generated timestamp, AND the pinned image-manifest the
  kit shipped with (every service + its tag).
- Category 1 (Art. 10 + 15 sanitizer): total sanitizer event count
  + per-detection-layer breakdown (L1 / L2 / L3 / unknown).
- Category 2 (Art. 12 + 14 evidence): total certificate count +
  per-verdict breakdown.
- Category 3 (Art. 10 + 12 + 14 + 15 inventory): total audit-event
  count + per-event-type breakdown.

The aggregator reuses the dashboard's existing DB pool connections —
the cert DB pool for Category 2's cert counts, the audit-log DB pool
for Category 1 + 3 sanitizer-event + audit-event counts. Neither
populates anything if the corresponding surface env var is empty;
the PDF still generates with "(no rows recorded in this window)"
placeholder copy.

#### Render-time banned-literal guard

The PDF generator funnels every text-emit through a render-time
banned-literal scanner. The corpus matches the project's locked
mechanism-allowlist set. If a literal appears anywhere — in the
customer name, in the kit version, in an aggregated count label —
the handler returns HTTP 500 with `PDF generation failed` and ZERO
PDF bytes touch the wire. This is the same fail-closed pattern the
admin "Reveal raw" audit flow follows.

#### Audit emit on every PDF generation

Every successful PDF generation emits an
`audit.compliance_pdf_generated` event into the audit-log DB (when
configured). Payload carries the actor email, the customer name,
the window endpoints, the page count, the byte size, and the
aggregated cert / sanitizer / audit counts so future audits can
correlate the PDF artefact back to the exact window scanned.

When the audit-log DB is configured (`LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL`
set), the handler fail-closes if the DB INSERT fails (DB unreachable
mid-export, role grant missing): returns 500 + ZERO PDF bytes — the
dashboard refuses to surface evidence content without a matching audit
row. In dev installs without the audit-log DB wired, the LogEmitter
fallback always returns nil and PDF generation proceeds; the audit row
lands only in pod logs. Configure the DB URL for the fail-closed
guarantee before any customer hand-off.

#### Configuration

Two optional knobs control the surface; both have safe defaults.

Compose path (in `customer.env`):

```bash
# Optional — cap the date-range span; defaults to 365 days.
#LUCAIRN_DASHBOARD_COMPLIANCE_MAX_WINDOW_DAYS=365

# Optional — pre-populate the form's customer-name input.
#LUCAIRN_DASHBOARD_COMPLIANCE_DEFAULT_CUSTOMER_NAME=Acme Corp GmbH
```

Kubernetes path (in `customer-values.yaml`):

```yaml
dashboard:
  enabled: true
  compliance:
    maxWindowDays: 365
    defaultCustomerName: ""
```

The `bin/lucairn doctor` adds a `check_dashboard_compliance` probe
that rejects banned-literal values in `DEFAULT_CUSTOMER_NAME` and
out-of-range `MAX_WINDOW_DAYS` values before the dashboard boots.

### Enable demo mode + the per-user demo-data toggle (dashboard 0.8.0+)

The dashboard ships with an opt-in demo path so a customer-IT or
operator can show the dashboard fully populated WITHOUT standing up
postgres-bridge + postgres-audit + the gateway admin HTTP API. Two
independent knobs, both OFF by default:

1. `LUCAIRN_DASHBOARD_DEMO_MODE=true` swaps the real cert / audit /
   saved-filters / admin-client stores for in-memory fixtures at boot
   time (50 synthetic certs, ~300 audit events, 3 customers + keys).
   Every surface renders populated. CSV export of certs + witness
   Verify degrade to friendly errors. **NOT FOR PRODUCTION** — leave
   UNSET on any install that talks to a real Lucairn stack.
2. `LUCAIRN_DASHBOARD_DEMO_TOGGLE_ENABLED=true` exposes a per-user
   `Live ◯○ Demo` switch in the dashboard home-page header. Cookie-
   scoped (`lucairn_dash_demo_view`, 30-day TTL, HttpOnly+Secure+Lax)
   so each signed-in user has their own preference. Auto-enabled when
   `LUCAIRN_DASHBOARD_DEMO_MODE=true` is also set.

Compose path (in `customer.env`):

```ini
LUCAIRN_DASHBOARD_ENABLED=true
LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD=<rotated value>
# Demo paths (both default to OFF):
LUCAIRN_DASHBOARD_DEMO_MODE=true
LUCAIRN_DASHBOARD_DEMO_TOGGLE_ENABLED=true
# Optional — pre-populate the compliance form's customer-name field
# so the demo PDF cover renders a stable label (matches the fixture
# data in apps/dashboard/internal/compliance/templates/cover_test.go):
LUCAIRN_DASHBOARD_COMPLIANCE_DEFAULT_CUSTOMER_NAME=Acme Corp GmbH
```

Run the dashboard standalone (no core stack required in demo mode):

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env \
  --profile dashboard up -d lucairn-dashboard
```

In demo mode the core stack (gateway, postgres, sanitizer) does NOT
need to be running — the dashboard boots standalone with in-memory
fixture data. Open `http://localhost:8443/login` and sign in with the
bootstrap email + password.

Kubernetes path (in `customer-values.yaml`):

```yaml
dashboard:
  enabled: true
  demoMode:
    enabled: true        # OFF in production
    toggleEnabled: true  # exposes the header switch on the home page
```

The dashboard logs a clear `DEMO MODE: ...` banner at boot when
`LUCAIRN_DASHBOARD_DEMO_MODE=true` is detected, so the operator can
verify which path is active. The dashboard binary refuses to start
demo mode silently — both env vars are independent + greppable in
the pod logs.

## Phase 8 — Per-deployment trust-zone tuning (self-hosted Enterprise)

> **Enterprise self-hosted only.** This feature has no effect on Lucairn-hosted
> Developer or Pro tiers. The hosted pilot's `GATEWAY_TMS_TRUST_ZONES` stays
> unset (operator cannot override it). This tuning affects only YOUR deployment.

### What it is

The Lucairn gateway classifies every request into named segments (system prompt,
user message, tool call, etc.) and assigns each a *trust zone* that controls how
deeply the sanitizer scans it. The built-in defaults are tuned for the broadest
safety baseline. Phase 8 lets a self-hosted Enterprise operator override those
defaults for their whole deployment via a single environment variable or Helm value.

Overrides apply to **all API keys on this deployment** — there is no per-key
granularity in v1.0. The gateway applies the override on every request from the
moment it boots. A `helm upgrade` → pod restart is the apply path (no hot-reload).

### The 9 segment types and their built-in default zones

| Segment type             | Built-in default zone                         |
|--------------------------|-----------------------------------------------|
| `system_prompt`          | `trusted_platform` — **skipped** (not scanned)|
| `platform_metadata`      | `trusted_platform` — **skipped**              |
| `user_content`           | `full_scan` — full PII scan                   |
| `assistant_content`      | `full_scan`                                   |
| `thinking_block`         | `full_scan`                                   |
| `tool_use_input`         | `value_only` — values scanned, keys skipped   |
| `tool_result_content`    | `value_only`                                  |
| `code_block`             | `shallow` — heuristic scan only               |
| `unknown`                | `full_scan` — unknown content scanned in full |

### The 4 trust zones

| Zone               | What the sanitizer does                                      |
|--------------------|--------------------------------------------------------------|
| `trusted_platform` | Skip entirely — no PII scan, no redaction, no cert manifest entry generated |
| `full_scan`        | Full PII scan (all detectors: known-entity + Presidio + optional ML)        |
| `value_only`       | Scan only JSON / structured VALUES, not key names             |
| `shallow`          | Heuristic / pattern-matching scan only (no ML, no Presidio)  |

### Direction and risk

Both STRICTER (e.g. `system_prompt: full_scan`) and WEAKER (e.g.
`tool_result_content: shallow`) than the defaults are allowed. There is no
safety floor — **you own the compliance posture** when weakening below defaults.
Lucairn Support cannot be held responsible for PII exposures resulting from an
operator-configured downgrade.

When an override is active, the gateway logs two clear banner lines at startup
(verbatim from `services/gateway/cmd/server/main.go`):
```
TMS trust-zone override ACTIVE (self-hosted deployment-global): code_block=full_scan system_prompt=full_scan
TMS trust-zone override: WARNING — this changes scan policy for ALL keys on this deployment (not per-customer). Ensure this is a self-hosted Enterprise deployment, not the hosted multi-tenant pilot.
```
When `GATEWAY_TMS_TRUST_ZONES` is unset the gateway instead logs:
```
TMS trust-zone override: none (GATEWAY_TMS_TRUST_ZONES unset — classifier defaults in effect)
```
The `TMS trust-zone override ACTIVE` line is searchable in pod logs and is
included in support bundles.

### Prerequisite: gateway image >= 0.5.1

This feature first shipped in the gateway image at `0.5.1` (the feature floor);
the current published release is `0.5.5` (`appVersion: 0.5.5`, chart `v1.9.7`),
also published to GHCR. The gateway binary that reads `GATEWAY_TMS_TRUST_ZONES`
is present from `0.5.1` onward, so any `>= 0.5.1` pin (including `0.5.5`) works.
Setting `GATEWAY_TMS_TRUST_ZONES` on an **older** image (e.g. `0.5.0`) is a
**silent no-op** — the var is present in the ConfigMap but that older gateway
does not read it.

`lucairn doctor` **blocks** setting this on an image older than 0.5.1 with a clear
error (verbatim from `bin/lucairn`):
```
tms trust zones: failed — GATEWAY_TMS_TRUST_ZONES requires gateway image >= 0.5.1 (the release containing TMS Slice 4); your LUCAIRN_IMAGE_TAG is 0.5.0. Bump the tag or unset the policy — on an older image the policy is silently ignored.
```

If `LUCAIRN_IMAGE_TAG` is not an exact `MAJOR.MINOR.PATCH` pin (e.g. `latest`,
`v0.5.1`, `sha-…`, or a bare `0.5`), the doctor fails closed — it cannot prove
the image is new enough:
```
tms trust zones: failed -- GATEWAY_TMS_TRUST_ZONES is set but LUCAIRN_IMAGE_TAG="latest" is not an exact semver pin; doctor cannot confirm the gateway image is >= 0.5.1. Pin an exact tag (e.g. 0.5.1) or unset the policy.
```

Pin `LUCAIRN_IMAGE_TAG=0.5.5` in `customer.env` (Compose) or
`--set global.imageTag=0.5.5` (Helm) — the current published release (any exact
`>= 0.5.1` pin satisfies the feature floor) — then apply the policy.

### Helm

Set overrides via `--set` at install or upgrade time:

```bash
# Require full scanning of system prompts (stricter than default):
helm upgrade lucairn charts/lucairn \
  --set gateway.tms.trustZones.system_prompt=full_scan

# Require full scanning of both system prompts and code blocks:
helm upgrade lucairn charts/lucairn \
  --set gateway.tms.trustZones.system_prompt=full_scan \
  --set gateway.tms.trustZones.code_block=full_scan
```

In `customer-values.yaml`:

```yaml
gateway:
  tms:
    trustZones:
      system_prompt: full_scan
      code_block: full_scan
```

An empty `trustZones: {}` (the default) means no overrides — gateway uses
built-in defaults for all segments. The `GATEWAY_TMS_TRUST_ZONES` key is absent
from the ConfigMap when trustZones is empty.

### Compose

In `customer.env`:

```
# Require full scanning of system prompts:
GATEWAY_TMS_TRUST_ZONES={"system_prompt":"full_scan"}

# Require full scanning of system prompts AND code blocks:
GATEWAY_TMS_TRUST_ZONES={"system_prompt":"full_scan","code_block":"full_scan"}
```

Leave the line commented-out (or unset) to use gateway defaults.

### Pre-flight validation

Run `lucairn doctor --offline` before `docker compose up` (or `helm upgrade`) to catch
policy errors before they reach the gateway:

- **Invalid zone value** (typo, e.g. `full_scna`) → `FAIL` — doctor names the
  bad key and the bad value.
- **Non-object policy** (a JSON array, string, or number instead of an object)
  → `FAIL` with a clean message (e.g. `must be a JSON object (got array)`).
- **`null` or empty object `{}`** → `ok` (identity) — matches the gateway, which
  treats both as "no override, use built-in defaults".
- **Duplicate segment-type key** → `FAIL` — matches the gateway's fail-loud.
- **Unknown segment type** → `WARN` — forward-compatible; the gateway also
  warns but boots cleanly.
- **Gateway image < 0.5.1** with a non-empty policy → `FAIL` — bump the tag or
  unset the policy first.
- **Non-semver `LUCAIRN_IMAGE_TAG`** (e.g. `latest`, `v0.5.1`, `sha-…`, bare
  `0.5`) with a non-empty policy → `FAIL` (fail-closed: the doctor cannot prove
  the image is ≥ 0.5.1; pin an exact `MAJOR.MINOR.PATCH` tag).
- **`python3` unavailable on the doctor host** → `WARN` (JSON validation
  skipped; the gateway's own fail-loud at startup remains the enforcement gate).

### Auditability

The effective trust zone for each segment is recorded in the signed cert's
**TMS manifest** (`tms_manifest_body`, unsigned metadata alongside the cert).
Every request processed under a tuned policy is auditable after the fact: the
manifest shows which segment type was assigned which zone and what the scan
outcome was. This is the same manifest the Lucairn dashboard surfaces in the
cert detail view.
