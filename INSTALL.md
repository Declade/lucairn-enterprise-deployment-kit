# INSTALL

Goal: a competent platform engineer should complete a standard install in about 3 hours without a vendor call.

## Pre-Requisites

For Docker Compose:

- Linux host with Docker Engine and Docker Compose v2.
- 4 vCPU, 16 GB RAM minimum for customer-side split deployment.
- TLS-terminating reverse proxy such as Caddy, Nginx, Traefik, or an enterprise ingress proxy.
- Outbound HTTPS to Lucairn-provided remote Sandbox B endpoint if using split deployment.

For Kubernetes:

- Kubernetes 1.28 or newer.
- Helm 3.13 or newer.
- Ingress controller with TLS.
- NetworkPolicy-capable CNI. Cilium is preferred for DNS controls and WireGuard encryption.
- Secret manager integration, or permission to create Kubernetes native secrets.

## Docker Compose Install

1. Unpack the release bundle.

```bash
tar -xzf lucairn-enterprise-deployment-kit-1.1.0-enterprise-customer-bundle.tar.gz
cd lucairn-enterprise-deployment-kit
```

2. Create the customer env file.

```bash
cp customer.env.example customer.env
chmod 600 customer.env
```

3. Log in to the private image registry.

Lucairn provides a GHCR username/token or mirrors the images into the customer's registry.

```bash
docker login ghcr.io
```

If the customer uses an internal registry mirror, set `LUCAIRN_IMAGE_REGISTRY` in `customer.env`.

4. Replace every `REPLACE_*` value in `customer.env`.

Generate random values:

```bash
openssl rand -hex 32       # 32-byte random as 64 hex chars (signing keys, tokens)
openssl rand -base64 32    # 32-byte random as base64           (GATEWAY_KEYSTORE_KEY)
```

**WARNING — DO NOT use `openssl rand -hex 32` for `VEIL_*_PUBLIC_KEY` slots.**
The public key MUST be derived from the corresponding private key (the
`VEIL_*_SIGNING_KEY` of the same service). Filling the public-key slots
with independently-generated random hex yields a key that does NOT match
the signing key, and every Veil claim the service signs will be silently
rejected by the witness verifier — the stack will look healthy but no
certificates will validate.

### 4a. Generate Ed25519 signing keypairs

For each of the following five service pairs, generate the signing-key
seed with `openssl rand -hex 32`, then derive the matching public key
using the bundled helper at `scripts/derive-veil-pubkey.sh`:

| Signing-key slot              | Public-key slot              |
|-------------------------------|------------------------------|
| `VEIL_AUDIT_SIGNING_KEY`      | `VEIL_AUDIT_PUBLIC_KEY`      |
| `VEIL_BRIDGE_SIGNING_KEY`     | `VEIL_BRIDGE_PUBLIC_KEY`     |
| `VEIL_SANITIZER_SIGNING_KEY`  | `VEIL_SANITIZER_PUBLIC_KEY`  |
| `VEIL_WITNESS_SIGNING_KEY`    | `VEIL_WITNESS_PUBLIC_KEY`    |
| `VEIL_GATEWAY_SIGNING_KEY`    | `VEIL_GATEWAY_PUBLIC_KEY`    |

Bash one-liner — fills both slots for one service in two lines of
output you can paste into `customer.env`:

```bash
SEED=$(openssl rand -hex 32)
echo "VEIL_AUDIT_SIGNING_KEY=$SEED"
echo "VEIL_AUDIT_PUBLIC_KEY=$(scripts/derive-veil-pubkey.sh "$SEED")"
```

Repeat for `BRIDGE`, `SANITIZER`, `WITNESS`, and `GATEWAY`.

`VEIL_MANIFEST_SIGNING_KEY` (no matching `_PUBLIC_KEY` slot) is the
manifest-only signing key and only needs the `openssl rand -hex 32`
step.

`VEIL_SANDBOX_B_PUBLIC_KEY` is **Lucairn-provided** (not customer-derived) —
the matching signing key lives on the Lucairn-hosted Sandbox B fleet.
Use whatever value Lucairn issues during onboarding; do not regenerate.

The helper requires Python 3 with the `cryptography` package (preferred)
or `pynacl`. Both are pure-Python wheels; install with
`pip install cryptography` if either is missing.

5. Run offline validation before network checks.

```bash
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
```

6. Run live validation.

```bash
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
```

The live validation checks whether the configured Lucairn images are pullable. If it fails with `container images: failed`, fix registry access before continuing.

7. Start the stack.

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env up -d
```

8. Confirm health.

```bash
curl -fsS http://127.0.0.1:8085/healthz
curl -fsS http://127.0.0.1:8085/readyz
```

9. Put the gateway behind TLS.

Terminate HTTPS at the customer reverse proxy and forward to `127.0.0.1:8080`. If the proxy is local or containerized, set `GATEWAY_TRUSTED_PROXY_CIDRS` to the proxy source CIDRs and rerun `bin/lucairn doctor`.

## Kubernetes Install

1. Create the image pull secret.

```bash
kubectl create namespace lucairn
kubectl create secret docker-registry lucairn-registry \
  --namespace lucairn \
  --docker-server ghcr.io \
  --docker-username "$GHCR_USERNAME" \
  --docker-password "$GHCR_TOKEN"
```

2. Prepare values.

```bash
cp customer-values.yaml.example customer-values.yaml
```

3. Replace every `REPLACE_*` value. Prefer an external secret manager for production.

4. Build chart dependencies and render once.

```bash
helm dependency build charts/lucairn
helm template lucairn charts/lucairn -f customer-values.yaml --namespace lucairn >/tmp/lucairn-rendered.yaml
```

5. Install.

```bash
helm upgrade --install lucairn charts/lucairn \
  -f customer-values.yaml \
  --namespace lucairn \
  --create-namespace
```

6. Watch rollout.

```bash
kubectl get pods -A -l app.kubernetes.io/part-of=dsa
kubectl rollout status deployment/gateway -n dsa-edge
```

## Support Bundle

If installation fails, generate a bundle:

```bash
bin/lucairn support-bundle --env customer.env --compose docker-compose.customer.yml
```

Review the archive before emailing it to Lucairn support.

## Customer Bundle Install

Use this path when Lucairn has prepared a customer-specific bundle with model files and image archives.

1. Unpack the bundle.

```bash
tar -xzf lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
cd lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ
```

2. Verify checksums.

```bash
bin/lucairn bundle verify --bundle .
```

3. Load images.

```bash
docker load -i images/lucairn-images.tar
```

4. Run pre-flight checks.

```bash
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml --skip-image-check
```

5. Start the selected model runtime profile.

```bash
docker compose \
  -f install/docker-compose.customer.yml \
  -f install/docker-compose.self-hosted.yml \
  --env-file install/customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" \
  up -d
```

6. Confirm health.

```bash
curl -fsS http://127.0.0.1:8085/healthz
curl -fsS http://127.0.0.1:8085/readyz
```
