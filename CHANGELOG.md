# Changelog

All notable changes to the Lucairn Enterprise Deployment Kit are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the kit follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each kit version (`VERSION` / `charts/lucairn/Chart.yaml` `version`) pins a set of
`dsa-*` service images by tag (`appVersion` / `image-manifest.yaml`
`default_lucairn_image_tag`). Both are listed per entry below.

Security advisories are published at <https://lucairn.eu/security>; the
disclosure process and contact are in [`SECURITY.md`](SECURITY.md). Entries that
carry a security fix are tagged **[Security]**.

## [Unreleased]

### Added
- **Gateway tool-schema PII guard mode knob (T-487).** The gateway's
  recursive tool-declaration schema PII guard (`GATEWAY_TOOL_SCHEMA_GUARD`;
  upstream `dual-sandbox-architecture` T-14) is now wired into the kit: a new
  `gateway.toolSchemaGuard` Helm value (unset by default, so a pinned image's
  own compiled-in `refuse` default governs) and a `GATEWAY_TOOL_SCHEMA_GUARD`
  compose entry (`docker-compose.customer.yml`, `docker-compose.self-hosted.yml`
  overlay; defaults to `refuse`) let an operator flip to `log` for a bounded
  observation window if the guard false-positives on their own tool schemas.
  The kit's shipped default stays `refuse` (T-493) — see `OPS.md` §
  "Tool-schema PII guard" for the three modes and exactly what
  `refuse_high_confidence` does and does not relax.

### Changed
- **[Security] `sandbox-a.sanitizer.confidenceThreshold` is now schema-bounded to
  a number in `[0, 1]` (T-517).** The value is rendered straight into the
  sanitizer ConfigMap as `presidio.confidence_threshold`, and an unusable value
  was invisible at runtime: Presidio scores never exceed 1.0, so
  `confidenceThreshold: 2.0` kept **zero** detections while every request still
  returned 200 and the certificate still listed `presidio_ner` in
  `layers_active` — a false attestation, not a degraded scan. A YAML `.nan` had
  the identical effect (every confidence comparison against NaN is false).
  `charts/lucairn/charts/sandbox-a/values.schema.json` now rejects both, plus
  strings, booleans, lists and maps, at `helm template` / `helm lint` time.
  Covered by `tests/test_sanitizer_confidence_threshold_schema.sh` (wired into
  `make test`). The sanitizer enforces the same bounds independently at boot,
  so Compose and hosted installs are covered as well.
  **Upgrade note:** installs that expressed this value as a *quoted string*
  (`confidenceThreshold: "0.35"`) must unquote it — the contract is a number.
  `helm --set` cannot express a float at all (Helm parses integers as int64 and
  leaves everything else a string), so use a values file or
  `--set-json sandbox-a.sanitizer.confidenceThreshold=0.35`. Untouched installs
  are unaffected: the shipped default is `0.35` and omitting the key still
  falls back to `0.35`.
- **[Security] Docs corrected for the veil-witness `:50058` ACL hoist (T-12 / T-507).**
  `INSTALL.md` and `OPS.md` stated that the veil-witness certificate RPC port
  (`:50058`) accepts unauthenticated callers by default on the legacy Compose
  compatibility path. As of the `dsa-veil-witness` T-12 fix (upstream
  `dual-sandbox-architecture` commit `2efc3dd6b`), that is no longer true: the
  per-method ACL now attaches on every code path, including every transport
  degradation exit, so `GetCertificate`/`ExportCertificates` refuse every
  caller — **including the gateway itself** — with `Unauthenticated` unless
  the operator has completed the mTLS bootstrap (`scripts/bootstrap-mtls-ca.sh`,
  documented in `INSTALL.md` § "Witness mTLS"). Both docs now state the
  post-fix posture and both point operators at the bootstrap step before
  minting a customer / running online doctor. Claim intake on `:50057` is a
  separate port and is unaffected.
