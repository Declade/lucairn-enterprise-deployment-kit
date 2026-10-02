# Config pack: Claude Code and Claude Desktop through the Lucairn gateway

Managed settings for Claude Code and Claude Desktop (third-party inference
mode) that point both tools' model requests at your Lucairn gateway and switch
off the features listed in `SETUP.md.tmpl`. Claude Code's `allowedProviders`
key makes it refuse sessions pointed anywhere else, and `requiredMinimumVersion`
stops Claude Code versions too old to know that key from starting (vendor docs;
not yet exercised on a managed machine, see the end of this file).

```bash
bin/lucairn config-pack --gateway https://gateway.example.com --output ./config-pack-out
```

Every input is validated first (see "Input rules" below). The pack is then
rendered and checked in a private temporary directory; only a pack that passes
is written to `--output`, so a refused input or a failed check leaves nothing
behind. Error messages name the input and the rule, never the rejected value.

Output:

| File | For |
| - | - |
| `managed-settings.json` | Claude Code managed settings (file, macOS profile or Windows registry delivery) |
| `claude-desktop.mobileconfig` | Claude Desktop on macOS (MDM profile, domain `com.anthropic.claudefordesktop`) |
| `claude-desktop.reg` | Claude Desktop on Windows (`HKLM\SOFTWARE\Policies\Claude`, all `REG_SZ`) |
| `SETUP.md` | Install steps, credential options, model list, firewall note |

Optional flags:

