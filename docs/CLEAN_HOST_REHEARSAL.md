# Clean-Host Rehearsal

A clean-host rehearsal proves the enterprise bundle can be installed from the customer-facing artifact alone. It should run before the first real customer handoff for a new bundle shape, image-delivery mode, or model-runtime profile.

## Host Rule

Use a fresh Linux host or VM with:

- Docker Engine and Docker Compose v2 installed
- no Lucairn repo checkout
- no pre-pulled Lucairn images unless the customer will also receive them that way
- no copied secrets except the exact bundle, customer-approved env values, and the GitHub PAT used to authenticate against ghcr.io (Lucairn-default GHCR images are currently private; the rehearser MUST exercise the `docker login ghcr.io` flow the customer will use. If the customer mirrors the images into a private registry, use the mirror's credentials instead.)

## Rehearsal Steps

1. Copy only the bundle tarball and the SHA256 checksum supplied through the
   approved authenticated handoff channel to the host.
2. Verify that external checksum before raw extraction. Do not use the CLI
   inside the unverified archive for this gate.

```bash
shasum -a 256 lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
```

Match the printed value byte-for-byte to the separately supplied checksum and
stop on any difference. S1 has not completed publisher authentication.

3. Only after that gate, extract and verify the bundle's internal contract.

```bash
tar -xzf lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
cd lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ
bin/lucairn bundle verify --bundle .
```

4. Follow the image-delivery section of the generated `INSTALL-CUSTOMER.md`
   only after the bundle check. Archive delivery names the real archive to
   load; registry delivery skips `docker load` and authenticates to the
   configured registry; directory delivery follows the authenticated handoff
   instructions for its actual files and never assumes a fixed archive.

5. Run the offline doctor.

```bash
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml --offline
```

6. Start the stack and wait for health and readiness. The offline doctor is
configuration-only; do not run online doctor before this point.

Run the exact mode-specific command in the generated `INSTALL-CUSTOMER.md`.
Do not replace it with a fixed overlay command: split bundles exclude
self-hosted files and managed-BYOK requires its own overlay. Confirm that
`install/customer.env.runtime-profile.yaml` and
`install/customer.env.image-manifest.yaml` remain beside `install/customer.env`;
a marker-bearing env without either sidecar must fail closed. For managed-BYOK,
set at least one provider key before starting the stack.

For S1, start and inspect with `bin/lucairn up --env install/customer.env --compose install/docker-compose.customer.yml` and
`bin/lucairn status --env install/customer.env --compose install/docker-compose.customer.yml`; use `pull`, bounded `logs`,
and non-destructive `down` with the same `--compose install/docker-compose.customer.yml`
path rather than recreating Compose flags. Split-remote rehearsal also requires the Lucairn-issued remote
credential file—endpoint and license alone are insufficient.

7. Mint the first customer key, save it as an existing regular mode-0600 file,
and run the online full doctor. It consumes the key only; never put it in an
env file or support bundle. Split-remote and managed-BYOK also require the
operator-selected model; local-runtime uses its recorded inventory name.

```bash
# local-runtime: after minting /secure/lucairn-customer.key (chmod 600)
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml \
  --customer-key-file /secure/lucairn-customer.key

# split-remote or managed-byok only: add the operator-selected model
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml \
  --customer-key-file /secure/lucairn-customer.key --model <selected-model>
```

8. Confirm health.

```bash
curl -fsS http://127.0.0.1:8085/healthz
curl -fsS http://127.0.0.1:8085/readyz
```

9. Generate a redacted support bundle.

```bash
bin/lucairn support-bundle \
  --env install/customer.env \
  --compose install/docker-compose.customer.yml \
  --output support-out
```

## Pass Criteria

- bundle verification passes
- doctor passes in the expected mode
- stack reaches healthy and ready
- support bundle is generated and does not expose secrets
- every discovered edge case is added to `INSTALL.md`, `OPS.md`, `TROUBLESHOOTING.md`, `bin/lucairn doctor`, or this document before the customer receives the package

## Transcript

Store the command transcript, host details, bundle checksum, image delivery mode, and model runtime mode in the private customer engagement folder. Do not commit customer secrets or host-specific credentials.
