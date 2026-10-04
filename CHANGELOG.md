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

## [1.9.6] — 2026-10-04 — images `0.5.5`

Kit-only release: the images stay `0.5.5` (same digests as 1.9.5), and no
migration ceiling changes (veil-witness 10 · audit 7 · id-bridge 4 ·
sandbox-a 8). It closes the [1.9.5] known gap for audit migration `000007`
(T-1219).

### Added
- **Retention for `audit_claim_deliveries` (T-1219) — closes the [1.9.5]
  known gap.** Audit migration `000007` (applied since 1.9.5) stores, per
  completed request, the request id, delivery bookkeeping, the output-scan
  summary (`output_scan_body`) and the signed claim bytes (`claim_raw`). The
  0.5.5 audit service never removes anything from it. A new sweep now **blanks**
  the two payload columns — the claim bytes and the scan summary are removed —
  on `DELIVERED` rows whose `delivered_at` is older than the retention period
  (default **30 days**):

  ```sql
  UPDATE audit_claim_deliveries
     SET claim_raw = NULL, output_scan_body = NULL, updated_at = NOW()
   WHERE delivery_state = 'DELIVERED'
     AND delivered_at < now() - interval '30 days'
     AND (claim_raw IS NOT NULL OR output_scan_body IS NOT NULL);
  ```

  run in batches of 10,000 rows (one transaction each) under a 5-minute
  statement timeout, as the migration role `dsa`.
  - **Rows are blanked, not deleted.** The gateway's audit spill buffer can
    replay an already-delivered completion event with no maximum age (it is
    count-capped and drains only on the next audit call). The audit service
    records the outbox row with `INSERT … ON CONFLICT (event_id) DO NOTHING`;
    a deleted row would let such a replay create a fresh `PENDING` row and
    re-send an old claim to the witness. A kept `DELIVERED` row makes the
    replay a no-op, and that path never reads the blanked columns. What stays
    — event id, request id, state, counters, timestamps — is bookkeeping; the
    request id is also kept for good in the append-only `audit_events`.
  - **Never touched:** `PENDING` / `DELIVERING` rows (in flight), `PARKED`
    rows, and `audit_events`. A `PARKED` row is the operator's to re-queue,
    and a blanked scan summary would rebuild a degraded claim, so `PARKED`
    rows older than the retention period are only **counted**: the run's log
    line turns into a `WARN` (OPS.md § "Audit claim-delivery retention").
  - **Helm:** a daily CronJob `audit-claim-delivery-retention` in the audit
    namespace (`17 3 * * *`), image `postgres:16-alpine` pinned by the digest
    `image-manifest.yaml` records. It connects as `dsa` with discrete
    `PGHOST`/`PGUSER`/`PGDATABASE` and `PGPASSWORD` from the
    `POSTGRES_PASSWORD` key of the `audit-credentials` Secret — never a
    connection URL. Values `audit.claimDeliveryRetention.{enabled, retention,
    schedule, image}`; `retention` is a string such as `30d`, because a bare
    YAML number in a values file is parsed first (`030` would arrive as octal
    24). Renders only with the bundled Postgres; with
    `audit.postgresql.enabled=false` nothing renders and OPS.md gives the SQL
    to schedule yourself. No new NetworkPolicy: the audit namespace already
    allows intra-namespace 5432.
  - **Compose:** a long-running service `audit-claim-delivery-retention`
    (`postgres:16-alpine` like `postgres-audit`, pinned by the manifest
    digest; network `dsa-audit` only; non-root, read-only rootfs;
    `restart: unless-stopped`, so it survives a Docker daemon restart). It
    starts after `migrate-audit` completes, sweeps once, then once a day.
    Disabled, it logs one line and idles (no restart loop). Connects as `dsa`
    with `PGPASSWORD=$POSTGRES_AUDIT_PASSWORD`, no URL. Optional `customer.env` keys:
    `LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS` (default 30) and
    `LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED` (default `true`).
  - **Refused values:** retention must be a whole number of days from 1 to
    36500. `0`, negatives, fractions and leading zeros are refused (Helm: at
    render time, and any non-string `retention`; Compose: the service exits
    with an error) instead of blanking fresh rows. To stop the sweep set
    `enabled=false` / `…_ENABLED=false` (the days value is then ignored, by
    the service and by `doctor` alike).
  - **Backups:** the 30-day default equals `backup.retentionDays`, so a blanked
    value can still exist in offsite backups for up to ~60 days in total.
  - **Logging:** one line per run — cutoff, retention, rows blanked, old
    `PARKED` rows — never row contents or connection settings. psql's own
    error text is never logged (libpq quotes connection parameters back in
    it); a failure logs a fixed reason and the psql exit code.
  - **doctor:** checks the script exactly where Compose mounts it (beside the
    selected Compose file) and the retention env values; reports the sweep as
    disabled when `…_ENABLED=false`.
  - Suite: `tests/test_audit_claim_delivery_retention.sh` (Helm render and
    refusals, Compose definition, and a real-Postgres run on the kit-pinned
    `postgres:16-alpine` digest: migrations 1–7, synthetic rows in all four
    states, replay idempotency as `audit_app`).

### Changed
- `tests/test_backup_helm.sh` counts only the backup CronJobs (the audit
  subchart now renders a second, default-on CronJob).

## [1.9.5] — 2026-10-04 — images `0.5.5`

### Read first — upgrading to images `0.5.5`

`0.5.5` is the first image release since `0.5.4` (2026-06-19). It is built from
`dual-sandbox-architecture` main `168874d8`
(build commit `168874d8161bb2d339d5bdc3440098cbd1311ff6`, built and signed 2026-10-04), so it carries everything below that
earlier kit entries described as "not in the pinned `0.5.4` image".

- **⚠ Release ordering — the gateway refuses to boot while it holds a `dsa-ai`
  or sandbox-B signing key (T-1102).** `0.5.5` is the first pinned gateway
  built with the T-1102 check (`checkNoAISigningKey`), which refuses to boot
  while `LCR_AI_SIGNING_KEY`, `VEIL_AI_SIGNING_KEY`,
  `LCR_SANDBOX_B_SIGNING_KEY` or `VEIL_SANDBOX_B_SIGNING_KEY` is non-blank in
  the **gateway's** environment. **Before** `helm upgrade`, set
  `gateway.secrets.values.veilAISigningKey` to `""` (or drop the key from a
  Secret you manage yourself). On Compose the shipped gateway service passes
  none of the four; check only overlays you added yourself — and do **not**
  blank `LCR_SANDBOX_B_SIGNING_KEY` in `customer.env`, which sandbox B itself
  needs. Doctor checks the value, not the order. From this image on, Sensitive Mode
  certificates the gateway seals read `overall_verdict: failed` until the
  gateway has its own witness identity; the Lucairn desktop app shows that
  signed verdict in builds from desktop source `4087d586`
  (2026-09-28, T-1114) onward — the app has no separate release number yet. Details: the T-1102
  entry under **Changed** below.
