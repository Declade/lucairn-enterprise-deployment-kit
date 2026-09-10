'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { FakeTable, glideRecordSeam } = require('./mocks/servicenow');
const LucairnConfig = require('../src/script_includes/LucairnConfig');

function makeConfig(props, tables) {
    tables = tables || {};
    return new LucairnConfig({
        getProperty: (name, fallback) =>
            (Object.prototype.hasOwnProperty.call(props, name) ? props[name] : fallback),
        glideRecord: glideRecordSeam(tables),
        log: () => {}
    });
}

const P = LucairnConfig.PROP;

test('defaults resolve to the named-REST-message transport', () => {
    const cfg = makeConfig({ [P.VENDOR]: 'openai' }).resolve();
    assert.strictEqual(cfg.transport, 'rest_message');
    assert.strictEqual(cfg.restMessage, 'Lucairn Service');
    assert.strictEqual(cfg.fnSanitize, 'sanitizeOnly');
    assert.strictEqual(cfg.fnSeal, 'sealCert');
    assert.strictEqual(cfg.timeoutMs, 45000);
    assert.strictEqual(cfg.clientId, 'lucairn-for-now-assist');
});

test('an unset vendor fails validation (no default is guessed)', () => {
    const c = makeConfig({});
    const problems = c.validate(c.resolve());
    assert.ok(problems.some((p) => p.includes('vendor is not set')), problems.join('|'));
});

test('a vendor outside the service allow-list fails validation', () => {
    const c = makeConfig({ [P.VENDOR]: 'servicenow' });
    const problems = c.validate(c.resolve());
    assert.ok(problems.some((p) => p.includes('not one of')), problems.join('|'));
});

test('endpoint mode requires https and an api key', () => {
    const c = makeConfig({
        [P.TRANSPORT]: 'endpoint',
        [P.BASE_URL]: 'http://insecure.example.test',
        [P.VENDOR]: 'openai'
    });
    const problems = c.validate(c.resolve());
    assert.ok(problems.some((p) => p.includes('must be https')), problems.join('|'));
    assert.ok(problems.some((p) => p.includes('api_key is not set')), problems.join('|'));
});

test('a valid endpoint-mode config has no problems and strips the trailing slash', () => {
    const c = makeConfig({
        [P.TRANSPORT]: 'endpoint',
        [P.BASE_URL]: 'https://lucairn.example.test/',
        [P.API_KEY]: 'lcr_live_synthetic_key',
        [P.VENDOR]: 'anthropic'
    });
    const cfg = c.resolve();
    assert.strictEqual(cfg.baseUrl, 'https://lucairn.example.test');
    assert.deepStrictEqual(c.validate(cfg), []);
});

test('a non-numeric or non-positive timeout falls back to the default', () => {
    assert.strictEqual(makeConfig({ [P.TIMEOUT_MS]: 'soon' }).resolve().timeoutMs, 45000);
    assert.strictEqual(makeConfig({ [P.TIMEOUT_MS]: '0' }).resolve().timeoutMs, 45000);
    assert.strictEqual(makeConfig({ [P.TIMEOUT_MS]: '-5' }).resolve().timeoutMs, 45000);
    assert.strictEqual(makeConfig({ [P.TIMEOUT_MS]: '4500' }).resolve().timeoutMs, 4500);
});

test('an unknown skill is fail-closed', () => {
    const tables = { [LucairnConfig.TABLE_SKILL_POLICY]: new FakeTable(LucairnConfig.TABLE_SKILL_POLICY) };
    const policy = makeConfig({}, tables).skillPolicy('Incident summarization');
    assert.strictEqual(policy.failOpen, false);
    assert.strictEqual(policy.source, 'default-fail-closed');
});

test('an explicit active fail-open row flips that one skill', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    table.seed({ skill_name: 'Incident summarization', active: '1', fail_open: '1' });
    table.seed({ skill_name: 'Change risk explainer', active: '1', fail_open: '0' });
    const c = makeConfig({}, { [LucairnConfig.TABLE_SKILL_POLICY]: table });

    assert.strictEqual(c.skillPolicy('Incident summarization').failOpen, true);
    assert.strictEqual(c.skillPolicy('Change risk explainer').failOpen, false);
    assert.strictEqual(c.skillPolicy('Some other skill').failOpen, false);
});

test('an inactive fail-open row does NOT flip the skill', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    table.seed({ skill_name: 'Incident summarization', active: '0', fail_open: '1' });
    const c = makeConfig({}, { [LucairnConfig.TABLE_SKILL_POLICY]: table });
    assert.strictEqual(c.skillPolicy('Incident summarization').failOpen, false);
});

test('a thrown policy lookup stays fail-closed', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    table.queryShouldThrow = true;
    const c = makeConfig({}, { [LucairnConfig.TABLE_SKILL_POLICY]: table });
    const policy = c.skillPolicy('Incident summarization');
    assert.strictEqual(policy.failOpen, false);
    assert.strictEqual(policy.source, 'lookup-error-fail-closed');
});

test('an empty skill name is fail-closed without touching the table', () => {
    const c = makeConfig({}, {}); // no tables registered: any access would throw
    assert.strictEqual(c.skillPolicy('').failOpen, false);
});

/* ---- round-1 gate finding 2: the query predicate is not the guarantee ----
 *
 * A scoped GlideRecord DROPS a condition naming a field the table does not
 * have. Every test below sets up a table on which the old code — which trusted
 * the predicate — returned failOpen = true for a skill that has no override.
 */

