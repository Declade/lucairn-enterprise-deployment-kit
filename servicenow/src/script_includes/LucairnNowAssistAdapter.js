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
 * THE EVIDENCE ROW IS THE PRECONDITION, NOT A SIDE EFFECT
 * ------------------------------------------------------
 * What the administrator authorised by setting fail_open is an AUDITED
 * unprotected run. If the `uncovered_run` row cannot be stored, that is not
 * what happens — what happens is an unprotected run with no record that it
 * occurred, which nobody authorised and nobody can find afterwards. So a failed
 * evidence insert BLOCKS, even under an active override. Round-1 gate finding 1
 * (specs/2026-09/gate-2026-09-10-kit-pr133-s1.md) is exactly this hole.
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
    NOT_COVERED: 'lucairn_run_not_covered',
    /* The adapter itself could not complete a decision — a platform API threw
     * where none was expected. Distinct from every other code because it means
     * "we do not know", not "we know it failed this way". */
    PLATFORM: 'lucairn_platform_error',
    /* An override was configured, protection failed, and the audit row that the
     * override depends on could not be written. */
    UNAUDITABLE: 'lucairn_uncovered_run_unauditable'
};

/* The ONLY certificate tier this adapter may report.
 *
 * /api/v1/sensitive-mode/seal-cert returns exactly this literal
 * (dual-sandbox-architecture sensitive_mode.go:1541,
 * `CertTier: "input-shield"`), and the tier is the whole claim: an input-shield
 * certificate attests that the sanitizer processed the submitted fields, and
 * nothing about where inference ran. A response carrying any other tier — e.g.
 * "full-chain", which asserts an isolated inference path this integration does
 * not have — is a contract violation, not a better certificate. */
