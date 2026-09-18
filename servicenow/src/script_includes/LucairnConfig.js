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
    VENDOR: 'lucairn.now_assist.vendor',

    /* Which destination the GenAI preprocessor hook publishes its sanitized
     * text to. Read by ../hooks/genai-preprocessor.js, NOT by this Script
     * Include — the hook is pasted into an extension point and cannot require a
     * Script Include just to read one string, so it carries the literal and
     * test/hook.test.js asserts the two agree. Registered here so the name has
     * one canonical home alongside every other property.
     *
     * Deliberately NOT part of resolve()/validate(): it governs the hook, not
     * the service round trip, and an adapter that refused to run because a
     * hook-only property was unset would fail closed for the wrong reason. The
     * hook does its own validation, and its unset value means the documented
     * default (`bare_output`). Round-5 gate finding: a destination LADDER can
     * verify one slot while the platform consumes another, so the destination
     * is declared rather than discovered. */
    OUTPUT_DESTINATION: 'lucairn.now_assist.output_destination'
};

LucairnConfig.TABLE_SKILL_POLICY = 'x_lcrn_now_assist_skill_policy';

/* Every field skillPolicy() depends on. If any one of them is missing from the
 * table, the lookup is not trustworthy and the policy stays fail-closed.
 *
 * Why this list exists: a scoped GlideRecord DROPS a query condition that names
 * a field the table does not have, rather than returning nothing. A policy
 * table missing `skill_name` therefore turns `addQuery('skill_name', name)`
 * into no filter at all, and the first row of the table — any skill's row,
 * possibly an inactive one — becomes the answer. Round-1 gate finding 2
 * (specs/2026-09/gate-2026-09-10-kit-pr133-s1.md) reproduced exactly that. */
LucairnConfig.POLICY_REQUIRED_FIELDS = ['skill_name', 'active', 'fail_open'];

/* The Lucairn service accepts exactly these three vendor values on the
 * certificate-sealing call. Mirrors the server-side allow-list; a value outside
 * the set is rejected with HTTP 400, so we catch it locally first. */
LucairnConfig.ALLOWED_VENDORS = ['anthropic', 'openai', 'google'];

