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

## `/healthz` Returns 200 But `/readyz` Returns 503

This is the most common "deployed but unusable" failure mode on a fresh install.
`/healthz` returns 200 as soon as the gateway process is listening on its port —
even if upstream service-link circuit breakers (sanitizer, witness, audit,
sandbox-b, bridge, identity) are open. Only `/readyz` reflects the full readiness
state. A `docker compose ps` row showing `(healthy)` therefore is not sufficient
evidence the gateway can actually serve traffic.

`bin/lucairn doctor` now probes both endpoints after the pre-deploy checks and
surfaces a 503 readyz with the specific recovery commands. To make doctor exit
non-zero on a 503 (e.g. in CI), pass `--strict-runtime`.

Common root causes on a fresh deploy:

- `SANDBOX_B_REMOTE_ENDPOINT` defaults to `https://inference.lucairn.example`,
  which is DNS-resolvable but never reachable. Split-deployment customers must
  set this to a Lucairn-provisioned endpoint. Self-hosted-inference customers
  must load `docker-compose.self-hosted.yml` so `SANDBOX_B_REMOTE_ENDPOINT` is
  blanked and the local `sandbox-b` container is added to the stack.
- Sanitizer config references recognizers not present in the deployed image
  (image-version drift). The sanitizer container crash-loops and the gateway's
  sanitizer circuit breaker opens.
- Bridge or witness signing keys are mismatched, so claim verification fails
  during the first request that hits each path.

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
