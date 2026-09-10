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

/* Certificate-sealing outcome, recorded separately from the coverage outcome.
 * A run can be covered and unsealed: the submitted fields were sanitized, and
 * the certificate that would have attested it does not exist. Those are two
 * different facts and the row states both. */
LucairnEvidence.SEAL = {
    NOT_ATTEMPTED: 'not_attempted',
    SEALED: 'sealed',
    FAILED: 'failed'
};

/* The fields that MAKE a row an audit record.
 *
 * A sys_id from insert() is proof that a ROW exists, not that an audit exists.
 * A partially imported table — system columns present, application columns
 * missing — accepts the insert and silently discards every setValue() naming a
 * field it does not have, so the row that comes back has an id and no outcome,
 * no skill, no correlation id and no fail-open marker. The adapter then treats
 * that content-less row as the audit trail the fail-open override depends on,
 * and an unprotected run proceeds "audited" by a row that records nothing.
 * Round-2 gate finding astra-B1.
 *
 * So the schema is checked BEFORE the insert may count as stored. Missing
 * schema ⇒ stored:false ⇒ the caller blocks, exactly as it does for a failed
 * insert.
 *
 * Scope: the fields an auditor needs to answer "what happened, to which skill,
 * when, and was an override in play". The certificate/diagnostic columns
 * (cert_*, duration_ms, redaction_total, layers_active, seal_*) are NOT in this
 * set on purpose — a missing one loses detail from a row that still records the
 * decision, and turning that into a blocked run would be a fail-closed posture
 * the finding does not call for. A missing one is visible in the row itself. */
LucairnEvidence.REQUIRED_FIELDS = [
    'outcome',
    'skill',
    'failure_class',
    'message',
    'correlation_id',
    'fail_open_override',
    'recorded_at'
];

/* The fields recordSeal() needs in order for a seal outcome to be recoverable
 * from the row rather than inferred from an empty cert_id. */
