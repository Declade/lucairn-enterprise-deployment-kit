# OPS

## Customer Lifecycle

Mint a new customer + first API key with `bin/lucairn-mint-customer` (run after `bin/lucairn doctor` reports `ok`). The script targets the gateway's `POST /api/v1/admin/keys` endpoint, applies tier defaults (Free / Pro / Enterprise) server-side, and prints the raw key once. See `bin/lucairn-mint-customer --help` for flag reference, env-var auth precedence (`LUCAIRN_ADMIN_KEY` preferred), and `--dry-run` to inspect the resolved payload before firing.

Tier promotion and key revocation are exposed by the gateway as `PATCH /api/v1/admin/keys/tier` and `DELETE /api/v1/admin/customers/{cid}/keys/{key_id}`. A future v2 of `bin/lucairn-mint-customer` will surface these as `--promote-tier` and `--revoke` subcommands.

## Monitoring

Minimum alerts:

- Gateway `/healthz` or `/readyz` non-200 for more than 5 minutes.
- Any service restart loop.
- Postgres volume above 80 percent.
- Certificate expiry under 30 days.
- Support bundle generation failure.
- Audit or Veil Witness write errors.
- Deployment license entering grace or degrade: `gateway_license_state{phase="grace"} == 1` (renewal due) and `gateway_license_state{phase="degraded"} == 1` (Enterprise features now locked). See the License section below.

Kubernetes installs should also alert on unavailable replicas, HPA maxed out for more than 15 minutes, and denied network-policy traffic that indicates unexpected cross-zone access.

## Logs

Docker Compose:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env logs --tail 300 gateway
docker compose -f docker-compose.customer.yml --env-file customer.env logs --tail 300 sanitizer
docker compose -f docker-compose.customer.yml --env-file customer.env logs --tail 300 veil-witness
```

Kubernetes:

```bash
kubectl logs -n dsa-edge deploy/gateway --tail=300
kubectl logs -n dsa-identity deploy/sandbox-a --tail=300
kubectl logs -n dsa-witness deploy/veil-witness --tail=300
```

## Backups

> ⚠ **The three compliance databases hold your regulator-cited evidence.**
> `audit` (immutable audit trail — AI Act Art. 12 / GDPR Art. 30), `bridge`
> (re-linkage tokens — GDPR DSAR / erasure), and `veil` (signed witness
> certificates). This data is NOT recoverable once the volume is gone. On the
> Helm path the PVCs carry `helm.sh/resource-policy: keep` so `helm uninstall`
> does NOT delete them — but disk loss, a deliberate `kubectl delete pvc`, or a
> Compose `docker compose down -v` still destroys them. **Take a backup before
> any uninstall/reinstall, PVC deletion, version upgrade, or host migration.**

Back up these volumes or databases:

- `pg-audit-data` (DB `audit`) — **compliance**
- `pg-bridge-data` (DB `bridge`) — **compliance**
- `postgres-veil-data` (DB `veil`) — **compliance**
- `pg-sandbox-a-data` (DB `sandbox_a`)
- `gateway-data`
- `cert-store` when certification is enabled

Recommended minimum:

- Nightly encrypted database backups.
- 30-day retention.
- Quarterly restore test (see "Restore validation" below).
- Backup encryption key held outside the Lucairn host.

### Compose path — backup (logical `pg_dump`)

Run from the kit directory. These are logical dumps in custom format
(`-Fc`), which restore cleanly across patch versions and are safe to gzip.

```bash
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="./backups/${STAMP}"
mkdir -p "${OUT}" && chmod 700 "${OUT}"

# Compliance DBs. Adjust users if you changed POSTGRES_*_USER:
#   postgres-audit  -> DB audit,  user dsa
#   postgres-bridge -> DB bridge, user dsa
#   postgres-veil   -> DB veil,   user veil
for svc_db_user in \
  "postgres-audit:audit:dsa" \
  "postgres-bridge:bridge:dsa" \
  "postgres-veil:veil:veil"; do
  svc="${svc_db_user%%:*}"; rest="${svc_db_user#*:}"; db="${rest%%:*}"; usr="${rest##*:}"
  docker compose -f docker-compose.customer.yml --env-file customer.env \
    exec -T "${svc}" pg_dump -U "${usr}" -d "${db}" -Fc \
    > "${OUT}/${db}.dump"
done

# Verify each dump is non-empty and lists a table-of-contents.
for db in audit bridge veil; do
  test -s "${OUT}/${db}.dump" || { echo "EMPTY DUMP: ${db}"; exit 1; }
  pg_restore --list "${OUT}/${db}.dump" >/dev/null \
    && echo "OK ${db} ($(du -h "${OUT}/${db}.dump" | cut -f1))"
done
```

### Compose path — restore (`pg_restore`)

Restore into a freshly provisioned, EMPTY database (the dump does not
truncate existing rows). For the append-only audit DB, restore into a clean
DB only — never replay a dump over a populated audit trail.

```bash
SRC="./backups/<STAMP>"   # the directory produced by the backup step

for svc_db_user in \
  "postgres-audit:audit:dsa" \
  "postgres-bridge:bridge:dsa" \
  "postgres-veil:veil:veil"; do
  svc="${svc_db_user%%:*}"; rest="${svc_db_user#*:}"; db="${rest%%:*}"; usr="${rest##*:}"
  docker compose -f docker-compose.customer.yml --env-file customer.env \
    exec -T "${svc}" pg_restore -U "${usr}" -d "${db}" --no-owner --clean --if-exists \
    < "${SRC}/${db}.dump"
done
```

### Helm path — backup (logical `pg_dump`)

The compliance Postgres pods are `audit-postgresql-0` (ns `dsa-audit`),
`id-bridge-postgresql-0` (ns `dsa-bridge`), and
`veil-witness-postgresql-0` (ns `dsa-witness`). The DB password is in each
chart's `<chart>-credentials` Secret under key `POSTGRES_PASSWORD`; pass it
via `PGPASSWORD` so it never lands in shell history.

```bash
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="./backups/${STAMP}"
mkdir -p "${OUT}" && chmod 700 "${OUT}"

