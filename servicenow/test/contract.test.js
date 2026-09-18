'use strict';

/*
 * THE CONTRACT TESTS.
 *
 * Every platform behaviour this application depends on is a HYPOTHESIS until an
 * instance settles it. The previous state of that fact was prose: the hook's
 * header enumerates four unproven items, the README's Leg 6 enumerates the
 * observables, and nothing executable connected the two. Prose does not go red.
 *
 * This file makes each hypothesis an executable row:
 *
 *   1. It is REGISTERED in ../contracts/instance-contracts.json with the
 *      runbook leg and probe that will settle it, and it may not leave
 *      `instance-pending` without an instance record. Editing a status is a
 *      failing test, not a commit.
 *   2. Where a part of it IS locally settleable — what the hook does with the
 *      binding it was given, rather than what the binding is called — that part
 *      is expressed against a DOCUMENTED-SHAPE STUB and pinned here.
 *   3. Where nothing is locally settleable, the row carries no local test and
 *      says why. An empty `expressed_by.tests` is a legitimate answer; an
 *      invented one would not be.
 *
 * WHAT A GREEN RUN OF THIS FILE MEANS: the application behaves as designed IF
 * the registered hypotheses hold. It never says they hold.
 * **Instance validation pending.**
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const { runHookInExtensionPoint, DESTINATIONS } = require('../probes/lib/instance-stub');
const { probes } = require('../probes/probes');
const LucairnConfig = require('../src/script_includes/LucairnConfig');
const LucairnSkillGuard = require('../src/script_includes/LucairnSkillGuard');
const LucairnNowAssistAdapter = require('../src/script_includes/LucairnNowAssistAdapter');

const ROOT = path.join(__dirname, '..');
const REGISTRY = JSON.parse(fs.readFileSync(
    path.join(ROOT, 'contracts', 'instance-contracts.json'), 'utf8'));
const README = fs.readFileSync(path.join(ROOT, 'README.md'), 'utf8');
const HOOK_SOURCE = fs.readFileSync(
    path.join(ROOT, 'src', 'hooks', 'genai-preprocessor.js'), 'utf8');

const RAW = 'Reported by Brannagh Oduya-Kestrel (brannagh.oduya-kestrel@northmarrow-example.test). Tag CAN-DESC-CONTRACT.';
const SANITIZED = 'Reported by [PERSON_1] ([EMAIL_1]). Tag [CANARY_1].';

/* ------------------------------------------------------------------------ *
 * THE FROZEN CLASSIFICATION — the registry does not get to classify itself.
 *
 * Two live counterexamples from the astra gate on this file's first version,
 * and both worked because the guards read the row they were checking:
 *
 *   1. SELF-PROMOTION. The promotion guard skipped any row whose `kind` was not
 *      "platform-hypothesis". So editing H3 to kind "service-contract",
 *      status "locally-pinned", locally_settleable true classified it straight
 *      OUT of its own check — 17/17 green, and a hypothesis had become a fact.
 *   2. SILENT DELETION. The inventory only asserted that hook_header_items
 *      1-4 were represented. Deleting H2b, H3b, H5, H6, H6b and H7 outright
 *      left 17/17 green, because nothing said those rows had to exist.
 *
 * So the classification and the required set live HERE, in the test, as
 * literals. A row's `kind` must match this map, and the registry's id set must
 * equal this list exactly. Adding a genuinely new contract therefore requires
 * editing this file — that friction is the point: it is the moment somebody
 * has to decide, deliberately, which side of the line the new row is on.
 * ------------------------------------------------------------------------ */

/** Ids that are PLATFORM HYPOTHESES: unproven, and not promotable in a commit. */
const HYPOTHESIS_IDS = [
    'H1-extension-point-exists',
    'H2-input-binding',
    'H2b-input-completeness',
    'H3-raise-aborts-run',
    'H3b-non-dispatch',
    'H4-output-destination',
    'H5-module-guard-inert',
    'H6-rest-message-alias',
    'H6b-alias-supplies-authorization',
    'H7-platform-digest-hex'
];

