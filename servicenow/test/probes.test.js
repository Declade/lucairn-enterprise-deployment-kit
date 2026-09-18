'use strict';

/*
 * The probe kit's RED-PROOF, executed by the kit's own gate.
 *
 * A probe kit that lives beside the tests but is never run by them rots: the
 * day a probe stops catching its fault, nothing says so. So the dry-run is a
 * test, and every probe must satisfy BOTH halves:
 *
 *   good()   — with the fault NOT seeded, the probe reports no finding
 *   seeded() — with the fault seeded, the probe CATCHES it
 *
 * The first half is the half that matters most: a probe that fires on the good
 * path is an alarm, and an alarm that is always on proves nothing when it goes
 * off. Requiring both is what makes "the probes catch these faults" measured.
 *
 * These probes run against local documented-shape stubs. Green here is evidence
 * about the PROBES, never about a ServiceNow instance — the platform behaviours
 * the stubs stand in for are registered as hypotheses in
 * ../contracts/instance-contracts.json. **Instance validation pending.**
 */

const test = require('node:test');
const assert = require('node:assert');

const { probes } = require('../probes/probes');

/* The six faults the package PRD names, plus the good path they are measured
 * against. Listed here as well as in the probe definitions so that DELETING a
 * probe fails the suite rather than shrinking the claim silently. */
const REQUIRED_FAULTS = [
    'missing vendor',
    'unsupported vendor',
    'connection refusal',
    'timeout',
    'evidence-write failure',
    'wrong-but-recognized output destination'
];

test('the probe kit covers every fault the package requires it to catch', () => {
    const covered = probes.map((p) => p.fault).filter(Boolean);
    for (const fault of REQUIRED_FAULTS) {
        assert.ok(covered.includes(fault),
            `no probe seeds "${fault}" — the kit's coverage shrank. Probes: ${covered.join(' | ')}`);
    }
});

for (const probe of probes) {
    test(`probe ${probe.id} — good path reports no finding`, async () => {
        const result = await probe.good();
        assert.strictEqual(result.pass, true,
            `${probe.id} flagged the good path: ${JSON.stringify(result.observed)}`);
    });

    if (probe.seeded) {
        test(`probe ${probe.id} — catches its seeded fault (${probe.fault})`, async () => {
            const result = await probe.seeded();
            assert.strictEqual(result.caught, true,
                `${probe.id} missed its own seeded fault: ${JSON.stringify(result.observed)}`);
        });
    }
}