# ns:pod:db:user:secret
for row in \
  "dsa-audit:audit-postgresql-0:audit:dsa:audit-credentials" \
  "dsa-bridge:id-bridge-postgresql-0:bridge:dsa:id-bridge-credentials" \
  "dsa-witness:veil-witness-postgresql-0:veil:veil:veil-witness-credentials"; do
  ns="${row%%:*}";  r="${row#*:}"
  pod="${r%%:*}";   r="${r#*:}"
  db="${r%%:*}";    r="${r#*:}"
  usr="${r%%:*}";   sec="${r##*:}"
  pw="$(kubectl -n "${ns}" get secret "${sec}" \
        -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
  kubectl -n "${ns}" exec -i "${pod}" -- \
    env PGPASSWORD="${pw}" pg_dump -U "${usr}" -d "${db}" -Fc \
    > "${OUT}/${db}.dump"
  unset pw
  test -s "${OUT}/${db}.dump" \
    && pg_restore --list "${OUT}/${db}.dump" >/dev/null \
    && echo "OK ${db} ($(du -h "${OUT}/${db}.dump" | cut -f1))"
done
```

### Helm path — restore (`pg_restore`)

```bash
SRC="./backups/<STAMP>"

for row in \
  "dsa-audit:audit-postgresql-0:audit:dsa:audit-credentials" \
  "dsa-bridge:id-bridge-postgresql-0:bridge:dsa:id-bridge-credentials" \
  "dsa-witness:veil-witness-postgresql-0:veil:veil:veil-witness-credentials"; do
  ns="${row%%:*}";  r="${row#*:}"
  pod="${r%%:*}";   r="${r#*:}"
  db="${r%%:*}";    r="${r#*:}"
  usr="${r%%:*}";   sec="${r##*:}"
  pw="$(kubectl -n "${ns}" get secret "${sec}" \
        -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
  kubectl -n "${ns}" exec -i "${pod}" -- \
    env PGPASSWORD="${pw}" pg_restore -U "${usr}" -d "${db}" \
        --no-owner --clean --if-exists \
    < "${SRC}/${db}.dump"
  unset pw
done
```

### Restore validation

A backup you have never restored is not a backup. Quarterly, restore the
latest dumps into a throwaway database (a scratch Compose stack or a temp
namespace) and assert row counts are non-zero and recent:

```bash
# Example: validate the audit dump restored into a scratch Postgres.
# (substitute your scratch connection details)
psql "<scratch-dsn>" -c "SELECT count(*) AS audit_events FROM audit_events;"
psql "<scratch-dsn>" -c "SELECT max(created_at) FROM audit_events;"
# Witness certs:
psql "<scratch-dsn>" -c "SELECT count(*) AS certificates FROM veil_certificates;"
```

Confirm the counts match the live system's order of magnitude and the
newest timestamp is within your RPO window. Record the validation date as
backup evidence (see the Upgrade runbook step 7).

> **Deferred (Tier-B, needs Marc decision + live Vast verify):** automated
> scheduling of these dumps. The Helm path will get a `CronJob` running
> `pg_dump` per compliance DB on a retention policy, and the Compose path a
> `bin/lucairn backup` / `bin/lucairn restore` wrapper, with documented
> RPO/RTO targets. Until then these are operator-run manual procedures. There
> is intentionally no point-in-time-recovery (WAL archiving) story here — the
> logical-dump RPO equals your backup interval.
### Automated backups (recommended)

> The PVCs carry `helm.sh/resource-policy: keep` so `helm uninstall` does NOT
> delete them. That stops accidental delete; it is NOT a backup. Disk loss, a
> deliberate `kubectl delete pvc`, a Compose `docker compose down -v`, or a host
> migration still destroys the data. The automated backups below are the real
> durability fix.

Lucairn ships automated, offsite, **client-side-encrypted** logical backups of
the three compliance databases:

- `audit` (immutable audit trail — AI Act Art. 12 / GDPR Art. 30),
- `bridge` (re-linkage tokens — GDPR DSAR / erasure),
- `veil` (signed witness certificates).

Each backup is `pg_dump -Fc` (logical, custom-format) → encrypted with
[`age`](https://github.com/FiloSottile/age) using an operator-held recipient
key → uploaded to a configured S3-compatible bucket (AWS S3, Hetzner Object
Storage, MinIO, Ceph). The bucket may be **your** bucket or one the operator
runs — no new sub-processor is forced. The bucket **never holds plaintext**
compliance data: the object is verified to carry the `age` header before
upload, and the pipeline aborts rather than upload an unencrypted dump.

RPO / RTO:

- **RPO = the backup interval** (default daily → up to ~24h of data loss in a
  worst-case full-volume loss). Tighten by lowering `backup.schedule` /
  `LUCAIRN_BACKUP_RETENTION_DAYS` cadence.
- **RTO = restore time**, dominated by dump download + `pg_restore` into a fresh
  DB. For the small compliance DBs this is typically minutes; measure it in your
  quarterly restore test and record the number here.
- There is intentionally **no point-in-time-recovery (WAL archiving)** — the
  logical-dump RPO equals your backup interval.

Retention: prune backups older than `retentionDays` (default 30). **Retention
must be ≥ your audit-evidence retention obligation** — do not lower it below
your regulator-mandated period.

> **Crypto-shred vs backup-aging caveat (DATA-08):** an encrypted backup
> contains the wrapped data-encryption keys (DEKs) that were live at dump time.
> After a record is crypto-shredded in the live DB (its wrapped key destroyed),
> that record's wrapped key still persists inside any backup taken **before** the
> shred, until that backup ages out per `retentionDays`. Account for this window
> when you document erasure timelines: full erasure of a record is only complete
> once every backup containing its wrapped key has aged out.

#### Helm path

Enable in `customer-values.yaml` (default OFF — existing installs are
unchanged):

```yaml
backup:
  enabled: true
  schedule: "30 2 * * *"     # daily 02:30 UTC; RPO == this interval
  retentionDays: 30          # >= your audit-evidence retention obligation
  s3:
    endpoint: ""             # blank = AWS S3; set for Hetzner/MinIO
    bucket: my-compliance-backups
    region: eu-central-1
    accessKeySecretRef: { name: lucairn-backup-s3, key: accessKeyId }
    secretKeySecretRef: { name: lucairn-backup-s3, key: secretAccessKey }
  encryption:
    recipientSecretRef: { name: lucairn-backup-age, key: recipient }