/** Ids that are SERVICE CONTRACTS: documented, and locally settleable. */
const SERVICE_CONTRACT_IDS = [
    'C-VENDOR-REQUIRED',
    'C-VENDOR-ALLOWLIST',
    'C-FAIL-CLOSED-TRANSPORT',
    'C-EVIDENCE-PRECONDITION',
    'C-CERT-TIER',
    'C-ERROR-DISCRIMINATOR',
    'C-DESTINATION-NOT-FAIL-CLOSED'
];

const REQUIRED_KIND = new Map(
    HYPOTHESIS_IDS.map((id) => [id, 'platform-hypothesis'])
        .concat(SERVICE_CONTRACT_IDS.map((id) => [id, 'service-contract'])));

const byId = new Map(REGISTRY.contracts.map((c) => [c.id, c]));

/* Every test name this file declares, so the registry cannot reference one that
 * does not exist and a test cannot quietly stop being a contract's expression. */
const declaredTests = new Set();
function contractTest(name, fn) {
    declaredTests.add(name);
    test(name, fn);
}

/**
 * A guard over a scripted decision — no network, no tables. The subject here is
 * the HOOK's handling of its bindings, and a round trip would only add noise.
 *
 * @param {object} protectResult what the stubbed adapter returns
 * @returns {{instance: object, seen: object[]}}
 */
function scriptedInstance(protectResult) {
    const seen = [];
    return {
        seen,
        instance: {
            adapter: {
                protect: (args) => { seen.push(args); return protectResult; }
            }
        }
    };
}

const COVERED = {
    allowed: true, coverage: 'covered', textForSkill: SANITIZED,
    correlationId: 'corr_contract', evidenceId: 'ev_contract', error: null
};
const BLOCKED = {
    allowed: false, coverage: 'uncovered', textForSkill: '',
    correlationId: 'corr_contract', evidenceId: 'ev_contract',
    error: { code: 'lucairn_service_unreachable', failure_class: 'connection_refused' }
};

/* ---- registry integrity -------------------------------------------------- */

test('REGISTRY every contract row is complete and well-formed', () => {
    assert.strictEqual(REGISTRY.instance_validation, 'pending',
        'the registry may not report anything but pending until an instance has settled a row');
    const ids = new Set();
    for (const c of REGISTRY.contracts) {
        assert.ok(c.id, 'a contract row has no id');
        assert.ok(!ids.has(c.id), `duplicate contract id: ${c.id}`);
        ids.add(c.id);
        assert.ok(typeof c.statement === 'string' && c.statement.length > 20, `${c.id}: no statement`);
        assert.ok(['platform-hypothesis', 'service-contract'].includes(c.kind), `${c.id}: bad kind`);
        assert.ok(['instance-pending', 'locally-pinned'].includes(c.status),
            `${c.id}: status "${c.status}" is not one this registry knows`);
        assert.ok(Array.isArray(c.source) && c.source.length > 0, `${c.id}: no source citation`);
        assert.ok(c.expressed_by && Array.isArray(c.expressed_by.tests) &&
            Array.isArray(c.expressed_by.probes), `${c.id}: expressed_by is malformed`);
        assert.ok(c.settled_on_instance_by && Array.isArray(c.settled_on_instance_by.runbook_legs) &&
            c.settled_on_instance_by.runbook_legs.length > 0,
            `${c.id}: no runbook leg would settle it — an unfalsifiable row is not a contract`);
        assert.ok(Object.prototype.hasOwnProperty.call(c, 'instance_record'),
            `${c.id}: instance_record must be present, even as null`);
    }
});

