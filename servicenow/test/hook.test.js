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
    vm.createContext(context);

    let raised = null;
    try {
        vm.runInContext(HOOK_SOURCE, context, { filename: 'genai-preprocessor.js' });
    } catch (e) {
        raised = e;
    }
    return { context, raised, seen };
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
