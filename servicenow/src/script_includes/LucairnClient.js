/*
 * LucairnClient — Script Include (Lucairn for Now Assist)
 *
 * Thin transport wrapper around sn_ws.RESTMessageV2 for the two Lucairn service
 * calls this application makes:
 *
 *   POST /api/v1/sanitize-only              -> redact the submitted fields
 *   POST /api/v1/sensitive-mode/seal-cert   -> finalise the input-shield cert
 *
 * Contract summary (full wire shapes in servicenow/README.md § Wire contract):
 *
 *   sanitize-only  request : { text, client_id? }
 *                  response: { sanitized_text, placeholder_map_id,
 *                              manifest { redaction_count, categories_triggered,
 *                                         layers_active, sanitizer_version },
 *                              cert_id_partial, expires_at }
 *   seal-cert      request : { cert_id_partial, request_content_hash,
 *                              response_content_hash, vendor, tool_name? }
 *                  response: { cert_id, cert_url, cert_tier, ... }
 *   errors         : { error, message, hint? }  (HTTP 4xx/5xx)
 *
 * Design rules in this file:
 *   1. NEVER throws to the caller. Every path returns a result object. The
 *      fail-closed decision lives in LucairnNowAssistAdapter and must not have
 *      to be wrapped in a try/catch to be correct.
 *   2. NEVER logs, returns or stores the API key, the submitted text, or the
 *      sanitized text in a diagnostic field.
 *   3. Failure classification is diagnostic only. `ok` is false for every
 *      non-2xx and every transport error, whatever the class turns out to be.
 *
 * TRANSPORT MODES (both are HYPOTHESES until the PDI run — see README
 * § Verification runbook, which is the falsifier):
 *   rest_message  Named outbound REST Message whose authentication is a
 *                 Connection & Credential alias. The platform resolves the
 *                 endpoint and injects the credential. This is the shipping
 *                 mode.
 *   endpoint      Direct setEndpoint() + an explicit `Authorization: Bearer`
 *                 header read from an encrypted property. Bring-up fallback so
 *                 the round trip can be proven before alias plumbing is
 *                 confirmed on the target release.
 *
 * ES5 only (Rhino-compatible).
 */
var LucairnClient = Class.create();

LucairnClient.PATH_SANITIZE = '/api/v1/sanitize-only';
LucairnClient.PATH_SEAL = '/api/v1/sensitive-mode/seal-cert';

/* Substrings observed in RESTMessageV2 transport errors. Used ONLY to label the
 * evidence row; see rule 3 above. */
LucairnClient.TIMEOUT_MARKERS = ['timed out', 'timeout', 'sockettimeout', 'read timed out'];
LucairnClient.REFUSED_MARKERS = [
    'connection refused', 'connect refused', 'connection reset',
    'no route to host', 'unknownhost', 'unknown host', 'name or service not known',
    'connection error', 'econnrefused'
];