test('REGISTRY the row inventory is an EXACT set — nothing may be deleted, nothing added unnoticed', () => {
    // astra counterexample 2: deleting H2b/H3b/H5/H6/H6b/H7 left the suite green,
    // because the old inventory only asked whether hook_header_items 1-4 were
    // represented. A registry you can shrink in silence records nothing.
    const present = REGISTRY.contracts.map((c) => c.id).sort();
    const required = HYPOTHESIS_IDS.concat(SERVICE_CONTRACT_IDS).sort();
    assert.deepStrictEqual(present, required,
        'the registry\'s rows and this test\'s frozen list disagree. A DELETED row is a dependency that stopped being written down; a NEW row must be classified here deliberately, as a hypothesis or a contract.');
});

test('REGISTRY a row cannot classify itself out of its own check', () => {
    // astra counterexample 1: flipping H3 to kind "service-contract" +
    // status "locally-pinned" + locally_settleable true made the promotion guard
    // SKIP it — the row reclassified itself, and a hypothesis became a fact in
    // one edit. The kind is therefore asserted against the frozen map, not read
    // off the row.
    for (const [id, kind] of REQUIRED_KIND) {
        const c = byId.get(id);
        assert.ok(c, `${id}: required row is missing`);
        assert.strictEqual(c.kind, kind,
            `${id}: is classified "${c.kind}" but this test holds it to be a ${kind}. A row does not get to change which guard applies to it.`);
    }
});

test('REGISTRY no hypothesis has been promoted without an instance record', () => {
    // The failure mode this guards: a hypothesis quietly becoming a fact between
    // two commits, by an edit to one word. Promotion needs evidence, and the
    // evidence is a gate record naming the instance family and patch level.
    //
    // Iterates the FROZEN id list, not the registry — so neither deleting a row
    // nor relabelling one can remove it from this check.
    for (const id of HYPOTHESIS_IDS) {
        const c = byId.get(id);
        assert.ok(c, `${id}: required hypothesis row is missing entirely`);
        assert.strictEqual(c.status, 'instance-pending',
            `${id}: a platform hypothesis may not be "${c.status}" while nothing has run on an instance`);
        assert.strictEqual(c.instance_record, null,
            `${id}: carries an instance record — if that is real, the status must change WITH it and this test must be updated deliberately`);
        assert.strictEqual(c.locally_settleable, false,
            `${id}: a platform hypothesis is by definition not locally settleable`);
        assert.ok(typeof c.why_not_locally_settleable === 'string' &&
            c.why_not_locally_settleable.length > 20,
            `${id}: must say WHY it cannot be settled locally, so the gap is legible`);
    }
});

test('REGISTRY every contract the manifest references resolves to a row', () => {
    // The packaging manifest hangs contract ids off artefacts — the hook, the
    // vendor property, the destination property, the alias and REST message. A
    // deleted row would leave those pointing at nothing, which is how an
    // artefact comes to look governed while its governance has gone.
    const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, 'app', 'app-manifest.json'), 'utf8'));
    let referenced = 0;
    for (const a of manifest.artifacts) {
        for (const id of (a.contracts || [])) {
            referenced += 1;
            assert.ok(byId.has(id),
                `manifest artefact "${a.name}" references contract "${id}", which no registry row provides`);
        }
    }
    assert.ok(referenced > 0, 'the manifest references no contracts at all — the link between artefacts and their governance is gone');
});

test('REGISTRY every row names a runbook leg that exists in the README', () => {
    for (const c of REGISTRY.contracts) {
        for (const leg of c.settled_on_instance_by.runbook_legs) {
            // Sub-legs (2a, 2b, 3a, 3b) are sub-headings under their base leg;
            // the README names the base leg, so match on that.
            const base = /^(Leg \d+)/.exec(leg);
            assert.ok(base, `${c.id}: "${leg}" is not a leg reference`);
            assert.ok(README.indexOf(base[1]) !== -1,
                `${c.id}: the README has no ${base[1]} — a contract pointing at a leg that does not exist settles nothing`);
        }
    }
});