```

Pre-create the Secrets in EACH compliance namespace (`dsa-audit`, `dsa-bridge`,
`dsa-witness`) — the CronJobs run in their source DB's namespace:

```bash
# Generate the age key pair ONCE on a secured operator host. Keep the private
# identity OFF the cluster — it is required to restore.
age-keygen -o lucairn-backup-age.key            # prints the public recipient
RECIPIENT="$(grep 'public key:' lucairn-backup-age.key | awk '{print $NF}')"

for ns in dsa-audit dsa-bridge dsa-witness; do
  kubectl -n "$ns" create secret generic lucairn-backup-age \
    --from-literal=recipient="$RECIPIENT"
  kubectl -n "$ns" create secret generic lucairn-backup-s3 \
    --from-literal=accessKeyId="$AWS_ACCESS_KEY_ID" \
    --from-literal=secretAccessKey="$AWS_SECRET_ACCESS_KEY"
done
```

With `backup.enabled=true` the chart renders one CronJob per compliance DB
(`lucairn-backup-audit`, `lucairn-backup-id-bridge`, `lucairn-backup-veil-witness`).
A half-config (enabled without a bucket or without an age recipient) fails fast
at `helm install`/`template` with an actionable message — it will never silently
upload plaintext.

If your S3 credentials come from IRSA / an instance role, leave the
`accessKeySecretRef.name` / `secretKeySecretRef.name` empty.

> **⚠️ Backup CronJob + NetworkPolicy-enforced clusters (2026-05-29 full-stack test).**
> By default the backup CronJob installs its tools (`age`, `aws-cli`) at runtime
> via `apk add` in an init container (`backup.installToolsAtRuntime: true`). On a
> NetworkPolicy-ENFORCING cluster (Calico/Cilium — the [hard prerequisite for
> the Veil isolation invariant](docs/CUSTOMER_HELM_RUNBOOK.md#prereqs-1-time))
> the chart's egress NPs block the alpine package CDN, so the init container
> cannot reach the mirror and the job fails (and the public CDN is flaky even
> with egress allowed). The backup *logic* (pg_dump → age-encrypt → S3 upload)
> is identical to the proven `bin/lucairn backup` Compose path. To make the
> CronJob robust on an NP-enforced cluster, EITHER:
> - set `backup.installToolsAtRuntime: false` and point `backup.image` at a
>   pre-baked image that already contains `age` + `aws-cli` (recommended), OR
> - add a backup-egress NetworkPolicy allowing the init container to reach your
>   package mirror + S3 endpoint.

#### Compose path

`bin/lucairn` wraps the same pipeline against the compose stack:

```bash
# Set LUCAIRN_BACKUP_* in customer.env (bucket, region, age recipient,
# retention). S3 creds come from the standard AWS resolution (env / ~/.aws /
# instance role) — never from customer.env.
bin/lucairn backup  --env customer.env
bin/lucairn backup  --env customer.env --verify    # + restore-into-throwaway smoke
```

`--verify` decrypts each fresh dump (needs `LUCAIRN_BACKUP_AGE_IDENTITY_FILE`)
and restores it into a throwaway `postgres:16-alpine` container, asserting it
restores cleanly with non-zero tables.

### Restore runbook

A backup you have never restored is not a backup. Restore into a **freshly
provisioned, EMPTY** database — the dump does not truncate existing rows, and
for the append-only `audit` DB you must never replay a dump over a populated
audit trail.

Compose path:

```bash
# STAMP is the backup timestamp (YYYYMMDDTHHMMSSZ) in the S3 key.
bin/lucairn restore --env customer.env --stamp 20260529T023000Z
# Single DB only:
bin/lucairn restore --env customer.env --stamp 20260529T023000Z --db audit
```

Helm path (download + decrypt on a secured operator host, then pipe into the
live pod):

```bash
# NOTE the key prefix: the Helm CronJob writes under the CHART name
# (lucairn/audit/ , lucairn/id-bridge/ , lucairn/veil-witness/) — NOT the
# compose service name. See "S3 key prefixes differ between paths" below.
KEY="lucairn/audit/audit-20260529T023000Z.dump.age"
aws s3 cp "s3://my-compliance-backups/${KEY}" ./audit.dump.age
age -d -i lucairn-backup-age.key -o ./audit.dump ./audit.dump.age
PW="$(kubectl -n dsa-audit get secret audit-credentials \
      -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
kubectl -n dsa-audit exec -i audit-postgresql-0 -- \
  env PGPASSWORD="$PW" pg_restore -U dsa -d audit --no-owner --clean --if-exists \
  < ./audit.dump
