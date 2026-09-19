# Laptop profile (LIP Mac lane)

A validated, **non-default** compose override for running the full Lucairn
self-hosted kit stack (gateway + sanitizer + witness + sandbox-b, all four
sanitizer layers including L3) on a single consultant-class Apple Silicon
laptop, with the local model runtime served by **host `ollama`** (not
containerized — Apple Metal/GPU is not reachable from inside a Docker
Desktop/colima Linux VM).

This directory is a contribution artifact from the **local intelligence
plane** program. Cite: `Opus Advisor/specs/2026-07/prd-2026-07-27-local-intelligence-plane.md`
(Locked); board **#173** (master), **#174** (screenshot ingestion / this
lane's original driver ticket).

**⚠️ UNTESTED BEYOND MARC'S OWN MACHINE.** Everything below was measured on
one Apple M5 Pro MacBook, 24GB RAM, macOS + colima (vz + Rosetta emulation
for the ~amd64-only kit images). It has not been run on any other Mac model,
chip generation, RAM size, or by anyone other than Marc. Treat every number
here as "reproduced once, on this machine" — not a supported configuration
claim.

## What this override changes vs. the shipped kit compose

Drop `docker-compose.laptop.yml` in alongside your kit's
`docker-compose.self-hosted.yml` and layer it with `-f` (or merge the pieces
you need). It is additive-only — nothing in the kit's own compose files is
modified by this contribution.

## Sizing (measured, this machine only)

- **colima VM: services-only, 8GB RAM** (the VM runs gateway/sanitizer/
  sandbox-b/witness containers only — no model runtime inside the VM).
  Earlier attempts ran ollama containers *inside* the VM too (needed up to
  16GB and still hit swap thrash with two 5.5GB models resident); moving the
  model runtime to the host and stopping the in-VM ollama containers is what
  got the VM down to a stable 8GB.
- **Models run on host `ollama`, not in a container** — this is the only way
  to reach Apple's GPU (Metal); a Linux VM/container cannot see it, so
  containerized ollama silently runs full-CPU.
- **One-resident-model rule on 24GB:** run exactly ONE model on the host,
  serving BOTH roles (L3 PII detection scan and the local-chat/ingestion
  inference calls). Trying to keep two 7B-class models resident
  simultaneously caused swap thrashing and an ollama hang requiring
  `pkill -f "ollama serve" && ollama serve` to recover. On a 24GB machine,
  co-residency does not have enough headroom once the kit's own containers
  are also running — pick one model and point every local-runtime caller at
  it.

## Six kit findings this profile works around

1. **Board #183** — a fresh clean-clone compose mounts
   `../starter-templates` (a path *outside* the repo), so sandbox-b loads
   "0 templates" out of the box on a fresh install.
2. **Board #184** — `qi_engine`'s `classifier.py:16` uses an unanchored
   `/age|alter|birth/` pattern matched against **field names**, which matches
   `user_messAGE_N` (the literal substring "age" inside "message") and
   misclassifies the whole conversation turn as a quasi-identifier, replacing
   it with `[NUMERIC]` — a fresh kit install with `QI_ENGINE_ENABLED=true`
   (the kit's shipped default; the hosted box runs it `false`) silently
   destroys 100% of chat content. This profile does not change the kit's
   code — the workaround is operational (disable `QI_ENGINE_ENABLED` for the
   laptop profile) until the upstream fix lands.
3. **Sanitizer 2GB cgroup memory cap → worker SIGKILL.** The kit's default
   `deploy.resources.limits.memory: 2g` on the sanitizer service SIGKILLs a
   worker on a real Claude-Code-sized payload; idle RSS with the L3 model
   context loaded is already ~1.3GB before any request lands. This profile
   raises it to `4g`. *(Not yet filed as a separate board ticket at the time
   of writing — see the note below.)*
4. **`MAX_PROMPT_CHARS` default (100K) is below a real Claude Code first
   turn.** A real Claude Code session's first payload (system prompt + tool
   definitions) measured **141,767 characters** — over the kit's 100,000-char
   default, which rejects every real session out of the box. This profile
   raises `MAX_PROMPT_CHARS` to 400,000. *(Not yet filed as a separate board
   ticket.)*
5. **`SANITIZER_MAX_FIELD_CHARS` default (48KiB) fail-closes on a CLAUDE.md-
   sized field.** Claude Code ships the project `CLAUDE.md` as one platform-
   reminder field; a measured real field was 142,873 characters — well over
   the 48KiB (49,152-char) default, which trips the sanitizer's fail-closed
   guard. This profile raises `SANITIZER_MAX_FIELD_CHARS` to 262144 (256KiB).
   *(Not yet filed as a separate board ticket.)*
6. **Warm-cache posture ships off.** The kit's compose/env-example files do
   not set the content-cache, whole-turn verdict-cache, or L3 per-chunk
   verdict-cache flags at all, so a fresh kit install runs without any of
   the warm-cache posture the hosted box uses for performance. This profile
   turns all three on explicitly (with HMAC keys sourced from your
   `customer.env`, never hardcoded — see the redaction note below).
   *(Not yet filed as a separate board ticket.)*

## Measured numbers (this machine, this session — cite before reusing)

- **L3 PII scan (warm, per-chunk):** ~0.3s, 10/10 stability runs.
- **Gateway turn, all-in:** ~2.8s (small/non-Claude-Code-sized turns).
- **Real Claude Code turn via the Teams-subscription upstream lane:**
  ~12–15s (measured range; first-turn cold payload scanning under Rosetta is
  the dominant cost, not the model call — small API-sized turns through the
  same stack run ~3s, and a cold 142K-char first payload measured
  71.8s cold / 80.2s warm in a separate full-payload run).
- All of the above are from local manual runs, not the official recall/perf
  gate. **The official 100%-recall fixture gate has NOT been run against
  this profile's exact config** — do not treat these numbers as a
  redaction-quality claim, only a latency/stability one.

## Secrets / redaction note

`GATEWAY_OAUTH_PASSTHROUGH_ALLOWLIST` in `docker-compose.laptop.yml` is set
to `${LIP_SUB_KEY_PREFIX:-}` — **you must supply your own key prefix** via
environment or your `customer.env` before starting the stack; the value
committed here is a placeholder variable reference, not a real prefix. All
three sanitizer cache HMAC keys are also `${VAR}` references only — none of
this file contains a literal secret. Keep it that way in any future edit to
this file.

## Related, not included here

A Windows-native twin of this profile (for Marc's physical 4090 PC lane,
Slice 4 of the LIP PRD) lives at
`Opus Advisor/local-intelligence-plane/windows/` in the Opus Advisor
workspace — it is **not** copied into this kit repo. If/when that lane is
validated and a kit contribution is warranted, it should land as its own
`contrib/windows-profile/` directory with its own README, not merged into
this one (different sizing, different GPU backend, different launcher
mechanics).

## Status

Locally validated on one machine, one session. Draft PR only — no merge
authority has been exercised for this contribution. Before this profile is
recommended to anyone else: (a) the official recall/perf fixture gate needs
to run against it, (b) items 3–6 above should get their own board tickets
if they are to be fixed upstream in the kit rather than worked around here,
and (c) it needs at least one independent reproduction on a different
Mac/RAM configuration.
