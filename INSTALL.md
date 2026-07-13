# INSTALL

Goal: a competent platform engineer should complete a standard install in about 3 hours without a vendor call.

## Release notes

> The canonical changelog is [`CHANGELOG.md`](CHANGELOG.md). Security advisories
> are published at <https://lucairn.eu/security>; the disclosure process and
> contact are in [`SECURITY.md`](SECURITY.md).

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

Both fixes are delivered in the `0.5.1` sanitizer image. The strict safe list
is also bundled in the kit (`config/safe-terms-strict.txt`), mounted into the
sanitizer container, and wired in `config/default-sanitizer.yaml` and the ITSM
starter template (`starter-templates/itsm/config.yaml`).

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

## Quickstart (30 seconds, dev mode)

```
git clone https://github.com/Declade/lucairn-enterprise-deployment-kit && cd lucairn-enterprise-deployment-kit
# Step 0: Lucairn must GRANT your GitHub account registry access BEFORE this step.
# See § "Step 0 — Registry access" above. One-time per host:
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
./bin/lucairn-init --dev
docker compose -f docker-compose.customer.yml -f docker-compose.self-hosted.yml --env-file customer.env up -d
```

That's it. `bin/lucairn-init --dev` writes a fully-populated, doctor-passing
`customer.env` (5 Ed25519 keypairs, hex32 service secrets, postgres
passwords, sensible dev-mode defaults) and runs `bin/lucairn doctor` against
it before exiting. Use `bin/lucairn-mint-customer` once the stack is healthy
to provision your first customer.

The `docker login` step requires Lucairn to have granted package-pull access
to the GitHub account that owns the PAT (see § "Step 0" above). First-time
setup walkthrough is in § "Registry Authentication" below. Skip the ghcr.io
`docker login` step ONLY when you are mirroring
images to a private registry — set `LUCAIRN_IMAGE_REGISTRY` to the mirror
prefix. If your private mirror requires authentication, run `docker login
<your-mirror-host>` instead (same `--password-stdin < ~/.<registry>-token`
pattern as the ghcr.io flow above).