```

> **S3 key prefixes differ between the Helm and Compose paths — they are NOT
> interoperable.** The Helm CronJob keys backups under the **chart** name:
> `lucairn/audit/`, `lucairn/id-bridge/`, `lucairn/veil-witness/`. The Compose
> `bin/lucairn backup` keys them under the **compose service** name:
> `lucairn/postgres-audit/`, `lucairn/postgres-bridge/`, `lucairn/postgres-veil/`.
> A backup taken by one path will NOT be found by the other path's restore (it
> lives under a different prefix). Restore each path with its own runbook, or
> use the same `s3.prefix` only if you never mix the two backup mechanisms
> against one bucket. The underlying dump format (`pg_dump -Fc`) is identical,
> so a manual `aws s3 cp` + `age -d` + `pg_restore` works against either prefix
> if you point at the right key.

> **Least-privilege role note (KIT-2 open question):** the audit/veil services
> connect at runtime as the least-privilege append-only roles (`audit_app` /
> `veil_app`). The dumps are taken as the schema-owning superuser
> (`dsa` / `veil`) and `pg_restore --clean --if-exists` runs as that same owner,
> so the append-only grants on `*_app` do not block restore. **Restore as the
> owner role, not the `*_app` role.** If you have hardened the owner role's
> privileges, grant it `CREATE`/`DROP` on the target schema for the duration of
> the restore. LIVE-VERIFY this on your cluster as part of the quarterly restore
> test and record the result.

### Restore validation

Quarterly, restore the latest dumps into a throwaway database and assert row
counts are non-zero and recent:

```bash
psql "<scratch-dsn>" -c "SELECT count(*) AS audit_events FROM audit_events;"
psql "<scratch-dsn>" -c "SELECT max(created_at) FROM audit_events;"
psql "<scratch-dsn>" -c "SELECT count(*) AS certificates FROM veil_certificates;"
```

Confirm the counts match the live system's order of magnitude and the newest
timestamp is within your RPO window. Record the validation date as backup
evidence.

## Key Rotation

Rotate in this order:

1. Upstream provider keys.
2. Gateway API keys.
3. Internal service token.
4. Database passwords.
5. Veil signing keys with a planned verification window.
6. `GATEWAY_KEYSTORE_KEY` only with a coordinated re-encryption migration.

Do not rotate all Veil keys at once. Keep retired public keys available through the witness-signed manifest retention window.

## Verify image signatures

Every published Lucairn container image is **cosign-signed** with a single
Lucairn-held Image Signing Key, and each signature is uploaded to the
**Sigstore Rekor public transparency log**. You can independently verify, before
or after pulling, that each image came from Lucairn and that its signature is
recorded in a public log — without trusting the registry alone.

This is supply-chain image provenance. It is separate from the per-request
Veil certificate chain: image signing proves "this binary is the one Lucairn
published"; the cert chain proves "this request was sanitized, isolated, and
attested." Both are independently checkable.

The public key ships with this kit at `keys/lucairn-cosign.pub`. Verification
needs `cosign` on PATH — install it from
<https://github.com/sigstore/cosign/releases> (verify its published checksum)
and nothing else; the public key alone is sufficient (no Lucairn phone-home,
no private material).

**Verify the whole published set (recommended):**

```bash
# Verifies all 12 dsa-* images + the dashboard against keys/lucairn-cosign.pub
# and the Rekor transparency log. Prints PASS/FAIL per image; exits non-zero if
# ANY signature is missing or invalid. Uses the tag/registry from
# image-manifest.yaml (override with --tag / --registry / --dashboard-tag).
bin/lucairn verify-images

# Pin an explicit release tag (the released image version), e.g.:
bin/lucairn verify-images --tag 0.5.0
```

**Verify a single image with raw cosign:**

```bash
cosign verify --key keys/lucairn-cosign.pub ghcr.io/declade/dsa-gateway:0.5.0
```

A successful `cosign verify` exits 0 and reports the signature payload plus a
Rekor transparency-log entry (`logIndex`). An unsigned or tampered image — or
any image not signed by the Lucairn key — exits non-zero and is rejected.

For the Image Signing Key's custody model, generation, and rotation procedure,
see the DSA repo `docs/operations/key-ceremony-runbook.md` § Key Inventory
(Image Signing Key). The private cosign key and its password are Lucairn-held,
stored mode-600 on the Lucairn issuer host, and are never distributed.

## Deployment license

The gateway enforces a self-hosted deployment entitlement license (Ed25519-signed, verified fully offline — no phone-home). It is separate from the platform tier license (`DSA_LICENSE_KEY`). It gates Enterprise-only FEATURES (e.g. the custom-trained L3 PII shield) and carries an expiry with a grace-then-degrade lifecycle. It does NOT enforce volume or seat caps (usage is metered elsewhere) and does NOT touch tier names.

Env (Compose: `customer.env`; Helm: `gateway.secrets.values.lucairnLicenseKey` / `lucairnLicensePublicKey` or `global.*`):

- `LUCAIRN_LICENSE_KEY` — the signed license token Lucairn issues you (or `LUCAIRN_LICENSE_FILE` for a mounted file).
- `LUCAIRN_LICENSE_PUBLIC_KEY` — the verification public key Lucairn provides (64-char hex). Same value for all customers of a given Lucairn signing-key generation.
- `LUCAIRN_LICENSE_GRACE_DAYS` — grace window after expiry (default 14).

Lifecycle:

- **Active** (before `valid_until`): full function.
- **Grace** (up to `LUCAIRN_LICENSE_GRACE_DAYS` after expiry): everything keeps working, loud warnings in gateway logs, `LICENSE_EXPIRED_GRACE` audit event, `gateway_license_state{phase="grace"}=1`. Renew during this window.
- **Degraded** (after grace): Enterprise features lock with a clear `feature_not_licensed` response; **the core PII sanitization pipeline keeps running** (licensing never breaks the compliance function); `LICENSE_EXPIRED_DEGRADED` audit event; `gateway_license_state{phase="degraded"}=1`.
- **Unregistered** (no license in production): Enterprise features locked, core pipeline runs. `gateway_license_state{phase="unlicensed"}=1`.
- **Dev/test**: `DSA_ENV=development` (or `test`) → warn-not-enforce, so dev/CI/demo are never blocked.

Check current status (operator endpoint, behind the admin key):

```bash
curl -fsS -H "X-Admin-Key: $DSA_ADMIN_KEY" \
  "$GATEWAY_BASE_URL/api/v1/admin/license-status" | jq .
