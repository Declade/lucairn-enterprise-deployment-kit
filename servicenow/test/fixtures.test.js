'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const fixtures = require('../fixtures/synthetic-incidents.json');

const SRC_DIR = path.join(__dirname, '..', 'src');
const ROOT = path.join(__dirname, '..');

function walk(dir, out) {
    out = out || [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            walk(p, out);
        } else {
            out.push(p);
        }
    }
    return out;
}

test('every fixture email and domain is a reserved .test domain', () => {
    // RFC 2606 reserves .test; a fixture that ever resolved would be a way for
    // synthetic data to leave the instance.
    const blob = JSON.stringify(fixtures);
    const emails = blob.match(/[\w.+-]+@[\w.-]+/g) || [];
    assert.ok(emails.length > 0, 'expected some fixture emails');
    for (const e of emails) {
        assert.match(e, /\.test$/, `fixture email is not on a reserved domain: ${e}`);
    }
});

test('fixture incident numbers sit in a synthetic range and sys_ids are 32 hex', () => {
    for (const inc of fixtures.incidents) {
        assert.match(inc.number, /^INC009\d{4}$/, inc.number);
        assert.match(inc.sys_id, /^[0-9a-f]{32}$/, inc.sys_id);
    }
});

test('fixtures cover the cases the adapter has to survive', () => {
    const ids = fixtures.incidents.map((i) => i.id);
    for (const needed of ['fixture-basic-contact', 'fixture-no-obvious-pii', 'fixture-multibyte']) {
        assert.ok(ids.includes(needed), `missing fixture: ${needed}`);
    }
});

test('no source or fixture file names this application a "gateway"', () => {
    // ServiceNow ships its own product with that name for the opposite
    // direction of travel. Every surface in this application says
    // "Lucairn service" instead.
    const files = walk(SRC_DIR)
        .concat([path.join(ROOT, 'fixtures', 'synthetic-incidents.json')]);
    for (const f of files) {
        const text = fs.readFileSync(f, 'utf8');
        assert.ok(
            !/gateway/i.test(text),
            `"gateway" appears in ${path.relative(ROOT, f)} — use "Lucairn service"`
        );
    }
});

test('no source file carries a live-looking API key', () => {
    for (const f of walk(SRC_DIR)) {
        const text = fs.readFileSync(f, 'utf8');
        const hits = text.match(/lcr_live_[A-Za-z0-9_-]+/g) || [];
        for (const hit of hits) {
            assert.ok(
                /synthetic|example|placeholder|redacted/i.test(hit),
                `possible real key in ${path.relative(ROOT, f)}: ${hit}`
            );
        }
    }
});