For production deployment with a Lucairn-issued license, see "Choose A
Deployment Mode" below and use `./bin/lucairn-init --production --license
<path>`. For managed-LLM mode (BYOK Anthropic, OpenAI, etc.) add `--byok` and
populate the provider key before `docker compose up`. The
`bin/lucairn-init --help` lists every flag.

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
your node sizing accordingly. The sanitizer's memory ceiling is back to
the compose-default `2Gi` post-extraction (the 6Gi box-local override
needed pre-PR #240 to fit both models in the sanitizer container is no
longer required).

### Dev / debug knob: `LUCAIRN_PII_ML_ALLOW_LAZY_NOT_READY`

`pii-ml.allowLazyNotReady: false` is the production default. Flipping it
on lets the sidecar accept gRPC scans before models finish loading (it
returns `scan_status=inference_error` per call instead of blocking OR
fail-OPEN). This is a dev-loop debug aid — NEVER set it on in
production: it disables the fail-CLOSED readyz gate that PR #240's Codex
r1 review locked in.

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

**The DSA gateway / sanitizer / veil-witness images (v0.5.0+) read each
setting under its `LCR_*` name first and fall back to the legacy `VEIL_*`
name when `LCR_*` is unset.** The doctor and the kit's
`docker-compose.customer.yml` BOTH apply the same dual-name fallback, so
pre-Stage-3 customer.env files keep validating and keep booting against
the new kit without modification — provided you upgrade the kit (compose +
doctor) and the images together.

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

After the optional migration, run `./bin/lucairn doctor` (Docker Compose) to
confirm the rename did not break any required-key check. On Kubernetes the chart
ships no test hook that validates the env rename (`helm test lucairn` only runs
the optional dashboard `/healthz` probe, and only when the dashboard subchart is
enabled) — instead re-run `helm template` / `helm upgrade` and confirm the
gateway and witness pods reach Ready, since they fail-closed at boot on a missing
required key.

## Pre-Requisites

For Docker Compose:

- Linux host with Docker Engine and Docker Compose v2.
- **16 GB RAM recommended** for the default topology with the L3 deep PII
  shield enabled (Phase 7 ML PII scanners **disabled by default** as of chart
  v1.7.1 — see § "Phase 7 ML PII scanners"). This covers the deterministic
  L1+L2 layers plus the sandbox-a + sanitizer + ollama-identity + gateway +
  witness + audit + id-bridge baseline **with the `qwen2.5:7b` L3 model
  resident in `ollama-identity` (~5 GB)**. **~8 GB is feasible with L3 disabled**
  (`LUCAIRN_L3_REQUIRED=false`, the kit default for all install paths): the
  `ollama-identity` container still runs but loads no model, so it idles at a
  few hundred MB and the L1+L2 stack fits in ~8 GB. **20 GB RAM** is required
  only when Phase 7 is explicitly re-enabled — the `pii-ml` sidecar runs
  Piiranha + GLiNER and reserves up to 4 GB for the container on top of the
  L3-on baseline. 4 vCPU is sufficient for any of these topologies at
  single-tenant pilot load.
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
Sigstore Rekor public transparency log. Before deploying, you can verify the
whole published set against the kit-bundled public key
(`keys/lucairn-cosign.pub`) and the per-release signed-digest record
(`keys/image-digests-<tag>.txt`). You need `cosign` (>= v2.0) and a digest
resolver (`docker buildx`, `crane`, or `skopeo`) on PATH:

```bash
bin/lucairn verify-images --tag 0.5.4
# or a single image, by its signed digest (from keys/image-digests-0.5.4.txt):
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
bin/lucairn sbom ghcr.io/declade/dsa-gateway:0.5.4
# save the raw verified SBOM:
bin/lucairn sbom ghcr.io/declade/dsa-gateway:0.5.4 --download dsa-gateway-0.5.4.spdx.json
# or with raw cosign:
cosign verify-attestation --type spdxjson \
  --key keys/lucairn-cosign.pub ghcr.io/declade/dsa-gateway:0.5.4
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
| **Split deployment** | Lucairn-hosted | `docker-compose.customer.yml` only | All of the self-hosted list **plus** `SANDBOX_B_REMOTE_ENDPOINT`, `SANDBOX_B_API_KEY`, `LCR_SANDBOX_B_PUBLIC_KEY`, optional mTLS material (`SANDBOX_B_CLIENT_CERT` etc.) | HTTPS to Lucairn-provided endpoint per request. |

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

The bare `customer.env.example` ships **split-deployment defaults**: the
license / signing / remote-endpoint slots are placeholder strings that the
operator must replace with Lucairn-provisioned values before the gateway will
start outside dev mode. For a self-hosted-inference install, replace
`SANDBOX_B_REMOTE_ENDPOINT` with an empty string (the self-hosted overlay
ignores it) and follow the model runtime steps in the `docker-compose.self-hosted.yml`
overlay (`MODEL_RUNTIME_PROFILE`, `MODEL_NAME`, `MODEL_PATH`, etc.).

### Deployment license (Enterprise features)

The gateway enforces a self-hosted deployment entitlement license that gates
Enterprise-only features (e.g. the custom-trained L3 PII shield) with a
grace-then-degrade expiry. It is verified entirely offline (no phone-home), so
air-gapped installs work. Lucairn issues you two values:

- `LUCAIRN_LICENSE_KEY` — the signed license token.
- `LUCAIRN_LICENSE_PUBLIC_KEY` — the verification public key.

`bin/lucairn-init --production` populates both automatically when you carry
them in the `--license` bundle (see below); otherwise set them in `customer.env`
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

The `--license` file `bin/lucairn-init --production` reads can carry **both**
licenses in one bundle. Four fields:

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

`bin/lucairn-init --production --license <bundle>` writes `DSA_LICENSE_KEY` +
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

## Docker Compose Install

1. Unpack the release bundle.

