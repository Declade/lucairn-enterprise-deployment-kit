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

            const readRequests = () => {
                const res = syncRequest({ url: url + '/__probe/requests', method: 'GET', timeoutMs: 5000 });
                if (!res.ok) { return []; }
                try { return JSON.parse(res.body).requests || []; } catch (e) { return []; }
            };

            resolve({
                url: url,
                requests: readRequests,
                requestCount: () => readRequests().length,
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
