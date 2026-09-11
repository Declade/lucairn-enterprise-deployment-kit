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
 * context that supplies exactly what the extension point supplies — an `input`,
 * a `LucairnSkillGuard` and the platform's `gs` — and the assertions are about
 * what the context holds afterwards, which is what the platform would hand the
 * model.
 *
 * The guard in the context is the REAL Script Include over a stubbed adapter,
 * so the covered / uncovered / blocked branches are the real ones. What is
 * faked is only the Lucairn round trip.
 *
 * ROUND 5 — WHAT THESE TESTS ARE NOW ABOUT
 * ----------------------------------------
 * Rounds 2-4 fixed how the hook WRITES. Round 5 deleted the multi-destination
 * ladder, because verifying a write answers "did my write land here", never "is
 * here what the platform reads". A ladder can therefore verify one destination
 * while the platform consumes a different one that still holds RAW.
 *
 * The two countermodels that proved it — one in each direction — are the
 * centrepiece of this file (§ competing destinations). Every other test either
 * pins one declared destination's write-read-compare behaviour, or pins the
 * configuration handling that chooses it.
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

require('./mocks/servicenow');
const LucairnSkillGuard = require('../src/script_includes/LucairnSkillGuard');
const LucairnConfig = require('../src/script_includes/LucairnConfig');

const HOOK_PATH = path.join(__dirname, '..', 'src', 'hooks', 'genai-preprocessor.js');
const HOOK_SOURCE = fs.readFileSync(HOOK_PATH, 'utf8');

const DESTINATION_PROPERTY = 'lucairn.now_assist.output_destination';

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
 * @param {boolean} [opts.omitInput]    the platform exposes no `input` at all
 *
 * CONFIGURATION — which destination the hook is told to publish to.
 * @param {string} [opts.destination]   the value `gs.getProperty` returns for
 *   `lucairn.now_assist.output_destination`. Absent means the property is UNSET
 *   (empty string), which must resolve to the documented default.
 * @param {boolean} [opts.omitGs]       no `gs` at all — the property service is
 *   unreachable, so the declared destination is unknowable.
 * @param {boolean} [opts.gsThrows]     `gs.getProperty` raises.
 *
 * THE DESTINATION SHAPES the extension point might expose.
 * @param {boolean} [opts.declareOutput] the extension point pre-declares
 *   `output` as an ordinary writable global property.
 * @param {boolean} [opts.constOutputBinding] the extension point declares
 *   `output` as a LEXICAL constant. This is the round-3 P1 repro and the
 *   sharpest shape of it: the binding resolves, assignment to it is a
 *   TypeError, and — the part that made the old catch-all fail OPEN rather
 *   than merely fail — the global-scope slot is a DIFFERENT one, so writing
 *   there succeeded silently while `output` still read the original value.
 * @param {boolean} [opts.letOutputBinding] the same lexical shape, WRITABLE —
 *   the control that shows the fix did not break the normal path, and the
 *   "untouched" witness in the competing-destination countermodels.
 * @param {boolean} [opts.rejectOutputAssignment] `output` is a global accessor
 *   that READS fine and REJECTS assignment (a read-only accessor, a frozen
 *   property, a throwing setter).
 * @param {boolean} [opts.globalOutputRestoreFails] `output` is a global
 *   accessor that accepts the FIRST write and throws on every one after it —
 *   so the `global_output` undo cannot put the prior value back. Pair it with
 *   `constOutputBinding` to shadow the global, which is what makes the publish
 *   fail in the first place. Round-5 advisory 1.
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
 *     'raw-with-throwing-setter' — reads fine, refuses writes.
 *     'always-throwing-getter' — never readable, setter accepts. The write may
 *        well have landed; it cannot be verified, so it does not count.
 *     'raw-records-order' — reads fine, refuses writes, and RECORDS how many
 *        writes had happened at read time. The ordering witness: a read-back
 *        must happen after the write, never as a probe before it.
 * @param {string} [opts.container] provide an output container / host API:
 *     'outputs'        — an `outputs` object with a writable `text` field.
 *     'frozen-outputs' — an `outputs` object FROZEN on the raw submission: it
 *                        refuses the write and reads back RAW.
 *     'lying-outputs'  — an `outputs` object that accepts writes to `text` and
 *                        reads back the old value regardless.
 *     'api'            — an `api` object with setOutput/getOutput.
 *     'api-write-only' — an `api` object with setOutput and NO reader.
 */