- **Sanitizer roster: 34 → 36 (T-768).** `attribution_person` and
  `labeled_id` are now on both shipped surfaces. The ServiceNow attribution
  leak (`"Reviewed by <Name>"` passing unredacted) is **closed on 0.5.5** for
  installs that use the shipped sanitizer config. Details: the T-768 entry
  under **Fixed** below.
- **Upgrade from 1.9.4 / 0.5.4:** set `LUCAIRN_IMAGE_TAG=0.5.5` (Compose) or
  `global.imageTag: "0.5.5"` (Helm), after the T-1102 step above. The 12
  `dsa-*` images are republished, cosign-signed and Rekor-logged at `0.5.5`
  (`bin/lucairn verify-images --tag 0.5.5`; digests in
  `keys/image-digests-0.5.5.txt`). `dsa-pii-ml` stays `0.5.1`;
  `lucairn-dashboard` stays `0.8.2`.
- **Migration review (docs/RELEASING.md § Migration review) — audit ceiling
  raised 6 → 7; the others unchanged: veil-witness 10 · id-bridge 4 ·
  sandbox-a 8.** The `0.5.5` images carry migrations above two of the old ceilings (measured 2026-10-04
  in the published `0.5.5` images' `/migrations`: veil-witness up to `000014`,
  audit up to `000007`, id-bridge `000004`, sandbox-a `000008`):
  - **veil-witness `000011`–`000014`** (`certificate_persistence_outbox`,
    `claim_receipts`, `decoder_expiry`, `partition_veil_certificates`). Not
    applied: `000011`/`000012` hold un-redacted claim data with no deletion
    path in this kit, and `goto 13`/`14` passes through them. At 0.5.5 the
    witness detects the v10 schema and runs its documented reduced-durability
    posture (direct certificate writes; legacy claim write-through) instead of
    failing — `services/veil-witness/internal/durability/posture.go`
    `ResolvePosture`; partition maintenance is a no-op on an unpartitioned
    table.
  - **audit `000007_claim_delivery_outbox`** (table `audit_claim_deliveries`).
    **Applied: the audit ceiling is now 7** (chart, Compose and the
    `migrations/audit/` mirror). The 0.5.5 audit service writes this table
    inside the same transaction as every pipeline-completion audit event
    whenever its witness emitter is enabled (the kit default,
    `LCR_ENABLED=true`), and has no degraded-schema fallback: capped at 6,
    that insert would fail, `EmitEvent` would return an error, and a
    production gateway (audit fail-closed) would answer proxied requests with
    `503 audit_evidence_unavailable`. **Upgrading: remove any
    `LUCAIRN_MIGRATE_TARGET_AUDIT=6` (Compose) or
    `audit.migrations.targetVersion: 6` (Helm) override you set earlier** —
    it would hold the schema below 7 with the same 503 result.
    Data held: request id, delivery state, the output-scan summary
    (hashes, offsets, counts and entity types per `proto/audit/v1/audit.proto`
    `output_scan_body`) and the signed claim bytes — no raw flagged text.
    Hashes of personal values can still count as pseudonymous personal data.
    ⚠ **Known gap — no deletion path yet (T-1219).** The service only inserts
    and updates rows; nothing in this kit deletes them, and the offsite backup
    CronJob (when enabled) copies the whole audit database. This is a
    deliberate, recorded exception to RELEASING.md step 3, taken because the
    alternative is an audit service that refuses every request. A retention
    period and a deletion path are tracked in T-1219. **Closed in
    [1.9.6](#196--2026-10-04--images-055):** a default-on retention sweep blanks
    the claim bytes and scan summary of delivered rows after 30 days.

### Added
- **[Security] The `witness-central` topology now refuses to start when the
  central witness is a Lucairn-operated host (T-682).** The overlay repoints
  every claim emitter at `LUCAIRN_CENTRAL_WITNESS_ADDR`, and one of those claims
  — the sanitizer's `PII_SANITIZED` — carries `redaction_manifest_body`, the
  placeholder→original map. Until now nothing in code stopped an operator from
  pointing that at `lucairn.eu` / `dsaveil.io`: the requirement that the central
  witness be "a server the consultant does not administer" existed only as a
  sentence in `docs/WITNESS_CENTRAL_RUNBOOK.md` § 1. A 2026-08-21 review named
  it: the overlay was *prose-guarded, not code-guarded*.

  Enforcement now lives at both points that actually consume the address:

  - **Compose** — a run-once preflight service `witness-egress-guard`
    (`scripts/witness-egress-guard.sh`) that `audit`, `id-bridge`, `sanitizer`,
    `gateway`, `sandbox-b` and `lucairn-dashboard` all declare
    `depends_on: condition: service_completed_successfully`. A refusal fails
    `docker compose up`; no emitter starts. It is defined in
    `docker-compose.customer.yml` because that is the only file both the
    witness-central overlay and `docker-compose.self-hosted.yml` are applied on
    top of.
  - **Helm** — the umbrella validator `validators.witnessCentralLucairnEgress`
    fails the render on the same domain set.

  Both surfaces check all three operator-facing witness addresses — the claim
  port (`LUCAIRN_CENTRAL_WITNESS_ADDR` / `<sub>.veilWitnessAddr`), the
  certificate port (`LUCAIRN_CENTRAL_WITNESS_CERT_ADDR` /
  `gateway.veilWitnessCertAddr`) because `GetCertificate` /
  `ExportCertificates` serve the same manifest bodies back out, and the
  dashboard's own cert-port dial (`LUCAIRN_DASHBOARD_WITNESS_ENDPOINT` /
  `dashboard.witness.endpoint`), which the witness-central runbook § 9 tells
  operators to repoint at the central witness. For a full
  `dns://authority/endpoint` target both halves are checked, since the
  authority is the name server and the endpoint is the host actually dialled.

  The single escape hatch is
  `LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS=true` (Compose,
  exactly `true`/`false`, no other spelling accepted) or
  `witnessEgress.unsafeAcknowledgeLucairnOperatedWitness=true` (Helm, a real
  YAML boolean). It is recorded rather than silently honoured: Compose prints a
  banner naming the host and the payload into the container log on every start,
  Helm renders a `lucairn-unsafe-lucairn-operated-witness` ConfigMap carrying
  the same text.

  Stated limits, in the runbook as well as here: the check is **name-based**
  (a bare IP pointing at Lucairn is not caught) and it is **not a privilege
  boundary** (anyone who can edit the install files or pass `--set` bypasses
  it). What it buys is that the egress cannot happen by accident and that the
  deliberate choice is named and recorded. Suite:
  `tests/test_witness_central_egress_guard.sh`.

  **No change to a stock install:** all three variables are unset there, the
  guard prints one line and exits 0. It is a run-once job, so it does not appear
  in a steady-state `docker compose ps` — read it with
  `docker compose logs witness-egress-guard`.