# -> {"phase":"active","enforced":true,"enabled_features":["l3_custom_shield"],"valid_until":"...","grace_until":"..."}
```

Renewal: Lucairn issues a fresh `LUCAIRN_LICENSE_KEY`; replace the env value (and `LUCAIRN_LICENSE_PUBLIC_KEY` if the signing key rotated) and restart the gateway. Because expiry is grace-then-degrade, a brief renewal delay never bricks the core pipeline.

## Scaling

> **v1.0 topology lock — the gateway is single-replica.** Lucairn Enterprise
> v1.0 ships a single-replica gateway with a file-keystore on a ReadWriteOnce
> PVC. The keystore is pod-local and is NOT shared across replicas, so the
> Helm chart's validator **hard-rejects** `gateway.replicaCount > 1` (and
> `gateway.hpa.enabled: true`) at render time — `helm install`/`upgrade`
> will FAIL the render with an explicit error rather than deploy a
> split-brain keystore. See `charts/lucairn/templates/_validators.tpl`
> (the `gateway.replicaCount != 1` guard), `charts/lucairn/charts/gateway/values.yaml`
> (the `replicaCount: 1` lock + HPA-disabled block), and INSTALL.md §
> "Lucairn Enterprise v1.0 deployment topology". Multi-replica gateway HA is
> the v2.0 roadmap (postgres-gateway keystore) — see INSTALL.md § "v2.0
> roadmap". Do NOT plan to scale the gateway horizontally on v1.0.
>
> The same single-replica + HPA-off lock applies to every pod-local-state
> subchart (audit, id-bridge, sandbox-a, sandbox-b, veil-witness, ingest,
> dashboard); the per-subchart validator rejects `replicaCount != 1` for
> each. **Sandbox B is included in this lock** — even though its Python
> service is stateless across requests, it is a load-bearing veil-claim
> emitter that is structurally UNTESTED at multi-replica, so the validator
> hard-rejects `sandbox-b.replicaCount > 1` (see
> `charts/lucairn/templates/_validators.tpl`, the
> `validators.podLocalStateSingleReplica` guard). The Compose path has no
> render-time guard — operators MUST keep these services single-instance on
> Compose by the same constraint.

What you CAN scale on v1.0:

- **Databases — vertically** before sharding. Scale the bundled Postgres
  instances up (CPU/memory/disk) rather than out.

Horizontal scaling of Sandbox B workers (stateless inference workers) lands
in v2.0 alongside the rest of the shared-state refactor — see INSTALL.md §
"v2.0 roadmap". On v1.0 it stays single-replica with the rest of the
pod-local-state subcharts above.

For Compose installs, move to Kubernetes before adding multi-host complexity.
Horizontal HA of the gateway and the other pod-local-state services lands in
v2.0 with the shared-state refactor — until then, vertical scaling and
single-replica are the v1.0 SLA.

## Upgrade

1. Read release notes.
2. Take database backups.
3. Run `bin/lucairn doctor`.
4. Pull images or update Helm values.
5. Apply the release.
6. Confirm `/healthz`, `/readyz`, and one synthetic inference request.
7. Generate a support bundle and archive it internally as upgrade evidence.

## Rollback

If an upgrade fails its post-apply checks (step 6 above), roll back to the
last known-good image set. The **known-good combination is the pinned set in
`image-manifest.yaml`** (`default_lucairn_image_tag` plus any per-service
`services:`/`optional_services:` pins) — that is the exact tag tuple this kit
release was validated against. Roll back BOTH the kit checkout and the images
together so the config tree and the recognizer registry stay in sync (the Sim 2
F3 drift class documented in `image-manifest.yaml`).

### Compose path

```bash
# 1) Revert LUCAIRN_IMAGE_TAG in customer.env to the previous known-good tag
#    (the value from image-manifest.yaml `default_lucairn_image_tag` for the
#    kit release you are rolling back to). Keep the file at mode 0600.
sed -i 's/^LUCAIRN_IMAGE_TAG=.*/LUCAIRN_IMAGE_TAG=<previous-known-good-tag>/' customer.env

# 2) Re-pull and recreate with the reverted tag.
docker compose -f docker-compose.customer.yml --env-file customer.env pull
docker compose -f docker-compose.customer.yml --env-file customer.env up -d

# 3) Confirm the manifest matches what is now running, then health-check.
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
```

If the upgrade ran database migrations, restore the pre-upgrade database
backup from § Backups BEFORE re-pointing the images at the older tag — older
images may not understand a newer schema. Roll the data back first, then the
images.

### Kubernetes path

```bash
# Show revision history and roll back to the previous (or a named) revision.
helm history lucairn -n lucairn
helm rollback lucairn -n lucairn          # previous revision
# helm rollback lucairn <REVISION> -n lucairn   # a specific revision

# Confirm the rolled-back release is healthy. The gateway Deployment lives in
# the dsa-edge namespace (see INSTALL.md § "Kubernetes Install").
kubectl rollout status deployment/gateway -n dsa-edge
kubectl get pods -A -l app.kubernetes.io/part-of=dsa
```

`helm rollback` re-applies the chart manifests (including image tags) from the
target revision. As on Compose, if the failed upgrade applied schema
migrations, restore the database backup (§ Backups) before rolling the release
back — Helm does not undo data migrations.

> **Warn — compliance-DB volumes are NOT auto-preserved in v1.0.** The
> gateway-keystore PVC carries `helm.sh/resource-policy: keep`, but the audit,
> id-bridge, and veil-witness Postgres PVCs do NOT. A `helm uninstall` (not a
> rollback) destroys those compliance databases. Always take a fresh backup (§
> Backups) BEFORE any uninstall or destructive rollback. Automated
> backup/restore + PVC retain-policy for the compliance DBs is tracked
> separately (HA-01 / INS-02) and is not yet shipped.

## Dashboard: bootstrap admin + rotate credentials

The Lucairn Enterprise Dashboard (opt-in; see `INSTALL.md` §
"Enable the Lucairn dashboard") ships with a single bootstrap admin
account so the operator can sign in the first time. Rotate this
credential as a day-1 task and again on a defined schedule.

### Compose path

Rotation is a single env edit + container restart:

```bash
# 1) Generate a fresh password.
NEW_PASS="$(openssl rand -base64 24)"