function runHook(opts) {
    const seen = [];
    const propertiesRead = [];

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

    /* The platform's property service. Present unless a test removes it: on an
     * instance `gs` always exists, and "there is no gs" is its own failure
     * case rather than the ambient condition of every other test. */
    if (!opts.omitGs) {
        context.gs = {
            getProperty: function (name, fallback) {
                propertiesRead.push(name);
                if (opts.gsThrows) {
                    throw new Error('property service unavailable');
                }
                if (name === DESTINATION_PROPERTY) {
                    return opts.destination === undefined ? '' : opts.destination;
                }
                return fallback;
            }
        };
    }

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
    if (opts.globalOutputRestoreFails) {
        /* Takes the first write, refuses every one after it — so the undo that
         * follows a failed `global_output` publish cannot put the prior value
         * back. The residual is real and the test says so out loud. */
        const held = { value: '__untouched__' };
        let globalWrites = 0;
        Object.defineProperty(context, 'output', {
            configurable: true,
            enumerable: true,
            get: function () { return held.value; },
            set: function (v) {
                globalWrites += 1;
                if (globalWrites > 1) {
                    throw new TypeError('this slot refuses to be restored');
                }
                held.value = v;
            }
        });
        context.globalOutputHeld = held;
    }
    if (opts.container === 'outputs') {
        context.outputs = { text: '__untouched__' };
    }
    if (opts.container === 'frozen-outputs') {
        /* The destination the platform CONSUMES, holding the raw submission and
         * refusing to be changed. Under a ladder this was the rung that failed
         * so that a writable one could "succeed". */
        context.outputs = Object.freeze({ text: RAW });
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
                'set output(v){ writes++; }',
            'raw-records-order':
                'get output(){ reads++; if (readAfterWrites === -1) { readAfterWrites = writes; } return "RAW"; },\n' +
                'set output(v){ writes++; throw new TypeError("setter rejected"); }'
        };
        const accessor = accessors[opts.withScope];
        if (!accessor) { throw new Error('unknown withScope shape: ' + opts.withScope); }
        vm.runInContext(
            'var writes = 0, reads = 0, readAfterWrites = -1; var scope = {\n' +
            accessor + '\n};', context);
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
     * global property otherwise. `globalPropInRealm` is the `global_output`
     * destination's slot. When they differ, a publish that reached the global
     * slot alone reached somewhere nobody reads. */
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
    let scopeReadAfterWrites = null;
    if (opts.withScope) {
        /* Snapshot the counters BEFORE reading the scope, because reading it is
         * itself an accessor call — an observation that changes what it
         * observes. `scopeReads` must count the HOOK's reads and nothing else. */
        const counters = vm.runInContext(
            '({ writes: writes, reads: reads, readAfterWrites: readAfterWrites })', context);
        scopeWrites = counters.writes;
        scopeReads = counters.reads;
        scopeReadAfterWrites = counters.readAfterWrites;
        scopeConsumed = vm.runInContext(
            '(function () { try { return String(scope.output); } ' +
            'catch (e) { return "<unreadable>"; } }())', context);
    }

    let containerHolds = null;
    if (opts.container === 'outputs' || opts.container === 'frozen-outputs') {
        containerHolds = context.outputs.text;
    }
    if (opts.container === 'lying-outputs') { containerHolds = context.outputsHeld.text; }
    if (opts.container === 'api' || opts.container === 'api-write-only') {
        containerHolds = context.apiSlot.value;
    }

    return {
        context, raised, seen, propertiesRead, outputInRealm, globalPropInRealm,
        scopeConsumed, scopeWrites, scopeReads, scopeReadAfterWrites, containerHolds
    };
}

