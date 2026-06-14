# OPS

## Customer Lifecycle

Mint a new customer + first API key with `bin/lucairn-mint-customer` (run after `bin/lucairn doctor` reports `ok`). The script targets the gateway's `POST /api/v1/admin/keys` endpoint, applies tier defaults (Developer / Pro / Enterprise) server-side, and prints the raw key once. See `bin/lucairn-mint-customer --help` for flag reference, env-var auth precedence (`LUCAIRN_ADMIN_KEY` preferred), and `--dry-run` to inspect the resolved payload before firing.

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

## pii-ml sidecar (Phase 7 ML PII scanners)

The `pii-ml` deployment in `dsa-identity` runs Piiranha + GLiNER as a
single-process Python gRPC service extracted from the sanitizer monolith
at PR #240 production-path follow-up. See INSTALL.md § "Phase 7 ML PII
scanners" for the deployment shape; this section covers ops.

### Health diagnostics

**Helm path:**

```bash
# Sidecar pod status
kubectl get pod -n dsa-identity -l app.kubernetes.io/name=pii-ml

# /healthz (always-up after container start)
kubectl exec -n dsa-identity deploy/pii-ml -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8088/healthz').read())"

# /readyz (200 only after both models loaded — fail-CLOSED ready gate)
kubectl exec -n dsa-identity deploy/pii-ml -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8088/readyz').read())"
```

**Compose path** (e.g. a customer deploying on Azure Container Apps):

```bash
# Sidecar container status
docker compose -f docker-compose.customer.yml --env-file customer.env ps pii-ml

# /healthz (always-up after container start)
docker compose -f docker-compose.customer.yml --env-file customer.env \
  exec pii-ml python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8088/healthz').read())"

# /readyz (200 only after both models loaded — fail-CLOSED ready gate)
docker compose -f docker-compose.customer.yml --env-file customer.env \
  exec pii-ml python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8088/readyz').read())"
```

### Inspecting model load logs

**Helm path:**

```bash
# Model load progress + boot warnings
kubectl logs -n dsa-identity deploy/pii-ml --tail=200

# Look for these markers:
#   "pii-ml booting"           — startup begin
#   "loading piiranha @ <SHA>" — HF fetch + model load (~5-30s)
#   "loading gliner @ <SHA>"   — HF fetch + model load (~30-90s)
#   "ready"                    — both loaded, readyz flipped to 200
```

**Compose path:**

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env \
  logs --tail 200 -f pii-ml
```

### Eager-load failure behavior

The sidecar runs with `LUCAIRN_PII_ML_EXIT_ON_LOAD_FAILURE=true` by
default. On a corrupted HF cache, missing weights, or a load-time
exception, the process hard-exits (`sys.exit(2)` for Piiranha,
`sys.exit(3)` for GLiNER) and Kubernetes restarts the container per the
`restartPolicy: Always` semantics on the Deployment. This is intentional
fail-CLOSED behavior locked at PR #240 Codex r1 review.

If the restart loop persists:

1. Check `kubectl describe pod -n dsa-identity -l app.kubernetes.io/name=pii-ml`
   for OOMKilled (raise `pii-ml.resources.limits.memory`).
2. Check pod logs for a corrupted HF cache — typically resolved by
   recreating the pod (`emptyDir` cache) OR wiping the PVC contents.
3. Verify the HF revision SHAs in `pii-ml.hfRevisions` match the values
   baked into the image's `image-manifest.yaml` entry — a mismatch
   silently re-downloads weights at a different revision and may break.

### Phase 7 is OFF by default (chart v1.7.1)

As of chart v1.7.1 (2026-06-10) the Phase 7 ML PII layer (Piiranha +
GLiNER) is **DISABLED by default** — the ML sidecar saturated CPU and
overloaded on large prompts (~147KB routed Claude Code turns), inducing
~90s/turn latency and a fail-closed refusal on the reference pilot. A
fresh install therefore runs L1+L2 (known-entity matching + Presidio) +
L3 (Ollama identity) with the pii-ml sidecar absent. There is nothing to
disable on a default install — the state below is already the shipped
default.

If you previously re-enabled Phase 7 and need to drop back to the default
L1+L2(+L3) profile without uninstalling the chart:

```bash
# In customer-values.yaml (this is the v1.7.1 default — both gates off):
pii-ml:
  enabled: false
sandbox-a:
  sanitizer:
    piiranha:
      enabled: false
    gliner:
      enabled: false

# Then:
helm upgrade lucairn charts/lucairn -f customer-values.yaml
```

This removes the pii-ml deployment and tells sanitizer to skip Phase 7
in the rendered config. Sanitizer keeps L1+L2 + L3 (Ollama identity)
running unchanged. The customer pipeline runs the deterministic-only
coverage profile (the pre-PR-#240 profile).

### Re-enabling Phase 7

To turn the ML layer back on, flip BOTH gates — see
`INSTALL.md` § "Re-enabling Phase 7" for the full Helm + Compose recipe
(and the 4Gi memory + ~1.6GB HF-download prerequisites). In short, set
`pii-ml.enabled: true` AND `sandbox-a.sanitizer.piiranha.enabled: true` +
`sandbox-a.sanitizer.gliner.enabled: true` (Helm), or bring the Compose
stack up with `--profile phase7` after flipping the sanitizer-side flags
in `config/default-sanitizer.yaml`.

### pii-ml sidecar — HF cache PVC

For air-gapped sites or sites that restart the pii-ml pod frequently
(e.g. during cluster upgrades), persist the HF cache to a PVC so the
~1.6GB weight download happens once per cluster instead of once per pod
restart.

```yaml
# In customer-values.yaml:
pii-ml:
  hfCacheVolume:
    type: pvc
    pvc:
      storageClass: ""        # leave blank for cluster default, or set explicitly
      storageSize: 3Gi
      accessMode: ReadWriteOnce
