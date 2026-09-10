'use strict';

/*
 * The GenAI Preprocessor hook, EXECUTED.
 *
 * Round-2 gate finding N-1: the previous test for this file read its source
 * text and asserted that the right words appeared in it, above a comment
 * claiming the hook "cannot be executed here". That was wrong twice over — it
 * can be executed, and while it was only being grepped it contained a
 * ReferenceError on its own success path: a strict-mode `output = verdict.text`
 * with no declared `output` binding aborts EVERY allowed run.
 *
 * A grep cannot see that. `node:vm` can: the hook body is run as a script in a
 * context that supplies exactly what the extension point supplies — an `input`
 * and a `LucairnSkillGuard` — and the assertions are about what the context
 * holds afterwards, which is what the platform would hand the model.
 *
 * The guard in the context is the REAL Script Include over a stubbed adapter,
 * so the covered / uncovered / blocked branches are the real ones. What is
 * faked is only the Lucairn round trip.
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

require('./mocks/servicenow');
const LucairnSkillGuard = require('../src/script_includes/LucairnSkillGuard');

const HOOK_PATH = path.join(__dirname, '..', 'src', 'hooks', 'genai-preprocessor.js');
const HOOK_SOURCE = fs.readFileSync(HOOK_PATH, 'utf8');

const RAW = 'Reported by Brannagh Oduya-Kestrel (brannagh.oduya-kestrel@northmarrow-example.test).';
const SANITIZED = 'Reported by [PERSON_1] ([EMAIL_1]).';

const COVERED = {
    allowed: true, coverage: 'covered', textForSkill: SANITIZED,
    correlationId: 'corr_1', evidenceId: 'ev_1', error: null
};

const UNCOVERED = {
    allowed: true, coverage: 'uncovered', textForSkill: RAW,
    correlationId: 'corr_1', evidenceId: 'ev_1',
    error: { code: 'lucairn_service_unreachable', failure_class: 'connection_refused' }
};

const BLOCKED = {
    allowed: false, coverage: 'uncovered', textForSkill: '',
    correlationId: 'corr_1', evidenceId: 'ev_1',
    error: { code: 'lucairn_service_unreachable', failure_class: 'connection_refused' }
};

/**
 * Run the hook exactly as pasted, in a context that mimics an extension point.
 *
 * @param {object} opts
 * @param {object} opts.protectResult   what the stubbed adapter returns
 * @param {string} [opts.input]         the submitted text the platform exposes
 * @param {boolean} [opts.declareOutput] does the extension point pre-declare
 *   `output`? BOTH answers must work: a pre-declared binding is assigned
 *   directly, an absent one is published onto the script's global scope.
 * @param {boolean} [opts.omitInput]    the platform exposes no `input` at all
 * @param {boolean} [opts.constOutputBinding] the extension point declares
 *   `output` as a LEXICAL constant. This is the round-3 P1 repro and the
 *   sharpest shape of it: the binding resolves, assignment to it is a
 *   TypeError, and — the part that makes the old catch-all fail OPEN rather
 *   than merely fail — the global-scope fallback writes to a DIFFERENT slot,
 *   so it succeeds silently while `output` still reads the original value.
 * @param {boolean} [opts.letOutputBinding] the same lexical shape, WRITABLE —
 *   the control that shows the fix did not break the normal path.
 * @param {boolean} [opts.rejectOutputAssignment] the extension point pre-declares
 *   `output` as a global accessor that REJECTS assignment (a read-only
 *   accessor, a frozen property, a setter that throws) — the same class, in the
 *   shape where the fallback happens to hit the same slot.
 * @param {boolean} [opts.strictEs5Wrapper] wrap the hook in a strict-mode ES5
 *   host script with no `globalThis`, which is what a scoped-app Rhino
 *   extension point can look like. The classic `(function(){return this;}())`
 *   substitute is then `undefined` (round-3 advisory).
 * @param {boolean} [opts.withholdFunctionConstructor] additionally remove
 *   `Function`, leaving the script NO way to reach its own global scope.
 */