/**
 * Every wiring-failure test asserts the same things, because "the hook raised"
 * on its own is not the property under test — a hook that raises AFTER
 * littering the global scope with a value nobody reads, or one that raises with
 * the BLOCK message, would pass a bare `assert.ok(raised)` and still be wrong in
 * Leg 6.
 */
function assertPublishFailure(result, expectedConsumed) {
    const { raised, outputInRealm, globalPropInRealm } = result;

    assert.ok(raised, 'an unverifiable destination must not be a silent success');
    // ONE discriminator for Leg 6: every wiring failure says this, and only
    // wiring failures say it.
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
    // The global slot must never be LEFT holding a value that reads as a
    // successful publish when the hook in fact failed to publish.
    assert.notStrictEqual(globalPropInRealm, SANITIZED,
        'a failed publish may not leave sanitized text in the global slot');
}

/* ======================================================================== */
/* ROUND 5 — COMPETING DESTINATIONS. The reason the ladder is gone.         */
/* ======================================================================== */

test('R5 countermodel A: a REFUSING consumed container is never traded for a writable bare output', () => {
    // astra's round-5 countermodel, direction one, verbatim in shape.
    //
    // `outputs.text` is the destination the platform consumes and it is FROZEN
    // on the raw submission — it refuses the write and reads back RAW. A bare
    // `output` binding is sitting right there, perfectly writable.
    //
    // Under the ladder: tier 1 fails, tier 3 succeeds and verifies, the hook
    // returns normally — and the model runs on `outputs.text`, which is RAW.
    // Neither destination lied; the FALLTHROUGH was the defect.
    //
    // With one declared destination there is nowhere to fall to.
    const result = runHook({
        protectResult: COVERED,
        destination: 'outputs_text',
        container: 'frozen-outputs',
        letOutputBinding: true
    });

    assertPublishFailure(result, '__untouched__');
    assert.match(String(result.raised.message), /outputs_text/, result.raised.message);
    // The consumed destination still holds what it held — and, critically, the
    // hook did not report success over it.
    assert.strictEqual(result.containerHolds, RAW);
    // The competing destination was never written to. Not "written and undone":
    // never touched, which is why no undo path exists for it.
    assert.strictEqual(result.outputInRealm, '__untouched__',
        'a destination that was not declared must not be written at all');
    assert.strictEqual(result.globalPropInRealm, null);
});

test('R5 countermodel B: a SUCCEEDING host api never substitutes for a rejecting declared output', () => {
    // Direction two. `api` accepts the write and reads it straight back — a
    // textbook verifiable destination. The declared one, the bare `output`
    // binding, rejects assignment and keeps its original value.
    //
    // Under the ladder the api was tried FIRST, verified, and the declared
    // destination was never even written: a covered verdict over a binding that
    // still held the raw submission.
    const result = runHook({
        protectResult: COVERED,
        destination: 'bare_output',
        container: 'api',
        rejectOutputAssignment: true
    });

    assertPublishFailure(result, '__untouched__');
    assert.match(String(result.raised.message), /bare_output/, result.raised.message);
    // The api was never consulted: no setOutput call, no speculative write.
    assert.strictEqual(result.containerHolds, '__untouched__',
        'a destination that was not declared must not be written at all');
});

