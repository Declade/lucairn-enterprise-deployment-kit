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
 * HOW THE SANITIZED TEXT IS PUBLISHED — THE ONE INVARIANT
 * -------------------------------------------------------
 * **This hook may not return normally unless the destination the platform
 * CONSUMES positively reads back the sanitized text.** Every other outcome —
 * a destination that refused the write, one that cannot be read, one that
 * reads back something else, or no destination at all — RAISES.
 *
 * Raising is the safe half of the trade. A raised hook is fail-closed at the
 * platform layer: the run stops, Leg 6 sees "no summary + an error", and its
 * "distinguishing (b) from a crash" step is what tells a wiring failure apart
 * from a decision. Returning normally while the consumed destination still
 * holds the ORIGINAL submission is the outcome this file is not allowed to
 * have: raw content, forwarded to the model, under a covered verdict, with no
 * error and no annotation.
 *
 * THREE ROUNDS OF GETTING THIS WRONG, AND WHY THE FIX LOOKS LIKE IT DOES
 * ----------------------------------------------------------------------
 * Round 2 shipped a bare `output = verdict.text`. This body is strict-mode, so
 * an assignment to an unresolvable reference is a ReferenceError, not an
 * implicit global: if the extension point does not pre-declare `output`, EVERY
 * protected run aborted. And an aborted run produces no summary and an error —
 * exactly the observables Leg 6 lists for "blocked", so a total outage would
 * have been scored as "blocking works". Round-2 finding N-1.
 *
 * Round 3 wrapped it: `try { output = … } catch { globalScope.output = … }`.
 * That catch does not only catch "there is no such binding"; it also catches an
 * assignment the binding REJECTED (a read-only accessor, a frozen property, a
 * throwing setter). The recovery was then a lie — sanitized text onto the
 * global scope, a normal return, and the binding the platform actually reads
 * back still holding the raw submission. Round-3 finding P1.
 *
 * Round 4 asked the two questions separately: a READ probe for "does the
 * binding exist?", an unguarded write for "did it take?". That still classified
 * by EXCEPTION TYPE — a probe read that threw ReferenceError was read as
 * absence — and a `with`-scoped `output` whose getter throws a same-realm
 * ReferenceError on its first read (then returns the raw text) and whose setter
 * rejects walked straight through it into the global fallback. Round-4 finding.
 *
 * The lesson the three rounds share: **no exception type can establish where a
 * value ended up.** Any of them can be produced deliberately by a hostile or
 * merely odd scope object. So this version classifies by exception type
 * nowhere. It writes, then READS BACK and compares to the exact string it
 * meant to publish, and only a successful comparison counts as published.
 *
 * THE DESTINATION TIERS (all four hypotheses, in preference order)
 * ---------------------------------------------------------------
 *   1. `outputs.text` — an output container object handed to the script.
 *   2. `api.setOutput(value)` / `api.getOutput()` — a host API pair.
 *   3. the bare `output` identifier, in whatever scope it is declared.
 *   4. `globalScope.output` — where a sloppy-mode assignment would have landed
 *      had `output` never been declared.
 *
 * Tiers 1 and 2 are UNVERIFIED SHAPE HYPOTHESES exactly like the `input` and
 * `output` names themselves; none has been observed on an instance, and the PDI
 * run replaces them (ADJUST-ON-PDI). They are tried FIRST because an explicitly
 * provided container is a far better answer than a bare identifier — but being
 * provided earns no trust here either: each is written, read back and compared,
 * and a tier that cannot be verified is skipped, not believed.
 *
 * Tier 4's verification deserves its own sentence, because it is the round-4
 * fix. After writing `globalScope.output`, this file re-reads the BARE
 * IDENTIFIER `output`, not `globalScope.output`. If `output` was genuinely
 * undeclared, the bare identifier now resolves to the global property and reads
 * back the sanitized text — verified. If `output` was a declared binding that
 * merely rejected the write (a lexical `const`, a `with`-scoped accessor), the
 * bare identifier still resolves to THAT binding, still reads back the raw
 * text, and the write is undone and the hook raises. Verifying the global slot
 * we just wrote would only ever confirm our own write.
 *
 * A return-value convention is NOT implemented. This body is pasted INTO the
 * extension point, so a `return` here returns from the IIFE and reaches no
 * platform. If the PDI shows the real contract is a return value, the wrapper
 * goes and the two ADJUST-ON-PDI lines change — record that in Leg 6 rather
 * than assuming any tier below covered it.
 *
 * ANTI-SPOOF BOUNDARY — SAY THIS PLAINLY
 * --------------------------------------
 * A read-back comparison defeats a destination that REFUSES or MISDIRECTS a
 * write. It does not defeat a destination that LIES on read-back — an accessor
 * that returns the sanitized text while retaining the raw text for the platform
 * is indistinguishable from a working one, from inside this script. That
 * adversary is out of scope, and nothing here should be read as excluding it.
 * The guarantee this file offers is the weaker, honest one: no SILENT path
 * exists where the hook returns normally having only been REFUSED.
 *
 * The publish-failure error is content-free AND carries no engine text. A
 * hostile destination controls the message of the exception it throws, so
 * forwarding it would hand an untrusted string to whatever reads the error.
 * It also deliberately does NOT reuse LucairnSkillGuard.ERROR_PREFIX: a Leg 6
 * observer reading "skill run blocked" for what is really a wiring failure
 * would score outcome (a) on a broken hook.
 *
 * test/hook.test.js executes this file in `node:vm` against every shape named
 * above — including the round-4 `with`-scope reproducer verbatim — rather than
 * grepping it for the right-looking words.
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
 *   7. RECORD WHICH DESTINATION THE INSTANCE ACTUALLY EXPOSES. If an allowed
 *      run raises `hook could not publish its output`, none of the four tiers
 *      above matched — that is a wiring finding, not a product one, and the
 *      fix is the two ADJUST-ON-PDI lines plus a tier that can verify whatever
 *      the record does expose. Do not "fix" it by removing the verification.
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
    // ADJUST-ON-PDI: publish to whatever the extension point reads back.

    /* Read the bare `output` identifier — whatever scope it resolves in — and
     * report WHETHER it could be read alongside what it read. It returns a
     * record instead of throwing on purpose: no caller in this file is allowed
     * to branch on the TYPE of the failure (header, round-4 finding). An
     * unreadable destination and a mismatched one are the same answer here —
     * "not verified". */
    function readBareOutput() {
        try {
            /* eslint-disable-next-line no-undef */
            return { read: true, value: output };
        } catch (unreadable) {
            return { read: false, value: null };
        }
    }

    /* Is the bare `output` identifier now holding exactly what we published? */
    function bareOutputHolds(value) {
        var seen = readBareOutput();
        return seen.read && seen.value === value;
    }

    /* Write `value` into `holder[field]`, then read it back. TRUE only on an
     * exact match. A refused write and a lying-by-omission one are both FALSE,
     * and neither is distinguished by the exception it did or did not throw. */
    function publishToField(holder, field, value) {
        try {
            holder[field] = value;
        } catch (writeRejected) {
            /* Deliberately swallowed: the read-back below is the only thing
             * allowed to decide, and it is about to run either way. */
        }
        try {
            return holder[field] === value;
        } catch (readBackFailed) {
            return false;
        }
    }

    /* The same contract for a setter/getter API pair. A host that offers a
     * setter but NO reader cannot be verified, so it is not used — this file
     * does not have a tier that assumes. If the PDI shows that IS the real
     * shape, Leg 6 records it and this function gains a way to read it. */
    function publishViaApi(host, value) {
        try {
            if (typeof host.setOutput !== 'function' ||
                typeof host.getOutput !== 'function') { return false; }
            try {
                host.setOutput(value);
            } catch (callRejected) { /* the read-back decides */ }
            return host.getOutput() === value;
        } catch (apiUnusable) {
            return false;
        }
    }

    var published = false;

    /* TIER 1 (HYPOTHESIS, ADJUST-ON-PDI) — an output container object the
     * extension point hands the script. Detection is wrapped because `typeof`
     * on a scope accessor can itself throw; a container that cannot even be
     * detected is simply not a destination. */
    try {
        /* eslint-disable-next-line no-undef */
        if (typeof outputs !== 'undefined' && outputs !== null) {
            /* eslint-disable-next-line no-undef */
            published = publishToField(outputs, 'text', verdict.text);
        }
    } catch (noOutputsContainer) {
        published = false;
    }

    /* TIER 2 (HYPOTHESIS, ADJUST-ON-PDI) — a host API pair. */
    if (!published) {
        try {
            /* eslint-disable-next-line no-undef */
            if (typeof api !== 'undefined' && api !== null) {
                /* eslint-disable-next-line no-undef */
                published = publishViaApi(api, verdict.text);
            }
        } catch (noHostApi) {
            published = false;
        }
    }

    /* TIER 3 — the bare `output` identifier, write-then-verify. The write is
     * attempted blind and its outcome is ignored; only the read-back counts.
     * This is where a rejecting binding (lexical `const`, throwing setter,
     * frozen property) stops being able to produce a false success. */
    if (!published) {
        try {
            /* eslint-disable-next-line no-undef */
            output = verdict.text;
        } catch (bareWriteRejected) { /* the read-back decides */ }
        published = bareOutputHolds(verdict.text);
    }

    /* TIER 4 — the script's global scope: where a sloppy-mode `output = …`
     * would have landed had `output` never been declared (finding N-1, the
     * abort-every-protected-run case).
     *
     * The verification afterwards re-reads the BARE IDENTIFIER, not the global
     * property we just wrote. That is the round-4 fix: if `output` was a real
     * binding that merely refused us, the identifier still resolves to IT, the
     * comparison fails, and this write is UNDONE before the raise — so nothing
     * downstream can mistake a leftover global value for a successful publish,
     * and Leg 6 sees a clean failure rather than a half-written state. */
    if (!published && globalScope) {
        var hadOwnOutput = false;
        var priorOutput;
        try {
            hadOwnOutput = Object.prototype.hasOwnProperty.call(globalScope, 'output');
            if (hadOwnOutput) { priorOutput = globalScope.output; }
        } catch (priorStateUnreadable) {
            /* A prior value we cannot read is a prior value we cannot restore;
             * the undo below removes the property instead. Recorded here rather
             * than hidden, because it is a real (if narrow) state change. */
            hadOwnOutput = false;
        }

        try {
            globalScope.output = verdict.text;
        } catch (globalWriteRejected) { /* the read-back decides */ }

        published = bareOutputHolds(verdict.text);

        if (!published) {
            try {
                if (hadOwnOutput) { globalScope.output = priorOutput; }
                else { delete globalScope.output; }
            } catch (undoFailed) {
                /* Nothing further to try. The raise below still stops the run,
                 * which is the property that matters. */
            }
        }
    }

    if (!published) {
        /* No destination read back the sanitized text. Content-free, no engine
         * text, and under its OWN prefix — a Leg 6 observer must not read this
         * as "skill run blocked". */
        throw new Error('[Lucairn for Now Assist] hook could not publish its ' +
            'output: no destination read back the sanitized text ' +
            '(correlation ' + verdict.correlationId + ')');
    }
}(function () {
    /* The script's global scope, in decreasing order of reliability.
     *
     * `globalThis` is ES2020 and absent on Rhino. The classic ES5 substitute,
     * an indirect `this`, is `undefined` when an enclosing wrapper is strict —
     * round-3 advisory. The `Function` constructor builds a NON-strict function
     * regardless of the calling code's strictness, so its `this` is the global
     * object even inside a strict wrapper; a runtime that withholds `Function`
     * (or a scoped-app sandbox that blocks it) lands on null, the last
     * destination tier is skipped, and the publish check raises rather than
     * pretending anything was published. */
    if (typeof globalThis !== 'undefined') { return globalThis; }
    var indirectThis = (function () { return this; }());
    if (indirectThis) { return indirectThis; }
    try {
        return Function('return this')();
    } catch (noFunctionConstructor) {
        return null;
    }
}()));
