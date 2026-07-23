# Fast L3 PII-shield runtime (vLLM) — sizing, requirements, and enablement

The level-3 deep PII shield (a Qwen2.5-7B model) runs on **Ollama by default**
(the `ollama-identity` service). Ollama time-slices concurrent L3 requests on a
single GPU, giving a hard ceiling of **~5 rec/s on one RTX 4090** — fine for
interactive turns, weak under concurrency / bulk.

This kit ships an **opt-in `vllm-l3` profile** that serves the same L3 model on
**vLLM**, whose continuous batching multiplies throughput on the same GPU. It is
**not the default** — it is native-Linux-GPU-only, WSL2-dead, and env-fragile.
**Ollama stays the kit default and the universal fallback.**

> **Measured win (2026-07-23, RTX 4090 24GB, native Linux, 40-chunk document,
> real L3 ensemble prompt):** L3 that takes **~240s (~4 min) sequentially drops
> to ~33s @ width-8 (7.4×) and ~18s @ width-16 (13×)**. Width-8 is the
> recommended operating point (max win with output matched to sequential). See
> the throughput benchmark findings for the full table.

---

## ⛔ Hard requirements (read before enabling)

- **Native-Linux GPU host, NVIDIA.** The host must have an NVIDIA GPU, a matched
  driver, and the **NVIDIA Container Toolkit** installed (so Docker can pass the
  GPU into the container via the `deploy.resources.reservations.devices` block).
- **⛔ WSL2 IS DEAD.** vLLM's V1 engine needs native-Linux CUDA UVA
  (unified virtual addressing). On WSL2 it fails at startup with:

  ```
  RuntimeError: UVA is not available
  ```

  There is no workaround. **Windows / WSL2 / CPU-only customers must use the
  Ollama L3 default** (leave `l3_runtime`/`l3_base_url` commented in
  `config/default-sanitizer.yaml` and do not add the `vllm-l3` profile).
  `bin/lucairn doctor` detects WSL2 and fails loud with this exact instruction.
- **CUDA ↔ driver match.** The pinned image ships CUDA-12.8 kernels. A
  **CUDA-13-capable driver runs the cu128 image fine** (CUDA is
  backward-compatible: a newer driver runs older-CUDA wheels). The failure mode
  is the reverse — a driver too old for the image's CUDA (e.g. a CUDA-12.0
  driver under a cu128 build) surfaces as `libcudart.so.NN not found` at boot.
- **VRAM sizing.** `Qwen2.5-7B-Instruct-AWQ` (4-bit AWQ quant) **fits a 24GB GPU
  (e.g. RTX 4090) with headroom** at `--gpu-memory-utilization 0.85` and
  `--max-model-len 8192`. Budget: ~6GB weights (AWQ) + KV cache scaled to the
  utilization fraction + activations. Smaller cards (<16GB) will not hold the
  8192 context comfortably — lower `--max-model-len` or use the Ollama path.

---

## Why the official Docker image (not `pip install vllm`)

`pip install vllm` on the demo host pulled a CUDA-13 build against a CUDA-12.8
driver → `libcudart.so.13 not found` plus a `transformers` break. The working
combination took three coordinated pins:

```
vllm==0.10.2  +  torch==2.8.0+cu128  +  transformers==4.55.4
```

The **official `vllm/vllm-openai` image bundles matched CUDA / torch / kernels**,
so productizing the runtime = a solved recipe, not per-customer version-hell.
The kit pins the image **by digest** (`image-manifest.yaml` → `pii_plane.vllm-l3`;
`VLLM_L3_IMAGE` in `customer.env.example`). The pip combo above is documented
only as a **fallback** for operators who must build the runtime themselves on a
native-Linux CUDA-12.8 host.

---

## What this runtime does NOT serve yet (be honest with the customer)

This runtime serves the **STOCK `Qwen2.5-7B-Instruct-AWQ`** (the AWQ equivalent
of the DSA-default `qwen2.5:7b`).

**It does NOT yet serve the custom-trained Enterprise "level-3 PII shield."**
That shield is real and **deliverable today on Ollama only** — it is a LoRA
fine-tune of Qwen2.5-7B, packaged as GGUF for Ollama. It is **not** vLLM-servable
as-is: an Ollama GGUF is not a vLLM artifact. Converting it (merge LoRA → HF →
AWQ/GPTQ quant, or vLLM native `--enable-lora`) plus **re-validating recall on
the quant** (AWQ ≠ GGUF Q4_K_M → detection must be re-checked) is a **filed
follow-up workstream**, not a shipped capability of this runtime.