- **Database migrations are capped at a pinned version; an open-ended
  `migrate up` now requires an explicit operator opt-in (T-350).** No kit
  install runs one by default, and no drift can cause one; only the
  `unsafeAcknowledge…` flag below can. Every migration Job used to run
  `migrate -path=… -database=… up`, which applies every migration file it
  finds. On the Helm path those files come from the **service image**
  (`cp -r /migrations /shared/migrations`), not from this repository — so which
  tables a customer install created was decided by whichever image tag happened
  to be pinned. Concretely: the veil-witness **source tree** carries
  `000011_certificate_persistence_outbox`, `000012_claim_receipts` (table
  `witness_claim_receipts`) and `000013_decoder_expiry`. The first two hold
  un-redacted personal data and **this kit ships no deletion path** for either.
  The `0.5.4` tag carried none of them — measured, its `/migrations` stopped
  at `000010` — so the exposure was the *next* image bump, which an uncapped
  `up` would have taken silently. That bump is `0.5.5` (this release): see
  **Read first** above for its migration review. `000013` is the decoder
  retention machinery, but `goto 13` applies 011 and 012 on the way, so it
  cannot be taken without them. A routine image-tag bump was sufficient to start creating
  them at a customer site, silently.

  Both install paths now migrate to a pinned target version and stop:
  `<subchart>.migrations.targetVersion` (Helm) and
  `LUCAIRN_MIGRATE_TARGET_<SERVICE>` (Compose), defaulting to the highest
  version this release reviewed — **veil-witness 10 · audit 7 · id-bridge 4 ·
  sandbox-a 8**, the last version in each `migrations/<tree>/` mirror. The
  ceiling is not operator configuration: on Helm it is a template literal that
  `--set` and `-f` cannot reach (over-ceiling fails the render), and on Compose
  it lives in the release-shipped, read-only-mounted
  `scripts/migration-ceilings.conf` rather than in an `environment:` value that a
  second `-f` overlay or `docker compose run -e` could raise. Three env-side
  routes to a higher cap are refused: a disagreeing `MIGRATE_KNOWN_SAFE_MAX`, a
  `MIGRATE_CEILING_FILE` that does not sit beside the runner, and a
  `MIGRATE_CEILING_KEY` naming another database's (higher) ceiling. This is not
  claimed as a privilege boundary — anyone who can pass `-e` can also edit their
  own install files — but every route now needs a deliberate edit to a shipped
  file, and the job logs the ceiling *and its source file* so a raised run is
  distinguishable after the fact. Fail-closed: an
  unset, zero, non-numeric, or over-ceiling target applies **nothing** and
  exits loudly rather than falling back to `up`; so does a dirty
  `schema_migrations` ledger. The job also reads the current version first and
  exits 0 without acting when the database is already at or beyond the target,
  so it can never migrate **down** (`migrate goto` would otherwise run
  `.down.sql`). Mechanism:
  `charts/lucairn/charts/<subchart>/templates/_migration-cap.tpl` + `scripts/migrate-capped.sh`;
  guard suite `tests/test_migration_version_cap.sh`.

  Escape hatch, for operators who have reviewed their own migrations and accept
  the consequences: `<subchart>.migrations.unsafeAcknowledgeOpenEndedMigrateUp=true`
  (Helm) / `LUCAIRN_MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP_<SERVICE>=true`
  (Compose). It is **per service**, so unblocking one database cannot silently
  open the others; it restores the old behaviour, prints a loud banner, and
  `bin/lucairn doctor` reports it. Nothing else reaches an open-ended `up`.

  Two install shapes the cap does not cover, stated rather than implied: an
  external-Postgres install (`postgresql.enabled=false`) renders no migration Job
  at all, and a migration left *below* the ceiling is silent-green — the service
  starts against a schema older than its code after a stderr NOTICE. Both are in
  `docs/RELEASING.md` § "Migration review".

  **Known gaps, unchanged by this release:** there is still no deletion or
  retention path for `witness_certificate_persistence_outbox` /
  `witness_claim_receipts`. Note also that `000013_decoder_expiry` — the decoder
  retention machinery — sits above the ceiling, and `goto 13` applies 011 and 012
  on the way, so the retention migration cannot be taken without also taking the
  two tables that have no retention path. The cap keeps the kit from creating them by drift;
  it does not delete them where they already exist, and the offsite backup
  CronJob `pg_dump`s whole databases without pruning. Tracked on T-350.
