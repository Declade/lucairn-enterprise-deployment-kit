# Split L3 pool — one shared GPU for several gateway boxes

The level-3 deep PII shield needs a GPU. The kit's two in-box lanes put that GPU
**in every box**: `ollama-identity` (the default) or the opt-in `vllm-l3` profile
(`docs/L3_VLLM_RUNTIME.md`). If you run **several gateway boxes**, that means
several GPUs.

The **split L3 pool** is a third arrangement of the *same* vLLM lane: the boxes
stay small and GPU-less, and **one** vLLM host — the *pool* — serves L3 for all
of them over **your private network**. vLLM's continuous batching is what makes
one GPU serve many callers; that is the same property the in-box `vllm-l3`
profile exists for (`docs/L3_VLLM_RUNTIME.md`).

**This is a configuration option, not a new component.** The kit ships **no
compose service for the pool** — the pool is a host you operate. Nothing in the
kit deploys, starts, or updates it.

```
        your private network (e.g. Hetzner vSwitch, RFC1918 only)
                                  │
   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
   │ gateway box1 │   │ gateway box2 │   │ gateway box3 │      (no GPU)
   │  sanitizer   │   │  sanitizer   │   │  sanitizer   │
   └──────┬───────┘   └──────┬───────┘   └──────┬───────┘
          └──────────────────┼──────────────────┘
                             ▼
                   ┌─────────────────────┐
                   │  L3 pool host       │   ONE GPU, vLLM, OpenAI-compatible
                   │  10.0.0.10:8000     │   bound to the private interface only
                   └─────────────────────┘
```

---

## When to use it (and when not)

| Situation | Use |
|---|---|
| One box, one GPU | in-box `ollama-identity` (default) or `vllm-l3` profile |
| Several boxes, one GPU budget, private network between them | **split pool (this page)** |
| Boxes on different networks / no private link between them | **not this** — keep L3 in-box |
| Windows / WSL2 / CPU-only boxes, GPU host available on the private net | **split pool** — the WSL2/GPU constraints move to the pool host |

The split pool does **not** change the model, the redaction behaviour, the
certificate contents, or any Enterprise claim. It changes **where the L3 process
runs**.

---

## ⛔ Hard requirements

- **Private network only.** `l3_base_url` must be an RFC1918 address
  (`10.x` / `172.16-31.x` / `192.168.x`), an IPv6 ULA (`fd00::/8`), or a
  private-DNS name. A public FQDN/IP is **blocked by the sanitizer at boot**
  (`dual-sandbox-architecture services/sanitizer/config.py:1507-1533`) and
  **failed by `bin/lucairn doctor`** (`bin/lucairn:1573-1584`).
- **The pool binds on the private interface and publishes NO public port.** The
  endpoint is unauthenticated by construction — see *Data flow* below.
- **The pool is inside the customer environment.** This option does not send
  anything to Lucairn or to any third party; there is no hosted pool.
- **The pool host owns the GPU requirements.** Native-Linux NVIDIA GPU, matched
  driver, NVIDIA Container Toolkit; WSL2 is dead for vLLM's V1 engine. Those
  constraints are unchanged — they just apply to the pool host now, not to every
  gateway box. See `docs/L3_VLLM_RUNTIME.md` § *Hard requirements*.
- **The pool serves the model the recall gate blessed.** The kit's in-box vLLM
  service pins `--served-model-name qwen2.5:7b` + `Qwen/Qwen2.5-7B-Instruct-AWQ`
  at a fixed `--revision` (`docker-compose.self-hosted.yml:603-612`). A pool
  serving a different model or quantization is a different artifact and needs
  its own recall evidence.
- **Run the pool with request-content logging OFF.** The kit's in-box service
  passes `--disable-log-requests` (`docker-compose.self-hosted.yml:622-628`)
  precisely so PII does not land in container logs. Your pool must do the same —
  the kit cannot enforce it on a host it does not deploy.

---

## Configure it

### 1. Sanitizer YAML — the runtime switch

`config/default-sanitizer.yaml`, in the `llm_scan:` block
(`config/default-sanitizer.yaml:104-129`):

```yaml
  llm_scan:
    enabled: true
    ollama_url: http://ollama:11434
    model: qwen2.5:7b
    l3_runtime: vllm
    l3_base_url: http://10.0.0.10:8000      # your pool's PRIVATE address
```

`l3_runtime` / `l3_base_url` are **YAML-only** fields. There is no
`LUCAIRN_L3_RUNTIME` / `LUCAIRN_L3_BASE_URL` env override — the compose overlay
says so at `docker-compose.self-hosted.yml:154-162`.

### 2. `customer.env` — declare the topology for `doctor`

```sh
LUCAIRN_L3_SPLIT_POOL=true
```

