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

function sealOkBody(overrides) {
    return JSON.stringify(Object.assign({
        cert_id: 'cert_synthetic1',
        // The shape the service actually returns: <base>/verify?id=<request_id>.
        cert_url: 'https://lucairn.example.test/verify?id=req_synthetic1',
        cert_tier: 'input-shield'
    }, overrides || {}));
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
 * @param {string[]}[opts.evidenceMissingFields] columns the evidence table does
 *   NOT have — a partially imported table. setValue() on one is discarded and
 *   the insert still returns a sys_id (round-2 finding astra-B1).
 * @param {boolean}[opts.evidenceUpdateFails] update() returns null, the way an
 *   ACL denial surfaces
 * @param {*}[opts.logThrows] make every log call raise
 */
function harness(opts) {
    opts = opts || {};
    const props = Object.assign({ [P.VENDOR]: 'openai' }, opts.props || {});

    const policyTable = new FakeTable(LucairnConfig.TABLE_SKILL_POLICY);
    (opts.policyRows || []).forEach((r) => policyTable.seed(r));

    const evidenceTable = new FakeTable(LucairnEvidence.TABLE);
    evidenceTable.insertShouldFail = opts.evidenceInsertFails === true;
    evidenceTable.updateShouldFail = opts.evidenceUpdateFails === true;
    evidenceTable.missingFields = opts.evidenceMissingFields || [];

    const tables = {
        [LucairnConfig.TABLE_SKILL_POLICY]: policyTable,
        [LucairnEvidence.TABLE]: evidenceTable
    };
    const gr = glideRecordSeam(tables);
    const logs = [];
    const log = (m) => {
        logs.push(m);
        if (opts.logThrows) { throw new Error('gs.warn raised'); }
    };

    const scripts = (opts.scripts || []).slice();
    const messages = [];
    let clock = 1000;
    const now = () => (clock += 20);

    const config = new LucairnConfig({
        getProperty: (name, fallback) => {
            if (opts.getPropertyThrows) {
                throw new Error('gs.getProperty raised: ' + String(opts.getPropertyThrows));
            }
            return Object.prototype.hasOwnProperty.call(props, name) ? props[name] : fallback;
        },
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
    assert.match(h.evidenceTable.rows[0].cert_url, /\/verify\?id=/);
    assert.strictEqual(h.evidenceTable.rows[0].seal_outcome, 'sealed');
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
    assert.ok(h.logs.some((l) => l.includes('without sanitizer coverage')), h.logs.join('|'));
    assert.strictEqual(res.forwardedSanitized, false);
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

/* ======================================================================== *
 * Round-1 gate findings (specs/2026-09/gate-2026-09-10-kit-pr133-s1.md).
 * Each test below reproduces a state the shipped adapter got wrong, and each
 * one fails against the pre-fix code — that is the point of writing them.
 * ======================================================================== */

/* ---- finding 1: the evidence row is the precondition for fail-open ------ */

test('FINDING 1: fail-open + a failed evidence insert BLOCKS the run', () => {
    const h = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        scripts: [{ throwOnExecute: new Error('Connection refused') }],
        evidenceInsertFails: true
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    // An override authorises an AUDITED unprotected run. With no row there is
    // no audit, so what the administrator authorised is not on offer.
    assert.strictEqual(res.allowed, false);
    assert.strictEqual(res.textForSkill, '');
    assert.strictEqual(res.error.code, LucairnNowAssistAdapter.ERROR.UNAUDITABLE);
    assert.strictEqual(res.evidenceStored, false);
    assert.strictEqual(h.evidenceTable.rows.length, 0);
    assert.ok(h.logs.some((l) => l.includes('unauditable')), h.logs.join('|'));
});

test('FINDING 1: the same hole on the timeout class', () => {
    const h = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        scripts: [{ throwOnExecute: new Error('Read timed out') }],
        evidenceInsertFails: true
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, false);
    assert.strictEqual(res.textForSkill, '');
});

test('FINDING 1: a transient insert failure still lets the blocked row land', () => {
    const h = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        scripts: [{ throwOnExecute: new Error('Connection refused') }],
        evidenceInsertFails: true
    });
    // The uncovered_run insert fails; storage recovers before the block is
    // recorded. The run is still blocked, and the row explains why.
    const originalWrite = h.evidenceTable.insertShouldFail;
    assert.strictEqual(originalWrite, true);
    const res = (() => {
        let first = true;
        Object.defineProperty(h.evidenceTable, 'insertShouldFail', {
            get() { if (first) { first = false; return true; } return false; }
        });
        return h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    })();

    assert.strictEqual(res.allowed, false);
    assert.strictEqual(h.evidenceTable.rows.length, 1);
    assert.strictEqual(h.evidenceTable.rows[0].outcome, 'blocked');
    assert.ok(String(h.evidenceTable.rows[0].message).includes('NOT honoured'),
        h.evidenceTable.rows[0].message);
});

/* ---- finding 2: a dropped predicate cannot widen fail-open -------------- */

test('FINDING 2: a policy table with a dropped predicate does not fail the run open', () => {
    const h = harness({
        // A row exists that WOULD fail this skill open, on a table whose
        // skill_name column is missing — so the filter is discarded.
        policyRows: [{ active: '1', fail_open: '1' }],
        scripts: [{ throwOnExecute: new Error('Connection refused') }]
    });
    h.policyTable.missingFields = ['skill_name'];

    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, false);
    assert.strictEqual(res.textForSkill, '');
    assert.strictEqual(h.evidenceTable.rows[0].outcome, 'blocked');
});

