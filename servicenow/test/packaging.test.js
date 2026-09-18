'use strict';

/*
 * The packaging artefacts, checked against reality.
 *
 * An inventory nobody checks is a document that used to be true. These tests
 * make the manifest load-bearing: the four places that independently knew what
 * this application is made of — the source tree, LucairnConfig, the record
 * specifications, and the build steps — now have to agree, and a disagreement
 * is a failing test rather than a support call on an instance.
 *
 * What these tests do NOT do is validate anything ServiceNow does. They are an
 * inventory-consistency check over source-form artefacts.
 * **Instance validation pending.**
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

require('./mocks/servicenow');
const LucairnConfig = require('../src/script_includes/LucairnConfig');
const LucairnEvidence = require('../src/script_includes/LucairnEvidence');
const LucairnClient = require('../src/script_includes/LucairnClient');

const ROOT = path.join(__dirname, '..');
const MANIFEST = JSON.parse(fs.readFileSync(path.join(ROOT, 'app', 'app-manifest.json'), 'utf8'));
const RELEASE = JSON.parse(fs.readFileSync(path.join(ROOT, 'app', 'release.json'), 'utf8'));
const PROPERTIES_MD = fs.readFileSync(path.join(ROOT, 'src', 'records', 'properties.md'), 'utf8');

const byKind = (kind) => MANIFEST.artifacts.filter((a) => a.kind === kind);

test('PACKAGING every Script Include on disk is in the manifest, and every listed source exists', () => {
    const dir = path.join(ROOT, 'src', 'script_includes');
    const onDisk = fs.readdirSync(dir).filter((f) => f.endsWith('.js')).sort();
    const listed = byKind('script_include')
        .map((a) => path.basename(a.source))
        .sort();

    assert.deepStrictEqual(listed, onDisk,
        'the manifest and src/script_includes/ disagree about what this application is made of');

    for (const a of MANIFEST.artifacts) {
        if (!a.source) { continue; }
        assert.ok(fs.existsSync(path.join(ROOT, a.source)),
            `${a.kind} "${a.name}" names a source that does not exist: ${a.source}`);
    }
});

test('PACKAGING the property set agrees three ways — manifest, LucairnConfig, records', () => {
    // A property documented but never read is a lie to an administrator; one
    // read but never documented is a setting nobody knows to set. Both used to
    // be possible without anything noticing.
    const inManifest = byKind('property').map((a) => a.name).sort();
    const inCode = Object.keys(LucairnConfig.PROP)
        .map((k) => LucairnConfig.PROP[k]).sort();
    const inDocs = Array.from(new Set(
        (PROPERTIES_MD.match(/lucairn\.now_assist\.[a-z_]+/g) || []))).sort();

    assert.deepStrictEqual(inManifest, inCode,
        'the manifest and LucairnConfig.PROP disagree about the property set');
    assert.deepStrictEqual(inManifest, inDocs,
        'the manifest and src/records/properties.md disagree about the property set');
});

test('PACKAGING the vendor property is recorded as required with no default', () => {
    const vendor = byKind('property').find((a) => a.name === LucairnConfig.PROP.VENDOR);
    assert.ok(vendor, 'the vendor property is not in the manifest');
    assert.strictEqual(vendor.required, true);
    assert.strictEqual(vendor.default, null,
        'a default for the vendor property would put an invented provenance value on every certificate');
});

test('PACKAGING the table names agree with the code that declares them', () => {
    const inManifest = byKind('table').map((a) => a.name).sort();
    assert.deepStrictEqual(inManifest,
        [LucairnConfig.TABLE_SKILL_POLICY, LucairnEvidence.TABLE].sort());

    for (const t of byKind('table')) {
        assert.ok(t.declared_by, `${t.name}: the manifest does not say which constant declares it`);
    }
});

test('PACKAGING every scoped name carries the placeholder prefix, and every substitution site exists', () => {
    const prefix = MANIFEST.scope.placeholder_prefix;
    assert.strictEqual(MANIFEST.scope.assigned_on_instance, null,
        'a real scope prefix is in the manifest — it belongs in the instance build record, not in source');

    for (const a of MANIFEST.artifacts) {
        if (a.kind !== 'table' && a.kind !== 'role') { continue; }
        assert.ok(a.name.indexOf(prefix) === 0,
            `${a.kind} "${a.name}" is scoped but does not carry the ${prefix} placeholder`);
    }
    for (const site of MANIFEST.scope.substitution_sites) {
        const p = path.join(ROOT, site);
        assert.ok(fs.existsSync(p), `scope substitution site does not exist: ${site}`);
        assert.ok(fs.readFileSync(p, 'utf8').indexOf(prefix) !== -1,
            `${site} is named as a scope substitution site but contains no ${prefix} name`);
    }
});

test('PACKAGING the REST message functions are an EXACT set, with path and property binding', () => {
    // astra counterexample: the old version iterated the functions that were
    // STILL LISTED, so deleting both artefacts left 9/9 green — the check
    // validated whatever survived. An inventory you can empty in silence is not
    // an inventory. The required set is frozen here, with the path each one
    // posts to and the property that must name it.
    const defaults = LucairnConfig.DEFAULTS;
    const REQUIRED_FUNCTIONS = {
        [defaults.fnSanitize]: {
            path: LucairnClient.PATH_SANITIZE,
            property: LucairnConfig.PROP.FN_SANITIZE
        },
        [defaults.fnSeal]: {
            path: LucairnClient.PATH_SEAL,
            property: LucairnConfig.PROP.FN_SEAL
        }
    };

    const listed = byKind('rest_message_function');
    assert.deepStrictEqual(
        listed.map((f) => f.name).sort(),
        Object.keys(REQUIRED_FUNCTIONS).sort(),
        'the manifest\'s REST functions and the set this application actually calls disagree');

    for (const fn of listed) {
        const want = REQUIRED_FUNCTIONS[fn.name];
        // The property default and the record name are set in two different
        // places by two different people on an instance; a mismatch there reads
        // as a missing function rather than as a typo.
        assert.strictEqual(fn.path, want.path,
            `REST function "${fn.name}" posts to ${fn.path}, but the client calls ${want.path}`);
        assert.strictEqual(fn.must_match_property, want.property,
            `REST function "${fn.name}" names "${fn.must_match_property}" as its source of truth; the client reads ${want.property}`);
    }

    const messages = byKind('rest_message');
    assert.strictEqual(messages.length, 1, 'there must be exactly one REST Message record listed');
    assert.strictEqual(messages[0].name, defaults.restMessage,
        'the REST Message name does not match LucairnConfig.DEFAULTS.restMessage');
});

test('PACKAGING no installable artefact is claimed, and the update set is explicitly absent', () => {
    // The one artefact type whose failure mode is SILENT. A hand-written update
    // set that names one field wrong imports wrong and says nothing.
    const absent = MANIFEST.not_included.map((n) => n.artifact).join(' ');
    assert.ok(/update_set|update set/i.test(absent),
        'the manifest no longer states that the update set is deliberately absent');
    for (const n of MANIFEST.not_included) {
        assert.ok(typeof n.why === 'string' && n.why.length > 40,
            `"${n.artifact}" is listed as absent with no reason — an unexplained absence becomes an oversight`);
    }
    const xml = fs.readdirSync(ROOT).filter((f) => /\.xml$/i.test(f));
    assert.deepStrictEqual(xml, [],
        `an update-set XML appeared in servicenow/ (${xml.join(', ')}) — it may only be EXPORTED from an instance build, with the instance family and patch level in the commit message`);
});

test('PACKAGING the intended target release is pinned AND sourced', () => {
    // A release candidate has to be built FOR something. The first version left
    // this null, which is not caution — it is an unanswered question wearing
    // caution's clothes, and it fails the acceptance criterion this work is
    // against. So the intended family is REQUIRED here, and required to be
    // sourced: an unsourced release number becomes a fact three documents later.
    const target = RELEASE.target_platform;

    assert.ok(typeof target.intended_release_family === 'string' &&
        target.intended_release_family.length > 0,
        'no intended target release family — a release candidate must say what it is built for');

    assert.ok(Array.isArray(target.intended_family_source) && target.intended_family_source.length > 0,
        'the intended target release is unsourced');

    // Every source must be reachable evidence: a release-scoped documentation
    // URL, or a cited line in the workspace record. Not an assertion.
    for (const src of target.intended_family_source) {
        assert.ok(/^https:\/\/www\.servicenow\.com\/docs\//.test(src) || /\.md:\d+/.test(src),
            `intended-target source is neither a documentation URL nor a cited line: ${src}`);
    }

    // And the source must actually NAME the family it is offered as evidence
    // for, case-insensitively. A citation that does not mention the thing it
    // cites is decoration.
    const family = target.intended_release_family.toLowerCase();
    assert.ok(target.intended_family_source.some((s) => s.toLowerCase().includes(family)),
        `none of the intended-target sources mentions "${target.intended_release_family}"`);

    assert.ok(typeof target.intended_family_basis === 'string' && target.intended_family_basis.length > 60,
        'the intended target must say on what basis it was chosen');

    // The boundary that keeps a build target from reading as a tested one.
    assert.ok(Array.isArray(target.intended_family_is_not) && target.intended_family_is_not.length >= 3,
        'the intended target must enumerate what it is NOT — that list is the whole difference between a build target and a claim');
});

test('PACKAGING an intended target is never mistaken for an observed one', () => {
    const target = RELEASE.target_platform;

    assert.strictEqual(RELEASE.instance_validation, 'pending');
    assert.strictEqual(target.observed_validation, 'pending');
    assert.strictEqual(target.observed_on.release_family, null,
        'release.json names a family something RAN on; that needs a gate record, and this test updated with it');
    assert.strictEqual(target.observed_on.patch_level, null);
    assert.strictEqual(RELEASE.built_and_tested_on, null,
        'release.json claims an instance build; that needs a gate record, and this test updated with it');
    assert.deepStrictEqual(RELEASE.gate_records, []);
    assert.ok(/NO OBSERVED VALIDATION/i.test(target.status),
        'the status line must carry the absence of observed validation, next to the pinned intent');

    // Availability floors stay a THIRD thing: sourced, and labelled as floors.
    for (const floor of target.documented_availability_floors) {
        assert.ok(floor.source, `${floor.mechanism}: an unsourced release number becomes a fact three documents later`);
        assert.ok(/FLOOR, not a target/i.test(floor.note || ''),
            `${floor.mechanism}: the note must distinguish an availability floor from a tested target`);
    }
});

test('PACKAGING every pinned service citation carries the commit it was verified at', () => {
    const svc = RELEASE.authoritative_contract_references.lucairn_service;
    assert.ok(/^[0-9a-f]{7,40}$/.test(svc.verified_at_commit),
        'the Lucairn service citations name no commit — a line number without one is a coincidence');
    assert.ok(svc.citations.length > 0);
    for (const c of svc.citations) {
        assert.ok(/^[a-z_]+\.go:\d+(-\d+)?$/.test(c.ref), `malformed citation: ${c.ref}`);
        assert.ok(typeof c.pins === 'string' && c.pins.length > 10,
            `${c.ref}: a citation that does not say what it pins is decoration`);
    }

    const docs = RELEASE.authoritative_contract_references.servicenow_documentation;
    for (const c of docs.citations) {
        assert.ok(/^https:\/\/www\.servicenow\.com\/docs\//.test(c.url), `not a documentation URL: ${c.url}`);
        assert.ok(c.release_scope, `${c.url}: no release scope recorded — version-scoped and unversioned pages are different evidence`);
    }
});
