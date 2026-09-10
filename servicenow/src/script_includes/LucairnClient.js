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
 *   4. DIAGNOSTICS ARE CONSTRUCTED, NEVER FORWARDED. `message` on a result is
 *      assembled exclusively from literals defined in THIS file plus an integer
 *      HTTP status. Exception text, transport-error text and upstream response
 *      `message` bodies are read only to CLASSIFY, and are never interpolated,
 *      concatenated or stored. Upstream `error` codes are emitted only when the
 *      value is a member of LucairnClient.API_ERROR_CODES — an allow-list of
 *      literals, not a shape rule.
 *
 *      Why: whatever an exception or an upstream body happens to contain ends
 *      up in an evidence row, and both can contain the submitted text or an
 *      Authorization value. Round-1 gate probe (specs/2026-09/
 *      gate-2026-09-10-kit-pr133-s1.md, finding 5) persisted both verbatim.
 *      There is no sanitizer for arbitrary upstream text — so none is carried.
 *   5. A NON-OK RESULT CARRIES NO UPSTREAM BODY AT ALL. `body` is null on every
 *      failure path. Rule 4 kept upstream text out of `message` while leaving
 *      the parsed body itself hanging off the result object, one
 *      JSON.stringify() away from a log line — a containment property that held
 *      only as long as nobody read the field. Round-2 gate finding N-2.
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

/* The maximum tool_name the Lucairn service accepts is 256 BYTES (Go
 * len(req.ToolName), dual-sandbox-architecture sensitive_mode.go:1294). A
 * JavaScript string length counts UTF-16 units, so 200 non-ASCII characters is
 * 200 "characters" and 400 bytes — accepted locally, rejected with HTTP 400 by
 * the service. Cap on bytes, and never split a character in half. */
LucairnClient.TOOL_NAME_MAX_BYTES = 256;

/* Hard cap on any diagnostic string this file produces. The strings are built
 * from the literals below so they are already short; the cap is the belt to the
 * braces, so a future edit cannot make a diagnostic unbounded. */
LucairnClient.MAX_DIAGNOSTIC_CHARS = 200;

/* Stage literals. Which step of the call failed. Our own vocabulary — never
 * derived from anything the platform or the service returned. */
LucairnClient.STAGE = {
    BUILD: 'request_build',
    EXECUTE: 'request_execute',
    READ: 'response_read',
    TRANSPORT: 'transport',
    PARSE: 'response_parse',
    STATUS: 'http_status'
};

/* Canonical reasons. A failure is labelled with ONE of these; the upstream text
 * that led to the label is discarded. Extending this list is how a new
 * diagnostic gets added — never by forwarding a message. */
LucairnClient.REASON = {
    timeout: 'the request timed out',
    connection_refused: 'the connection was refused or the host did not resolve',
    http_error: 'the service returned a non-success status',
    contract_error: 'the response body was not the documented JSON shape',
    unknown: 'no recognised diagnostic marker'
};

/* Allow-list of Lucairn service error codes that may be echoed into an evidence
 * row. Sourced from the live handlers (dual-sandbox-architecture
 * sensitive_mode.go + errors.go). A code outside this list is reported as
 * 'unrecognised_error_code' — the value itself is dropped, because an
 * unrecognised code is exactly the case where we cannot vouch for its content. */