test('a policy table missing skill_name cannot widen fail-open (dropped predicate)', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    // The table exists but has no skill_name column, so addQuery('skill_name', …)
    // is discarded and every row becomes a candidate.
    table.missingFields = ['skill_name'];
    table.seed({ active: '1', fail_open: '1', justification: 'some other skill' });
    const c = makeConfig({}, { [LucairnConfig.TABLE_SKILL_POLICY]: table });

    const policy = c.skillPolicy('Incident summarization');
    assert.strictEqual(policy.failOpen, false);
    assert.strictEqual(policy.source, 'schema-invalid-fail-closed');
});

test('a policy table missing active cannot let an inactive override through', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    table.missingFields = ['active'];
    table.seed({ skill_name: 'Incident summarization', fail_open: '1' });
    const c = makeConfig({}, { [LucairnConfig.TABLE_SKILL_POLICY]: table });

    assert.strictEqual(c.skillPolicy('Incident summarization').failOpen, false);
});

test('a returned row for a DIFFERENT skill is rejected in code, not trusted', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    // The schema is complete, so the schema check passes — but the fake drops
    // the predicate anyway, standing in for any platform-side reason the filter
    // did not apply. The row-identity re-check is the only thing left.
    table.seed({ skill_name: 'Change risk explainer', active: '1', fail_open: '1' });
    const c = makeConfig({}, { [LucairnConfig.TABLE_SKILL_POLICY]: table });
    const gr = glideRecordSeam({ [LucairnConfig.TABLE_SKILL_POLICY]: table });

    const cheating = new LucairnConfig({
        getProperty: (n, f) => f,
        glideRecord: (name) => {
            const rec = gr(name);
            rec.addQuery = function () { /* predicates silently go nowhere */ };
            return rec;
        },
        log: () => {}
    });

    const policy = cheating.skillPolicy('Incident summarization');
    assert.strictEqual(policy.failOpen, false);
    assert.strictEqual(policy.source, 'row-identity-mismatch-fail-closed');
    // Sanity: the same table DOES flip the skill the row actually names.
    assert.strictEqual(c.skillPolicy('Change risk explainer').failOpen, true);
});

test('a dropped setLimit that yields two candidate rows is an ambiguous policy', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    table.ignoreLimit = true;
    table.seed({ skill_name: 'Incident summarization', active: '1', fail_open: '1' });
    table.seed({ skill_name: 'Incident summarization', active: '1', fail_open: '0' });
    const c = makeConfig({}, { [LucairnConfig.TABLE_SKILL_POLICY]: table });

    const policy = c.skillPolicy('Incident summarization');
    assert.strictEqual(policy.failOpen, false);
    assert.strictEqual(policy.source, 'ambiguous-policy-fail-closed');
});

test('a missing policy table is fail-closed', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    table.tableInvalid = true;
    table.seed({ skill_name: 'Incident summarization', active: '1', fail_open: '1' });
    const c = makeConfig({}, { [LucairnConfig.TABLE_SKILL_POLICY]: table });

    assert.strictEqual(c.skillPolicy('Incident summarization').source, 'schema-invalid-fail-closed');
});

test('a runtime without isValid()/isValidField() is fail-closed, not assumed fine', () => {
    // Absence of the validation API means we cannot check the schema, and an
    // unverifiable lookup is not a lookup we may act on.
    const bare = {
        addQuery: () => {},
        setLimit: () => {},
        query: () => {},
        next: () => true,
        getValue: (f) => ({ skill_name: 'Incident summarization', active: '1', fail_open: '1' }[f])
    };
    const c = new LucairnConfig({
        getProperty: (n, f) => f,
        glideRecord: () => bare,
        log: () => {}
    });

    const policy = c.skillPolicy('Incident summarization');
    assert.strictEqual(policy.failOpen, false);
    assert.strictEqual(policy.source, 'schema-invalid-fail-closed');
});

test('a throwing isValid() is fail-closed', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    table.isValidShouldThrow = true;
    table.seed({ skill_name: 'Incident summarization', active: '1', fail_open: '1' });
    const c = makeConfig({}, { [LucairnConfig.TABLE_SKILL_POLICY]: table });

    assert.strictEqual(c.skillPolicy('Incident summarization').source, 'lookup-error-fail-closed');
});

test('a case-differing policy row does not apply (the platform match is case-insensitive)', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    table.seed({ skill_name: 'incident summarization', active: '1', fail_open: '1' });
    const c = makeConfig({}, { [LucairnConfig.TABLE_SKILL_POLICY]: table });

    // The fake compares with String(), so the row is not even selected here;
    // on the platform it WOULD be selected and then rejected by the identity
    // re-check. Both paths land on fail-closed, which is the property that
    // matters — a near-miss row must never turn protection off.
    assert.strictEqual(c.skillPolicy('Incident summarization').failOpen, false);
    assert.strictEqual(c.skillPolicy('incident summarization').failOpen, true);
});

test('a policy lookup failure log carries no exception text', () => {
    const table = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    table.queryShouldThrow = true;
    const logs = [];
    const c = new LucairnConfig({
        getProperty: (n, f) => f,
        glideRecord: glideRecordSeam({ [LucairnConfig.TABLE_SKILL_POLICY]: table }),
        log: (m) => logs.push(m)
    });

    c.skillPolicy('Incident summarization');
    assert.ok(logs.length > 0);
    assert.ok(!logs.join('|').includes('simulated query failure'), logs.join('|'));
});