```bash
tar -xzf lucairn-enterprise-deployment-kit-1.9.4.tar.gz
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

The `sign-manifest` tool ships **inside the pinned `dsa-veil-witness:0.5.4`
image** (`/usr/local/bin/sign-manifest`), so the ceremony is turnkey via
`docker run --entrypoint sign-manifest` on the ceremony host — no Go toolchain,
no build-from-source, no dev-mode fallback:

```bash
# On the ceremony host, with the witness seed available. keys.json is the
# per-service key roster (service_id / key_id / public_key / purpose /
# algorithm / key_state — the shape the gateway's buildPublicKeyManifest emits).
# The default image entrypoint is `veil-witness`, so override it to sign-manifest.
docker run --rm \
  --entrypoint sign-manifest \
  -v "$PWD/keys.json:/keys.json:ro" \
  ghcr.io/declade/dsa-veil-witness:0.5.4 \
  --keys-json /keys.json \
  --issuer "$LCR_ISSUER" \
  --witness-signing-key-hex "$LCR_WITNESS_SIGNING_KEY" \
  --witness-key-id witness_manifest_v1 \
  > witness-signed-manifest.json

# Then mount/copy witness-signed-manifest.json to the gateway host at the path
# in LCR_WITNESS_SIGNED_MANIFEST_PATH (Compose: bind-mount into /certs/;
# Helm: the chart mounts gateway.secrets — see OPS.md).
```

> **Flags** (run `docker run --rm --entrypoint sign-manifest
> ghcr.io/declade/dsa-veil-witness:0.5.4 -h` to confirm against your pin):
> `--keys-json` (required), `--issuer` (required; matches `LCR_ISSUER` / legacy
> `VEIL_ISSUER` at the gateway), `--witness-signing-key-hex` (required; the
> Ed25519 witness seed, hex 32 bytes), `--witness-key-id` (default
> `witness_manifest_v1`), `--version` (default `1`), `--protocol-versions`
> (default `1,2`), `--signed-at` (RFC3339; empty uses current UTC). The witness
> seed only ever enters the container as a flag value on the ceremony host —
> it never leaves that machine. Keep `bin/lucairn doctor`'s `check_manifest_blob`
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

6. Run live validation.

```bash
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
```

The live validation checks whether the configured Lucairn images are pullable. If it fails with `container images: failed`, fix registry access before continuing.

7. Start the stack.

For **split deployment**:

```bash
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
stack:

```bash
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

**Out-of-the-box default — continue-mode (L1+L2 only).** Both `lucairn-init`
and the bare `customer.env.example` (manual `cp customer.env.example customer.env`
path) set `LUCAIRN_L3_REQUIRED=false` for every deployment path. With this
default the stack runs continue-mode: the sanitizer applies the
L1 (deterministic regex/dictionary) + L2 (sandbox-a) PII layers, the L3 shield
is treated as optional, and the verification certificate is honestly downgraded
to **`COMPLETENESS_PARTIAL`** (the witness omits `llm_pii_scan` from
`layers_active`). The gateway does **not** return `503 l3_scrubber_unavailable`
— requests complete immediately even though the `qwen2.5:7b` model has not yet
been staged.

The pre-stage procedure above is the **optional** path to **re-enable L3
fail-closed** mode. To activate it after staging the model:

1. Complete the throwaway-pull staging procedure above.
2. Set `LUCAIRN_L3_REQUIRED=true` in `customer.env`.
3. Restart the stack (`docker compose … up -d`).

With `LUCAIRN_L3_REQUIRED=true` the sanitizer is fail-CLOSED: the gateway
returns `503 l3_scrubber_unavailable` if the L3 shield is unreachable rather
than degrading to L1+L2 silently. The certificate completeness becomes
`COMPLETENESS_FULL` once the model is loaded and all four claim layers are
active. Provision the full 16 GB RAM before enabling this mode (see
§ Pre-Requisites).

> **`LUCAIRN_L3_REQUIRED` governs TWO services — they MUST agree.** The
> veil-witness reads the SAME flag as the sanitizer and "mirrors
> `config.l3_required()` in the sanitizer so the two sides agree"
> (`services/veil-witness/internal/verifier/verifier.go:170-172`). If the witness
> demands L3 (`LUCAIRN_L3_REQUIRED=true`) while the sanitizer skips the L3
> `llm_pii_scan` layer (L3 off), the witness **downgrades every certificate to
> `COMPLETENESS_PARTIAL`** (`verifier.go:503`) — even on an otherwise-healthy
> stack. Set the flag the SAME on both sides.
>
> **Helm:** this is wired as the SINGLE `global.l3Required` value
> (`charts/lucairn/values.yaml`, default `false`) — there is no per-subchart
> override. Both the `sandbox-a` sanitizer container AND the `veil-witness` pod
> resolve `LUCAIRN_L3_REQUIRED` from this one key with the SAME fallback
> (`false`), so the two sides resolve identically in every case and can never
> split. The default (`false`) yields `LUCAIRN_L3_REQUIRED="false"` on both ⇒
> `COMPLETENESS_FULL` with L3 absent. To require L3, flip it once with
> `--set global.l3Required=true` (after staging the GPU L3 shield, i.e.
> `--set sandbox-a.sanitizer.llmScanEnabled=true`) so an absent L3 layer
> correctly downgrades the cert to `PARTIAL`. (Before this single-knob wiring the
> Helm witness defaulted to L3-required ⇒ every fresh L3-off install's certs
> silently downgraded to `PARTIAL`.)
>
> **Migration (chart 1.9.4+):** the old per-subchart overrides
> `sandbox-a.sanitizer.l3Required` and `veil-witness.config.l3Required` are
> **REMOVED**. They are no longer read by the pod templates, so leaving them in a
> values file would *silently* fall back to `LUCAIRN_L3_REQUIRED="false"` — a
> silent fail-closed→continue-mode security downgrade on upgrade. To prevent that,
> the chart now **`fail`s the `helm template`/`helm install`** when either
> deprecated key is present, with a message pointing you at `global.l3Required`.
> Delete those keys from your values file and set `global.l3Required=true` (or
> `false`) instead.

### Self-hosted with managed LLM (BYOK Anthropic, OpenAI, etc.)

When the customer wants the Lucairn control + identity plane on-premise but
is OK with the LLM call itself going to a managed cloud provider (Anthropic,
OpenAI, Mistral, Gemini, Azure OpenAI, AWS Bedrock, internal LLM gateway),
load the BYOK overlay on top of the customer + self-hosted overlays:

```bash
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  -f docker-compose.self-hosted-byok.yml \
  --env-file customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" \
  up -d
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

