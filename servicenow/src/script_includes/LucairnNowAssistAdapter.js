/*
 * LucairnNowAssistAdapter — Script Include (Lucairn for Now Assist)
 *
 * The only entry point other code in this application should call.
 *
 * Two-step contract against the Lucairn service:
 *
 *   1. protect({ skill, text })  -> sanitize the submitted fields before the
 *                                   Now Assist skill runs.
 *   2. seal({ ... })             -> after the skill has produced a response,
 *                                   finalise the input-shield certificate.
 *
 * WHY FAIL-CLOSED IS THE DEFAULT HERE
 * -----------------------------------
 * In Lucairn's other integrations a client-side failure is backstopped by the
 * Lucairn service itself, which still sanitizes before any model sees the text.
 * That backstop does not exist here: on this path the adapter IS the only layer
 * in front of the Now Assist model. A silent fail-open would mean raw content
 * reaching the model with nothing recording that it happened. So:
 *
 *   - Any failure blocks the run, unless
 *   - an administrator has explicitly set fail_open = true for that one skill,
 *     in which case the run proceeds on RAW content and an `uncovered_run`
 *     evidence row is written so the decision is auditable afterwards.
 *
 * WHAT THE CERTIFICATE CLAIMS
 * ---------------------------
 * The certificate produced by seal() is an INPUT-SHIELD certificate. It attests
 * exactly one thing: the sanitizer processed the submitted fields before the
 * skill ran. It does not attest anything about what ServiceNow's own inference
 * ultimately contained, and it is not a coverage claim over the whole
 * interaction. Do not restate it more strongly anywhere.
 *
 * ES5 only (Rhino-compatible).
 */
var LucairnNowAssistAdapter = Class.create();

LucairnNowAssistAdapter.ERROR = {
    CONFIG: 'lucairn_config_error',
    UNREACHABLE: 'lucairn_service_unreachable',
    CONTRACT: 'lucairn_contract_error',
    INPUT: 'lucairn_invalid_input',
    NOT_COVERED: 'lucairn_run_not_covered'
};