- **Release-blocking migration review (T-350).** `docs/RELEASING.md` gains a
  "Migration review" section: every kit release that bumps a pinned image tag
  or touches `migrations/` must enumerate the new migrations, state the
  data-retention impact of each, and **block on the absence of a deletion path**
  for any table holding personal data before the version ceiling may be raised.
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
- **`bin/lucairn doctor --tools` — dry-run the gateway's tool-schema PII guard
  before the first routed turn (T-498).** The kit ships
  `GATEWAY_TOOL_SCHEMA_GUARD=refuse` (T-493), so the gateway enforces from the
  very first request with no observation window. That default was chosen on an
  *arithmetic* false-positive estimate over random hex, not on a *measurement*
  over real tool schemas — this command is what converts the estimate into a
  fact for one install. It replays the shipped guard offline over a tool payload
  you supply (`--tools-file`, or `-` for stdin; a bare `tools` array, an
  Anthropic/OpenAI request body, or an MCP `tools/list` response) and reports
  every finding with its matcher class, its location, and which modes would
  refuse it, plus a summary (`N finding(s); M would 400 under 'refuse', K under
  'refuse_high_confidence'`). It exits non-zero when the effective mode would
  reject the payload, so it drops into a pre-deploy pipeline. The mode comes
  from `--tools-mode`, else `GATEWAY_TOOL_SCHEMA_GUARD` in `--env`, else the
  gateway's own `refuse` default — with the same fail-safe parsing the gateway
  uses (unset, empty and misspelled all resolve to `refuse`, loudly for the
  last). No network, no running stack, no cluster; `python3` only.
  The matched value is never printed, and by default neither are your property
  names: locations render as a pointer skeleton with client-authored key
  segments replaced by a `<k:…>` fingerprint, mirroring what the gateway is
  allowed to write to a log sink. `--reveal-pointers` opts into the
  caller-facing pointers for the local fix loop.
  The guard logic in `bin/lucairn-tool-schema-guard.py` is a port of
  `dual-sandbox-architecture` `services/gateway/internal/api/{tool_schema_pii_guard,
  iban_checksum,tool_name_pii_guard}.go` at `08e1afb6b`. It runs BOTH gateway
  walks (permissive, and the strict re-walk with the digit-run matcher off) so
  each mode's verdict comes from the walk that actually decides it — modelling
  `refuse_high_confidence` as a filter over the permissive findings is wrong,
  because a numeric literal can be a low-confidence digit-run hit permissively
  and a fail-closed `bounds_exceeded` refusal strictly. Verified against the Go
  implementation over 57 adversarial cases and 7000 randomised payloads: zero
  disagreements on kind, matcher class, detail or pointer skeleton, on either
  walk. A clean report means "the guard as shipped would forward this payload",
  never "this payload is free of personal data". See OPS.md §
  "Tool-schema PII guard" → "Dry-run it BEFORE the first routed turn".