function runHook(opts) {
    const seen = [];

    /* A constructor whose instances are the real guard over a stub adapter. */
    function GuardStub() {
        return new LucairnSkillGuard({
            adapter: {
                protect: function (args) {
                    seen.push(args);
                    return opts.protectResult;
                }
            },
            log: function () { }
        });
    }
    GuardStub.ERROR_PREFIX = LucairnSkillGuard.ERROR_PREFIX;
    GuardStub.UNCOVERED_ANNOTATION = LucairnSkillGuard.UNCOVERED_ANNOTATION;
    GuardStub.DECISION = LucairnSkillGuard.DECISION;

    const context = { LucairnSkillGuard: GuardStub };
    if (!opts.omitInput) {
        context.input = opts.input === undefined ? RAW : opts.input;
    }
    if (opts.declareOutput) {
        context.output = '__untouched__';
    }
    if (opts.rejectOutputAssignment) {
        /* A binding that READS fine and REFUSES to be written. `output` still
         * resolves, so this is emphatically not the "no such binding" case. */
        Object.defineProperty(context, 'output', {
            configurable: true,
            enumerable: true,
            get: function () { return '__untouched__'; },
            set: function () { throw new TypeError('this binding rejects assignment'); }
        });
    }
    vm.createContext(context);

    if (opts.strictEs5Wrapper) {
        /* Sloppy-mode host script, so the deletes are legal; the HOOK is then
         * run under an explicit strict wrapper below. */
        vm.runInContext('delete this.globalThis;', context);
        if (opts.withholdFunctionConstructor) {
            vm.runInContext('delete this.Function;', context);
        }
    }

    let prologue = '';
    if (opts.strictEs5Wrapper) { prologue += "'use strict';\n"; }
    if (opts.constOutputBinding || opts.letOutputBinding) {
        /* A lexical binding lives in the realm's global LEXICAL environment,
         * not as a property of the global object — which is precisely why the
         * old fallback could "succeed" without ever reaching it. */
        prologue += "'use strict';\n" +
            (opts.constOutputBinding ? 'const' : 'let') + " output = '__untouched__';\n";
    }
    const source = prologue + HOOK_SOURCE;

    let raised = null;
    try {
        vm.runInContext(source, context, { filename: 'genai-preprocessor.js' });
    } catch (e) {
        raised = e;
    }
    /* Read BOTH slots from inside the realm. `outputInRealm` is what the
     * platform would read back — the lexical binding when there is one, the
     * global property otherwise. `globalPropInRealm` is where the fallback
     * writes. When they differ, a fallback that fired is a fallback that
     * published sanitized text somewhere nobody reads. */
    const outputInRealm = vm.runInContext(
        "typeof output === 'undefined' ? null : String(output)", context);
    const globalPropInRealm = vm.runInContext(
        "(typeof globalThis === 'undefined' || globalThis.output === undefined) " +
        "? null : String(globalThis.output)", context);

    return { context, raised, seen, outputInRealm, globalPropInRealm };
}

/* ---- N-1: the allowed path must not abort ------------------------------- */

test('N-1: a covered run assigns the sanitized text — with NO pre-declared output binding', () => {
    // This is the case the old code got wrong. Strict mode + an unresolvable
    // `output` is a ReferenceError, so every protected run aborted, and an
    // aborted run is indistinguishable from a successful block in Leg 6.
    const { context, raised, seen } = runHook({ protectResult: COVERED });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(context.output, SANITIZED);
    assert.ok(!String(context.output).includes('Brannagh'));
    assert.deepStrictEqual(seen.length, 1);
    assert.strictEqual(seen[0].skill, 'Incident summarization');
    assert.strictEqual(seen[0].text, RAW);
});

test('N-1: a covered run assigns the sanitized text — WITH a pre-declared output binding', () => {
    const { context, raised } = runHook({ protectResult: COVERED, declareOutput: true });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(context.output, SANITIZED);
});