LucairnClient.API_ERROR_CODES = [
    'audit_evidence_unavailable',
    'cert_id_partial_not_found',
    'cert_signing_unavailable',
    'customer_placeholder_cap_exceeded',
    'empty_context',
    'entitlement_mismatch',
    'inference_service_unavailable',
    'invalid_api_key',
    'invalid_field',
    'invalid_input',
    'invalid_json',
    'license_expired',
    'method_not_allowed',
    'missing_api_key',
    'missing_field',
    'passthrough_pii_detected',
    'placeholder_cache_full',
    'placeholder_map_id_not_found',
    'quota_exceeded',
    'rate_limit_exceeded',
    'registration_limit',
    'request_too_large',
    'sanitizer_rejected',
    'sanitizer_unavailable',
    'tier_insufficient',
    'token_service_unavailable',
    'too_many_identity_fields',
    'unsupported_media_type',
    'usage_service_unavailable',
    'veil_evidence_unavailable'
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
            body.tool_name = LucairnClient.capUtf8Bytes(
                String(args.toolName), LucairnClient.TOOL_NAME_MAX_BYTES);
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
            return this._transportFailure(e, started, LucairnClient.STAGE.BUILD);
        }

        var response;
        try {
            msg.setRequestBody(JSON.stringify(body));
            response = msg.execute();
        } catch (e) {
            /* RESTMessageV2 raises for connection-level problems on some
             * releases and returns an error-flagged response on others. Both
             * paths land on a non-ok result. */
            return this._transportFailure(e, started, LucairnClient.STAGE.EXECUTE);
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
            return this._result(false, status, null, raw, this._classify(this._peek(e)),
                durationMs, LucairnClient.STAGE.READ, '');
        }

        /* Transport-error inspection.
         *
         * hadTransportError is set from haveError() and is NEVER cleared by a
         * later failure. Round-1 gate finding 4: a throwing getErrorMessage()
         * used to reset the flag, so a known-failed transport carrying a 200
         * proceeded as covered. Diagnostic failure is itself a failure now:
         * `inspectionFailed` fails the call closed on its own. */
        var hadTransportError = false;
        var inspectionFailed = false;
        var transportText = '';

        try {
            if (response.haveError) {
                hadTransportError = (response.haveError() === true);
            }
            /* haveError() absent is not evidence of success — it is absent on
             * some releases. The status code decides below. */
        } catch (e) {
            inspectionFailed = true;
        }

        if (hadTransportError) {
            try {
                transportText = response.getErrorMessage ? String(response.getErrorMessage()) : '';
            } catch (e) {
                /* We know the transport failed; we just cannot say why. The
                 * flag stands and the class degrades to 'unknown'. */
                transportText = '';
                inspectionFailed = true;
            }
        }

        if (hadTransportError || inspectionFailed || status === 0) {
            return this._result(false, status, null, raw,
                this._classify(transportText), durationMs,
                LucairnClient.STAGE.TRANSPORT, '');
        }

        var parsed = null;
        try {
            parsed = raw ? JSON.parse(raw) : null;
        } catch (e) {
            return this._result(false, status, null, raw, 'contract_error', durationMs,
                LucairnClient.STAGE.PARSE, '');
        }

        if (status < 200 || status > 299) {
            return this._result(false, status, parsed, raw, 'http_error', durationMs,
                LucairnClient.STAGE.STATUS, this._safeApiCode(parsed));
        }

        return this._result(true, status, parsed, raw, 'none', durationMs, '', '');
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

    _transportFailure: function (e, started, stage) {
        return this._result(false, 0, null, '', this._classify(this._peek(e)),
            this._now() - started, stage, '');
    },

    /**
     * Read an exception's text for CLASSIFICATION ONLY. The return value of this
     * function must never reach a result object, a log line or an evidence row —
     * it is fed to _classify() and discarded. Kept as a named function so that
     * "who touches raw exception text" is one grep.
     */
    _peek: function (e) {
        try {
            if (e === null || e === undefined) {
                return '';
            }
            return (e.message !== undefined && e.message !== null) ? String(e.message) : String(e);
        } catch (inner) {
            return '';
        }
    },

    /**
     * Label a transport error. Diagnostic only — see rule 3 in the header.
     * Timeout is checked FIRST because a timeout message can also mention
     * "connection", and a mislabelled timeout is the more confusing of the two
     * when reading an evidence row.
     *
     * Takes text; returns one of a fixed set of labels. Nothing of the input
     * survives into the output.
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

    /**
     * The ONE place an upstream-supplied string may become part of a
     * diagnostic — and only when it is character-for-character a member of the
     * allow-list. Anything else is replaced, not truncated: a value we do not
     * recognise is precisely the value we cannot vouch for.
     *
     * @returns {string} an allow-listed code, or 'unrecognised_error_code'
     */
    _safeApiCode: function (parsed) {
        var candidate;
        try {
            candidate = (parsed && parsed.error !== undefined && parsed.error !== null)
                ? String(parsed.error) : '';
        } catch (e) {
            return 'unrecognised_error_code';
        }
        if (!candidate) {
            return 'no_error_code';
        }
        for (var i = 0; i < LucairnClient.API_ERROR_CODES.length; i++) {
            if (LucairnClient.API_ERROR_CODES[i] === candidate) {
                return candidate;
            }
        }
        return 'unrecognised_error_code';
    },

    /**
     * Build the diagnostic string stored on an evidence row.
     *
     * Every component is a literal from this file plus an integer. There is no
     * code path by which submitted text, sanitized text, an Authorization value
     * or an exception body can appear in the output — that is the property the
     * canary test in test/client.test.js asserts.
     */
    _diagnostic: function (failureClass, status, stage, apiCode) {
        var parts = [];
        parts.push('class=' + (LucairnClient.REASON[failureClass] ? failureClass : 'unknown'));
        parts.push('http=' + (parseInt(status, 10) || 0));
        if (stage) {
            parts.push('stage=' + stage);
        }
        if (apiCode) {
            parts.push('code=' + apiCode);
        }
        parts.push('reason=' + (LucairnClient.REASON[failureClass] || LucairnClient.REASON.unknown));
        var out = 'Lucairn service call failed: ' + parts.join(' ');
        return out.length > LucairnClient.MAX_DIAGNOSTIC_CHARS
            ? out.substring(0, LucairnClient.MAX_DIAGNOSTIC_CHARS)
            : out;
    },

    _result: function (ok, status, body, raw, failureClass, durationMs, stage, apiCode) {
        var isOk = ok === true;
        return {
            ok: isOk,
            status: status,
            /* CONTAINMENT IS STRUCTURAL, not a matter of what callers happen to
             * read. On a failure the parsed upstream body is dropped here, after
             * classification has taken the one thing it may take — an
             * allow-listed error code. An upstream error body can quote the
             * request it rejected and the Authorization header it rejected it
             * with; while it rode along on the result object, every caller,
             * logger and future edit was one JSON.stringify away from persisting
             * both. Rule 4 said diagnostics are never forwarded; this makes the
             * whole result obey it. Round-2 gate finding N-2.
             *
             * `rawLength` survives because a length is not content and is the
             * only thing anyone actually debugged with. */
            body: isOk ? body : null,
            rawLength: String(raw || '').length,
            failureClass: isOk ? 'none' : failureClass,
            durationMs: durationMs,
            /* Typed, bounded, allow-listed. Safe to persist verbatim. */
            stage: isOk ? '' : String(stage || ''),
            apiCode: isOk ? '' : String(apiCode || ''),
            message: isOk ? '' : this._diagnostic(failureClass, status, stage, apiCode)
        };
    },

    type: 'LucairnClient'
};