```

The PVC carries `helm.sh/resource-policy: keep` so `helm uninstall`
preserves the downloaded weights for clean re-install (mirroring the
`postgres-*` PVC pattern).

For air-gapped sites that cannot fetch HF weights at boot:

1. On a connected operator host, populate a directory with the HF cache
   layout for both Piiranha + GLiNER (the HF Python lib's standard cache
   structure under `~/.cache/huggingface/`).
2. Pack as a tarball + copy to the cluster.
3. Pre-create the PVC via `kubectl apply` of a PVC manifest matching the
   chart's naming (`pii-ml-hf-cache`), bind it via a one-shot Job that
   untars the cache contents to `/home/appuser/.cache/huggingface`, then
   `helm upgrade --install lucairn ...` with `pii-ml.hfCacheVolume.type=pvc`.

The sidecar boot will skip the HF download and load weights directly
from the pre-staged cache. See the Lucairn support team for an
air-gapped staging script template.

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

## Disaster recovery: full cold-restore

The per-DB restore procedures above (§ Backups → "Restore runbook") recover
your compliance data **into a still-running deployment**. This section is the
different, heavier case: **the whole cluster is gone** (disk loss, a destroyed
namespace, a host migration, a `kubectl delete pvc`) and you are rebuilding the
deployment from nothing. It choreographs the existing tooling end-to-end so a
fresh deployment comes back **signing and verifying certificates** — not just
holding the old data.

> **This runbook reuses only tooling that already ships.** It does NOT
> introduce a new backup mechanism. It sequences four things you already have:
> your offline **signing-seed escrow** (§ "Signing-key escrow & cold recovery"
> below), the `age`-encrypted **compliance-DB dumps** (§ Backups), the
> **witness-signed manifest** ceremony (`bin/lucairn` / the Veil key-ceremony
> runbook), and a **fresh-cert verify** (`bin/lucairn doctor` + a synthetic
> request). The same NO-point-in-time-recovery limit from § Backups applies:
> the data you recover is exactly what was in your most recent dump, so your
> recovery point is your backup interval — **measure your own recovery time in
> your environment**; it is not a guaranteed figure.

### What a cold-restore must re-establish, and in what order

The ordering matters: the witness-signed manifest is verified at gateway boot
against the witness public key, and a fresh certificate only verifies once the
signing seeds AND the restored evidence are both back. Re-establish in this
order:

1. **Signing seeds first** — re-provide the customer-cluster `VEIL_*` seeds from
   your offline escrow (§ below). Without these the witness cannot sign and the
   gateway will not accept a mismatched manifest.
2. **Compliance data** — restore the three compliance DBs (`audit`, `bridge`,
   `veil`) from your most recent dumps using the EXISTING restore tooling.
3. **Witness-signed manifest** — regenerate / redeploy the witness-signed
   `/.well-known/veil-keys.json` blob so the gateway boots and verifies it.
4. **Fresh-cert verify** — submit one synthetic request and confirm a freshly
   issued certificate verifies end-to-end.

A common ordering mistake is re-establishing the manifest before the seeds are
back: the gateway then fails closed at boot on an env↔blob mismatch. Re-provide
seeds first.

### Step 0 — prerequisites on a secured operator host

You need, OFF the lost cluster:

- Your **offline signing-seed escrow blob** and the `age`/`gpg` identity that
  decrypts it (§ "Signing-key escrow & cold recovery").
- Your most recent **compliance-DB dumps** — either reachable in your S3 bucket
  (the automated CronJob / `bin/lucairn backup` path) or a local copy — plus the
  `age` identity file that decrypts them (`LUCAIRN_BACKUP_AGE_IDENTITY_FILE`).
- The kit checkout at the **same release** the dumps were taken against (roll
  the config tree and images together — see § Rollback).
- `kubectl`/`helm` (Helm path) or `docker compose` (Compose path), plus `age`.

### Step 1 — provision an empty deployment and re-provide the signing seeds

Bring up an EMPTY deployment (no data yet) and provide the recovered `VEIL_*`
seeds BEFORE the witness and gateway start signing.

**Helm path** — feed the recovered seeds to the chart via a values overlay (the
chart owns the Secrets on `k8s-native`), **plus the public keys re-derived from
those seeds**, then install.

> **Why you must re-derive and set the public keys, not just the seeds.** On
> `k8s-native` the chart does **NOT** derive any public key from a seed — it
> plugs each `secrets.values.veil*PublicKey` slot verbatim into the gateway
> Secret (`charts/lucairn/charts/gateway/templates/secret.yaml:48-55`) and each
> `veil-witness.config.*PublicKey` into the witness ConfigMap
> (`charts/lucairn/charts/veil-witness/templates/configmap.yaml:13-16`). Only the
> one-time `scripts/render-values.sh` derives them, and a cold-restore re-uses
> your *original* `customer-values.yaml` rather than re-running that renderer.
> If you restore only the private seeds onto a freshly-rendered base, the public
> keys come from a **different (fresh) render** and no longer match the restored
> seeds — every Veil signature then fails verification and the well-known roster
> is wrong. So the restore overlay must carry **every public key re-derived from
> the restored seeds**.
>
> **Equivalent alternative:** preserve and restore your **original rendered
> `customer-values.yaml`** (it already holds the matching public keys for the
> seeds you escrowed) and skip the re-derivation. Re-derive-from-seeds is the
> primary path documented here because the seeds — not the rendered values file —
> are what the escrow blob actually holds.

```bash
# Decrypt the offline escrow blob on the operator host (see the escrow section).
# umask 077 BEFORE the write so the seed-bearing plaintext is created 0600 — under
# the default umask 022 it would land 0644 (world-readable to local users).
( umask 077; age -d -i veil-escrow.identity -o /dev/shm/veil-seeds.env veil-seeds.escrow.age )
chmod 0600 /dev/shm/veil-seeds.env   # belt-and-suspenders if age ignored the umask
# Exports the seven root seeds: LCR_AUDIT/BRIDGE/SANITIZER/SANDBOX_B/WITNESS/
# GATEWAY_SIGNING_KEY + LCR_MANIFEST_SIGNING_KEY (the "What to escrow" set).
set -a; . /dev/shm/veil-seeds.env; set +a
```

On `k8s-native` (the default — `charts/lucairn/values.yaml:32`,
`charts/lucairn/charts/*/values.yaml secrets.backend: k8s-native`), the
`<service>-credentials` Secrets are **chart-managed**: the chart renders them
itself from your values (`charts/lucairn/charts/veil-witness/templates/secret.yaml:1-30`,
`charts/lucairn/charts/gateway/templates/secret.yaml:1-38`). Do **NOT**
pre-create those Secrets with `kubectl create secret` — `helm install` would then
fail with an existing-resource ownership conflict. Instead, put the recovered
seeds into your **values overlay** so the chart creates the Secrets with the
right data, then install:

```bash
# (a) Re-derive every public key from the RESTORED seeds. The chart does not do
#     this for you — it plugs each *PublicKey slot verbatim — so derive them here
#     and set them in the overlay below. derive-veil-pubkey.sh emits the Ed25519
#     public of a signing seed (scripts/derive-veil-pubkey.sh:3-4); pipe the seed
#     on stdin so it never lands on the process argument list (SEC-04).
PUB_AUDIT=$(printf '%s' "$LCR_AUDIT_SIGNING_KEY"       | scripts/derive-veil-pubkey.sh)
PUB_BRIDGE=$(printf '%s' "$LCR_BRIDGE_SIGNING_KEY"     | scripts/derive-veil-pubkey.sh)
PUB_SANITIZER=$(printf '%s' "$LCR_SANITIZER_SIGNING_KEY" | scripts/derive-veil-pubkey.sh)
PUB_SANDBOX_B=$(printf '%s' "$LCR_SANDBOX_B_SIGNING_KEY" | scripts/derive-veil-pubkey.sh)
PUB_WITNESS=$(printf '%s' "$LCR_WITNESS_SIGNING_KEY"   | scripts/derive-veil-pubkey.sh)
PUB_GATEWAY=$(printf '%s' "$LCR_GATEWAY_SIGNING_KEY"   | scripts/derive-veil-pubkey.sh)
# Manifest public keys — runtime-derivation source matters (see the escrow
# section's "Derived — do NOT escrow these" note):
#   LCR_GATEWAY_MANIFEST_PUBLIC_KEY  ← LCR_MANIFEST_SIGNING_KEY  (the gateway
#       signs its manifest with this seed at veil.go:206 — NOT veilGatewaySigningKey)
#   LCR_WITNESS_MANIFEST_PUBLIC_KEY  ← LCR_WITNESS_SIGNING_KEY   (witness
#       signs its manifest blob with the witness seed; sign-manifest --witness-signing-key-hex)
PUB_GATEWAY_MANIFEST=$(printf '%s' "$LCR_MANIFEST_SIGNING_KEY" | scripts/derive-veil-pubkey.sh)
PUB_WITNESS_MANIFEST=$(printf '%s' "$LCR_WITNESS_SIGNING_KEY"  | scripts/derive-veil-pubkey.sh)

# (b) Write the recovered seeds AND the re-derived public keys into a restore
#     values overlay (mode 0600). Seed slot names match the "What to escrow"
#     table's Helm column; public-key slots are the gateway.secrets.values.veil*
#     roster (the source of /.well-known/veil-keys.json) plus the four witness
#     emitter pubkeys the witness ConfigMap needs to verify claims.
#     The ( umask 077; cat > ... ) subshell creates the seed-bearing overlay 0600;
#     a plain `cat >` under umask 022 would create it 0644 (world-readable).
( umask 077; cat > /dev/shm/restore-seeds.values.yaml <<EOF
veil-witness:
  secrets: { values: { signingKey: "${LCR_WITNESS_SIGNING_KEY}" } }
  # The witness verifies emitter claims against these four pubkeys
  # (charts/lucairn/charts/veil-witness/templates/configmap.yaml:13-16).
  config:
    bridgePublicKey: "${PUB_BRIDGE}"
    sanitizerPublicKey: "${PUB_SANITIZER}"
    sandboxBPublicKey: "${PUB_SANDBOX_B}"
    auditPublicKey: "${PUB_AUDIT}"
gateway:
  secrets:
    values:
      # Gateway per-request CLAIM signer + its public counterpart.
      veilGatewaySigningKey: "${LCR_GATEWAY_SIGNING_KEY}"
      veilGatewayPublicKey: "${PUB_GATEWAY}"
      # Gateway MANIFEST signer — the key the gateway signs /.well-known with
      # (services/gateway/internal/api/veil.go:206). Its public counterpart
      # LCR_GATEWAY_MANIFEST_PUBLIC_KEY is the Ed25519 public of THIS seed.
      veilManifestSigningKey: "${LCR_MANIFEST_SIGNING_KEY}"
      veilGatewayManifestPublicKey: "${PUB_GATEWAY_MANIFEST}"
      # The remaining well-known roster pubkeys the gateway publishes
      # (veil.go:1262-1301): witness + witness-manifest + the four emitters.
      veilWitnessPublicKey: "${PUB_WITNESS}"
      veilWitnessManifestPublicKey: "${PUB_WITNESS_MANIFEST}"
      veilBridgePublicKey: "${PUB_BRIDGE}"
      veilSanitizerPublicKey: "${PUB_SANITIZER}"
      veilSandboxBPublicKey: "${PUB_SANDBOX_B}"
      veilAuditPublicKey: "${PUB_AUDIT}"
id-bridge:
  secrets: { values: { veilSigningKey: "${LCR_BRIDGE_SIGNING_KEY}" } }
audit:
  secrets: { values: { veilSigningKey: "${LCR_AUDIT_SIGNING_KEY}" } }
sandbox-a:
  # The sanitizer is a sidecar in the sandbox-a pod (no sanitizer subchart);
  # its seed restores through the sandbox-a slot. See the escrow table note.
  secrets: { values: { veilSigningKey: "${LCR_SANITIZER_SIGNING_KEY}" } }
sandbox-b:
  secrets: { values: { veilSigningKey: "${LCR_SANDBOX_B_SIGNING_KEY}" } }
EOF
)
chmod 0600 /dev/shm/restore-seeds.values.yaml   # confirm 0600 regardless of umask

# (c) Install pointing at the (still empty) compliance DBs. The overlay now
#     carries the restored seeds AND every re-derived public key, so the gateway
#     Secret + witness ConfigMap match the restored signers — signatures verify
#     and the well-known roster is complete.
helm install lucairn ./charts/lucairn -n lucairn --create-namespace \
  -f customer-values.yaml -f /dev/shm/restore-seeds.values.yaml

shred -u /dev/shm/veil-seeds.env /dev/shm/restore-seeds.values.yaml
```

> **External Secrets backend (`vault` / `aws` / `azure`).** Do NOT use the
> values overlay above. Restore the recovered seed values **into your secret
> store BEFORE `helm install`** (`charts/lucairn/charts/*/templates/externalsecret.yaml`
> pull them at sync time); the ExternalSecret then materializes each
> `<service>-credentials` Secret. The chart does not own those Secrets on this
> backend, so there is no pre-create conflict — but the data must be in the store
> first or the pods start without their signing seeds.
>
> **⚠ Supported full-restore path is the bundled `k8s-native` values-overlay
> above — not the ESO path as currently shipped.** The gateway ExternalSecret
> template (`charts/lucairn/charts/gateway/templates/externalsecret.yaml`) does
> **NOT** map four of the gateway-roster keys:
> `LCR_GATEWAY_SIGNING_KEY`, `LCR_GATEWAY_PUBLIC_KEY`,
> `LCR_GATEWAY_MANIFEST_PUBLIC_KEY`, and `LCR_WITNESS_MANIFEST_PUBLIC_KEY`
> have no `data:` entry, so an ESO restore on the shipped chart **cannot** produce
> the documented 8-key gateway roster on its own (it materializes
> `LCR_MANIFEST_SIGNING_KEY` + the five emitter pubkeys, and nothing else from
> the manifest/gateway set). This is a shipped-chart gap of the same class as the
> witness/audit ExternalSecret completeness fix — **tracked as a follow-up to
> extend the gateway ExternalSecret**.
>
> Until the chart is extended, an ESO restore must **supply those four values
> through the secret store itself** — because on a non-`k8s-native` gateway
> backend `charts/lucairn/charts/gateway/templates/secret.yaml` is guarded by
> `{{- if eq .Values.secrets.backend "k8s-native" }}` and does **NOT** render, so
> `gateway.secrets.values.veil*` overlay values are **silently ignored** (a
> `k8s-native`-style values overlay for the gateway subchart does nothing on the
> ESO backend). Two backend-accurate options:
>
> 1. **Stay on ESO** — put the re-derived `LCR_GATEWAY_PUBLIC_KEY` /
>    `LCR_GATEWAY_MANIFEST_PUBLIC_KEY` / `LCR_WITNESS_MANIFEST_PUBLIC_KEY` and
>    the restored `LCR_GATEWAY_SIGNING_KEY` **into the external secret store** (the
>    same store the gateway ExternalSecret syncs from) keyed under names the
>    extended ExternalSecret will map — OR, on the shipped chart that does not yet
>    map them, `kubectl patch secret gateway-credentials` to add the four `data:`
>    entries on the **materialized** `gateway-credentials` Secret **after** ESO
>    has synced it (re-apply the patch after any ESO refresh that recreates the
>    Secret, since ESO owns it).
> 2. **Flip the gateway subchart to `k8s-native`** (`gateway.secrets.backend:
>    k8s-native`) for the restore and supply the **full** gateway Secret inputs via
>    the values overlay above — then the chart-rendered `secret.yaml` materializes
>    the complete roster.
>
> Do **not** assume the ESO path alone yields the full roster as written, and do
> **not** carry the missing pubkeys in a gateway values overlay while the backend
> stays ESO — verify with the well-known key_id check below before declaring the
> restore complete.

**Compose path** — restore the `VEIL_*` seeds into `customer.env` (mode 0600)
from the decrypted escrow blob, then bring the stack up empty:

```bash
# umask 077 so the decrypted seed plaintext is created 0600, not 0644 under the
# default umask 022 (it holds the seven root signing seeds in cleartext).
( umask 077; age -d -i veil-escrow.identity -o /dev/shm/veil-seeds.env veil-seeds.escrow.age )
chmod 0600 /dev/shm/veil-seeds.env
# Merge the VEIL_* lines into customer.env (keep the file at mode 0600), then:
shred -u /dev/shm/veil-seeds.env
docker compose -f docker-compose.customer.yml --env-file customer.env up -d
```

> Customers on the `vault` / `aws` / `azure` secrets backend (External Secrets)
> re-provide the seeds by restoring them into that backend instead — the offline
> escrow is the recovery path for the **`k8s-native`** Secret backend (and for
> the Compose path), where a lost cluster also loses the only copy of the seed.

### Step 2 — restore the three compliance DBs from your dumps

Use the EXISTING restore tooling — do NOT hand-roll a new path. Restore into the
freshly provisioned, EMPTY databases (the dumps do not truncate, and the
append-only `audit` DB must never be replayed over populated rows).

```bash
# Compose path (wraps download + age-decrypt + pg_restore):
bin/lucairn restore --env customer.env --stamp <YYYYMMDDTHHMMSSZ>

