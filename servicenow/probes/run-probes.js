#!/usr/bin/env node
'use strict';

/*
 * Run the falsification probe kit in DRY-RUN mode against the local
 * documented-shape stubs.
 *
 * DRY-RUN IS THE ONLY MODE THIS FILE HAS, and that is deliberate. There is no
 * `--live` flag and no instance mode: the on-instance work is the runbook in
 * ../README.md § Verify on the PDI, executed by hand with its observables
 * recorded in a gate record. A flag that pretended to run these probes against
 * an instance would be the thing this whole directory exists to avoid.
 *
 *   node probes/run-probes.js            human-readable report, exit 1 on failure
 *   node probes/run-probes.js --json     the same verdicts as JSON
 *
 * ACCEPTANCE (both halves, per probe):
 *   - the good path reports NO finding
 *   - the seeded fault IS caught
 * Anything else exits non-zero. A probe that cannot fail is not evidence.
 */

const { probes } = require('./probes');

const asJson = process.argv.indexOf('--json') !== -1;

async function main() {
    const results = [];

    for (const probe of probes) {
        const entry = {
            id: probe.id,
            title: probe.title,
            fault: probe.fault,
            runbook_legs: probe.legs,
            contracts: probe.contracts,
            good: null,
            seeded: null,
            verdict: 'FAIL',
            error: null
        };
        try {
            entry.good = await probe.good();
            if (probe.seeded) {
                entry.seeded = await probe.seeded();
            }
            const goodOk = entry.good && entry.good.pass === true;
            const seededOk = probe.seeded ? !!(entry.seeded && entry.seeded.caught === true) : true;
            entry.verdict = (goodOk && seededOk) ? 'PASS' : 'FAIL';
        } catch (e) {
            entry.error = String((e && e.stack) || e);
            entry.verdict = 'FAIL';
        }
        results.push(entry);
    }

    const failed = results.filter((r) => r.verdict !== 'PASS');

    if (asJson) {
        process.stdout.write(JSON.stringify({
            mode: 'dry-run',
            target: 'local documented-shape stubs (probes/lib)',
            instance_validation: 'pending',
            results
        }, null, 2) + '\n');
    } else {
        console.log('Lucairn for Now Assist — falsification probe kit');
        console.log('mode: DRY-RUN against local documented-shape stubs. Instance validation pending.');
        console.log('');
        for (const r of results) {
            console.log(`${r.verdict === 'PASS' ? 'PASS' : 'FAIL'}  ${r.id} — ${r.title}`);
            if (r.fault) {
                console.log(`      seeded fault: ${r.fault}`);
                console.log(`      caught: ${r.seeded ? r.seeded.caught : 'NOT RUN'}` +
                    `   good path clean: ${r.good ? r.good.pass : 'NOT RUN'}`);
            } else {
                console.log(`      good path clean: ${r.good ? r.good.pass : 'NOT RUN'}`);
            }
            console.log(`      settles on the instance at: ${r.runbook_legs.join(', ')}`);
            if (r.error) { console.log(`      ERROR: ${r.error}`); }
            if (r.verdict !== 'PASS') {
                console.log('      observed: ' + JSON.stringify(r.seeded ? r.seeded.observed : (r.good && r.good.observed)));
            }
            console.log('');
        }
        console.log(`${results.length - failed.length}/${results.length} probes PASS`);
        if (failed.length) {
            console.log('FAILED: ' + failed.map((f) => f.id).join(', '));
        }
        console.log('');
        console.log('A green dry-run says the probes detect these faults in the shapes the');
        console.log('contract documents. It is not evidence about a ServiceNow instance —');
        console.log('see ../contracts/instance-contracts.json and README.md § Verify on the PDI.');
    }

    process.exitCode = failed.length ? 1 : 0;
}

main().catch((e) => {
    console.error('probe kit crashed: ' + String((e && e.stack) || e));
    process.exitCode = 1;
});
