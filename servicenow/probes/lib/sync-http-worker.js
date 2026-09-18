'use strict';

/*
 * One synchronous HTTP round trip, performed in a CHILD process.
 *
 * WHY A CHILD PROCESS
 * -------------------
 * `sn_ws.RESTMessageV2.execute()` is SYNCHRONOUS on the instance: the calling
 * script blocks until a response, a transport error or a timeout. Node's http
 * client is not. A probe kit that faked the call with a scripted object would
 * only ever exercise error text WE wrote — and the whole point of the probe kit
 * is to produce REAL transport faults (a genuinely refused TCP connection, a
 * genuine read timeout) and see what the adapter does with them.
 *
 * So the transport shim runs this worker with execFileSync and reads one JSON
 * line back. The request really is made, over a real socket, and the error text
 * really is the runtime's.
 *
 * ⚠️ HONESTY BOUNDARY. The error TEXT here is Node's, not the instance's Rhino
 * runtime's. The probes therefore accept on the FAIL-CLOSED OUTCOME (blocked
 * run + evidence row), and only RECORD the failure classification as
 * diagnostic — exactly the rule README § Leg 2 and § Leg 3 state for the
 * instance. A probe that asserted a classification would be asserting a
 * property of this file.
 *
 * FAULT PROVENANCE — why the failure shape is structured, not just a string
 * -------------------------------------------------------------------------
 * The adapter's failure CLASSIFICATION is diagnostic and deliberately fuzzy: it
 * matches substrings and degrades to "unknown" rather than gating a decision on
 * a guess. That is right for the adapter and useless for a probe. A probe that
 * accepted the adapter's label would call anything that failed a "refusal" —
 * including this worker failing to start, which is a broken harness rather than
 * a caught fault. The astra gate reproduced exactly that.
 *
 * So the worker reports WHAT HAPPENED AT THE SOCKET, structurally and
 * independently of any classifier: `kind` says whether a transport attempt was
 * even made, `code` carries the runtime's own errno, and `timedOut` is set only
 * by the timeout path. The probes assert on those.
 *
 * Input  (stdin, JSON): { url, method, headers, body, timeoutMs }
 * Output (stdout, JSON):
 *   { ok: true,  kind: 'transport', status, body }
 *   { ok: false, kind: 'transport', error, code, timedOut }
 *   { ok: false, kind: 'worker',    error }        — the harness broke, not the peer
 */

const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');

let request;
try {
    request = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch (parseFailed) {
    process.stdout.write(JSON.stringify({
        ok: false, kind: 'worker', error: 'probe worker could not read its request'
    }));
    process.exit(0);
}

const timeoutMs = parseInt(request.timeoutMs, 10) > 0 ? parseInt(request.timeoutMs, 10) : 45000;
const mod = String(request.url || '').indexOf('https:') === 0 ? https : http;

let settled = false;
function finish(payload) {
    if (settled) { return; }
    settled = true;
    process.stdout.write(JSON.stringify(payload));
    process.exit(0);
}

/* Set by the timeout handler ONLY. A socket error that arrives after we have
 * destroyed the request must not be able to overwrite the reason. */
let timedOut = false;

function transportError(e) {
    return {
        ok: false,
        kind: 'transport',
        error: String((e && e.message) || e),
        /* The runtime's own errno — ECONNREFUSED, ENOTFOUND, ECONNRESET. This
         * is the evidence a probe asserts on; the adapter's substring
         * classification is diagnostic and must never stand in for it. */
        code: (e && e.code) ? String(e.code) : '',
        timedOut: timedOut
    };
}

let req;
try {
    req = mod.request(String(request.url), {
        method: request.method || 'POST',
        headers: request.headers || {},
        /* The stub serves plain http; this only matters if a future probe is
         * pointed at a self-signed https stub. It never applies to a real
         * service call, because this file is not used on an instance. */
        rejectUnauthorized: false
    }, (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => { body += chunk; });
        res.on('end', () => finish({
            ok: true, kind: 'transport', status: res.statusCode, body: body
        }));
        res.on('error', (e) => finish(transportError(e)));
    });
} catch (buildFailed) {
    /* The request could not even be constructed — a malformed URL, say. That is
     * the harness, not the peer. */
    finish({ ok: false, kind: 'worker', error: String((buildFailed && buildFailed.message) || buildFailed) });
}

if (req) {
    req.setTimeout(timeoutMs, () => {
        /* A real read timeout: the socket was accepted and the peer never
         * answered inside the budget. */
        timedOut = true;
        req.destroy();
        finish({
            ok: false,
            kind: 'transport',
            error: 'the request timed out after ' + timeoutMs + ' ms',
            code: 'ETIMEDOUT',
            timedOut: true
        });
    });
    req.on('error', (e) => finish(transportError(e)));
    req.end(request.body === undefined || request.body === null ? '' : String(request.body));
}
