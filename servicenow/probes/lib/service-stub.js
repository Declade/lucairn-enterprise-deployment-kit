'use strict';

/*
 * Lifecycle for the documented-shape Lucairn service stub.
 *
 * WHAT IT IS
 * ----------
 * A stand-in for the CONTRACT in ../../README.md § Wire contract — which in
 * turn cites the live handlers by repository, file and line. It is not a model
 * of the service: it substitutes configured literal spans for placeholders so a
 * probe can ask "did the canary survive?", and it honours the documented
 * one-shot claim on `cert_id_partial`.
 *
 * WHAT IT IS NOT
 * --------------
 * It is not evidence about the real service, and a probe passing against it is
 * not evidence about a ServiceNow instance. **Instance validation pending.**
 *
 * The server runs in its own process (see ./service-stub-server.js for why that
 * is forced rather than chosen), so everything here is lifecycle plus two
 * control calls.
 *
 * Connection REFUSAL is deliberately NOT a knob: it is produced by pointing the
 * client at a port nothing listens on (closedPort()), which is a real
 * ECONNREFUSED rather than a simulated one.
 */

const net = require('node:net');
const path = require('node:path');
const { spawn } = require('node:child_process');

const { syncRequest } = require('./sync-http');

const SERVER = path.join(__dirname, 'service-stub-server.js');

/**
 * Bind a port, learn its number, release it. Nothing listens there afterwards,
 * so a connection attempt is genuinely refused.
 *
 * @returns {Promise<number>}
 */
function closedPort() {
    return new Promise((resolve, reject) => {
        const srv = net.createServer();
        srv.on('error', reject);
        srv.listen(0, '127.0.0.1', () => {
            const port = srv.address().port;
            srv.close(() => resolve(port));
        });
    });
}

/**
 * @param {object} [opts]
 * @param {number} [opts.delayMs]  answer this late (produces a real read timeout)
 * @param {Array<[string,string]>} [opts.redactions] literal -> placeholder
 * @param {number} [opts.sanitizeStatus] @param {object} [opts.sanitizeBody]
 * @param {number} [opts.sealStatus]     @param {object} [opts.sealBody]
 * @returns {Promise<{url: string, requestCount: function(): number,
 *                    requests: function(): object[], close: function(): Promise<void>}>}
 */
function startServiceStub(opts) {
    opts = opts || {};
    return new Promise((resolve, reject) => {
        const child = spawn(process.execPath, [SERVER, JSON.stringify(opts)], {
            stdio: ['ignore', 'pipe', 'pipe']
        });

        let buffered = '';
        let settled = false;
        const fail = (e) => {
            if (settled) { return; }
            settled = true;
            try { child.kill('SIGKILL'); } catch (ignored) { /* already gone */ }
            reject(e instanceof Error ? e : new Error(String(e)));
        };

        child.on('error', fail);
        child.stderr.setEncoding('utf8');
        child.stderr.on('data', (d) => { buffered += d; });
        child.stdout.setEncoding('utf8');
        child.stdout.on('data', (d) => {
            buffered += d;
            const m = /PORT=(\d+)/.exec(buffered);
            if (!m || settled) { return; }
            settled = true;
            const url = 'http://127.0.0.1:' + m[1];

            /* TELEMETRY UNAVAILABILITY IS A FAILURE, LOUDLY.
             *
             * This used to return [] when the control call failed or came back
             * malformed. The astra gate showed what that buys: P5b asserts
             * "no seal call was made" by subtracting two counts, and with the
             * telemetry silently empty it subtracted fabricated zeros — passing
             * BOTH halves while a real seal invocation had gone through. An
             * absent measurement is not a measurement of absence. So it throws,
             * the probe's verdict becomes FAIL, and nobody reads a fabricated
             * zero as evidence.
             *
             * ROUND-2b: `ok` IS NOT A STATUS CHECK. The transport reports `ok`
             * for any response that COMPLETED — a 503 with `{"requests":[]}` is
             * a perfectly successful round trip, and the first version of this
             * guard read it as "zero traffic observed". The same fabricated
             * zero, one layer further in. So the status is checked too, and only
             * a 2xx may be read as a measurement. */
            const readRequests = () => {
                const res = syncRequest({ url: url + '/__probe/requests', method: 'GET', timeoutMs: 5000 });
                if (!res.ok) {
                    throw new Error('probe telemetry unavailable (' + (res.kind || 'unknown') + '): ' +
                        (res.error || 'no error text') + ' — a probe cannot assert absence without it');
                }
                const status = parseInt(res.status, 10);
                if (!(status >= 200 && status <= 299)) {
                    throw new Error('probe telemetry answered HTTP ' + res.status +
                        ' — a non-2xx body is not a measurement, and an empty one is not a measurement of absence');
                }
                let parsed;
                try {
                    parsed = JSON.parse(res.body);
                } catch (e) {
                    throw new Error('probe telemetry returned an unparsable body — a probe cannot assert absence without it');
                }
                if (!parsed || !Array.isArray(parsed.requests)) {
                    throw new Error('probe telemetry returned no request list — a probe cannot assert absence without it');
                }
                return parsed.requests;
            };

            resolve({
                url: url,
                requests: readRequests,
                requestCount: () => readRequests().length,
                /** How many requests reached one path. Absence per PATH, not in aggregate. */
                countPath: (p) => readRequests().filter((r) => r.path === p).length,
                close: () => new Promise((done) => {
                    child.on('exit', () => done());
                    try { child.kill('SIGKILL'); } catch (ignored) { done(); }
                })
            });
        });

        setTimeout(() => fail(new Error('the service stub did not report a port: ' + buffered)), 10000).unref();
    });
}

module.exports = { startServiceStub, closedPort };
