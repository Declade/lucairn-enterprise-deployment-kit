/*
 * LucairnEvidence — Script Include (Lucairn for Now Assist)
 *
 * Writes one row per protected skill run to x_lcrn_now_assist_evidence.
 *
 * What an evidence row is and is NOT:
 *   - It IS an instance-local record of what this adapter did on a given run.
 *   - It is NOT a certificate. Certificates are minted by the Lucairn service
 *     and referenced here by cert_id / cert_url when one exists.
 *
 * Row outcomes:
 *   covered       - the submitted fields were sanitized before the skill ran
 *   blocked       - the adapter could not reach/complete protection and the run
 *                   was stopped (fail-closed)
 *   uncovered_run - protection failed AND this skill is configured fail-open,
 *                   so the run proceeded on RAW content. This is the row that
 *                   makes a fail-open decision auditable after the fact.
 *
 * PII rule: this table stores no submitted content, sanitized or raw. Only
 * counts, identifiers, durations and error text produced by the adapter.
 *
 * ES5 only (Rhino-compatible).
 */
var LucairnEvidence = Class.create();

LucairnEvidence.TABLE = 'x_lcrn_now_assist_evidence';

LucairnEvidence.OUTCOME = {
    COVERED: 'covered',
    BLOCKED: 'blocked',
    UNCOVERED_RUN: 'uncovered_run'
};

/* Failure classes are for triage only. They NEVER influence the fail-closed
 * decision — any non-success is blocked regardless of how it is classified, so
 * a misclassification can never widen the exposure. */
LucairnEvidence.FAILURE = {
    NONE: 'none',
    CONNECTION_REFUSED: 'connection_refused',
    TIMEOUT: 'timeout',
    HTTP_ERROR: 'http_error',
    CONTRACT_ERROR: 'contract_error',
    CONFIG_ERROR: 'config_error',
    UNKNOWN: 'unknown'
};

LucairnEvidence.prototype = {

    /**
     * @param {object} [deps] test seam. `{ glideRecord: fn, log: fn, now: fn }`.
     */
    initialize: function (deps) {
        deps = deps || {};
        this._glideRecord = deps.glideRecord || function (table) {
            return new GlideRecord(table);
        };
        this._log = deps.log || function (msg) {
            gs.warn('[Lucairn for Now Assist] ' + msg);
        };
        this._now = deps.now || function () {
            return new GlideDateTime().getDisplayValue();
        };
    },

    /**
     * Insert one evidence row.
     *
     * Never throws. A storage failure is logged and reported back via the
     * return value; it must not itself become a second failure that the caller
     * has to reason about mid-decision. The caller has ALREADY made its
     * fail-closed/fail-open decision before calling this.
     *
     * @param {object} rec
     * @param {string} rec.outcome        one of LucairnEvidence.OUTCOME
     * @param {string} rec.skill          Now Assist skill name
     * @param {string} [rec.failureClass] one of LucairnEvidence.FAILURE
     * @param {string} [rec.message]      short diagnostic, no submitted content
     * @param {string} [rec.correlationId]
     * @param {string} [rec.certId]
     * @param {string} [rec.certUrl]
     * @param {string} [rec.certIdPartial]
     * @param {number} [rec.durationMs]
     * @param {number} [rec.redactionTotal]
     * @param {string[]} [rec.layersActive]
     * @param {boolean} [rec.failOpenOverride]
     * @returns {{stored: boolean, sysId: string, error: string}}
     */
    write: function (rec) {
        var result = { stored: false, sysId: '', error: '' };
        try {
            var gr = this._glideRecord(LucairnEvidence.TABLE);
            gr.initialize();
            gr.setValue('outcome', rec.outcome || LucairnEvidence.OUTCOME.BLOCKED);
            gr.setValue('skill', String(rec.skill || ''));
            gr.setValue('failure_class', rec.failureClass || LucairnEvidence.FAILURE.NONE);
            gr.setValue('message', this._truncate(rec.message, 1000));
            gr.setValue('correlation_id', String(rec.correlationId || ''));
            gr.setValue('cert_id', String(rec.certId || ''));
            gr.setValue('cert_url', String(rec.certUrl || ''));
            gr.setValue('cert_id_partial', String(rec.certIdPartial || ''));
            gr.setValue('duration_ms', this._int(rec.durationMs));
            gr.setValue('redaction_total', this._int(rec.redactionTotal));
            gr.setValue('layers_active', (rec.layersActive || []).join(','));
            gr.setValue('fail_open_override', rec.failOpenOverride === true);
            gr.setValue('recorded_at', this._now());

            var sysId = gr.insert();
            if (!sysId) {
                result.error = 'insert returned no sys_id';
                this._log('evidence insert returned no sys_id for skill "' + rec.skill + '"');
                return result;
            }
            result.stored = true;
            result.sysId = String(sysId);
            return result;
        } catch (e) {
            result.error = e.message;
            this._log('evidence insert failed for skill "' + rec.skill + '": ' + e.message);
            return result;
        }
    },

    /**
     * Attach certificate identifiers to an already-written evidence row.
     *
     * Separate from write() because the certificate only exists after the
     * skill has produced a response and the seal call has returned — by which
     * point the covered/blocked decision is long made. Never throws.
     *
     * @param {string} sysId  sys_id returned by write()
     * @param {object} cert   `{ certId, certUrl, sealDurationMs }`
     * @returns {{updated: boolean, error: string}}
     */
    attachCert: function (sysId, cert) {
        var result = { updated: false, error: '' };
        var id = String(sysId || '');
        if (!id) {
            result.error = 'no evidence sys_id';
            return result;
        }
        try {
            var gr = this._glideRecord(LucairnEvidence.TABLE);
            if (!gr.get(id)) {
                result.error = 'evidence row not found';
                return result;
            }
            gr.setValue('cert_id', String(cert.certId || ''));
            gr.setValue('cert_url', String(cert.certUrl || ''));
            if (cert.sealDurationMs !== undefined) {
                gr.setValue('seal_duration_ms', this._int(cert.sealDurationMs));
            }
            gr.update();
            result.updated = true;
            return result;
        } catch (e) {
            result.error = e.message;
            this._log('evidence cert attach failed for ' + id + ': ' + e.message);
            return result;
        }
    },

    _truncate: function (s, max) {
        var v = String(s === null || s === undefined ? '' : s);
        return v.length > max ? v.substring(0, max) : v;
    },

    _int: function (n) {
        var v = parseInt(n, 10);
        return isNaN(v) ? 0 : v;
    },

    type: 'LucairnEvidence'
};

if (typeof module !== 'undefined' && module.exports) {
    module.exports = LucairnEvidence;
}