test('REGISTRY every referenced test and probe exists', () => {
    const probeIds = new Set(probes.map((p) => p.id));
    for (const c of REGISTRY.contracts) {
        for (const name of c.expressed_by.tests) {
            assert.ok(declaredTests.has(name),
                `${c.id}: references a test that this file does not declare: "${name}"`);
        }
        for (const id of c.expressed_by.probes) {
            assert.ok(probeIds.has(id),
                `${c.id}: references a probe that does not exist: "${id}"`);
        }
    }
});

test('REGISTRY covers all four of the hook header\'s unproven items', () => {
    const items = new Set(REGISTRY.contracts
        .map((c) => c.hook_header_item)
        .filter((n) => typeof n === 'number'));
    for (const n of [1, 2, 3, 4]) {
        assert.ok(items.has(n),
            `the hook header enumerates unproven item ${n}, and no registry row claims it`);
    }
});

test('REGISTRY covers every destination the hook actually recognises', () => {
    // Parsed from the hook source, not copied: adding a fifth destination there
    // without registering it fails here rather than shipping unregistered.
    const m = /var DESTINATIONS = \[([^\]]+)\];/.exec(HOOK_SOURCE);
    assert.ok(m, 'the hook no longer declares a DESTINATIONS list in the expected shape');
    const inHook = m[1].split(',').map((s) => s.trim().replace(/^'|'$/g, '')).filter(Boolean);

    const row = REGISTRY.contracts.find((c) => c.id === 'H4-output-destination');
    assert.deepStrictEqual(inHook.slice().sort(), (row.destinations || []).slice().sort(),
        'the registry\'s destination list and the hook\'s do not agree');
    assert.deepStrictEqual(inHook.slice().sort(), DESTINATIONS.slice().sort(),
        'the documented-shape stub does not model every destination the hook recognises');
});

test('REGISTRY every probe maps back to at least one registered contract', () => {
    const ids = new Set(REGISTRY.contracts.map((c) => c.id));
    for (const p of probes) {
        assert.ok(Array.isArray(p.contracts) && p.contracts.length > 0,
            `${p.id}: a probe with no contract is a test looking for a reason`);
        for (const c of p.contracts) {
            assert.ok(ids.has(c), `${p.id}: references an unregistered contract "${c}"`);
        }
    }
});

test('REGISTRY no file claims a hypothesis has been validated on an instance', () => {
    // Narrow literal ban, deliberately: these are the phrases that would turn a
    // registered hypothesis into a fact in a reader's mind without anything
    // having run. Broader wording checks produce false positives on the many
    // places this directory says the OPPOSITE.
    const banned = [
        'install-validated', 'instance-validated', 'pdi-verified',
        'instance validation complete', 'validated on the instance',
        'verified on a live instance'
    ];
    const files = [];
    (function walk(dir) {
        for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
            const p = path.join(dir, e.name);
            if (e.isDirectory()) { walk(p); } else if (/\.(js|json|md|sh)$/.test(e.name)) { files.push(p); }
        }
    })(ROOT);

    for (const f of files) {
        const text = fs.readFileSync(f, 'utf8').toLowerCase();
        for (const phrase of banned) {
            // This file is allowed to name the phrases it bans.
            if (f === __filename) { continue; }
            assert.ok(text.indexOf(phrase) === -1,
                `"${phrase}" appears in ${path.relative(ROOT, f)} — nothing here has run on an instance`);
        }
    }
});

/* ---- H2: the input binding ----------------------------------------------- */