| Flag | Effect |
| - | - |
| `--models ID,ID` | Claude Desktop `inferenceModels`. The Lucairn gateway does not serve `GET /v1/models`, so without this the desktop model picker is empty until IT adds the list. |
| `--key-helper CMD` | Claude Code `apiKeyHelper` (a command that prints the user's Lucairn key). |
| `--desktop-key-helper PATH` / `--desktop-key-helper-windows PATH` | Claude Desktop `inferenceCredentialKind=helper-script` + `inferenceCredentialHelper` / `inferenceCredentialHelperWindows`; removes the static key slot. Absolute paths under an administrator-controlled root only (see "Input rules"): a helper can also print request headers, and the vendor documents that those are "merged over these static entries (helper wins on conflict)", so a helper the user can edit could switch the require header off. |
| `--egress-proxy URL` | Claude Desktop `egressProxyUrl` (MDM only): `http://` or `https://`, a valid host name, optional port 1-65535, nothing else. |
| `--force` | Overwrite files in `--output`. |

As rendered, no file contains a Lucairn key: Claude Desktop gets the
placeholder `REPLACE_WITH_YOUR_LUCAIRN_KEY` (or a helper path), Claude Code
gets no credential unless `--key-helper` is given. IT fills in the key or the
helper before deployment. Keys never go into a header
map (`ANTHROPIC_CUSTOM_HEADERS` / `inferenceCustomHeaders`); `check.py`
refuses a credential header there.

## Files in this directory

| File | Role |
| - | - |
| `spec.json` | Single source of truth: every key and value the pack writes. |
| `SETUP.md.tmpl` | The setup note rendered into the pack. |
| `render.py` | Renderer (python3, standard library). `bin/lucairn config-pack` calls it. |
| `check.py` | Offline validator: syntax of all three formats (duplicate keys included), every key against the docs snapshot, the policy values (written out in `check.py`, independent of `spec.json`), contract and no-secret rules, `--golden` (the byte pin, on the files in `--dir` when given) and `--corpus`. |
| `docs-keys-snapshot.json` | Key names extracted from the vendor's raw Markdown docs, with URL, date and page hash. |
| `snapshot_docs_keys.py` | Refreshes the snapshot from the live docs (maintainers, needs network). |
| `golden-sha256.json` | SHA-256 of the default render for `https://gateway.lucairn.eu`, plus of `spec.json` and `SETUP.md.tmpl`. |
| `parity-corpus.json` | Hostile-but-accepted gateway URLs with their normalised value and the SHA-256 of every rendered file, plus the URLs both renderers must refuse. The website checks its copy of the same file. |

The lucairn.eu account area (Downloads page) renders the same pack for a
gateway URL (no optional flags) with a TypeScript port. It vendors `spec.json`,
the setup template, `golden-sha256.json` and `parity-corpus.json`, and its
tests pin the same hashes, so the two renderers cannot drift apart silently.
When you change `spec.json`, `SETUP.md.tmpl` or the input rules:

1. `python3 config-pack/render.py --gateway https://gateway.lucairn.eu --print-golden > config-pack/golden-sha256.json`
2. `python3 config-pack/render.py --gateway https://gateway.lucairn.eu --print-corpus > /tmp/corpus.json && mv /tmp/corpus.json config-pack/parity-corpus.json`
3. `bash tests/test_config_pack.sh`
4. Copy the four files into the website (`node scripts/sync-config-pack.mjs <kit>`
   there) in the same change window, and port any input-rule change to
   `src/lib/configPack/render.ts`.

## Input rules

One set of rules, implemented in `render.py` and in the website's
`render.ts`; `parity-corpus.json` pins every decision below with a test case
on both sides.

Gateway URL (`--gateway`, and the website's gateway field):

- Only a space, tab, CR or LF at either end is trimmed. Any other whitespace
  or control character (NUL, vertical tab, U+0085, no-break space, byte-order
  mark, ...) is refused wherever it sits. Python and JavaScript disagree on
  what "whitespace" means, so neither language's own trim is used.
- `https://` in lower case, then a host, an optional `:port` and an optional
  path. Refused: `http://`, user info (`user@`, `user:pw@`), query (`?`),
  fragment (`#`), percent-encoding (`%`), backslashes, quotes, angle brackets,
  spaces and every non-ASCII character.
- Host: ASCII letters, digits and hyphens in dot-separated labels of 1-63
  characters that don't start or end with a hyphen; 253 characters at most; no
  empty label, so no leading or trailing dot. Punycode (`xn--...`) is accepted
  as written and not decoded; a Unicode host name is refused (enter its
  punycode form). Letter case is kept as written. A host whose last label is
  a number (decimal or `0x` hex) is read as an IPv4 address by URL parsers, so
  it is accepted only as a plain dotted quad (`10.0.0.5`: four parts, 0-255,
  no leading zeros); `1.2.3`, `0x7f.1` and `2130706433` are refused. IPv6
  literals are refused.
- Port: 1-65535 without leading zeros (`:0443` is refused). An explicit
  `:443` is dropped, because it is the default.
- Path: letters, digits and `. _ ~ / -`. Trailing slashes are dropped; an
  empty, `.` or `..` segment anywhere else is refused (`/a//b`, `/a/../b`).
- Refused as well: anything shaped like a key (`lcr_live_...`, `sk-ant-...`)
  and the pack's own placeholder text.

Claude Desktop credential helper:

- macOS/Linux (`--desktop-key-helper`): an absolute path under `/Library/`,
  `/usr/local/` or `/opt/` (not `/opt/homebrew/`, `/usr/local/Homebrew/` or
  `/usr/local/Cellar/`, which belong to a user account); ASCII letters,
  digits, spaces and `_ . / + @ , = -`; no `~`, no empty, `.` or `..` segment.
- Windows (`--desktop-key-helper-windows`): `C:\Program Files\...` or
  `C:\Program Files (x86)\...` with backslashes (any letter case); no `~`,
  no forward slash, no `:` after the drive, no empty segment and no segment
  ending in a dot or space (Windows drops those, so `...` or `x.` would not
  mean what it says).
- The path rule is a coarse filter. SETUP.md tells IT that the helper file
  and its folder must be owned by root (Administrators) and not writable by
  the user.

Proxy URL (`--egress-proxy`): `http://` or `https://`, a host by the gateway
host rules, an optional port by the gateway port rules, an optional trailing
slash (dropped); no user info and no path.

Model IDs (`--models`) and the Claude Code key helper (`--key-helper`): a
fixed ASCII alphabet without quotes; anything shaped like a key is refused.

Independent of these rules, the `.reg` and `.mobileconfig` writers refuse any
control character (CR and LF included) or non-ASCII character in a value, and
the `.reg` reader in `check.py` accepts only the two escapes the format has
(`\\` and `\"`).

## Key provenance

Every key below was checked on 2026-10-02 against the raw Markdown of the
vendor's docs (not a summary), and `check.py` re-checks it against
`docs-keys-snapshot.json` on every test run.

Claude Code, `managed-settings.json`
([settings reference](https://code.claude.com/docs/en/settings-reference),
[environment variables](https://code.claude.com/docs/en/env-vars),
[mods admin](https://code.claude.com/docs/en/plugins/mods/admin)):

| Key | Value | Source |
| - | - | - |
| `env.ANTHROPIC_BASE_URL` | gateway URL | env-vars; pinned by `allowedProviders` (llm-gateway) |
| `env.ANTHROPIC_CUSTOM_HEADERS` | `x-lucairn-require-added-parts-sanitized: 1` | env-vars (`Name: Value`); the header name the Lucairn gateway reads |
| `env.CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS` | `1` | env-vars |
| `env.CLAUDE_CODE_DISABLE_AUTO_MEMORY` | `1` | env-vars |
| `env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` | env-vars |
| `env.DISABLE_TELEMETRY` | `1` | env-vars; managed-settings "Turn telemetry off" |
| `env.DISABLE_ERROR_REPORTING` | `1` | env-vars |
| `env.DISABLE_FEEDBACK_COMMAND` | `1` | env-vars |
| `allowedProviders` | `["customEndpoint"]` | settings reference (managed, Claude Code 2.1.285+) |
| `requiredMinimumVersion` | `"2.1.285"` | settings reference (managed): "When the running version is older, Claude Code exits at startup"; the floor `allowedProviders` needs |
| `includeGitInstructions` | `false` | settings reference |
| `autoMemoryEnabled` | `false` | settings reference |
| `skipWebFetchPreflight` | `true` | settings reference |
| `disableClaudeAiConnectors` | `true` | settings reference |
| `disableAutoMode` | `"disable"` | settings reference |
| `useAutoModeDuringPlan` | `false` | settings reference |
| `permissions.defaultMode` | `"default"` | settings reference |
| `permissions.blockReadsOutsideWorkingDirectories` | `true` | settings reference (2.1.257+) |
| `permissions.deny` | `Read(...)` rules for credential paths: `~/` for home folders, `//**/` for file names | settings reference; permissions page: `//path` is an "Absolute path from filesystem root", `Read(//**/.env)` blocks "any `.env` anywhere on the filesystem", while `Read(**/.env)` only blocks "any `.env` at or under the current directory" (so not in `--add-dir` folders) |
| `allowManagedHooksOnly` | `true` | settings reference (managed) |
| `allowManagedMcpServersOnly` | `true` | settings reference (managed) |
| `allowedMcpServers` | `[]` | settings reference ("an empty array blocks every server users add") |
| `strictKnownMarketplaces` | `[]` | settings reference (managed; empty = complete lockdown) |
| `disableSideloadFlags` | `true` | settings reference (managed) |
| `pluginConfigs."cc-plugin-sec-default@builtin".options.allowManagedModsOnly` | `true` | mods admin page (the built-in guard's option) |
| `parentSettingsBehavior` | `"merge"` | settings reference (managed); Claude Desktop "Code" page recommends it when both are deployed |

Claude Desktop, `.mobileconfig` / `.reg`
([configuration reference](https://claude.com/docs/third-party/claude-desktop/configuration),
[gateway](https://claude.com/docs/third-party/claude-desktop/gateway)); every
value is written as a string, as the reference requires:

| Key | Value | Source |
| - | - | - |
| `inferenceProvider` | `gateway` | configuration reference |
| `inferenceGatewayBaseUrl` | gateway URL | configuration reference / gateway page |
| `inferenceGatewayAuthScheme` | `x-api-key` | gateway page (`bearer` or `x-api-key`); the Lucairn gateway reads a Lucairn key from `x-api-key` |
| `inferenceGatewayApiKey` | `REPLACE_WITH_YOUR_LUCAIRN_KEY` | gateway page (static key); removed when a helper is given |
| `inferenceCustomHeaders` | `{"x-lucairn-require-added-parts-sanitized":"1"}` | configuration reference ("No credentials") |
| `disableDeploymentModeChooser` | `true` | configuration reference |
| `autoModeEnabled` | `false` | configuration reference; Code page |
| `blockReadsOutsideWorkingDirectories` | `true` | configuration reference |
| `skipWebFetchPreflight` | `true` | configuration reference |
| `isLocalDevMcpEnabled` | `false` | configuration reference |
| `isDesktopExtensionEnabled` | `false` | configuration reference |
| `userPluginMarketplacesEnabled` | `false` | configuration reference |
| `userPluginUploadsEnabled` | `false` | configuration reference |
| `skillCreationEnabled` | `false` | configuration reference |
| `disableEssentialTelemetry` | `true` | configuration reference; telemetry page |
| `disableNonessentialTelemetry` | `true` | configuration reference; telemetry page |
| `disableNonessentialServices` | `true` | configuration reference; telemetry page |
| `updateViaUpdatesHost` | `true` | configuration reference ("so api.anthropic.com can stay blocked") |
| optional: `inferenceCredentialKind`, `inferenceCredentialHelper`, `inferenceCredentialHelperWindows`, `inferenceModels`, `egressProxyUrl` | from flags | configuration reference |

## Left out on purpose

- **A real key anywhere**, and `apiKeyHelper` / helper paths by default: the
  credential is per user and the helper path is site-specific.
- **`inferenceModels` by default**: which model IDs a gateway routes is a
  per-deployment fact; writing a guessed list would ship a broken picker.
- **`egressProxyUrl`, OpenTelemetry (`CLAUDE_CODE_ENABLE_TELEMETRY`,
  `OTEL_EXPORTER_OTLP_*`, Desktop `otlpEndpoint`)**: site-specific endpoints; a
  placeholder would break traffic. Add them for your collector or proxy.
- **`disableAutoUpdates`** (Desktop): `updateViaUpdatesHost` keeps updates
  working while `api.anthropic.com` is blocked. Set `disableAutoUpdates` if IT
  pushes every build.
- **`allowManagedPermissionRulesOnly`**: with `parentSettingsBehavior: "merge"`
  the vendor docs say it weakens Claude Desktop's read block.
- **`strictPluginOnlyCustomization`, `allowedWorkspaceFolders`,
  `coworkEgressAllowedHosts`, `disabledBuiltinTools`,
  `permissions.disableBypassPermissionsMode`**: organisation-specific
  hardening; deny rules and the read block already apply in every mode.
- **`forceLoginMethod` / `forceLoginOrgUUID` / `forceLoginGatewayUrl`**: the
  vendor docs say they block gateway credentials at startup. `check.py`
  refuses them.

## What is verified, and what is not yet

Verified:

- Every key name against the raw vendor docs (snapshot, 2026-10-02).
- Syntax: JSON (no duplicate keys at any level), property list (`plistlib`,
  duplicate keys from the raw XML, `plutil -lint` on macOS), `.reg` (header,
  CRLF, ASCII, strict escaping, one policy key, no duplicate value name in any
  letter case).
- Policy values: every setting the pack depends on is present, nested where
  the vendor documents it and set to the right value and type (a string
  `"false"` is not the boolean `false`); the require header appears exactly
  once with value `1` in both tools. Each of these checks has a test that
  weakens the pack and expects the check to fail.
- Input rules: `parity-corpus.json` (14 accepted URLs with file hashes, 59
  refused) on both renderers.
- Claude Code 2.1.284 against a localhost recording stub, isolated home,
  dummy key, the rendered settings passed as a settings file: the request
  carried `x-lucairn-require-added-parts-sanitized: 1` and the key in
  `x-api-key`; no git status block (the baseline run without the settings
  carried the branch name and the latest commit subject); and with
  `--permission-mode auto` forced, no `safeguards` field (the baseline
  auto-mode run had it).
  Managed-only keys (`allowedProviders` and the locks) can't be exercised
  without writing to a system path, so they were not run live.

Not yet verified (planned: a measurement on a separate macOS user account):

- Claude Desktop accepting the profile and showing only the gateway sign-in.
- `inferenceGatewayBaseUrl` as a bare origin. The vendor docs show both a
  bare origin and a `/v1` form; the pack uses the bare origin so it equals
  Claude Code's `ANTHROPIC_BASE_URL`, which `allowedProviders` compares
  exactly in the desktop app's Code tab.
- `allowedProviders` refusing a non-gateway session on a managed machine.
