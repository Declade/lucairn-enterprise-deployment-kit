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
 * Input  (stdin, JSON): { url, method, headers, body, timeoutMs }
 * Output (stdout, JSON): { ok: true, status, body } | { ok: false, error }
 */

const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');

let request;
try {
    request = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch (parseFailed) {
    process.stdout.write(JSON.stringify({ ok: false, error: 'probe worker could not read its request' }));
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
        res.on('end', () => finish({ ok: true, status: res.statusCode, body: body }));
        res.on('error', (e) => finish({ ok: false, error: String((e && e.message) || e) }));
    });
} catch (buildFailed) {
    finish({ ok: false, error: String((buildFailed && buildFailed.message) || buildFailed) });
}

if (req) {
    req.setTimeout(timeoutMs, () => {
        /* A real read timeout: the socket was accepted and the peer never
         * answered inside the budget. */
        req.destroy();
        finish({ ok: false, error: 'the request timed out after ' + timeoutMs + ' ms' });
    });
    req.on('error', (e) => finish({ ok: false, error: String((e && e.message) || e) }));
    req.end(request.body === undefined || request.body === null ? '' : String(request.body));
}
