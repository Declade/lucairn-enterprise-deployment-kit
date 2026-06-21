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