test("FINDING 2: another skill's fail-open row cannot be borrowed", () => {
    const h = harness({
        policyRows: [{ skill_name: fixtures.skill_names.unlisted, active: '1', fail_open: '1' }],
        scripts: [{ throwOnExecute: new Error('Connection refused') }]
    });
    h.policyTable.ignoreLimit = true;

    assert.strictEqual(h.adapter.protect({ skill: SKILL, text: 'x' }).allowed, false);
});

/* ---- finding 3: malformed success bodies are not coverage --------------- */

test('FINDING 3: the malformed-body matrix is fail-closed, not "covered"', () => {
    const RAW = INCIDENT.description;
    const cases = [
        {
            name: 'placeholder_map_id is a boolean',
            body: { sanitized_text: SANITIZED, placeholder_map_id: true,
                    cert_id_partial: 'cert_partial_x', expires_at: 'z', manifest: {} }
        },
        {
            name: 'cert_id_partial is an object',
            body: { sanitized_text: SANITIZED, placeholder_map_id: 'pmap_x',
                    cert_id_partial: {}, expires_at: 'z', manifest: {} }
        },
        {
            name: 'the whole gate-probe body: truthy non-strings, no manifest, no expiry',
            body: { sanitized_text: RAW, placeholder_map_id: true, cert_id_partial: {} }
        },
        {
            name: 'placeholder_map_id is an empty string',
            body: { sanitized_text: SANITIZED, placeholder_map_id: '',
                    cert_id_partial: 'cert_partial_x', expires_at: 'z', manifest: {} }
        },
        {
            name: 'cert_id_partial is an empty string',
            body: { sanitized_text: SANITIZED, placeholder_map_id: 'pmap_x',
                    cert_id_partial: '', expires_at: 'z', manifest: {} }
        },
        {
            name: 'sanitized_text is empty for a non-empty submission',
            body: { sanitized_text: '', placeholder_map_id: 'pmap_x',
                    cert_id_partial: 'cert_partial_x', expires_at: 'z', manifest: {} }
        },
        {
            name: 'expires_at is missing',
            body: { sanitized_text: SANITIZED, placeholder_map_id: 'pmap_x',
                    cert_id_partial: 'cert_partial_x', manifest: {} }
        },
        {
            name: 'manifest is an array',
            body: { sanitized_text: SANITIZED, placeholder_map_id: 'pmap_x',
                    cert_id_partial: 'cert_partial_x', expires_at: 'z', manifest: [] }
        },
        {
            name: 'sanitized_text is a number',
            body: { sanitized_text: 42, placeholder_map_id: 'pmap_x',
                    cert_id_partial: 'cert_partial_x', expires_at: 'z', manifest: {} }
        }
    ];

    for (const c of cases) {
        const h = harness({ scripts: [{ status: 200, body: JSON.stringify(c.body) }] });
        const res = h.adapter.protect({ skill: SKILL, text: RAW });

        assert.strictEqual(res.allowed, false, c.name);
        assert.strictEqual(res.coverage, 'uncovered', c.name);
        assert.strictEqual(res.textForSkill, '', c.name);
        assert.strictEqual(res.error.code, LucairnNowAssistAdapter.ERROR.CONTRACT, c.name);
        assert.strictEqual(h.evidenceTable.rows[0].outcome, 'blocked', c.name);
    }
});

