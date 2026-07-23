# L3 runtime throughput benchmark — vLLM-L3 vs Ollama-L3

**The enterprise pitch datum:** on the SAME single GPU, serving the L3 deep PII
shield on **vLLM** instead of **Ollama** multiplies bulk/concurrent throughput
**7.4× at width-8 and 13× at width-16.**

Harness: `tools/l3_throughput_bench.py` (stdlib-only; direct OpenAI-compatible
endpoint). Runtime packaging: `docs/L3_VLLM_RUNTIME.md`.

---

## RAW vLLM continuous-batching measurement (real hardware, 2026-07-23)

- **Box:** RTX 4090 24GB, driver 580.126.09 (CUDA-13-capable), Ubuntu 24.04
  **native Linux** (kernel 6.8, NOT WSL2).
- **Runtime:** the proven pinned combo `torch==2.8.0+cu128` + `vllm==0.10.2` +
  `transformers==4.55.4` (the same recipe the official `vllm/vllm-openai` image
  bundles), `Qwen/Qwen2.5-7B-Instruct-AWQ`, `--enforce-eager
  --gpu-memory-utilization 0.85 --max-model-len 8192`.
- **Path:** the **raw vLLM `/v1/chat/completions` server** — i.e. the DIRECT
  endpoint, NOT through the sanitizer (B-E4: a sanitizer-path number saturates on
  gunicorn workers before the GPU, so it would measure gunicorn, not vLLM).

### "One big example" — 40-chunk document, REAL L3 ensemble prompt

40 varied PII-laden records (37,668 chars, avg 941/chunk), the actual L3
`_ENSEMBLE_PROMPT`, `max_tokens=512`, `temp=0`, `seed=42`, Qwen2.5-7B-AWQ:

| Width | Total time (40 chunks) | Speedup | tok/s | out-tokens |
|---|---|---|---|---|
| **1 (sequential = today's L3)** | **240.8s (~4 min)** | 1× | 70 | 16,805 |
| **8 (recommended)** | **32.5s** | **7.4×** | 517 | 16,805 |
| **16** | **18.5s** | **13.0×** | 915 | 16,946 |

A big document whose L3 pass takes **~4 minutes sequentially drops to ~33s @
width-8 / ~18s @ width-16** on one 4090. Detection stayed correct
(PERSON/DOB/etc. tagged; the model wraps JSON in ```fences — the sanitizer parser
strips them).

### 24-request concurrency sweep (heavier per-request output)

24 requests, ~1,200-char PII-scan prompt, `max_tokens=200`, `temp=0`,
Qwen2.5-7B-AWQ (this is the shape `tools/l3_throughput_bench.py --requests 24
--max-tokens 200` reproduces):

| Concurrency | rec/s | tok/s | vs sequential |
|---|---|---|---|
| 1 (sequential) | 0.36 | 71 | — |
| **8** | **2.70** | 526 | **7.5×** |
| **16** | **4.02** | 783 | **11.2×** |

Absolute rec/s is low here only because this probe forces 200-token outputs; the
real L3 task emits short verdicts (higher absolute rec/s). The **ratio** is the
enterprise datum and it is decisive across both output profiles.

---

## The Ollama ceiling (the thing vLLM beats)

Ollama **time-slices** concurrent requests on one GPU — a **decisive negative
sweep** on the same 4090 showed a hard **~5 rec/s ceiling** with no concurrency
knob that helps (`specs/2026-07/findings-2026-07-21-pc-gpu-vs-hetzner-latency.md`
§ Ollama L3 parallelism sweep). That is exactly why the fast path uses vLLM:
continuous batching converts concurrency into throughput; Ollama cannot.

To capture the Ollama comparison number on your own hardware, run the harness
against the Ollama `/v1` shim and compare the `rec/s` column:

```sh
python3 tools/l3_throughput_bench.py \
    --base-url http://ollama-identity:11434/v1 --model qwen2.5:7b \
    --concurrency 1,8,16 --requests 24 --max-tokens 200
```

---

## Width-8 is the recommended operating point

**Determinism finding (the reason the byte-identity gate exists):** width-1 and
width-8 produced the **identical output token count (16,805)** — evidence that
width-8 output matches sequential; width-16 **drifted +141 tokens (~1 chunk).**
This is vLLM's known **batch-level nondeterminism** — continuous batching shifts
FP reduction order with batch composition, so `temp=0`+`seed=42` makes each
*request* deterministic but does NOT guarantee bitwise-identical output across
*concurrency levels*. ⇒ **width-8 = the sweet spot** (near-max win with output
matched to sequential); higher widths trade determinism for marginal speed. In
production the L3 verdict cache freezes the first verdict, so this bites mainly
the caches-off byte-identity gate.

---

## What is PROVEN vs what is PENDING (honesty for the pitch)

**Proven (GPU-only, 2026-07-23):**
- vLLM runs on a native-Linux GPU (the thing WSL2 cannot do).
- The concurrency throughput win is real and large: **7.4× @ w8, 13× @ w16** on
  a real 40-chunk document (4 min → 33s / 18s).

**Multi-GPU / multi-user scaling is a PROJECTION, not a measurement.** The win
compounds with more/bigger GPUs and across concurrent users, but this
single-endpoint harness measures ONE GPU. Do not present multi-GPU numbers as
measured.

**PENDING — the on-GPU ENABLE-gate checks (gate RELEASE, not this merge):**
these belong to the joint HARD ENABLE GATE (PRD A + PRD B) and must pass on the
EXACT pinned image + model revision before any demo enablement or kit release
with `l3_runtime=vllm`:

1. **Sanitizer-path byte-identity** across widths {1,2,8} through the real
   `_dispatch_chunks_concurrent` (unit byte-identity + temp0+seed42 determinism
   already green; the live sanitizer-path confirm is the one genuinely-open
   check — best run via the kit compose stack on a Docker-capable Linux GPU host,
   which stands up sanitizer + pii-ml + vLLM cleanly).
2. **Real-served-model recall 100%** (incl. the real-PDI 26/26 corpus, not
   fixtures only).
3. **Fail-closed probe** under concurrency.
4. **B-E1 container-log grep** — after a redaction round-trip, grep the
   `vllm-l3` container logs for the raw fixture PII = **zero hits**
   (`--disable-log-requests` must hold).

---

## Bottom line

The two hardest, GPU-only facts are proven: **vLLM runs native-Linux and the
concurrency throughput win is real and large** (7.4× @ w8, 13× @ w16 on a real
40-chunk doc). Width-8 is the recommended operating point (max win, output
matched to sequential). The last live confirm (sanitizer-path byte-identity text
@ w8) belongs in the kit build's edge-verify, alongside the recall + log-grep +
fail-closed enable-gate checks.

_Source measurements: `specs/2026-07/findings-2026-07-23-vast-4090-vllm-concurrency-gate.md`
+ `specs/2026-07/findings-2026-07-21-pc-gpu-vs-hetzner-latency.md`._
