# Hermes Agent through Lucairn

Verified with **Hermes Agent v2026.9.24** (CLI 0.21.5, commit
`f97608f178d1ffeca59860195ab7da295f7c8e5f`), Python 3.12, on macOS, against
`https://gateway.lucairn.eu`, 2026-10-14. Read [`../README.md`](../README.md) first
(keys, work folder rule, shared limits).

## Set up

```sh
./install.sh                 # pinned clone + venv in ~/.local/share/lucairn-clients/hermes/v2026.9.24
                             # needs git, uv, python3.12 — nothing global, never ~/.hermes
./install.sh --check         # verify only (no network)
```

Put both keys in the Keychain or the environment ([`../README.md`](../README.md#keys)).

## Start

```sh
./hermes.sh -z "your question"            # one question
./hermes.sh                               # interactive chat (leave with /exit)
./hermes.sh sessions list                 # earlier chats
./hermes.sh --resume <id> -z "next"       # continue one
./hermes.sh -m claude-sonnet-5-5 --provider lucairn-anthropic -z "…"   # another model
./hermes.sh --reset-config                # put the recipe back (keeps chats)
```

Hermes works inside `LUCAIRN_WORK_DIR` (default `/Users/Shared/agent-work/hermes`);
its file tools act there. The profile (`HERMES_HOME`) is
`~/.local/share/lucairn-clients/hermes/profile/hermes-home` unless you set
`LUCAIRN_HERMES_PROFILE`.

## The recipe (`config.yaml`) — every line is load-bearing

| Setting | Why |
|---|---|
| `providers.lucairn-anthropic` (`api: ${LUCAIRN_GATEWAY_URL}`, `transport: anthropic_messages`, `key_env: LUCAIRN_API_KEY`, `X-Upstream-Key: ${LUCAIRN_UPSTREAM_KEY}`), `model.provider: lucairn-anthropic` | the gateway is the model provider; keys come from the environment only |
| `context_length: 200000` | stops most model-metadata probes |
| `auxiliary.title_generation.model_upgrade_enabled: false` | no hidden "name this chat" request (else 2 requests per message) |
| `agent.api_max_retries: 1`, `agent.auto_recovery_cycles: 0` | one refused message = one request (Hermes default: 3) |
| `agent.max_turns: 25` | Hermes' own hard stop for a task that keeps calling tools (default: unlimited). Set, not exercised in testing |
| `web.keyless_fallback: false`, `web.keyless_rescue: false`, `agent.disabled_toolsets: [web]` | **web search off** — see below |
| `security.allow_lazy_installs: false` | no packages fetched from pypi.org at run time (measured: a fresh install otherwise installs boto3 and friends on its first start) |
| `platform_toolsets.cli: [file]` | file tools only |

`hermes.sh` refuses to start when the guarded lines are missing or changed, and
when the profile's `.env` holds a key.

### Why web search is off

Unconfigured, Hermes' web tools fall back to a "keyless ring" of four public
search services — `mcp.exa.ai`, `search.parallel.ai`, `api.firecrawl.dev`,
`api.keenable.ai` — so a search query (which can carry anything from the
conversation) would leave your machine **without passing the Lucairn gateway**.
Source in the pinned install: `src/plugins/web/keyless_mcp.py:21-23` (exa,
parallel, keenable addresses), `:318` (the ring), and
`src/plugins/web/firecrawl/provider.py:24` (firecrawl address).

Measured 2026-10-14 through a connection log: a profile without the web settings
contacted `api.keenable.ai` for one web search; with this recipe — default, with
`-t web` forced, and with only `keyless_fallback: false` — 0 contacts to any of
the four.

## Never use the settings form for keys

Keep both keys in the Keychain or the environment. Measured (2026-10-13/14):

- A key typed into Hermes' settings form (desktop app) is stored **in clear text**
  in `<HERMES_HOME>/.env`. `hermes.sh` refuses to start while such a line exists.
- Pressing Save in Custom Endpoints rewrites `config.yaml` (adds `base_url`,
  removes `transport`, can swap `key_env`); a refused message then sends 3 requests
  instead of 1. `hermes.sh` refuses such a config; restore with
  `./hermes.sh --reset-config`.
- The provider key (`X-Upstream-Key`) has no field in the form at all.

## Limits

- API-key lane only; a Claude subscription (seat) login cannot be carried.
- Each start makes 5–8 GET model-metadata probes to the gateway (answer 404, no
  content, carry the Lucairn key to the gateway only).
- Only the `file` toolset is part of the verified setup. Terminal, browser,
  text-to-speech, image generation and the other default toolsets were not
  verified and may contact other services — add them only after your own check.
- A first interactive terminal start was seen (2026-10-13) to download Hermes'
  `tirith` scanner from github.com release assets (content-free); not re-measured
  with this recipe.
- The rate-limit message always says "Wait a minute" in its headline — also for a
  used-up monthly quota (the gateway's own text is on the last line).
- Retries and loops: the recipe sets 1 request per refused message and a cap of
  25 model steps per task. Within those 25 steps nothing stops a model that keeps
  re-doing the same tool call (seen: a small file task took 8 steps before the
  placeholder rule).
- The Hermes desktop app is not covered by this launcher; if you use it, start it
  with the same environment and never type keys into its form.
- The standing placeholder rule (`../lib/placeholder-rule.md`) is appended once
  to the profile's `SOUL.md` (Hermes reads it into every system prompt).
