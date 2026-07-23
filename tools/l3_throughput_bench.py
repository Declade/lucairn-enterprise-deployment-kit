#!/usr/bin/env python3
"""L3 runtime concurrency-throughput benchmark (PRD B, Slice B3).

Measures sustained records/second of an OpenAI-compatible L3 endpoint under
N concurrent in-flight requests, to quantify the vLLM continuous-batching win
over the Ollama time-sliced ceiling on the SAME GPU.

WHY THIS EXISTS
  The L3 deep PII shield runs on Ollama by default. Ollama time-slices
  concurrent requests on one GPU -> a hard ~5 rec/s ceiling. vLLM's continuous
  batching multiplies throughput with concurrency (measured 7.4x @ width-8,
  13x @ width-16 on one RTX 4090). This harness produces that ratio as the
  enterprise pitch datum.

B-E4 (benchmark validity) — READ THIS
  This harness hits the model endpoint DIRECTLY (the vLLM/Ollama OpenAI
  `/v1/chat/completions` server), NOT through the sanitizer. That is deliberate:
  the real sanitizer path can saturate on gunicorn workers BEFORE the GPU, so a
  sanitizer-path number would measure gunicorn, not vLLM. Point `--base-url` at
  the model server (e.g. the vllm-l3 alias at http://vllm-l3:8000/v1, or the
  ollama-identity server). Multi-GPU scaling is a PROJECTION, never measured by
  this single-endpoint harness — label it as such in any pitch.

DEPENDENCY-LIGHT
  Python stdlib only (urllib + concurrent.futures). No `openai`, no `requests`.
  Runs on any host that can reach the endpoint.

USAGE
  # vLLM-L3 (OpenAI /v1/chat/completions):
  python3 tools/l3_throughput_bench.py \
      --base-url http://127.0.0.1:8000/v1 \
      --model Qwen/Qwen2.5-7B-Instruct-AWQ \
      --concurrency 1,8,16 --requests 24 --max-tokens 200

  # Ollama-L3 ceiling (Ollama also serves an OpenAI-compatible /v1 shim):
  python3 tools/l3_throughput_bench.py \
      --base-url http://127.0.0.1:11434/v1 \
      --model qwen2.5:7b \
      --concurrency 1,8,16 --requests 24 --max-tokens 200

  Run BOTH and compare the rec/s columns: that ratio is the datum.

NOTE ON DETERMINISM
  temp=0 + a fixed seed makes each *request* deterministic, but vLLM continuous
  batching can shift FP reduction order with batch composition -> output can
  drift slightly across *concurrency levels* (the "batch-level nondeterminism"
  documented in the findings). This harness measures THROUGHPUT, not
  byte-identity; the sanitizer-path byte-identity gate is a separate check.
"""

import argparse
import http.client
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

# A representative L3-scan prompt (~1,200 chars) with mixed PII, so the
# per-request cost approximates a real L3 chunk. This is a SYNTHETIC fixture —
# no real personal data.
DEFAULT_PROMPT = (
    "Scan the following record for personal data and list every span you find "
    "as a JSON array of {type, value} objects. Record:\n"
    "Patient Maria Gonzalez, DOB 1984-03-11, MRN 4471982, seen at Klinikum "
    "Nord on 2026-01-14. Contact: maria.gonzalez@example.org, +49 151 23456789. "
    "Address: Steinweg 12, 90402 Nuernberg. Insurance ID DE-88123-004. "
    "Referring physician Dr. Ahmed Farouk (BSNR 998877). Employer: Siemens AG, "
    "employee no. 55-2210. Emergency contact: Thomas Gonzalez, +49 170 9988776. "
    "Prior visit note references patient Johann Weber (DOB 1971-09-02) and "
    "nurse Priya Nair. IBAN DE12 3456 7890 1234 5678 90. Case worker: "
    "s.mueller@example.org. Do not include non-personal tokens."
)


def one_request(base_url, model, prompt, max_tokens, seed, timeout):
    """Fire one /v1/chat/completions request. Returns (ok, latency_s, out_tokens)."""
    url = base_url.rstrip("/") + "/chat/completions"
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "seed": seed,
        "stream": False,
    }
    data = json.dumps(body).encode("utf-8")
    # NOTE: NO Authorization header. The L3 endpoint is internal + unauthenticated
    # by design (identity-plane isolation); sending a credential would be the A-E2
    # egress anti-pattern. This harness never sends one.
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        dt = time.perf_counter() - t0
        out_toks = 0
        usage = payload.get("usage") or {}
        if isinstance(usage, dict):
            out_toks = int(usage.get("completion_tokens") or 0)
        return True, dt, out_toks
    except (
        urllib.error.URLError,
        urllib.error.HTTPError,
        http.client.HTTPException,  # IncompleteRead/RemoteDisconnected under load — not an OSError
        ValueError,
        OSError,
    ) as exc:
        dt = time.perf_counter() - t0
        return False, dt, 0, str(exc)  # 4-tuple on failure; caller handles


