'use strict';

/*
 * Synchronous HTTP for the probe kit, plus the RESTMessageV2 shim built on it.
 *
 * The shim exposes exactly the surface LucairnClient uses — setHttpMethod,
 * setEndpoint, setRequestHeader, setHttpTimeout, setRequestBody, execute, and
 * on the response getStatusCode / getBody / haveError / getErrorMessage /
 * getErrorCode. Nothing else. A source that reaches for a platform API this
 * shim does not have will fail loudly, which is how we find out we depended on
 * something we never verified.
 *
 * TWO TRANSPORT-ERROR MODES, because the platform has two
 * -------------------------------------------------------
 * LucairnClient's header records that RESTMessageV2 "raises for connection-level
 * problems on some releases and returns an error-flagged response on others".
 * Both are unverified on the target release, so the probe kit drives BOTH:
 *
 *   errorMode: 'throw' — execute() raises, like the releases that raise
 *   errorMode: 'flag'  — execute() returns a response whose haveError() is true
 *
 * A fault probe that only exercised one mode would have tested one release
 * family's behaviour and reported it as the adapter's.
 */

const path = require('node:path');
const { execFileSync } = require('node:child_process');

const WORKER = path.join(__dirname, 'sync-http-worker.js');

/**
 * One blocking HTTP round trip.
 *
 * @param {object} req `{ url, method, headers, body, timeoutMs }`
 * @returns {{ok: boolean, status?: number, body?: string, error?: string}}
 */
function syncRequest(req) {
    const budget = parseInt(req.timeoutMs, 10) > 0 ? parseInt(req.timeoutMs, 10) : 45000;
    let stdout;
    try {
        stdout = execFileSync(process.execPath, [WORKER], {
            input: JSON.stringify(req),
            encoding: 'utf8',
            /* The worker enforces the request budget itself; this is only the
             * backstop for a worker that never returns at all. */
            timeout: budget + 15000,
            maxBuffer: 8 * 1024 * 1024
        });
    } catch (workerFailed) {
        /* kind: 'worker' — THE HARNESS BROKE, not the peer. The astra gate
         * reproduced a worker-startup failure being counted as a caught
         * connection refusal: the adapter classified the resulting text as a
         * transport failure and blocked, which is what the probe was looking
         * for. A broken harness must never be able to score as a caught fault,
         * so the distinction is structural and the probes assert on it. */
        return {
            ok: false,
            kind: 'worker',
            error: 'probe transport worker failed: ' + String((workerFailed && workerFailed.message) || workerFailed)
        };
    }
    try {
        const parsed = JSON.parse(stdout);
        if (!parsed || typeof parsed !== 'object' || typeof parsed.kind !== 'string') {
            return { ok: false, kind: 'worker', error: 'probe transport worker returned a result with no provenance' };
        }
        return parsed;
    } catch (unparsable) {
        return { ok: false, kind: 'worker', error: 'probe transport worker returned an unparsable result' };
    }
}

/**
 * A RESTMessageV2 stand-in that performs REAL requests.
 *
 * Covers BOTH construction forms LucairnClient uses:
 *   new sn_ws.RESTMessageV2()                      — endpoint mode, the caller
 *                                                    sets the endpoint itself
 *   new sn_ws.RESTMessageV2(messageName, fnName)   — the shipping mode, where
 *                                                    the REST Message RECORD
 *                                                    holds the endpoint and the
 *                                                    script never sees a URL
 * The `functions` map stands in for that record: function name -> path. Without
 * it a named-message probe would have to reach for setEndpoint, which the
 * shipping path never calls — and the probe would then be exercising the
 * bring-up fallback while claiming to exercise the shipping transport.
 *
 * @param {object} opts
 * @param {string} [opts.errorMode] 'throw' (default) or 'flag'
 * @param {string} [opts.baseUrl]   base URL the stub REST Message resolves to
 * @param {object} [opts.functions] REST Message function name -> path
 * @param {object[]} [opts.calls] array the shim appends one record per call to
 * @returns {function(string=, string=): object} a factory suitable for
 *   LucairnClient's `newMessage` / `newNamedMessage` seams
 */
function restMessageFactory(opts) {
    opts = opts || {};
    const errorMode = opts.errorMode === 'flag' ? 'flag' : 'throw';
    const calls = opts.calls || [];
    const functions = opts.functions || {};

    return function newMessage(messageName, fnName) {
        const preset = (fnName && Object.prototype.hasOwnProperty.call(functions, fnName))
            ? String(opts.baseUrl || '') + functions[fnName]
            : '';
        const state = { method: 'post', endpoint: preset, headers: {}, timeoutMs: 45000, body: '' };

        return {
            setHttpMethod: function (m) { state.method = m; },
            setEndpoint: function (e) { state.endpoint = e; },
            setRequestHeader: function (k, v) { state.headers[k] = v; },
            /* RESTMessageV2.setHttpTimeout takes MILLISECONDS on the platform;
             * the adapter passes cfg.timeoutMs straight through, so the shim
             * reads it the same way. */
            setHttpTimeout: function (t) { state.timeoutMs = t; },
            setRequestBody: function (b) { state.body = b; },
            execute: function () {
                const res = syncRequest({
                    url: state.endpoint,
                    method: (state.method || 'post').toUpperCase(),
                    headers: state.headers,
                    body: state.body,
                    timeoutMs: state.timeoutMs
                });
                calls.push({ endpoint: state.endpoint, body: state.body, result: res });

                if (!res.ok) {
                    if (errorMode === 'throw') {
                        throw new Error(res.error || 'transport failure');
                    }
                    return {
                        getStatusCode: function () { return 0; },
                        getBody: function () { return ''; },
                        haveError: function () { return true; },
                        getErrorMessage: function () { return res.error || 'transport failure'; },
                        getErrorCode: function () { return '1'; }
                    };
                }

                return {
                    getStatusCode: function () { return res.status; },
                    getBody: function () { return res.body; },
                    haveError: function () { return false; },
                    getErrorMessage: function () { return ''; },
                    getErrorCode: function () { return '0'; }
                };
            }
        };
    };
}

module.exports = { syncRequest, restMessageFactory };
