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
 * @param {string} [opts.withScope] run the hook inside `with (scope) { … }`,
 *   the shape a Rhino extension point can genuinely have. The value names the
 *   scope object's `output` accessor:
 *     'reference-error-then-raw' — round-4 gate finding, astra's reproducer
 *        VERBATIM: the getter throws a same-realm ReferenceError on its FIRST
 *        read and returns the raw text afterwards; the setter rejects. Round
 *        4 classified that first ReferenceError as "no such binding" and fell
 *        through to the global scope, returning normally while the binding the
 *        platform consumes still held RAW.
 *     'raw-with-throwing-setter' — reads fine, refuses writes, and the global
 *        fallback lands in a DIFFERENT slot.
 *     'always-throwing-getter' — never readable, setter accepts. The write may
 *        well have landed; it cannot be verified, so it does not count.
 * @param {string} [opts.container] provide an explicit output destination:
 *     'outputs'        — an `outputs` object with a writable `text` field.
 *     'api'            — an `api` object with setOutput/getOutput.
 *     'api-write-only' — an `api` object with setOutput and NO reader.
 *     'lying-outputs'  — an `outputs` object that accepts writes to `text` and
 *                        reads back the old value regardless.
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
    if (opts.container === 'outputs') {
        context.outputs = { text: '__untouched__' };
    }
    if (opts.container === 'lying-outputs') {
        /* Accepts the write, reads back the old value. The read-back
         * comparison is the ONLY thing that can catch this. */
        const held = { text: '__untouched__' };
        context.outputs = Object.defineProperty({}, 'text', {
            configurable: true, enumerable: true,
            get: function () { return '__untouched__'; },
            set: function (v) { held.text = v; }
        });
        context.outputsHeld = held;
    }
    if (opts.container === 'api' || opts.container === 'api-write-only') {
        const slot = { value: '__untouched__' };
        context.apiSlot = slot;
        context.api = { setOutput: function (v) { slot.value = v; } };
        if (opts.container === 'api') {
            context.api.getOutput = function () { return slot.value; };
        }
    }

    vm.createContext(context);

    if (opts.withScope) {
        /* The scope object is built INSIDE the realm so that the accessors and
         * their counters are realm-native, exactly as in the gate reproducer. */
        const accessors = {
            'reference-error-then-raw':
                'get output(){ if (++reads === 1) { throw new ReferenceError("getter dependency unavailable"); } return "RAW"; },\n' +
                'set output(v){ writes++; throw new TypeError("setter rejected"); }',
            'raw-with-throwing-setter':
                'get output(){ reads++; return "RAW"; },\n' +
                'set output(v){ writes++; throw new TypeError("setter rejected"); }',
            'always-throwing-getter':
                'get output(){ reads++; throw new Error("read failed"); },\n' +
                'set output(v){ writes++; }'
        };
        const accessor = accessors[opts.withScope];
        if (!accessor) { throw new Error('unknown withScope shape: ' + opts.withScope); }
        vm.runInContext(
            'var writes = 0, reads = 0; var scope = {\n' + accessor + '\n};', context);
    }

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
    let source = prologue + HOOK_SOURCE;
    if (opts.withScope) {
        /* `with` is a SyntaxError under a strict wrapper, so this shape and
         * `strictEs5Wrapper` are mutually exclusive by construction. The hook's
         * own body is strict regardless — its 'use strict' is inside the IIFE. */
        source = prologue + 'with (scope) {\n' + HOOK_SOURCE + '\n}';
    }

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

    /* What a `with`-scoped extension point would consume, plus how often the
     * accessors were touched — the gate reproducer's own observables. */
    let scopeConsumed = null;
    let scopeWrites = null;
    let scopeReads = null;
    if (opts.withScope) {
        const probe = vm.runInContext(
            '({ consumed: (function () { try { return String(scope.output); } ' +
            'catch (e) { return "<unreadable>"; } }()), writes: writes, reads: reads })',
            context);
        scopeConsumed = probe.consumed;
        scopeWrites = probe.writes;
        scopeReads = probe.reads;
    }

    let containerHolds = null;
    if (opts.container === 'outputs') { containerHolds = context.outputs.text; }
    if (opts.container === 'lying-outputs') { containerHolds = context.outputsHeld.text; }
    if (opts.container === 'api' || opts.container === 'api-write-only') {
        containerHolds = context.apiSlot.value;
    }

    return {
        context, raised, seen, outputInRealm, globalPropInRealm,
        scopeConsumed, scopeWrites, scopeReads, containerHolds
    };
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