contractTest('H2 the hook hands the platform-supplied input to the guard verbatim and in full', () => {
    // WHAT THIS SETTLES: the hook does not trim, truncate, re-encode or
    // summarise what the extension point gave it — a certificate over a
    // fragment would attest less than it appears to.
    // WHAT IT DOES NOT SETTLE: that `input` is the binding the platform uses.
    // That is H2-input-binding, instance-pending, and a wrong ADJUST-ON-PDI name
    // is one of the three candidate causes README § Leg 6 lists for a fixture
    // name surviving into a summary.
    const long = RAW + ' ' + 'x'.repeat(5000) + ' 日本語のテスト文字列も含む。';
    const { instance, seen } = scriptedInstance(COVERED);
    const run = runHookInExtensionPoint({
        hookSource: HOOK_SOURCE, instance, input: long,
        declared: 'bare_output', consumed: 'bare_output'
    });

    assert.strictEqual(run.raised, null, 'the covered path must not raise');
    assert.strictEqual(seen.length, 1, 'exactly one protection decision per run');
    assert.strictEqual(seen[0].text, long, 'the submitted text reached the guard altered');
    assert.strictEqual(seen[0].text.length, long.length);
});

contractTest('H2 an absent input binding yields an empty submission, not a guess at another binding', () => {
    // The documented consequence of the ADJUST-ON-PDI name being wrong: the hook
    // does NOT go looking for `inputs.text` or `payload.prompt`. It sanitizes
    // the empty string, which is visible in the evidence row rather than silent.
    //
    // ⚠️ RECORDED AS A GUESS-POINT, not as a safety property: on an instance
    // whose real binding is not `input`, this path publishes sanitized EMPTINESS
    // to the declared destination while the platform's own binding still holds
    // the raw submission — the same shape as C-DESTINATION-NOT-FAIL-CLOSED, and
    // detectable only by Leg 6's coverage half. It is pinned here so it cannot
    // be mistaken for fail-closed behaviour.
    const { instance, seen } = scriptedInstance(COVERED);
    const run = runHookInExtensionPoint({
        hookSource: HOOK_SOURCE, instance, input: undefined,
        declared: 'bare_output', consumed: 'bare_output'
    });

    assert.strictEqual(run.raised, null);
    assert.strictEqual(seen[0].text, '', 'an absent input must not become a guess at another binding');
    assert.ok(!/inputs\.text|payload\.prompt/.test(
        HOOK_SOURCE.split('ADJUST-ON-PDI (2/2)')[1] || ''),
        'the hook body consults an alternative input binding — that is a destination ladder in the input position');
});

/* ---- H3 + C-ERROR-DISCRIMINATOR: what a block does ----------------------- */

contractTest('H3 a blocked verdict raises under the block prefix and publishes nothing', () => {
    const { instance } = scriptedInstance(BLOCKED);
    const run = runHookInExtensionPoint({
        hookSource: HOOK_SOURCE, instance, input: RAW,
        declared: 'bare_output', consumed: 'bare_output'
    });

    assert.ok(run.raised, 'a block must raise — a hook that returns "please stop" has stopped nothing');
    assert.strictEqual(run.raised.message.indexOf(LucairnSkillGuard.ERROR_PREFIX), 0);
    // The raise exits before the publish, so the slot still holds what the
    // extension point handed in. That is the hook header's own note about
    // outcome (b), made observable rather than asserted.
    assert.strictEqual(run.consumedValue, RAW,
        'a blocked run must not have written the destination at all');
});

contractTest('C-ERROR-DISCRIMINATOR a wiring failure never borrows the block prefix', () => {
    // Leg 6 has exactly one discriminator between "protection blocked the run"
    // and "the hook is broken". If a wiring failure could wear the block prefix,
    // a total outage would be scored as working protection — which is round-2
    // finding N-1 with better manners.
    const { instance } = scriptedInstance(COVERED);
    const run = runHookInExtensionPoint({
        hookSource: HOOK_SOURCE, instance, input: RAW,
        declared: 'outputs_text', consumed: 'outputs_text'
    });
    assert.strictEqual(run.raised, null, 'sanity: the matched case publishes');

    // An unrecognised configured value is a wiring failure.
    const typo = scriptedInstance(COVERED);
    const bad = runHookInExtensionPoint({
        hookSource: HOOK_SOURCE, instance: typo.instance, input: RAW,
        declared: 'outputs_txt', consumed: 'outputs_text'
    });
    assert.ok(bad.raised, 'an unrecognised destination must raise rather than fall back to a default');
    assert.ok(bad.raised.message.indexOf('hook could not publish its output:') !== -1,
        `a wiring failure must carry the wiring phrase; got: ${bad.raised.message}`);
    assert.strictEqual(bad.raised.message.indexOf(LucairnSkillGuard.ERROR_PREFIX), -1,
        'a wiring failure must never wear the block prefix');
    assert.strictEqual(bad.consumedValue, RAW,
        'nothing may be published when the declared destination is not understood');
});