LucairnNowAssistAdapter.prototype = {

    /**
     * @param {object} [deps] test seam:
     *   `{ config, client, evidence, sha256, guid, now, log }`
     *   Every dependency defaults to the real Script Include.
     */
    initialize: function (deps) {
        deps = deps || {};
        this._config = deps.config || new LucairnConfig();
        this._evidence = deps.evidence || new LucairnEvidence();
        this._sha256 = deps.sha256 || LucairnSha256;
        this._makeClient = deps.makeClient || function (cfg) {
            return new LucairnClient(cfg);
        };
        this._guid = deps.guid || function () {
            return String(gs.generateGUID());
        };
        this._now = deps.now || function () {
            return new Date().getTime();
        };
        this._log = deps.log || function (msg) {
            gs.warn('[Lucairn for Now Assist] ' + msg);
        };
    },

    /**
     * Sanitize the submitted fields before the skill runs.
     *
     * @param {object} args
     * @param {string} args.skill            Now Assist skill name (policy key)
     * @param {string} args.text             the submitted content
     * @param {string} [args.correlationId]  reuse an existing id if the caller has one
     * @returns {object} result — see the header of _decide() for the shape.
     */
    protect: function (args) {
        args = args || {};
        var skill = String(args.skill || '');
        var text = (args.text === null || args.text === undefined) ? '' : String(args.text);
        var correlationId = String(args.correlationId || this._guid());
        var started = this._now();

        if (!skill) {
            /* No skill name means no policy can be resolved, so no fail-open
             * override can apply. Hard block. */
            return this._block({
                skill: '',
                correlationId: correlationId,
                code: LucairnNowAssistAdapter.ERROR.INPUT,
                failureClass: 'config_error',
                message: 'protect() called without a skill name',
                durationMs: this._now() - started,
                text: text
            });
        }

        var cfg = this._config.resolve();
        var problems = this._config.validate(cfg);
        if (problems.length > 0) {
            return this._decide({
                skill: skill,
                correlationId: correlationId,
                code: LucairnNowAssistAdapter.ERROR.CONFIG,
                failureClass: 'config_error',
                message: 'configuration incomplete: ' + problems.join('; '),
                durationMs: this._now() - started,
                text: text
            });
        }

        var client = this._makeClient(cfg);
        var res = client.sanitizeOnly(text);

        if (!res.ok) {
            return this._decide({
                skill: skill,
                correlationId: correlationId,
                code: LucairnNowAssistAdapter.ERROR.UNREACHABLE,
                failureClass: res.failureClass,
                message: res.message,
                durationMs: res.durationMs,
                text: text
            });
        }

        var body = res.body || {};
        var missing = [];
        if (typeof body.sanitized_text !== 'string') {
            missing.push('sanitized_text');
        }
        if (!body.cert_id_partial) {
            missing.push('cert_id_partial');
        }
        if (!body.placeholder_map_id) {
            missing.push('placeholder_map_id');
        }
        if (missing.length > 0) {
            /* A 200 with a shape we do not recognise is NOT a success. Treating
             * it as one would forward whatever came back — possibly the raw
             * text — as if it had been sanitized. */
            return this._decide({
                skill: skill,
                correlationId: correlationId,
                code: LucairnNowAssistAdapter.ERROR.CONTRACT,
                failureClass: 'contract_error',
                message: 'Lucairn service response missing: ' + missing.join(', '),
                durationMs: res.durationMs,
                text: text
            });
        }

        var manifest = body.manifest || {};
        var evidenceWrite = this._evidence.write({
            outcome: 'covered',
            skill: skill,
            failureClass: 'none',
            message: '',
            correlationId: correlationId,
            certIdPartial: String(body.cert_id_partial),
            durationMs: res.durationMs,
            redactionTotal: this._sumRedactions(manifest.redaction_count),
            layersActive: manifest.layers_active || [],
            failOpenOverride: false
        });

        return {
            allowed: true,
            coverage: 'covered',
            skill: skill,
            textForSkill: body.sanitized_text,
            placeholderMapId: String(body.placeholder_map_id),
            certIdPartial: String(body.cert_id_partial),
            manifest: manifest,
            expiresAt: body.expires_at ? String(body.expires_at) : '',
            correlationId: correlationId,
            evidenceId: evidenceWrite.sysId,
            durationMs: res.durationMs,
            error: null
        };
    },

    /**
     * Finalise the input-shield certificate once the skill has responded.
     *
     * Refuses to seal a run that was not covered. A certificate minted for a
     * fail-open run would assert that the submitted fields were sanitized when
     * they were not — the exact overclaim the evidence row exists to prevent.
     *
     * @param {object} args
     * @param {object} args.protectResult   the object returned by protect()
     * @param {string} args.responseText    the skill's response, as produced
     * @param {string} [args.forwardedText] the bytes actually handed to the
     *   skill; defaults to protectResult.textForSkill. Pass it explicitly if
     *   the caller wrapped or trimmed the sanitized text — the hash must cover
     *   what was really forwarded, not what we assume was.
     * @param {string} [args.toolName]      provenance display string
     * @returns {{sealed: boolean, certId: string, certUrl: string, certTier: string,
     *            durationMs: number, error: object|null}}
     */
    seal: function (args) {
        args = args || {};
        var pr = args.protectResult || {};

        if (pr.coverage !== 'covered' || !pr.certIdPartial) {
            return this._sealError(LucairnNowAssistAdapter.ERROR.NOT_COVERED,
                'refusing to seal a certificate for a run that was not covered by the sanitizer',
                'contract_error', pr.correlationId);
        }
        if (typeof args.responseText !== 'string' || args.responseText.length === 0) {
            /* No response means no honest response hash. Hashing an empty
             * string here would put a real-looking digest of nothing into the
             * certificate. */
            return this._sealError(LucairnNowAssistAdapter.ERROR.INPUT,
                'seal() requires the skill response text; refusing to hash a placeholder',
                'contract_error', pr.correlationId);
        }

        var forwarded = (typeof args.forwardedText === 'string')
            ? args.forwardedText
            : String(pr.textForSkill || '');

        var cfg = this._config.resolve();
        var problems = this._config.validate(cfg);
        if (problems.length > 0) {
            return this._sealError(LucairnNowAssistAdapter.ERROR.CONFIG,
                'configuration incomplete: ' + problems.join('; '),
                'config_error', pr.correlationId);
        }

        var client = this._makeClient(cfg);
        var res = client.sealCert({
            certIdPartial: pr.certIdPartial,
            requestContentHash: this._sha256.wireOfUtf8(forwarded),
            responseContentHash: this._sha256.wireOfUtf8(args.responseText),
            toolName: args.toolName || ('ServiceNow Now Assist — ' + (pr.skill || 'skill'))
        });

        if (!res.ok) {
            /* Sealing failure does NOT retroactively expose anything: the
             * submitted fields were already sanitized before the skill ran.
             * The run stays covered; only the certificate is missing, and the
             * evidence row records that. */
            this._log('certificate sealing failed for skill "' + pr.skill + '": ' + res.message);
            return this._sealError(LucairnNowAssistAdapter.ERROR.UNREACHABLE,
                res.message, res.failureClass, pr.correlationId, res.durationMs);
        }

        var body = res.body || {};
        if (!body.cert_id || !body.cert_url) {
            return this._sealError(LucairnNowAssistAdapter.ERROR.CONTRACT,
                'seal response missing cert_id / cert_url', 'contract_error',
                pr.correlationId, res.durationMs);
        }

        this._evidence.attachCert(pr.evidenceId, {
            certId: String(body.cert_id),
            certUrl: String(body.cert_url),
            sealDurationMs: res.durationMs
        });

        return {
            sealed: true,
            certId: String(body.cert_id),
            certUrl: String(body.cert_url),
            certTier: body.cert_tier ? String(body.cert_tier) : '',
            durationMs: res.durationMs,
            error: null
        };
    },

    /* ---- internals ------------------------------------------------------ */

    /**
     * The fail-closed / fail-open fork.
     *
     * Result shape (both branches):
     *   {
     *     allowed:      boolean   — may the skill run proceed?
     *     coverage:     'covered' | 'uncovered'
     *     textForSkill: string    — sanitized text when covered, raw when the
     *                               skill is configured fail-open, '' when blocked
     *     evidenceId, correlationId, durationMs,
     *     error: null | { code, message, failure_class, evidence_id, correlation_id }
     *   }
     */
    _decide: function (f) {
        var policy = this._config.skillPolicy(f.skill);
        if (policy.failOpen !== true) {
            return this._block(f);
        }

        var write = this._evidence.write({
            outcome: 'uncovered_run',
            skill: f.skill,
            failureClass: f.failureClass,
            message: f.message,
            correlationId: f.correlationId,
            durationMs: f.durationMs,
            failOpenOverride: true
        });

        this._log('skill "' + f.skill + '" is configured fail-open; the run proceeded ' +
            'on unsanitized content (' + f.failureClass + '). Evidence: ' + write.sysId);

        return {
            allowed: true,
            coverage: 'uncovered',
            skill: f.skill,
            textForSkill: f.text,
            placeholderMapId: '',
            certIdPartial: '',
            manifest: {},
            expiresAt: '',
            correlationId: f.correlationId,
            evidenceId: write.sysId,
            durationMs: f.durationMs,
            error: {
                code: f.code,
                message: f.message,
                failure_class: f.failureClass,
                evidence_id: write.sysId,
                correlation_id: f.correlationId
            }
        };
    },

    _block: function (f) {
        var write = this._evidence.write({
            outcome: 'blocked',
            skill: f.skill,
            failureClass: f.failureClass,
            message: f.message,
            correlationId: f.correlationId,
            durationMs: f.durationMs,
            failOpenOverride: false
        });

        return {
            allowed: false,
            coverage: 'uncovered',
            skill: f.skill,
            textForSkill: '',
            placeholderMapId: '',
            certIdPartial: '',
            manifest: {},
            expiresAt: '',
            correlationId: f.correlationId,
            evidenceId: write.sysId,
            durationMs: f.durationMs,
            error: {
                code: f.code,
                message: f.message,
                failure_class: f.failureClass,
                evidence_id: write.sysId,
                correlation_id: f.correlationId
            }
        };
    },

    _sealError: function (code, message, failureClass, correlationId, durationMs) {
        return {
            sealed: false,
            certId: '',
            certUrl: '',
            certTier: '',
            durationMs: durationMs || 0,
            error: {
                code: code,
                message: message,
                failure_class: failureClass,
                correlation_id: String(correlationId || '')
            }
        };
    },

    _sumRedactions: function (counts) {
        var total = 0;
        var k;
        if (!counts || typeof counts !== 'object') {
            return 0;
        }
        for (k in counts) {
            if (Object.prototype.hasOwnProperty.call(counts, k)) {
                var n = parseInt(counts[k], 10);
                if (!isNaN(n)) {
                    total += n;
                }
            }
        }
        return total;
    },

    type: 'LucairnNowAssistAdapter'
};

if (typeof module !== 'undefined' && module.exports) {
    module.exports = LucairnNowAssistAdapter;
}
