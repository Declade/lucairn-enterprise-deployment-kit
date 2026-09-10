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

/**
 * Every file the naming guard scans. Defined once so the guard and the test
 * that checks the guard's coverage cannot drift apart — the round-1 gate found
 * the guard reading src/ only while the README, the record specifications and
 * the runbook went unchecked (D-4).
 *
 * @returns {string[]} absolute paths
 */
function guardedFiles() {
    return walk(SRC_DIR).concat([
        path.join(ROOT, 'fixtures', 'synthetic-incidents.json'),
        path.join(ROOT, 'README.md'),
        path.join(ROOT, 'run-tests.sh')
    ]);
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

test('no shipped file names this application a "gateway"', () => {
    // ServiceNow ships its own product with that name for the opposite
    // direction of travel. Every surface in this application says
    // "Lucairn service" instead.
    //
    // The guard is a blunt substring check on purpose, and it covers the DOCS
    // as well as the code — the round-1 gate found it scanning src/ only, which
    // left the README, the record specifications and the runbook (the surfaces a
    // customer's administrator actually reads) unguarded. D-4.
    //
    // Consequence worth knowing: an upstream file path containing the segment
    // trips this too. Cite upstream handlers by repository plus file and line
    // (`dual-sandbox-architecture sensitive_mode.go:1541`) rather than by full
    // path — still greppable, and it keeps the guard blunt.
    for (const f of guardedFiles()) {
        const text = fs.readFileSync(f, 'utf8');
        assert.ok(
            !/gateway/i.test(text),
            `"gateway" appears in ${path.relative(ROOT, f)} — use "Lucairn service"`
        );
    }
});

test('the naming guard actually scans the docs, not just the code', () => {
    // A guard whose file list quietly stopped matching reality is worse than no
    // guard, so the LIST ITSELF is asserted — not merely that the files exist.
    // Shrinking guardedFiles() back to src/ only, which is what the round-1
    // gate found (D-4), fails here rather than passing silently.
    const scanned = guardedFiles().map((f) => path.relative(ROOT, f));

    for (const required of [
        'README.md',                                      // the doc a customer's admin reads
        'run-tests.sh',
        'fixtures/synthetic-incidents.json',
        'src/records/tables.md',
        'src/records/properties.md',
        'src/records/connection-and-credential-alias.md',
        'src/hooks/genai-preprocessor.js',
        'src/script_includes/LucairnNowAssistAdapter.js'
    ]) {
        assert.ok(scanned.includes(required),
            `the naming guard no longer scans ${required} — coverage shrank. Scanned: ${scanned.join(', ')}`);
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