/**
 * Truncate `s` so its UTF-8 encoding is at most `maxBytes`, without splitting a
 * character (or a surrogate pair) in half.
 *
 * ES5 has no TextEncoder, so the byte width is computed per code point from the
 * UTF-8 encoding rules directly.
 *
 * @param {string} s
 * @param {number} maxBytes
 * @returns {string}
 */
LucairnClient.capUtf8Bytes = function (s, maxBytes) {
    var str = String(s === null || s === undefined ? '' : s);
    var limit = parseInt(maxBytes, 10);
    if (isNaN(limit) || limit <= 0) {
        return '';
    }

    var bytes = 0;
    var i = 0;
    while (i < str.length) {
        var code = str.charCodeAt(i);
        var width = 1;
        var consumed = 1;

        if (code < 0x80) {
            width = 1;
        } else if (code < 0x800) {
            width = 2;
        } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length) {
            var low = str.charCodeAt(i + 1);
            if (low >= 0xDC00 && low <= 0xDFFF) {
                /* A surrogate PAIR is one code point, four UTF-8 bytes, and two
                 * UTF-16 units. Splitting it would emit a lone surrogate. */
                width = 4;
                consumed = 2;
            } else {
                width = 3;
            }
        } else {
            width = 3;
        }

        if (bytes + width > limit) {
            break;
        }
        bytes += width;
        i += consumed;
    }
    return str.substring(0, i);
};

/**
 * UTF-8 byte length of a string. Exposed for tests and for callers that need to
 * assert a limit rather than enforce one.
 *
 * @param {string} s
 * @returns {number}
 */
LucairnClient.utf8ByteLength = function (s) {
    var str = String(s === null || s === undefined ? '' : s);
    var bytes = 0;
    var i = 0;
    while (i < str.length) {
        var code = str.charCodeAt(i);
        if (code < 0x80) {
            bytes += 1;
            i += 1;
        } else if (code < 0x800) {
            bytes += 2;
            i += 1;
        } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length &&
                   str.charCodeAt(i + 1) >= 0xDC00 && str.charCodeAt(i + 1) <= 0xDFFF) {
            bytes += 4;
            i += 2;
        } else {
            bytes += 3;
            i += 1;
        }
    }
    return bytes;
};

if (typeof module !== 'undefined' && module.exports) {
    module.exports = LucairnClient;
}
