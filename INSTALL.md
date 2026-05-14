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
tar -xzf lucairn-enterprise-deployment-kit-1.0.0-enterprise-deployment-kit.tar.gz
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
openssl rand -hex 32
openssl rand -base64 32
```

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