Do not tell a customer the fast path serves their custom-trained shield. On this
runtime, the fast path serves the stock model; the custom shield stays on Ollama
until its conversion+recall workstream ships.

---

## Enabling the fast L3 path

Enabling has **two** parts — the runtime switch is **YAML config, not an env
var** (`l3_runtime`/`l3_base_url` are read only from
`config/default-sanitizer.yaml`; there is no `LUCAIRN_L3_RUNTIME`/
`LUCAIRN_L3_BASE_URL` env override):

**1. Add the profile** in `customer.env` (starts the runtime container):

```sh
COMPOSE_PROFILES=...,vllm-l3
```

**2. Uncomment BOTH lines** in `config/default-sanitizer.yaml`, in the
`llm_scan:` block right under `model: qwen2.5:7b` (points the sanitizer at the
vLLM backend):

```yaml
    l3_runtime: vllm
    l3_base_url: http://vllm-l3:8000
```

`vllm-l3` is the network alias of the `model-runtime-vllm-l3` service on the
**identity-only** net `dsa-model-runtime-identity` (internal:true, no egress).
It is a single-label (no-dot) name, so it classifies as **internal** — no
`l3_allow_external_base_url` opt-in is required.

**0. Pre-stage the model weights FIRST** — the `vllm-l3` service is on the
`internal: true` identity net (no container egress) and cannot pull from HF at
boot. See § "Pre-staging the model" below for the one-time ceremony that
populates `vllm-l3-model-store`. Skipping this = the profile never starts.

Then bring the stack up with the self-hosted overlay and run the preflight:

```sh
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  --env-file customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" --profile vllm-l3 \
  up -d
```

Verify the endpoint **after** it is up — from INSIDE the identity net, because
the service publishes no host port by design (`doctor` also prints this command):

```sh
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  --profile vllm-l3 \
  exec model-runtime-vllm-l3 curl -fsS http://localhost:8000/v1/models
```

### Split-knowledge isolation (do not break this)

`model-runtime-vllm-l3` is attached **only** to `dsa-model-runtime-identity` —
the same isolated identity bridge as `ollama-identity`, **never** the AI-plane
`dsa-model-runtime` net that sandbox-b and the AI-plane `model-runtime-vllm`
(`--profile vllm`) use. The L3 shield scans raw identity data; its runtime is
air-gapped from the AI plane. The AI-plane `vllm` profile and this `vllm-l3`
profile are **different trust planes** and must never share a network.

### Egress / trust-boundary guardrails (A-E2)

- `l3_base_url` (in `config/default-sanitizer.yaml`) must resolve to an
  **internal** address. A non-internal base_url fails the sanitizer's boot config
  check by default (opt-in override only). The `vllm-l3` alias is internal by
  construction, so the recommended value is compliant.
- The vLLM backend sends **no credential / no `Authorization` header**. Do not
  put userinfo (`http://user:secret@host`) in the URL.
- The sanitizer's `/v1/config` runs **unauthenticated by default (dev-open)** and
  its output includes `l3_base_url` (internal topology, non-secret — same
  disclosure class as the existing `ollama_url`). The kit does **not**
  auto-inject `DSA_ADMIN_KEY` on the sanitizer (that would flip an operator who
  already sets it elsewhere from unauthenticated → authenticated `/v1/config` on
  upgrade — a behavior change from a feature that must stay inert when off). If
  you want defense-in-depth you **may** set `DSA_ADMIN_KEY` on the sanitizer
  yourself, but the **primary control is the identity-plane network boundary**
  (`dsa-model-runtime-identity` is `internal: true`; NetworkPolicy/mTLS in Helm).
  See also `docs/CLEAN_HOST_REHEARSAL.md` for a fresh-host walk.

---

## Pre-staging the model (MANDATORY — mirrors `ollama-identity`)