LucairnConfig.DEFAULTS = {
    transport: 'rest_message',
    restMessage: 'Lucairn Service',
    fnSanitize: 'sanitizeOnly',
    fnSeal: 'sealCert',
    /* The Lucairn service's own request budget is 90 s and a sanitize call on
     * the heaviest layer has been measured at ~9.6 s end to end. A 30 s client
     * timeout could therefore abandon a call the service was still going to
     * answer — the adapter would block a run that protection would have
     * covered. 45 s sits above the observed worst case and well inside the
     * service budget. Round-1 gate fold-in L-2. */
    timeoutMs: 45000,
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
    /**
     * Cap an operator-set value that is quoted back inside a problem string.
     * These values are administrator configuration, never request content — but
     * a validation problem ends up in an evidence row's `message`, so nothing
     * unbounded goes in there on principle.
     */
    _short: function (v) {
        var s = String(v === null || v === undefined ? '' : v);
        return s.length > 40 ? s.substring(0, 40) + '…' : s;
    },

    validate: function (cfg) {
        var problems = [];

        if (cfg.transport !== 'rest_message' && cfg.transport !== 'endpoint') {
            problems.push('transport must be "rest_message" or "endpoint" (got "' +
                this._short(cfg.transport) + '")');
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

        /* THE DECISION IS UNCHANGED — only the error surface is actionable.
         *
         * Both branches below fail closed exactly as before: an unset vendor and
         * an out-of-set vendor each stop the flow at the first step, no value is
         * defaulted, nothing is mapped onto a neighbouring vendor, and the
         * accepted set is still LucairnConfig.ALLOWED_VENDORS and nothing else.
         * What changed is that the message now tells the operator WHICH property
         * to set and WHY the application will not choose for them — an operator
         * reading "vendor is not set" on an evidence row had no way to act on it
         * without finding the README first.
         *
         * The property NAME is read from PROP rather than written out again, so
         * the message cannot drift from the property it names. Both strings stay
         * administrator configuration plus literals — no request content, and
         * `_short()` bounds the one operator-supplied value that is quoted. */
        if (!cfg.vendor) {
            problems.push('vendor is not set: set the property ' + LucairnConfig.PROP.VENDOR +
                ' to one of ' + LucairnConfig.ALLOWED_VENDORS.join(', ') +
                ' — there is no default on purpose, and every protected run stays blocked ' +
                'until it is set (README § "Known gap: the vendor field")');
        } else if (LucairnConfig.ALLOWED_VENDORS.indexOf(cfg.vendor) === -1) {
            problems.push('vendor "' + this._short(cfg.vendor) + '" is not one of: ' +
                LucairnConfig.ALLOWED_VENDORS.join(', ') +
                ' — the Lucairn service accepts exactly these three. Set ' +
                LucairnConfig.PROP.VENDOR + ' to the one that is honest for this deployment; ' +
                'if none of them is, that is a blocker to raise, not a value to map onto a ' +
                'neighbour (README § "Known gap: the vendor field")');
        }

        return problems;
    },

    /**
     * Is a GlideRecord boolean truthy? Platform booleans surface as '1'/'0'
     * strings; the fakes and some APIs hand back real booleans. Anything that
     * is not an explicit truthy marker is FALSE — never "probably yes".
     *
     * @param {*} raw
     * @returns {boolean}
     */
    _isTrue: function (raw) {
        return raw === '1' || raw === 1 || raw === true || raw === 'true';
    },

    /**
     * Per-skill protection policy.
     *
     * Fail-closed is the default and is what an unknown skill, an unreadable
     * table, a table with the wrong shape, an ambiguous result, or a thrown
     * exception all resolve to. Only an explicitly present policy row whose
     * OWN field values say `skill_name = <the skill asked for>`, `active` and
     * `fail_open` flips a skill to fail-open.
     *
     * TWO independent checks, deliberately:
     *   1. SCHEMA — the table exists and carries every field the query names.
     *      A scoped GlideRecord silently DROPS a condition on a field that does
     *      not exist, so an unvalidated query can return a row it never asked
     *      for. See LucairnConfig.POLICY_REQUIRED_FIELDS.
     *   2. ROW IDENTITY — the values on the row that came back are re-read and
     *      compared in code. The query predicate is treated as an optimisation,
     *      never as the guarantee. If the predicate was honoured this check is
     *      free; if it was dropped, this is the check that catches it.
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

            /* --- check 1: schema ------------------------------------------ */
            if (typeof gr.isValid !== 'function' || gr.isValid() !== true) {
                /* Either the table is missing, or this runtime cannot tell us
                 * whether it is. Both are "we cannot trust the lookup". */
                this._log('skill policy table ' + LucairnConfig.TABLE_SKILL_POLICY +
                    ' is missing or unverifiable; staying fail-closed');
                return { failOpen: false, source: 'schema-invalid-fail-closed' };
            }
            if (typeof gr.isValidField !== 'function') {
                this._log('skill policy field validation is unavailable on this runtime; staying fail-closed');
                return { failOpen: false, source: 'schema-invalid-fail-closed' };
            }
            for (var f = 0; f < LucairnConfig.POLICY_REQUIRED_FIELDS.length; f++) {
                var field = LucairnConfig.POLICY_REQUIRED_FIELDS[f];
                if (gr.isValidField(field) !== true) {
                    this._log('skill policy table is missing field "' + field +
                        '"; a query on it would be dropped, so staying fail-closed');
                    return { failOpen: false, source: 'schema-invalid-fail-closed' };
                }
            }

            /* --- the query ------------------------------------------------- */
            gr.addQuery('skill_name', name);
            gr.addQuery('active', true);
            /* TWO, not one. The ambiguity check below needs a second candidate
             * to exist before it can see one: with setLimit(1) HONOURED — the
             * normal case — two conflicting active rows for the same skill are
             * indistinguishable from one, and whichever row the platform
             * happened to order first silently became the policy. The check only
             * ever fired when the limit was DROPPED, i.e. when the table was
             * already broken. Round-2 advisory fold-in.
             *
             * The limit stays because it bounds the read; it just has to be one
             * higher than the number of rows an unambiguous answer allows. */
            gr.setLimit(2);
            gr.query();
            if (!gr.next()) {
                return closed;
            }

            /* --- check 2: row identity ------------------------------------- */
            /* Read every value off the row BEFORE advancing the cursor for the
             * ambiguity check below — after next() the cursor no longer points
             * at this row. */
            var rowNameRaw = gr.getValue('skill_name');
            var rowActive = gr.getValue('active');
            var rowFailOpen = gr.getValue('fail_open');

            var rowName = String(rowNameRaw === null || rowNameRaw === undefined ? '' : rowNameRaw)
                .replace(/^\s+|\s+$/g, '');
            if (rowName !== name) {
                this._log('skill policy lookup for "' + name + '" returned a row for "' +
                    rowName + '"; the query predicate was not honoured, so staying fail-closed');
                return { failOpen: false, source: 'row-identity-mismatch-fail-closed' };
            }
            if (!this._isTrue(rowActive)) {
                this._log('skill policy lookup for "' + name +
                    '" returned an inactive row; staying fail-closed');
                return { failOpen: false, source: 'row-inactive-fail-closed' };
            }

            /* More than one active row for this skill means we cannot say which
             * one is the policy, and an ambiguous policy is not an override —
             * whichever row sorted first would otherwise decide, which is not a
             * decision anybody made. Duplicate rows are also how a reviewed
             * `fail_open = false` row gets quietly overtaken by an unreviewed
             * `true` one. Mark `skill_name` unique (see src/records/tables.md)
             * so the platform refuses the second row in the first place; this is
             * the check for the instance where that was not done. */
            if (gr.next() === true) {
                this._log('skill policy lookup for "' + name +
                    '" returned more than one row; ambiguous policy, staying fail-closed');
                return { failOpen: false, source: 'ambiguous-policy-fail-closed' };
            }

            var failOpen = this._isTrue(rowFailOpen);
            return {
                failOpen: failOpen,
                source: failOpen ? 'policy-row-fail-open' : 'policy-row-fail-closed'
            };
        } catch (e) {
            this._log('skill policy lookup failed for "' + name + '", staying fail-closed');
            return { failOpen: false, source: 'lookup-error-fail-closed' };
        }
    },

    type: 'LucairnConfig'
};

if (typeof module !== 'undefined' && module.exports) {
    module.exports = LucairnConfig;
}
