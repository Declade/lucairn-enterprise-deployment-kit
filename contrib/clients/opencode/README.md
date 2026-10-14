# OpenCode through Lucairn

Verified with **OpenCode 1.19.0** (npm `opencode-ai@1.19.0`; macOS arm64 binary
sha256 `476151a6c8b56e084d223d71a9312479e3b95547f8d8649b3489577059f9c5b4`; Windows
x64 `opencode.exe` sha256 `bb731f311416df16691fa16763eb87657c4a5f5f3bcff5202718c416e8f7ab1a`,
identical to the one in the GitHub release asset) on macOS and Windows 11,
against `https://gateway.lucairn.eu`, 2026-10-14. Read [`../README.md`](../README.md)
first (keys, work folder rule, shared limits).

`pins.sh` holds the sha256 of the OpenCode binary for every platform package in
the lockfile (darwin-arm64/x64, linux-arm64/x64, windows-x64/arm64). `install.sh`
moves an install into place only when its binary matches, and `opencode.sh`
checks it again at every start: a binary that does not match never gets the keys.

## Set up

```sh
./install.sh            # npm ci against package-lock.json (sha512-checked), no install scripts,
                        # built in a temp folder, moved into ~/.local/share/lucairn-clients/opencode/1.19.0
                        # only after the binary matched pins.sh — nothing global
./install.sh --check    # verify only (no network)
```

Put both keys in the Keychain or the environment ([`../README.md`](../README.md#keys)).

## Start

```sh
./opencode.sh                         # chat in the terminal, no tools (leave with Ctrl+C)
./opencode.sh "Reply with OK"         # one question
./opencode.sh --work                  # chat with file tools (read, write, edit, glob) in the work folder
./opencode.sh --work "task"           # one file task
./opencode.sh --web                   # local browser page on 127.0.0.1:14096 (Ctrl+C stops it)
./opencode.sh -- session list         # any other opencode command; continue a chat: -- -s <id>
LUCAIRN_OPENCODE_MODEL=claude-sonnet-5-5 ./opencode.sh "…"
```

Never start `opencode` itself: it would use your real home folder and none of the
switches below.

## What is set up

Config files in `config/` (no key in them — `{env:…}` references only):

| Setting | Why |
|---|---|
| `provider.anthropic.options`: `baseURL {env:LUCAIRN_BASE_URL}`, `apiKey {env:LUCAIRN_API_KEY}`, header `X-Upstream-Key {env:LUCAIRN_UPSTREAM_KEY}` | the gateway is the model provider |
| `enabled_providers: ["anthropic"]` | OpenCode's own hosted models are not selectable |
| `agent.title.disable: true` | no second "title" request per chat |
| `autoupdate: false`, `share: "disabled"`, `snapshot: false` | no update, no sharing |
| `permission: {"*": "deny", …}` | every tool denied; `opencode-work.json` allows only `read`, `edit`, `glob` (= read, write, edit, glob) |
| `agent.build.steps: 12` (work config) | a step limit — see Limits: a soft one |
| `instructions: ["{env:LUCAIRN_RULES_FILE}"]` | the standing placeholder rule (`../lib/placeholder-rule.md`) |

Environment set by `opencode.sh` (these switches exist only as environment
variables): `OPENCODE_DISABLE_MODELS_FETCH`, `OPENCODE_DISABLE_AUTOUPDATE`,
`OPENCODE_DISABLE_SHARE`, `OPENCODE_DISABLE_LSP_DOWNLOAD`,
`OPENCODE_DISABLE_CLAUDE_CODE`, `OPENCODE_DISABLE_EXTERNAL_SKILLS`,
`OPENCODE_DISABLE_PROJECT_CONFIG` (keeps `AGENTS.md` / `opencode.json` / their
instruction files from folders above the work folder away from the model),
`npm_config_offline=true`.

Tools from an MCP server (e.g. ServiceNow): copy
`config/opencode-servicenow.example.json`, fill in the absolute paths, and start
with `LUCAIRN_OPENCODE_CONFIG=<your copy> ./opencode.sh`. Only the tools named
`allow` in its `permission` block can run; the server's login comes from the
environment, never from the file.

## Limits

- **Up to 6 requests per message (5 retries)** on a 429 or an unreachable gateway
  (about 69 s) before the error shows; hard-coded, no setting lowers it. Each one
  that reaches the gateway counts on your quota.
- **No hard loop cap.** `agent.build.steps` is an instruction to the model, not a
  stop: a model that ignores it keeps calling tools (2026-10-13, offline: 220–371
  requests in 25 s). Watch long tool tasks; Ctrl+C stops them.
- **Work folder rule:** no person's or account name and no brand-like word in the
  path (the launcher refuses a path that contains your login name anywhere).
  Measured 2026-10-14: in
  `/Users/Shared/lucairn-work/…` the gateway showed "lucairn" as a person's name
  inside the model's own file calls and the task looped; in the default
  `/Users/Shared/agent-work/opencode` with the placeholder rule it took 4 requests.
- `OPENCODE_DISABLE_PROJECT_CONFIG=1` also ignores the work folder's OWN
  `AGENTS.md` / `opencode.json`; put project instructions into the config file.
- The first use of `glob` downloads ripgrep (3.9 MB) from github.com once per
  profile (content-free).
- **OpenCode desktop app: not supported** (not tested; it keeps its data outside
  the profile and registers a system-wide link handler). Terminal and browser page
  only. The browser page has no password (127.0.0.1 only).
- OpenCode connected straight to the gateway even with `HTTPS_PROXY` set
  (measured); in a network that only allows traffic through a proxy it may not
  reach the gateway.
- A used-up monthly quota shows the same rate-limit error as the per-minute limit.
- The work folder path is in every request's system prompt and goes to the model
  vendor as written.
