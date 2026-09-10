'use strict';

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');

require('./mocks/servicenow');
const LucairnSha256 = require('../src/script_includes/LucairnSha256');

const fixtures = require('../fixtures/synthetic-incidents.json');

/*
 * The certificate binds to these digests, so a wrong hash is not a cosmetic
 * bug — it produces a certificate that references bytes nobody sent. Vectors
 * come from FIPS 180-4 plus a differential check against Node's own crypto.
 */

test('FIPS 180-4 published vectors', () => {
    assert.strictEqual(
        LucairnSha256.hexOfUtf8(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    );
    assert.strictEqual(
        LucairnSha256.hexOfUtf8('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    );
    assert.strictEqual(
        LucairnSha256.hexOfUtf8('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1'
    );
});

test('one-million-a vector (multi-block, length > 2^16 bits)', () => {
    const oneMillionA = 'a'.repeat(1000000);
    assert.strictEqual(
        LucairnSha256.hexOfUtf8(oneMillionA),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0'
    );
});

test('differential check against node crypto across lengths and block boundaries', () => {
    const lengths = [0, 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 1000];
    for (const n of lengths) {
        const s = 'Lucairn synthetic payload '.repeat(200).slice(0, n);
        const expected = crypto.createHash('sha256').update(s, 'utf8').digest('hex');
        assert.strictEqual(LucairnSha256.hexOfUtf8(s), expected, `length ${n}`);
    }
});

test('multibyte content hashes the UTF-8 bytes, not the UTF-16 code units', () => {
    const incident = fixtures.incidents.find((i) => i.id === 'fixture-multibyte');
    const expected = crypto.createHash('sha256').update(incident.description, 'utf8').digest('hex');
    assert.strictEqual(LucairnSha256.hexOfUtf8(incident.description), expected);
});

test('astral-plane characters (surrogate pairs) encode as 4-byte UTF-8', () => {
    const s = 'ticket \u{1F512} sealed';
    const expected = crypto.createHash('sha256').update(s, 'utf8').digest('hex');
    assert.strictEqual(LucairnSha256.hexOfUtf8(s), expected);
    assert.deepStrictEqual(LucairnSha256._utf8Bytes('\u{1F512}'), [0xf0, 0x9f, 0x94, 0x92]);
});

test('a lone surrogate becomes U+FFFD instead of throwing', () => {
    // Total function: an adapter must never fail closed because of an encoding
    // edge case it could have handled deterministically.
    assert.deepStrictEqual(LucairnSha256._utf8Bytes('\uD800'), [0xef, 0xbf, 0xbd]);
    assert.doesNotThrow(() => LucairnSha256.hexOfUtf8('a\uDC00b'));
});

test('wire shape matches the sha256:<64 hex> pattern the service requires', () => {
    const wire = LucairnSha256.wireOfUtf8('anything');
    assert.match(wire, /^sha256:[0-9a-f]{64}$/);
});
