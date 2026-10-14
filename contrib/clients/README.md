# Agent clients through Lucairn — Hermes, OpenCode, OpenWork

Launchers and recipes that run three open-source agent clients through a Lucairn
gateway (the hosted `https://gateway.lucairn.eu`, or your own self-hosted gateway).
Each folder holds an `install.sh` (pinned client version, nothing global), a
launcher, the client configuration, and a README with setup, start and limits.

| Client | Folder | Verified with | Surfaces covered |
|---|---|---|---|
| Hermes Agent | [`hermes/`](hermes/README.md) | v2026.9.24 (CLI 0.21.5, commit `f97608f1`) | command line (one question, chat, resume), file tools |
| OpenCode | [`opencode/`](opencode/README.md) | 1.19.0 | terminal chat, one question, file tools, local browser page |
| OpenWork | [`openwork/`](openwork/README.md) | openwork-server 0.18.58 (OpenCode engine 1.18.30); desktop dev build v0.18.58 | host + one question / chat, file tools, local web page, desktop app (dev build) |

Verified on macOS (Apple silicon) and on Windows 11 x64 (native Windows programs,
launchers run from Git Bash) against `https://gateway.lucairn.eu` on 2026-10-14
with synthetic content only. The launchers are bash scripts for macOS, Linux and
Windows (Git Bash, part of Git for Windows); Linux was not part of that run. The
OpenWork desktop app launcher is macOS only. A newer client version may behave
differently — re-run your own checks before you move a pin.

## What every launcher does

- **Keys stay out of files.** The Lucairn API key and the provider key are read
  from the environment (`LUCAIRN_API_KEY`, `LUCAIRN_UPSTREAM_KEY`) or from the
  macOS Keychain by item name, and handed to the client's process environment
  only — never written to a config file, never put on a command line. The
  launcher takes them out of its own environment the moment it starts, so the
  helper programs it runs (config checks and writers, build steps) never see
  them.
- **Clean environment.** Every inherited variable is dropped before the client
  starts (no stray provider key, no real home folder); all client state lives in
  a profile folder the launcher owns. Proxy settings (`HTTPS_PROXY`, `NO_PROXY`, …)
  are kept.
- **Lucairn is the only provider** the client can pick, its "name this chat"
  request is switched off (a message without tools that is answered at once = one
  model request = one certificate; retries and tool use add requests, see the
  limits below), and the client's own update checks / hosted extras are switched
  off where the client offers a switch.
- **Gateway address checked.** `LUCAIRN_GATEWAY_URL` must be `https://<host>…`
  (`http://` only for `127.0.0.1`, `localhost` or `[::1]`); an address with a user
  name or password part (`…@…`), a query or an odd character is refused and
  nothing starts.
- **Work folder rule.** The client runs inside a work folder whose full path holds
  no person's or account name (default `/Users/Shared/agent-work/<client>` on
  macOS, `/var/tmp/agent-work/<client>` on Linux). The gateway replaces names in
  the text it forwards — also inside file paths — and the model then loses track
  of its own files. The launchers refuse a folder whose path contains your login
  name or your home folder's name anywhere, in any letter case — also inside a
  longer word, e.g. `/var/tmp/alice-project` for the login `alice` (override at
  your own cost: `LUCAIRN_ALLOW_NAMED_WORKDIR=1`). Keep folder
  names plain lowercase words: a brand-like word in a path was replaced as a
  person's name in testing.
- **Placeholder rule.** A short standing text (`lib/placeholder-rule.md`) goes into
  every system prompt: placeholders such as `[PERSON_1]` in earlier tool calls mean
  the real value was used, so the model does not redo the call, and file tools get
  relative file names (full paths are often shown back as a placeholder). Measured:
  a file task that looped past the account's per-minute limit without it finished
  in 4 requests with it.

## Keys

The verified setup is the **API-key lane**: a Lucairn API key plus your model
provider's API key, which travels to the gateway in the `X-Upstream-Key` header.
These clients cannot carry a Claude subscription (seat) login through Lucairn —
that path works only with an unmodified Claude Code.

```sh
# macOS Keychain (item names are the launcher defaults; change them with
# LUCAIRN_KEYCHAIN_ITEM / LUCAIRN_UPSTREAM_KEYCHAIN_ITEM)
security add-generic-password -a "$(id -un)" -s lucairn-api-key -w        # prompts for the Lucairn key
security add-generic-password -a "$(id -un)" -s lucairn-upstream-key -w   # prompts for the provider key
```

Or export `LUCAIRN_API_KEY` and `LUCAIRN_UPSTREAM_KEY` from your own secret store
before you start a launcher.

## Windows

Run the same launchers from **Git Bash** (Git for Windows); the clients run as
native Windows programs. Differences:

- **Keys:** there is no Keychain lookup on Windows. Hand `LUCAIRN_API_KEY` and
  `LUCAIRN_UPSTREAM_KEY` to the launcher through the environment of the session
  that starts it (verified that way), from your own secret store — not as
  permanent user variables and never in a file. Windows Credential Manager was
  not verified.
- **Paths:** use Git Bash paths (`/c/…`, `/e/…`) for `LUCAIRN_CLIENTS_HOME`,
  `LUCAIRN_WORK_DIR` and the profile variables. Default work folder:
  `/c/agent-work/<client>` (`C:\agent-work\<client>`). The work folder rule
  applies, also to brand-like words in the path.
- **Profile:** the launchers point `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`,
  `TEMP` and `TMP` into the profile as well, so nothing lands in your real user
  folder (measured: no client folder appeared there).
- **Needs:** Git for Windows; node + npm (OpenCode, OpenWork); for Hermes `uv`,
  `git` and Python 3.12 from python.org (found through the `py` launcher, or set
  `LUCAIRN_HERMES_PYTHON`).
- **First start of a profile:** OpenCode and the OpenWork engine download ripgrep
  (about 1.8 MB, content-free) from github.com at start-up on Windows, once per
  profile (on macOS only at the first file search).

## Common environment

| Variable | Default | Meaning |
|---|---|---|
| `LUCAIRN_GATEWAY_URL` | `https://gateway.lucairn.eu` | your gateway (https; `http://` only for `127.0.0.1` / `localhost` / `[::1]`, a local test gateway; no `user@` part) |
| `LUCAIRN_CLIENTS_HOME` | `~/.local/share/lucairn-clients` | where installs and profiles go |
| `LUCAIRN_WORK_DIR` | `/Users/Shared/agent-work/<client>` | the work folder |
| `LUCAIRN_KEYCHAIN_ACCOUNT` | your login name | Keychain account of both items |

## Limits shared by all three

- API-key lane only; no subscription (seat) login.
- A used-up monthly quota and the per-minute rate limit both arrive as HTTP 429
  `rate_limit_error` (only the message text differs), so the clients show their
  generic "rate limited / wait" text for both.
- A question that uses tools costs several model requests (a small file task took
  4 in testing, each client); a per-minute limit on your Lucairn account is reached
  quickly.
- Retries on a 429 or an unreachable gateway: Hermes (with the recipe) sends 1
  request per refused message; OpenCode and OpenWork send up to 6 requests per
  message (5 retries, about 69 s, hard-coded — no setting lowers it). Each one that
  reaches the gateway counts on your quota.
- The keys sit in the environment of the client's processes; other programs of
  the same user can read them.
- Anything a tool reads (a file, a tool result) goes through Lucairn to the model
  vendor like any message. Put only data in the work folder you may send.
- What the sanitizer recognises is not changed by these launchers.