**The model weights MUST be pre-staged before the `vllm-l3` profile can start —
on every host, not just air-gapped ones.** The `model-runtime-vllm-l3` service
runs on the identity net `dsa-model-runtime-identity`, which is `internal: true`
(split-knowledge isolation). An `internal: true` container has **no egress
regardless of whether the HOST has internet** — Docker isolates the container
network, so the host's connectivity is irrelevant. vLLM therefore **cannot**
pull the weights from Hugging Face at boot; it must read them from a pre-staged
cache. The service is configured with `HF_HUB_OFFLINE=1` +
`TRANSFORMERS_OFFLINE=1` and a mounted cache volume `vllm-l3-model-store` so it
loads locally and never dials HF. This is exactly the `ollama-identity` pattern
(which stages `qwen2.5:7b` into `ollama-identity-model-store` via a throwaway
egress-enabled `ollama pull`).

### One-time ceremony — populate `vllm-l3-model-store`

Run this ONCE on the host (before/without the `vllm-l3` profile), in a
**throwaway egress-enabled** container that writes into the same named volume the
isolated service mounts. It pulls the exact pinned revision into the HF cache:

```sh
# Pull Qwen2.5-7B-Instruct-AWQ @ the pinned revision into vllm-l3-model-store.
# --entrypoint is overridden to run huggingface-cli (the image bundles it).
docker run --rm \
  -e HF_HUB_ENABLE_HF_TRANSFER=0 \
  -v vllm-l3-model-store:/root/.cache/huggingface \
  --entrypoint huggingface-cli \
  vllm/vllm-openai:v0.10.2@sha256:607442e407b0fea97f8a132a78b787c121a996dd4de181fa08e8da06e71ec2db \
  download Qwen/Qwen2.5-7B-Instruct-AWQ \
    --revision b25037543e9394b818fdfca67ab2a00ecc7dd641
```

> The kit pins this volume's name to `vllm-l3-model-store` (an explicit, NOT
> project-prefixed `name:` in `docker-compose.self-hosted.yml` → `volumes:`), so
> the `docker run -v vllm-l3-model-store …` command above targets the exact volume
> vLLM mounts — no `<project>_` prefix to resolve. If your host itself is
> air-gapped, run the download on an internet-connected staging host and
> `docker volume` export/import the result, or vendor the weights into a
> bind-mount and point `--model` at the local path.

The pinned revision is recorded in `image-manifest.yaml`
(`pii_plane.qwen2.5-7b-awq-model.revision`). `bin/lucairn doctor` (B-E2) asserts
that this manifest `revision:` byte-equals the compose `--revision` on the
`model-runtime-vllm-l3` service — a **static compose↔manifest consistency
check** (the served revision itself cannot be probed: the endpoint is on the
internal net). A drift between the two host-side pins fails closed under
`doctor --strict`, so the runtime can never quietly load weights the recall gate
did not bless. Because the pre-stage ceremony pulls that same revision, the
staged cache matches what the service expects. (Guarding against a silent
*upstream* re-upload beyond the pinned commit is what pinning `--revision` to an
immutable HF commit sha does; doctor guards the two local pins stay in lockstep.)

---

## Failure modes and what catches them

| Failure mode | Caught by |
|---|---|
| No NVIDIA GPU on the host | `doctor` (nvidia-smi absent → fail loud) |
| WSL2 (UVA-dead) | `doctor` (greps /proc/version → fail loud) |
| Driver too old for the image's CUDA | `doctor` warns on low driver CUDA; boot fails `libcudart.so.NN not found` |
| `vllm-l3` endpoint unreachable after up | `docker compose ... exec model-runtime-vllm-l3 curl -fsS http://localhost:8000/v1/models` (no host port by design; `doctor` prints this command) |
| Image tag drift vs the pinned digest | `image-manifest.yaml` + `doctor --strict` |
| Compose `--revision` drifts from the manifest pin | `doctor --strict` B-E2 compose↔manifest revision consistency check (fail-closed) |
| Model weights re-uploaded upstream (beyond the pin) | `--revision` pinned to an immutable HF commit sha |
| Raw PII in vLLM container logs | `--disable-log-requests` (B-E1) + the log-grep acceptance probe |
| Split-knowledge break (shared net) | identity-net-only attachment; net-isolation assertion |

---

## Rollback to Ollama

Remove `vllm-l3` from `COMPOSE_PROFILES` and re-comment the `l3_runtime` /
`l3_base_url` lines in `config/default-sanitizer.yaml`, then recreate. The
sanitizer returns to the `ollama-identity` L3 path — the default is always
Ollama.