### Changed
- **[Security] The gateway must not hold a `dsa-ai` signing key (T-1102).**
  The witness trusts exactly one `dsa-ai` public key — sandbox B's. A gateway
  holding sandbox B's seed can sign claims the witness accepts as sandbox B's,
  which breaks the separation between the two services. Older chart comments
  told operators to give the gateway's `LCR_AI_SIGNING_KEY`
  (`gateway.secrets.values.veilAISigningKey`) the same seed as sandbox B for
  Sensitive Mode; that instruction is removed.
  - **Doctor now fails** when the chart's own gateway Secret would carry a
    non-empty `LCR_AI_SIGNING_KEY` (`veilAISigningKey` in your Helm values),
    and on Compose when `LCR_AI_SIGNING_KEY` (or legacy `VEIL_AI_SIGNING_KEY`)
    in `customer.env` equals `LCR_SANDBOX_B_SIGNING_KEY`. With an
    external-secret backend doctor cannot see the Secret and prints an INFO
    note instead. It never prints the key.
  - **The chart's own ExternalSecret no longer delivers the key:** the
    gateway ExternalSecret stops mapping `LCR_AI_SIGNING_KEY`, and the Kind
    mTLS runtime-values generator and `values-test.yaml` leave it empty. A
    Secret you create or extend yourself can still carry it — keep it out.
  - **Upgrade note:** gateway images built with T-1102 (pinned from kit 1.9.5,
    images `0.5.5`) refuse to boot while any of `LCR_AI_SIGNING_KEY`,
    `VEIL_AI_SIGNING_KEY`, `LCR_SANDBOX_B_SIGNING_KEY` or
    `VEIL_SANDBOX_B_SIGNING_KEY` has a non-blank value in the gateway's
    environment. Remove them
    from the gateway's config before upgrading. Until the gateway has its own
    signing identity at the witness, Sensitive Mode certificates it seals read
    `overall_verdict: failed`.
    ⚠ Release ordering: kit 1.9.5 is the first release that pins a T-1102 gateway image
    (`0.5.5`); its **Read first** block above carries this note. Any kit release that bumps
    `default_lucairn_image_tag` (image-manifest.yaml) to a gateway built
    from dual-sandbox-architecture main after PR #681 MUST (a) carry this note at the top of
    its release notes, (b) state that `LCR_AI_SIGNING_KEY` must be blank in the gateway
    Secret/customer.env BEFORE `helm upgrade` / `docker compose up` (doctor checks the
    value, not the order), and (c) name the desktop version whose certificate chip reads the
    signed verdict, because Sensitive Mode certificates read `overall_verdict: failed`
    from that image onward until the gateway has its own witness identity.
  - **If you ever followed the old "same seed as sandbox B" comment, removing
    the key does not revoke it.** Rotate sandbox B's key as described in
    [`docs/KEY_CEREMONY_RUNBOOK.md` § 9.4](docs/KEY_CEREMONY_RUNBOOK.md#94-sandbox-b-key-held-by-a-gateway-t-1102);
    note that after the rotation, older certificates whose `dsa-ai` claim was
    signed with the old key fail a fresh witness check, so the runbook
    requires a witness release with key history before you rotate.
- **Upgrade note — gateway evidence-admission settings are now exact enums,
  checked at render time (T-871).** A gateway image built from
  dual-sandbox-architecture main `c3d2aa0d` or later (DSA #622) **refuses to
  boot** on any SET `GATEWAY_EVIDENCE_ADMISSION_POSTURE` other than exactly
  `enforce` or `log`, and on any SET `GATEWAY_EVIDENCE_BOOT_MODE` other than
  exactly `` (empty), `strict` or `permissive`. Older images read `ENFORCE`,
  `Enforce` and ` enforce ` as enforce and silently read every other value
  (`""`, `production`, a `$(DSA_ENV)` reference) as LOG — so an install that
  worked yesterday CrashLoops after the next gateway image re-pin, with no
  chart-time error.
  - **Helm:** `gateway.evidenceGap.posture` must be exactly `enforce` or `log`;
    `ENFORCE`, `Enforce`, ` enforce `, `""` and any value containing `$` now
    fail `helm template` / `helm upgrade` with a message that describes the
    value's shape (it never echoes the value). `posture: null` renders no env
    line at all (the gateway reads UNSET as LOG).
    `gateway.evidenceGap.bootMode` must be exactly `""`, `strict` or
    `permissive` (`""`/null render no env line).
  - **Compose / plain env:** set exactly `enforce` or `log`. If you template
    the value from your shell, write `${X:-log}`, not `${X}` — an unset `X`
    expands to an empty-but-SET variable, which the new gateway refuses.
  - **Also refused at render now:** any `$` in the other literal env values
    and args the gateway and sandbox-a (sanitizer) sub-charts render from
    Helm values (ports, session/wait timeouts, streaming knobs, the evidence
    gap path, the mTLS mount path and key names, the sanitizer's L3 posture,
    pii-ml endpoint/transport, cache/stream-state backend, Redis URLs and
    TTLs, Ollama keep-alive, the sandbox-a Postgres user/database), because
    Kubernetes expands `$(NAME)` and reduces `$$` in env values and args at
    Pod creation. Renders of every shipped values file are byte-identical to
    before. Regression: `tests/test_gateway_env_enum_guard.sh`.
- **⚑ BREAKING — `LUCAIRN_L3_REQUIRED` is retired; certificates now say
  `COMPLETENESS_PARTIAL` when the L3 deep PII shield did not run (T-393 /
  T-385).** The retired variable welded together two unrelated questions that
  are answered by two different services, so no single value could express the
  combination most installs want. Each question now has its own flag, and they
  do **not** have to agree:

  | Question | Service | Flag / Helm value | Values | Default |
  |---|---|---|---|---|
  | What happens to a **request** when L3 is unavailable? | sanitizer | `LUCAIRN_L3_AVAILABILITY_POSTURE` / `global.l3AvailabilityPosture` | `degrade` \| `reject` | `degrade` |
  | What does the **certificate** claim when L3 did not run? | veil-witness | `LUCAIRN_L3_COMPLETENESS_POSTURE` / `global.l3CompletenessPosture` | `partial` (only — see below) | `partial` |

  **What you will notice — HELM INSTALLS ONLY.** On Helm, verification
  certificates for L1+L2-only requests change from `COMPLETENESS_FULL` to
  `COMPLETENESS_PARTIAL`. **Nothing about the scrubbing changed.** The chart
  shipped `global.l3Required: false` and rendered it onto the veil-witness pod,
  which made the witness certify FULL for requests the deep PII shield never
  saw — while `docs/CUSTOMER_HELM_RUNBOOK.md` described that same state as
  "honestly downgraded to PARTIAL". The documentation was describing the
  behaviour operators were entitled to expect; the certificate now matches it.

  **Compose installs are unaffected on this point.** The Compose files never set
  the variable on the `veil-witness` service — only on the sanitizer — so the
  witness already defaulted to downgrading, and those installs already certified
  `COMPLETENESS_PARTIAL`.

  **`global.l3CompletenessPosture: full` is not available (board T-385,
  2026-08-04) — see the dedicated entry below.** An earlier draft of this
  release briefly offered `full` as an explicit opt-in to reproduce the old
  over-claiming wording; that offer is withdrawn before shipping.

  **⚠️ One availability default DID move: `docker-compose.self-hosted.yml` no
  longer defaults to fail-closed.** It used to supply
  `LUCAIRN_L3_REQUIRED=true`, so a hand-rolled `customer.env` carrying no L3
  line inherited fail-closed; it now supplies no posture, and that env inherits
  the image default `degrade`. Migrating the default instead (to
  `LUCAIRN_L3_AVAILABILITY_POSTURE=reject`) would have been an outage: it would
  have overridden the `LUCAIRN_L3_REQUIRED=false` that `lucairn-init` and
  `customer.env.example` have written **for all install paths** since 2026-06,
  skipping the boot refusal and fail-closing against a `qwen2.5:7b` model the
  kit does not stage by default — `503` on every request from an upgrade alone.
  **Self-hosted operators who want fail-closed must now set
  `LUCAIRN_L3_AVAILABILITY_POSTURE=reject` explicitly.** Everywhere else request
  availability is unchanged: `degrade` is behaviour-identical to the retired
  `false`, and the certificate still reports coverage loss regardless of
  posture.

  **Why it is breaking beyond the certificate:** both service images REFUSE TO
  START when they see `LUCAIRN_L3_REQUIRED` beside an unset replacement, rather
  than silently resolving to a posture the operator never chose. Until this
  release the kit set that variable **unconditionally** — the chart's
  `values.yaml` shipped `global.l3Required: false` and both pod templates
  rendered the env with an `else` branch, and the Compose files supplied a
  `:-false` / `:-true` default. A kit install picking up the newer images would
  therefore have CrashLooped — **both** pods on Helm (the chart rendered the
  variable onto each), the **sanitizer** on Compose (only that service ever
  received it) — on 100% of installs, from an image bump alone. Nothing now sets
  either variable unless an operator does.

  **Migration (delete the retired flag; do not leave it set):**
  - *Helm* — the chart sets no posture at all; a stock `helm template` renders
    **no** `LUCAIRN_L3_*` env and the images apply their own defaults. If your
    values file still carries `global.l3Required`, the render now `fail`s with a
    migration message unless both `global.l3AvailabilityPosture` and
    `global.l3CompletenessPosture` are set alongside it
    (`validators.l3LegacyFlagWithoutPosture`). Set both, then delete
    `global.l3Required`.
  - *Compose* — set `LUCAIRN_L3_AVAILABILITY_POSTURE` in `customer.env`
    (`lucairn-init` and `customer.env.example` now write `degrade`) and delete
    `LUCAIRN_L3_REQUIRED`. `bin/lucairn doctor` warns while the retired line is
    still present — and a leftover line is a boot refusal on **every** compose
    path, split and self-hosted alike, because neither file supplies a posture
    on your behalf (see the ⚠️ note above about the overlay's removed
    fail-closed default).
  - One key cannot express `degrade` + `partial` in any case: the two services
    derive **opposite** postures from the same retired value.

  `validators.l3AirGapWithoutFailClosed`'s fail-closed test moved with the flag,
  and moved COMPLETELY: it now accepts **only**
  `global.l3AvailabilityPosture=reject` (trimmed + lowercased, matching the
  sanitizer's own parser). The retired `global.l3Required` does **not** satisfy
  it in any value. A legacy arm was drafted and removed before merge — the
  sibling migration guard means it could only ever be reached alongside a
  posture that overrides it, so its one reachable effect would have been to let
  `degrade` through the air-gap guard, re-opening the exact silent-shield-less
  install the guard exists to prevent. Air-gapped operators must therefore state
  the posture explicitly.
  Upstream design: `prd-2026-08-01-l3-availability-vs-certificate-honesty-split.md`.
- **[Security] `global.l3CompletenessPosture=full` is no longer an available
  value (board T-385, 2026-08-04).** This is an honesty guarantee, not a
  feature removal: `full` let an operator configure the veil-witness to
  certify `COMPLETENESS_FULL` / `VERDICT_VERIFIED` for a request the deep PII
  shield (L3) never scanned — `llm_pii_scan` absent from `layers_active`
  while the certificate said otherwise. `partial` is now the only value this
  chart's render-time allowlist accepts (`validators.l3PostureValues` and its
  per-pod mirror in `charts/veil-witness/templates/deployment.yaml`); setting
  `full` fails `helm template` / `helm install` / `helm upgrade` rather than
  producing a certificate that over-claims. The veil-witness image's own
  Go-side parsing of `full` is untouched by this change — that is a separate,
  not-yet-scheduled retirement — this entry closes only the path a Helm
  install used to configure it through. A certificate can only ever say FULL
  now by a request genuinely having run L3.
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

  **The recommended install path is fixed to match.** `scripts/render-
  values.sh` (`INSTALL.md` § "Option A — automated") never filled
  `admin.secrets.values.adminPassword` or `observability.secrets.values.
  grafanaAdminPassword` — both render into a live Secret on a **default**
  install (`admin` has no enable gate; `observability.enabled` defaults to
  `true`) — and its own self-check warning mischaracterized both as
  "opt-in feature placeholders", masking the gap. Before the guard fix
  above this silently shipped the published placeholder string as a real
  Grafana/admin credential on every default install; with the guard fix
  alone (and this script unchanged) it would instead have hard-failed the
  recommended install path outright. The renderer now generates both
  credentials the same way it already generates the adjacent
  `auditAppPassword` / `veilAppPassword` slots, and the self-check warning
  text no longer asserts every leftover token is safely opt-in — it tells
  the operator to verify each one instead. A new end-to-end test
  (`tests/test_sec_hardening.sh`, "T-490b-E2E") runs the renderer and then
  `helm template`s its own output against default umbrella values,
  asserting a clean render with zero `REPLACE_WITH_*` tokens surviving into
  any rendered Secret — the control whose absence hid this gap.

### Removed
- **`observability.grafana.adminPassword` (dead key).** No template ever read it,
  so setting it never protected the Grafana admin account — the Grafana pod reads
  the `grafana-admin` Secret, which is rendered from
  `observability.secrets.values.grafanaAdminPassword`. Rather than drop it
  silently, `observability/templates/_validate.tpl` now fails the render with a
  migration message if a values file still sets it.

### Fixed
- **The sanitizer recognizer roster was 13 entries behind the upstream default,
  and nothing noticed (T-768).** `config/default-sanitizer.yaml` and the Helm
  `sandbox-a` sanitizer ConfigMap both listed 33 recognizers under
  `sanitizer.presidio.custom_recognizers`; the upstream sanitizer default lists
  46. A recognizer that is not listed is never loaded, and the sanitizer boots
  and answers normally, so the gap was silent. Both surfaces now carry **36**
  (34 on images `0.5.4`, plus 2 that only `0.5.5` registers).
  Of the 13 upstream names:
  - **Added (3):** `medical_record_number` (the glued `MRN123456` form:
    `MRN`, an optional `-` or space, 6-10 digits). It is in the recognizer
    registry of the `dsa-sanitizer:0.5.4` image, and it is narrow: no
    false-positive class was found. Plus, on `0.5.5`: `attribution_person`
    (registered at `services/sanitizer/recognizers.py:1761` on DSA main
    `f70d0fe8`; licensed by a closed list of attribution verbs, not by shape)
    and `labeled_id` (`recognizers.py:2030`; fires only when an ID label such
    as "Patientennummer" or "customer number" is present). The ServiceNow
    attribution leak class (`"Reviewed by <Name>"` passing unredacted, fixed
    upstream by `attribution_person`) is **closed on 0.5.5**.
  - **Opt-in only, for healthcare / clinical installs (2):** `de_places` and
    `drugs_and_diagnoses`. Both are in the `0.5.4` image, but on it they flag
    ordinary words above the kit's 0.35 threshold: `de_places` (LOCATION,
    score 0.40) tags the German "oder" and "buchen" and the English "worms";
    `drugs_and_diagnoses` (MEDICAL_CONDITION, score 0.55) tags "pain" and
    "fatigue". Add them under `sanitizer.presidio.custom_recognizers` only if
    catching place, drug and diagnosis names is worth redacting those words
    too. Compose: add them to your sanitizer config. Helm: the chart has no
    supported values key for the roster, so this means carrying the change in your copy of the
    `sandbox-a` sanitizer ConfigMap template.
  - **No-ops, not listed (2):** `de_companies` (ORGANIZATION) and
    `software_products` (PRODUCT). The scanner discards both entity types —
    still true on `0.5.5` (`_SKIP_ENTITY_TYPES`,
    `services/sanitizer/presidio_scan.py:516` on `f70d0fe8`) — so listing them
    redacts nothing; this release makes no company or product coverage claim.
    They become useful only once a kit release pins a sanitizer image that
    keeps those entity types.
  - **Held back for false positives (6):** `format_ticket`,
    `format_numeric_run`, `format_hex_block`, `format_uuid`, `format_ulid`,
    and `patientennummer_id_prefix` (registered from `0.5.5`). They fire on
    shape alone: on `0.5.4` at the kit's 0.35 threshold the `format_*` group
    redacts ServiceNow `sys_id`s and git SHAs, request UUIDs and `INC0010001`
    / `ID-002882393`, which breaks agent and ServiceNow flows;
    `patientennummer_id_prefix` is in the same bare-shape class
    (`_BARE_SHAPE_ID_RECOGNIZER_PREFIXES`,
    `services/sanitizer/two_lane_zoner.py:279`). The sanitizer keeps those
    shapes intact only with its two-lane zoner. `0.5.5` has the zoner, but it
    is OFF unless the config sets `sanitizer.two_lane_zoner.enabled: true`
    (default `false`, `services/sanitizer/config.py:4677` and `:5507`), and this
    kit does not set it. Same decision the upstream Helm chart made for
    `format_ticket` and `patientennummer_id_prefix`.
  - **Fail-loud floor.** New `config/sanitizer-roster-must-have.txt` lists the
    36 names. `tests/test_sanitizer_roster_must_have.sh` (in `make test`) fails
    when either shipped surface lacks one, when the two surfaces differ, or
    when a held-back, opt-in or no-op name appears on a default surface.
  - **No runtime doctor check yet.** `bin/lucairn doctor` does NOT check an
    install's active sanitizer roster. A Python-free reader that tried to do
    this could be made to report a complete roster while the sanitizer's real
    YAML loader read none, so it was not shipped. A doctor check that asks the
    pinned sanitizer image's own loader is a follow-up. Until then, compare
    your config against `config/sanitizer-roster-must-have.txt` by hand.
  - **Upgrade note:** Helm installs get the new ConfigMap on `helm upgrade`,
    but the `sandbox-a` Deployment carries no ConfigMap checksum, so the
    running sanitizer keeps the old roster until the pod restarts:
    `kubectl -n <namespace> rollout restart deployment/sandbox-a`. Cached
    sanitizer results do not mask the change: the cache key folds in the
    roster. Compose installs that still use the shipped
    `config/default-sanitizer.yaml` get it with the new kit files; then
    `docker compose up -d --force-recreate sanitizer`. Compose installs with
    their OWN sanitizer config (`SANITIZER_CONFIG_FILE` pointing elsewhere)
    must add `medical_record_number`, `attribution_person` and `labeled_id`
    under `sanitizer.presidio.custom_recognizers` themselves (the last two only
    once they run images `0.5.5` — `0.5.4` refuses to boot on them), and should check their
    roster against `config/sanitizer-roster-must-have.txt`. Expect slightly more redaction of
    `MRN…` numbers, of names after attribution verbs ("Reviewed by …"), and of
    digit runs next to an ID label; nothing else new unless you opt in.
- **The L3 posture allowlists were blind to every value Sprig calls empty —
  including `false` and `0`, the two an operator is most likely to type
  (T-548).** All four posture guards coerced with `toString (default ""
  <value>)`, and Sprig's `default` decides emptiness with its own `empty()`,
  which counts the YAML boolean `false`, the number `0`, an empty list and an
  empty map as empty alongside `nil` and `""`. So `--set
  global.l3AvailabilityPosture=false` — a bare literal Helm infers as a boolean,
  and the guards' OWN documented most-likely error (renaming the retired
  `global.l3Required` and keeping its value) — coerced to `""`, hit the
  "absence" short-circuit, and never reached the allowlist. `hasKey` stayed
  true, so the pod template rendered `LUCAIRN_L3_AVAILABILITY_POSTURE: "false"`
  into the container and the sanitizer refused it at boot: CrashLoopBackOff,
  the exact outcome these render-time guards exist to prevent. The same held
  for `global.l3CompletenessPosture=false`, which is the wire form of the
  certificate posture T-385 deleted. `true` and `1` were caught all along
  (non-empty to Sprig), so only the `false`/`0` half of each enum was open.
  - The list/map half was worse than the scalars: the pod templates render the
    env var's `value:` from the RAW field, never from the guard's coerced
    variable, so `--set-json 'global.l3AvailabilityPosture=[]'` shipped
    `value: "[]"` into the container — and `{}` shipped `value: "map[]"`, Go's
    `fmt.Sprint` of an empty map.
  - The coercion now carves out untyped nil BY KIND (`kindIs "invalid"`, the
    same carve-out the T-490 secret guards use) instead of by Sprig emptiness,
    so every real value — including `false`, `0`, `[]` and `{}` — is compared
    verbatim. An
    empty *string* and a null `key:` are still ABSENCE and still take the image
    default; whitespace-only is still refused. Fixed at all four sites:
    `charts/lucairn/templates/_validators.tpl` (umbrella, both postures),
    `charts/lucairn/charts/sandbox-a/templates/deployment.yaml` and
    `charts/lucairn/charts/veil-witness/templates/deployment.yaml` (the
    pod-local mirrors that a subchart-scoped `global` reaches without passing
    the umbrella validator).
  - Same Sprig-`empty()` trap as the T-562 sanitizer-knob sweep and T-472; the
    enum validators were in neither sweep's blast radius. `tests/test_l3_posture_flags.sh`
    now probes the enums with bare `--set` (YAML-typed) as well as
    `--set-string` — the string-only probes are why this survived review.
