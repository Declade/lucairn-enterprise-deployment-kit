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
        cert_url: 'https://lucairn.example.test/verify?id=req_synthetic1',
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
    assert.strictEqual(res.stage, 'request_execute');
    // The diagnostic is CONSTRUCTED from this file's own literals. The Java
    // exception text that produced the label is not part of it — assert on the
    // canonical reason, and assert the upstream text is absent.
    assert.match(res.message, /reason=the connection was refused/);
    assert.ok(!res.message.includes('HttpHostConnectException'), res.message);
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

/* ---- round-1 gate finding 4: a failed diagnostic is itself a failure ----- */

test('haveError() true + a throwing getErrorMessage() stays a FAILURE, not a success', () => {
    // The old code reset hadTransportError inside the catch, so a 200 body
    // arriving alongside a known transport failure was returned as ok.
    const client = clientWith(REST_CFG, {
        status: 200,
        body: OK_SANITIZE_BODY,
        errorMessageThrows: new Error('getErrorMessage is not a function on this release')
    });
    const res = client.sanitizeOnly('anything');

    assert.strictEqual(res.ok, false);
    assert.strictEqual(res.stage, 'transport');
    // We know the transport failed; we cannot say why, so the class degrades
    // rather than the verdict.
    assert.strictEqual(res.failureClass, 'unknown');
});

test('a throwing haveError() fails the call closed', () => {
    const client = clientWith(REST_CFG, {
        status: 200,
        body: OK_SANITIZE_BODY,
        haveErrorThrows: new Error('haveError blew up')
    });
    assert.strictEqual(client.sanitizeOnly('anything').ok, false);
});

test('a throwing getBody() is a failure, and no exception text is carried', () => {
    const client = clientWith(REST_CFG, {
        status: 200,
        getBodyThrows: new Error('stream closed while reading Brannagh Oduya-Kestrel')
    });
    const res = client.sanitizeOnly('anything');

    assert.strictEqual(res.ok, false);
    assert.strictEqual(res.stage, 'response_read');
    assert.ok(!JSON.stringify(res).includes('Brannagh'), res.message);
});

/* ---- round-1 gate finding 5: diagnostics are constructed, not forwarded --- */

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

test('CANARY: an exception carrying content and a credential leaks neither', () => {
    // The old test threw a bare 'Connection refused' — an exception with
    // nothing in it to leak, so it could not fail. This one is loaded.
    const CONTENT_CANARY = 'Brannagh Oduya-Kestrel, brannagh.oduya-kestrel@northmarrow-example.test';
    const KEY_CANARY = 'lcr_live_synthetic_canary_0000';
    const client = clientWith(REST_CFG, {
        throwOnExecute: new Error(
            `POST failed: Connection refused; request body was {"text":"${CONTENT_CANARY}"}; ` +
            `headers: Authorization: Bearer ${KEY_CANARY}`
        )
    });
    const res = client.sanitizeOnly(CONTENT_CANARY);
    const serialised = JSON.stringify(res);

    assert.ok(!serialised.includes('Brannagh'), serialised);
    assert.ok(!serialised.includes('northmarrow-example.test'), serialised);
    assert.ok(!serialised.includes('lcr_live_'), serialised);
    assert.ok(!serialised.includes('Bearer'), serialised);
    // The classification still happened — the text was read, then discarded.
    assert.strictEqual(res.failureClass, 'connection_refused');
});

test('CANARY: an upstream error body cannot push its message into the diagnostic', () => {
    const client = clientWith(REST_CFG, {
        status: 400,
        body: JSON.stringify({
            error: 'invalid_field',
            message: 'field text rejected: "Brannagh Oduya-Kestrel" with key lcr_live_synthetic_leak_canary'
        })
    });
    const res = client.sanitizeOnly('anything');
    const serialised = JSON.stringify(res.message) + JSON.stringify(res.apiCode);

    assert.strictEqual(res.ok, false);
    // The error CODE is allow-listed, so it survives; the message never does.
    assert.strictEqual(res.apiCode, 'invalid_field');
    assert.ok(!serialised.includes('Brannagh'), serialised);
    assert.ok(!serialised.includes('lcr_live_'), serialised);
});

