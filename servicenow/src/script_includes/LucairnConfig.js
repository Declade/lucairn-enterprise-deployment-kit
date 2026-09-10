/*
 * LucairnConfig — Script Include (Lucairn for Now Assist)
 *
 * Single place that resolves runtime configuration:
 *   - transport mode + endpoints for the Lucairn service
 *   - per-skill protection policy (fail-closed by default)
 *
 * Fail-closed is the DEFAULT everywhere in this file. Every "I could not read
 * the config" path returns the SAFE value, never the permissive one:
 *   - unknown / unreadable skill policy  -> failOpen = false
 *   - missing required property          -> validate() returns an error
 *
 * ES5 only (Rhino-compatible).
 */
var LucairnConfig = Class.create();

/* ---- Property names -------------------------------------------------------
 *
 * All properties live under the application scope. Values and purpose are
 * documented in servicenow/src/records/properties.md.
 *
 * NAMING RULE: every property, table, field and label in this application calls
 * the remote side "the Lucairn service". ServiceNow ships a product of its own
 * whose name would collide here, and it points the opposite direction of
 * travel, so that word appears nowhere in this application. The guard test in
 * servicenow/test/fixtures.test.js enforces it across src/ and fixtures/.
 */
LucairnConfig.PROP = {
    /* 'rest_message' (default, uses the Connection & Credential alias) or
     * 'endpoint' (direct setEndpoint + explicit Authorization header; used
     * during PDI bring-up when alias resolution is still being proven). */
    TRANSPORT: 'lucairn.now_assist.transport',

    /* rest_message mode */
    REST_MESSAGE: 'lucairn.now_assist.rest_message_name',
    FN_SANITIZE: 'lucairn.now_assist.rest_fn_sanitize',
    FN_SEAL: 'lucairn.now_assist.rest_fn_seal',

    /* endpoint mode */
    BASE_URL: 'lucairn.now_assist.base_url',
    API_KEY: 'lucairn.now_assist.api_key',

    /* shared */
    TIMEOUT_MS: 'lucairn.now_assist.timeout_ms',
    CLIENT_ID: 'lucairn.now_assist.client_id',

    /* Provenance value sent to the Lucairn service when sealing a certificate.
     * There is NO default on purpose — see servicenow/README.md
     * § "Known gap: the vendor field". An unset value fails validation, which
     * fails closed. */
    VENDOR: 'lucairn.now_assist.vendor'
};

LucairnConfig.TABLE_SKILL_POLICY = 'x_lcrn_now_assist_skill_policy';

/* The Lucairn service accepts exactly these three vendor values on the
 * certificate-sealing call. Mirrors the server-side allow-list; a value outside
 * the set is rejected with HTTP 400, so we catch it locally first. */
LucairnConfig.ALLOWED_VENDORS = ['anthropic', 'openai', 'google'];

LucairnConfig.DEFAULTS = {
    transport: 'rest_message',
    restMessage: 'Lucairn Service',
    fnSanitize: 'sanitizeOnly',
    fnSeal: 'sealCert',
    timeoutMs: 30000,
    clientId: 'lucairn-for-now-assist'
};

