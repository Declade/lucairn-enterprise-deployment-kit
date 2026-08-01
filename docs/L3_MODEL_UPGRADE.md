# Upgrading the L3 PII-shield model — sizing, artifacts, runbook (T-370)

> **Nothing in this document is enabled.** The kit's L3 model is and stays
> `qwen2.5:7b` on every lane and every install path. This document PREPARES a
> future model bump so that, once the gate in § 0 passes on *your* runtime's
> artifact, the change is a one-value flip plus the runtime prerequisites in
> § 1. It changes no default and turns nothing on.

PRD: `prd-2026-07-31-l3-rebuild-recoverable-truncation-gemma4.md` (Slice 3).
Board: T-370 (this document), T-391 (the fail-closed window during the pull).

Related operator docs: [`L3_VLLM_RUNTIME.md`](L3_VLLM_RUNTIME.md) (in-box fast
runtime), [`L3_SPLIT_POOL.md`](L3_SPLIT_POOL.md) (one shared GPU for several
gateway boxes).

---

## 0. The gate

**`gemma4:31b` requires the per-artifact recall gate (T-370 / PRD Slice 3) to
pass on YOUR runtime's artifact before flipping this value.**
**The 2026-07-31 validation covered the Ollama Q4_K_M lane at ceiling on a
saturated corpus — it is not transferable.**

Read "not transferable" literally:

- **Quantization format is part of the artifact.** `gemma4:31b` on Ollama is a
  Q4_K_M GGUF. A vLLM AWQ, W4A16 or FP8 build of the same upstream weights is a
  **different artifact** with different rounding behaviour. Recall numbers do
  not carry across formats.
- **Even the same format on different hardware/runtime builds is a re-run**, not
  an inherited pass. The validation lane was Ollama on one machine, not the
  customer box and not the kit's vLLM lane.
- **"At ceiling" is not "perfect."** The 2026-07-31 corpus is saturated: it can
  prove a regression, it cannot rank models. A clean run on it is a *floor*
  check, not a quality claim.

This gate is **documentation only**. Nothing in the kit enforces it — no
`bin/lucairn doctor` check, no chart validator, no CI job fails if an operator
sets `sanitizer.llmScanModel: gemma4:31b`. Treat § 1 as the checklist that
would otherwise have been a preflight. (Filed as a follow-up on T-370.)

No recall numbers appear in this document by design.

---

## 1. Kit-side prerequisites that are NOT satisfied today

Five things block the flip in the kit as shipped. Four are mechanical; the
fifth is the gate above.

### B1 — the pinned Ollama image cannot run the model *or* suppress reasoning

The kit pins `ollama/ollama:0.6.2` by tag **and** digest in both lanes:

- Helm: `charts/lucairn/charts/sandbox-a/values.yaml` → `ollamaIdentity.image.tag`
  / `.digest` (rendered at
  `charts/lucairn/charts/sandbox-a/templates/ollama-identity-statefulset.yaml:30`,
  and re-used as the model-pull CLI client at
  `charts/lucairn/charts/sandbox-a/templates/ollama-identity-model-job.yaml:101`)
- Compose: `docker-compose.self-hosted.yml` `ollama-identity.image`
  (`${OLLAMA_IMAGE:-ollama/ollama:0.6.2@sha256:74a0929e…}`)
- Release record: `image-manifest.yaml` → `pii_plane.ollama-identity`

Two independent problems with 0.6.2:

1. **Model support.** Gemma 4 support landed in Ollama **0.22.0** (April 2026);
   see <https://ollama.com/library/gemma4:31b>. `ollama pull gemma4:31b` against
   0.6.2 fails outright — which at least fails loudly, in the model-pull Job.