- **`helm template` panicked when an Ingress was disabled by nulling its block
  (T-421 residual).** `charts/lucairn/charts/gateway/templates/ingress.yaml`
  and `charts/lucairn/charts/dashboard/templates/ingress.yaml` read
  `.Values.ingress.enabled` bare, and Go templates abort on a field access
  against untyped nil rather than treating it as false. So `--set
  gateway.ingress=null`, or a values overlay writing `ingress:` with nothing
  under it, killed the render with `nil pointer evaluating interface
  {}.enabled` — naming a pointer instead of the thing the operator turned off.
  `ingress.enabled: false` was the only spelling that worked and nothing said
  so. Both templates now bind `{{ $ingress := default dict .Values.ingress }}`
  and read through it, the same nil-safe shape the umbrella `NOTES.txt` half of
  this ticket already used. (That earlier fix's own commit message recorded
  this residual one template later and scoped it out.) New regression suite
  `tests/test_helm_ingress_nil_safety.sh`, wired into `make test`.
- **The gateway could not persist its evidence gap store — silently (T-573).**
  `charts/lucairn/charts/gateway/values.yaml` sets
  `containerSecurityContext.readOnlyRootFilesystem: true`, and the deployment
  mounted nothing at the evidence-gap path. Measured on a kit install: the
  gateway pod reached **1/1 Ready** while its own log said
  `evidence gap store at /data/evidence-gaps.jsonl is not writable... read-only
  file system`, then degraded silently — permissive boot mode plus the LOG
  posture admit every request while recording nothing durably, and
  `kubectl get pods` stays green. Under the ENFORCE posture the same chart would
  refuse ALL healthy traffic. Upstream twin: `dual-sandbox-architecture` T-571
  HIGH-1.
  - The gateway now gets a writable `evidence-gap` volume mounted at
    `evidenceGap.mountPath` (default `/data`), plus
    `GATEWAY_EVIDENCE_GAP_PATH` / `GATEWAY_EVIDENCE_ADMISSION_POSTURE` /
    `GATEWAY_EVIDENCE_BOOT_MODE`. The env var and the mountPath are derived from
    the SAME values, so they cannot drift apart.
  - Default backing is an `emptyDir` bounded by `evidenceGap.sizeLimit`
    (64Mi): writable, survives a container crash-restart, **not** pod
    rescheduling. `evidenceGap.persistence.enabled=true` opts into a
    ReadWriteOnce PVC that survives rescheduling — **single replica only**. The
    chart ABORTS the render when persistence is combined with
    `replicaCount > 1` or `hpa.enabled`, including when an `existingClaim` is
    supplied: a ReadWriteMany volume is **not** an escape hatch, because
    compaction rebuilds the whole file from one pod's in-memory map and renames
    it over the shared path, destroying the other replicas' records.
  - Posture default stays `log`. **Do not flip `evidenceGap.posture: enforce`
    on any install until the mount is confirmed present** — that is what turns
    the silent degradation into refused traffic.
  - Pinned by `tests/test_gateway_evidence_gap_volume.sh` (in `make test`),
    which asserts on the RENDERED manifest that a mount covers the configured
    path, is not readOnly, is a writable volume kind, and is openable by the
    container UID (`fsGroup`), with positive controls for the mount and for
    `fsGroup`.
  - Scope note: `dsa-gateway:0.5.4` predates the upstream feature (these env
    vars are inert on it); `0.5.5`, which this release pins, is built from a
    source that carries it (`services/gateway/internal/evidencegap`).