# Helm path: download + decrypt on the operator host, pipe into each pod —
# exactly the per-DB "Restore runbook" steps in § Backups, run for all three
# DBs (audit, bridge, veil). The S3 key prefix is the CHART name on the Helm
# path (lucairn/audit/, lucairn/id-bridge/, lucairn/veil-witness/).
```

The recovered data is exactly the content of your most recent dump — anything
written after that dump is not recoverable (no point-in-time recovery; the RPO
equals your backup interval).

### Step 3 — re-establish the witness-signed manifest

With the seeds back and the DBs restored, regenerate / redeploy the
witness-signed `/.well-known/veil-keys.json` blob so the gateway boots and the
W2B runtime harness's manifest check passes. The blob is produced at the
ceremony host with the recovered witness seed and distributed to each gateway
(see the Veil **Key Ceremony Runbook**, § "Producing the witness-signed
manifest blob"). After redeploying the blob, restart the gateway so it
re-reads and re-verifies it against `LCR_WITNESS_PUBLIC_KEY` at boot.

### Step 4 — verify a fresh certificate end-to-end

Confirm the rebuilt deployment is not just holding old data but is **issuing
verifiable certificates again**:

```bash
# Pre-flight wiring.
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml

# Confirm the published key roster carries every expected key_id. A fully
# configured deployment publishes the five service keys PLUS the two manifest
# keys (gateway + witness) when LCR_GATEWAY_MANIFEST_PUBLIC_KEY and
# LCR_WITNESS_MANIFEST_PUBLIC_KEY are set — the gateway only appends a key
# when its public-key env var is non-empty (dual-sandbox-architecture
# services/gateway/internal/api/veil.go:1262-1301). Assert the key_ids by name
# rather than a bare count so a missing manifest key is caught explicitly. This
# reads only public key_ids — no private key material is disclosed.
# This is a GATE: it must exit non-zero when any key_id is missing. The
# success/failure branch is attached to jq's own exit status — do NOT fold a
# `|| echo ...` onto the jq pipeline, because the `||` would swallow jq's
# non-zero exit and the check would falsely pass on a missing key.
curl -s "$GATEWAY_BASE_URL/.well-known/veil-keys.json" \
  | jq -e '[.keys[].key_id] as $ids
           | ["witness_v1","bridge_v1","sanitizer_v1","sandbox_b_v1","audit_v1",
              "gateway_manifest_v1","witness_manifest_v1"]
           | all(. as $k | $ids | index($k))' >/dev/null \
  || { echo "MISSING key_id — check VEIL_*_PUBLIC_KEY wiring" >&2; exit 1; }