test('N-1: an uncovered (fail-open) run assigns the annotated text, and does not abort', () => {
    const { context, raised } = runHook({ protectResult: UNCOVERED });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.ok(String(context.output).indexOf(LucairnSkillGuard.UNCOVERED_ANNOTATION) === 0,
        String(context.output));
    assert.ok(String(context.output).includes('No certificate exists'));
    // The override means the raw text proceeds — labelled, but raw.
    assert.ok(String(context.output).includes('Brannagh'));
});

/* ---- P1: a REJECTED assignment is not a missing binding ----------------- */

test('P1: a REJECTED assignment propagates — and nothing is published behind its back', () => {
    // Round-3 gate finding, in astra's repro shape. A lexical `const output`
    // resolves, so this is not the "no such binding" case, and assigning to it
    // is a TypeError. Under the round-2 catch-all that TypeError was recovered
    // as if the binding were missing: sanitized text was written to
    // globalThis.output — a DIFFERENT slot — the hook returned normally, and
    // the binding the platform actually reads back still held the ORIGINAL
    // text. A covered verdict over raw content, with no error and no
    // annotation. That is the fail-open this test exists to keep dead.
    const { raised, outputInRealm, globalPropInRealm } = runHook({
        protectResult: COVERED, constOutputBinding: true
    });

    assert.ok(raised, 'a rejected assignment must not be swallowed');
    // The wording is the engine's ("Assignment to constant variable" on V8), so
    // match loosely — what matters is that the rejection reached the caller.
    assert.match(String(raised.message), /constant|assignment/i, raised.message);

    // The consumed binding is untouched — no silent raw continuation...
    assert.strictEqual(outputInRealm, '__untouched__');
    // ...and the fallback did NOT fire behind its back.
    assert.strictEqual(globalPropInRealm, null,
        'nothing may be published to the global scope when a real binding rejected the write');
});

test('P1: the same holds for a global binding whose setter throws', () => {
    // The other shape of the class: `output` is a global accessor that refuses
    // the write. Here the fallback would hit the same slot and re-throw anyway,
    // so this shape alone cannot falsify the catch-all — it is here because the
    // fix must cover the class, not just the repro.
    const { raised, outputInRealm } = runHook({
        protectResult: COVERED, rejectOutputAssignment: true
    });

    assert.ok(raised, 'a rejected assignment must not be swallowed');
    assert.match(String(raised.message), /rejects assignment/);
    assert.strictEqual(outputInRealm, '__untouched__');
});

test('P1: the propagated error is not the block error — Leg 6 must not score it as (a)', () => {
    const { raised } = runHook({ protectResult: COVERED, constOutputBinding: true });

    assert.ok(raised);
    assert.ok(!String(raised.message).includes(LucairnSkillGuard.ERROR_PREFIX),
        'a wiring failure must not present as "skill run blocked": ' + raised.message);
    assert.ok(!String(raised.message).includes('Brannagh'), raised.message);
});

