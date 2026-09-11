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
 *   4. The names of the input and output the platform hands the script, and
 *      WHICH of the four destination shapes below the platform consumes.
 *
 * Item 4 is why the first two lines of run() are marked ADJUST-ON-PDI, and why
 * the destination is a CONFIGURED value rather than a search — see below.
 *
 * HOW THE SANITIZED TEXT IS PUBLISHED — THE ONE INVARIANT
 * -------------------------------------------------------
 * **This hook may not return normally unless the DECLARED destination positively
 * reads back the sanitized text, on a fresh evaluation of the configured
 * expression.** Every other outcome — a destination that refused the write, one
 * that cannot be read, one that reads back something else, one that hands out a
 * fresh wrapper per read, or no destination at all — RAISES.
 *
 * Say the gap in that sentence out loud: DECLARED, not consumed. The hook
 * verifies the destination it was configured with. If an administrator declares
 * a RECOGNISED destination that is not the one this extension point exposes to
 * the platform, the hook can verify its own destination perfectly and return
 * normally while the consumed one still holds the raw submission — no error, no
 * annotation. Nothing in-process can close that gap: which slot a platform reads
 * is not observable from inside the script (§ EXACTLY ONE DESTINATION). It is
 * closed by OBSERVATION — § WIRING step 7 below, run as part of Leg 6, whose
 * coverage half is the only check that can tell a right destination from a
 * wrong-but-recognised one — and by restricting who may write the property
 * (../records/properties.md § "output_destination — write authority").
 *
 * Raising is the safe half of the trade. A raised hook is fail-closed at the
 * platform layer: the run stops, Leg 6 sees "no summary + an error", and its
 * "distinguishing (b) from a crash" step is what tells a wiring failure apart
 * from a decision. Returning normally while the consumed destination still
 * holds the ORIGINAL submission is the outcome this file is not allowed to
 * have: raw content, forwarded to the model, under a covered verdict, with no
 * error and no annotation.
 *
 * EXACTLY ONE DESTINATION PER EXECUTION — AND WHY THE TIERS ARE GONE
 * ------------------------------------------------------------------
 * Rounds 2, 3 and 4 each fixed one destination and left a LADDER: try shape 1,
 * and on failure try shape 2, then 3, then 4. Round 5 found the ladder itself
 * to be the defect, independently of how well any single rung was verified.
 *
 * A ladder can verify ONE destination while the platform consumes a DIFFERENT
 * one that still holds the raw submission. Both directions were reproduced:
 *
 *   - a consumed `outputs.text` frozen on the RAW submission REFUSES the write,
 *     the ladder falls through to a perfectly writable bare `output`, verifies
 *     THAT, and returns normally — while the platform reads `outputs.text`,
 *     which is still raw;
 *   - and the mirror image: a host `api` that accepts and reads back the
 *     sanitized text is verified first, so a REJECTING bare `output` — the
 *     binding the platform actually consumes — is never even written.
 *
 * Neither destination lied. Neither rung was wrong about itself. The FALLING
 * THROUGH is the flaw: a hook cannot discover which slot a platform reads by
 * writing to slots until one of them answers. So this version does not search.
 *
 * **The destination is declared, in configuration, and only that destination is
 * ever touched.** It is written, read back and compared; a mismatch, an
 * unreadable destination, an absent one, or an unrecognised configuration value
 * all RAISE. No other destination is attempted, written, or consulted — which
 * is also why no undo path is needed for destinations we never wrote to.
 *
 * The configuration value lives in the system property
 * `lucairn.now_assist.output_destination` (registered as
 * `LucairnConfig.PROP.OUTPUT_DESTINATION`; documented in
 * ../records/properties.md), and takes exactly one of:
 *
 *   | value             | the hook writes and reads back                       |
 *   |-------------------|------------------------------------------------------|
 *   | `bare_output`     | the bare `output` identifier, in whatever scope it    |
 *   |   (DEFAULT)       | resolves. The most likely contract, so it is what an  |
 *   |                   | unset property means.                                 |
 *   | `outputs_text`    | `outputs.text` on an output container object, with    |
 *   |                   | `outputs` resolved AFRESH for the read-back.          |
 *   | `api_set_output`  | `api.setOutput(v)` written, then `api` resolved       |
 *   |                   | AFRESH and `api.getOutput()` called to read back.     |
 *   | `global_output`   | `globalScope.output`, VERIFIED by re-reading the bare |
 *   |                   | identifier — see its own note below.                  |
 *
 * ⚠️ **ALL FOUR ARE ADJUST-ON-PDI HYPOTHESES.** Not one of them has been
 * observed on an instance. The default is a guess about which guess is most
 * likely, nothing more; Leg 6 step 7 is where it gets replaced by an
 * observation. If the PDI shows the real contract is a fifth shape, the fix is
 * a new destination that can be verified — never a fallback to one that cannot.
 *
 * Two consequences of deleting the ladder, stated plainly rather than
 * discovered later:
 *
 *   - Under the DEFAULT `bare_output`, an extension point that pre-declares no
 *     `output` binding at all now RAISES, where the old tier 4 would silently
 *     have created a global. That case is a CONFIGURATION answer
 *     (`global_output`), not a fallback. Fail-closed and visible beats
 *     fail-quiet: round-2 finding N-1 was a total outage that Leg 6 would have
 *     scored as "blocking works", and the cure for it is the error text below,
 *     which says wiring rather than block.
 *   - A misconfigured destination is discovered AFTER the sanitize round trip,
 *     because the block decision must win the race for the error text: a
 *     blocked run has to raise the BLOCK error, not a wiring one. The cost is a
 *     discarded service call on a misconfigured instance; the benefit is that
 *     Leg 6 never reads a wiring failure as outcome (a).
 *
 * `global_output` deserves its own sentence, because its verification is not
 * the obvious one. After writing `globalScope.output`, this file re-reads the
 * BARE IDENTIFIER `output`, not `globalScope.output`. If `output` was genuinely
 * undeclared, the bare identifier now resolves to the global property and reads
 * back the sanitized text — verified. If `output` was a declared binding that
 * shadows the global (a lexical `const`, a `with`-scoped accessor), the bare
 * identifier still resolves to THAT binding, reads back something else, and the
 * hook raises. Verifying the global slot we just wrote would only ever confirm
 * our own write.
 *
 * THREE ROUNDS OF GETTING THE *WRITE* WRONG, AND ONE OF GETTING THE SHAPE WRONG
 * -----------------------------------------------------------------------------
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
 * Round 5 removed the ladder, above.
 *
 * Round 6 found the same family one level down, in the read-back itself. The
 * `outputs_text` and `api_set_output` destinations resolved their root
 * identifier ONCE and then wrote and verified through that captured object. A
 * `with`-scoped `outputs` accessor that hands out a FRESH object per read
 * defeats it without lying: our copy honestly holds the sanitized text, the
 * comparison passes, the hook returns normally — and the platform's next
 * `outputs.text` lookup returns a different object still holding RAW. A
 * per-read `api` wrapper reproduces it identically. Round-6 finding.
 *
 * The lesson rounds 2-4 share: **no exception type can establish where a value
 * ended up.** Any of them can be produced deliberately by a hostile or merely
 * odd scope object. So this version classifies by exception type nowhere. It
 * writes, then READS BACK and compares to the exact string it meant to publish,
 * and only a successful comparison counts as published.
 *
 * The lesson round 5 adds: **no sequence of writes can establish which slot a
 * platform reads.** Verifying a destination answers "did my write land HERE",
 * never "is HERE what gets consumed". Only configuration — ultimately, only the
 * PDI observation behind the configuration — answers the second question.
 *
 * The lesson round 6 adds, and it is the one that generalises all of them:
 * **a read-back through an artifact the hook is holding proves nothing about
 * what the platform will read.** Every destination below therefore verifies by
 * RE-EVALUATING its configured expression from scratch — a fresh `outputs`
 * lookup, a fresh `api` lookup and reader call, a fresh read of the bare
 * `output` identifier — through the same binding path the platform would use.
 * Nothing captured before the write is allowed to answer for it.
 *
 * A return-value convention is NOT implemented. This body is pasted INTO the
 * extension point, so a `return` here returns from the IIFE and reaches no
 * platform. If the PDI shows the real contract is a return value, the wrapper
 * goes and the ADJUST-ON-PDI lines change — record that in Leg 6 rather than
 * assuming any destination above covered it.
 *
 * ANTI-SPOOF BOUNDARY — SAY THIS PLAINLY
 * --------------------------------------
 * A read-back comparison defeats a destination that REFUSES or MISDIRECTS a
 * write. Re-evaluating the configured expression (round 6) additionally defeats
 * a destination that REFRESHES PER READ — a wrapper handed out anew on every
 * lookup, which would otherwise verify itself while the platform reads a
 * different instance.
 *
 * It does not defeat a destination that LIES on read-back — an accessor that
 * returns the sanitized text to US while retaining the raw text for the
 * platform's later read is indistinguishable from a working one, from inside
 * this script. That adversary is out of scope, and nothing here should be read
 * as excluding it. The line between the two is worth stating precisely: a
 * refresh-per-read wrapper answers the SAME question honestly from a different
 * object, and re-reading catches it; a lying reader answers the same question
 * differently depending on who asks, and nothing in-process can catch that.
 * The guarantee this file offers is the weaker, honest one: no SILENT path
 * exists where the hook returns normally having only been REFUSED, MISDIRECTED,
 * or verified against an object the platform does not read.
 *
 * The publish-failure error is content-free AND carries no engine text. A
 * hostile destination controls the message of the exception it throws, so
 * forwarding it would hand an untrusted string to whatever reads the error. It
 * quotes the DECLARED destination and, on a configuration error, the
 * configured value capped to 40 characters — administrator configuration, never
 * request content. It also deliberately does NOT reuse
 * LucairnSkillGuard.ERROR_PREFIX: a Leg 6 observer reading "skill run blocked"
 * for what is really a wiring failure would score outcome (a) on a broken hook.
 * Every wiring failure — unreadable configuration, unrecognised value,
 * unverified destination — says `hook could not publish its output:`, so Leg 6
 * needs exactly one discriminator.
 *
 * test/hook.test.js executes this file in `node:vm` against every shape named
 * above — including the round-4 `with`-scope reproducer and both round-5
 * competing-destination countermodels verbatim — rather than grepping it for
 * the right-looking words.
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
 *   7. RECORD WHICH DESTINATION THE INSTANCE ACTUALLY EXPOSES, and set
 *      `lucairn.now_assist.output_destination` to it. If an allowed run raises
 *      `hook could not publish its output`, the declared destination is not the
 *      one this extension point exposes — that is a wiring finding, not a
 *      product one, and the fix is the property plus, if needed, the
 *      ADJUST-ON-PDI lines. Do NOT "fix" it by trying another destination in
 *      code on failure: that ladder is the round-5 defect, and it can verify a
 *      slot nobody reads while the consumed one stays raw.
 *
 *      ⚠️ A run that does NOT raise is not yet proof the destination is right —
 *      a recognised-but-wrong value verifies itself and returns normally. The
 *      proof is Leg 6's COVERAGE half: an allowed run whose summary is visibly
 *      sanitized. Record the destination value alongside the outcome letter; a
 *      Leg 6 record that does not name it has not verified it.
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

    /* The declared-destination configuration. The property name is duplicated
     * from LucairnConfig.PROP.OUTPUT_DESTINATION on purpose — this body is
     * PASTED into an extension point and cannot require a Script Include just to
     * read one string — and test/hook.test.js asserts the two literals match, so
     * the duplication cannot drift silently. */
    var DESTINATION_PROPERTY = 'lucairn.now_assist.output_destination';
    var DESTINATION_DEFAULT = 'bare_output';
    var DESTINATIONS = ['bare_output', 'outputs_text', 'api_set_output', 'global_output'];

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

    /* Every wiring failure carries this one prefix and this one phrase, so a
     * Leg 6 observer has a single discriminator to apply and never has to
     * decide whether an unfamiliar message counts. */
    function publishFailure(reason) {
        return new Error('[Lucairn for Now Assist] hook could not publish its ' +
            'output: ' + reason + ' (correlation ' + verdict.correlationId + ')');
    }

    /* Administrator configuration quoted back into an error message. Never
     * request content — but bounded on principle, exactly as LucairnConfig
     * bounds the values it quotes into validation problems. */
    function shortValue(v) {
        var s = String(v === null || v === undefined ? '' : v);
        return s.length > 40 ? s.substring(0, 40) + '…' : s;
    }

    /* ---- which destination, and only that one --------------------------- */

    /* Read the declared destination. Returns whether it could be READ at all
     * alongside the value, because "the property service could not answer" and
     * "the property is unset" are different answers with different outcomes:
     * unset means the documented default, unreadable means RAISE. Guessing a
     * destination when the configured one is unknowable is the round-5 defect
     * wearing a different hat — it is exactly how a hook comes to verify a slot
     * the operator did not choose. */
    function readDeclaredDestination() {
        var service = null;
        try {
            /* eslint-disable-next-line no-undef */
            service = (typeof gs !== 'undefined' && gs !== null) ? gs : null;
        } catch (noPropertyService) {
            service = null;
        }
        if (!service) { return { read: false, value: '' }; }
        /* Round-6 gate advisory: LOOKING UP `getProperty` can itself throw — it
         * may be an accessor, and a scope object controls what its accessors do.
         * Unwrapped, that exception escaped this function with ITS OWN message,
         * which both leaks engine text and destroys the single
         * `hook could not publish its output:` discriminator Leg 6 relies on. */
        var accessor;
        try {
            accessor = service.getProperty;
        } catch (accessorThrew) {
            return { read: false, value: '' };
        }
        if (typeof accessor !== 'function') {
            return { read: false, value: '' };
        }
        try {
            var raw = service.getProperty(DESTINATION_PROPERTY, '');
            return { read: true, value: (raw === null || raw === undefined) ? '' : String(raw) };
        } catch (propertyUnreadable) {
            return { read: false, value: '' };
        }
    }

    var declared = readDeclaredDestination();
    if (!declared.read) {
        throw publishFailure('the output-destination property ' +
            DESTINATION_PROPERTY + ' could not be read');
    }

    var destination = declared.value.replace(/^\s+|\s+$/g, '').toLowerCase();
    if (!destination) {
        destination = DESTINATION_DEFAULT;
    }
    if (DESTINATIONS.indexOf(destination) === -1) {
        /* Fail closed on a typo. The tempting alternative — "unrecognised, so
         * use the default" — silently publishes somewhere the operator did not
         * choose, which is the whole class this round deleted. */
        throw publishFailure('output destination "' + shortValue(destination) +
            '" is not one of: ' + DESTINATIONS.join(', '));
    }

    /* ---- write, read back, compare; nothing else counts ------------------ */

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

    /* DESTINATION `outputs_text` (HYPOTHESIS, ADJUST-ON-PDI) — an output
     * container object the extension point hands the script.
     *
     * ROUND-6 GATE FINDING — WHY THE WRITE AND THE READ-BACK ARE SEPARATE
     * LOOKUPS. The previous version resolved `outputs` once, handed that OBJECT
     * to a helper, and had the helper write and verify through the reference it
     * was given. That is rounds 2-4's mistake in a new costume: it trusts a
     * CAPTURED artifact. A `with`-scoped `outputs` accessor that returns a FRESH
     * object on every read then verifies TRUTHFULLY — the copy we wrote really
     * does hold the sanitized text — while the platform's own next `outputs.text`
     * lookup gets a different, still-raw object. Nobody lied; we verified a
     * container the platform never sees.
     *
     * So the read-back RE-EVALUATES the configured expression from scratch,
     * through the same binding path the platform would use. It must not reuse
     * anything the write touched. */
    function publishToOutputsText(value) {
        try {
            /* Detection is wrapped because `typeof` on a scope accessor can
             * itself throw; a container that cannot even be detected is not a
             * destination, and because it is the DECLARED one there is nowhere
             * else to go. */
            /* eslint-disable-next-line no-undef */
            if (typeof outputs === 'undefined' || outputs === null) { return false; }
            /* eslint-disable-next-line no-undef */
            outputs.text = value;
        } catch (writeUnavailableOrRejected) {
            /* Deliberately swallowed: the fresh read-back below is the only
             * thing allowed to decide, and it is about to run either way. */
        }
        try {
            /* A FRESH `outputs` lookup — NOT the object the write used. */
            /* eslint-disable-next-line no-undef */
            return outputs.text === value;
        } catch (readBackFailed) {
            return false;
        }
    }

    /* DESTINATION `api_set_output` (HYPOTHESIS, ADJUST-ON-PDI) — a host API
     * pair. A host that offers a setter but NO reader cannot be verified, so it
     * is not used: this file does not have a destination that assumes. If the
     * PDI shows that IS the real shape, Leg 6 records it and this function gains
     * a way to read it — it does not gain a way to skip the reading.
     *
     * Same round-6 rule as `outputs_text`: the verifying `api.getOutput()` call
     * goes through a FRESH `api` lookup, never a host object captured before the
     * write. A wrapper handed out per-read would otherwise answer for itself. */
    function publishViaApi(value) {
        try {
            /* eslint-disable-next-line no-undef */
            if (typeof api === 'undefined' || api === null) { return false; }
            /* eslint-disable-next-line no-undef */
            if (typeof api.setOutput !== 'function' ||
                /* eslint-disable-next-line no-undef */
                typeof api.getOutput !== 'function') { return false; }
            /* eslint-disable-next-line no-undef */
            api.setOutput(value);
        } catch (apiUnusableOrRejected) {
            /* the fresh read-back below decides */
        }
        try {
            /* A FRESH `api` lookup and a FRESH reader call. */
            /* eslint-disable-next-line no-undef */
            return api.getOutput() === value;
        } catch (readBackFailed) {
            return false;
        }
    }

    /* DESTINATION `bare_output` (DEFAULT) — the bare `output` identifier,
     * write-then-verify. The write is attempted blind and its outcome is
     * ignored; only the read-back counts. This is where a rejecting binding
     * (lexical `const`, throwing setter, frozen property) stops being able to
     * produce a false success — and, with the ladder gone, stops being able to
     * hand the run to some other slot instead. */
    function publishToBareOutput(value) {
        try {
            /* eslint-disable-next-line no-undef */
            output = value;
        } catch (bareWriteRejected) { /* the read-back decides */ }
        return bareOutputHolds(value);
    }

    /* DESTINATION `global_output` — the script's global scope: where a
     * sloppy-mode `output = …` would have landed had `output` never been
     * declared. Declare this one when the extension point pre-declares no
     * `output` binding at all.
     *
     * The verification re-reads the BARE IDENTIFIER, not the global property we
     * just wrote: if `output` is a real binding that shadows the global, the
     * identifier resolves to IT, the comparison fails, and the hook raises.
     *
     * The write is then undone on a BEST-EFFORT basis — restored if there was a
     * prior own value we could read, deleted otherwise — so that a failed
     * publish does not leave sanitized text sitting in a slot something
     * downstream might read as a success. It is best-effort and not more than
     * that: if the global slot ALSO refuses the restore, or its prior value
     * could not be read, the sanitized text can remain there. The raise still
     * stops the run, the publish error is still the one that surfaces, and the
     * residual is this sentence rather than a claim of unconditional cleanup.
     * Round-5 advisory; test/hook.test.js exercises the failed restoration. */
    function publishToGlobalOutput(value) {
        if (!globalScope) { return false; }

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
            globalScope.output = value;
        } catch (globalWriteRejected) { /* the read-back decides */ }

        if (bareOutputHolds(value)) { return true; }

        try {
            if (hadOwnOutput) { globalScope.output = priorOutput; }
            else { delete globalScope.output; }
        } catch (undoFailed) {
            /* Best-effort, as documented above: nothing further to try, and the
             * publish failure — not this exception — is what must surface. */
        }
        return false;
    }

    var published = false;
    if (destination === 'outputs_text') {
        published = publishToOutputsText(verdict.text);
    } else if (destination === 'api_set_output') {
        published = publishViaApi(verdict.text);
    } else if (destination === 'bare_output') {
        published = publishToBareOutput(verdict.text);
    } else if (destination === 'global_output') {
        published = publishToGlobalOutput(verdict.text);
    }

    if (!published) {
        /* The declared destination did not read back the sanitized text. No
         * other destination was tried, and none will be: see § EXACTLY ONE
         * DESTINATION. Content-free, no engine text, and under its OWN prefix —
         * a Leg 6 observer must not read this as "skill run blocked". */
        throw publishFailure('the declared destination "' + destination +
            '" did not read back the sanitized text');
    }
}(function () {
    /* The script's global scope, in decreasing order of reliability. Only the
     * `global_output` destination uses it; every other destination ignores it
     * entirely, including when it is null.
     *
     * `globalThis` is ES2020 and absent on Rhino. The classic ES5 substitute,
     * an indirect `this`, is `undefined` when an enclosing wrapper is strict —
     * round-3 advisory. The `Function` constructor builds a NON-strict function
     * regardless of the calling code's strictness, so its `this` is the global
     * object even inside a strict wrapper; a runtime that withholds `Function`
     * (or a scoped-app sandbox that blocks it) lands on null, and a declared
     * `global_output` destination then raises rather than pretending anything
     * was published. */
    if (typeof globalThis !== 'undefined') { return globalThis; }
    var indirectThis = (function () { return this; }());
    if (indirectThis) { return indirectThis; }
    try {
        return Function('return this')();
    } catch (noFunctionConstructor) {
        return null;
    }
}()));
