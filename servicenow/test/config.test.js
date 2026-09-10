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
    assert.strictEqual(cfg.timeoutMs, 30000);
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
    assert.strictEqual(makeConfig({ [P.TIMEOUT_MS]: 'soon' }).resolve().timeoutMs, 30000);
    assert.strictEqual(makeConfig({ [P.TIMEOUT_MS]: '0' }).resolve().timeoutMs, 30000);
    assert.strictEqual(makeConfig({ [P.TIMEOUT_MS]: '-5' }).resolve().timeoutMs, 30000);
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