test('P1: a plain declared binding is still assigned — the fix did not break the normal path', () => {
    // The mirror of the const test: same lexical-declaration machinery, but a
    // WRITABLE binding. It must be assigned directly, and the global-scope
    // fallback must stay out of it.
    const { raised, outputInRealm, globalPropInRealm } = runHook({
        protectResult: COVERED, letOutputBinding: true
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(outputInRealm, SANITIZED);
    assert.strictEqual(globalPropInRealm, null, 'the fallback must not have fired');
});

/* ---- the strict ES5 wrapper with no globalThis (round-3 advisory) -------- */

test('advisory: strict ES5 wrapper, no globalThis — the global fallback still reaches the realm', () => {
    // `(function(){return this;}())` is undefined under a strict wrapper. The
    // Function constructor builds a non-strict function whatever the caller's
    // strictness, so its `this` is still the global object.
    const { raised, outputInRealm } = runHook({
        protectResult: COVERED, strictEs5Wrapper: true
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(outputInRealm, SANITIZED);
});

test('advisory: strict ES5 wrapper AND no Function — the hook raises rather than continuing', () => {
    // Nowhere to publish to. The documented behaviour is to RAISE, content-free
    // and under its own prefix: a run that silently continues on whatever the
    // extension point already held would be running on the ORIGINAL text under
    // a covered verdict. Fail closed, and say which failure it is.
    const { raised, outputInRealm } = runHook({
        protectResult: COVERED, strictEs5Wrapper: true, withholdFunctionConstructor: true
    });

    assert.ok(raised, 'an unreachable global scope must not be a silent success');
    assert.match(String(raised.message), /could not publish its output/);
    assert.ok(!String(raised.message).includes(LucairnSkillGuard.ERROR_PREFIX),
        'a wiring failure must not present as "skill run blocked": ' + raised.message);
    assert.ok(!String(raised.message).includes('Brannagh'), raised.message);
    assert.strictEqual(outputInRealm, null, 'nothing may have been published');
});

test('advisory: strict ES5 wrapper with a pre-declared binding is unaffected', () => {
    // The global-scope question never arises when the binding exists.
    const { raised, outputInRealm } = runHook({
        protectResult: COVERED, strictEs5Wrapper: true,
        withholdFunctionConstructor: true, declareOutput: true
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(outputInRealm, SANITIZED);
});

/* ---- the blocking path -------------------------------------------------- */

test('a blocked decision raises out of the hook and assigns nothing', () => {
    const { context, raised } = runHook({ protectResult: BLOCKED });

    // `instanceof Error` is deliberately NOT the assertion: the throw happens
    // inside the vm realm, so its Error has a different prototype chain.
    assert.ok(raised, 'the hook must raise on a blocked decision');
    assert.match(String(raised.message), /skill run blocked/);
    assert.match(String(raised.message), /correlation corr_1/);
    // Nothing was handed onward: not the raw text, not an empty-but-assigned
    // value that a later step could mistake for a sanitized one.
    assert.strictEqual(Object.prototype.hasOwnProperty.call(context, 'output'), false);
});

test('a blocked decision does not leak the submitted text into the raised error', () => {
    const { raised } = runHook({ protectResult: BLOCKED });

    assert.ok(raised);
    assert.ok(!raised.message.includes('Brannagh'), raised.message);
    assert.ok(!raised.message.includes('northmarrow-example.test'), raised.message);
});

test('a blocked decision leaves a pre-declared output binding untouched', () => {
    // The raise exits before the assignment, so whatever the extension point
    // already held is what it still holds. On outcome (b) — a swallowed raise —
    // that is the ORIGINAL text, with no annotation. README Leg 6 says so.
    const { context, raised } = runHook({ protectResult: BLOCKED, declareOutput: true });

    assert.ok(raised);
    assert.strictEqual(context.output, '__untouched__');
});

/* ---- input handling ----------------------------------------------------- */

test('a platform that exposes no input at all is handled as an empty submission', () => {
    const { raised, seen, context } = runHook({ protectResult: COVERED, omitInput: true });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(seen[0].text, '');
    assert.strictEqual(context.output, SANITIZED);
});

test('a non-string input is coerced before it reaches the guard', () => {
    const { raised, seen } = runHook({ protectResult: COVERED, input: 12345 });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(seen[0].text, '12345');
});

/* ---- the labels the hook must keep -------------------------------------- */

test('the hook stays labelled as the hypothesis it is', () => {
    // Execution proves what the code does. These assertions guard what the file
    // CLAIMS — that the platform bindings are still marked unproven and still
    // point at the leg that falsifies them.
    assert.ok(/HYPOTHESIS/.test(HOOK_SOURCE), 'the hook must carry its hypothesis label');
    assert.ok(/ADJUST-ON-PDI/.test(HOOK_SOURCE), 'the unproven bindings must stay marked');
    assert.ok(/Leg 6/.test(HOOK_SOURCE), 'the hook must point at its falsifier');
});