LucairnNowAssistAdapter.CERT_TIER = 'input-shield';

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
        /* Outermost guard. Everything below is written not to throw, but
         * "written not to throw" is a claim about code we control, and the
         * platform APIs underneath it are not. gs.getProperty() raising inside
         * config.resolve() used to escape protect() entirely, so the caller saw
         * an exception rather than a blocked run — a failure mode with no
         * decision and no evidence row. Now it is a block, like every other
         * failure. Round-1 gate fold-in M-2. */
        try {
            return this._protect(args);
        } catch (e) {
            return this._hardBlock(args);
        }
    },

    _protect: function (args) {
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

        var body = this._isPlainObject(res.body) ? res.body : {};

        /* A 200 with a shape we do not recognise is NOT a success. Treating one
         * as a success would forward whatever came back — possibly the raw text
         * — as if it had been sanitized, and mint a certificate saying so.
         *
         * PRESENCE IS NOT ENOUGH: `placeholder_map_id: true` and
         * `cert_id_partial: {}` are both present and both truthy, and the
         * round-1 gate probe walked them straight through the old `!body.x`
         * checks into a "covered" verdict (finding 3). Types and emptiness are
         * checked here, not assumed. */
        var problems = this._validateSanitizeBody(body, text);
        if (problems.length > 0) {
            var fields = {
                skill: skill,
                correlationId: correlationId,
                code: LucairnNowAssistAdapter.ERROR.CONTRACT,
                failureClass: 'contract_error',
                message: 'Lucairn service response failed validation: ' + problems.join('; '),
                durationMs: res.durationMs,
                text: text
            };
            /* M-1: if the malformed response nonetheless carries a distinct
             * sanitized_text, a fail-open run should forward THAT rather than
             * the raw submission. It is not a coverage claim — the run stays
             * uncovered and unsealable — but forwarding less is strictly better
             * than forwarding more, and the evidence row says which happened. */
            if (typeof body.sanitized_text === 'string' &&
                body.sanitized_text.length > 0 &&
                body.sanitized_text !== text) {
                fields.sanitizedText = body.sanitized_text;
            }
            return this._decide(fields);
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
            /* The manifest is validated as an OBJECT, not field by field — it is
             * diagnostic, and a malformed manifest must not be able to fail an
             * otherwise-good run. A non-array here would throw inside .join(). */
            layersActive: (Object.prototype.toString.call(manifest.layers_active) === '[object Array]')
                ? manifest.layers_active : [],
            failOpenOverride: false
        });

        if (evidenceWrite.stored !== true) {
            /* Unlike the fail-open path, this one still ALLOWS the run: the
             * submitted fields really were sanitized, so blocking here would
             * turn a lost audit row into an outage on a protected run. The
             * caller is told the row is missing rather than left to infer it
             * from an empty evidenceId, and seal() will decline to attach a
             * certificate to a row that does not exist. */
            this._log('the covered-run evidence row could not be stored for skill "' + skill +
                '"; the run was protected but is not recorded');
        }

        return {
            allowed: true,
            coverage: 'covered',
            skill: skill,
            textForSkill: body.sanitized_text,
            placeholderMapId: String(body.placeholder_map_id),
            certIdPartial: String(body.cert_id_partial),
            manifest: manifest,
            expiresAt: String(body.expires_at),
            correlationId: correlationId,
            evidenceId: evidenceWrite.sysId,
            evidenceStored: evidenceWrite.stored === true,
            forwardedSanitized: true,
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
        /* Same reasoning as protect(): a platform throw must become a typed
         * "not sealed", never an exception escaping into the skill run. */
        try {
            return this._seal(args);
        } catch (e) {
            return this._sealError(LucairnNowAssistAdapter.ERROR.PLATFORM,
                'the adapter could not complete the sealing step (platform error); no certificate exists',
                'unknown', (args && args.protectResult) ? args.protectResult.correlationId : '');
        }
    },

    _seal: function (args) {
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
            return this._sealFailed(pr, LucairnNowAssistAdapter.ERROR.INPUT,
                'seal() requires the skill response text; refusing to hash a placeholder',
                'contract_error');
        }

        var forwarded = (typeof args.forwardedText === 'string')
            ? args.forwardedText
            : String(pr.textForSkill || '');

        var cfg = this._config.resolve();
        var problems = this._config.validate(cfg);
        if (problems.length > 0) {
            return this._sealFailed(pr, LucairnNowAssistAdapter.ERROR.CONFIG,
                'configuration incomplete: ' + problems.join('; '), 'config_error');
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
             * evidence row records that.
             *
             * THERE IS NO RETRY, deliberately. `cert_id_partial` is claimed
             * atomically by the first seal call that reaches the service
             * (dual-sandbox-architecture sensitive_mode.go:352
             * findAndClaimByCertIDPartial), so a second attempt with the same
             * value returns 404 — replacing an accurate diagnostic with a
             * misleading one. Recovery is a fresh sanitize-only + seal flow. */
            this._log('certificate sealing failed for skill "' + pr.skill + '": ' + res.message);
            return this._sealFailed(pr, LucairnNowAssistAdapter.ERROR.UNREACHABLE,
                res.message, res.failureClass, res.durationMs);
        }

        var body = this._isPlainObject(res.body) ? res.body : {};
        var sealProblems = this._validateSealBody(body);
        if (sealProblems.length > 0) {
            return this._sealFailed(pr, LucairnNowAssistAdapter.ERROR.CONTRACT,
                'seal response failed validation: ' + sealProblems.join('; '),
                'contract_error', res.durationMs);
        }

        this._evidence.recordSeal(pr.evidenceId, {
            outcome: 'sealed',
            certId: String(body.cert_id),
            certUrl: String(body.cert_url),
            failureClass: 'none',
            message: '',
            sealDurationMs: res.durationMs
        });

        return {
            sealed: true,
            certId: String(body.cert_id),
            certUrl: String(body.cert_url),
            certTier: LucairnNowAssistAdapter.CERT_TIER,
            durationMs: res.durationMs,
            error: null
        };
    },

    /* ---- internals ------------------------------------------------------ */

    /**
     * The fail-closed / fail-open fork.
     *
     * Result shape (every branch, including _block and _hardBlock):
     *   {
     *     allowed:      boolean   — may the skill run proceed?
     *     coverage:     'covered' | 'uncovered'
     *     textForSkill: string    — sanitized text when covered; the least
     *                               content available when the skill is
     *                               configured fail-open; '' when blocked
     *     forwardedSanitized: boolean — is textForSkill sanitized output rather
     *                               than the raw submission? On an uncovered run
     *                               this is NOT a coverage claim; it says which
     *                               of two unprotected options was forwarded.
     *     evidenceStored: boolean — did the audit row actually land? False on a
     *                               covered run means the content was protected
     *                               but the run is unrecorded. It cannot be
     *                               false on an allowed UNCOVERED run: that
     *                               combination blocks instead (finding 1).
     *     evidenceId, correlationId, durationMs,
     *     error: null | { code, message, failure_class, evidence_id, correlation_id }
     *   }
     */
    _decide: function (f) {
        var policy = this._config.skillPolicy(f.skill);
        if (policy.failOpen !== true) {
            return this._block(f);
        }

        /* M-1: forward the least content that is available. On a malformed-but-
         * partially-usable response that is the service's own sanitized_text;
         * otherwise it is the raw submission. Either way the run is UNCOVERED —
         * this is a harm-reduction choice inside an already-unprotected run, not
         * a weaker form of coverage. */
        var forwardSanitized = (typeof f.sanitizedText === 'string' && f.sanitizedText.length > 0);
        var forwarded = forwardSanitized ? f.sanitizedText : f.text;
        var note = forwardSanitized
            ? ' | fail-open forwarded the sanitized_text carried by the incomplete response, not the raw submission'
            : ' | fail-open forwarded the RAW submission';
        var message = f.message + note;

        var write = this._evidence.write({
            outcome: 'uncovered_run',
            skill: f.skill,
            failureClass: f.failureClass,
            message: message,
            correlationId: f.correlationId,
            durationMs: f.durationMs,
            failOpenOverride: true
        });

        if (write.stored !== true) {
            /* FINDING 1. The override authorises an AUDITED unprotected run.
             * With no row there is no audit, so the thing the administrator
             * authorised is not what would happen — block instead.
             *
             * _block() attempts its own insert. If evidence storage is broken
             * outright that one fails too and the run is still blocked, which is
             * the safe end of the failure; if the failure was transient, the
             * `blocked` row lands and says why. */
            this._log('skill "' + f.skill + '" is configured fail-open, but the uncovered_run ' +
                'evidence row could not be stored; blocking the run instead — an unauditable ' +
                'fail-open is not the override that was authorised');

            return this._block({
                skill: f.skill,
                correlationId: f.correlationId,
                code: LucairnNowAssistAdapter.ERROR.UNAUDITABLE,
                failureClass: f.failureClass,
                message: f.message +
                    ' | fail-open override NOT honoured: the uncovered_run evidence row could not be stored',
                durationMs: f.durationMs,
                text: f.text
            });
        }

        this._log('skill "' + f.skill + '" is configured fail-open; the run proceeded ' +
            'without sanitizer coverage (' + f.failureClass + '). Evidence: ' + write.sysId);

        return {
            allowed: true,
            coverage: 'uncovered',
            skill: f.skill,
            textForSkill: forwarded,
            placeholderMapId: '',
            certIdPartial: '',
            manifest: {},
            expiresAt: '',
            correlationId: f.correlationId,
            evidenceId: write.sysId,
            evidenceStored: true,
            forwardedSanitized: forwardSanitized,
            durationMs: f.durationMs,
            error: {
                code: f.code,
                message: message,
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
            evidenceStored: write.stored === true,
            forwardedSanitized: false,
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

    /**
     * Last-resort block for a platform exception that escaped the normal paths.
     *
     * Touches as little as possible: `args` is read defensively, the evidence
     * write is attempted but not depended on, and neither config nor the client
     * is consulted — any of them could be the thing that just threw.
     */
    _hardBlock: function (args) {
        var skill = '';
        var correlationId = '';
        try {
            skill = String((args && args.skill) || '');
        } catch (e) { skill = ''; }
        try {
            correlationId = String((args && args.correlationId) || '');
        } catch (e) { correlationId = ''; }

        var message = 'the adapter could not complete a protection decision ' +
            '(a platform call raised); the run is blocked';

        try {
            this._log('protect() raised before a decision could be made for skill "' +
                skill + '"; blocking the run');
        } catch (e) { /* logging must not be the reason a block fails */ }

        var evidenceId = '';
        var stored = false;
        try {
            var write = this._evidence.write({
                outcome: 'blocked',
                skill: skill,
                failureClass: 'unknown',
                message: message,
                correlationId: correlationId,
                durationMs: 0,
                failOpenOverride: false
            });
            evidenceId = write.sysId || '';
            stored = write.stored === true;
        } catch (e) { evidenceId = ''; stored = false; }

        return {
            allowed: false,
            coverage: 'uncovered',
            skill: skill,
            textForSkill: '',
            placeholderMapId: '',
            certIdPartial: '',
            manifest: {},
            expiresAt: '',
            correlationId: correlationId,
            evidenceId: evidenceId,
            evidenceStored: stored,
            forwardedSanitized: false,
            durationMs: 0,
            error: {
                code: LucairnNowAssistAdapter.ERROR.PLATFORM,
                message: message,
                failure_class: 'unknown',
                evidence_id: evidenceId,
                correlation_id: correlationId
            }
        };
    },

    /**
     * A seal attempt that did not produce a certificate. Records the outcome on
     * the run's evidence row — a covered run whose seal failed must be
     * distinguishable from one where seal() was never called — then returns the
     * typed error.
     */
    _sealFailed: function (pr, code, message, failureClass, durationMs) {
        try {
            if (pr && pr.evidenceId) {
                this._evidence.recordSeal(pr.evidenceId, {
                    outcome: 'failed',
                    certId: '',
                    certUrl: '',
                    failureClass: failureClass,
                    message: message,
                    sealDurationMs: durationMs || 0
                });
            }
        } catch (e) { /* the seal already failed; recording must not throw over it */ }
        return this._sealError(code, message, failureClass,
            pr ? pr.correlationId : '', durationMs);
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

    /* ---- response validation -------------------------------------------- */

    _isNonEmptyString: function (v) {
        return typeof v === 'string' && v.length > 0;
    },

    _isPlainObject: function (v) {
        return v !== null && typeof v === 'object' &&
            Object.prototype.toString.call(v) !== '[object Array]';
    },

    /**
     * @param {object} body  the parsed 200 body from /api/v1/sanitize-only
     * @param {string} text  what was submitted — an empty submission is the one
     *   case where an empty sanitized_text is honest
     * @returns {string[]} problems; empty means the body is the documented shape
     */
    _validateSanitizeBody: function (body, text) {
        var problems = [];

        if (typeof body.sanitized_text !== 'string') {
            problems.push('sanitized_text must be a string');
        } else if (text.length > 0 && body.sanitized_text.length === 0) {
            /* Empty output for non-empty input is not "nothing to redact" — it
             * is a response we cannot forward and cannot certify. */
            problems.push('sanitized_text is empty for a non-empty submission');
        }
        if (!this._isNonEmptyString(body.cert_id_partial)) {
            problems.push('cert_id_partial must be a non-empty string');
        }
        if (!this._isNonEmptyString(body.placeholder_map_id)) {
            problems.push('placeholder_map_id must be a non-empty string');
        }
        if (!this._isNonEmptyString(body.expires_at)) {
            problems.push('expires_at must be a non-empty string');
        }
        if (!this._isPlainObject(body.manifest)) {
            problems.push('manifest must be an object');
        }
        return problems;
    },

    /**
     * @param {object} body  the parsed 200 body from /sensitive-mode/seal-cert
     * @returns {string[]} problems; empty means a usable input-shield certificate
     */
    _validateSealBody: function (body) {
        var problems = [];

        if (!this._isNonEmptyString(body.cert_id)) {
            problems.push('cert_id must be a non-empty string');
        }
        if (!this._isNonEmptyString(body.cert_url)) {
            problems.push('cert_url must be a non-empty string');
        }
        if (body.cert_tier !== LucairnNowAssistAdapter.CERT_TIER) {
            /* Not a warning. A tier this adapter did not ask for is a claim it
             * cannot make: "full-chain" would assert an isolated inference path
             * that does not exist here. */
            problems.push('cert_tier must be "' + LucairnNowAssistAdapter.CERT_TIER + '"');
        }
        return problems;
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