- **Every shipped sanitizer config set a RETIRED key that stops a clean install
  from coming up (T-576).** `charts/lucairn/charts/sandbox-a/templates/sanitizer-configmap.yaml`,
  `config/default-sanitizer.yaml` and `starter-templates/itsm/config.yaml` all
  set `presidio.strict_safe_terms_file: /config/safe-terms-strict.txt`. The
  sanitizer RETIRED that key on 2026-07-25 (upstream `dual-sandbox-architecture`
  commit `811ef43b0`, "consolidate 3 FP never-redact surfaces into
  redaction_policy") and deliberately made it a **boot refusal** rather than a
  silent no-op, because ignoring a still-set never-redact file would silently
  become over-redaction. Measured consequence on a sanitizer image built after
  that date: the sanitizer sidecar `CrashLoopBackOff`s → `sandbox-a` never
  becomes Ready → the gateway's isolation-invariant poller never verifies → the
  gateway restart-loops on its own startup probe, and the whole stack fails to
  come up. The ten product-vocabulary terms now ride
  `sanitizer.redaction_policy.stop_terms` with `surface: l1_strict`, which the
  current sanitizer reads and which reproduces the old semantics byte-for-byte
  (whole detected span, lowercased + stripped, exact match, any entity type —
  so `Claude` alone is suppressed while `Claude Müller` still redacts).
  `redaction_policy.enabled` is deliberately left unset: the `l1_strict` list
  applies regardless, while enabling the block would additionally activate the
  per-zone layer policy, which the kit has never shipped.
  - Helm operators get a new `sandbox-a.sanitizer.strictSafeTerms` list value to
    append their own strict terms — the replacement for editing the retired
    file. The now-dead `safe-terms-strict.txt` ConfigMap data key was removed.
  - `config/safe-terms-strict.txt` and its Compose bind-mount are RETAINED but
    no longer wired by any shipped config; they exist so an operator still on a
    pre-retirement image with a hand-written config keeps a real host-side mount
    source. Edit the `redaction_policy.stop_terms` block, not that file.
  - Pinned by `tests/test_sanitizer_retired_config_keys.sh` (in `make test`),
    and `bin/lucairn doctor` now warns when an operator-authored config declares
    `strict_safe_terms_file` or `gliner_stop_terms_file`.
  - Note on the pinned images: kit 1.9.4 pinned `dsa-*:0.5.4` (built
    2026-06-19), which PREDATES the retirement. Kit 1.9.5 pins `0.5.5`, which
    refuses the retired key — so the shipped configs must stay free of it, and
    so must any operator config carried forward from 1.9.4.
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
- **`docker-compose.customer.yml` sanitizer memory cap SIGKILLed workers on
  real Claude Code payloads (T-210).** The shipped `deploy.resources.limits.memory`
  was `2G`; idle RSS with models loaded is already ~1.3G, leaving little
  headroom before a real-sized turn pushes a worker over the cgroup cap and
  it gets SIGKILLed mid-scan. Raised to `4G`. `INSTALL.md` § "Memory
  requirements" updated to match.
- **`docker-compose.self-hosted.yml` sandbox-b rejected a real Claude Code
  first turn (T-211).** The image's built-in `MAX_PROMPT_CHARS` default is
  100000; a measured real Claude Code first turn was 141,767 characters and
  got rejected. The sandbox-b service block now sets
  `MAX_PROMPT_CHARS: "${MAX_PROMPT_CHARS:-400000}"`. Documented in
  `customer.env.example`.
- **`docker-compose.customer.yml` sanitizer had no explicit
  `SANITIZER_MAX_FIELD_CHARS` (T-212).** Left unset, the effective ceiling is
  whatever the pinned image's compiled-in default happens to be, so a kit
  install's behavior silently shifts across image vintages. The sanitizer
  service block now sets
  `SANITIZER_MAX_FIELD_CHARS: "${SANITIZER_MAX_FIELD_CHARS:-262144}"`
  (matches upstream `dual-sandbox-architecture`'s current default),
  pinning the kit's behavior independent of image vintage. Documented in
  `customer.env.example`.
- **`charts/lucairn/templates/NOTES.txt` nil-derefed when `gateway.ingress`
  was unset (T-421).** The two `.Values.gateway.ingress.enabled` /
  `.Values.gateway.ingress.className` references assumed `gateway.ingress`
  is always a populated map; when it resolves to nil (reproduced by
  `--set gateway.ingress=null`, and equally reachable from any values
  override that leaves the key unset), rendering panics with `nil pointer
  evaluating interface {}.enabled`. Both references are now nil-safe: `{{- $gatewayIngress
  := default dict .Values.gateway.ingress }}`, then `$gatewayIngress.enabled`
  / `$gatewayIngress.host` / `$gatewayIngress.className`.
  Verified with an isolated Go-template fixture reproducing the two
  expressions standalone: the bare form panics on an unset `gateway.ingress`
  and the nil-safe form renders cleanly with empty fallbacks, while a
  populated `gateway.ingress` renders identically either way.
  `helm template charts/lucairn` (default values, all required secrets
  supplied) renders byte-identical NOTES output before and after this
  change; `helm lint charts/lucairn` passes. A full end-to-end
  `gateway.ingress: null` render of the whole umbrella chart still fails —
  earlier, at the unrelated pre-existing `.Values.ingress.enabled` nil-deref
  in `charts/lucairn/charts/gateway/templates/ingress.yaml`'s own template,
  which is out of this fix's scope.

### Notes
- **Gateway-cache replay cert-honesty fix (T-409) has not shipped in any kit
  release.** Upstream `dual-sandbox-architecture` closed a gateway-cache hole
  where a turn whose certificate was honestly `COMPLETENESS_PARTIAL` (L3
  skipped by policy, tier, customer-allowlist, or zone policy) could still be
  written to the sanitize cache — a later cache-replay of that turn then
  rendered `COMPLETENESS_FULL` / `VERDICT_VERIFIED` with L3 never having run
  (merged 2026-08-02, `6d535775f`, PR #470). Sanitizer `0.5.4` predates the
  fix by about six weeks; `0.5.5`, which this release pins, is built from a
  source that carries it (`cert_full_eligible`). **On `0.5.4` and older,
  enabling `SANITIZE_CACHE_ENABLED` is not recommended.**
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