echo "all 7 key_ids present"
# NOTE: the published roster is exactly these 7 (five emitter pubkeys + the two
# manifest pubkeys). buildPublicKeyManifest() does NOT publish the gateway CLAIM
# pubkey LCR_GATEWAY_PUBLIC_KEY (there is no gateway_v1 key_id in
# /.well-known/veil-keys.json — veil.go:1262-1301). The restored
# veilGatewayPublicKey is consumed by the WITNESS, not the roster: it is the key
# the witness uses to verify the gateway's per-request CLAIM signature
# (services/veil-witness/cmd/server/main.go:49,114 — CC-017 P2). Its correctness
# is therefore confirmed by the fresh-cert end-to-end check below (a
# VERDICT_VERIFIED cert with the gateway claim verifying), NOT by this roster
# gate. Do NOT add gateway_v1 to the expected-id list above — it would make this
# gate fail against a correctly configured deployment.
# Then submit a proxy request and GET /api/v1/veil/certificate/<request_id> —
# the verification block must show overall_verdict = VERDICT_VERIFIED with a
# valid witness signature (see the Veil Key Ceremony Runbook § Verification).
```

A `VERDICT_VERIFIED` on a freshly issued certificate is the cold-restore
success condition: the seeds, the restored evidence, and the manifest are all
coherent again.

### Restore-drill evidence (HA-01 closure)

> **PENDING — filled by the executed Vast/Kind cold-restore drill (merge gate).**
> This runbook is closed only once it has been run verbatim on a fresh
> throwaway cluster from empty → re-provided seeds → restored DBs → manifest →
> a `VERDICT_VERIFIED` fresh cert. Record the result on one line here:
>
>     restore drill PASSED on 2026-__-__, measured RTO ~__ min (Vast/Kind, fresh cluster)
>
> Until that line is present and dated, treat the cold-restore path as
> documented-but-unverified. The measured RTO is **evidence from one drill in a
> specific environment — measure your own**; it is not a committed or guaranteed
> figure.

### Signing-key escrow & cold recovery

The compliance-DB backups above protect your **data**. They do NOT protect your
**signing seeds** — the backup pipeline dumps the three Postgres DBs and nothing
else. On the `k8s-native` Secret backend (and on the Compose path), the
customer-cluster `VEIL_*` signing seeds live ONLY inside the cluster. If the
cluster/Secret is lost, those seeds are gone: existing certificates stay
verifiable by anyone holding the public keys, but the rebuilt deployment cannot
re-issue or continue signing, and a cold-restore (above) has nothing to
re-provide in Step 1. Escrow closes that gap.

> **Customers on the `vault` / `aws` / `azure` (External Secrets) backend** keep
> their seeds in that backend and recover them from there — that backend IS the
> escrow. The offline escrow below is the recovery path for the **`k8s-native`**
> Secret backend and the **Compose** path, where the cluster holds the only copy.

#### What to escrow (exactly the customer-cluster ROOT seeds)

Escrow exactly the **independently-generated root signing seeds** the deployment
consumes — the seeds you produced at the ceremony with
`openssl rand -hex 32` (`customer.env.example:86`). These are the only values at
cluster-loss risk; the public keys and the manifest public keys are **derived
from them**, so they are NOT escrowed (you re-derive them on restore — see the
note below).

These are the env-var names the deploy actually consumes on the **Compose** path
(value-position `${...}` substitutions) and the matching `secrets.values.*` slots
on the **Helm** path. Take an OFFLINE encrypted copy of exactly this set:

| Root seed | Env var (Compose) | Helm `secrets.values.*` slot | Consumed by (pod) | Derived public key(s) | Cite |
|-----------|-------------------|------------------------------|-------------------|-----------------------|------|
| Audit Claim Key     | `LCR_AUDIT_SIGNING_KEY`     | `audit.secrets.values.veilSigningKey`            | audit         | `LCR_AUDIT_PUBLIC_KEY`     | `docker-compose.customer.yml:269`, `charts/lucairn/charts/audit/templates/secret.yaml:27`, `charts/lucairn/charts/audit/values.yaml:124` |
| Bridge Claim Key    | `LCR_BRIDGE_SIGNING_KEY`    | `id-bridge.secrets.values.veilSigningKey`        | id-bridge     | `LCR_BRIDGE_PUBLIC_KEY`    | `docker-compose.customer.yml:298`, `charts/lucairn/charts/id-bridge/templates/secret.yaml:19`, `charts/lucairn/charts/id-bridge/values.yaml:118` |
| Sanitizer Claim Key | `LCR_SANITIZER_SIGNING_KEY` | `sandbox-a.secrets.values.veilSigningKey`        | sandbox-a (sanitizer **sidecar**) | `LCR_SANITIZER_PUBLIC_KEY` | `docker-compose.customer.yml:367` (sanitizer svc), `charts/lucairn/charts/sandbox-a/templates/secret.yaml:20`, `charts/lucairn/charts/sandbox-a/templates/deployment.yaml:164-193` (sidecar `name: sanitizer` reads `LCR_SIGNING_KEY`), `customer-values.yaml.example:242` |
| Sandbox-B Claim Key | `LCR_SANDBOX_B_SIGNING_KEY` | `sandbox-b.secrets.values.veilSigningKey`        | sandbox-b     | `LCR_SANDBOX_B_PUBLIC_KEY` | `docker-compose.self-hosted.yml:157`, `customer.env.example:55`, `charts/lucairn/charts/sandbox-b/templates/secret.yaml:37`, `charts/lucairn/charts/sandbox-b/values.yaml:248` |
| Witness Signing Key | `LCR_WITNESS_SIGNING_KEY`   | `veil-witness.secrets.values.signingKey`         | veil-witness  | `LCR_WITNESS_PUBLIC_KEY` + `LCR_WITNESS_MANIFEST_PUBLIC_KEY` | `docker-compose.customer.yml:410`, `charts/lucairn/charts/veil-witness/templates/secret.yaml:27`, `charts/lucairn/charts/veil-witness/values.yaml:155` |
| Gateway Claim Key   | `LCR_GATEWAY_SIGNING_KEY`   | `gateway.secrets.values.veilGatewaySigningKey`   | gateway       | `LCR_GATEWAY_PUBLIC_KEY`   | `docker-compose.customer.yml:532` (`:?required`), `charts/lucairn/charts/gateway/templates/secret.yaml:38`, `charts/lucairn/charts/gateway/values.yaml:224` |
| Gateway Manifest Signing Key | `LCR_MANIFEST_SIGNING_KEY` | `gateway.secrets.values.veilManifestSigningKey` | gateway      | `LCR_GATEWAY_MANIFEST_PUBLIC_KEY` | `docker-compose.customer.yml:533`, `charts/lucairn/charts/gateway/templates/secret.yaml:27`, `charts/lucairn/charts/gateway/values.yaml:216`; signs the gateway manifest at `dual-sandbox-architecture services/gateway/internal/api/veil.go:206` (signer wired from `LCR_MANIFEST_SIGNING_KEY` at `main.go:1095`, published as `gateway_manifest_v1` at `veil.go:1284`) |

> **The sanitizer has no subchart of its own.** It runs as a sidecar container
> (`name: sanitizer`) inside the **sandbox-a** pod, so its signing seed is
> restored through the **`sandbox-a`** Helm slot — `sandbox-a.secrets.values.veilSigningKey`
> (`charts/lucairn/charts/sandbox-a/templates/deployment.yaml:164-193`). On the
> Compose path the seed is the distinct `LCR_SANITIZER_SIGNING_KEY` var consumed
> by the `sanitizer` service (`docker-compose.customer.yml:367`); on the Helm path
> the same value goes into the sandbox-a slot. `customer-values.yaml.example:242`
> labels the slot `REPLACE_WITH_64_HEX_SANITIZER_OR_SANDBOX_A_SIGNING_KEY`
> precisely because the sandbox-a pod's Veil signature *is* the sanitizer
> sidecar's signature — there is no separate sandbox-a root seed.

`bin/lucairn doctor` env-presence-checks this same set (minus `LCR_SANDBOX_B_SIGNING_KEY`,
whose presence it infers from the Sandbox-B path) as the deployment's required
secrets — see `bin/lucairn:231-236`.

> **Derived — do NOT escrow these** (re-derive from the seeds above on restore via
> `scripts/derive-veil-pubkey.sh`, which emits the Ed25519 public of a signing
> seed — `scripts/derive-veil-pubkey.sh:3-4`):
> - The per-service `LCR_*_PUBLIC_KEY` companions — each is the Ed25519 public of
>   its same-named signing seed (`LCR_AUDIT_PUBLIC_KEY` ← `LCR_AUDIT_SIGNING_KEY`,
>   `LCR_BRIDGE_PUBLIC_KEY` ← `LCR_BRIDGE_SIGNING_KEY`, `LCR_SANITIZER_PUBLIC_KEY`
>   ← `LCR_SANITIZER_SIGNING_KEY`, `LCR_WITNESS`/`LCR_SANDBOX_B`/`LCR_GATEWAY`
>   likewise). See `customer.env.example:94-101`.
> - `LCR_GATEWAY_MANIFEST_PUBLIC_KEY` — Ed25519 public of **`LCR_MANIFEST_SIGNING_KEY`**
>   (NOT `LCR_GATEWAY_SIGNING_KEY`). The gateway signs its manifest with the
>   `LCR_MANIFEST_SIGNING_KEY` seed (`dual-sandbox-architecture services/gateway/internal/api/veil.go:206`,
>   signer wired from `LCR_MANIFEST_SIGNING_KEY` at `main.go:1095`; published as
>   `gateway_manifest_v1` at `veil.go:1284`). Derive it with
>   `scripts/derive-veil-pubkey.sh "$LCR_MANIFEST_SIGNING_KEY"`.
> - `LCR_WITNESS_MANIFEST_PUBLIC_KEY` — Ed25519 public of `LCR_WITNESS_SIGNING_KEY`
>   (`charts/lucairn/charts/gateway/values.yaml:240-242`). Derive it with
>   `scripts/derive-veil-pubkey.sh "$LCR_WITNESS_SIGNING_KEY"`.
>
> There is **no separate witness-manifest signing seed**: the witness manifest is
> signed with the witness signing key (`LCR_WITNESS_SIGNING_KEY`), and the
> gateway manifest is signed with `LCR_MANIFEST_SIGNING_KEY` — these are two of
> the seven roots above, not extra seeds. `LCR_GATEWAY_SIGNING_KEY` is the
> gateway's own per-request **claim** signature (`main.go:462`), a distinct root
> from the gateway **manifest** signer. Escrowing the seven roots above recovers
> every signing and manifest path.
>
> The gateway binary signs its manifest with `LCR_MANIFEST_SIGNING_KEY`
> (`veil.go:206`), so `LCR_GATEWAY_MANIFEST_PUBLIC_KEY` MUST be the Ed25519
> public of `LCR_MANIFEST_SIGNING_KEY` (NOT `LCR_GATEWAY_SIGNING_KEY`) or the
> W2B Runtime Invariant Harness #3 self-check degrades.
>
> **The restore overlay above re-derives this pubkey explicitly (step (a),
> `PUB_GATEWAY_MANIFEST ← LCR_MANIFEST_SIGNING_KEY`) — that re-derivation is the
> authoritative restore path and is runtime-correct on its own, independent of the
> renderer.** A separate sibling PR (#63, `fix/render-values-gateway-manifest-pubkey`)
> fixes `scripts/render-values.sh` and `customer.env.example` so a *fresh* render
> derives `LCR_GATEWAY_MANIFEST_PUBLIC_KEY` from `LCR_MANIFEST_SIGNING_KEY`
> automatically. **AFTER #63 merges**, re-running `render-values.sh` (or following
> the `customer.env.example` derivation lines) produces the correct manifest
> public key with no manual override. **Until #63 merges, the renderer and
> `customer.env.example` on `main` still derive it from the wrong seed** — so for
> any restore today, use the explicit re-derivation in the overlay above as the
> source of truth and do NOT rely on a `render-values.sh` re-run alone.

These are the seeds at cluster-loss risk. The **License Signing Key** and the
**Image Signing Key** are Lucairn-held, off-cluster keys — they are NOT part of
your customer-cluster escrow (Lucairn holds their custody separately).

#### How to escrow — offline `age` (or GPG), off the data backups

The operator holds the escrow copy. Use the same `age` tooling the backups
already use — there is **no new vendor and no hosted key service**; you encrypt
to your own recipient and keep the identity offline:

```bash
# ONE-TIME at the key ceremony, on a secured operator host (NOT a cluster node).
# 1) Generate (or reuse) an escrow recipient key pair. Keep the identity OFFLINE.
age-keygen -o veil-escrow.identity            # prints the public recipient
RECIPIENT="$(grep 'public key:' veil-escrow.identity | awk '{print $NF}')"