Terminate HTTPS at the customer reverse proxy and forward to `127.0.0.1:8080`. If the proxy is local or containerized, set `GATEWAY_TRUSTED_PROXY_CIDRS` to the proxy source CIDRs and rerun `bin/lucairn doctor`.

10. Mint your first customer.

Once `bin/lucairn doctor` reports `ok`, mint your first Lucairn customer + API key:

```bash
export LUCAIRN_ADMIN_KEY="$(grep '^DSA_ADMIN_KEY=' customer.env | cut -d= -f2-)"

./bin/lucairn-mint-customer \
  --name "Acme GmbH" \
  --email "ops@acme.de" \
  --tier enterprise
```

The script prints the raw API key **once** — capture it to a 0600 file. Smoke with `curl -H "x-api-key: <raw_key>" $GATEWAY_BASE_URL/api/v1/usage`. See `./bin/lucairn-mint-customer --help` for all flags including `--byok-per-request`, `--managed-ai`, `--provider-key`, `--dry-run`, `--verbose`, and `--tool-scope`.

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

Kubernetes pull Secrets require a `dockerconfigjson` payload with a
base64 `auth` entry. On hosts where Docker uses `credsStore`/`credHelpers`
(Docker Desktop, hardened workstations), `docker login` writes the
credential to the OS keychain and stores only helper metadata in
`~/.docker/config.json` — that metadata is not usable by Kubernetes
(pods would fail with `ImagePullBackOff`). Use an isolated
`DOCKER_CONFIG` set to a freshly-`mktemp`'d directory for the login,
so the resulting `config.json` has a direct `auth` entry the chart can
render into the per-namespace Secret. The PAT only ever appears via
stdin (and then via the `--set-file` flag read at install time).

```bash
# 1. Create an isolated Docker config for the install (avoids credsStore /
#    credHelpers on Docker Desktop / hardened workstations that store
#    credentials outside config.json).
DOCKER_CONFIG=$(mktemp -d)
export DOCKER_CONFIG

# 2. Log Docker into ghcr.io (or your private mirror).
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token

# The resulting $DOCKER_CONFIG/config.json now contains a real `auth`
# entry usable by Kubernetes imagePullSecrets. KEEP the path — the
# `helm install` step below reads it via --set-file. Do NOT copy the
# file contents into customer-values.yaml; that would leak the registry
# PAT into version control.
```

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
      # The eso-service-account in each namespace must be IRSA-annotated with
      # an IAM role granting secretsmanager:GetSecretValue on the Lucairn
      # secret paths.
      serviceAccountAnnotation: "arn:aws:iam::<acct>:role/lucairn-eso"