# 2) Patch customer.env in place. Keep the file at mode 0600.
sed -i.bak \
  "s|^LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD=.*|LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD=${NEW_PASS}|" \
  customer.env

# 3) Recreate the dashboard container so it reads the new env.
docker compose \
  -f docker-compose.customer.yml \
  --env-file customer.env \
  --profile dashboard \
  up -d --force-recreate lucairn-dashboard

# 4) Confirm the new password works.
curl -fsS http://127.0.0.1:8443/healthz
```

Active sessions are revoked on restart (in-memory session store).

### Kubernetes path

The Helm chart provisions a Secret named `lucairn-dashboard-bootstrap-admin`
at install time (random 32-char password). Rotation replaces the Secret
and bounces the dashboard Deployment:

```bash
NEW_PASS="$(openssl rand -base64 24)"
NEW_SESSION="$(openssl rand -hex 24)"

kubectl -n lucairn create secret generic lucairn-dashboard-bootstrap-admin \
  --from-literal=password="${NEW_PASS}" \
  --from-literal=session-secret="${NEW_SESSION}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n lucairn rollout restart deploy/lucairn-dashboard
kubectl -n lucairn rollout status deploy/lucairn-dashboard
```

Customers who pre-create their own Secret can keep using their existing
rotation tooling — set `dashboard.bootstrapAdmin.passwordSecretName` to
the Secret name in `customer-values.yaml` and the chart skips its own
random-password Secret on subsequent installs.

### When to rotate

- Day-1, after the first successful login from each operator.
- Whenever an operator with the bootstrap credential leaves the team.
- After incident response involving the dashboard host.
- On the same schedule as the rest of the kit's secrets (per the
  "Key Rotation" section above).

### Dashboard: rotating the OIDC client secret

When OIDC SSO is enabled (`dashboard.oidc.enabled: true`), the client
secret is the credential the dashboard uses to authenticate to the IdP's
token endpoint. Rotate on the same cadence as any other shared credential
between the dashboard and the IdP — typically quarterly or on operator
departure.

The rotation flow is "rotate at the IdP first, then push to the kit":

1. Generate a new client secret at your IdP. Consult your IdP's documentation
   for the "regenerate secret" procedure in its client/app admin page.
2. Update the kit:

#### Compose path

```bash
NEW_SECRET="<value from the IdP>"
sed -i.bak \
  "s|^LUCAIRN_DASHBOARD_OIDC_CLIENT_SECRET=.*|LUCAIRN_DASHBOARD_OIDC_CLIENT_SECRET=${NEW_SECRET}|" \
  customer.env
docker compose \
  -f docker-compose.customer.yml \
  --env-file customer.env \
  --profile dashboard \
  up -d --force-recreate lucairn-dashboard
curl -fsS http://127.0.0.1:8443/healthz
```

#### Kubernetes path

```bash
NEW_SECRET="<value from the IdP>"
kubectl -n lucairn create secret generic lucairn-dashboard-oidc \
  --from-literal=client-secret="${NEW_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n lucairn rollout restart deploy/lucairn-dashboard
kubectl -n lucairn rollout status deploy/lucairn-dashboard
```

Active sessions are unaffected by client_secret rotation (sessions are
local to the dashboard). Users do NOT have to re-authenticate. The next
OIDC sign-in attempt picks up the new secret transparently.

## Dashboard: rotating audit DB credentials

The cert browser + inspector + audit-defensibility-grade validator
reach the customer's audit Postgres through a dedicated read-only role
(see `INSTALL.md` § "Audit DB + Witness wiring"). Rotate the role's
password on the same cadence as the rest of the kit's secrets.

Compose path:

```bash
# 1) Rotate at Postgres first. Connect as the audit DB owner (the kit's
#    `dsa` superuser by default) and ALTER the role:
psql -h postgres-bridge -U dsa -d dsa -c \
  "ALTER ROLE lucairn_dashboard_ro WITH PASSWORD '<new-password>';"

# 2) Patch customer.env in place. Keep the file at mode 0600.
NEW_DB_URL="postgres://lucairn_dashboard_ro:<new-password>@postgres-bridge:5432/dsa?sslmode=require"
sed -i.bak \
  "s|^LUCAIRN_DASHBOARD_AUDIT_DB_URL=.*|LUCAIRN_DASHBOARD_AUDIT_DB_URL=${NEW_DB_URL}|" \
  customer.env

# 3) Recreate the dashboard container so it reads the new env.
docker compose \
  -f docker-compose.customer.yml \
  --env-file customer.env \
  --profile dashboard \
  up -d --force-recreate lucairn-dashboard

# 4) Confirm health.
curl -fsS http://127.0.0.1:8443/healthz
```

Kubernetes path:

```bash
# 1) Rotate at Postgres first (same ALTER ROLE as above).

# 2) Replace the Secret with the new connection string.
kubectl -n lucairn create secret generic lucairn-dashboard-audit-db \
  --from-literal=connection-string='postgres://lucairn_dashboard_ro:<new-password>@postgres-bridge:5432/dsa?sslmode=verify-full' \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) Bounce the Deployment so the pod picks up the new Secret value.
kubectl -n lucairn rollout restart deploy/lucairn-dashboard
kubectl -n lucairn rollout status deploy/lucairn-dashboard
```

Active dashboard sessions are NOT invalidated by this rotation — sessions
are local to the dashboard process and the audit DB has no view of them.
The next cert-browser page request after the bounce dials the DB with
the new credentials transparently.

When to rotate:

- Day-1, after the first successful cert-browser page load.
- Whenever an operator with the audit DB password leaves the team.
- On the same schedule as the rest of the kit's secrets (per the
  "Key Rotation" section above).

## Rotating the Grafana JWT shared secret

The Grafana embed handoff uses an HS256 shared secret (≥32 chars).
The dashboard pod reads it via `LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET`;
the Grafana pod reads the same value via `GF_AUTH_JWT_KEY_FILE`
(mounted from the same Secret as `/etc/grafana/jwt/shared-secret`).

Tokens have a 60-second TTL — any token in flight at rotation time
expires within one minute, so the rotation order is non-critical
provided both pods restart within ~60s of the Secret edit.

### Compose path

```bash
NEW_SECRET="$(openssl rand -hex 24)"  # 48-char hex

