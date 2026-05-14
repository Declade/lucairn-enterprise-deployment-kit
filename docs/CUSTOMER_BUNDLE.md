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

## Customer Install

Customer receives one tarball and runs:

```bash
tar -xzf lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
cd lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ
docker load -i images/lucairn-images.tar
bin/lucairn bundle verify --bundle .
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml --skip-image-check
docker compose \
  -f install/docker-compose.customer.yml \
  -f install/docker-compose.self-hosted.yml \
  --env-file install/customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" \
  up -d
```

## Important

The bundle may contain customer secrets and customer-owned model files. Store it under the customer engagement directory, encrypt it at rest, and do not upload it to generic issue trackers or shared drives.

