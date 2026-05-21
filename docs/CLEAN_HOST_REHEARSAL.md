# Clean-Host Rehearsal

A clean-host rehearsal proves the enterprise bundle can be installed from the customer-facing artifact alone. It should run before the first real customer handoff for a new bundle shape, image-delivery mode, or model-runtime profile.

## Host Rule

Use a fresh Linux host or VM with:

- Docker Engine and Docker Compose v2 installed
- no Lucairn repo checkout
- no pre-pulled Lucairn images unless the customer will also receive them that way
- no copied secrets except the exact bundle and customer-approved env values (Lucairn-default GHCR images are public; registry credentials are only required if the customer mirrors the images into a private registry)

## Rehearsal Steps

1. Copy only the bundle tarball and checksum to the host.
2. Verify the checksum before extraction.

```bash
shasum -a 256 lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
```

3. Extract and verify the bundle.

```bash
tar -xzf lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
cd lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ
bin/lucairn bundle verify --bundle .
```

4. If `images/lucairn-images.tar` exists, load it.

```bash
docker load -i images/lucairn-images.tar
```

If image delivery is registry-based, skip `docker load` and authenticate to the configured registry instead.

5. Run the offline doctor.

```bash
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml --offline
```

6. Run the live doctor only after registry/network access is intentionally configured.

```bash
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml
```

7. Start the stack.

```bash
docker compose \
  -f install/docker-compose.customer.yml \
  -f install/docker-compose.self-hosted.yml \
  --env-file install/customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" \
  up -d
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
