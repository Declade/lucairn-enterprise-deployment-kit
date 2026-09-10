'use strict';

const test = require('node:test');
const assert = require('node:assert');

require('./mocks/servicenow');
const LucairnSkillGuard = require('../src/script_includes/LucairnSkillGuard');

const RAW = 'Reported by Brannagh Oduya-Kestrel (brannagh.oduya-kestrel@northmarrow-example.test).';
const SANITIZED = 'Reported by [PERSON_1] ([EMAIL_1]).';

/**
 * A guard over a stubbed adapter. The adapter's own behaviour is covered by
 * adapter.test.js; what is under test here is whether a decision becomes an
 * OUTCOME — round-1 gate finding 7.
 */
function guardOver(protectResult) {
    const logs = [];
    const guard = new LucairnSkillGuard({
        adapter: { protect: () => protectResult },
        log: (m) => logs.push(m)
    });
    return { guard, logs };
}

const BLOCKED = {
    allowed: false, coverage: 'uncovered', textForSkill: '',
    correlationId: 'corr_1', evidenceId: 'ev_1',
    error: { code: 'lucairn_service_unreachable', failure_class: 'connection_refused' }
};

const COVERED = {
    allowed: true, coverage: 'covered', textForSkill: SANITIZED,
    correlationId: 'corr_1', evidenceId: 'ev_1', error: null
};

const UNCOVERED = {
    allowed: true, coverage: 'uncovered', textForSkill: RAW,
    correlationId: 'corr_1', evidenceId: 'ev_1',
    error: { code: 'lucairn_service_unreachable', failure_class: 'connection_refused' }
};

test('a blocked decision becomes a blocked run: enforce() raises and forwards nothing', () => {
    const { guard, logs } = guardOver(BLOCKED);

    assert.throws(() => guard.enforce({ skill: 'Incident summarization', text: RAW }),
        /skill run blocked/);
    assert.strictEqual(guard.evaluate({ skill: 'Incident summarization', text: RAW }).text, '');
    assert.ok(logs.some((l) => l.includes('blocking')), logs.join('|'));
});

test('a blocked decision never leaks the submitted text into the raised error', () => {
    const { guard } = guardOver(BLOCKED);
    let raised = null;
    try {
        guard.enforce({ skill: 'Incident summarization', text: RAW });
    } catch (e) {
        raised = e;
    }
    assert.ok(raised);
    assert.ok(!raised.message.includes('Brannagh'), raised.message);
});

test('a covered decision hands the skill the sanitized text and nothing else', () => {
    const { guard } = guardOver(COVERED);
    const text = guard.enforce({ skill: 'Incident summarization', text: RAW });

    assert.strictEqual(text, SANITIZED);
    assert.ok(!text.includes('Brannagh'));
    assert.strictEqual(guard.evaluate({ skill: 'x', text: RAW }).annotated, false);
});

test('an uncovered (fail-open) run proceeds but carries a visible annotation', () => {
    const { guard } = guardOver(UNCOVERED);
    const verdict = guard.evaluate({ skill: 'Incident summarization', text: RAW });

    assert.strictEqual(verdict.block, false);
    assert.strictEqual(verdict.decision, 'uncovered');
    assert.strictEqual(verdict.annotated, true);
    assert.ok(verdict.text.indexOf(LucairnSkillGuard.UNCOVERED_ANNOTATION) === 0, verdict.text);
    assert.ok(verdict.text.includes('No certificate exists'));
    // enforce() does not raise on an override — that is what the override means.
    assert.doesNotThrow(() => guard.enforce({ skill: 'Incident summarization', text: RAW }));
});

test('every decision carries the ids needed to find the run in the evidence table', () => {
    for (const res of [BLOCKED, COVERED, UNCOVERED]) {
        const { guard } = guardOver(res);
        const verdict = guard.evaluate({ skill: 'Incident summarization', text: RAW });
        assert.strictEqual(verdict.evidenceId, 'ev_1');
        assert.strictEqual(verdict.correlationId, 'corr_1');
    }
});

/*
 * The preprocessor hook itself is covered by test/hook.test.js, which EXECUTES
 * it in `node:vm`. A source-text grep used to stand in for that here, above a
 * comment asserting the hook "cannot be executed" — and while it was only being
 * grepped, its success path carried a ReferenceError that aborted every allowed
 * run (round-2 gate finding N-1). A test that reads code for the right-looking
 * words cannot fail on the code being wrong.
 */

