'use strict';

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');

const { FakeTable, glideRecordSeam, fakeRestMessage } = require('./mocks/servicenow');
const LucairnConfig = require('../src/script_includes/LucairnConfig');
const LucairnEvidence = require('../src/script_includes/LucairnEvidence');
const LucairnClient = require('../src/script_includes/LucairnClient');
const LucairnSha256 = require('../src/script_includes/LucairnSha256');
const LucairnNowAssistAdapter = require('../src/script_includes/LucairnNowAssistAdapter');

const fixtures = require('../fixtures/synthetic-incidents.json');
const INCIDENT = fixtures.incidents.find((i) => i.id === 'fixture-basic-contact');
const SKILL = fixtures.skill_names.protected;

const P = LucairnConfig.PROP;

const SANITIZED = 'Reported by [PERSON_1] ([EMAIL_1], [PHONE_1]). Her ThinkPad in office 4.12 shows a firmware error.';

function sanitizeOkBody() {
    return JSON.stringify({
        sanitized_text: SANITIZED,
        placeholder_map_id: 'pmap_synthetic1',
        manifest: {
            redaction_count: { person_name: 1, email: 1, phone: 1 },
            categories_triggered: ['person_name', 'email', 'phone'],
            layers_active: ['regex_pii', 'ner_pii'],
            sanitizer_version: 'test-fixture'
        },
        cert_id_partial: 'cert_partial_synthetic1',
        expires_at: '2026-09-10T12:05:00Z'
    });
}

function sealOkBody() {
    return JSON.stringify({
        cert_id: 'cert_synthetic1',
        cert_url: 'https://lucairn.example.test/api/v1/veil/certificate/req_synthetic1',
        cert_tier: 'input-shield'
    });
}

/**
 * Build an adapter over the real Config / Evidence / Client Script Includes,
 * with only the platform boundary (properties, GlideRecord, RESTMessageV2)
 * faked. The fail-closed decision therefore runs through the real code path.
 *
 * @param {object} opts
 * @param {object} [opts.props]        system properties
 * @param {Array}  [opts.policyRows]   rows seeded into the skill policy table
 * @param {Array}  [opts.scripts]      per-call RESTMessageV2 scripts, in order
 * @param {boolean}[opts.evidenceInsertFails]
 */
function harness(opts) {
    opts = opts || {};
    const props = Object.assign({ [P.VENDOR]: 'openai' }, opts.props || {});

    const policyTable = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    (opts.policyRows || []).forEach((r) => policyTable.seed(r));

    const evidenceTable = new FakeTable(LucairnEvidence.TABLE);
    evidenceTable.insertShouldFail = opts.evidenceInsertFails === true;

    const tables = {
        [LucairnConfig.TABLE_SKILL_POLICY]: policyTable,
        [LucairnEvidence.TABLE]: evidenceTable
    };
    const gr = glideRecordSeam(tables);
    const logs = [];
    const log = (m) => logs.push(m);

    const scripts = (opts.scripts || []).slice();
    const messages = [];
    let clock = 1000;
    const now = () => (clock += 20);

    const config = new LucairnConfig({
        getProperty: (name, fallback) =>
            (Object.prototype.hasOwnProperty.call(props, name) ? props[name] : fallback),
        glideRecord: gr,
        log
    });

    const evidence = new LucairnEvidence({
        glideRecord: gr,
        log,
        now: () => '2026-09-10 12:00:00'
    });

    const makeClient = (cfg) => new LucairnClient(cfg, {
        newNamedMessage: (name, fn) => {
            const script = scripts.shift() || { status: 200, body: sanitizeOkBody() };
            const msg = fakeRestMessage(script);
            msg.calls.constructedWith = [name, fn];
            messages.push(msg);
            return msg;
        },
        newMessage: () => {
            const script = scripts.shift() || { status: 200, body: sanitizeOkBody() };
            const msg = fakeRestMessage(script);
            messages.push(msg);
            return msg;
        },
        now,
        log
    });

    const adapter = new LucairnNowAssistAdapter({
        config,
        evidence,
        sha256: LucairnSha256,
        makeClient,
        guid: () => 'corr_synthetic1',
        now,
        log
    });

    return { adapter, evidenceTable, policyTable, messages, logs };
}