test('FINDING 3: a seal response carrying the wrong cert_tier is a contract error', () => {
    // "full-chain" asserts an isolated inference path this integration does not
    // have. Accepting it would let the adapter report a claim it cannot make.
    for (const tier of ['full-chain', '', undefined, 'INPUT-SHIELD', 42]) {
        const h = harness({
            scripts: [
                { status: 200, body: sanitizeOkBody() },
                { status: 200, body: sealOkBody({ cert_tier: tier }) }
            ]
        });
        const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
        const sealRes = h.adapter.seal({ protectResult: pr, responseText: 'a summary' });

        assert.strictEqual(sealRes.sealed, false, String(tier));
        assert.strictEqual(sealRes.certId, '', String(tier));
        assert.strictEqual(sealRes.certTier, '', String(tier));
        assert.strictEqual(sealRes.error.code, LucairnNowAssistAdapter.ERROR.CONTRACT, String(tier));
        // No certificate reference may land on the row.
        assert.strictEqual(h.evidenceTable.rows[0].cert_id, '', String(tier));
        assert.strictEqual(h.evidenceTable.rows[0].seal_outcome, 'failed', String(tier));
    }
});

test('FINDING 3: seal rejects non-string cert identifiers', () => {
    for (const bad of [{ cert_id: true }, { cert_id: {} }, { cert_url: 42 }, { cert_url: '' }]) {
        const h = harness({
            scripts: [
                { status: 200, body: sanitizeOkBody() },
                { status: 200, body: sealOkBody(bad) }
            ]
        });
        const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
        const sealRes = h.adapter.seal({ protectResult: pr, responseText: 'a summary' });

        assert.strictEqual(sealRes.sealed, false, JSON.stringify(bad));
    }
});

test('the sealed result reports the locked tier, not whatever came back', () => {
    const h = harness({
        scripts: [
            { status: 200, body: sanitizeOkBody() },
            { status: 200, body: sealOkBody() }
        ]
    });
    const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    const sealRes = h.adapter.seal({ protectResult: pr, responseText: 'a summary' });
    assert.strictEqual(sealRes.certTier, LucairnNowAssistAdapter.CERT_TIER);
});

/* ---- finding 5: no exception text or credential reaches an evidence row -- */

test('FINDING 5 CANARY: a loaded exception leaks neither content nor credential into evidence', () => {
    const CONTENT_CANARY = 'Brannagh Oduya-Kestrel, brannagh.oduya-kestrel@northmarrow-example.test';
    const KEY_CANARY = 'lcr_live_synthetic_canary_0000';
    const h = harness({
        scripts: [{
            throwOnExecute: new Error(
                `Connection refused while POSTing {"text":"${CONTENT_CANARY}"} ` +
                `with header Authorization: Bearer ${KEY_CANARY}`
            )
        }]
    });
    h.adapter.protect({ skill: SKILL, text: CONTENT_CANARY });

    // Assert on what was STORED, not on what the function returned.
    assert.strictEqual(h.evidenceTable.rows.length, 1);
    const stored = JSON.stringify(h.evidenceTable.rows[0]);
    assert.ok(!stored.includes('Brannagh'), stored);
    assert.ok(!stored.includes('northmarrow-example.test'), stored);
    assert.ok(!stored.includes('lcr_live_'), stored);
    assert.ok(!stored.includes('Bearer'), stored);
    // The classification survived, so the row is still diagnostic.
    assert.strictEqual(h.evidenceTable.rows[0].failure_class, 'connection_refused');
});

test('FINDING 5 CANARY: an upstream 4xx body cannot push its message into evidence', () => {
    const h = harness({
        scripts: [{
            status: 400,
            body: JSON.stringify({
                error: 'invalid_field',
                message: 'rejected "Brannagh Oduya-Kestrel" (key lcr_live_synthetic_leak_canary)'
            })
        }]
    });
    h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    const stored = JSON.stringify(h.evidenceTable.rows[0]);
    assert.ok(!stored.includes('Brannagh'), stored);
    assert.ok(!stored.includes('lcr_live_'), stored);
    assert.ok(stored.includes('invalid_field'), stored); // allow-listed code survives
});

