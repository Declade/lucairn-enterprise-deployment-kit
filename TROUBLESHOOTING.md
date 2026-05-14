# TROUBLESHOOTING

## Compose Refuses to Start

Run:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env config --quiet
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
```

Common causes:

- Missing `DSA_SERVICE_TOKEN`.
- `GATEWAY_KEYSTORE_KEY` is not base64 32 bytes.
- A required Veil key is blank.
- Host port 8080 or 8085 is already in use.
- Private GHCR images are not pullable. Run `docker login ghcr.io` or use the customer registry mirror in `LUCAIRN_IMAGE_REGISTRY`.

## Gateway Unhealthy

Check:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env logs --tail 300 gateway
curl -v http://127.0.0.1:8085/healthz
curl -v http://127.0.0.1:8085/readyz
```

Likely causes:

- Bridge or Sandbox A is not ready.
- Remote Sandbox B endpoint is unreachable.
- License values are missing.
- Witness manifest path is configured but the file is not mounted.

## Sanitizer Slow to Become Ready

The sanitizer can take longer on first boot while models load.

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env logs --tail 300 sanitizer
```

If memory pressure appears, raise the container memory limit. The Compose kit defaults to 2 GB for sanitizer.

## Certificate Errors

Run:

```bash
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
openssl x509 -noout -subject -issuer -dates -in path/to/cert.pem
```

Common causes:

- Wrong CA bundle for remote Sandbox B.
- Client cert and key do not match.
- Cert expires within 30 days.
- Witness mTLS files are mounted into the wrong directory.

## Generating a Support Bundle

```bash
bin/lucairn support-bundle --env customer.env --compose docker-compose.customer.yml
```

The generated archive includes:

- Version metadata.
- Redacted env file.
- Redacted compose file and resolved compose config when available.
- Container status.
- Logs.
- Certificate validity report.
- Schema-version placeholder or available schema notes.

Review the archive before sending it to Lucairn support.