/* ---- happy path --------------------------------------------------------- */

test('happy path: the skill receives sanitized text and a covered evidence row is written', () => {
    const h = harness({ scripts: [{ status: 200, body: sanitizeOkBody() }] });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, true);
    assert.strictEqual(res.coverage, 'covered');
    assert.strictEqual(res.textForSkill, SANITIZED);
    assert.strictEqual(res.certIdPartial, 'cert_partial_synthetic1');
    assert.strictEqual(res.placeholderMapId, 'pmap_synthetic1');
    assert.strictEqual(res.error, null);

    // The raw content must not reach the skill.
    assert.ok(!res.textForSkill.includes('Brannagh'));
    assert.ok(!res.textForSkill.includes('brannagh.oduya-kestrel@northmarrow-example.test'));

    assert.strictEqual(h.evidenceTable.rows.length, 1);
    const row = h.evidenceTable.rows[0];
    assert.strictEqual(row.outcome, 'covered');
    assert.strictEqual(row.skill, SKILL);
    assert.strictEqual(row.failure_class, 'none');
    assert.strictEqual(row.redaction_total, 3);
    assert.strictEqual(row.layers_active, 'regex_pii,ner_pii');
    assert.strictEqual(row.fail_open_override, false);
    assert.strictEqual(row.correlation_id, 'corr_synthetic1');
});

test('the evidence row stores no submitted or sanitized content', () => {
    const h = harness({ scripts: [{ status: 200, body: sanitizeOkBody() }] });
    h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    const serialised = JSON.stringify(h.evidenceTable.rows);

    assert.ok(!serialised.includes('Brannagh'), serialised);
    assert.ok(!serialised.includes('[PERSON_1]'), serialised);
    assert.ok(!serialised.includes('ThinkPad'), serialised);
});

test('seal(): hashes cover the forwarded and response bytes and the cert lands on the row', () => {
    const h = harness({
        scripts: [
            { status: 200, body: sanitizeOkBody() },
            { status: 200, body: sealOkBody() }
        ]
    });
    const protectRes = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    const responseText = 'Summary: a laptop fails to boot after a patch window.';
    const sealRes = h.adapter.seal({ protectResult: protectRes, responseText });

    assert.strictEqual(sealRes.sealed, true);
    assert.strictEqual(sealRes.certId, 'cert_synthetic1');
    assert.strictEqual(sealRes.certTier, 'input-shield');
    assert.strictEqual(sealRes.error, null);

    const sent = JSON.parse(h.messages[1].calls.body);
    assert.strictEqual(sent.cert_id_partial, 'cert_partial_synthetic1');
    assert.strictEqual(sent.vendor, 'openai');
    assert.strictEqual(
        sent.request_content_hash,
        'sha256:' + crypto.createHash('sha256').update(SANITIZED, 'utf8').digest('hex')
    );
    assert.strictEqual(
        sent.response_content_hash,
        'sha256:' + crypto.createHash('sha256').update(responseText, 'utf8').digest('hex')
    );
    assert.strictEqual(sent.tool_name, 'ServiceNow Now Assist — ' + SKILL);

    assert.strictEqual(h.evidenceTable.rows[0].cert_id, 'cert_synthetic1');
    assert.match(h.evidenceTable.rows[0].cert_url, /veil\/certificate/);
});

