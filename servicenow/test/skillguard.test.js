'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

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

test('the preprocessor hook stub consumes allowed:false and is labelled a hypothesis', () => {
    // The hook is a paste-in for an extension point that has never run, so it
    // cannot be executed here. What CAN be checked is that it did not quietly
    // become an unlabelled claim, and that it still consumes the block.
    const hook = fs.readFileSync(
        path.join(__dirname, '..', 'src', 'hooks', 'genai-preprocessor.js'), 'utf8');

    assert.ok(/HYPOTHESIS/.test(hook), 'the hook must carry its hypothesis label');
    assert.ok(/verdict\.block/.test(hook), 'the hook must consume the block decision');
    assert.ok(/throw new Error/.test(hook), 'the hook must act on a block, not just report it');
    assert.ok(/ADJUST-ON-PDI/.test(hook), 'the unproven bindings must stay marked');
    assert.ok(/Leg 6/.test(hook), 'the hook must point at its falsifier');
});