test('R5: the declared destination is read back AFTER the write, never probed before it', () => {
    // The ordering discipline rounds 2-4 kept losing. The scope records how many
    // writes had happened at read time: 1, so the read is a read-BACK. A
    // probe-then-write implementation reads at 0 and this goes red.
    const result = runHook({
        protectResult: COVERED, withScope: 'raw-records-order'
    });

    assertPublishFailure(result);
    assert.strictEqual(result.scopeWrites, 1, 'exactly one write, to the declared destination');
    assert.strictEqual(result.scopeReads, 1, 'exactly one read, and it is the read-back');
    assert.strictEqual(result.scopeReadAfterWrites, 1,
        'the read must follow the write — a probe-first implementation reads at 0');
    assert.strictEqual(result.scopeConsumed, 'RAW');
});

/* ======================================================================== */
/* The destination configuration itself                                     */
/* ======================================================================== */

test('the hook reads its destination from the documented property, and LucairnConfig agrees', () => {
    // The property name is duplicated between the pasted hook and
    // LucairnConfig.PROP because the hook cannot require a Script Include. This
    // is the test that keeps the duplication from drifting apart.
    assert.strictEqual(LucairnConfig.PROP.OUTPUT_DESTINATION, DESTINATION_PROPERTY);
    assert.ok(HOOK_SOURCE.includes("'" + DESTINATION_PROPERTY + "'"),
        'the hook must name the documented destination property');

    const { propertiesRead } = runHook({ protectResult: COVERED, declareOutput: true });
    assert.ok(propertiesRead.includes(DESTINATION_PROPERTY),
        'the hook must actually read the property: ' + propertiesRead.join(', '));
});