test('seal(): an explicit forwardedText is hashed instead of the assumed one', () => {
    const h = harness({
        scripts: [
            { status: 200, body: sanitizeOkBody() },
            { status: 200, body: sealOkBody() }
        ]
    });
    const protectRes = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    const wrapped = 'Context: ' + SANITIZED;
    h.adapter.seal({ protectResult: protectRes, responseText: 'ok', forwardedText: wrapped });

    const sent = JSON.parse(h.messages[1].calls.body);
    assert.strictEqual(
        sent.request_content_hash,
        'sha256:' + crypto.createHash('sha256').update(wrapped, 'utf8').digest('hex')
    );
});

/* ---- fail-closed: connection refused ------------------------------------ */

test('FAIL-CLOSED on connection refused: the run is blocked and an evidence row is written', () => {
    const h = harness({
        scripts: [{ throwOnExecute: new Error('java.net.ConnectException: Connection refused') }]
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, false);
    assert.strictEqual(res.textForSkill, '');
    assert.strictEqual(res.error.code, LucairnNowAssistAdapter.ERROR.UNREACHABLE);
    assert.strictEqual(res.error.failure_class, 'connection_refused');
    assert.strictEqual(res.error.correlation_id, 'corr_synthetic1');
    assert.ok(res.error.evidence_id);

    assert.strictEqual(h.evidenceTable.rows.length, 1);
    assert.strictEqual(h.evidenceTable.rows[0].outcome, 'blocked');
    assert.strictEqual(h.evidenceTable.rows[0].failure_class, 'connection_refused');
    assert.strictEqual(h.evidenceTable.rows[0].fail_open_override, false);
});

/* ---- fail-closed: timeout ----------------------------------------------- */

test('FAIL-CLOSED on timeout: the run is blocked and an evidence row is written', () => {
    const h = harness({
        scripts: [{ throwOnExecute: new Error('java.net.SocketTimeoutException: Read timed out') }]
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, false);
    assert.strictEqual(res.textForSkill, '');
    assert.strictEqual(res.error.failure_class, 'timeout');
    assert.strictEqual(h.evidenceTable.rows[0].outcome, 'blocked');
    assert.strictEqual(h.evidenceTable.rows[0].failure_class, 'timeout');
});

test('FAIL-CLOSED on a 5xx, on a contract violation, and on a bad config', () => {
    const cases = [
        {
            name: 'http 503',
            opts: { scripts: [{ status: 503, body: JSON.stringify({ error: 'sanitizer_unavailable', message: 'down' }) }] },
            failureClass: 'http_error',
            code: LucairnNowAssistAdapter.ERROR.UNREACHABLE
        },
        {
            name: '200 missing cert_id_partial',
            opts: { scripts: [{ status: 200, body: JSON.stringify({ sanitized_text: 'x', placeholder_map_id: 'p' }) }] },
            failureClass: 'contract_error',
            code: LucairnNowAssistAdapter.ERROR.CONTRACT
        },
        {
            name: 'vendor not configured',
            opts: { props: { [P.VENDOR]: '' } },
            failureClass: 'config_error',
            code: LucairnNowAssistAdapter.ERROR.CONFIG
        }
    ];

    for (const c of cases) {
        const h = harness(c.opts);
        const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
        assert.strictEqual(res.allowed, false, c.name);
        assert.strictEqual(res.error.failure_class, c.failureClass, c.name);
        assert.strictEqual(res.error.code, c.code, c.name);
        assert.strictEqual(h.evidenceTable.rows[0].outcome, 'blocked', c.name);
    }
});

test('a missing skill name is blocked outright, with no policy lookup to override it', () => {
    const h = harness({ policyRows: [{ skill_name: '', active: '1', fail_open: '1' }] });
    const res = h.adapter.protect({ skill: '', text: 'anything' });

    assert.strictEqual(res.allowed, false);
    assert.strictEqual(res.error.code, LucairnNowAssistAdapter.ERROR.INPUT);
});

test('a blocked run still reports the failure even if the evidence insert fails', () => {
    const h = harness({
        scripts: [{ throwOnExecute: new Error('Connection refused') }],
        evidenceInsertFails: true
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    // Losing the audit row must not turn a block into a pass.
    assert.strictEqual(res.allowed, false);
    assert.strictEqual(res.error.evidence_id, '');
});

/* ---- fail-open override -------------------------------------------------- */

test('FAIL-OPEN override: the configured skill runs raw and an uncovered_run row is written', () => {
    const h = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        scripts: [{ throwOnExecute: new Error('Connection refused') }]
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, true);
    assert.strictEqual(res.coverage, 'uncovered');
    assert.strictEqual(res.textForSkill, INCIDENT.description);
    assert.strictEqual(res.certIdPartial, '');
    assert.strictEqual(res.error.failure_class, 'connection_refused');

    assert.strictEqual(h.evidenceTable.rows.length, 1);
    const row = h.evidenceTable.rows[0];
    assert.strictEqual(row.outcome, 'uncovered_run');
    assert.strictEqual(row.fail_open_override, true);
    assert.strictEqual(row.failure_class, 'connection_refused');
    assert.ok(h.logs.some((l) => l.includes('unsanitized content')), h.logs.join('|'));
});

test('FAIL-OPEN override applies to timeouts too, and only to the listed skill', () => {
    const h = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        scripts: [{ throwOnExecute: new Error('Read timed out') }]
    });
    assert.strictEqual(h.adapter.protect({ skill: SKILL, text: 'x' }).allowed, true);

    const h2 = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        scripts: [{ throwOnExecute: new Error('Read timed out') }]
    });
    const other = h2.adapter.protect({ skill: fixtures.skill_names.unlisted, text: 'x' });
    assert.strictEqual(other.allowed, false);
    assert.strictEqual(h2.evidenceTable.rows[0].outcome, 'blocked');
});