# 2) Assemble the seven ROOT seeds you generated at the ceremony into one env
#    file in a tmpfs (never a shared/persisted filesystem). These are the exact
#    env-var names the deploy consumes — see the "What to escrow" table above.
#    ( umask 077; cat > ... ) creates the cleartext-seed file 0600; a plain
#    `cat >` under umask 022 would leave it 0644 (world-readable to local users).
( umask 077; cat > /dev/shm/veil-seeds.env <<'EOF'
LCR_AUDIT_SIGNING_KEY=<audit seed hex>
LCR_BRIDGE_SIGNING_KEY=<bridge seed hex>
LCR_SANITIZER_SIGNING_KEY=<sanitizer seed hex>
LCR_SANDBOX_B_SIGNING_KEY=<sandbox-b seed hex>
LCR_WITNESS_SIGNING_KEY=<witness seed hex>
LCR_GATEWAY_SIGNING_KEY=<gateway seed hex>
LCR_MANIFEST_SIGNING_KEY=<gateway manifest seed hex>
EOF
)
chmod 0600 /dev/shm/veil-seeds.env

# 3) Record a NON-DISCLOSING checksum of the plaintext (so step 4 can prove the
#    blob round-trips without ever re-printing a live seed). Store this checksum
#    alongside the escrow blob — it is a hash, not key material.
sha256sum /dev/shm/veil-seeds.env | awk '{print $1}' > veil-seeds.escrow.sha256