# 1) Update customer.env atomically.
sed -i.bak "s|^LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET=.*|LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET=${NEW_SECRET}|" customer.env

# 2) Update the Grafana container's mounted secret-file (if your
#    Grafana config reads the shared secret from a file, update the
#    file in lockstep). For the bundled compose stack with Grafana
#    as a side-deployment, the simplest pattern is a Docker Compose
#    `secrets:` mount that points at a host file; update + recreate.

# 3) Recreate the dashboard container.
docker compose -f docker-compose.customer.yml \
  --env-file customer.env --profile dashboard \
  up -d --force-recreate lucairn-dashboard
# 4) Restart your Grafana container so it re-reads the shared-secret
#    file (the customer brings their own Grafana — the bundled compose
#    does NOT ship a `grafana` service). Run the equivalent of:
#    `docker compose -f <your-grafana-compose>.yml up -d --force-recreate <your-grafana-service>`
#    or `docker restart <your-grafana-container>` depending on how the
#    customer fronts Grafana.
```

### Kubernetes path

```bash
NEW_SECRET="$(openssl rand -hex 24)"

# 1) Update the Secret in BOTH namespaces. The dashboard sub-chart's
#    secret-grafana-jwt.yaml auto-renders the Secret into both
#    `lucairn` AND `dsa-observability` on `helm upgrade`, with a
#    lookup-precedence that re-reads existing values. Rotation is
#    therefore a two-step:
kubectl -n lucairn create secret generic lucairn-dashboard-grafana-jwt \
  --from-literal=shared-secret="${NEW_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n dsa-observability create secret generic lucairn-dashboard-grafana-jwt \
  --from-literal=shared-secret="${NEW_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) Bounce both Deployments so they re-read the Secret. Order does
#    not matter — the 60s JWT TTL bounds any in-flight token's
#    lifetime so even a brief mismatch window heals automatically.
kubectl -n lucairn rollout restart deploy/lucairn-dashboard
kubectl -n dsa-observability rollout restart deploy/grafana
```

When to rotate:

- On a customer-defined cadence (90 days is typical for HMAC secrets).
- Whenever an operator with cluster Secret read access leaves the team.
- After any Grafana-side incident response that suspects key compromise.

## Rotating the gateway admin token

The dashboard's `/keys` surface authenticates against the gateway
admin HTTP API using the same bearer token the gateway validates
constant-time (`DSA_ADMIN_KEY`). Rotation is a two-step:

1. Mint a fresh 32-byte (or longer) random token: `openssl rand -hex 32`.
2. Update the gateway's `DSA_ADMIN_KEY` AND the dashboard's
   `LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN` to the new value, in
   any order.

The dashboard holds the token in process memory (read once from
the env var or mounted secret at boot) and includes it on every
admin call. To pick up the rotated value the dashboard container
itself must restart (compose: `docker compose ... up -d --force-
recreate lucairn-dashboard`; Helm: rolling restart of the
`lucairn-dashboard` Deployment). The gateway likewise picks up
its new `DSA_ADMIN_KEY` on its own restart. A brief mismatch window
(≤ rolling-restart duration) is acceptable — clients of the
dashboard's `/keys` surface see a temporary `502` and retry on
next page reload.

### Compose path

```bash
NEW_TOKEN="$(openssl rand -hex 32)"

# 1) Update both env values atomically in customer.env.
sed -i.bak \
  -e "s|^DSA_ADMIN_KEY=.*|DSA_ADMIN_KEY=${NEW_TOKEN}|" \
  -e "s|^LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN=.*|LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN=${NEW_TOKEN}|" \
  customer.env

# 2) Recreate both containers.
docker compose -f docker-compose.customer.yml \
  --env-file customer.env up -d --force-recreate gateway

docker compose -f docker-compose.customer.yml \
  --env-file customer.env --profile dashboard \
  up -d --force-recreate lucairn-dashboard

# 3) Verify doctor sees the new token end-to-end.
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
```

### Kubernetes path

```bash
NEW_TOKEN="$(openssl rand -hex 32)"

# 1) Rotate the Secret carrying DSA_ADMIN_KEY on the gateway side
#    (typically named `lucairn-gateway-admin`).
kubectl -n lucairn create secret generic lucairn-gateway-admin \
  --from-literal=admin-key="${NEW_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) Rotate the dashboard-side mirror Secret.
kubectl -n lucairn create secret generic lucairn-dashboard-gateway-admin \
  --from-literal=admin-token="${NEW_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) Roll both Deployments so they re-read the Secret values.
kubectl -n lucairn rollout restart deploy/gateway
kubectl -n lucairn rollout restart deploy/lucairn-dashboard

# 4) Verify the dashboard's pre-flight passes.
DOCTOR_INCLUDE_DASHBOARD=1 bin/lucairn doctor --env customer.env \
  --compose docker-compose.customer.yml