LucairnClient.prototype = {

    /**
     * @param {object} cfg   resolved LucairnConfig
     * @param {object} [deps] test seam:
     *   `{ restMessage: fn(messageName, fnName)|fn(), now: fn(), log: fn() }`
     */
    initialize: function (cfg, deps) {
        deps = deps || {};
        this.cfg = cfg || {};
        this._newNamedMessage = deps.newNamedMessage || function (msgName, fnName) {
            return new sn_ws.RESTMessageV2(msgName, fnName);
        };
        this._newMessage = deps.newMessage || function () {
            return new sn_ws.RESTMessageV2();
        };
        this._now = deps.now || function () {
            return new Date().getTime();
        };
        this._log = deps.log || function (msg) {
            gs.warn('[Lucairn for Now Assist] ' + msg);
        };
    },

    /**
     * @param {string} text  content to sanitize
     * @returns {object} see _call()
     */
    sanitizeOnly: function (text) {
        var body = {
            text: String(text === null || text === undefined ? '' : text)
        };
        if (this.cfg.clientId) {
            body.client_id = this.cfg.clientId;
        }
        return this._call(this.cfg.fnSanitize, LucairnClient.PATH_SANITIZE, body);
    },

    /**
     * @param {object} args
     * @param {string} args.certIdPartial
     * @param {string} args.requestContentHash   "sha256:<64 hex>"
     * @param {string} args.responseContentHash  "sha256:<64 hex>"
     * @param {string} [args.toolName]
     * @returns {object} see _call()
     */
    sealCert: function (args) {
        var body = {
            cert_id_partial: String(args.certIdPartial || ''),
            request_content_hash: String(args.requestContentHash || ''),
            response_content_hash: String(args.responseContentHash || ''),
            vendor: String(this.cfg.vendor || '')
        };
        if (args.toolName) {
            body.tool_name = String(args.toolName).substring(0, 256);
        }
        return this._call(this.cfg.fnSeal, LucairnClient.PATH_SEAL, body);
    },

    /* ---- internals ------------------------------------------------------ */

    _call: function (fnName, path, body) {
        var started = this._now();
        var msg;

        try {
            msg = this._build(fnName, path);
        } catch (e) {
            return this._transportFailure(e, started, 'could not construct the Lucairn service request');
        }

        var response;
        try {
            msg.setRequestBody(JSON.stringify(body));
            response = msg.execute();
        } catch (e) {
            /* RESTMessageV2 raises for connection-level problems on some
             * releases and returns an error-flagged response on others. Both
             * paths land on a non-ok result. */
            return this._transportFailure(e, started, 'Lucairn service call failed');
        }

        var durationMs = this._now() - started;

        var status = 0;
        var raw = '';
        try {
            status = parseInt(response.getStatusCode(), 10);
            if (isNaN(status)) {
                status = 0;
            }
            /* Read the body exactly once. Some transports back getBody() with a
             * consumable stream, so calling it twice can return an empty
             * second read that looks like an empty response. */
            var bodyValue = response.getBody();
            raw = (bodyValue === null || bodyValue === undefined) ? '' : String(bodyValue);
        } catch (e) {
            return this._result(false, status, null, raw, this._classify(e.message), durationMs,
                'could not read the Lucairn service response');
        }

        var hadTransportError = false;
        var transportMessage = '';
        try {
            hadTransportError = (response.haveError && response.haveError() === true);
            if (hadTransportError) {
                transportMessage = String(response.getErrorMessage ? response.getErrorMessage() : 'transport error');
            }
        } catch (e) {
            /* haveError()/getErrorMessage() are not present on every release.
             * Absence is not evidence of success — status code decides below. */
            hadTransportError = false;
        }

        if (hadTransportError || status === 0) {
            return this._result(false, status, null, raw,
                this._classify(transportMessage), durationMs,
                transportMessage || 'Lucairn service unreachable');
        }

        var parsed = null;
        try {
            parsed = raw ? JSON.parse(raw) : null;
        } catch (e) {
            return this._result(false, status, null, raw, 'contract_error', durationMs,
                'Lucairn service returned a non-JSON body (HTTP ' + status + ')');
        }

        if (status < 200 || status > 299) {
            var apiCode = (parsed && parsed.error) ? String(parsed.error) : 'http_' + status;
            var apiMsg = (parsed && parsed.message) ? String(parsed.message) : 'HTTP ' + status;
            return this._result(false, status, parsed, raw, 'http_error', durationMs,
                apiCode + ': ' + apiMsg);
        }

        return this._result(true, status, parsed, raw, 'none', durationMs, '');
    },

    _build: function (fnName, path) {
        var msg;
        if (this.cfg.transport === 'endpoint') {
            msg = this._newMessage();
            msg.setHttpMethod('post');
            msg.setEndpoint(this.cfg.baseUrl + path);
            /* The Connection & Credential alias is the shipping auth path; this
             * explicit header exists only for the bring-up fallback mode. */
            msg.setRequestHeader('Authorization', 'Bearer ' + this.cfg.apiKey);
        } else {
            msg = this._newNamedMessage(this.cfg.restMessage, fnName);
        }
        msg.setRequestHeader('Content-Type', 'application/json');
        msg.setRequestHeader('Accept', 'application/json');
        msg.setHttpTimeout(this.cfg.timeoutMs);
        return msg;
    },

    _transportFailure: function (e, started, prefix) {
        var text = (e && e.message) ? String(e.message) : String(e);
        return this._result(false, 0, null, '', this._classify(text),
            this._now() - started, prefix + ': ' + text);
    },

    /**
     * Label a transport error. Diagnostic only — see rule 3 in the header.
     * Timeout is checked FIRST because a timeout message can also mention
     * "connection", and a mislabelled timeout is the more confusing of the two
     * when reading an evidence row.
     */
    _classify: function (message) {
        var m = String(message || '').toLowerCase();
        var i;
        for (i = 0; i < LucairnClient.TIMEOUT_MARKERS.length; i++) {
            if (m.indexOf(LucairnClient.TIMEOUT_MARKERS[i]) !== -1) {
                return 'timeout';
            }
        }
        for (i = 0; i < LucairnClient.REFUSED_MARKERS.length; i++) {
            if (m.indexOf(LucairnClient.REFUSED_MARKERS[i]) !== -1) {
                return 'connection_refused';
            }
        }
        return 'unknown';
    },

    _result: function (ok, status, body, raw, failureClass, durationMs, message) {
        return {
            ok: ok === true,
            status: status,
            body: body,
            rawLength: String(raw || '').length,
            failureClass: ok === true ? 'none' : failureClass,
            durationMs: durationMs,
            message: message || ''
        };
    },

    type: 'LucairnClient'
};

if (typeof module !== 'undefined' && module.exports) {
    module.exports = LucairnClient;
}