def run_level(base_url, model, prompt, n_requests, concurrency, max_tokens, seed, timeout):
    """Run n_requests through a pool of `concurrency` workers; return metrics dict."""
    results = []
    errors = []
    wall_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futs = [
            pool.submit(one_request, base_url, model, prompt, max_tokens, seed, timeout)
            for _ in range(n_requests)
        ]
        for fut in as_completed(futs):
            r = fut.result()
            if r[0]:
                results.append((r[1], r[2]))
            else:
                errors.append(r[3] if len(r) > 3 else "unknown")
    wall = time.perf_counter() - wall_start

    ok = len(results)
    total_out = sum(o for _, o in results)
    rec_s = (ok / wall) if wall > 0 else 0.0
    tok_s = (total_out / wall) if wall > 0 else 0.0
    return {
        "concurrency": concurrency,
        "requests": n_requests,
        "ok": ok,
        "errors": len(errors),
        "wall_s": round(wall, 2),
        "rec_s": round(rec_s, 2),
        "tok_s": round(tok_s, 1),
        "out_tokens": total_out,
        "error_samples": errors[:3],
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="L3 concurrency-throughput benchmark (direct endpoint).")
    ap.add_argument("--base-url", required=True,
                    help="OpenAI-compatible base URL, e.g. http://vllm-l3:8000/v1 (DIRECT endpoint, not the sanitizer).")
    ap.add_argument("--model", required=True, help="Model id, e.g. Qwen/Qwen2.5-7B-Instruct-AWQ or qwen2.5:7b")
    ap.add_argument("--concurrency", default="1,8,16", help="Comma-separated widths to sweep (default 1,8,16).")
    ap.add_argument("--requests", type=int, default=24, help="Requests per width (default 24).")
    ap.add_argument("--max-tokens", type=int, default=200, help="max_tokens per request (default 200).")
    ap.add_argument("--seed", type=int, default=42, help="Sampling seed (default 42).")
    ap.add_argument("--timeout", type=float, default=120.0, help="Per-request timeout seconds (default 120).")
    ap.add_argument("--prompt-file", default=None, help="Optional file with a custom scan prompt.")
    ap.add_argument("--json", action="store_true", help="Emit machine-readable JSON instead of a table.")
    args = ap.parse_args(argv)

    prompt = DEFAULT_PROMPT
    if args.prompt_file:
        with open(args.prompt_file, encoding="utf-8") as fh:
            prompt = fh.read()

    try:
        widths = [int(x) for x in args.concurrency.split(",") if x.strip()]
    except ValueError:
        ap.error("--concurrency must be comma-separated integers (e.g. 1,8,16)")

    # Guard rails: ThreadPoolExecutor requires max_workers >= 1, and a
    # non-positive request count would report meaningless "successful" rows.
    if not widths:
        ap.error("--concurrency parsed to no widths; give at least one, e.g. 1,8,16")
    bad = [w for w in widths if w < 1]
    if bad:
        ap.error(f"--concurrency widths must be >= 1 (got {bad}); each is a ThreadPoolExecutor worker count")
    if args.requests < 1:
        ap.error(f"--requests must be >= 1 (got {args.requests})")

    rows = []
    for w in widths:
        row = run_level(args.base_url, args.model, prompt, args.requests, w,
                        args.max_tokens, args.seed, args.timeout)
        rows.append(row)

    if args.json:
        print(json.dumps({
            "base_url": args.base_url, "model": args.model,
            "requests_per_width": args.requests, "max_tokens": args.max_tokens,
            "note": "DIRECT endpoint (B-E4): not the sanitizer path; multi-GPU is a projection, not measured.",
            "rows": rows,
        }, indent=2))
        return 0

    # Human table + speedup vs the smallest width (assumed sequential baseline).
    base_rec = rows[0]["rec_s"] if rows and rows[0]["rec_s"] > 0 else 0.0
    print(f"L3 throughput — {args.model} @ {args.base_url}  (direct endpoint, B-E4)")
    print(f"  {args.requests} requests/width, max_tokens={args.max_tokens}, temp=0, seed={args.seed}")
    print()
    print(f"  {'width':>6} | {'ok':>4} | {'err':>4} | {'wall_s':>7} | {'rec/s':>7} | {'tok/s':>7} | {'vs base':>8}")
    print("  " + "-" * 62)
    for r in rows:
        speedup = f"{(r['rec_s']/base_rec):.1f}x" if base_rec > 0 else "—"
        print(f"  {r['concurrency']:>6} | {r['ok']:>4} | {r['errors']:>4} | "
              f"{r['wall_s']:>7} | {r['rec_s']:>7} | {r['tok_s']:>7} | {speedup:>8}")
        if r["error_samples"]:
            print(f"         err sample: {r['error_samples'][0][:80]}")
    print()
    print("  NOTE: multi-GPU scaling is a PROJECTION, not measured here. Ratio (vs base)")
    print("  is the enterprise datum. Run the same command against the Ollama /v1 to")
    print("  capture the ~5 rec/s ceiling for the comparison.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