# 4) Encrypt to your offline recipient, then destroy the plaintext.
age -r "$RECIPIENT" -o veil-seeds.escrow.age /dev/shm/veil-seeds.env
shred -u /dev/shm/veil-seeds.env

# 5) Verify the round-trip WITHOUT disclosing any seed: decrypt to the same
#    checksum and compare. Nothing is echoed to the terminal; only an OK/FAIL.
if [ "$(age -d -i veil-escrow.identity veil-seeds.escrow.age | sha256sum | awk '{print $1}')" \
     = "$(cat veil-seeds.escrow.sha256)" ]; then
  echo "escrow round-trip OK"
else
  echo "escrow round-trip FAILED — do not rely on this blob" >&2
fi
```

> The decrypt in step 5 streams straight into `sha256sum` — the plaintext seeds
> are never written to disk or printed to the terminal, so a live seed never
> reaches scrollback or shell history. If you prefer an end-to-end proof instead
> of a checksum, restore the blob into a throwaway cluster (see "full
> cold-restore" above) and confirm a fresh cert verifies — that also never
> discloses a seed.

Store `veil-seeds.escrow.age` **separately from your `age`/GPG identity**, and
**OFF the S3 compliance-data backups** — the escrow copy must not co-reside with
the data dumps (it is the recovery input the cold-restore § consumes, and
keeping signing seeds out of the data backups preserves the key-custody
separation; see the DATA-08 crypto-shred caveat in § Backups).

GPG works the same way, but you **must** harden it to mirror the `age` flow — a
bare `gpg --decrypt` writes the plaintext seeds to **stdout** (scrollback +
shell history), which breaks the "a live seed is never printed" guarantee.
Always decrypt under `umask 077` straight into a `0600` tmpfs file, then verify
with the same non-disclosing checksum compare (never echo the seed):

```bash
# --- GPG escrow CREATE (fallback for the age create flow above) ---
# Step 2's ( umask 077; cat > /dev/shm/veil-seeds.env ... ) + step 3's
# sha256sum-to-veil-seeds.escrow.sha256 are IDENTICAL; only encrypt/decrypt change.
gpg --encrypt --recipient <key> -o veil-seeds.escrow.gpg /dev/shm/veil-seeds.env
shred -u /dev/shm/veil-seeds.env
# Verify the round-trip WITHOUT disclosing any seed (stream straight to sha256sum):
if [ "$(gpg --decrypt veil-seeds.escrow.gpg 2>/dev/null | sha256sum | awk '{print $1}')" \
     = "$(cat veil-seeds.escrow.sha256)" ]; then
  echo "escrow round-trip OK"
else
  echo "escrow round-trip FAILED — do not rely on this blob" >&2
fi

# --- GPG escrow DECRYPT (fallback for the restore decrypt flow above) ---
# umask 077 BEFORE the write so the seed-bearing plaintext is created 0600;
# --output writes to the file, NOT stdout, so no live seed reaches the terminal.
( umask 077; gpg --decrypt --output /dev/shm/veil-seeds.env veil-seeds.escrow.gpg )
chmod 0600 /dev/shm/veil-seeds.env   # belt-and-suspenders if gpg ignored the umask
set -a; . /dev/shm/veil-seeds.env; set +a
# ... use the seeds, then: shred -u /dev/shm/veil-seeds.env
```

> **Custody rules (do not bypass):**
> - The escrow copy is generated **off-cluster** at the ceremony. Never write a
>   plaintext seed to a cluster node or into a data backup.
> - The `age`/GPG **identity** stays offline and separate from the escrow blob.
> - Escrow is **not** key rotation. It recovers the SAME seeds you already run;
>   it never changes what is signed. Rotating a seed is the separate "Key
>   Rotation" procedure below (and the Veil Key Ceremony Runbook).
> - Re-verify the decrypt round-trip whenever you regenerate the escrow blob.

This escrow blob is exactly what the cold-restore runbook above consumes in
Step 1 to bring a rebuilt deployment back to a signing, verifying state.

## Witness mTLS

The veil-witness cert RPC port (:50058) accepts unauthenticated callers by
default. For production, see INSTALL.md § "Witness mTLS" for the full
enable recipe (Compose path and Helm/Kubernetes path). The witness degrades
gracefully to unauthenticated when any server-side cert path is unset, so
claims keep flowing during a cert rotation.

**To verify mTLS is active:**

```bash
# Should see TLS handshake, not a plain-text connection
openssl s_client -connect <witness-host>:50058 \
  -CAfile /opt/dsa/certs/witness-mtls/ca.crt \
  -cert   /opt/dsa/certs/witness-mtls/gateway-client.crt \
  -key    /opt/dsa/certs/witness-mtls/gateway-client.key
