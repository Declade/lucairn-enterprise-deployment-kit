# Config pack: Claude Code and Claude Desktop through the Lucairn gateway

Managed settings for Claude Code and Claude Desktop (third-party inference
mode) that point both tools' model requests at your Lucairn gateway and switch
off the features listed in `SETUP.md.tmpl`. Claude Code's `allowedProviders`
key makes it refuse sessions pointed anywhere else (vendor docs; not yet
exercised on a managed machine, see the end of this file).

```bash
bin/lucairn config-pack --gateway https://gateway.example.com --output ./config-pack-out
```

Output (rendered, then checked before the command reports success):

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
| `--desktop-key-helper PATH` / `--desktop-key-helper-windows PATH` | Claude Desktop `inferenceCredentialKind=helper-script` + `inferenceCredentialHelper` / `inferenceCredentialHelperWindows`; removes the static key slot. |
| `--egress-proxy URL` | Claude Desktop `egressProxyUrl` (MDM only). |
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
| `check.py` | Offline validator: syntax of all three formats, every key against the docs snapshot, contract and no-secret rules, and (`--golden`) the byte pin. |
| `docs-keys-snapshot.json` | Key names extracted from the vendor's raw Markdown docs, with URL, date and page hash. |
| `snapshot_docs_keys.py` | Refreshes the snapshot from the live docs (maintainers, needs network). |
| `golden-sha256.json` | SHA-256 of the default render for `https://gateway.lucairn.eu`, plus of `spec.json` and `SETUP.md.tmpl`. |

The lucairn.eu account area (Downloads page) renders the same default pack
with a TypeScript port. It vendors `spec.json` and the setup template and pins
the same `golden-sha256.json` values, so the two renderers cannot drift apart
silently. When you change `spec.json` or `SETUP.md.tmpl`:

1. `python3 config-pack/render.py --gateway https://gateway.lucairn.eu --print-golden > config-pack/golden-sha256.json`
2. `bash tests/test_config_pack.sh`
3. Copy `spec.json`, the template and the new hashes into the website
   (`scripts/sync-config-pack.mjs` there) in the same change window.

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
| `includeGitInstructions` | `false` | settings reference |
| `autoMemoryEnabled` | `false` | settings reference |
| `skipWebFetchPreflight` | `true` | settings reference |
| `disableClaudeAiConnectors` | `true` | settings reference |
| `disableAutoMode` | `"disable"` | settings reference |
| `useAutoModeDuringPlan` | `false` | settings reference |
| `permissions.defaultMode` | `"default"` | settings reference |
| `permissions.blockReadsOutsideWorkingDirectories` | `true` | settings reference (2.1.257+) |
| `permissions.deny` | `Read(...)` rules for credential paths | settings reference; path syntax from the permissions page |
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
- **`requiredMinimumVersion`**: would also stop Claude Desktop's embedded Claude
  Code engine if it is older; SETUP.md explains how to add it safely.
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
- Syntax: JSON (no duplicate keys), property list (`plistlib`, `plutil -lint`
  on macOS), `.reg` (header, CRLF, ASCII, escaping, one policy key).
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