2. **Reasoning suppression — the silent one.** The sanitizer sends `think` as a
   **top-level** `/api/generate` key when the config resolves reasoning
   suppression on (DSA `services/sanitizer/llm_scan.py:1209-1240`, payload dict
   at `:1209`, `think` block immediately after `options` at `:1227`). Ollama's
   server is Go; `encoding/json` **silently drops unknown request fields**, so a
   build that predates the `think` API accepts the request, returns 200, and
   keeps reasoning. `gemma4` is a thinking model that returns EMPTY content
   while it reasons, which the verdict decoder refuses to read as "no PII
   found" → `malformed` → the sanitizer fail-closes. Net effect: **503 on 100%
   of L3 calls, with no error anywhere pointing at the version pin.** This is
   the "configured but unenforced" class (board T-297).

   The sanitizer resolves the flag automatically from the model name — the
   operator does **not** need to set it. `_L3_REASONING_DEFAULT_BY_MODEL`
   (`services/sanitizer/config.py:82-103`) maps the `gemma4` family → suppress,
   and `resolve_l3_reasoning_default` (`config.py:136-158`) is consulted only
   when `l3_reasoning_disabled` is unset (`config.py:1101`, applied at
   `config.py:1419-1420`). The family matcher normalises both the Ollama tag
   (`gemma4:31b`) and the HuggingFace id (`google/gemma-4-31B-it`)
   (`_l3_model_family_tokens`, `config.py:105-133`). So the *config* side is
   already correct; only the *runtime* is too old to honour the resulting wire
   field.

**Consequence:** bumping `llmScanModel` without bumping the Ollama image pin
(tag **and** digest, in the chart values, the compose default, **and**
`image-manifest.yaml`) produces a total, silent L3 outage. The image bump is
its own supply-chain change and its own review — it is deliberately not part of
this PR.

### B2 — the pinned vLLM image is too old for the model