/* ---- P1: only a READ-BACK counts as published --------------------------- */

/**
 * Every unverifiable-destination test asserts the same four things, because
 * "the hook raised" on its own is not the property under test — a hook that
 * raises AFTER littering the global scope with a value nobody reads, or one
 * that raises with the BLOCK message, would pass a bare `assert.ok(raised)`
 * and still be wrong in Leg 6.
 */
function assertPublishFailure(result, expectedConsumed) {
    const { raised, outputInRealm, globalPropInRealm } = result;

    assert.ok(raised, 'an unverifiable destination must not be a silent success');
    assert.match(String(raised.message), /could not publish its output/, raised.message);
    // Not the block error: Leg 6 must not score a wiring failure as outcome (a).
    assert.ok(!String(raised.message).includes(LucairnSkillGuard.ERROR_PREFIX),
        'a wiring failure must not present as "skill run blocked": ' + raised.message);
    // Content-free, and no engine text a hostile destination could have authored.
    assert.ok(!String(raised.message).includes('Brannagh'), raised.message);

    if (expectedConsumed !== undefined) {
        assert.strictEqual(outputInRealm, expectedConsumed,
            'the consumed binding must be exactly what it was before the hook ran');
    }
    // The global fallback must never be LEFT holding a value that reads as a
    // successful publish when the hook in fact failed to publish.
    assert.notStrictEqual(globalPropInRealm, SANITIZED,
        'a failed publish may not leave sanitized text in the global slot');
}

test('P1: a REJECTED assignment raises — and nothing is published behind its back', () => {
    // Round-3 gate finding, in astra's repro shape. A lexical `const output`
    // resolves, so this is not the "no such binding" case, and assigning to it
    // is a TypeError. Under the round-2 catch-all that TypeError was recovered
    // as if the binding were missing: sanitized text was written to
    // globalThis.output — a DIFFERENT slot — the hook returned normally, and
    // the binding the platform actually reads back still held the ORIGINAL
    // text. A covered verdict over raw content, with no error and no
    // annotation. That is the fail-open this test exists to keep dead.
    const result = runHook({ protectResult: COVERED, constOutputBinding: true });

    assertPublishFailure(result, '__untouched__');
    // The global slot is not merely "not sanitized" here — the speculative
    // tier-4 write was UNDONE, so the realm is exactly as it was.
    assert.strictEqual(result.globalPropInRealm, null,
        'a fallback write that did not reach the consumed binding must be undone');
});

test('P1: the same holds for a global binding whose setter throws', () => {
    // The other shape of the class: `output` is a global accessor that refuses
    // the write. Here the fallback hits the SAME slot, so the read-back — not
    // the exception — is what shows the write never took.
    const result = runHook({ protectResult: COVERED, rejectOutputAssignment: true });

    assertPublishFailure(result, '__untouched__');
});

/* ---- the round-4 blocker: exception type cannot establish absence -------- */

