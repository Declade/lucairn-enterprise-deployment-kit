# OpenWork through Lucairn

Verified with **openwork-server 0.18.58** (npm), which runs the **OpenCode engine
1.18.30**, and the OpenWork **desktop app as a dev build from tag v0.18.58**, on
macOS, against `https://gateway.lucairn.eu`, 2026-10-14 (the tag's commit
`258218b9`; `desktop.sh` refuses any other). Read
[`../README.md`](../README.md) first (keys, work folder rule, shared limits).

## Set up

```sh
./install.sh            # npm ci against package-lock.json (sha512-checked), no install scripts,
                        # into ~/.local/share/lucairn-clients/openwork/0.18.58 — needs node >= 22.13
./install.sh --check    # verify only (no network)
```

The host downloads its OpenCode engine from github.com (OpenCode release assets)
on its first start, into the profile.

## Start

```sh
./openwork.sh ask "question"              # one message in a new chat
./openwork.sh ask "first" "second"        # several messages in ONE chat
./openwork.sh ask --continue "next"       # continue the most recent chat
./openwork.sh ask --work "file task"      # with file tools (read, write, edit) in the work folder
./openwork.sh list                        # stored chats (no model call)
./openwork.sh web                         # OpenWork web page on http://127.0.0.1:18787
OPENWORK_SRC=<clone at v0.18.58> ./desktop.sh        # desktop app (see below)
./desktop.sh stop                         # close it and wipe its storage
```

## What is set up

`lib/config.mjs` writes the engine config into the profile at every start:

- provider `lucairn` (`@ai-sdk/anthropic`, `baseURL {env:LUCAIRN_BASE_URL}`),
  models `claude-haiku-4-5` / `claude-sonnet-5-5`; `enabled_providers: ["lucairn"]`
- **no key in the config** — the API key field holds a placeholder. The **key
  helper** `plugin/lucairn-keys-from-env.js` sets `x-api-key` and `x-upstream-key`
  from the engine's environment on requests to the gateway origin only, and
  never follows a redirect with them (a redirect answer fails the request). Why: the
  engine hands OpenWork's interface the provider list with `{env:…}` values filled
  in, and the interface saves it in its browser storage — measured 2026-10-13:
  without the helper, 8 key hits in 4 files while the desktop app ran
- `agent.title.disable: true`, `share: "disabled"`, `autoupdate: false`
- `permission: {"*": "deny"}` plus `allow` per wanted tool (`--work`: `read`, `edit`)
- `instructions`: `plugin/lucairn-rules.md` (answer in the chat, never call the
  `skill` tool — it cannot be removed) and `../lib/placeholder-rule.md`

Environment: `OPENWORK_DISABLE_FREE_INFERENCE=1` and `OPENWORK_NO_UPDATE_CHECK=1`
(no hosted free model, no update check), `OPENCODE_DISABLE_MODELS_FETCH`,
`OPENCODE_DISABLE_AUTOUPDATE`, `OPENCODE_DISABLE_EXTERNAL_SKILLS`,
`OPENCODE_DISABLE_CLAUDE_CODE`.

MCP tools (e.g. ServiceNow): write a JSON file
`{"mcp": {"servicenow": {"type": "local", "command": [...], "enabled": true}}, "allow": ["servicenow_table_read", …]}`
and start with `LUCAIRN_OPENWORK_MCP=<file>`. Only the listed tools can run.

## Desktop app

`desktop.sh` runs the dev build from a source clone (the signed installer was not
verified). It needs node, pnpm and bun (`LUCAIRN_NODE`, `LUCAIRN_PNPM`, `LUCAIRN_BUN`
if they are not on your PATH):

```sh
git clone --depth 1 --branch v0.18.58 https://github.com/different-ai/openwork.git <dir>
cd <dir> && pnpm install --frozen-lockfile        # about 3.5 GB
OPENWORK_SRC=<dir> ./desktop.sh                   # first start builds the app (several minutes)
```

It refuses to start unless `git` is installed and the clone is exactly commit
`258218b9b69c91e3d5020488fe1d14ff767679e9` (tag v0.18.58 on 2026-10-14) with no
changed tracked files — a moved tag is refused. It runs the app's build steps
and its interface dev server without the keys; only the app itself gets them.
`desktop.sh stop` signals only a process group it can prove is this app.

On top of the settings above it: **wipes the app's browser storage on every
start and every stop** (also when the window is closed), keeps the app's Electron
profile in the Lucairn profile, uses the app's mock key store instead of the macOS
Keychain, points the "OpenWork Cloud" address at a dead local address (no sign-in,
no cloud model), sets the workspace folder to the work folder, and preselects
"Claude Sonnet 5.5 via Lucairn" through the app's local debug port.

## Limits

- **Up to 6 requests per message (5 retries)** on a gateway error or an
  unreachable gateway (about 69 s); hard-coded in the engine, no setting lowers it.
  Each one that reaches the gateway counts on your quota.
- **No hard loop cap** in the engine: a model that keeps calling tools is not
  stopped. Watch long tool tasks.
- The `skill` tool cannot be switched off; the standing instructions ask the model
  not to call it (one clean first attempt measured — a wasted, billed step stays
  possible).
- **Work folder rule** as in [`../README.md`](../README.md): the path is in every
  system prompt and in every file-tool call.
- The search tool (`glob`) is not offered (it downloads a helper from github.com).
- The keys sit in the environment of the host and engine processes.
- Desktop: a debug port is open on 127.0.0.1 while the app runs (needed to
  preselect the model); there is no config setting for the starting model, so the
  window comes back on the launcher's model after a restart. Chats are all titled
  "New session" (title request off). The web page (`openwork.sh web`) keeps its
  provider list in your browser's storage — with the key helper that list holds a
  placeholder, not a key; use a separate browser profile anyway.
- A used-up monthly quota shows the same rate-limit error as the per-minute limit.