test('FINDING 5 CANARY: a seal failure records a diagnostic with nothing borrowed from upstream', () => {
    const h = harness({
        scripts: [
            { status: 200, body: sanitizeOkBody() },
            {
                status: 503,
                body: JSON.stringify({
                    error: 'veil_evidence_unavailable',
                    message: 'claim failed for "Brannagh Oduya-Kestrel"; key lcr_live_synthetic_leak_canary'
                })
            }
        ]
    });
    const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    const sealRes = h.adapter.seal({ protectResult: pr, responseText: 'a summary' });

    assert.strictEqual(sealRes.sealed, false);
    const stored = JSON.stringify(h.evidenceTable.rows[0]);
    assert.ok(!stored.includes('Brannagh'), stored);
    assert.ok(!stored.includes('lcr_live_'), stored);
});

/* ---- seal-failure recording + no retry ---------------------------------- */

test('a seal failure is RECORDED on the row, not left silent', () => {
    const h = harness({
        scripts: [
            { status: 200, body: sanitizeOkBody() },
            { throwOnExecute: new Error('Read timed out') }
        ]
    });
    const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    h.adapter.seal({ protectResult: pr, responseText: 'a summary' });

    const row = h.evidenceTable.rows[0];
    assert.strictEqual(row.outcome, 'covered');          // coverage is not retracted
    assert.strictEqual(row.seal_outcome, 'failed');      // and the seal failure is on the record
    assert.strictEqual(row.seal_failure_class, 'timeout');
    assert.strictEqual(row.cert_id, '');
});

test('a run that was never sealed is distinguishable from one whose seal failed', () => {
    const h = harness({ scripts: [{ status: 200, body: sanitizeOkBody() }] });
    h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    assert.strictEqual(h.evidenceTable.rows[0].seal_outcome, 'not_attempted');
});

test('seal() makes exactly one call and never retries a consumed partial', () => {
    const h = harness({
        scripts: [
            { status: 200, body: sanitizeOkBody() },
            { status: 503, body: JSON.stringify({ error: 'veil_evidence_unavailable', message: 'consumed' }) }
        ]
    });
    const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    h.adapter.seal({ protectResult: pr, responseText: 'a summary' });

    // One sanitize call + one seal call. A retry would be a third message and
    // would draw a 404 on an already-claimed cert_id_partial.
    assert.strictEqual(h.messages.length, 2);
});

/* ---- M-1: fail-open forwards the least content available ---------------- */

test('M-1: a fail-open run forwards the sanitized text when the response carries one', () => {
    const h = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        scripts: [{
            status: 200,
            // A 200 that is not the documented shape — but it does carry a
            // distinct sanitized_text.
            body: JSON.stringify({ sanitized_text: SANITIZED, placeholder_map_id: 'pmap_x' })
        }]
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, true);
    assert.strictEqual(res.coverage, 'uncovered');   // still NOT a coverage claim
    assert.strictEqual(res.forwardedSanitized, true);
    assert.strictEqual(res.textForSkill, SANITIZED);
    assert.ok(!res.textForSkill.includes('Brannagh'));
    assert.strictEqual(h.evidenceTable.rows[0].outcome, 'uncovered_run');
    assert.ok(String(h.evidenceTable.rows[0].message).includes('forwarded the sanitized_text'),
        h.evidenceTable.rows[0].message);
    // And it still cannot be sealed.
    assert.strictEqual(h.adapter.seal({ protectResult: res, responseText: 'x' }).sealed, false);
});

test('M-1: a response whose "sanitized" text IS the raw submission is recorded as raw', () => {
    const h = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        scripts: [{
            status: 200,
            body: JSON.stringify({ sanitized_text: INCIDENT.description, placeholder_map_id: 'p' })
        }]
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.forwardedSanitized, false);
    assert.ok(String(h.evidenceTable.rows[0].message).includes('forwarded the RAW submission'),
        h.evidenceTable.rows[0].message);
});

/* ---- M-2: a platform throw at the entry point is a block, not an escape -- */

test('M-2: a throwing gs.getProperty returns a BLOCKED result instead of raising', () => {
    const h = harness({ getPropertyThrows: 'property store offline' });

    let res;
    assert.doesNotThrow(() => {
        res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    });
    assert.strictEqual(res.allowed, false);
    assert.strictEqual(res.textForSkill, '');
    assert.strictEqual(res.error.code, LucairnNowAssistAdapter.ERROR.PLATFORM);
    // The block is on the record too.
    assert.strictEqual(h.evidenceTable.rows.length, 1);
    assert.strictEqual(h.evidenceTable.rows[0].outcome, 'blocked');
    // …and the exception text did not ride along into it.
    assert.ok(!JSON.stringify(h.evidenceTable.rows[0]).includes('property store offline'));
});

