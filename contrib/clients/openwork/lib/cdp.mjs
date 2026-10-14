// cdp.mjs <port> eval <js-expression> | text — minimal Chrome DevTools Protocol client for the OpenWork
// desktop app's local debug port (127.0.0.1 only). Used by desktop.sh to preselect the Lucairn model
// (no config setting exists for it) and to check the window shows it. Needs Node with a global WebSocket.
const [port, cmd, arg] = process.argv.slice(2);
const targets = await (await fetch(`http://127.0.0.1:${port}/json`, { signal: AbortSignal.timeout(5000) })).json();
const page =
  targets.find((t) => t.type === "page" && !t.url.startsWith("devtools://") && /localhost|127\.0\.0\.1|file:|app:/.test(t.url)) ??
  targets.find((t) => t.type === "page");
if (!page) {
  console.error("no page target");
  process.exit(2);
}
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 0;
const pending = new Map();
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) {
    const { res, rej } = pending.get(m.id);
    pending.delete(m.id);
    m.error ? rej(new Error(m.error.message)) : res(m.result);
  }
};
const send = (method, params = {}) => new Promise((res, rej) => {
  const i = ++id;
  pending.set(i, { res, rej });
  ws.send(JSON.stringify({ id: i, method, params }));
  setTimeout(() => { if (pending.has(i)) { pending.delete(i); rej(new Error("cdp timeout " + method)); } }, 20000);
});
const evaluate = async (expression) => {
  const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
};
let rc = 0;
try {
  if (cmd === "eval") console.log(JSON.stringify(await evaluate(arg)));
  else if (cmd === "text") console.log(String(await evaluate("document.body.innerText")).slice(0, 4000));
  else { console.error("usage: cdp.mjs <port> eval <js> | text"); rc = 2; }
} catch (e) {
  console.error(String(e.message || e));
  rc = 1;
} finally {
  ws.close();
}
process.exit(rc);
