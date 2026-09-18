'use strict';

/*
 * The Lucairn service stub, as its OWN PROCESS.
 *
 * WHY A SEPARATE PROCESS — this is not an implementation detail, it is forced
 * -------------------------------------------------------------------------
 * The adapter's transport is SYNCHRONOUS (RESTMessageV2.execute blocks), so the
 * probe kit blocks the calling process for the whole round trip. A stub server
 * living in that same process would never get to answer: its event loop is the
 * one that is blocked. The first version of this file deadlocked exactly so.
 *
 * Config arrives as one JSON argument. Two control paths exist alongside the
 * two contract paths, both under /__probe/ so they can never be confused with
 * the documented wire contract:
 *   GET  /__probe/requests  — everything the stub has received
 *   POST /__probe/shutdown  — stop
 *
 * Shapes served on the contract paths are the ones in ../../README.md
 * § Wire contract. Nothing here sanitizes anything: it substitutes configured
 * literal spans so a probe can ask whether a canary survived.
 */

const http = require('node:http');

let opts = {};
try {
    opts = JSON.parse(process.argv[2] || '{}');
} catch (e) {
    opts = {};
}

const redactions = opts.redactions || [];
const received = [];
const claimed = {};
let seq = 0;

const server = http.createServer((req, res) => {
    let raw = '';
    req.setEncoding('utf8');
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
        const send = (status, body) => {
            const payload = JSON.stringify(body);
            res.writeHead(status, {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(payload)
            });
            res.end(payload);
        };

        if (req.url === '/__probe/requests') {
            return send(200, { requests: received });
        }
        if (req.url === '/__probe/shutdown') {
            send(200, { ok: true });
            return setTimeout(() => process.exit(0), 10);
        }

        let parsed = null;
        try { parsed = raw ? JSON.parse(raw) : null; } catch (e) { parsed = null; }

        /* Recorded on ARRIVAL, before any configured delay. The timeout probe
         * asks "was the connection accepted and the request received?" — which
         * is precisely what distinguishes a read timeout (README § Leg 3a) from
         * a refusal (§ Leg 2b). Recording it after the delay would have made
         * every timed-out request look like one that never arrived. */
        received.push({ path: req.url, body: parsed, hasAuthorization: !!req.headers.authorization });

        const answer = () => {
            if (req.url === '/api/v1/sanitize-only') {
                if (opts.sanitizeStatus && opts.sanitizeStatus !== 200) {
                    return send(opts.sanitizeStatus, opts.sanitizeBody ||
                        { error: 'sanitizer_unavailable', message: 'stubbed failure', hint: 'probe kit' });
                }
                if (opts.sanitizeBody) { return send(200, opts.sanitizeBody); }

                const text = (parsed && typeof parsed.text === 'string') ? parsed.text : '';
                let sanitized = text;
                const counts = {};
                redactions.forEach((pair) => {
                    const literal = pair[0];
                    const placeholder = pair[1];
                    if (sanitized.indexOf(literal) !== -1) {
                        const hits = sanitized.split(literal).length - 1;
                        sanitized = sanitized.split(literal).join(placeholder);
                        const key = placeholder.replace(/[^A-Za-z_]/g, '').toLowerCase() || 'other';
                        counts[key] = (counts[key] || 0) + hits;
                    }
                });
                seq += 1;
                return send(200, {
                    sanitized_text: sanitized,
                    placeholder_map_id: 'pmap_probe' + seq,
                    manifest: {
                        redaction_count: counts,
                        categories_triggered: Object.keys(counts),
                        layers_active: ['probe_stub'],
                        sanitizer_version: 'documented-shape-stub'
                    },
                    cert_id_partial: 'cert_partial_probe' + seq,
                    expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString()
                });
            }

            if (req.url === '/api/v1/sensitive-mode/seal-cert') {
                if (opts.sealStatus && opts.sealStatus !== 200) {
                    return send(opts.sealStatus, opts.sealBody ||
                        { error: 'cert_signing_unavailable', message: 'stubbed failure' });
                }
                if (opts.sealBody) { return send(200, opts.sealBody); }

                const partial = (parsed && parsed.cert_id_partial) || '';
                /* One-shot, as documented: the first seal call claims the
                 * partial and a second returns 404. A probe must not be able to
                 * lean on a retry the service does not allow. */
                if (!partial || claimed[partial]) {
                    return send(404, { error: 'cert_id_partial_not_found', message: 'already claimed or unknown' });
                }
                claimed[partial] = true;
                return send(200, {
                    cert_id: 'cert_probe_' + partial,
                    cert_url: 'https://lucairn.example.test/verify?id=req_' + partial,
                    cert_tier: 'input-shield'
                });
            }

            return send(404, { error: 'invalid_input', message: 'unknown path' });
        };

        if (opts.delayMs) { setTimeout(answer, opts.delayMs); } else { answer(); }
    });
});

server.listen(0, '127.0.0.1', () => {
    process.stdout.write('PORT=' + server.address().port + '\n');
});
