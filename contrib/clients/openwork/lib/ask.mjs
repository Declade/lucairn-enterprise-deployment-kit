// ask.mjs — send one or more messages in ONE chat through a running OpenWork host (openwork.sh ask).
// Input (environment, set by openwork.sh): OW_URL (host address), OW_TOKENS (its web-tokens.json),
// OW_MODEL (lucairn/<model>), OW_CONTINUE=1 (continue the most recent chat), OW_LIST=1 (list chats only),
// OW_TURN_TIMEOUT_MS (default 600000). Arguments: the messages.
// Prints each answer; exit 0 when every message completed without a client error, 1 otherwise.
import { readFile } from "node:fs/promises";

const base = process.env.OW_URL;
const { token } = JSON.parse(await readFile(process.env.OW_TOKENS, "utf8"));
const auth = { authorization: `Bearer ${token}`, "content-type": "application/json" };
const call = async (method, path, body, ms = 60000) => {
  const res = await fetch(base + path, { method, headers: auth, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(ms) });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: res.status, text, json };
};

const ws = await call("GET", "/workspaces");
const P = `/workspace/${ws.json.items[0].id}/opencode`;
await call("GET", `${P}/config`, undefined, 180000); // waits until the engine is up
const stored = ((await call("GET", `${P}/session`)).json ?? [])
  .map((x) => ({ id: x.id, title: x.title, updated: x.time?.updated ?? 0 }))
  .sort((a, b) => b.updated - a.updated);

if (process.env.OW_LIST === "1") {
  console.log(`stored chats: ${stored.length}`);
  for (const x of stored.slice(0, 20)) console.log(`  ${x.id} | ${x.title} | last used ${x.updated ? new Date(x.updated).toISOString() : "?"}`);
  process.exit(0);
}

let sid;
if (process.env.OW_CONTINUE === "1") {
  if (!stored.length) { console.error("no stored chat to continue"); process.exit(1); }
  sid = stored[0].id;
  console.log(`--- continuing chat ${sid}`);
} else {
  sid = (await call("POST", `${P}/session`, {})).json.id;
}

const stepsOf = async () => {
  const msgs = (await call("GET", `${P}/session/${sid}/message`)).json ?? [];
  const parts = msgs.flatMap((m) => m.parts ?? []);
  return {
    steps: parts.filter((p) => p.type === "step-start").length,
    tools: parts.filter((p) => p.type === "tool").map((p) => `${p.tool}=${p.state?.status}`),
    retries: parts.filter((p) => p.type === "retry").length,
  };
};
const [providerID, ...rest] = (process.env.OW_MODEL || "lucairn/claude-haiku-4-5").split("/");
let prev = (await stepsOf()).steps;
let ok = true;
const messages = process.argv.slice(2);
for (const [i, text] of messages.entries()) {
  const t0 = Date.now();
  const reply = await call("POST", `${P}/session/${sid}/message`, { parts: [{ type: "text", text }], model: { providerID, modelID: rest.join("/") } }, Number(process.env.OW_TURN_TIMEOUT_MS ?? 600000));
  const info = reply.json?.info ?? {};
  const err = info.error ? `${info.error.name}: ${String(info.error.data?.message ?? "").slice(0, 300)}` : reply.status !== 200 ? `HTTP ${reply.status}` : null;
  await new Promise((r) => setTimeout(r, 1500));
  const s = await stepsOf();
  console.log(`--- message ${i + 1}: ${Date.now() - t0} ms, model steps (= gateway requests): ${s.steps - prev}`);
  prev = s.steps;
  console.log((reply.json?.parts ?? []).filter((p) => p.type === "text").map((p) => p.text).join("\n") || "(no text)");
  if (err) { console.log(`--- CLIENT REPORTED AN ERROR: ${err}`); ok = false; break; }
}
const fin = await stepsOf();
if (fin.tools.length) console.log(`--- tool calls: ${fin.tools.join(", ")}`);
console.log(`--- chat ${sid} | client result: ${ok ? "clean" : "FAILED"} | retries: ${fin.retries}`);
process.exit(ok ? 0 : 1);
