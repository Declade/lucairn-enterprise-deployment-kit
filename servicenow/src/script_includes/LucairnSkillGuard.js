/*
 * LucairnSkillGuard — Script Include (Lucairn for Now Assist)
 *
 * The thing that turns a protection DECISION into a skill-run OUTCOME.
 *
 * LucairnNowAssistAdapter.protect() answers "may this run proceed, and on what
 * text". Nothing consumed that answer until this file existed: the adapter
 * returned `allowed: false` and the skill ran anyway, because no code was wired
 * anywhere that could stop it. Round-1 gate finding 7 / D-1
 * (specs/2026-09/gate-2026-09-10-kit-pr133-s1.md) is exactly that gap — the
 * PRD's acceptance criterion is a BLOCKED SKILL RUN, and a blocked adapter
 * return is not one.
 *
 * ⚠️ HYPOTHESIS — NOT EXECUTION-PROVEN
 * ------------------------------------
 * Everything about HOW a script aborts a Now Assist skill run is unproven. No
 * instance with Now Assist skills has executed this code. What is written here
 * is the mechanism that is most defensible from the documented model, plus the
 * observable that settles it:
 *
 *   Claim under test: "a GenAI Preprocessor script that raises stops the skill
 *   run, and the caller sees an error rather than a summary."
 *
 *   Note what that claim does NOT say: nothing about whether inference was
 *   dispatched. The observable is a suppressed OUTPUT. "before inference" is a
 *   second claim needing its own evidence — README § Leg 6 states the
 *   falsifier for it, and round-2 finding astra-B2 is the record of this file
 *   having asserted it for free.
 *
 *   Falsifier (README § Verify on the PDI, Leg 6): run the OOTB skill from its
 *   own product UI with the hook wired and the service unreachable. If a
 *   summary comes back, the claim is FALSE — whatever this file returns.
 *
 * Three outcomes are possible on the instance and all three are handled:
 *   a) the raise aborts the run           -> output suppression works; the
 *      suppression claim holds at the scope Leg 6 measured
 *   b) the raise is swallowed, run proceeds -> blocking does NOT work. ⚠️ The
 *      annotation does NOT survive as a control on this path: the hook raises
 *      BEFORE it assigns its output, so a swallowed raise leaves the skill
 *      running on the original text, unannotated. The evidence row is the only
 *      surviving control, and no blocking claim may be made anywhere
 *      (packaging, deck, docs)
 *   c) the hook is never invoked at all   -> the preprocessor lane is dead for
 *      this skill and the P2 clone lane is the remaining path
 * Record which one happened in the gate record. Do not infer (a) from a green
 * unit test — this file's tests prove what THIS code does, not what the
 * platform does with it.
 *
 * ES5 only (Rhino-compatible).
 */
var LucairnSkillGuard = Class.create();

/* Marker prefix on the raised error, so an instance log line can be attributed
 * to this application rather than to a platform fault. */
LucairnSkillGuard.ERROR_PREFIX = '[Lucairn for Now Assist] skill run blocked: ';

/* Prepended to the text handed onward when a run proceeds WITHOUT sanitizer
 * coverage. It is deliberately visible in the model input and in anything the
 * model quotes back: an uncovered run should be obvious to whoever reads the
 * output, not only to whoever reads the evidence table. */
LucairnSkillGuard.UNCOVERED_ANNOTATION =
    '[Lucairn: this content was NOT processed by the Lucairn sanitizer. ' +
    'No certificate exists for this interaction.]';

LucairnSkillGuard.DECISION = {
    COVERED: 'covered',
    UNCOVERED: 'uncovered',
    BLOCKED: 'blocked'
};

LucairnSkillGuard.prototype = {

    /**
     * @param {object} [deps] test seam: `{ adapter, log }`
     */
    initialize: function (deps) {
        deps = deps || {};
        this._adapter = deps.adapter || new LucairnNowAssistAdapter();
        this._log = deps.log || function (msg) {
            gs.warn('[Lucairn for Now Assist] ' + msg);
        };
    },

    /**
     * Decide, without acting. Returns a plain object so a caller can choose how
     * to act on the instance — and so this logic is testable without depending
     * on how the platform treats a raised error.
     *
     * @param {object} args `{ skill, text, correlationId? }`
     * @returns {{decision: string, block: boolean, text: string,
     *            annotated: boolean, reason: string, evidenceId: string,
     *            correlationId: string, protectResult: object}}
     */
    evaluate: function (args) {
        args = args || {};
        var res = this._adapter.protect({
            skill: args.skill,
            text: args.text,
            correlationId: args.correlationId
        });

        if (res.allowed !== true) {
            return {
                decision: LucairnSkillGuard.DECISION.BLOCKED,
                block: true,
                /* Nothing goes onward. Not the raw text, not a truncated
                 * version of it, not a summary of it. */
                text: '',
                annotated: false,
                reason: (res.error && res.error.code) ? String(res.error.code) : 'unknown',
                evidenceId: String(res.evidenceId || ''),
                correlationId: String(res.correlationId || ''),
                protectResult: res
            };
        }

        if (res.coverage !== 'covered') {
            /* An administrator flipped this skill fail-open. The run proceeds —
             * that is what the override means — but it proceeds LABELLED. */
            return {
                decision: LucairnSkillGuard.DECISION.UNCOVERED,
                block: false,
                text: LucairnSkillGuard.UNCOVERED_ANNOTATION + '\n' + String(res.textForSkill || ''),
                annotated: true,
                reason: (res.error && res.error.code) ? String(res.error.code) : 'fail_open_override',
                evidenceId: String(res.evidenceId || ''),
                correlationId: String(res.correlationId || ''),
                protectResult: res
            };
        }

        return {
            decision: LucairnSkillGuard.DECISION.COVERED,
            block: false,
            text: String(res.textForSkill),
            annotated: false,
            reason: '',
            evidenceId: String(res.evidenceId || ''),
            correlationId: String(res.correlationId || ''),
            protectResult: res
        };
    },

    /**
     * Decide AND act: raise when the decision is to block, otherwise hand back
     * the text the skill should run on.
     *
     * Raising is the mechanism because it is the only one that does not depend
     * on the caller checking a return value — a hook that returns "please stop"
     * into a platform that ignores return values has stopped nothing. Whether
     * the platform honours the raise is the open question above.
     *
     * @param {object} args `{ skill, text, correlationId? }`
     * @returns {string} the text the skill should run on
     * @throws {Error} when the run must not proceed
     */
    enforce: function (args) {
        var verdict = this.evaluate(args);
        if (verdict.block) {
            this._log('blocking the "' + String((args || {}).skill || '') + '" skill run (' +
                verdict.reason + '); evidence ' + verdict.evidenceId);
            throw new Error(LucairnSkillGuard.ERROR_PREFIX + verdict.reason +
                ' (correlation ' + verdict.correlationId + ')');
        }
        return verdict.text;
    },

    type: 'LucairnSkillGuard'
};

if (typeof module !== 'undefined' && module.exports) {
    module.exports = LucairnSkillGuard;
}