**No service reads this variable.** It is read by `bin/lucairn doctor` only
(`bin/lucairn:710-719`). It exists because, from configuration alone, a
split-pool box (`l3_runtime: vllm`, no `vllm-l3` profile) is **indistinguishable**
from the broken half-enabled in-box box (`l3_runtime: vllm`, profile forgotten →
the sanitizer dials a compose alias that was never started → fail-closed 503 on
every request). Doctor must keep failing the second one, so the first one
declares itself. A typo'd value is a hard doctor failure, never a silent skip
(`bin/lucairn:710-719`, `bin/lucairn:1651-1656`).

### 3. `COMPOSE_PROFILES` — do **not** add `vllm-l3`

There is no local vLLM container on a pool client. If the profile is active
anyway, doctor warns (`bin/lucairn:1587-1589`): the local
`model-runtime-vllm-l3` service would start, demand a GPU this box may not have,
and sit unused while the sanitizer dials the pool.

### 4. The pool host

Out of kit scope — you run an OpenAI-compatible vLLM server yourself. Use the
kit's in-box service as the reference argument set
(`docker-compose.self-hosted.yml:572-632`), bind it to the private interface,
and keep `--disable-log-requests`.

---

## Data flow — what actually crosses the private network

**Sequential mode (`mode: sequential`, the kit default —
`config/default-sanitizer.yaml:150`):** the text handed to L3 is the output of L1 and
L2 — `llm_scanner.scan(presidio_result.text, …)`
(`dual-sandbox-architecture services/sanitizer/app.py:5924-5927`), where
`presidio_result` is the L2 pass over the L1-redacted text (`app.py:5904-5908`).

**Ensemble mode (`mode: ensemble`, an explicit Pro/Enterprise opt-in):** L2 and
L3 run in parallel over the **L1-redacted** text — `scan_raw, l1_text`
(`app.py:5583-5586`). L2's redactions have not been applied yet on that path.

So what transits to the pool is the request text **after** the earlier layers
plus the L3 prompt around it.

> **Be precise about what that means.** The residual is **not** PII-free — the
> entire purpose of L3 is to catch identifiers L1 and L2 missed, so by
> construction the text sent to the pool can still contain them. That is why
> this option is **private-network-only** and why the sanitizer blocks a
> non-internal `l3_base_url` at boot
> (`services/sanitizer/config.py:1507-1533`).

Also crossing: **nothing else.** The vLLM L3 backend sends **no
`Authorization` header and takes no api-key argument** — the backend has no
credential surface at all (`services/sanitizer/llm_scan.py:400-412`), and a
`user:pass@` URL is rejected outright
(`services/sanitizer/llm_scan.py:495-510`, doctor mirror at
`bin/lucairn:1541-1549`).

Not crossing: certificates, the pseudonym registry, audit records, and the
witness chain. Those stay on the gateway box exactly as before — this option
touches only the L3 model call.

**The pool is inside the customer environment.** Enterprise self-hosted
positioning is unchanged by this option: the pool is one more host on the
customer's own private network, operated by the customer.

---

## Why an RFC1918 address is accepted

The sanitizer classifies `l3_base_url` with an **allowlist**,
`_is_internal_l3_base_url`
(`dual-sandbox-architecture services/sanitizer/llm_scan.py:431-492`):

- an **IP literal** is internal **iff** it is loopback, RFC1918/RFC4193 private,
  or the unspecified address — and **never** link-local, so the cloud metadata
  endpoint `169.254.169.254` is excluded (`llm_scan.py:484-492`);
- a **hostname** is internal iff it is single-label (no dot) or ends with
  `.internal` / `.svc` / `.local` / `.cluster.local` / `.svc.cluster.local`
  (`llm_scan.py:415-428`, `:476-483`).

A pool at `10.0.0.10` takes the IP branch and is **internal** → the split option
needs **no** `l3_allow_external_base_url` opt-in. That opt-in (which permits a
non-internal endpoint over HTTPS with a loud audit log,
`services/sanitizer/config.py:1519-1554`) is **not part of this option** and
doctor fails a non-internal host regardless.

`bin/lucairn doctor` mirrors that classifier host-side in `_l3_host_is_internal`
(`bin/lucairn:651-694`). The mirror is deliberately a **subset**: every address
doctor calls internal is also internal to the sanitizer, but not the reverse — so
doctor can never green-light a `base_url` the sanitizer would block at boot.
Verified 2026-08-01 by running the sanitizer's own function over the exact case
list pinned in `tests/test_l3_split_pool_preflight.sh`.

> The pre-2026-08 doctor classifier was a glob list
> (`10.*|192.168.*|172.1[6-9].*|…`). Globs match **hostnames** too, so
> `http://10.evil.com:8000` passed doctor and was then blocked by the sanitizer
> at boot; and the host extraction truncated at the first `:`, mangling IPv6
> literals (`http://[2001:db8::1]:8000` → `[2001` → no dot → silently accepted).
> Both are closed and pinned by tests.

---

## What `bin/lucairn doctor` checks