test('M-2: a fail-open policy cannot rescue a platform throw either', () => {
    const h = harness({
        getPropertyThrows: 'property store offline',
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }]
    });
    // The override is resolved from the same platform that just failed. An
    // adapter that cannot read its own configuration cannot conclude it was
    // told to run unprotected.
    assert.strictEqual(h.adapter.protect({ skill: SKILL, text: 'x' }).allowed, false);
});

test('M-2: seal() survives a platform throw with a typed not-sealed result', () => {
    const h = harness({ scripts: [{ status: 200, body: sanitizeOkBody() }] });
    const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    const broken = new LucairnNowAssistAdapter({
        config: { resolve: () => { throw new Error('property store offline'); }, validate: () => [] },
        evidence: { write: () => ({ stored: true, sysId: 'x', error: '' }), recordSeal: () => ({}) },
        sha256: LucairnSha256,
        makeClient: () => { throw new Error('unreachable'); },
        guid: () => 'corr_synthetic1',
        now: () => 1,
        log: () => {}
    });

    let sealRes;
    assert.doesNotThrow(() => {
        sealRes = broken.seal({ protectResult: pr, responseText: 'a summary' });
    });
    assert.strictEqual(sealRes.sealed, false);
    assert.strictEqual(sealRes.error.code, LucairnNowAssistAdapter.ERROR.PLATFORM);
});

/* ---- the covered path still tells the truth about its own audit row ------ */

