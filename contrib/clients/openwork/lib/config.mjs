// config.mjs <out.json> <plugin-dir> [files] [model=<id>] [mcp=<config.json>]
// Writes the OpenCode engine config for the Lucairn OpenWork launchers. No secret is written:
// the API key field holds a placeholder and plugin/lucairn-keys-from-env.js adds both keys
// from the engine's environment on gateway requests only.
//   files          allow the engine's own file tools (read, edit = read, write, edit) in the work folder.
//                  No shell, no web, no glob (glob downloads ripgrep from github.com on first use).
//   model=<id>     claude-haiku-4-5 (default) or claude-sonnet-5-5
//   mcp=<file>     merge {"mcp": {...}, "allow": ["tool_name", ...]} from a JSON file you write
//                  (e.g. a ServiceNow MCP server); only the listed tools are allowed.
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const [out, pluginDir, ...rest] = process.argv.slice(2);
if (!out || !pluginDir) {
  console.error("usage: config.mjs <out.json> <plugin-dir> [files] [model=<id>] [mcp=<file>]");
  process.exit(2);
}
const flags = new Set(rest.filter((a) => !a.includes("=")));
const kv = Object.fromEntries(rest.filter((a) => a.includes("=")).map((a) => [a.slice(0, a.indexOf("=")), a.slice(a.indexOf("=") + 1)]));
const model = kv.model || "claude-haiku-4-5";
const MODELS = {
  "claude-haiku-4-5": { name: "Claude Haiku 4.5 via Lucairn", limit: { context: 200000, output: 8192 } },
  "claude-sonnet-5-5": { name: "Claude Sonnet 5.5 via Lucairn", limit: { context: 200000, output: 8192 } },
};
if (!MODELS[model]) {
  console.error(`config.mjs: unknown model ${model} (use ${Object.keys(MODELS).join(" or ")})`);
  process.exit(2);
}
const cfg = {
  $schema: "https://opencode.ai/config.json",
  provider: {
    lucairn: {
      npm: "@ai-sdk/anthropic",
      name: "Lucairn (Anthropic lane)",
      options: { baseURL: "{env:LUCAIRN_BASE_URL}", apiKey: "not-a-key-set-by-lucairn-keys-from-env" },
      models: MODELS,
    },
  },
  model: "lucairn/" + model,
  small_model: "lucairn/claude-haiku-4-5",
  enabled_providers: ["lucairn"],
  share: "disabled",
  autoupdate: false,
  permission: { "*": "deny" },
  agent: { title: { disable: true } },
  plugin: ["file://" + pluginDir + "/lucairn-keys-from-env.js"],
  // Standing text in every system prompt: the engine's `skill` tool cannot be removed (lucairn-rules.md stops
  // the wasted calls, measured), and the gateway's placeholders must not make the model redo tool calls.
  instructions: [pluginDir + "/lucairn-rules.md", resolve(pluginDir, "..", "..", "lib", "placeholder-rule.md")],
};
if (flags.has("files")) for (const t of ["read", "edit"]) cfg.permission[t] = "allow";
if (kv.mcp) {
  const extra = JSON.parse(readFileSync(kv.mcp, "utf8"));
  cfg.mcp = extra.mcp || {};
  for (const t of extra.allow || []) cfg.permission[t] = "allow";
}
writeFileSync(out, JSON.stringify(cfg, null, 2) + "\n", { mode: 0o600 });