```

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

If you choose different names, put the complete block in
`customer-production-values.yaml`. In production with `gateway.veilEnabled=true`,
Helm fails before install if any field is absent or if
`veilWitnessSignedManifestPath` is not exactly `mountPath/fileName`. This Secret
is separate from the readiness-bundle contract; it projects exactly one file,
read-only, at the gateway path that verifies the witness signature at startup.

Use `charts/lucairn/values-prod.yaml` as the production base. It enables
`global.mtls`, fixes these Secret names, and rejects all optional gRPC profiles
(`ingest`, `admin`, dashboard, certification, PII ML, demo, and
postgres-gateway) rather than allowing an insecure or partial extension. To use
different names or key names, change all entries in `global.mtls` together.

Before install, run the Helm-only preflight with the same ordered values pair
as Helm. Keep customer-specific values in the overlay; do not flatten or copy
the production contract into it. A green render alone is not an accepted
deployment.

```bash
bin/lucairn doctor \
  --values charts/lucairn/values-prod.yaml \
  --values customer-production-values.yaml \
  --offline
helm template lucairn charts/lucairn \
  -f charts/lucairn/values-prod.yaml \
  -f customer-production-values.yaml >/dev/null
```

Then install and wait for every workload; run the handshake battery before
declaring success:

```bash
helm upgrade --install lucairn charts/lucairn \
  -f charts/lucairn/values-prod.yaml \
  -f customer-production-values.yaml \
  --namespace lucairn --create-namespace --wait --timeout 12m

# Isolated, destructive-to-its-own-Kind-cluster acceptance only:
scripts/test-enterprise-mtls-kind.sh
```

The harness creates ephemeral CA/leaves and a mode-0600 application values
file under a uniquely named `/tmp` state path. The latter contains fresh
signing seeds, their derived public keys, database/cache credentials, shared
service/canary tokens, and the gateway keystore key; it is never printed or
committed. The seven mTLS identity Secrets remain independently pre-created,
mirroring the operator/PKI production contract. The harness creates a unique
valid witness-signed manifest from that same coherent disposable key set and
creates `lucairn-witness-signed-manifest` in `dsa-edge` before Helm. It does not
write the ceremony `keys.json`, witness seed, or signed output into the
worktree. It then creates a unique Kind cluster, installs only the mandatory
mesh plus its required service
databases/caches (not Admin, observability, or Sandbox-B Ollama/model pull),
performs positive handshakes and wrong-CA, wrong-SAN, no-client, expired-leaf,
and partial-Secret negatives, rotates the Audit leaf, and tears down its owned
state. The five non-Witness positive checks run from its generic probe; the
two Witness checks run a temporary verified-TLS helper in the actual gateway
Pod using that Pod's projected leaf identity. The same temporary helper invokes
the gateway health handler locally over loopback, then is deleted after that
evidence battery. Because this harness uses stock Kind/kindnet, it proves only
the actual Pod's projected-leaf transport identity; it does not prove
NetworkPolicy enforcement or per-link caller authorization. The Witness checks
prove transport handshakes only; they do not claim to invoke gateway application
Witness RPC methods. mTLS proves CA membership authentication and exact server
identity, while authorization remains a separate NetworkPolicy and application
control. It requires authenticated GHCR credentials in `DOCKER_CONFIG` and a
functioning container runtime. It does not use a production or customer
context.

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

By default the veil-witness cert RPC port (:50058) accepts unauthenticated
callers. For production deployments Lucairn recommends enabling mutual-TLS
so only the gateway (and, optionally, the dashboard) can query certificates.

### Compose path

1. Run the bootstrap CA script to generate a deploy-local CA + server cert
   for the witness + a client cert for the gateway:

   ```bash
   scripts/bootstrap-mtls-ca.sh /opt/dsa/certs/witness-mtls
   ```

2. Add to `customer.env`:

   ```bash
   LCR_WITNESS_MTLS_HOST_DIR=/opt/dsa/certs/witness-mtls
   WITNESS_MTLS_CA_BUNDLE_PATH=/etc/witness-mtls/ca.crt
   WITNESS_MTLS_SERVER_CERT_PATH=/etc/witness-mtls/witness-server.crt
   WITNESS_MTLS_SERVER_KEY_PATH=/etc/witness-mtls/witness-server.key
   WITNESS_MTLS_GATEWAY_CLIENT_CERT_PATH=/etc/witness-mtls/gateway-client.crt
   WITNESS_MTLS_GATEWAY_CLIENT_KEY_PATH=/etc/witness-mtls/gateway-client.key
   WITNESS_MTLS_SERVER_NAME=witness
   ```

3. Recreate the witness and gateway containers:

   ```bash
   docker compose -f docker-compose.customer.yml up -d --no-deps --force-recreate veil-witness gateway
   ```

The witness logs a warning and degrades gracefully to unauthenticated when
any of the three server-side paths are unset — claims from bridge, sanitizer,
and audit continue flowing while the operator provisions the CA.

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

Use this path when Lucairn has prepared a customer-specific bundle with model files and image archives.

1. Unpack the bundle.

```bash
tar -xzf lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
cd lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ
```

2. Verify checksums.

```bash
bin/lucairn bundle verify --bundle .
```

3. Load images when the bundle contains an archive.

```bash
docker load -i images/lucairn-images.tar
```

If `images/lucairn-images.tar` is absent, this handoff uses registry or customer-mirror delivery. Log in to the configured registry, keep `LUCAIRN_IMAGE_REGISTRY` and `LUCAIRN_IMAGE_TAG` aligned with the handoff note, and skip `docker load`.

4. Run pre-flight checks.

```bash
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml --skip-image-check
```

5. Start the selected model runtime profile.

```bash
docker compose \
  -f install/docker-compose.customer.yml \
  -f install/docker-compose.self-hosted.yml \
  --env-file install/customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" \
  up -d
