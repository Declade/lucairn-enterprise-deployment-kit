# Customer Bundle Builder

Use a customer bundle when Lucairn prepares a delivery package manually with customer-specific model files, images, config, and install docs.

## Model Formats

The bundle contract is runtime-neutral. The model manifest supports:

- `gguf` with `llama-cpp`.
- `safetensors` or `pytorch` with `vllm` or `tgi`.
- `ollama` with the `ollama` profile.
- `onnx` with an OpenAI-compatible ONNX runtime container.
- `tensorrt-llm` with an OpenAI-compatible Triton/TensorRT runtime container.
- `openai-compatible` with an external customer endpoint.
- `custom` with any runtime image that exposes an OpenAI-compatible API inside the Compose network.

## Create a Bundle

```bash
bin/lucairn bundle create \
  --customer-slug acme \
  --models-dir /secure/staging/acme/models \
  --model-manifest /secure/staging/acme/model-manifest.yaml \
  --env /secure/staging/acme/customer.env \
  --image-tar /secure/staging/acme/lucairn-images.tar \
  --output dist/customer-bundles
```

The command writes:

```text
dist/customer-bundles/lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
```

## Verify Before Sending

```bash
bin/lucairn bundle verify --bundle dist/customer-bundles/lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
```

Verification checks:

- Bundle structure.
- Model manifest support.
- Model file presence.
- SHA256 checksums for every bundled file.

Run this command on the trusted packaging/handoff station before transfer. It
validates the S1 bundle contract, but does not complete publisher
authentication; that remains WP4 S6 work.

## Agent Package Factory

Codex, Claude Code, or another approved agent can create and verify the bundle from a standard staging directory:

```bash
bin/lucairn bundle prepare \
  --customer-slug acme \
  --staging-dir /secure/staging/acme \
  --output /secure/outbound/acme
```

The staging directory must contain:

```text
customer.env
customer.env.runtime-profile.yaml  # required beside customer.env for S1-generated installs
customer.env.image-manifest.yaml   # recorded init-time image manifest; required for S1
models/model-manifest.yaml
models/[model files]
images/lucairn-images.tar
```

The image archive is optional when the customer will pull images from a registry. S1 runtime state is three non-secret/secret-adjacent artifacts: `customer.env`, its runtime-profile sidecar, and its recorded image-manifest snapshot. A marker-bearing `customer.env` without either sidecar fails closed; deletion, symlinking, or changing the snapshot is not recoverable by silently using the current kit manifest. A genuinely pre-S1 env has no sidecars and remains legacy-only until explicit adoption. For local-runtime, its declared model name and file must agree with `models/model-manifest.yaml`; the canonical bundle `MODEL_PATH` is `.` because `models/` is mounted at `/models`. Optional staged `customer-data/`, `demo-data/`, or `data/` is copied into `customer-data/` inside the bundle. Source trees and verified bundles may contain only regular files/directories, and `SHA256SUMS` must cover the exact payload set. `bundle prepare` performs the manifest/file gate and writes a non-secret report named `lucairn-customer-bundle-[slug]-report.txt` with the bundle checksum, model metadata, image delivery mode, customer data presence, and `bundle_verify=ok`.

## Customer Install

The customer receives the tarball and its SHA256 checksum through the approved
authenticated handoff channel. Before raw extraction, the customer compares
the tarball digest to that separately supplied checksum; the CLI inside an
unverified archive cannot authenticate the archive.

```bash
shasum -a 256 lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
# Match the printed digest to the separately supplied handoff checksum.
tar -xzf lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
cd lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ
bin/lucairn bundle verify --bundle .
# Follow the generated mode-specific command in INSTALL-CUSTOMER.md.
# It selects the exact overlays recorded in install/customer.env.runtime-profile.yaml.
```

After the extracted-bundle check, the generated note is mode-aware: archive
delivery names a real image archive to load, registry delivery says to
authenticate and not to run `docker load`, and directory delivery refers to
the authenticated handoff instructions for its actual files. The note also
orders doctor correctly for managed-BYOK: set at least one provider key before
doctor. A fresh BYOK env is intentionally not already doctor-passing.

The generated S1 note starts/stops/inspects via the profile-bound lifecycle
commands (`bin/lucairn up|down|status|logs|pull --env install/customer.env --compose install/docker-compose.customer.yml`).
For split-remote, the original init must use the Lucairn-issued remote
credential file; neither the remote endpoint nor the license supplies remote
API authentication by itself.

## Important

The bundle may contain customer secrets and customer-owned model files. Store it under the customer engagement directory, encrypt it at rest, and do not upload it to generic issue trackers or shared drives.
