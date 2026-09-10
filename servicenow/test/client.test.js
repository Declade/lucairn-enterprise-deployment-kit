'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { fakeRestMessage } = require('./mocks/servicenow');
const LucairnClient = require('../src/script_includes/LucairnClient');

const REST_CFG = {
    transport: 'rest_message',
    restMessage: 'Lucairn Service',
    fnSanitize: 'sanitizeOnly',
    fnSeal: 'sealCert',
    timeoutMs: 12000,
    clientId: 'lucairn-for-now-assist',
    vendor: 'openai'
};

const ENDPOINT_CFG = Object.assign({}, REST_CFG, {
    transport: 'endpoint',
    baseUrl: 'https://lucairn.example.test',
    apiKey: 'lcr_live_synthetic_key'
});

const OK_SANITIZE_BODY = JSON.stringify({
    sanitized_text: 'Reported by [PERSON_1] ([EMAIL_1], [PHONE_1]).',
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

function clientWith(cfg, script, capture) {
    const msg = fakeRestMessage(script);
    if (capture) { capture.msg = msg; }
    let clock = 1000;
    return new LucairnClient(cfg, {
        newNamedMessage: (name, fn) => {
            msg.calls.constructedWith = [name, fn];
            return msg;
        },
        newMessage: () => msg,
        now: () => (clock += 25),
        log: () => {}
    });
}

/* ---- happy path --------------------------------------------------------- */

test('sanitize-only sends the documented request shape on the named REST message', () => {
    const cap = {};
    const client = clientWith(REST_CFG, { status: 200, body: OK_SANITIZE_BODY }, cap);
    const res = client.sanitizeOnly('Reported by Brannagh Oduya-Kestrel.');

    assert.strictEqual(res.ok, true);
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.failureClass, 'none');
    assert.ok(res.durationMs > 0);

    assert.deepStrictEqual(cap.msg.calls.constructedWith, ['Lucairn Service', 'sanitizeOnly']);
    assert.deepStrictEqual(JSON.parse(cap.msg.calls.body), {
        text: 'Reported by Brannagh Oduya-Kestrel.',
        client_id: 'lucairn-for-now-assist'
    });
    assert.strictEqual(cap.msg.calls.headers['Content-Type'], 'application/json');
    assert.strictEqual(cap.msg.calls.headers.Accept, 'application/json');
    assert.strictEqual(cap.msg.calls.timeout, 12000);
    // The Connection & Credential alias supplies auth in this mode — the script
    // must not set an Authorization header itself.
    assert.strictEqual(cap.msg.calls.headers.Authorization, undefined);
    assert.strictEqual(res.body.placeholder_map_id, 'pmap_synthetic1');
});

test('seal-cert sends the documented request shape including the vendor', () => {
    const cap = {};
    const body = JSON.stringify({
        cert_id: 'cert_synthetic1',
        cert_url: 'https://lucairn.example.test/api/v1/veil/certificate/req_synthetic1',
        cert_tier: 'input-shield'
    });
    const client = clientWith(REST_CFG, { status: 200, body }, cap);
    const res = client.sealCert({
        certIdPartial: 'cert_partial_synthetic1',
        requestContentHash: 'sha256:' + 'a'.repeat(64),
        responseContentHash: 'sha256:' + 'b'.repeat(64),
        toolName: 'ServiceNow Now Assist — Incident summarization'
    });

    assert.strictEqual(res.ok, true);
    assert.deepStrictEqual(cap.msg.calls.constructedWith, ['Lucairn Service', 'sealCert']);
    assert.deepStrictEqual(JSON.parse(cap.msg.calls.body), {
        cert_id_partial: 'cert_partial_synthetic1',
        request_content_hash: 'sha256:' + 'a'.repeat(64),
        response_content_hash: 'sha256:' + 'b'.repeat(64),
        vendor: 'openai',
        tool_name: 'ServiceNow Now Assist — Incident summarization'
    });
    assert.strictEqual(res.body.cert_tier, 'input-shield');
});

test('endpoint mode sets the Bearer header and the full URL', () => {
    const cap = {};
    const client = clientWith(ENDPOINT_CFG, { status: 200, body: OK_SANITIZE_BODY }, cap);
    client.sanitizeOnly('anything');

    assert.strictEqual(cap.msg.calls.method, 'post');
    assert.strictEqual(cap.msg.calls.endpoint, 'https://lucairn.example.test/api/v1/sanitize-only');
    assert.strictEqual(cap.msg.calls.headers.Authorization, 'Bearer lcr_live_synthetic_key');
});

/* ---- failure class 1: connection refused -------------------------------- */

test('connection refused thrown from execute() is a non-ok result, classified', () => {
    const client = clientWith(REST_CFG, {
        throwOnExecute: new Error('org.apache.http.conn.HttpHostConnectException: Connection refused')
    });
    const res = client.sanitizeOnly('anything');

    assert.strictEqual(res.ok, false);
    assert.strictEqual(res.failureClass, 'connection_refused');
    assert.strictEqual(res.status, 0);
    assert.match(res.message, /Connection refused/);
});

test('connection refused surfaced via haveError() is a non-ok result, classified', () => {
    const client = clientWith(REST_CFG, {
        status: 0,
        body: '',
        transportError: 'Connection refused (Connection refused)'
    });
    const res = client.sanitizeOnly('anything');

    assert.strictEqual(res.ok, false);
    assert.strictEqual(res.failureClass, 'connection_refused');
});

test('an unresolvable host is classified as connection_refused', () => {
    const client = clientWith(REST_CFG, {
        throwOnExecute: new Error('java.net.UnknownHostException: lucairn.invalid')
    });
    assert.strictEqual(client.sanitizeOnly('x').failureClass, 'connection_refused');
});

/* ---- failure class 2: timeout ------------------------------------------- */

test('a read timeout thrown from execute() is a non-ok result, classified', () => {
    const client = clientWith(REST_CFG, {
        throwOnExecute: new Error('java.net.SocketTimeoutException: Read timed out')
    });
    const res = client.sanitizeOnly('anything');

    assert.strictEqual(res.ok, false);
    assert.strictEqual(res.failureClass, 'timeout');
});

test('a timeout surfaced via haveError() is a non-ok result, classified', () => {
    const client = clientWith(REST_CFG, {
        status: 0,
        body: '',
        transportError: 'The request timed out after 30000 ms'
    });
    assert.strictEqual(client.sanitizeOnly('x').failureClass, 'timeout');
});

test('timeout wins over connection wording when a message mentions both', () => {
    // A mislabelled timeout is the more confusing evidence row of the two, so
    // the timeout markers are checked first. Either way the run is not ok.
    const client = clientWith(REST_CFG, {
        throwOnExecute: new Error('connection error: read timed out')
    });
    assert.strictEqual(client.sanitizeOnly('x').failureClass, 'timeout');
});

/* ---- other non-success paths -------------------------------------------- */

test('a structured 4xx surfaces the service error code and message', () => {
    const client = clientWith(REST_CFG, {
        status: 401,
        body: JSON.stringify({ error: 'missing_api_key', message: 'No API key was supplied.' })
    });
    const res = client.sanitizeOnly('anything');

    assert.strictEqual(res.ok, false);
    assert.strictEqual(res.failureClass, 'http_error');
    assert.strictEqual(res.status, 401);
    assert.match(res.message, /missing_api_key/);
});

test('a 200 with a non-JSON body is a contract error, not a success', () => {
    const client = clientWith(REST_CFG, { status: 200, body: '<html>proxy error</html>' });
    const res = client.sanitizeOnly('anything');

    assert.strictEqual(res.ok, false);
    assert.strictEqual(res.failureClass, 'contract_error');
});

test('a status of 0 without an error API is still treated as unreachable', () => {
    const client = clientWith(REST_CFG, { status: 0, body: '', omitErrorApi: true });
    const res = client.sanitizeOnly('anything');

    assert.strictEqual(res.ok, false);
    assert.strictEqual(res.failureClass, 'unknown');
});

test('the result never carries the api key or the submitted text', () => {
    const client = clientWith(ENDPOINT_CFG, {
        throwOnExecute: new Error('Connection refused')
    });
    const res = client.sanitizeOnly('Brannagh Oduya-Kestrel, brannagh@northmarrow-example.test');
    const serialised = JSON.stringify(res);

    assert.ok(!serialised.includes('lcr_live_'), serialised);
    assert.ok(!serialised.includes('Brannagh'), serialised);
    assert.ok(!serialised.includes('northmarrow-example.test'), serialised);
});

test('the client never throws, whatever execute() does', () => {
    const client = clientWith(REST_CFG, { throwOnExecute: new Error('kaboom') });
    assert.doesNotThrow(() => client.sanitizeOnly('x'));
    assert.doesNotThrow(() => client.sealCert({ certIdPartial: 'p' }));
});