```

---

## Sanitizer content cache (Redis)

The sanitizer ships with a dedicated Redis content-cache
(`redis-sanitizer-cache` / Helm: `sandbox-a-sanitizer-cache` StatefulSet)
that is **default ON**. Cache hits skip Presidio L1/L2 entirely; the
cache fails-OPEN on Redis outage (miss, not 500).

**To verify the cache is working (Compose):**

```bash
# Two identical requests — second should show cache_hit_ratio=1.0
docker exec dsa-sandbox-a-1 wget -qO- \
  "http://localhost:8086/v1/sanitize" \
  --post-data '{"text":"Erika Schmidt, born 01.01.1980"}' | jq '.cache_stats'
```

**To monitor cache hit ratio (Helm):**

```bash
kubectl exec -n dsa-identity deploy/sandbox-a -c sanitizer -- \
  wget -qO- http://localhost:8086/v1/sanitize \
  --post-data '{"text":"test"}' | jq '.cache_stats'
```

To disable the bundled Redis cache, see INSTALL.md § "Sanitizer content cache".

---

## Key Rotation

Rotate in this order:

1. Upstream provider keys.
2. Gateway API keys.
3. Internal service token.
4. Database passwords.
5. Veil signing keys with a planned verification window.
6. `GATEWAY_KEYSTORE_KEY` only with a coordinated re-encryption migration.

Do not rotate all Veil keys at once. Keep retired public keys available through the witness-signed manifest retention window.

> **Rotation is not escrow.** Rotating a Veil seed replaces it with a new pair;
> it changes nothing about how a cold cluster recovers an EXISTING seed. To
> survive a full cluster/Secret loss you need an offline copy of the seeds you
> currently run — see § "Disaster recovery: full cold-restore" → "Signing-key
> escrow & cold recovery" above. Whenever you rotate a seed, regenerate the
> escrow blob so it holds the current seed set.

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

The public key ships with this kit at `keys/lucairn-cosign.pub`, and the exact
**signed digests** for each release ship at `keys/image-digests-<tag>.txt`.
Verification needs `cosign` (>= v2.0) plus a registry digest resolver
(`docker buildx`, `crane`, or `skopeo`) on PATH — nothing else; the public key
alone is sufficient (no Lucairn phone-home, no private material).

**Pin `cosign` itself (recommended).** cosign releases publish a
`cosign_checksums.txt` next to the binaries. Pin a known-good SHA-256 so a
tampered cosign can't quietly weaken your verification:

```bash
# 1. Download the binary + the project's checksums file for a pinned version.
VER=v2.4.1
curl -sSLO "https://github.com/sigstore/cosign/releases/download/${VER}/cosign-linux-amd64"
curl -sSLO "https://github.com/sigstore/cosign/releases/download/${VER}/cosign_checksums.txt"

# 2. Verify the binary against the published checksum (must print 'OK').
grep ' cosign-linux-amd64$' cosign_checksums.txt | sha256sum -c -

# 3. Optionally cross-check that sha256 against one you recorded out-of-band.
sha256sum cosign-linux-amd64

# 4. Install.
chmod +x cosign-linux-amd64 && sudo mv cosign-linux-amd64 /usr/local/bin/cosign
cosign version   # must report v2.x
```

**Verify the whole published set (recommended):**

```bash
# Reads keys/image-digests-<tag>.txt as the authoritative signed set, resolves
# each tag's CURRENT registry digest and asserts it equals the SIGNED digest (a
# re-pointed tag = downgrade/substitution = hard FAIL), then cosign-verifies
# each image BY DIGEST and requires a Rekor transparency-log entry. Prints
# PASS/FAIL per image; exits non-zero if ANY image fails.
# With one release recorded, no flag is needed — the tag is read from the
# committed keys/image-digests-*.txt (currently 0.5.0):
bin/lucairn verify-images

# Or pin the release explicitly:
bin/lucairn verify-images --tag 0.5.0

# Air-gapped mirror that re-hosts the SAME signed bytes:
bin/lucairn verify-images --tag 0.5.0 --registry registry.internal/lucairn
```

**Verify a single image with raw cosign (by digest).** Read the signed digest
from `keys/image-digests-0.5.0.txt`, then:

```bash
cosign verify --key keys/lucairn-cosign.pub \
  ghcr.io/declade/dsa-gateway@sha256:<digest-from-the-record-file>
```

A successful `cosign verify` exits 0 and reports the signature payload plus a
Rekor transparency-log entry (`logIndex`). An unsigned or tampered image — or
any image whose tag was re-pointed to other bytes — exits non-zero and is
rejected.

> The `keys/image-digests-<tag>.txt` record is the authoritative signed-set
> source for `verify-images`. These same digests are also folded into
> `image-manifest.yaml` (the `image_digests:` block) so `lucairn doctor`
> can WARN — and `lucairn doctor --strict` BLOCK — when a deployed tag's
> current registry digest no longer matches the recorded one. See
> **Digest-pin enforcement** below.

### Digest-pin enforcement (`doctor --strict`)

`image-manifest.yaml` records the `@sha256:` content digest each image was
built + signed against (the `image_digests:` block; the 13 signed Lucairn
artifacts are kept in lockstep with `keys/image-digests-<tag>.txt`). This lets
`doctor` verify that the mutable tags you deploy still resolve to the exact
bytes this kit release was validated against — **without** rewriting your
compose/Helm refs to `@sha256:`, so your `LUCAIRN_IMAGE_TAG` /
`LUCAIRN_IMAGE_REGISTRY` overrides keep working.

```bash
# Warn-only (default): a tag whose current registry digest differs from the
# recorded one prints a warning but does NOT fail the doctor run.
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml

# Fail-closed (verify-or-fail): --strict is a hard gate. A green --strict ALWAYS
# means "every enforceable ref was actually resolved and matched, with at least
# one ref confirmed and no dangerous skip". It fails (non-zero exit) on any of:
#   - a digest MISMATCH (re-pointed / substituted / downgraded tag);
#   - an UNRESOLVED non-pending ref (a resolver was present but could not read
#     the current digest — fail-closed, so an attacker can't pass by inducing an
#     error for the one ref they swapped);
#   - an INVALID manifest entry (a present-but-malformed digest, or a digest +
#     pending:true contradiction — a manifest-integrity error, NOT a pending
#     slot);
#   - the cardinality floor: --strict verified nothing (everything pending /
#     unresolved) — distinct message, refusing to report a green run that
#     confirmed nothing.
# --strict is distinct from --strict-runtime (which fail-closes on the gateway
# /healthz + /readyz probes); you can pass both, they are independent.
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --strict
```

**Resolver + offline.** `--strict` enforces LIVE registry digests, so it needs a
registry digest resolver on PATH (`docker buildx imagetools`, `crane`, or
`skopeo`) plus network reach to the registry:

- **plain `doctor`** (no `--strict`) with **no resolver** SKIPS the digest check
  (warns, never fails the run) — "cannot verify" is deliberately not treated as
  "verified mismatch", so a fresh install is never blocked by an un-resolvable
  check.
- **plain `doctor --offline`** skips the LIVE digest comparison (warn-only) — by
  definition it has no registry reach.
- **`doctor --strict --offline`** is a **hard error** (non-zero): you cannot
  enforce live digests offline. Drop `--offline`, or run a plain `--offline`
  doctor for the warn-only check.
- **`doctor --strict` with NO resolver on PATH** is a **hard error** (non-zero):
  `--strict` cannot verify anything without a resolver — install
  `crane`/`skopeo` or ensure `docker buildx` is available.

The `dsa-*` services honor your `LUCAIRN_IMAGE_TAG` / `LUCAIRN_IMAGE_REGISTRY`
overrides when the effective ref is resolved. The `lucairn-dashboard` image —
also one of the cosign-signed artifacts — honors the same
`LUCAIRN_IMAGE_REGISTRY` plus its OWN tag var `LUCAIRN_DASHBOARD_IMAGE_TAG`
(default `0.8.2`, distinct from the `dsa-*` `LUCAIRN_IMAGE_TAG`), so a dashboard
tag/registry override is digest-checked under `--strict` like the `dsa-*`
services.

**Pending (un-pinned) entries.** Some `image_digests:` slots ship as
`pending: true` — they have a schema slot but no enforceable digest yet. These
are the L3 PII-shield model (`qwen2.5:7b`, an Ollama model manifest, not an OCI
image) and the opt-in self-hosted runtime alternatives
(`docker-compose.self-hosted.yml`: vLLM / TGI / ONNX Runtime / Triton /
llama.cpp / the generic runtime adapter), which float a mutable tag or are
operator-built. `doctor --strict` SKIPS pending entries (it never blocks on
them), and they are filled in during the **digest-pin ceremony** for the
specific runtime a customer actually deploys:

> This ceremony pull is to **record** the model's digest for the manifest. It
> is NOT how you stage the runtime model into a customer's air-gapped
> `ollama-identity` — that runs on an internal-only (no-egress) network; see
> INSTALL.md § "Pre-stage the L3 deep PII-shield model" for the throwaway-pull
> staging procedure.

```bash
# L3 model digest (run on a host with ollama):
ollama pull qwen2.5:7b
ollama show qwen2.5:7b --modelfile | grep -i digest   # record the model digest

# Self-hosted runtime image digest (run on a host with a resolver), for the ONE
# runtime you deploy, e.g. vLLM:
crane digest vllm/vllm-openai:<the-tag-you-pin>        # or: skopeo / docker buildx imagetools
```

Record the resolved value into the matching `pending:` slot's `digest:` field
in `image-manifest.yaml` (drop the `pending: true` line). The
`ollama-identity` runtime image is already digest-pinned — both in
`image-manifest.yaml` and in the Helm chart
(`charts/lucairn/charts/sandbox-a/values.yaml` → `ollamaIdentity.image.digest`).

For the Image Signing Key's custody model, generation, and rotation procedure,
see the DSA repo `docs/operations/key-ceremony-runbook.md` § Key Inventory
(Image Signing Key). The private cosign key and its password are Lucairn-held,
stored mode-600 on the Lucairn issuer host, and are never distributed.

## Fetch + verify the Software Bill of Materials (SBOM)

Every published Lucairn image ships a per-image **Software Bill of Materials**
(SBOM) in **SPDX-JSON** format, listing every package the image contains. The
SBOM is attached to its image as a **cosign-signed SPDX attestation**, with the
signature logged to the **Sigstore Rekor public transparency log** — signed by
the **same Image Signing Key** that signs the images themselves (no extra key,
no extra vendor). You can fetch the SBOM, verify it came from Lucairn, and
inspect exactly what is in each image — useful for vulnerability triage and a
supply-chain questionnaire's "do you provide an SBOM?".

Note the division of labour: `lucairn verify-images` is the image-integrity gate
— it is digest-pinned (verifies against the recorded signed digest in
`keys/image-digests-<tag>.txt`) and refuses a re-pointed tag as a
downgrade/substitution. `lucairn sbom` instead fetches + verifies the SBOM
attestation for whatever bytes the given image ref currently resolves to, so run
`verify-images` first if you want to assert the bytes are the published ones.

Verification needs `cosign` (>= v2.0) on PATH (see "Verify image signatures"
above for the pin-cosign-by-checksum recipe). `jq` is recommended for the
richest summary.

**Fetch + verify with the kit helper (recommended):**

```bash
# Verifies the SPDX SBOM attestation against keys/lucairn-cosign.pub, requires a
# Rekor transparency-log entry, then summarizes it (package count, SPDX version,
# document name). Exits non-zero if the attestation is missing/invalid.
bin/lucairn sbom ghcr.io/declade/dsa-gateway:0.5.0

# Also save the raw verified SPDX-JSON SBOM to a file:
bin/lucairn sbom ghcr.io/declade/dsa-gateway:0.5.0 \
  --download dsa-gateway-0.5.0.spdx.json

# Air-gapped mirror that re-hosts the SAME signed bytes:
bin/lucairn sbom ghcr.io/declade/dsa-gateway:0.5.0 \
  --registry registry.internal/lucairn
```

**Fetch + verify with raw cosign (equivalent):**

```bash
# Verify the SPDX attestation (prints the signed DSSE envelope + Rekor entry):
cosign verify-attestation --type spdxjson \
  --key keys/lucairn-cosign.pub \
  ghcr.io/declade/dsa-gateway:0.5.0

# Extract just the SPDX-JSON SBOM predicate (the package list):
cosign verify-attestation --type spdxjson \
  --key keys/lucairn-cosign.pub \
  ghcr.io/declade/dsa-gateway:0.5.0 \
  | jq -r '.payload' | base64 -d | jq '.predicate' > dsa-gateway-0.5.0.spdx.json
```

A successful verification exits 0 and reports a Rekor transparency-log entry; a
missing or invalid attestation exits non-zero. The same procedure works for any
published image (the 12 `dsa-*` services + `lucairn-dashboard`) — swap the
image reference.

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

### v0.5.1 / chart 1.9.1 — over-redaction fix (2026-06-14)

Schema change: none. No database migration required.

Sanitizer-only image change: the `0.5.1` sanitizer image includes two
L1+L2 false-positive-reduction fixes. Operators get fewer PERSON redactions
on product vocabulary (Claude/signable/…) with no change to recall on real
PII. The strict safe list is bundled in `config/safe-terms-strict.txt` and
auto-mounted by `docker-compose.customer.yml`; Helm operators get it via the
`sanitizer-config` ConfigMap key `safe-terms-strict.txt`.

**Compose:** set `LUCAIRN_IMAGE_TAG=0.5.1` in `customer.env`, then:
```bash
docker compose -f docker-compose.customer.yml --env-file customer.env pull sanitizer
docker compose -f docker-compose.customer.yml --env-file customer.env up -d --no-deps --force-recreate sanitizer
```

**Helm:** set `global.imageTag: "0.5.1"` (or override `sandbox-a.sanitizer.imageTag`) and apply:
```bash
helm upgrade lucairn charts/lucairn -n lucairn -f your-values.yaml
```

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