/* ---- H4: the four documented destinations -------------------------------- */

contractTest('H4 every documented destination shape publishes and verifies through a fresh evaluation', () => {
    // One assertion per documented shape, against a stub built to that shape.
    // Each is a HYPOTHESIS about the extension point (H4-output-destination);
    // what is pinned here is that the hook publishes to exactly the declared one
    // and confirms it by re-evaluating the configured expression.
    for (const destination of DESTINATIONS) {
        const { instance } = scriptedInstance(COVERED);
        const run = runHookInExtensionPoint({
            hookSource: HOOK_SOURCE, instance, input: RAW,
            declared: destination, consumed: destination
        });
        assert.strictEqual(run.raised, null,
            `${destination}: raised on a matched destination — ${run.raised && run.raised.message}`);
        assert.strictEqual(run.consumedValue, SANITIZED,
            `${destination}: the consumed slot does not hold the sanitized text`);
    }
});

contractTest('C-DESTINATION a recognised-but-wrong destination returns normally and leaves the consumed slot raw', () => {
    // THIS TEST PINS A KNOWN GAP, not a safety property. It exists so that the
    // day someone claims the destination handling is fail-closed, this row goes
    // red rather than the claim going out.
    //
    // Both directions, because both were reproduced during the round-5 review:
    // the declared destination can be the one that works while the consumed one
    // stays raw, and vice versa.
    const pairs = [
        ['bare_output', 'outputs_text'],
        ['outputs_text', 'bare_output'],
        ['api_set_output', 'outputs_text']
    ];
    for (const [declared, consumed] of pairs) {
        const { instance } = scriptedInstance(COVERED);
        const run = runHookInExtensionPoint({
            hookSource: HOOK_SOURCE, instance, input: RAW, declared, consumed
        });
        assert.strictEqual(run.raised, null,
            `${declared}->${consumed}: the hook cannot detect this and must not appear to`);
        assert.strictEqual(run.consumedValue, RAW,
            `${declared}->${consumed}: the consumed slot should still hold the RAW submission`);
    }
});

/* ---- C-VENDOR: the provider-identity boundary ---------------------------- */

contractTest('C-VENDOR the accepted set is exactly three literals and nothing supplies a default', () => {
    assert.deepStrictEqual(LucairnConfig.ALLOWED_VENDORS, ['anthropic', 'openai', 'google'],
        'the accepted vendor set changed — that is a change to the Lucairn service\'s own contract and needs its own design pass');

    const config = new LucairnConfig({
        getProperty: (name, fallback) => fallback,
        glideRecord: () => { throw new Error('no table access expected'); },
        log: () => {}
    });
    const cfg = config.resolve();
    assert.strictEqual(cfg.vendor, '', 'resolve() supplied a vendor value from nowhere');

    const problems = config.validate(cfg);
    const vendorProblem = problems.find((p) => p.indexOf('vendor is not set') === 0);
    assert.ok(vendorProblem, `an unset vendor must fail validation; got: ${problems.join(' | ')}`);
    // The error SURFACE is actionable: an operator reading an evidence row must
    // learn which property to set without going to find the README first.
    assert.ok(vendorProblem.indexOf(LucairnConfig.PROP.VENDOR) !== -1,
        'the message does not name the property to set');
    assert.ok(vendorProblem.indexOf('no default') !== -1,
        'the message does not say the absence of a default is deliberate');
    for (const v of LucairnConfig.ALLOWED_VENDORS) {
        assert.ok(vendorProblem.indexOf(v) !== -1, `the message does not list ${v}`);
    }

    const wrong = config.validate(Object.assign({}, cfg, { vendor: 'acme-llm' }));
    const wrongProblem = wrong.find((p) => p.indexOf('not one of') !== -1);
    assert.ok(wrongProblem, 'an out-of-set vendor must fail validation');
    assert.ok(wrongProblem.indexOf('acme-llm') !== -1, 'the message does not quote the rejected value');
    assert.ok(wrongProblem.indexOf('blocker to raise') !== -1,
        'the message does not tell the operator to raise the gap rather than map onto a neighbour');
});

