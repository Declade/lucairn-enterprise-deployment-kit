# Customer Handoff Gates

This is the pre-send checklist for any Lucairn enterprise install package. It is intentionally operational, not commercial or legal.
Every handoff gate below must be satisfied before the package leaves the private engagement workspace.

## Required Inputs

- customer slug and internal engagement owner
- install owner on the customer side
- selected deployment path: Docker Compose bundle or Kubernetes values
- image delivery mode: registry, customer mirror, tar archive, or directory archive
- model runtime mode: external OpenAI-compatible endpoint or bundled self-hosted runtime profile
- `customer.env.runtime-profile.yaml` and `customer.env.image-manifest.yaml`
  beside `customer.env` for every S1-generated Compose install
- exact bundle path, SHA256 checksum, and generated non-secret report
- approved delivery channel for the bundle and checksum

## Build Gate

Run from this repository:

```bash
bin/lucairn bundle prepare \
  --customer-slug acme \
  --staging-dir /secure/staging/acme \
  --output /secure/outbound/acme
```

The generated report must contain:

```text
bundle_verify=ok
customer_env=present
image_delivery=archive|directory|registry
```

For a local-runtime handoff, verify the profile's declared model name and file
agree with `models/model-manifest.yaml`. The bundle rule is
`MODEL_PATH=.`: the bundle's `models/` directory is mounted at `/models`.
This is not a claim that the model is available; `bundle prepare` performs the
later manifest/file gate. A marker-bearing env whose runtime-profile or
recorded image-manifest sidecar is missing, symlinked, or changed must not be
sent: it fails closed. A pre-S1 env without either sidecar is a clearly
labeled legacy handoff until explicit adoption.

If `customer_data=present`, confirm the staged data is synthetic or explicitly approved for that engagement before packaging.

## Verification Gate

Run these against the exact artifact that will be sent. Use `--require-sha256`,
`--customer-slug`, and `--max-age-days` so the receiver gate matches the
operator gate even if the manifest has been tampered to declare a weaker
policy or replay a stale bundle. This runs at the trusted packaging/handoff
station before transfer; it validates the S1 payload contract but does not
complete publisher authentication:

```bash
bin/lucairn bundle verify \
  --bundle /secure/outbound/acme/lucairn-customer-bundle-acme-*.tar.gz \
  --require-sha256 \
  --customer-slug acme \
  --max-age-days 30
```

- `--require-sha256` forces `checksum_policy: sha256-required` regardless of
  the manifest, so a downgraded `checksum_policy: none` cannot bypass the
  re-hash.
- `--customer-slug` rejects bundles whose `bundle-manifest.txt` was built for
  a different customer (cross-customer replay).
- `--max-age-days` rejects bundles older than N days (stale-bundle replay).

The customer must receive the exact SHA256 checksum separately through the
approved authenticated handoff channel and compare it before raw extraction.
Never describe the `bin/lucairn` copied from an unverified archive as the
authentication mechanism for that archive.

Then extract the bundle into a temporary directory and run:

```bash
bin/lucairn doctor \
  --env install/customer.env \
  --compose install/docker-compose.customer.yml \
  --offline
```

After registry authentication, start the recorded topology, wait for health and
readiness, then mint the first customer key into a regular mode-0600 file. Run
the online full doctor only after those steps (Lucairn-default GHCR is private;
see `INSTALL.md` § "Registry Authentication"). It consumes the existing key
and never stores it; split-remote and managed-BYOK also require an explicit
operator-selected model.

```bash
bin/lucairn up --env install/customer.env --compose install/docker-compose.customer.yml
# wait for readiness; mint /secure/lucairn-customer.key and chmod 600
# local-runtime uses its recorded model and does not receive --model:
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml \
  --customer-key-file /secure/lucairn-customer.key
# split-remote or managed-byok only: add the operator-selected model:
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml \
  --customer-key-file /secure/lucairn-customer.key --model <selected-model>
```

For managed-BYOK, set at least one provider key in the staged env before start;
init deliberately leaves provider keys empty and skips its own doctor run.

For split-remote, record that the Lucairn-issued remote credentials file was
used at init (without recording its contents). Endpoint plus license alone is
not a valid remote-auth handoff. Use the S1 lifecycle wrappers for start,
upgrade pull, status, bounded logs, and non-destructive down.

## Handoff Gate

Record the following in the private engagement note before sending:

- bundle filename and SHA256 checksum
- checksum delivery through the approved authenticated channel (separate from
  the raw tarball)
- generated report filename
- image delivery mode and whether `docker load` is expected
- model runtime profile and whether model weights are bundled
- runtime-profile sidecar present (or explicitly approved pre-S1 legacy status)
- install owner and planned install window
- support contact path for redacted support bundles
- explicit note that Lucairn support does not need shell access or unredacted env files

Do not send the package if any gate is missing, if the generated report includes secrets, or if the delivery mode in the report does not match the customer install plan.