- **[Security] Chart-managed passwords no longer ship a working default (T-10).**
  Six sub-charts shipped the literal placeholder `CHANGE-ME…` as a *functioning*
  password in this public repository — nothing rejected it (not the chart, not
  Postgres, not the services), so `helm install` with untouched values produced a
  running system whose credentials are readable on GitHub. All nine slots now
  ship **empty**, and each sub-chart's `templates/_validate.tpl` hard-fails the
  render on an empty value **or** on any `CHANGE-ME…`-shaped placeholder:
  `admin.secrets.values.adminPassword`,
  `audit.secrets.values.{postgresPassword,auditAppPassword}`,
  `id-bridge.secrets.values.postgresPassword`,
  `observability.secrets.values.grafanaAdminPassword`,
  `sandbox-a.secrets.values.postgresPassword`,
  `veil-witness.secrets.values.{postgresPassword,veilAppPassword}`.
  The value is trimmed before both checks, so neither a whitespace-only value nor
  a space-prefixed placeholder slips through (only the *check* is trimmed — the
  Secret still renders the operator's value byte-for-byte).

  The guards are **not** gated on `global.dsaEnv` (the umbrella default is
  `development`, so a production-only guard would never fire on the install path
  that actually shipped the weak credential). They apply where the value is
  really rendered into a Secret: the `k8s-native` secrets backend, and — for the
  bundled-database passwords — only when that sub-chart's `postgresql.enabled` is
  true. External-Secrets installs of `audit` / `id-bridge` / `sandbox-a` /
  `veil-witness` (`values-prod.yaml`, `secrets.backend: vault`) and
  external-Postgres installs are unaffected.

  `admin` and `observability` are the two exceptions, and their guards are
  unconditional: neither sub-chart ships an `externalsecret.yaml`, so no
  `secrets.backend` value supplies those credentials from anywhere. Set
  `admin.enabled: false` / `observability.enabled: false` if you do not deploy
  those surfaces.
- **[Security] Kit password guards reject a non-string `--set` value (T-490).**
  `admin` / `audit` / `id-bridge` / `observability` / `sandbox-a` /
  `veil-witness` coerced every value through `toString` before checking it, so
  `--set adminPassword=true` (parsed by Helm as a **boolean**, not a string)
  rendered a 4-character password with no complaint. Every guard now rejects
  any non-string YAML type by name before that coercion runs; a quoted
  numeric-looking password (`--set-string ...=12345678`) is unaffected.
- **[Security] Kit password guards reject the kit's own `REPLACE_WITH_*`
  placeholder shape (T-490 second half).** The same six guards rejected the
  `CHANGE-ME…` shape (T-10) but not the shape `customer-values.yaml.example`
  itself ships for every unset credential: ~46 `REPLACE_WITH_*` slots,
  several of them these exact password fields. An operator who copies that
  example and misses one slot got a Secret whose password was, literally,
  the published string `REPLACE_WITH_ADMIN_PASSWORD` — the same class of
  defect T-10 closed for `CHANGE-ME…`. All six guards now also reject
  `replace[-_ ]?with…` (case-insensitive, same separator tolerance as the
  `change[-_ ]?me` pattern beside it); a real-looking value, including one
  that merely contains the substring "replace", is unaffected.

### Removed
- **`observability.grafana.adminPassword` (dead key).** No template ever read it,
  so setting it never protected the Grafana admin account — the Grafana pod reads
  the `grafana-admin` Secret, which is rendered from
  `observability.secrets.values.grafanaAdminPassword`. Rather than drop it
  silently, `observability/templates/_validate.tpl` now fails the render with a
  migration message if a values file still sets it.

### Fixed
- **`admin` sub-chart gained an `ExternalSecret` template (T-488).**
  `--set admin.secrets.backend=vault` used to render "clean" with nothing to
  ever populate the `admin-credentials` Secret that `deployment.yaml` mounts
  unconditionally, so the pod hit `CreateContainerConfigError` at start.
  `admin` now ships `templates/externalsecret.yaml` (parity with the other
  credential-bearing sub-charts) and its password guard is gated on
  `secrets.backend == k8s-native` to match.
- **`values.yaml` declared `observability:` twice (T-489).** A duplicate
  top-level key silently discarded the first block — YAML keeps only the
  last occurrence. The surviving block already carried the intended config,
  so this is a no-op for rendered output; the fix is closing the hole so a
  future edit to the wrong block doesn't silently vanish. A duplicate-key
  static check (`tests/lib/check_duplicate_yaml_keys.py`) now runs in
  `tests/static_checks.sh` against every chart values file.

### Notes
- **Upgrade (witness `:50058` ACL, T-12):** kit installs inherit this on the
  next `dsa-veil-witness` image pull — no kit-side action is required for the
  fix itself. An install that has **not** run the Compose mTLS bootstrap
  (`scripts/bootstrap-mtls-ca.sh`) will see certificate reads refuse
  (`Unauthenticated`) starting with that pull: the gateway's own certificate
  retrieval, the dashboard's certs surface, and `bin/lucairn doctor`'s
  certificate-receipt check. This is expected behavior, not a regression —
  see `INSTALL.md` § "Witness mTLS" for the bootstrap steps. Production Helm
  installs (`global.mtls.enabled=true`, required topology) are unaffected.
- **Upgrade:** a `helm upgrade` that previously relied on the shipped defaults
  will now fail to render until each slot above is supplied, e.g.
  `--set "audit.secrets.values.postgresPassword=$(openssl rand -base64 24)"`, or
  moved onto an External Secrets backend. `customer-values.yaml.example` gained
  the two slots it never listed (`admin.secrets.values.adminPassword`,
  `observability.secrets.values.grafanaAdminPassword`) in the existing
  `REPLACE_WITH_*` convention. **Changing a database password on an existing
  install does not change the password inside the already-initialised Postgres
  volume** — supply the value the cluster is currently using, or rotate it in
  the database first.

## [1.9.4] — 2026-06-19 — images `0.5.4`

Per-key MCP tool-scope enforcement + control-plane `tool_allowlist`.

### Added
- **[Security] Per-key MCP tool-scope enforcement (gateway).** The gateway reads
  a `tool_allowlist` field from the customer profile (synced via
  `ControlAPISync`) and enforces it server-side on every `/api/v1/mcp` request:
  only MCP data-source tools in the allowlist are forwarded to the model; all
  other `mcp__*` tools are stripped. An empty allowlist (the default) is
  byte-identical to pre-0.5.4 behaviour (INERT until configured). Configured via
  the admin dashboard `ToolAllowlistForm` or the
  `/api/admin/keys/:id/tool-allowlist` route.
- **`--tool-scope` flag** on `bin/lucairn-mint-customer` for per-engagement MCP
  tool-scoping.

### Notes
- **Upgrade from 1.9.3 / 0.5.3:** set `LUCAIRN_IMAGE_TAG=0.5.4` (Compose) or
  `global.imageTag: "0.5.4"` (Helm). No database migration on the gateway/DSA
  stack. The 12 `dsa-*` images are republished, cosign-signed, and Rekor-logged
  at `0.5.4` (`bin/lucairn verify-images --tag 0.5.4` → 13/13). `dsa-pii-ml`
  stays `0.5.1`; `lucairn-dashboard` stays `0.8.2`.

## [1.9.3] — 2026-06-16 — images `0.5.3`

Lucairn anti-tamper (INERT until pin-baked) + S1–S6 security remediations.

### Added
- **Deployment-entitlement anti-tamper (INERT on stock images).** Carries the
  anti-tamper coupling from Lucairn gateway PRs #291/#292: fail-closed boot on a
  missing/forged entitlement; `POST /api/v1/register` disabled (`403
  registration_disabled`); the `DSA_ENV=development` enforcement bypass closed;
  `customer_id` coupling (`403 entitlement_mismatch`). The stock GHCR images ship
  `PinnedPublicKeyHex=""` and are fully **INERT** for anti-tamper — enforcement
  activates only on a Lucairn-built pin-baked gateway image.

### Fixed
- **[Security] S1–S6 security remediations.** Six security-audit findings
  remediated across the `dsa-*` service images. See
  <https://lucairn.eu/security> for advisory detail.

### Notes
- **Upgrade from 1.9.2 / 0.5.2:** set `LUCAIRN_IMAGE_TAG=0.5.3` (Compose) or
  `global.imageTag: "0.5.3"` (Helm). No database migration. Images republished,
  cosign-signed, and Rekor-logged at `0.5.3` (`verify-images --tag 0.5.3` →
  13/13).

## [1.9.2] — 2026-06-15 — images `0.5.2`

A6 LOCATION stop-list + turnkey `sign-manifest`.

### Fixed
- **A6 strict LOCATION stop-list (no recall loss).** spaCy's English NER still
  mis-tagged common words (`West`/`Loop`/`For`) as LOCATION in messy
  ITSM/ServiceNow prose. A new whole-token-exact LOCATION stop-list
  (`config/safe-terms-strict-location.txt`) drops a detection only when it is a
  single LOCATION-typed token from spaCy's own NER that exactly matches a listed
  term. Multi-word places, longer tokens, PERSON-tagged `West`, and L1 identity
  surnames all stay redacted — recall-safe by construction.

### Changed
- **`sign-manifest` is now turnkey.** The `dsa-veil-witness:0.5.2` image ships
  `sign-manifest` at `/usr/local/bin/sign-manifest`; the production key-ceremony
  step (INSTALL § 4b) runs it via `docker run --entrypoint sign-manifest …` — no
  Go toolchain, no build-from-source, no dev-mode fallback.

### Notes
- **Upgrade from 1.9.1 / 0.5.1:** set `LUCAIRN_IMAGE_TAG=0.5.2`. No database
  migration; a sanitizer container restart is the only operational step. Images
  republished, cosign-signed, and Rekor-logged at `0.5.2` (`verify-images --tag
  0.5.2` → 13/13).

## [1.9.1] — 2026-06-14 — images `0.5.1`

L1+L2 over-redaction fix.

### Fixed
- **Strict product-vocabulary safe list (no recall loss).** The L1+L2 sanitizer
  (Presidio/spaCy) mis-tagged system/product vocabulary as PERSON on ITSM and
  ServiceNow payloads (`Claude` appeared as `[PERSON_4]` 81× in one session;
  `signable` as `[PERSON_2]`). A new strict whole-span-exact safe list
  (`config/safe-terms-strict.txt`) suppresses a detection only when the entire
  detected span equals a safe term — multi-token spans like "Claude Müller" are
  not suppressed; the surname still redacts. Recall on real PII is unchanged
  (100% on the conv-3cde524c adversarial fixture). Terms: `Claude / Opus /
  Sonnet / Haiku / Anthropic / Lucairn / Codex / Veil / signable / Remedy`.
- **German place-name `de_places` en-exclusion.** The German place-name
  recognizer no longer fires on English-language input. Baked into the sanitizer
  image; no config change required.

### Notes
- **Upgrade from 1.9.0 / 0.5.0:** set `LUCAIRN_IMAGE_TAG=0.5.1`. No database
  migration; a sanitizer container restart is the only operational step. The
  strict safe list is bundled in the kit (`config/safe-terms-strict.txt`),
  mounted into the sanitizer container, and wired in
  `config/default-sanitizer.yaml` and the ITSM starter template.

## [1.9.0] — images `0.5.0`

Initial `0.5.x` image baseline. Detailed per-release notes in this changelog
begin at 1.9.1 / 0.5.1; this entry is recorded for the upgrade paths referenced
above. For the full feature surface of this release, see [`INSTALL.md`](INSTALL.md)
and [`OPS.md`](OPS.md).