The kit pins `vllm/vllm-openai:v0.10.2` by digest
(`docker-compose.self-hosted.yml` `model-runtime-vllm-l3.image`;
`image-manifest.yaml` → `pii_plane.vllm-l3`). The official vLLM recipe for this
model family requires **vLLM ≥ 0.19.1**
(<https://recipes.vllm.ai/Google/gemma-4-31B-it>), and the community AWQ build
states `vllm>=0.19.0`. The vLLM lane therefore needs its own image bump before
any artifact in § 3 can even load.

### B3 — the pinned sanitizer image predates the L3 rebuild

`image-manifest.yaml` pins `ghcr.io/declade/dsa-sanitizer:0.5.4`. The model
swap only makes sense on a sanitizer that carries PRD Slices 1-3: reasoning
control (S1), coverage-guaranteed bisection recovery (S2), and the paired
sizing + verdict-cache revision bump (S3). Those merged to DSA `main` on
2026-07-31; `0.5.4` predates them.

**Provenance caveat (honest statement):** the `0.5.4` tag's build commit is not
resolvable from the DSA repository, so "0.5.4 predates S1-S3" is an inference
from the merge dates, not a verified fact about that image. Do not treat it as
one. Confirm the sanitizer image actually carries S1-S3 before the flip — the
cheapest check is that its shipped `LlmScanConfig` exposes
`l3_reasoning_disabled` and `l3_chunk_overlap_chars`.

### B4 — the Ollama-lane storage is too small (Helm)

The identity-plane StatefulSet's volume claim is **10Gi**. The model is **20GB**
(<https://ollama.com/library/gemma4:31b>) = ~18.6 GiB, before the existing
`qwen2.5:7b` blob and Ollama's own scratch. The pull cannot succeed. Sizing in
§ 2.

### B5 — the recall gate itself

§ 0. Blocking regardless of B1-B4.

---

## 2. Sizing — the Ollama lane

All values below are **guidance for the gemma4 option**, not defaults. The
chart's shipped defaults are unchanged and sized for `qwen2.5:7b`.

| Knob | Shipped default (qwen2.5:7b) | Guidance for `gemma4:31b` | Where |
|---|---|---|---|
| Model store size (Helm) | `10Gi` | **`40Gi`** | `sandbox-a.ollamaIdentity.persistence.size` |
| Container memory limit (Helm) | `10Gi` | see § 2.3 — **UNMEASURED** | `sandbox-a.ollamaIdentity.resources.limits.memory` |
| Model-pull Job deadline | `3600` s | **`10800`** s on links below ~50 Mbit/s | `sandbox-a.sanitizer.llmScanModelPullDeadlineSeconds` |
| `l3_num_ctx` | `4096` | **`4096` — do not raise** | sanitizer config (§ 2.4) |
| Host disk (Compose) | ~5 GB for the model | **≥ 25 GB free** for model store alone | Docker volume `ollama-identity-model-store` |

### 2.1 Model store size

`charts/lucairn/charts/sandbox-a/templates/ollama-identity-statefulset.yaml`
declares one `volumeClaimTemplates` entry mounted at `/root/.ollama`. Its size
is now a chart value, `ollamaIdentity.persistence.size`, **defaulting to the
same `10Gi` the chart has always rendered** — the knob exists so the gemma4
option is reachable at all; it does not change what a stock install gets.

Why **40Gi** and not 20Gi:

- the model itself is ~18.6 GiB;
- during a rolling model change the **old blob is still present** (`ollama pull`
  adds; it does not evict), so peak occupancy is old + new — with the shipped
  `qwen2.5:7b` (~4.4 GiB) that is ~23 GiB;
- Ollama writes blobs through a temp path in the same filesystem, so the pull
  needs free space beyond the final size;
- a full PVC surfaces as a *failed pull*, not as a disk alert.

**⚠️ Resizing an existing install is not a `helm upgrade`.** `volumeClaimTemplates`
is immutable on an existing StatefulSet: changing the size renders a spec
Kubernetes rejects. On an install that already ran, either

- expand the PVC in place — only if the StorageClass sets
  `allowVolumeExpansion: true`: patch the PVC's
  `spec.resources.requests.storage`, then delete the StatefulSet with
  `--cascade=orphan` and re-run `helm upgrade` so the new template matches; or
- delete the StatefulSet (`--cascade=orphan`) **and** its PVC, then
  `helm upgrade` — this discards the staged model and forces a fresh pull.

Plan the storage size **before** first install if the gemma4 option is on the
roadmap.

### 2.2 GPU scheduling — absent from the chart (read before sizing memory)

`grep -rn "nvidia.com/gpu\|runtimeClassName" charts/lucairn/charts/sandbox-a/`
returns **nothing**. The chart requests no GPU and sets no runtime class, so on
a stock Kubernetes install `ollama-identity` runs **CPU-only** unless the
cluster imposes a GPU runtime by other means. On the CPU path the model's
weights are resident in **host RAM**, not VRAM.

This is survivable for a ~4.4 GiB model under a 10Gi limit. It is not
survivable for a ~18.6 GiB one: the container is OOMKilled during load,
`ollama list` stops answering, the readiness probe
(`ollama-identity-statefulset.yaml:65-69`) fails, and — with `global.l3Required:
true` — the sanitizer fail-closes on every request.

The compose lane is different: `model-runtime-vllm-l3` reserves an NVIDIA
device (`docker-compose.self-hosted.yml`, `deploy.resources.reservations.devices`),
but `ollama-identity` in compose reserves none either.

**Therefore: the gemma4 option on the Helm Ollama lane needs GPU scheduling
added to the chart first, or an explicitly CPU-sized memory limit.** Both are
out of scope here and neither is shipped.

### 2.3 Container memory

The current limit is `10Gi`
(`charts/lucairn/charts/sandbox-a/values.yaml`, rendered at
`ollama-identity-statefulset.yaml:78-80`). A 24GB-card-class deployment keeps
the weights in VRAM and needs far less host RAM than the CPU path — but **the
kit has no measured host-RAM figure for this model under Ollama, on either
path.** Stating one would be a guess.

What is safe to say:

- On the **GPU** path, host RAM is needed for blob read/verify and for Ollama's
  own working set, not for the full weights. The existing `10Gi` limit is a
  plausible starting point and must be **verified under load**, not assumed.
- On the **CPU** path (§ 2.2, i.e. the stock chart today), the limit must exceed
  the resident model size — so `10Gi` is definitively too small and ~24Gi+ is
  the starting point.
- Whichever path, record the measured peak in the gate evidence rather than
  copying a number from this table.

`ollamaIdentity.keepAlive` defaults to `-1` (weights pinned resident) so the
fail-closed block never fires from a cold-start hiccup. That makes peak
occupancy the *steady-state* occupancy — size for the peak.

### 2.4 `l3_num_ctx` stays 4096

The PRD pins `l3_num_ctx: 4096` and lists raising it as **out of scope**: VRAM
is the binding constraint on 24GB cards (23.0 / 24.0 GiB measured at 4096 —
PRD § Out of scope, § Implementation decisions). The upstream model advertises a
256K context; that is irrelevant here — the KV cache for it does not fit
alongside the weights on the target card.

The sizing triple is enforced in the sanitizer, not the kit: chunk **3000**
(`services/sanitizer/config.py:1003`), `num_predict` **2200**
(`services/sanitizer/llm_scan.py:236`), `l3_num_ctx` **4096**
(`config.py:1048`), with a boot-time fit guard that raises if the triple cannot
fit by construction (`config.py:1248-1265`). The kit does not set any of them —
`config/default-sanitizer.yaml`'s `llm_scan` block carries no `l3_chunk_chars`
/ `l3_num_ctx` key, so the sanitizer **image defaults** apply.

**Consequence worth stating plainly:** the kit inherits its L3 sizing from
whichever sanitizer image it pins. That is exactly why B3 matters — a gemma4
model bump on a pre-S3 sanitizer image pairs the new model with the old,
defective budget.

### 2.5 Model-pull deadline

The model-pull Job is bounded by `activeDeadlineSeconds`
(`ollama-identity-model-job.yaml:44`, value
`sanitizer.llmScanModelPullDeadlineSeconds`, default `3600`). Two facts make the
default marginal for a 20GB pull:

- the Job first waits up to **300 s** for `ollama-identity` to answer
  (`ollama-identity-model-job.yaml:119-128`, 150 iterations × 2 s), and that
  wait is inside the same deadline;
- `activeDeadlineSeconds` bounds the **whole Job**, across all `backoffLimit: 3`
  retries (`:31`) — a retry does not reset the clock.

So the transfer budget is `3600 − 300 = 3300 s`. A 20 GB pull inside 3300 s
needs a sustained **~48.5 Mbit/s** (20 GB = 160,000 Mbit; 160,000 / 3300 ≈ 48.5).

| Sustained link | 20 GB transfer | Fits `3600` (incl. 300 s wait)? |
|---|---|---|
| 1 Gbit/s | ~160 s | yes, comfortably |
| 100 Mbit/s | ~1,600 s | yes (~1,900 s of 3,600) |
| 50 Mbit/s | ~3,200 s | **marginal** (~3,500 s of 3,600) |
| 25 Mbit/s | ~6,400 s | **no — Job killed mid-pull** |

For reference, `qwen2.5:7b` (~4.7 GB) breaks even at ~11.4 Mbit/s, so the
gemma4 option raises the required sustained link by ~4.3×.

**Operator knob:** set
`sandbox-a.sanitizer.llmScanModelPullDeadlineSeconds: 10800` (3 h) alongside the
model bump on any link that cannot be *shown* to sustain ~50 Mbit/s. 10800 s
covers **~15.24 Mbit/s** — apply the same 300 s deduction the table above uses:
the transfer budget is 10800 − 300 = 10,500 s, and 160,000 / 10,500 ≈ 15.24. (A
14.8 Mbit/s link would need 10,811 s of transfer + 300 s of wait = 11,111 s and
the Job would be **killed** 311 s short. Deduct the wait, every time.) Raising
the value is free — the deadline exists to stop a *stalled*
pull hanging forever, not to enforce a service level.

Air-gapped installs are unaffected: with
`global.identityModelRegistryEgress: false` the Job is not rendered at all
(`ollama-identity-model-job.yaml:20`) and the model is pre-seeded into the PVC.
Pre-seeding a 20GB model still needs the § 2.1 storage size.

### 2.6 Compose lane

Compose uses a named Docker volume (`ollama-identity-model-store`) with no size
cap, so the constraint is **host disk**. `docs/CUSTOMER_INSTALL_RUNBOOK.md:33`
quotes 50 GB free for the pilot topology with L3 **off**; the gemma4 option
consumes ~20 GB of that for the model store alone, ~25 GB during a changeover
while the old blob is still staged. Re-check headroom before staging.

The compose identity net is `internal: true`, so `ollama-identity` cannot pull
anything itself — the model is staged via the one-time throwaway egress-enabled
Ollama documented in `INSTALL.md` § "Pre-stage the L3 deep PII-shield model".
That throwaway container must also be ≥ 0.22.0 (B1) for a gemma4 pull.

---

## 3. vLLM-lane artifact candidates (researched 2026-08-01)

The PRD leaves the vLLM-lane quantization as an implementation decision: pick an
available quantized `google/gemma-4-31B-it` build and re-run the recall gate on
**that** artifact. This section records what exists. **None of these is pinned,
recommended, or gated.** They are candidates for the gate in § 0.

Target envelope: a single **24 GB** card, `l3_num_ctx` 4096, served by vLLM.

| Candidate | Format | Size (as published) | 24 GB card? | Notes |
|---|---|---|---|---|
| [`google/gemma-4-31B-it-qat-w4a16-ct`](https://huggingface.co/google/gemma-4-31B-it-qat-w4a16-ct) | W4A16, compressed-tensors, **QAT** | not stated on the card — **UNMEASURED** | **plausible, unverified** | First-party Google checkpoint, Apache-2.0, described as serialized for native vLLM inference. QAT rather than post-training quantization. Highest-provenance candidate. |
| [`QuantTrio/gemma-4-31B-it-AWQ`](https://huggingface.co/QuantTrio/gemma-4-31B-it-AWQ) | AWQ 4-bit | **20 GiB** (card) | **marginal** | Apache-2.0. Card states `vllm>=0.19.0`; its own example runs `--tensor-parallel-size 2`. At 20 GiB of weights, a 24 GB card leaves ~3-4 GiB for KV + activations. Third-party. |
| [`unsloth/gemma-4-31B-it-qat-w4a16`](https://huggingface.co/unsloth/gemma-4-31B-it-qat-w4a16) | W4A16, QAT | not verified | plausible, unverified | Third-party repack of the Google QAT checkpoint. |
| [`RedHatAI/gemma-4-31B-it-FP8-Dynamic`](https://huggingface.co/RedHatAI/gemma-4-31B-it-FP8-Dynamic) / [`-FP8-block`](https://huggingface.co/RedHatAI/gemma-4-31B-it-FP8-block) | FP8 (E4M3) | ~50 % of BF16 per the cards | **no** | Recommended by the official vLLM recipe, but at ~1 byte/param over ~30.7 B params the weights alone are ~30 GB — Hopper/Blackwell multi-GPU territory, not a 24 GB card. |
| [`nvidia/Gemma-4-31B-IT-NVFP4`](https://huggingface.co/nvidia/Gemma-4-31B-IT-NVFP4) | NVFP4 4-bit | not verified | **hardware-gated** | Also recommended by the official recipe, but the recipe states Blackwell (B200/B300) is **required**. Rules out Ada-generation 24 GB cards (e.g. RTX 4090). |
| [`amd/gemma-4-31B-it-MXFP4`](https://huggingface.co/amd/gemma-4-31B-it-MXFP4), `mlx-community/*` | MXFP4 / MLX | — | **n/a** | Wrong hardware family for this lane (AMD / Apple Silicon). |
| `bartowski/…-GGUF`, `unsloth/…-GGUF`, `ggml-org/…-GGUF`, `lmstudio-community/…-GGUF` | GGUF | — | **n/a for vLLM** | GGUF is the Ollama/llama.cpp lane, i.e. § 2, not this one. |

**The finding, stated plainly:** for a single 24 GB card there is exactly one
viable class — **4-bit W4A16/AWQ** — and it is **marginal**, not comfortable.
The two builds the official vLLM recipe actually recommends (FP8-dynamic,
NVFP4) are both unusable here: FP8 does not fit 24 GB, and NVFP4 requires
Blackwell. A ~20 GiB weight footprint on a 24 GB card leaves single-digit GiB
for KV cache and activations; whether that is workable at
`--max-model-len 4096` with `--gpu-memory-utilization` in the 0.85-0.92 range
is **UNMEASURED** and is part of the gate, not an assumption.

If the recall gate fails on every 4-bit build, the honest outcomes are: raise
the card class (32 GB+), move the vLLM lane to the split L3 pool
([`L3_SPLIT_POOL.md`](L3_SPLIT_POOL.md)) where one bigger GPU serves several
boxes, or keep the vLLM lane on its current model. "Ship it anyway on a
marginal fit" is not on the list.

### What a vLLM-lane bump would touch

Recorded so the change set is not rediscovered later. **Do not apply any of
this now.**

- `docker-compose.self-hosted.yml`, `model-runtime-vllm-l3`: `--model`,
  `--served-model-name` (must keep serving the *name the sanitizer config
  sends*, or every call 404s), `--revision`, `--quantization`, `--dtype`,
  `--max-model-len`, `--gpu-memory-utilization`, and the vLLM image pin (B2).
- `image-manifest.yaml` → `pii_plane`: the vLLM image digest, plus a model
  entry whose `revision:` must byte-equal the compose `--revision`.
  `bin/lucairn doctor --strict` compares the two (check B-E2, implemented at
  `bin/lucairn:1937-1980`).

  **⚠️ That check does NOT survive renaming the manifest entry.** Its extractor
  anchors on the **literal entry name** `qwen2.5-7b-awq-model:`
  (`bin/lucairn:1962`). Rename that key as part of a model bump — the obvious
  thing to do — and the extraction returns empty, which the check reports as a
  **warn and returns 0, even under `--strict`**. So it is *not* a fail-closed
  backstop for a one-sided bump; it silently stops checking.

  **The manifest key name is load-bearing.** Either keep the existing
  `qwen2.5-7b-awq-model:` key when swapping the artifact underneath it, or
  update the anchor at `bin/lucairn:1962` **in the same change** as the rename.
  Doing neither loses the only compose↔manifest revision check without any
  signal. (Not fixed here — this document is docs-only; filed as a follow-up on
  T-370.)
- The AWQ builds' cards pin an exact HF commit; pin the **gated** revision, not
  a branch.

---

## 4. Upgrade runbook — bumping the L3 model

Post-#104 procedure. It applies to *any* L3 model change; the gemma4 option
additionally requires everything in § 1.

### 4.1 Before you start

1. § 0 gate passed **on the artifact this deployment will serve**, evidence
   recorded.
2. § 1 B1-B4 resolved for the lane in question (Ollama image ≥ 0.22.0 / vLLM
   image ≥ 0.19.1, sanitizer image carrying S1-S3, storage sized).
3. Storage headroom checked for **old + new** blobs (§ 2.1 / § 2.6).
4. A maintenance window agreed — § 4.3 is a *visible outage* with
   `l3Required: true`.
5. Rollback value written down (§ 4.6).

### 4.2 Helm — what `helm upgrade` actually does

The model-pull Job is named `ollama-identity-model-pull-r{{ .Release.Revision }}`
(`ollama-identity-model-job.yaml:25`). Every `helm upgrade` increments the
release revision, so each upgrade creates a **new** Job that re-runs
`ollama pull` for whatever `sanitizer.llmScanModel` now says
(`:129-130`). That is deliberate: a fixed-name Job would be rejected as
immutable and the chart could claim a new model while the cluster kept serving
the old one.

```
helm upgrade lucairn charts/lucairn \
  --set sandbox-a.sanitizer.llmScanModel=<new-model> \
  --set sandbox-a.sanitizer.llmScanModelPullDeadlineSeconds=10800 \
  --set sandbox-a.ollamaIdentity.persistence.size=40Gi \
  ... (your existing values)
```

**Air-gapped installs (`global.identityModelRegistryEgress: false`) have no
pull Job at all** — it is not rendered (`ollama-identity-model-job.yaml:20`), so
`helm upgrade` flips the ConfigMap to the new model name and **nothing ever
fetches it**. The window in § 4.3 is then unbounded until a human pre-seeds the
PVC. Pre-seed *before* the upgrade on that path; it is not optional sequencing,
it is the only sequencing that terminates.

The L3 shield itself is enabled by a **pair** of values that the umbrella
validator requires to move together: `sandbox-a.sanitizer.llmScanEnabled=true`
**and** `global.llmShieldEnabled=true` (sub-charts cannot read each other's
values, so the enable state is mirrored into `global` for the NetworkPolicies
that let the model-pull Job reach the registry). Setting only the first fails
the render with an explicit message — it does not deploy a shield that can
never load a model. `values-test.yaml` sets both.

`persistence.size` only takes effect on a **fresh** StatefulSet — see the
immutability warning in § 2.1. Size it at install time or do the orphan-delete
dance before this upgrade, not during it.

The same value drives two objects that must agree: the pull Job (`:129-130`)
and the sanitizer's config (`sanitizer-configmap.yaml:119`,
`llm_scan.model`). They read the same key, so they cannot drift — but that is
also precisely what creates the window in § 4.3.

### 4.3 ⚠️ The fail-closed window during the pull (T-391)

**`helm upgrade` rolls the sanitizer's ConfigMap to the new model name
immediately, while the multi-GB `ollama pull` is still running.** For the whole
duration of that pull:

- the sanitizer asks `ollama-identity` for a model that is **not staged yet**;
- Ollama answers **404 model not found**;
- the sanitizer's L3 path treats that as unavailable;
- with `global.l3Required: true` (fail-closed, the recommended posture) the
  gateway returns **503 on every request**;
- with `global.l3Required: false` requests continue on L1+L2 and every
  certificate minted in the window is honestly downgraded (`llm_pii_scan`
  dropped from `layers_active`).

Neither is data loss; both are visible. **Expected duration = the pull time**:

| Path | Window duration | Symptom |
|---|---|---|
| Egress-enabled, 1 Gbit/s | ~160 s | 503s (or downgraded certs) for that long |
| Egress-enabled, 100 Mbit/s | ~27 min | as above |
| Egress-enabled, < ~48 Mbit/s | longer than the Job's own deadline — the Job is **killed**, the model never lands, and the window does not end on its own | as above, until the deadline is raised and the upgrade re-run |
| **Air-gapped** (`identityModelRegistryEgress: false`) | **unbounded — until a human pre-seeds the PVC** | **hard 503 on every request**, never a downgrade |

The air-gap row is the sharp one, and it is sharper than it looks. On that path
the pull Job is not rendered at all
(`ollama-identity-model-job.yaml:20`), so nothing fetches the new model — and
`validators.l3AirGapWithoutFailClosed`
(`charts/lucairn/templates/_validators.tpl:855-870`, invoked from
`validators.yaml:25`) **refuses to render** the air-gap path unless
`global.l3Required=true`. That guard is correct and deliberate — it exists so a
missed pre-seed cannot silently run shield-less — but it means the air-gap
upgrade window is **always** the hard-503 variant. Mitigation 3 below (flip
`l3Required` false for the window) is **not available** there: the render fails.
Pre-staging is the only option on the air-gap path.

Mitigations, in order of preference:

1. **Pre-stage the model before the upgrade.** Run `ollama pull <new-model>`
   against the *running* `ollama-identity` (`kubectl exec` into the pod, or in
   compose the throwaway egress-enabled container) **before** touching
   `llmScanModel`. Ollama serves the old model throughout; when the new blob is
   staged the `helm upgrade` flips the name onto an already-present model and
   the window collapses to the next request. **This is the recommended path for
   any production install.**
2. Schedule the upgrade inside an agreed maintenance window and accept the 503s.
3. Temporarily set `global.l3Required: false` for the window — this trades a
   hard outage for honestly-downgraded certificates. It is a **deliberate
   posture change**: it must be agreed with the customer, and flipped back
   immediately afterwards. **Unavailable on the air-gapped path** — the
   umbrella validator fails the render for that combination (see above).

### 4.4 Verifying the pull completed

```
# Job finished successfully (revision N = the release revision you just created)
kubectl -n dsa-identity get job ollama-identity-model-pull-rN
kubectl -n dsa-identity logs job/ollama-identity-model-pull-rN     # ends with "Model pull complete." then `ollama list`

# The model is actually resident
kubectl -n dsa-identity exec statefulset/ollama-identity -- ollama list

# The sanitizer agrees with the pull Job (both read sanitizer.llmScanModel)
kubectl -n dsa-identity get cm -o yaml | grep -A2 'llm_scan:'

# End-to-end: L3 answers instead of fail-closing
kubectl -n dsa-identity exec deploy/sandbox-a -c sanitizer -- \
  wget -qO- http://127.0.0.1:8086/readyz
```

Compose equivalents: `docker compose exec ollama-identity ollama list`, and the
sanitizer's `/readyz`.

A green `/readyz` with `l3Required: true` is the load-bearing check — it is what
was failing during § 4.3's window.

### 4.5 Cleaning up the old blob

`ollama pull` **adds**; nothing evicts the previous model. After the new model
is verified resident and serving:

```
kubectl -n dsa-identity exec statefulset/ollama-identity -- ollama rm qwen2.5:7b
# compose:
docker compose exec ollama-identity ollama rm qwen2.5:7b
```

**Do not run this until § 4.4 is green.** The old blob is the rollback path
(§ 4.6) and removing it early converts a 30-second rollback into another
multi-GB pull — during an incident.

Keep the old blob for at least one full business cycle after the change. Only
then reclaim the space; and if PVC headroom is what forces an early cleanup,
that is a signal § 2.1 was undersized, not a reason to skip the safety margin.

The pull Job is **not** deleted automatically — the revision suffix means old
Jobs accumulate. `kubectl -n dsa-identity delete job -l app.kubernetes.io/name=ollama-identity-model-pull`
removes completed ones; it deletes no model data.

### 4.6 Rollback

Flip the value back and upgrade:

```
helm upgrade lucairn charts/lucairn \
  --set sandbox-a.sanitizer.llmScanModel=qwen2.5:7b \
  ... (your existing values)
```

If § 4.5 was **not** run, the old blob is still on the PVC: the new revision's
pull Job finds it already present, returns immediately, and the sanitizer's
ConfigMap flips back to a model that is resident — **no § 4.3 window on the way
back**. That asymmetry is the whole reason the cleanup step is last and gated.

If § 4.5 **was** run, rollback re-pulls the old model and re-opens the § 4.3
window for its duration (~4.7 GB for `qwen2.5:7b`).

Compose rollback: edit `llm_scan.model` in `config/default-sanitizer.yaml` back
to `qwen2.5:7b` and restart the sanitizer.

Rolling back the **sanitizer image** (B3) is a separate decision from rolling
back the **model**, and the two are not independent: an older sanitizer image
carries older sizing defaults (§ 2.4). Roll back the pair, or neither.

---

## 5. Model licence

Gemma 4 is published under Apache-2.0 on the model cards cited in § 3.

**Re-confirm <https://ai.google.dev/gemma/terms> before any customer ship.**
This is a PRD locked constraint, not boilerplate: the licence terms for this
model family were changed once already (findings 2026-07-29), so a licence
verdict recorded on one date is not evidence about a later one. Re-read the
terms page as part of the ship checklist and record the date it was read.

**Trademark — naming rule (PRD locked constraint, Gemma terms § 6).** Do not
brand any Lucairn feature, tier, page, or product surface with the upstream
model name. The L3 shield is "the L3 deep PII shield" regardless of which
weights back it. Using the model identifier as a **configuration value**
(`llmScanModel: gemma4:31b`, an HF repo id in a compose `--model` flag) is
fine — that is a technical reference, not branding. Customer-facing copy names
the capability, never the model.

The sales-language lock is unchanged and independent of this document: the
stock L3 shield is not the Enterprise-only custom-trained PII shield, whichever
model backs it.

---

## 6. Citation basis

Kit line numbers are against this repository at the commit that introduced this
document. Sanitizer (`services/sanitizer/**`) line numbers are against
`dual-sandbox-architecture` `origin/main` @ `b9b6ccdbd`, re-grepped 2026-08-01;
they move on every sanitizer merge, so re-derive rather than trusting them if a
citation does not resolve.

**⚑ SAME-REPO citations rot from the very commit that writes them.** This is
not a cross-repo hazard only. Measured twice on this change set: (1) the ten
`llm_scan.py:*` references PR #104 shipped had already drifted by the time
T-370 read them; (2) eight of the kit-local citations *in this document and in
the Job template* were invalidated by **this PR's own comment insertions** —
adding a 6-line comment above `activeDeadlineSeconds` moved it 37 → 44 and
pushed every line below it down, including citations written minutes earlier in
the same editing session. Three of those eight were not caught by review and
turned up only on re-derivation.

Practical rule: after any edit that inserts lines, **re-grep every citation
into the edited file, including your own** — write the citation last, or verify
it last. A citation is a claim about the current tree, and inserting a comment
is enough to falsify it.