LucairnConfig.prototype = {

    /**
     * @param {object} [deps] test seam. `{ getProperty: fn, glideRecord: fn, log: fn }`.
     *   In the instance runtime the defaults bind to gs.getProperty / GlideRecord / gs.warn.
     */
    initialize: function (deps) {
        deps = deps || {};
        this._getProperty = deps.getProperty || function (name, fallback) {
            return gs.getProperty(name, fallback);
        };
        this._glideRecord = deps.glideRecord || function (table) {
            return new GlideRecord(table);
        };
        this._log = deps.log || function (msg) {
            gs.warn('[Lucairn for Now Assist] ' + msg);
        };
    },

    _str: function (name, fallback) {
        var v = this._getProperty(name, fallback);
        if (v === null || v === undefined) {
            return '';
        }
        return String(v).replace(/^\s+|\s+$/g, '');
    },

    /**
     * Resolve the full configuration. NEVER returns the API key inside any
     * object that is logged or written to an evidence record — callers hand the
     * whole config to LucairnClient, which is the only consumer of `apiKey`.
     */
    resolve: function () {
        var d = LucairnConfig.DEFAULTS;
        var timeoutRaw = this._str(LucairnConfig.PROP.TIMEOUT_MS, String(d.timeoutMs));
        var timeout = parseInt(timeoutRaw, 10);
        if (isNaN(timeout) || timeout <= 0) {
            timeout = d.timeoutMs;
        }

        return {
            transport: this._str(LucairnConfig.PROP.TRANSPORT, d.transport) || d.transport,
            restMessage: this._str(LucairnConfig.PROP.REST_MESSAGE, d.restMessage) || d.restMessage,
            fnSanitize: this._str(LucairnConfig.PROP.FN_SANITIZE, d.fnSanitize) || d.fnSanitize,
            fnSeal: this._str(LucairnConfig.PROP.FN_SEAL, d.fnSeal) || d.fnSeal,
            baseUrl: this._str(LucairnConfig.PROP.BASE_URL, '').replace(/\/+$/, ''),
            apiKey: this._str(LucairnConfig.PROP.API_KEY, ''),
            timeoutMs: timeout,
            clientId: this._str(LucairnConfig.PROP.CLIENT_ID, d.clientId) || d.clientId,
            vendor: this._str(LucairnConfig.PROP.VENDOR, '').toLowerCase()
        };
    },

    /**
     * @returns {string[]} human-readable problems. Empty array = usable config.
     *   The API key value itself is never included in a message.
     */
    validate: function (cfg) {
        var problems = [];

        if (cfg.transport !== 'rest_message' && cfg.transport !== 'endpoint') {
            problems.push('transport must be "rest_message" or "endpoint" (got "' + cfg.transport + '")');
        }

        if (cfg.transport === 'rest_message') {
            if (!cfg.restMessage) {
                problems.push('rest_message_name is not set');
            }
            if (!cfg.fnSanitize || !cfg.fnSeal) {
                problems.push('rest_fn_sanitize / rest_fn_seal are not both set');
            }
        }

        if (cfg.transport === 'endpoint') {
            if (!cfg.baseUrl) {
                problems.push('base_url is not set');
            } else if (cfg.baseUrl.indexOf('https://') !== 0) {
                /* The API key travels in the Authorization header. Refusing
                 * plaintext http here is not a nicety: an http endpoint would
                 * put a live lcr_live_ key on the wire in the clear. */
                problems.push('base_url must be https');
            }
            if (!cfg.apiKey) {
                problems.push('api_key is not set');
            }
        }

        if (!cfg.vendor) {
            problems.push('vendor is not set (allowed: ' + LucairnConfig.ALLOWED_VENDORS.join(', ') + ')');
        } else if (LucairnConfig.ALLOWED_VENDORS.indexOf(cfg.vendor) === -1) {
            problems.push('vendor "' + cfg.vendor + '" is not one of: ' + LucairnConfig.ALLOWED_VENDORS.join(', '));
        }

        return problems;
    },

    /**
     * Per-skill protection policy.
     *
     * Fail-closed is the default and is what an unknown skill, an unreadable
     * table, or a thrown exception all resolve to. Only an explicitly present
     * policy row with fail_open = true (and active = true) flips a skill to
     * fail-open.
     *
     * @param {string} skillName
     * @returns {{failOpen: boolean, source: string}}
     */
    skillPolicy: function (skillName) {
        var closed = { failOpen: false, source: 'default-fail-closed' };
        var name = String(skillName || '').replace(/^\s+|\s+$/g, '');
        if (!name) {
            return closed;
        }

        try {
            var gr = this._glideRecord(LucairnConfig.TABLE_SKILL_POLICY);
            gr.addQuery('skill_name', name);
            gr.addQuery('active', true);
            gr.setLimit(1);
            gr.query();
            if (!gr.next()) {
                return closed;
            }
            var raw = gr.getValue('fail_open');
            /* GlideRecord booleans surface as '1'/'0' strings. Anything that is
             * not an explicit truthy marker stays fail-closed. */
            var failOpen = (raw === '1' || raw === 1 || raw === true || raw === 'true');
            return {
                failOpen: failOpen,
                source: failOpen ? 'policy-row-fail-open' : 'policy-row-fail-closed'
            };
        } catch (e) {
            this._log('skill policy lookup failed for "' + name + '", staying fail-closed: ' + e.message);
            return { failOpen: false, source: 'lookup-error-fail-closed' };
        }
    },

    type: 'LucairnConfig'
};

if (typeof module !== 'undefined' && module.exports) {
    module.exports = LucairnConfig;
}