test('an error code outside the allow-list is replaced, not truncated', () => {
    const client = clientWith(REST_CFG, {
        status: 500,
        body: JSON.stringify({ error: 'Brannagh Oduya-Kestrel', message: 'x' })
    });
    const res = client.sanitizeOnly('anything');

    assert.strictEqual(res.apiCode, 'unrecognised_error_code');
    assert.ok(!res.message.includes('Brannagh'), res.message);
});

test('every diagnostic this client produces stays inside the length cap', () => {
    const long = 'x'.repeat(50000);
    const client = clientWith(REST_CFG, { throwOnExecute: new Error(long) });
    const res = client.sanitizeOnly('anything');

    assert.ok(res.message.length <= LucairnClient.MAX_DIAGNOSTIC_CHARS,
        `diagnostic was ${res.message.length} chars`);
});

/* ---- round-1 gate fold-in L-1: the service caps BYTES, not characters ---- */

test('tool_name is capped on UTF-8 bytes, and never splits a character', () => {
    const cap = {};
    const client = clientWith(REST_CFG, { status: 200, body: '{}' }, cap);
    // 200 × 'ä' is 200 UTF-16 units and 400 UTF-8 bytes. The service rejects
    // anything over 256 bytes with HTTP 400, so the old substring(0, 256) cap
    // shipped a request that could only fail.
    client.sealCert({ certIdPartial: 'p', toolName: 'ä'.repeat(200) });

    const sent = JSON.parse(cap.msg.calls.body);
    assert.strictEqual(LucairnClient.utf8ByteLength(sent.tool_name), 256);
    assert.strictEqual(sent.tool_name.length, 128); // whole characters only
});

test('tool_name capping keeps surrogate pairs intact at the boundary', () => {
    const cap = {};
    const client = clientWith(REST_CFG, { status: 200, body: '{}' }, cap);
    // 63 ASCII bytes then astral characters: the cap lands mid-pair unless the
    // pair is treated as one code point.
    const name = 'a'.repeat(63) + '\u{1F600}'.repeat(100);
    client.sealCert({ certIdPartial: 'p', toolName: name });

    const sent = JSON.parse(cap.msg.calls.body);
    assert.ok(LucairnClient.utf8ByteLength(sent.tool_name) <= 256);
    assert.strictEqual(LucairnClient.utf8ByteLength(sent.tool_name), 63 + 48 * 4);
    // A lone surrogate would round-trip through JSON as U+FFFD.
    assert.ok(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])/.test(sent.tool_name));
    assert.ok(!/(^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(sent.tool_name));
});

test('utf8ByteLength boundary cases', () => {
    assert.strictEqual(LucairnClient.utf8ByteLength(''), 0);
    assert.strictEqual(LucairnClient.utf8ByteLength('a'), 1);
    assert.strictEqual(LucairnClient.utf8ByteLength('ä'), 2);
    assert.strictEqual(LucairnClient.utf8ByteLength('€'), 3);
    assert.strictEqual(LucairnClient.utf8ByteLength('\u{1F600}'), 4);
    assert.strictEqual(LucairnClient.capUtf8Bytes('äää', 5), 'ää');
    assert.strictEqual(LucairnClient.capUtf8Bytes('äää', 6), 'äää');
    assert.strictEqual(LucairnClient.capUtf8Bytes('\u{1F600}', 3), '');
    assert.strictEqual(LucairnClient.capUtf8Bytes('\u{1F600}', 4), '\u{1F600}');
});

test('the client never throws, whatever execute() does', () => {
    const client = clientWith(REST_CFG, { throwOnExecute: new Error('kaboom') });
    assert.doesNotThrow(() => client.sanitizeOnly('x'));
    assert.doesNotThrow(() => client.sealCert({ certIdPartial: 'p' }));
});