test('an uncovered run cannot be sealed into a certificate', () => {
    const h = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        scripts: [{ throwOnExecute: new Error('Connection refused') }]
    });
    const protectRes = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    const sealRes = h.adapter.seal({ protectResult: protectRes, responseText: 'a summary' });

    assert.strictEqual(sealRes.sealed, false);
    assert.strictEqual(sealRes.error.code, LucairnNowAssistAdapter.ERROR.NOT_COVERED);
    // Only the sanitize attempt was made; no seal call went out.
    assert.strictEqual(h.messages.length, 1);
});

test('seal() refuses to invent a response hash when there is no response', () => {
    const h = harness({ scripts: [{ status: 200, body: sanitizeOkBody() }] });
    const protectRes = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    for (const bad of [undefined, null, '', 42]) {
        const sealRes = h.adapter.seal({ protectResult: protectRes, responseText: bad });
        assert.strictEqual(sealRes.sealed, false, String(bad));
        assert.strictEqual(sealRes.error.code, LucairnNowAssistAdapter.ERROR.INPUT, String(bad));
    }
    assert.strictEqual(h.messages.length, 1);
});

test('a seal failure does not retract coverage — the row keeps its covered outcome', () => {
    const h = harness({
        scripts: [
            { status: 200, body: sanitizeOkBody() },
            { throwOnExecute: new Error('Read timed out') }
        ]
    });
    const protectRes = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    const sealRes = h.adapter.seal({ protectResult: protectRes, responseText: 'a summary' });

    assert.strictEqual(sealRes.sealed, false);
    assert.strictEqual(sealRes.error.failure_class, 'timeout');
    assert.strictEqual(h.evidenceTable.rows[0].outcome, 'covered');
    // No certificate reference was attached, so the row shows a covered run
    // with no certificate — which is exactly what happened.
    assert.strictEqual(h.evidenceTable.rows[0].cert_id, '');
    assert.strictEqual(h.evidenceTable.rows[0].cert_url, '');
});

test('protect() never throws, whatever the platform does', () => {
    const h = harness({ scripts: [{ throwOnExecute: new Error('kaboom') }] });
    assert.doesNotThrow(() => h.adapter.protect({ skill: SKILL, text: INCIDENT.description }));
});