test('P1 (round 4): a with-scoped getter that throws ReferenceError does NOT read as an absent binding', () => {
    // THE REPRODUCER, verbatim from the round-4 gate finding. A Rhino extension
    // point can genuinely be `with`-scoped. The scope object's `output` getter
    // throws a same-realm ReferenceError on its FIRST read and returns the raw
    // text on every read after; its setter rejects.
    //
    // Round 4 answered "does the binding exist?" with a READ PROBE and
    // classified by exception type: ReferenceError meant absent. So it took
    // that first throw as absence, wrote SANITIZED to globalThis.output — a
    // slot the `with` scope shadows — and RETURNED NORMALLY. The model then ran
    // on the scope binding, which still held RAW, under a covered verdict.
    //
    // No exception type can establish where a value ended up; only reading the
    // destination back can. This test is the one that says so.
    const result = runHook({
        protectResult: COVERED, withScope: 'reference-error-then-raw'
    });

    assertPublishFailure(result);

    // The binding the platform consumes was never changed, and — the part that
    // makes this a fail-OPEN rather than a mere failure — the hook did not
    // return as though it had succeeded.
    assert.strictEqual(result.scopeConsumed, 'RAW');
    assert.strictEqual(result.globalPropInRealm, null,
        'globalThis.output must not be left holding a "success" the scope shadows');

    // The shape really was exercised: the setter was called and refused, and
    // the getter was read back after the write rather than probed before it.
    assert.strictEqual(result.scopeWrites, 1, 'the write must have been attempted');
    assert.ok(result.scopeReads >= 2,
        'the destination must be read back after each write attempt, not probed once');
});

test('P1 (round 4): a with-scoped binding that reads fine and refuses writes raises too', () => {
    const result = runHook({
        protectResult: COVERED, withScope: 'raw-with-throwing-setter'
    });

    assertPublishFailure(result);
    assert.strictEqual(result.scopeConsumed, 'RAW');
    assert.strictEqual(result.globalPropInRealm, null);
    assert.strictEqual(result.scopeWrites, 1);
});

test('P1 (round 4): a destination that cannot be READ BACK is not a destination', () => {
    // The setter here ACCEPTS the write — the sanitized text may well have
    // landed. It cannot be verified, so it does not count. Fail closed: an
    // unverifiable publish and a failed one are the same answer, which is the
    // whole point of not branching on exception types.
    const result = runHook({
        protectResult: COVERED, withScope: 'always-throwing-getter'
    });

    assertPublishFailure(result);
    assert.strictEqual(result.scopeConsumed, '<unreadable>');
    assert.strictEqual(result.globalPropInRealm, null);
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

/* ---- explicitly provided destinations (hypothesis tiers 1 and 2) --------- */

test('an `outputs` container is preferred over the bare identifier — and verified', () => {
    const { raised, containerHolds, outputInRealm, globalPropInRealm } = runHook({
        protectResult: COVERED, container: 'outputs'
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(containerHolds, SANITIZED);
    // An explicitly provided destination ends the search: no bare identifier is
    // written, so nothing is published to a slot the platform may not read.
    assert.strictEqual(outputInRealm, null);
    assert.strictEqual(globalPropInRealm, null);
});

test('an `api.setOutput` / `api.getOutput` pair is used and verified', () => {
    const { raised, containerHolds, globalPropInRealm } = runHook({
        protectResult: COVERED, container: 'api'
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(containerHolds, SANITIZED);
    assert.strictEqual(globalPropInRealm, null);
});

test('an `api` with a setter but NO reader is SKIPPED, not believed', () => {
    // Being handed a destination earns no trust: a tier that cannot be read
    // back cannot be verified, so the search continues past it. Here it lands
    // on the global scope, which CAN be verified.
    const { raised, globalPropInRealm } = runHook({
        protectResult: COVERED, container: 'api-write-only'
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(globalPropInRealm, SANITIZED,
        'the unverifiable tier must be passed over, not treated as published');
});

test('a container that LIES on read-back is not accepted as published', () => {
    // It takes the write and reads back the old value. With no other reachable
    // destination — a strict ES5 wrapper on a runtime without `Function` — the
    // hook has nowhere it can verify, so it raises rather than returning over a
    // destination it only HOPES it wrote.
    const result = runHook({
        protectResult: COVERED, container: 'lying-outputs',
        strictEs5Wrapper: true, withholdFunctionConstructor: true
    });

    assertPublishFailure(result);
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