test('a manifest with the wrong inner shapes cannot fail an otherwise-good run', () => {
    // The manifest is diagnostic. A string where an array belongs used to throw
    // inside the evidence write, which lost the audit row for a run that was
    // fine — a malformed manifest must degrade the diagnostics, not the run.
    const h = harness({
        scripts: [{
            status: 200,
            body: JSON.stringify({
                sanitized_text: SANITIZED,
                placeholder_map_id: 'pmap_x',
                cert_id_partial: 'cert_partial_x',
                expires_at: 'z',
                manifest: { redaction_count: 'lots', layers_active: 'regex_pii' }
            })
        }]
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, true);
    assert.strictEqual(res.coverage, 'covered');
    assert.strictEqual(res.evidenceStored, true);
    assert.strictEqual(h.evidenceTable.rows[0].redaction_total, 0);
    assert.strictEqual(h.evidenceTable.rows[0].layers_active, '');
});

test('a covered run whose evidence row failed to store says so, and stays allowed', () => {
    const h = harness({
        scripts: [{ status: 200, body: sanitizeOkBody() }],
        evidenceInsertFails: true
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    // The content WAS protected, so blocking here would turn a lost audit row
    // into an outage on a run that was fine.
    assert.strictEqual(res.allowed, true);
    assert.strictEqual(res.coverage, 'covered');
    assert.strictEqual(res.evidenceStored, false);
    assert.strictEqual(res.evidenceId, '');
});

/* ---- round-2 gate findings ---------------------------------------------- */

test('astra-B1: an insert into a table that cannot hold the audit fields is NOT stored', () => {
    // A partially imported table — system columns present, application columns
    // missing — accepts the insert and discards every setValue() naming a field
    // it does not have. The old code read the returned sys_id as proof of an
    // audit record, so a content-less row authorised a fail-open run as
    // "audited".
    const h = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        evidenceMissingFields: ['fail_open_override'],
        scripts: [{ transportError: 'connection refused' }]
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, false);
    assert.strictEqual(res.error.code, 'lucairn_uncovered_run_unauditable');
    assert.strictEqual(res.textForSkill, '');
    // And no row pretends otherwise: the same schema failure stops the blocked
    // insert too, which is the safe end of a broken evidence table.
    assert.strictEqual(res.evidenceStored, false);
    assert.ok(h.logs.some((l) => l.includes('missing field "fail_open_override"')), h.logs.join('|'));
});

test('astra-B1: every required audit field is load-bearing, one at a time', () => {
    for (const field of LucairnEvidence.REQUIRED_FIELDS) {
        const h = harness({
            policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
            evidenceMissingFields: [field],
            scripts: [{ transportError: 'connection refused' }]
        });
        const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
        assert.strictEqual(res.allowed, false, `a table missing "${field}" must not authorise a fail-open run`);
    }
});

test('astra-B1: a covered run over an unusable evidence table reports evidenceStored:false', () => {
    const h = harness({
        evidenceMissingFields: ['correlation_id'],
        scripts: [{ status: 200, body: sanitizeOkBody() }]
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    // The content really was sanitized, so the run proceeds — but nothing
    // records it, and that is stated rather than implied.
    assert.strictEqual(res.allowed, true);
    assert.strictEqual(res.coverage, 'covered');
    assert.strictEqual(res.evidenceStored, false);
    assert.strictEqual(res.evidenceId, '');
});

test('N-3: a covered run with no evidence row cannot be sealed', () => {
    const h = harness({
        scripts: [{ status: 200, body: sanitizeOkBody() }, { status: 200, body: sealOkBody() }],
        evidenceInsertFails: true
    });
    const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    assert.strictEqual(pr.allowed, true);
    assert.strictEqual(pr.evidenceStored, false);

    const sealRes = h.adapter.seal({ protectResult: pr, responseText: 'a summary' });

    assert.strictEqual(sealRes.sealed, false);
    assert.strictEqual(sealRes.error.code, 'lucairn_evidence_row_missing');
    assert.strictEqual(sealRes.certId, '');
    // And the refusal is real, not cosmetic: no seal call was made at all, so
    // no cert_id_partial was consumed on a run nothing records.
    assert.strictEqual(h.messages.length, 1);
});

test('N-3: a covered run WITH an evidence row still seals normally', () => {
    const h = harness({
        scripts: [{ status: 200, body: sanitizeOkBody() }, { status: 200, body: sealOkBody() }]
    });
    const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    const sealRes = h.adapter.seal({ protectResult: pr, responseText: 'a summary' });

    assert.strictEqual(sealRes.sealed, true);
    assert.strictEqual(h.messages.length, 2);
});

test('a silent update() failure is reported, not read as a recorded seal', () => {
    const h = harness({
        scripts: [{ status: 200, body: sanitizeOkBody() }, { status: 200, body: sealOkBody() }],
        evidenceUpdateFails: true
    });
    const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    h.adapter.seal({ protectResult: pr, responseText: 'a summary' });

    // The row never took the certificate...
    assert.strictEqual(h.evidenceTable.rows[0].seal_outcome, 'not_attempted');
    // ...and that is said out loud rather than left to look like "nobody sealed".
    assert.ok(h.logs.some((l) => l.includes('could not be recorded on evidence row')), h.logs.join('|'));
});

test('a failed seal whose recording also fails does not pass unremarked', () => {
    const h = harness({
        scripts: [
            { status: 200, body: sanitizeOkBody() },
            { status: 503, body: JSON.stringify({ error: 'cert_signing_unavailable' }) }
        ],
        evidenceUpdateFails: true
    });
    const pr = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });
    const sealRes = h.adapter.seal({ protectResult: pr, responseText: 'a summary' });

    assert.strictEqual(sealRes.sealed, false);
    assert.ok(h.logs.some((l) => l.includes('seal failure for skill')), h.logs.join('|'));
});

test('a throwing logger cannot turn one decided run into two evidence rows', () => {
    // Round-2 advisory fold-in. gs.warn() raising on the fail-open path used to
    // unwind into protect()'s outer catch AFTER the uncovered_run row had
    // landed: one run, two rows, and different correlation ids on them.
    const h = harness({
        policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
        scripts: [{ transportError: 'connection refused' }],
        logThrows: true
    });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, true);
    assert.strictEqual(res.coverage, 'uncovered');
    assert.strictEqual(h.evidenceTable.rows.length, 1);
    assert.strictEqual(h.evidenceTable.rows[0].outcome, 'uncovered_run');
    assert.strictEqual(h.evidenceTable.rows[0].correlation_id, 'corr_synthetic1');
});

test('a platform throw is correlated with the id the run actually used', () => {
    // The caller passed no correlationId, so protect() generated one. A blocked
    // row written from `args` alone carried an empty id and could not be joined
    // to anything.
    const h = harness({ getPropertyThrows: 'boom' });
    const res = h.adapter.protect({ skill: SKILL, text: INCIDENT.description });

    assert.strictEqual(res.allowed, false);
    assert.strictEqual(res.correlationId, 'corr_synthetic1');
    assert.strictEqual(h.evidenceTable.rows[0].correlation_id, 'corr_synthetic1');
});