```

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
2. Run `bin/lucairn doctor` — the dashboard pre-flight check exits with a
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
   kubectl -n lucairn create secret generic lucairn-dashboard-oidc \
     --from-literal=client-secret='<your-idp-client-secret>'
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

2. Run `bin/lucairn doctor` — the new `dashboard certs:` pre-flight
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
   kubectl -n lucairn create secret generic lucairn-dashboard-audit-db \
     --from-literal=connection-string='postgres://lucairn_dashboard_ro:<password>@postgres-bridge:5432/dsa?sslmode=verify-full'
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

3. Run `bin/lucairn doctor` — the new `dashboard grafana:` pre-flight
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

2. Run `bin/lucairn doctor` — the new `dashboard keys:` pre-flight
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
   `curl -H "X-API-Key: <minted-key>" https://<gateway-host>/v1/messages …`.

#### Kubernetes path

1. Pre-create the Secret carrying the admin token. The Secret name +
   key the dashboard sub-chart consumes are
   `lucairn-dashboard-gateway-admin` + `admin-token` by default;
   override via `dashboard.gateway.adminTokenSecretRef.{name,key}`.

   ```bash
   kubectl -n lucairn create secret generic lucairn-dashboard-gateway-admin \
     --from-literal=admin-token='<gateway DSA_ADMIN_KEY value>'
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

Verify `bin/lucairn doctor` returns green for `dashboard audit-log`:

```bash
./bin/lucairn doctor
```

#### Kubernetes path

Pre-create the Secret holding the libpq connection string:

```bash
kubectl -n lucairn create secret generic lucairn-dashboard-audit-log \
  --from-literal=url='postgres://audit_app:REAL_PASSWORD@postgres-audit:5432/audit?sslmode=disable'
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
the current published release is `0.5.4` (`appVersion: 0.5.4`, chart `v1.9.4`),
also published to GHCR. The gateway binary that reads `GATEWAY_TMS_TRUST_ZONES`
is present from `0.5.1` onward, so any `>= 0.5.1` pin (including `0.5.4`) works.
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

Pin `LUCAIRN_IMAGE_TAG=0.5.4` in `customer.env` (Compose) or
`--set global.imageTag=0.5.4` (Helm) — the current published release (any exact
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

Run `lucairn doctor` before `docker compose up` (or `helm upgrade`) to catch
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