```

When to rotate:

- Day-1 after first successful `/keys` page load (replace any
  bootstrap value the kit shipped with).
- Whenever a dashboard admin user leaves the team.
- On the same cadence as the rest of the kit's bearer tokens.

## Bulk-revoking API keys via the dashboard

The `/keys` page supports bulk revoke via row checkboxes + the
"Revoke selected" toolbar button. Every key in the bulk selection
emits its own `key.revoke_requested` audit event (NOT one
aggregate `key.bulk_revoke_requested`) so the audit stream stays
joinable with single-revoke entries.

Operational bounds the dashboard enforces against the gateway
admin surface:

- Worker pool size = 5 concurrent `DeleteKey` RPCs per bulk job.
- Process-wide rate limit = 10 RPC/s (shared across all
  in-flight bulk jobs).
- Max keys per single bulk submission = 100 (oversize requests
  receive HTTP 413).

Operators who need to revoke more than 100 keys in one motion
submit multiple bulk jobs back-to-back. The gateway's per-IP
admin rate limit (60/min) is the harder ceiling — the
dashboard's 10 RPC/s stays well under it.



## Rotating the audit log DB credentials

The dashboard's `/audit` surface connects to `postgres-audit` as the
`audit_app` role (default) or a custom role you wired via
`LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL`. Rotate on the same cadence as
the other audit-DB credentials in the kit.

Step 1 — rotate `audit_app`'s password in `postgres-audit`:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env \
  exec postgres-audit psql -U dsa -d audit \
  -c "ALTER USER audit_app WITH PASSWORD '<NEW_PASSWORD>';"
```

Step 2 — update the dashboard env var (Compose) OR Secret (K8s):

```bash
# Compose path: edit customer.env
LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL=postgres://audit_app:<NEW_PASSWORD>@postgres-audit:5432/audit?sslmode=disable

# K8s path: rotate the Secret
kubectl -n lucairn create secret generic lucairn-dashboard-audit-log \
  --from-literal=url="postgres://audit_app:<NEW_PASSWORD>@postgres-audit:5432/audit?sslmode=disable" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Step 3 — rolling-restart the dashboard so it re-reads the env var:

```bash
# Compose:
docker compose -f docker-compose.customer.yml --env-file customer.env --profile dashboard up -d --force-recreate lucairn-dashboard

# K8s:
kubectl -n lucairn rollout restart deploy/lucairn-dashboard
```

Step 4 — verify `bin/lucairn doctor` returns green for the
`dashboard audit-log` section:

```bash
./bin/lucairn doctor
```

If saved filters share the same role (the default), the rotation
above is sufficient. If you wired a separate
`LUCAIRN_DASHBOARD_AUDIT_LOG_SAVED_FILTERS_DB_URL` with a dedicated
`dashboard_app` role, rotate that role + URL identically.

### `migrations/audit/000003_least_privilege_role.up.sql.tmpl` is a template

Note for operators applying migrations manually: the
`migrations/audit/000003_least_privilege_role.up.sql.tmpl` file is
NOT plain SQL — the `${AUDIT_APP_PASSWORD}` placeholder is substituted
at deploy time by `scripts/render-migrations.sh` (invoked from the
`prep-migrations` compose service). Running `migrate up` against the
raw `.tmpl` file would INSERT a literal `${AUDIT_APP_PASSWORD}`
string into the role's password and the next dashboard restart would
fail authentication.

If you need to apply this migration manually:

```bash
# Render via the same script the compose pipeline uses.
AUDIT_APP_PASSWORD='<password>' VEIL_APP_PASSWORD='<password>' \
  SRC_ROOT=./migrations OUT_ROOT=/tmp/rendered \
  scripts/render-migrations.sh

# Then run the RENDERED .up.sql file (not the .up.sql.tmpl original).
psql "$AUDIT_DB_URL" -f /tmp/rendered/audit/000003_least_privilege_role.up.sql
```

The script fails-closed when `$AUDIT_APP_PASSWORD` or
`$VEIL_APP_PASSWORD` is unset (exit 2) so a forgotten env var
surfaces immediately rather than silently corrupting the migration.

## Audit log: reveal raw payload + CSV export with PII

The admin "Reveal raw" button on the `/audit/{event_id}` detail
page returns the unredacted payload to the browser AND emits a
paired `audit.reveal_raw` event into `audit_events`. The event
captures:

- `actor` — the admin's email
- `target_event_id` — the event the admin unmasked
- `target_event_type`, `target_source`, `target_request_id`,
  `target_payload_type` — context for the auditor

A future `audit.reveal_raw` audit (the meta-audit) is therefore
fully self-describing.

The CSV export endpoint `/audit/export.csv?reveal=true` is also
admin-only. It emits one `audit.csv_export_with_reveal` event
BEFORE the stream starts (so the audit trail records the bulk
reveal even if the operator's browser drops mid-stream). The
event payload captures the operator + the filter query the
export used.

Default (no `?reveal=true`) CSV export streams REDACTED payloads
to anyone with dashboard access; no audit event is emitted (the
operator-visible state of the redacted browser is exactly what
they see in the file).

## Compliance PDF export — audit trail

Every PDF generation through the dashboard's `/compliance` surface
emits one `audit.compliance_pdf_generated` event into
`audit_events` (when the audit-log DB is configured; pod-log fallback
otherwise). The event payload captures:

- `actor` — the admin's email
- `customer_name` — the sanitised string from the form
- `window_from` / `window_to` — RFC3339 timestamps of the exported
  range
- `page_count` — number of PDF pages produced
- `byte_size` — total size of the PDF bytes returned
- `cert_count` / `sanitizer_events` / `audit_events` — the
  aggregated counts the cover page summarises

The handler emits the audit event BEFORE writing PDF bytes to the
response stream. If the emit fails (DB unreachable mid-export,
audit_app role grant missing) the handler returns HTTP 500 with
`audit emit failed` and ZERO PDF bytes touch the wire. The
fail-closed mirror of the reveal-raw + csv_export_with_reveal
flows: evidence content never surfaces without a matching audit
row.

### Render-time banned-literal guard

The compliance PDF renderer scans every text-emit against the
project's locked mechanism-allowlist set. If a banned literal
appears in the customer name, the kit-version metadata, or anywhere
else in the rendered copy, the handler returns HTTP 500 with `PDF
generation failed`. The most common operator-side cause is a
banned-literal substring inside
`LUCAIRN_DASHBOARD_COMPLIANCE_DEFAULT_CUSTOMER_NAME`. The
`bin/lucairn doctor` pre-up probe rejects the same set so the
operator catches the misconfiguration before the dashboard pod
boots; the in-binary guard is the second layer of defence.
