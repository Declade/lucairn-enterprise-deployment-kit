/*
 * GenAI Preprocessor hook — PASTE-IN STUB
 * =======================================
 *
 * ⚠️⚠️ THIS FILE IS A HYPOTHESIS. It has never executed on an instance.
 *
 * It exists so that `allowed: false` from LucairnNowAssistAdapter.protect() has
 * something that CONSUMES it. Without a hook wired somewhere, the adapter can
 * decide a run must not proceed and the run proceeds anyway — the PRD's
 * acceptance criterion is a blocked SKILL RUN, not a blocked adapter return.
 * Round-1 gate finding 7 / D-1 (specs/2026-09/gate-2026-09-10-kit-pr133-s1.md).
 *
 * WHAT IS UNPROVEN, PRECISELY
 * ---------------------------
 *   1. That a preprocessor extension point exists and is invocable for the
 *      target skill on the target release.
 *   2. That the script receives the submitted text, and receives ALL of it —
 *      context appended after the hook would never reach the sanitizer, and the
 *      certificate would then attest a fragment. (PRD § Failure modes.)
 *   3. That raising here ABORTS the run rather than being logged and ignored.
 *   4. The names of the input and output the platform hands the script.
 *
 * Item 4 is why the first two lines of run() are marked ADJUST-ON-PDI. The
 * variable names below are the documented-model guess; the PDI run replaces
 * them with what the record actually exposes, and the change is two lines.
 *
 * WHY THE OUTPUT ASSIGNMENT IS NOT A BARE `output = …`
 * ----------------------------------------------------
 * This body is strict-mode, and in strict mode an assignment to an unresolvable
 * reference is a ReferenceError rather than an implicit global. If the
 * extension point does not pre-declare `output`, a bare `output = verdict.text`
 * therefore THROWS on the ALLOWED path — every protected run aborts.
 *
 * That failure is invisible in the acceptance leg, which is what makes it
 * dangerous rather than merely broken: an aborted hook produces no summary and
 * an error, i.e. exactly the observables Leg 6 lists for "blocked". A total
 * outage would have been scored as "blocking works". Round-2 gate finding N-1.
 *
 * The assignment below therefore tries the declared binding first and falls
 * back to the script's global scope, and test/hook.test.js executes this file
 * in `node:vm` — both paths, with and without a pre-declared `output` — rather
 * than grepping it for the right-looking words.
 *
 * NONE of 1-4 may be asserted in packaging, a deck or customer copy until the
 * gate record for README § Verify on the PDI, Leg 6 says which way each went.
 *
 * WIRING (PDI-time step, part of "Build on the PDI")
 * -------------------------------------------------
 *   1. Build the application and its five Script Includes first, and get Leg 1
 *      of the runbook green. A hook on top of an unproven round trip cannot be
 *      diagnosed.
 *   2. Create the sixth Script Include, `LucairnSkillGuard`, from
 *      ../script_includes/LucairnSkillGuard.js.
 *   3. Clone the OOTB skill you are protecting (Now Assist Skill Kit →
 *      Incident summarization → clone). Only a clone is editable.
 *   4. On the clone, open the pre-inference extension point and paste the body
 *      of run() below into it. The candidate carriers, in the order to try
 *      them, are the hypothesis tables named in the PRD § In scope:
 *      `sys_one_extend_capability_definition`,
 *      `sys_generative_ai_request_validator`, `sys_generative_ai_validator`.
 *      RECORD which one accepted the script, and which ones do not exist on the
 *      instance family you are on — that list is itself a finding.
 *   5. Set the skill name below to match the policy row exactly. The policy
 *      table is keyed on this string, and a mismatch reads as "no override",
 *      which is fail-closed — safe, but confusing to debug.
 *   6. Run Leg 6. Record outcome (a), (b) or (c) from the LucairnSkillGuard
 *      header.
 *
 * ES5 only (Rhino-compatible).
 */
(function (globalScope) {
    'use strict';

    /* ADJUST-ON-PDI (1/2): the name the extension point uses for the submitted
     * text. `input`, `inputs.text` and `payload.prompt` are all plausible; the
     * record's own field list settles it. */
    var submittedText = (typeof input !== 'undefined' && input !== null) ? String(input) : '';

    /* ADJUST-ON-PDI (2/2): must match `skill_name` on the policy row exactly. */
    var SKILL_NAME = 'Incident summarization';

    var guard = new LucairnSkillGuard();
    var verdict = guard.evaluate({ skill: SKILL_NAME, text: submittedText });

    if (verdict.block) {
        /* Raise, rather than returning a flag. A hook that returns "please
         * stop" into a platform that ignores return values has stopped nothing.
         *
         * If the raise turns out to be swallowed — outcome (b) — this is the
         * line whose behaviour proves it, and the blocking claim dies here
         * rather than in a customer's instance.
         *
         * NOTE, and say this out loud in the Leg 6 record: raising exits the
         * hook HERE. The assignment below never runs, so on outcome (b) the
         * skill proceeds on whatever the extension point already held — the
         * ORIGINAL submitted text, with no annotation. A swallowed raise is not
         * a degraded-but-labelled run; it is an unlabelled unprotected one. */
        throw new Error(LucairnSkillGuard.ERROR_PREFIX + verdict.reason +
            ' (correlation ' + verdict.correlationId + ')');
    }

    /* Covered: `verdict.text` is the sanitized text.
     * Uncovered (an administrator's fail-open override): `verdict.text` is the
     * least content available, carrying a visible annotation saying the run is
     * not covered and no certificate exists. Either way the skill runs on
     * verdict.text and never on the original. */
    // ADJUST-ON-PDI: assign to whatever the extension point reads back.
    try {
        /* The declared binding, whatever scope the extension point declared it
         * in. This is the path that runs when the platform pre-declares
         * `output`, and it is the one that reaches a function-scoped binding. */
        // eslint-disable-next-line no-undef
        output = verdict.text;
    } catch (unresolvableOutputBinding) {
        /* Strict mode + no declared `output` ⇒ ReferenceError, which used to
         * abort the whole protected run (finding N-1). Publish onto the script's
         * global scope instead, which is where a sloppy-mode `output = …` would
         * have landed the value anyway.
         *
         * If the extension point reads a binding that is neither pre-declared
         * nor global, NEITHER path reaches it — record that in Leg 6 as outcome
         * (c)-adjacent and change the two ADJUST-ON-PDI lines rather than
         * assuming this fallback covered it. */
        globalScope.output = verdict.text;
    }
}(typeof globalThis !== 'undefined' ? globalThis : (function () { return this; }())));