With `LUCAIRN_L3_SPLIT_POOL=true`, `check_l3_split_pool_preflight`
(`bin/lucairn:1515-1601`) replaces the in-box L3 preflight:

| Condition | Result |
|---|---|
| `l3_runtime` is not `vllm` in the active YAML | **FAIL** — L3 still routes to `ollama-identity` |
| `l3_base_url` unset/commented | **FAIL** |
| `l3_base_url` carries userinfo (`user:pass@`) | **FAIL** — would synthesize an `Authorization` header |
| host is `vllm-l3` / `localhost` / loopback / `0.0.0.0` | **FAIL** — a pool is remote; nothing local serves L3 here |
| host is a public FQDN or public IP | **FAIL** — the sanitizer blocks it at boot anyway |
| host is RFC1918 / ULA / private-DNS | **pass** |
| `vllm-l3` profile also active | **WARN** — local GPU service would run unused |
| GPU / NVIDIA toolkit / WSL2 | **skipped** — the GPU is on the pool host |

Undeclared (the default), the split branch is inert and every in-box check
behaves exactly as before — pinned by the no-regression cases in
`tests/test_l3_split_pool_preflight.sh`.

**Doctor does not probe the endpoint.** It runs on the host; the sanitizer dials
the pool from inside its container, so a host-side probe can pass or fail for
reasons that do not apply to the container. Doctor prints the post-up command
instead — the same honesty rule the in-box lane already follows for its
no-host-port service (`bin/lucairn:1863-1865`).

---

## Reachability — verify it, don't assume it

The kit does **not** add a network for the pool, and it cannot: the pool's
address is on the customer's own network.

What the kit's own networks do:

- The in-box L3 model network `dsa-model-runtime-identity` is declared
  `internal: true` (`docker-compose.self-hosted.yml:43-55`). A container reaches
  **nothing** off the host through an internal bridge — that is why the in-box
  vLLM weights must be pre-staged. **A remote pool is therefore not reachable
  over that network.**
- The sanitizer is also attached to `dsa-identity` (`internal: true`,
  `docker-compose.customer.yml:56-58`) and to `dsa-witness-identity`
  (`docker-compose.customer.yml:73-74`), which is **not** declared
  `internal: true`. Attachments: `docker-compose.customer.yml:628-630` plus
  `docker-compose.self-hosted.yml:184-185`.

Whether that routes to *your* pool subnet is a host/network question the kit
cannot answer. **Verify it after `up`, from inside the sanitizer container:**

```sh
docker compose -f docker-compose.customer.yml -f docker-compose.self-hosted.yml \
  exec sanitizer python3 -c \
  "import urllib.request;print(urllib.request.urlopen('http://10.0.0.10:8000/v1/models').status)"
```

`200` means the sanitizer can reach the pool. Anything else means L3 will fail
closed (503 on every request, by design — `fallback_on_error: reject`,
`config/default-sanitizer.yaml:135`). If the
container cannot route there, add your own compose override attaching the
sanitizer to a network that reaches the pool. Do **not** attach the pool or the
sanitizer to the AI-plane networks: the L3 shield sees identity data and must
stay off the AI plane (`docker-compose.self-hosted.yml:530-537`).

---

## Failure modes and what catches them

| Failure mode | Caught by |
|---|---|
| Split declared, YAML runtime never flipped | `doctor` FAIL (`bin/lucairn:1522-1532`) |
| `l3_base_url` unset | `doctor` FAIL |
| Pool address is public | `doctor` FAIL + sanitizer boot block (`config.py:1507-1533`) |
| Hostname that looks RFC1918 (`10.evil.com`) | `doctor` FAIL (`_l3_host_is_internal`) + sanitizer boot block |
| Credentials in the URL | `doctor` FAIL + sanitizer boot rejection (`llm_scan.py:495-510`) |
| Pointed at the local `vllm-l3` alias with no local service | `doctor` FAIL (would otherwise be 503-on-every-request) |
| Local `vllm-l3` profile left active on a pool client | `doctor` WARN |
| Marker typo (`LUCAIRN_L3_SPLIT_POOL=ture`) | `doctor` FAIL — never a silent skip |
| Pool unreachable from the sanitizer container | post-up `exec` probe above; then fail-closed 503s (`config/default-sanitizer.yaml:135`) |
| Pool logs request content | **not caught by the kit** — you operate the pool; pass `--disable-log-requests` |
| Pool serves a different model/quantization | **not caught by the kit** — pin the model and re-run your recall gate |

The last two are honest gaps, not oversights: the kit does not deploy the pool
host, so it cannot assert anything about it.

---

## Rollback

Comment `l3_runtime` / `l3_base_url` back out in
`config/default-sanitizer.yaml` and remove `LUCAIRN_L3_SPLIT_POOL` from
`customer.env`, then recreate. L3 returns to the in-box `ollama-identity`
default — the same rollback the in-box vLLM lane uses
(`docs/L3_VLLM_RUNTIME.md` § *Rollback to Ollama*).
