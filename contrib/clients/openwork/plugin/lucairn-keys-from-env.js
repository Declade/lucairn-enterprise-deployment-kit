// lucairn-keys-from-env.js — OpenCode engine plugin used by the Lucairn OpenWork launchers.
//
// Why it exists: the OpenCode engine hands OpenWork's interface the provider list with every
// {env:...} value already filled in, and the interface saves that list in its browser storage
// (openwork.providerList.v1) — so a key written into the config as {env:LUCAIRN_API_KEY} ends up in
// clear text on disk (measured: 8 hits in 4 files while the desktop app runs).
//
// What it does: the generated config holds NO key, only a placeholder. On requests to the Lucairn
// gateway origin ONLY (the origin of LUCAIRN_BASE_URL, set by the launcher; a URL with a user name
// or password part never matches), it sets the two credential headers from the engine's process
// environment:
//   LUCAIRN_API_KEY -> x-api-key,  LUCAIRN_UPSTREAM_KEY -> x-upstream-key
// and forbids redirects for that request (redirect: "error"): fetch drops only Authorization /
// Cookie on a cross-origin redirect, these custom headers would be sent on to wherever the answer
// points. A redirect therefore fails the request (fail closed) instead of carrying the keys.
// Nothing else in any request is read or changed. No log, no file.
let installed = false;

function gatewayOrigin() {
  try {
    return new URL(process.env.LUCAIRN_BASE_URL || "").origin;
  } catch {
    return null;
  }
}

function install() {
  if (installed) return;
  installed = true;
  const origin = gatewayOrigin();
  if (!origin || origin === "null") return;
  const base = globalThis.fetch;
  const patched = async (input, init) => {
    let nextInit = init;
    try {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      const target = new URL(url);
      if (target.origin === origin && !target.username && !target.password) {
        const headers = new Headers(init?.headers ?? (typeof input === "object" && "headers" in input ? input.headers : undefined));
        if (process.env.LUCAIRN_API_KEY) headers.set("x-api-key", process.env.LUCAIRN_API_KEY);
        if (process.env.LUCAIRN_UPSTREAM_KEY) headers.set("x-upstream-key", process.env.LUCAIRN_UPSTREAM_KEY);
        nextInit = { ...(init ?? {}), headers, redirect: "error" };
      }
    } catch {
      nextInit = init;
    }
    return base(input, nextInit);
  };
  globalThis.fetch = Object.assign(patched, base);
}

export const LucairnKeysFromEnv = async () => {
  install();
  return {};
};