contractTest('C-VENDOR no source file introduces a vendor literal or a provider mapping', () => {
    // The non-amendment boundary, made executable. A second place that knows a
    // vendor name is a place a mapping can grow — and a mapped vendor puts a
    // false provenance value on a certificate.
    const files = [];
    (function walk(dir) {
        for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
            const p = path.join(dir, e.name);
            if (e.isDirectory()) { walk(p); } else if (/\.js$/.test(e.name)) { files.push(p); }
        }
    })(path.join(ROOT, 'src'));

    for (const f of files) {
        const text = fs.readFileSync(f, 'utf8');
        const hits = text.match(/['"](anthropic|openai|google|bedrock|azure|gemini|watsonx|mistral)['"]/gi) || [];
        if (path.basename(f) === 'LucairnConfig.js') {
            // The one home for the set: ALLOWED_VENDORS, three literals, once each.
            assert.strictEqual(hits.length, 3,
                `LucairnConfig declares ${hits.length} vendor literals; the allow-list is three and nothing else may name one`);
            continue;
        }
        assert.strictEqual(hits.length, 0,
            `${path.relative(ROOT, f)} names a vendor literal: ${hits.join(', ')}`);
    }
});

/* ---- C-CERT-TIER --------------------------------------------------------- */

contractTest('C-CERT-TIER a tier other than input-shield is a contract violation, not an upgrade', () => {
    assert.strictEqual(LucairnNowAssistAdapter.CERT_TIER, 'input-shield');

    const adapter = new LucairnNowAssistAdapter({
        config: { resolve: () => ({}), validate: () => [], skillPolicy: () => ({ failOpen: false }) },
        evidence: { write: () => ({ stored: true, sysId: 'ev1' }), recordSeal: () => ({ updated: true }) },
        sha256: { wireOfUtf8: () => 'sha256:' + '0'.repeat(64) },
        makeClient: () => ({
            sealCert: () => ({
                ok: true, status: 200, durationMs: 5, failureClass: 'none', message: '',
                body: {
                    cert_id: 'cert_x',
                    cert_url: 'https://lucairn.example.test/verify?id=req_x',
                    // "full-chain" asserts an isolated inference path this
                    // integration does not have. A better-sounding tier is the
                    // one response shape that must NOT be accepted.
                    cert_tier: 'full-chain'
                }
            })
        }),
        guid: () => 'corr_x',
        log: () => {}
    });

    const out = adapter.seal({
        protectResult: {
            coverage: 'covered', certIdPartial: 'cert_partial_x', evidenceStored: true,
            evidenceId: 'ev1', textForSkill: SANITIZED, correlationId: 'corr_x', skill: 'Incident summarization'
        },
        responseText: 'Summary: synthetic.'
    });

    assert.strictEqual(out.sealed, false, 'a full-chain tier was accepted');
    assert.strictEqual(out.error.code, LucairnNowAssistAdapter.ERROR.CONTRACT);
});