test('an UNSET destination property means the documented default, bare_output', () => {
    // The default is a hypothesis about which hypothesis is likeliest, and the
    // header says so. What matters here is that it is a real, verified publish
    // to ONE destination — not a search.
    const { raised, outputInRealm, globalPropInRealm, containerHolds } = runHook({
        protectResult: COVERED, declareOutput: true, container: 'outputs'
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(outputInRealm, SANITIZED);
    assert.strictEqual(globalPropInRealm, SANITIZED,
        'a declared global `output` IS the bare identifier here');
    // An `outputs` container is present and was NOT written: it was not declared.
    assert.strictEqual(containerHolds, '__untouched__');
});

test('an UNRECOGNISED destination value raises — it does not quietly fall back to the default', () => {
    // The tempting bug: "unknown value, so use the default". That publishes
    // somewhere the operator did not choose, which is the class this round
    // deleted. A typo must be visible, and fail-closed.
    const result = runHook({
        protectResult: COVERED, destination: 'bare-output', declareOutput: true
    });

    assertPublishFailure(result, '__untouched__');
    assert.match(String(result.raised.message), /is not one of/, result.raised.message);
    assert.match(String(result.raised.message), /bare-output/, result.raised.message);
});

test('a destination value is trimmed and case-folded before it is matched', () => {
    const { raised, outputInRealm } = runHook({
        protectResult: COVERED, destination: '  BARE_OUTPUT  ', declareOutput: true
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(outputInRealm, SANITIZED);
});

test('an UNREADABLE destination property raises rather than guessing', () => {
    // `gs.getProperty` throws. The declared destination is unknowable, and
    // publishing to the default anyway would be the round-5 defect in another
    // costume: verifying a slot the operator did not choose.
    const result = runHook({
        protectResult: COVERED, gsThrows: true, declareOutput: true
    });

    assertPublishFailure(result, '__untouched__');
    assert.match(String(result.raised.message), /could not be read/, result.raised.message);
});

test('no property service at all raises for the same reason', () => {
    const result = runHook({
        protectResult: COVERED, omitGs: true, declareOutput: true
    });

    assertPublishFailure(result, '__untouched__');
    assert.match(String(result.raised.message), /could not be read/, result.raised.message);
});

test('a BLOCKED run raises the block error even when the destination is misconfigured', () => {
    // Order matters for Leg 6: a blocked run must present as a block, not as a
    // wiring failure, or outcome (a) becomes unreadable.
    const { raised } = runHook({ protectResult: BLOCKED, destination: 'nonsense' });

    assert.ok(raised);
    assert.match(String(raised.message), /skill run blocked/);
    assert.ok(!String(raised.message).includes('could not publish its output'), raised.message);
});

/* ======================================================================== */
/* Each declared destination, on its own                                    */
/* ======================================================================== */

test('destination bare_output: a covered run publishes to the declared binding', () => {
    const { context, raised, seen } = runHook({
        protectResult: COVERED, destination: 'bare_output', declareOutput: true
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(context.output, SANITIZED);
    assert.ok(!String(context.output).includes('Brannagh'));
    assert.deepStrictEqual(seen.length, 1);
    assert.strictEqual(seen[0].skill, 'Incident summarization');
    assert.strictEqual(seen[0].text, RAW);
});

test('destination bare_output: a plain LEXICAL binding is assigned, and nothing else is', () => {
    const { raised, outputInRealm, globalPropInRealm } = runHook({
        protectResult: COVERED, destination: 'bare_output', letOutputBinding: true
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(outputInRealm, SANITIZED);
    assert.strictEqual(globalPropInRealm, null,
        'the global slot is a different destination and must stay untouched');
});

test('destination bare_output: NO declared binding raises — that case is a CONFIGURATION answer', () => {
    // Round-2 finding N-1's shape, resolved the honest way. Strict mode plus an
    // unresolvable `output` means the write throws and the read-back throws, so
    // the declared destination cannot be verified and the hook raises with a
    // WIRING message. The old code silently invented a global here; the fix for
    // an instance that really works that way is `destination = global_output`,
    // recorded at Leg 6 step 7 — not a fallback in code.
    const result = runHook({ protectResult: COVERED, destination: 'bare_output' });

    assertPublishFailure(result, null);
    assert.strictEqual(result.globalPropInRealm, null,
        'no global may be invented on the way out');
});

test('destination outputs_text: the container is written and verified', () => {
    const { raised, containerHolds, outputInRealm, globalPropInRealm } = runHook({
        protectResult: COVERED, destination: 'outputs_text', container: 'outputs'
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(containerHolds, SANITIZED);
    assert.strictEqual(outputInRealm, null);
    assert.strictEqual(globalPropInRealm, null);
});

test('destination outputs_text: an ABSENT container raises', () => {
    const result = runHook({ protectResult: COVERED, destination: 'outputs_text' });

    assertPublishFailure(result, null);
    assert.match(String(result.raised.message), /outputs_text/, result.raised.message);
});

test('destination outputs_text: a container that LIES on read-back is not accepted', () => {
    // It takes the write and reads back the old value. The read-back comparison
    // is the only thing that can catch it, and there is nowhere to fall through
    // to — so it raises.
    const result = runHook({
        protectResult: COVERED, destination: 'outputs_text', container: 'lying-outputs'
    });

    assertPublishFailure(result, null);
});

test('destination api_set_output: the pair is used and verified', () => {
    const { raised, containerHolds, globalPropInRealm } = runHook({
        protectResult: COVERED, destination: 'api_set_output', container: 'api'
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(containerHolds, SANITIZED);
    assert.strictEqual(globalPropInRealm, null);
});

test('destination api_set_output: a setter with NO reader raises — it is not believed', () => {
    // Being handed a destination earns no trust. Under the ladder this "skipped"
    // to the next rung; there is no next rung, and there must not be: the write
    // may well have landed, but an unverifiable publish and a failed one are the
    // same answer.
    const result = runHook({
        protectResult: COVERED, destination: 'api_set_output', container: 'api-write-only'
    });

    assertPublishFailure(result, null);
    assert.strictEqual(result.globalPropInRealm, null,
        'the unverifiable destination must not be papered over by another one');
});

test('destination global_output: publishes when `output` was genuinely undeclared', () => {
    const { raised, outputInRealm } = runHook({
        protectResult: COVERED, destination: 'global_output'
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(outputInRealm, SANITIZED);
});

test('destination global_output: a SHADOWING lexical binding makes it fail, and the write is undone', () => {
    // The round-4 insight, kept: verification re-reads the BARE identifier, not
    // the global property we just wrote. A lexical `const output` shadows the
    // global, so the identifier still reads `__untouched__`, the publish fails,
    // and the speculative global write is rolled back.
    const result = runHook({
        protectResult: COVERED, destination: 'global_output', constOutputBinding: true
    });

    assertPublishFailure(result, '__untouched__');
    assert.strictEqual(result.globalPropInRealm, null,
        'a global write that did not reach the consumed binding must be undone');
});

test('destination global_output: a failed RESTORATION does not mask the publish error', () => {
    // Round-5 advisory 1. The global slot accepts the write and then refuses the
    // undo. Two things must hold, and the second is the honest residual rather
    // than a cleanup guarantee:
    //   1. the error that surfaces is the PUBLISH failure, not the setter's
    //      TypeError — a cleanup problem may not replace the real diagnosis;
    //   2. the sanitized text can remain in the global slot. The hook does not
    //      claim unconditional cleanup, and this test is where that limit is
    //      written down instead of discovered.
    const result = runHook({
        protectResult: COVERED, destination: 'global_output',
        globalOutputRestoreFails: true, constOutputBinding: true
    });

    assert.ok(result.raised, 'a failed publish must still raise');
    assert.match(String(result.raised.message), /could not publish its output/,
        result.raised.message);
    assert.ok(!String(result.raised.message).includes('refuses to be restored'),
        'the undo failure must not replace the publish error: ' + result.raised.message);
    assert.ok(!String(result.raised.message).includes(LucairnSkillGuard.ERROR_PREFIX),
        result.raised.message);
    // The consumed binding — the lexical one — was never changed. That is the
    // property that matters for safety.
    assert.strictEqual(result.outputInRealm, '__untouched__');
    // The documented residual, asserted rather than wished away.
    assert.strictEqual(result.context.globalOutputHeld.value, SANITIZED,
        'the header says the undo is best-effort; this is what best-effort means');
});

test('destination global_output: no reachable global scope raises', () => {
    // A strict ES5 wrapper on a runtime with neither `globalThis` nor
    // `Function`. Nowhere to publish to, so raise — content-free and under the
    // wiring prefix.
    const { raised, outputInRealm } = runHook({
        protectResult: COVERED, destination: 'global_output',
        strictEs5Wrapper: true, withholdFunctionConstructor: true
    });

    assert.ok(raised, 'an unreachable global scope must not be a silent success');
    assert.match(String(raised.message), /could not publish its output/);
    assert.ok(!String(raised.message).includes(LucairnSkillGuard.ERROR_PREFIX),
        'a wiring failure must not present as "skill run blocked": ' + raised.message);
    assert.ok(!String(raised.message).includes('Brannagh'), raised.message);
    assert.strictEqual(outputInRealm, null, 'nothing may have been published');
});

test('destination global_output: a strict ES5 wrapper with no globalThis still reaches the realm', () => {
    // `(function(){return this;}())` is undefined under a strict wrapper. The
    // Function constructor builds a non-strict function whatever the caller's
    // strictness, so its `this` is still the global object. Round-3 advisory.
    const { raised, outputInRealm } = runHook({
        protectResult: COVERED, destination: 'global_output', strictEs5Wrapper: true
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(outputInRealm, SANITIZED);
});

test('destination bare_output under a strict ES5 wrapper with a pre-declared binding is unaffected', () => {
    // The global-scope question never arises when the declared destination is
    // the binding itself.
    const { raised, outputInRealm } = runHook({
        protectResult: COVERED, destination: 'bare_output', strictEs5Wrapper: true,
        withholdFunctionConstructor: true, declareOutput: true
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(outputInRealm, SANITIZED);
});

/* ======================================================================== */
/* Rounds 3 and 4: only a READ-BACK counts as published                     */
/* ======================================================================== */

test('P1 (round 3): a REJECTED assignment raises — and nothing is published behind its back', () => {
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
    // Round 5 makes this stronger than "undone": the global slot is not a
    // destination here at all, so nothing was ever written to it.
    assert.strictEqual(result.globalPropInRealm, null,
        'an undeclared destination must not be written, let alone relied on');
});

test('P1 (round 3): the same holds for a global binding whose setter throws', () => {
    const result = runHook({ protectResult: COVERED, rejectOutputAssignment: true });

    assertPublishFailure(result, '__untouched__');
});

test('P1 (round 4): a with-scoped getter that throws ReferenceError does NOT read as an absent binding', () => {
    // THE REPRODUCER, verbatim from the round-4 gate finding, and it must stay
    // green. A Rhino extension point can genuinely be `with`-scoped. The scope
    // object's `output` getter throws a same-realm ReferenceError on its FIRST
    // read and returns the raw text on every read after; its setter rejects.
    //
    // Round 4 answered "does the binding exist?" with a READ PROBE and
    // classified by exception type: ReferenceError meant absent. So it took
    // that first throw as absence, wrote SANITIZED to globalThis.output — a
    // slot the `with` scope shadows — and RETURNED NORMALLY. The model then ran
    // on the scope binding, which still held RAW, under a covered verdict.
    //
    // No exception type can establish where a value ended up; only reading the
    // destination back can. Round 5 adds the other half: and no other
    // destination may be tried when that read-back fails.
    const result = runHook({
        protectResult: COVERED, withScope: 'reference-error-then-raw'
    });

    assertPublishFailure(result);

    assert.strictEqual(result.scopeConsumed, 'RAW');
    assert.strictEqual(result.globalPropInRealm, null,
        'globalThis.output must not be left holding a "success" the scope shadows');

    // The shape really was exercised: the write was attempted on the declared
    // destination, and the single read is the read-back that follows it.
    assert.strictEqual(result.scopeWrites, 1, 'the write must have been attempted');
    assert.strictEqual(result.scopeReads, 1,
        'exactly one read of the declared destination: the read-back');
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

/* ======================================================================== */
/* The fail-open (uncovered) path and the blocking path                     */
/* ======================================================================== */

test('an uncovered (fail-open) run publishes the annotated text, and does not abort', () => {
    const { context, raised } = runHook({ protectResult: UNCOVERED, declareOutput: true });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.ok(String(context.output).indexOf(LucairnSkillGuard.UNCOVERED_ANNOTATION) === 0,
        String(context.output));
    assert.ok(String(context.output).includes('No certificate exists'));
    // The override means the raw text proceeds — labelled, but raw.
    assert.ok(String(context.output).includes('Brannagh'));
});

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
    // The raise exits before the publish, so whatever the extension point
    // already held is what it still holds. On outcome (b) — a swallowed raise —
    // that is the ORIGINAL text, with no annotation. README Leg 6 says so.
    const { context, raised } = runHook({ protectResult: BLOCKED, declareOutput: true });

    assert.ok(raised);
    assert.strictEqual(context.output, '__untouched__');
});

/* ---- input handling ----------------------------------------------------- */

test('a platform that exposes no input at all is handled as an empty submission', () => {
    const { raised, seen, context } = runHook({
        protectResult: COVERED, omitInput: true, declareOutput: true
    });

    assert.strictEqual(raised, null, raised && raised.message);
    assert.strictEqual(seen[0].text, '');
    assert.strictEqual(context.output, SANITIZED);
});

test('a non-string input is coerced before it reaches the guard', () => {
    const { raised, seen } = runHook({
        protectResult: COVERED, input: 12345, declareOutput: true
    });

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
    // All four destinations are hypotheses too, and the file must keep saying so.
    assert.ok(/ALL FOUR ARE ADJUST-ON-PDI HYPOTHESES/.test(HOOK_SOURCE),
        'the destination list must stay labelled as unobserved');
});