LucairnEvidence.SEAL_REQUIRED_FIELDS = [
    'seal_outcome',
    'seal_failure_class',
    'seal_message',
    'cert_id',
    'cert_url'
];

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
     *   `stored: true` means an audit record exists — the table can hold every
     *   field in LucairnEvidence.REQUIRED_FIELDS AND the insert returned an id.
     *   An insert into a table that cannot hold those fields is NOT stored,
     *   however well it went (astra-B1).
     */
    write: function (rec) {
        var result = { stored: false, sysId: '', error: '' };
        try {
            var gr = this._glideRecord(LucairnEvidence.TABLE);

            /* astra-B1: schema first. An insert into a table that cannot hold
             * the audit fields produces a sys_id and no audit. */
            var schema = this._schemaProblem(gr, LucairnEvidence.REQUIRED_FIELDS);
            if (schema) {
                result.error = schema;
                this._safeLog('evidence table is not usable as an audit record (' + schema +
                    '); treating the write as failed');
                return result;
            }

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
            gr.setValue('seal_outcome', LucairnEvidence.SEAL.NOT_ATTEMPTED);
            gr.setValue('seal_failure_class', LucairnEvidence.FAILURE.NONE);
            gr.setValue('recorded_at', this._now());

            var sysId = gr.insert();
            if (!sysId) {
                result.error = 'insert returned no sys_id';
                this._safeLog('evidence insert returned no sys_id for skill "' + rec.skill + '"');
                return result;
            }
            result.stored = true;
            result.sysId = String(sysId);
            return result;
        } catch (e) {
            /* Typed, not forwarded. A platform exception raised mid-insert can
             * quote the value it choked on, and the caller writes this string
             * into a log line. See LucairnClient rule 4. */
            result.error = 'evidence insert raised';
            this._safeLog('evidence insert failed for skill "' + String(rec.skill || '') + '"');
            return result;
        }
    },

    /**
     * Record the outcome of the certificate-sealing step on an already-written
     * evidence row.
     *
     * Separate from write() because the sealing step only happens after the
     * skill has produced a response — by which point the covered/blocked
     * decision is long made. Never throws.
     *
     * BOTH outcomes are recorded, not just the happy one. A covered run whose
     * seal failed leaves a row saying so; silence would be indistinguishable
     * from "nobody ever called seal()".
     *
     * There is NO retry. `cert_id_partial` is consumed by the first seal call
     * that reaches the service, so a second attempt with the same value returns
     * 404 and would overwrite an accurate diagnostic with a misleading one.
     * Recovery is a fresh sanitize-only + seal flow, not a retry.
     *
     * @param {string} sysId  sys_id returned by write()
     * @param {object} seal
     * @param {string} seal.outcome        one of LucairnEvidence.SEAL
     * @param {string} [seal.certId]
     * @param {string} [seal.certUrl]
     * @param {string} [seal.failureClass]
     * @param {string} [seal.message]      bounded, typed diagnostic; no content
     * @param {number} [seal.sealDurationMs]
     * @returns {{updated: boolean, error: string}}
     */
    recordSeal: function (sysId, seal) {
        var result = { updated: false, error: '' };
        var id = String(sysId || '');
        var s = seal || {};
        if (!id) {
            result.error = 'no evidence sys_id';
            return result;
        }
        try {
            var gr = this._glideRecord(LucairnEvidence.TABLE);

            var schema = this._schemaProblem(gr, LucairnEvidence.SEAL_REQUIRED_FIELDS);
            if (schema) {
                result.error = schema;
                this._safeLog('evidence table cannot record a seal outcome (' + schema + ')');
                return result;
            }

            if (!gr.get(id)) {
                result.error = 'evidence row not found';
                return result;
            }
            gr.setValue('seal_outcome', s.outcome || LucairnEvidence.SEAL.FAILED);
            gr.setValue('cert_id', String(s.certId || ''));
            gr.setValue('cert_url', String(s.certUrl || ''));
            gr.setValue('seal_failure_class', s.failureClass || LucairnEvidence.FAILURE.NONE);
            gr.setValue('seal_message', this._truncate(s.message, 500));
            if (s.sealDurationMs !== undefined) {
                gr.setValue('seal_duration_ms', this._int(s.sealDurationMs));
            }
            /* update() returns the sys_id it wrote, or null when the write did
             * not happen (an ACL denial is the common one — the application can
             * insert evidence and cannot update it). Reporting `updated: true`
             * for a null return would report a seal outcome the row does not
             * carry, which is the same class of defect as astra-B1 one step
             * later in the flow. Round-2 advisory fold-in. */
            var updatedId = gr.update();
            if (!updatedId) {
                result.error = 'update returned no sys_id';
                this._safeLog('evidence seal outcome was not written for ' + id +
                    ' (update returned no sys_id)');
                return result;
            }
            result.updated = true;
            return result;
        } catch (e) {
            result.error = 'seal outcome could not be recorded';
            this._safeLog('evidence seal outcome could not be recorded for ' + id);
            return result;
        }
    },

    /**
     * Is this GlideRecord usable as an audit record?
     *
     * Mirrors LucairnConfig.skillPolicy()'s schema check, and for the same
     * reason: the platform does not error on an operation naming a field the
     * table does not have — a query condition is dropped, a setValue() is
     * discarded. Both turn "the table is wrong" into a plausible-looking
     * success. The check is fail-closed: a runtime that cannot answer
     * isValid()/isValidField() is treated as an unusable table, not as a
     * usable one.
     *
     * @param {object} gr
     * @param {string[]} fields
     * @returns {string} '' when usable, otherwise a short typed problem string
     *   (no submitted content — this value reaches a caller's log line).
     */
    _schemaProblem: function (gr, fields) {
        if (typeof gr.isValid !== 'function' || gr.isValid() !== true) {
            return 'evidence table missing or unverifiable';
        }
        if (typeof gr.isValidField !== 'function') {
            return 'evidence field validation unavailable';
        }
        for (var i = 0; i < fields.length; i++) {
            if (gr.isValidField(fields[i]) !== true) {
                return 'evidence table is missing field "' + fields[i] + '"';
            }
        }
        return '';
    },

    /**
     * Log, and never be the reason a caller's outcome changes.
     *
     * write() and recordSeal() both promise "never throws", and both used to
     * break that promise in the one place it matters: the log line INSIDE their
     * catch blocks. An injected logger that throws — a platform `gs.warn` under
     * an ACL, a caller's own logger with a bug — made the recovery path raise,
     * so the exception escaped into the adapter and, one frame up, turned a
     * MINTED certificate into "no certificate exists" (round-3 advisory).
     *
     * A diagnostic is not allowed to have that power.
     */
    _safeLog: function (msg) {
        try {
            this._log(msg);
        } catch (e) { /* a diagnostic must never be the reason an outcome changes */ }
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
