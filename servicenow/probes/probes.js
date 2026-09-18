'use strict';

/*
 * The falsification probes.
 *
 * THE RULE THIS FILE IS BUILT ON
 * ------------------------------
 * A probe that only ever passes has proven nothing. Every probe here is a PAIR:
 *
 *   good()    — the fault is NOT seeded. The probe must report NO finding.
 *   seeded()  — the fault IS seeded. The probe must CATCH it.
 *
 * A probe that reports a finding on the good path is an alarm, not a probe; a
 * probe that misses its own seeded fault is decoration. The runner fails the
 * kit unless BOTH halves behave, which is what makes "the probes catch these
 * six faults" a measured statement rather than an assertion.
 *
 * WHAT A GREEN RUN MEANS, EXACTLY
 * -------------------------------
 * The probes ran against local documented-shape stubs (probes/lib/). A green
 * dry-run says the probe kit detects the six faults in the shapes the contract
 * documents. It says NOTHING about a ServiceNow instance: the platform
 * behaviours these shapes stand in for are unproven hypotheses, enumerated in
 * ../contracts/instance-contracts.json and settled only by the runbook legs in
 * ../README.md § Verify on the PDI. **Instance validation pending.**
 */

const fs = require('node:fs');
const path = require('node:path');

const { startServiceStub, closedPort } = require('./lib/service-stub');
const { syncRequest } = require('./lib/sync-http');
const { makeInstance, runHookInExtensionPoint, DESTINATIONS } = require('./lib/instance-stub');
const LucairnNowAssistAdapter = require('../src/script_includes/LucairnNowAssistAdapter');
const LucairnSkillGuard = require('../src/script_includes/LucairnSkillGuard');
const LucairnClient = require('../src/script_includes/LucairnClient');

const fixtures = require('../fixtures/synthetic-incidents.json');
const INCIDENT = fixtures.incidents.find((i) => i.id === 'fixture-basic-contact');
const SKILL = fixtures.skill_names.protected;

const HOOK_SOURCE = fs.readFileSync(
    path.join(__dirname, '..', 'src', 'hooks', 'genai-preprocessor.js'), 'utf8');

/* A synthetic canary in the shape the eval-experiment plan uses
 * (specs/2026-09/plan-servicenow-eval-experiments.md § Canary seeding matrix).
 * Its whole job is to be findable afterwards: if it survives into a slot the
 * platform reads, the content was never protected. */
const CANARY = 'CAN-DESC-PROBE1';
const SUBMITTED = INCIDENT.description + ' Ticket tag ' + CANARY + '.';

const REDACTIONS = [
    [CANARY, '[CANARY_1]'],
    ['Brannagh Oduya-Kestrel', '[PERSON_1]'],
    ['brannagh.oduya-kestrel@northmarrow-example.test', '[EMAIL_1]']
];

const ERROR_MODES = ['throw', 'flag'];

/* Read from the client, not retyped: a path rename there must break the probes
 * rather than quietly pointing them at a path nobody calls. */
const SEAL_PATH = LucairnClient.PATH_SEAL;

/** Run `fn` with a live service stub, closing it afterwards whatever happens. */
async function withService(opts, fn) {
    const stub = await startServiceStub(Object.assign({ redactions: REDACTIONS }, opts || {}));
    try {
        return await fn(stub);
    } finally {
        await stub.close();
    }
}

function coveredRun(instance) {
    return instance.adapter.protect({ skill: SKILL, text: SUBMITTED });
}

function lastRow(instance) {
    const rows = instance.rows();
    return rows.length ? rows[rows.length - 1] : null;
}

/**
 * FAULT PROVENANCE, PER ATTEMPT.
 *
 * Two astra counterexamples killed the previous accounting, and both came from
 * asking the wrong witness:
 *
 *   1. CUMULATIVE ARRIVALS. "was the connection accepted?" was
 *      `svc.requestCount() > 0` against a stub shared by both transport-error
 *      modes. One mode's arrival therefore credited the other: a genuinely
 *      accepted timeout under `throw` plus a refusal that never arrived under
 *      `flag` scored as a clean timeout catch in both.
 *   2. THE ADAPTER'S LABEL. The adapter's failure class is a substring match
 *      that degrades to "unknown" — right for a decision that blocks either
 *      way, useless as evidence. A worker that failed to START produced a
 *      blocked run and a transport-looking label, and scored as a caught
 *      connection refusal.
 *
 * So each attempt is measured on its own: the stub's arrival count is read
 * before and after, and the transport records for THAT attempt are inspected
 * for the runtime's own errno. Nothing is inferred from an aggregate, and
 * nothing is taken from the classifier.
 *
 * @param {object} opts
 * @param {object} opts.instance  a FRESH instance — its httpCalls must belong to this attempt alone
 * @param {function(): number} [opts.arrivals] reads the stub's arrival count; omitted when no stub is addressed
 * @param {function(): object} opts.run  performs the attempt
 * @returns {object} the observation for this attempt
 */
function attempt(opts) {
    const before = opts.arrivals ? opts.arrivals() : 0;
    const result = opts.run();
    const after = opts.arrivals ? opts.arrivals() : 0;

    const calls = opts.instance.httpCalls;
    return {
        result: result,
        /* Arrivals attributable to THIS attempt, not to the run as a whole. */
        arrival_delta: after - before,
        transport_attempts: calls.length,
        /* Every attempt must have reached the socket layer. A 'worker' record
         * means the harness broke; it may never count as a caught fault. */
        all_transport: calls.length > 0 && calls.every((c) => c.result && c.result.kind === 'transport'),
        harness_failures: calls.filter((c) => !c.result || c.result.kind !== 'transport')
            .map((c) => (c.result && c.result.error) || 'unknown'),
        /* The runtime's own errno per call, and whether the timeout path fired.
         * Independent of the adapter's diagnostic classification. */
        codes: calls.map((c) => (c.result && c.result.code) || ''),
        timed_out: calls.map((c) => !!(c.result && c.result.timedOut))
    };
}

/* ------------------------------------------------------------------------- */

const probes = [

    {
        id: 'P0-good-path',
        title: 'the documented good path, end to end, on every declared destination',
        fault: null,
        legs: ['Leg 0', 'Leg 1', 'Leg 6 coverage half'],
        contracts: ['H2-input-binding', 'H4-output-destination', 'C-CERT-TIER'],
        /* No seeded half: this probe IS the good path the others' controls
         * reuse. Its value is that a kit whose good path is broken cannot
         * report six green catches and look healthy. */
        async good() {
            return withService({}, async (svc) => {
                const observed = { destinations: {}, seal: null };
                for (const destination of DESTINATIONS) {
                    const instance = makeInstance({ baseUrl: svc.url });
                    const run = runHookInExtensionPoint({
                        hookSource: HOOK_SOURCE, instance, input: SUBMITTED,
                        declared: destination, consumed: destination, skill: SKILL
                    });
                    observed.destinations[destination] = {
                        raised: run.raised ? String(run.raised.message) : null,
                        published: typeof run.consumedValue === 'string' &&
                            run.consumedValue.indexOf('[CANARY_1]') !== -1,
                        canary_survived: typeof run.consumedValue === 'string' &&
                            run.consumedValue.indexOf(CANARY) !== -1,
                        evidence_outcome: lastRow(instance) ? lastRow(instance).outcome : null
                    };
                }

                /* The seal half, on a plain adapter call: a covered run must
                 * mint an input-shield certificate and record it. */
                const sealInstance = makeInstance({ baseUrl: svc.url });
                const protectResult = coveredRun(sealInstance);
                const sealed = sealInstance.adapter.seal({
                    protectResult,
                    responseText: 'Summary: a laptop fails to boot after a patch window.'
                });
                observed.seal = {
                    coverage: protectResult.coverage,
                    sealed: sealed.sealed,
                    cert_tier: sealed.certTier,
                    seal_recorded: sealed.sealRecorded,
                    cert_url_present: !!sealed.certUrl
                };

                const destinationsOk = DESTINATIONS.every((d) => {
                    const o = observed.destinations[d];
                    return o.raised === null && o.published === true &&
                        o.canary_survived === false && o.evidence_outcome === 'covered';
                });
                const sealOk = observed.seal.sealed === true &&
                    observed.seal.cert_tier === LucairnNowAssistAdapter.CERT_TIER &&
                    observed.seal.seal_recorded === true;

                return { pass: destinationsOk && sealOk, observed };
            });
        }
    },

    {
        id: 'P1-missing-vendor',
        title: 'the vendor property is unset',
        fault: 'missing vendor',
        legs: ['Leg 1', 'README § Known gap: the vendor field'],
        contracts: ['C-VENDOR-REQUIRED'],
        async good() {
            return withService({}, async (svc) => {
                const instance = makeInstance({ baseUrl: svc.url, vendor: 'openai' });
                const res = coveredRun(instance);
                return {
                    pass: res.allowed === true && res.coverage === 'covered',
                    observed: { allowed: res.allowed, coverage: res.coverage }
                };
            });
        },
        async seeded() {
            return withService({}, async (svc) => {
                const instance = makeInstance({ baseUrl: svc.url, vendor: '' });
                const res = coveredRun(instance);
                const row = lastRow(instance);
                const observed = {
                    allowed: res.allowed,
                    error_code: res.error && res.error.code,
                    failure_class: res.error && res.error.failure_class,
                    evidence_outcome: row && row.outcome,
                    /* The property name must be IN the operator-facing message:
                     * an operator who cannot see which property to set has not
                     * been told anything actionable. */
                    message_names_the_property:
                        !!(res.error && String(res.error.message)
                            .indexOf('lucairn.now_assist.vendor') !== -1),
                    /* No request may have been made: validation runs BEFORE the
                     * sanitize call, so an unset vendor never costs a round trip
                     * and never sanitizes anything. */
                    service_requests: svc.requestCount()
                };
                return {
                    caught: res.allowed === false &&
                        observed.error_code === LucairnNowAssistAdapter.ERROR.CONFIG &&
                        observed.evidence_outcome === 'blocked' &&
                        observed.message_names_the_property === true &&
                        observed.service_requests === 0,
                    observed
                };
            });
        }
    },

    {
        id: 'P2-unsupported-vendor',
        title: 'the vendor property names a value the service does not accept',
        fault: 'unsupported vendor',
        legs: ['Leg 1', 'README § Known gap: the vendor field'],
        contracts: ['C-VENDOR-ALLOWLIST'],
        async good() {
            return withService({}, async (svc) => {
                const instance = makeInstance({ baseUrl: svc.url, vendor: 'anthropic' });
                const res = coveredRun(instance);
                return {
                    pass: res.allowed === true && res.coverage === 'covered',
                    observed: { allowed: res.allowed, coverage: res.coverage }
                };
            });
        },
        async seeded() {
            return withService({}, async (svc) => {
                /* A vendor that is honest about the deployment but outside the
                 * service's accepted set. The application does not map it onto
                 * one of the three — mapping would put a false provenance value
                 * on a certificate. It blocks. */
                const instance = makeInstance({ baseUrl: svc.url, vendor: 'acme-llm' });
                const res = coveredRun(instance);
                const row = lastRow(instance);
                const message = String((res.error && res.error.message) || '');
                const observed = {
                    allowed: res.allowed,
                    error_code: res.error && res.error.code,
                    evidence_outcome: row && row.outcome,
                    message_lists_accepted_values:
                        message.indexOf('anthropic') !== -1 &&
                        message.indexOf('openai') !== -1 &&
                        message.indexOf('google') !== -1,
                    service_requests: svc.requestCount()
                };
                return {
                    caught: res.allowed === false &&
                        observed.error_code === LucairnNowAssistAdapter.ERROR.CONFIG &&
                        observed.evidence_outcome === 'blocked' &&
                        observed.message_lists_accepted_values === true &&
                        observed.service_requests === 0,
                    observed
                };
            });
        }
    },

    {
        id: 'P3-connection-refused',
        title: 'the Lucairn service refuses the connection',
        fault: 'connection refusal',
        legs: ['Leg 2b'],
        contracts: ['C-FAIL-CLOSED-TRANSPORT'],
        async good() {
            return withService({}, async (svc) => {
                const out = {};
                for (const errorMode of ERROR_MODES) {
                    const instance = makeInstance({ baseUrl: svc.url, errorMode });
                    const res = coveredRun(instance);
                    out[errorMode] = { allowed: res.allowed, coverage: res.coverage };
                }
                return {
                    pass: ERROR_MODES.every((m) => out[m].allowed === true && out[m].coverage === 'covered'),
                    observed: out
                };
            });
        },
        async seeded() {
            /* A REAL refusal: a port that was bound long enough to learn its
             * number and then released. Not a scripted exception.
             *
             * A stub runs alongside it, addressed by nobody, so that "nothing
             * arrived" is a MEASURED zero on a live telemetry endpoint rather
             * than the absence of a measurement. */
            const port = await closedPort();
            return withService({}, async (svc) => {
                const out = {};
                for (const errorMode of ERROR_MODES) {
                    const instance = makeInstance({
                        baseUrl: 'http://127.0.0.1:' + port, errorMode, timeoutMs: 4000
                    });
                    const a = attempt({
                        instance,
                        arrivals: () => svc.requestCount(),
                        run: () => coveredRun(instance)
                    });
                    const res = a.result;
                    const row = lastRow(instance);
                    out[errorMode] = {
                        allowed: res.allowed,
                        error_code: res.error && res.error.code,
                        /* RECORDED, NOT ASSERTED. The classification comes from Node's
                         * error text, which is not the instance's — README § Leg 2
                         * says the same about the instance, and adding an observed
                         * marker there is a gate-record item, not a failure. */
                        observed_failure_class: res.error && res.error.failure_class,
                        evidence_outcome: row && row.outcome,
                        text_for_skill_empty: res.textForSkill === '',
                        /* PROVENANCE for THIS mode. */
                        arrival_delta: a.arrival_delta,
                        all_transport: a.all_transport,
                        harness_failures: a.harness_failures,
                        codes: a.codes,
                        refused_by_kernel: a.codes.length > 0 && a.codes.every((c) => c === 'ECONNREFUSED')
                    };
                }
                return {
                    caught: ERROR_MODES.every((m) =>
                        out[m].allowed === false &&
                        out[m].error_code === LucairnNowAssistAdapter.ERROR.UNREACHABLE &&
                        out[m].evidence_outcome === 'blocked' &&
                        out[m].text_for_skill_empty === true &&
                        /* The fault was a real refusal at the socket, in THIS
                         * mode: the harness reached the transport layer, the
                         * kernel refused every attempt, and nothing arrived
                         * anywhere. A broken worker fails `all_transport`; a
                         * timeout fails `refused_by_kernel`. */
                        out[m].all_transport === true &&
                        out[m].refused_by_kernel === true &&
                        out[m].arrival_delta === 0),
                    observed: out
                };
            });
        }
    },

    {
        id: 'P4-timeout',
        title: 'the Lucairn service accepts the connection and answers too late',
        fault: 'timeout',
        legs: ['Leg 3a'],
        contracts: ['C-FAIL-CLOSED-TRANSPORT'],
        async good() {
            return withService({}, async (svc) => {
                const instance = makeInstance({ baseUrl: svc.url, timeoutMs: 45000 });
                const res = coveredRun(instance);
                return {
                    pass: res.allowed === true && res.coverage === 'covered',
                    observed: { allowed: res.allowed, coverage: res.coverage }
                };
            });
        },
        async seeded() {
            /* A REAL read timeout: the stub accepts the connection and answers
             * well past the budget. README § Leg 3 warns against `timeout_ms=1`
             * for exactly this reason — a budget that expires before the socket
             * opens records a setting, not an observed timeout. */
            return withService({ delayMs: 2000 }, async (svc) => {
                const out = {};
                for (const errorMode of ERROR_MODES) {
                    const instance = makeInstance({
                        baseUrl: svc.url, errorMode, timeoutMs: 400
                    });
                    const a = attempt({
                        instance,
                        arrivals: () => svc.requestCount(),
                        run: () => coveredRun(instance)
                    });
                    const res = a.result;
                    const row = lastRow(instance);
                    out[errorMode] = {
                        allowed: res.allowed,
                        error_code: res.error && res.error.code,
                        observed_failure_class: res.error && res.error.failure_class,
                        evidence_outcome: row && row.outcome,
                        /* THIS attempt's arrival, not the run's running total.
                         * The cumulative version let an accepted request under
                         * one transport mode certify a refusal under the other. */
                        arrival_delta: a.arrival_delta,
                        all_transport: a.all_transport,
                        harness_failures: a.harness_failures,
                        timed_out: a.timed_out,
                        timeout_path_fired: a.timed_out.length > 0 && a.timed_out.every(Boolean)
                    };
                }
                return {
                    caught: ERROR_MODES.every((m) =>
                        out[m].allowed === false &&
                        out[m].error_code === LucairnNowAssistAdapter.ERROR.UNREACHABLE &&
                        out[m].evidence_outcome === 'blocked' &&
                        /* What makes this a TIMEOUT and not a refusal, per mode:
                         * the harness reached the transport layer, the request
                         * genuinely ARRIVED at the stub on this attempt, and the
                         * worker's timeout path — not a socket error — ended it. */
                        out[m].all_transport === true &&
                        out[m].arrival_delta === 1 &&
                        out[m].timeout_path_fired === true),
                    observed: out
                };
            });
        }
    },

    {
        id: 'P5-evidence-write-failure',
        title: 'a fail-open override whose audit row cannot be stored',
        fault: 'evidence-write failure',
        legs: ['Leg 4b'],
        contracts: ['C-EVIDENCE-PRECONDITION'],
        async good() {
            /* The override, working as designed: protection fails, the audited
             * unprotected run proceeds, and the row records it. No finding —
             * this is the behaviour an administrator asked for. */
            const port = await closedPort();
            const instance = makeInstance({
                baseUrl: 'http://127.0.0.1:' + port,
                timeoutMs: 4000,
                policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }]
            });
            const res = instance.adapter.protect({ skill: SKILL, text: SUBMITTED });
            const row = lastRow(instance);
            return {
                pass: res.allowed === true && res.coverage === 'uncovered' &&
                    row && row.outcome === 'uncovered_run' && row.fail_open_override === true,
                observed: {
                    allowed: res.allowed, coverage: res.coverage,
                    evidence_outcome: row && row.outcome
                }
            };
        },
        async seeded() {
            const port = await closedPort();
            const instance = makeInstance({
                baseUrl: 'http://127.0.0.1:' + port,
                timeoutMs: 4000,
                policyRows: [{ skill_name: SKILL, active: '1', fail_open: '1' }],
                evidenceInsertFails: true
            });
            const res = instance.adapter.protect({ skill: SKILL, text: SUBMITTED });
            const observed = {
                allowed: res.allowed,
                error_code: res.error && res.error.code,
                text_for_skill_empty: res.textForSkill === '',
                rows_written: instance.rows().length
            };
            return {
                /* The override authorises an AUDITED unprotected run. With no
                 * row there is no audit, so the run is blocked instead. */
                caught: res.allowed === false &&
                    observed.error_code === LucairnNowAssistAdapter.ERROR.UNAUDITABLE &&
                    observed.text_for_skill_empty === true &&
                    observed.rows_written === 0,
                observed
            };
        }
    },

    {
        id: 'P5b-covered-run-without-evidence-row',
        title: 'a covered run whose evidence row is missing cannot be sealed',
        fault: 'evidence-write failure (certificate half)',
        legs: ['Leg 4b, check 2'],
        contracts: ['C-EVIDENCE-PRECONDITION'],
        async good() {
            return withService({}, async (svc) => {
                const instance = makeInstance({ baseUrl: svc.url });
                const protectResult = coveredRun(instance);
                const sealed = instance.adapter.seal({
                    protectResult, responseText: 'Summary: synthetic.'
                });
                return {
                    pass: protectResult.evidenceStored === true && sealed.sealed === true,
                    observed: { evidence_stored: protectResult.evidenceStored, sealed: sealed.sealed }
                };
            });
        },
        async seeded() {
            return withService({}, async (svc) => {
                const instance = makeInstance({ baseUrl: svc.url, evidenceInsertFails: true });
                const protectResult = coveredRun(instance);
                /* Counted on the SEAL PATH specifically, and read from live
                 * telemetry that now throws rather than returning an empty list.
                 * The astra gate passed both halves of this probe while a real
                 * seal invocation had gone through, because a failed telemetry
                 * read became [] and the subtraction produced a fabricated zero.
                 * P5c below is the standing proof that this detector can see a
                 * seal call at all. */
                const before = svc.countPath(SEAL_PATH);
                const sealed = instance.adapter.seal({
                    protectResult, responseText: 'Summary: synthetic.'
                });
                const observed = {
                    coverage: protectResult.coverage,
                    evidence_stored: protectResult.evidenceStored,
                    sealed: sealed.sealed,
                    error_code: sealed.error && sealed.error.code,
                    /* No seal call may be made at all: the refusal is a local
                     * decision, and spending the one-shot cert_id_partial on it
                     * would burn a value that cannot be reused. */
                    seal_requests: svc.countPath(SEAL_PATH) - before
                };
                return {
                    caught: protectResult.allowed === true &&
                        observed.evidence_stored === false &&
                        observed.sealed === false &&
                        observed.error_code === LucairnNowAssistAdapter.ERROR.NO_EVIDENCE_ROW &&
                        observed.seal_requests === 0,
                    observed
                };
            });
        }
    },

    {
        id: 'P5c-premature-seal-detection',
        title: 'the seal-call detector can actually see a seal call',
        fault: 'a seal request reaching the service despite a declined seal',
        legs: ['Leg 4b, check 2'],
        contracts: ['C-EVIDENCE-PRECONDITION'],
        /* P5b asserts an ABSENCE — "no seal call was made". An absence is the
         * easiest thing in the world to measure wrongly: every broken detector
         * reports one. So this probe seeds the presence and requires the same
         * detector to report it. Without this, P5b's zero is unfalsifiable. */
        async good() {
            return withService({}, async (svc) => {
                const instance = makeInstance({ baseUrl: svc.url, evidenceInsertFails: true });
                const protectResult = coveredRun(instance);
                const before = svc.countPath(SEAL_PATH);
                instance.adapter.seal({ protectResult, responseText: 'Summary: synthetic.' });
                const delta = svc.countPath(SEAL_PATH) - before;
                return {
                    pass: delta === 0,
                    observed: { seal_requests: delta }
                };
            });
        },
        async seeded() {
            return withService({}, async (svc) => {
                const instance = makeInstance({ baseUrl: svc.url, evidenceInsertFails: true });
                const protectResult = coveredRun(instance);
                const before = svc.countPath(SEAL_PATH);

                instance.adapter.seal({ protectResult, responseText: 'Summary: synthetic.' });

                /* A real seal request, put on the wire behind the adapter's
                 * back — exactly the event P5b claims did not happen. */
                const injected = syncRequest({
                    url: svc.url + SEAL_PATH,
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    /* No `vendor` field, deliberately. This request exists to
                     * put one POST on the seal path so the detector has
                     * something to see; the stub does not validate a vendor,
                     * and naming one here would put a vendor literal in a file
                     * for no reason at all. The allow-list has exactly one home
                     * (LucairnConfig), and it stays that way. */
                    body: JSON.stringify({
                        cert_id_partial: String(protectResult.certIdPartial || 'cert_partial_injected'),
                        request_content_hash: 'sha256:' + '0'.repeat(64),
                        response_content_hash: 'sha256:' + '0'.repeat(64),
                        tool_name: 'probe kit — injected premature seal'
                    }),
                    timeoutMs: 5000
                });

                const delta = svc.countPath(SEAL_PATH) - before;
                const observed = {
                    injected_reached_the_transport: injected.kind === 'transport',
                    seal_requests: delta
                };
                return {
                    /* The detector must SEE it. A detector that reports zero
                     * here reports zero always, and P5b's absence claim is
                     * worth nothing. */
                    caught: observed.injected_reached_the_transport === true && delta >= 1,
                    observed
                };
            });
        }
    },

    {
        id: 'P6-wrong-but-recognised-destination',
        title: 'the declared output destination is recognised but is not the one consumed',
        fault: 'wrong-but-recognized output destination',
        legs: ['Leg 6 coverage half', 'genai-preprocessor.js § WIRING step 7'],
        contracts: ['H4-output-destination', 'C-DESTINATION-NOT-FAIL-CLOSED'],
        async good() {
            return withService({}, async (svc) => {
                const instance = makeInstance({ baseUrl: svc.url });
                const run = runHookInExtensionPoint({
                    hookSource: HOOK_SOURCE, instance, input: SUBMITTED,
                    declared: 'outputs_text', consumed: 'outputs_text', skill: SKILL
                });
                const consumed = String(run.consumedValue === undefined ? '' : run.consumedValue);
                return {
                    pass: run.raised === null && consumed.indexOf(CANARY) === -1 &&
                        consumed.indexOf('[CANARY_1]') !== -1,
                    observed: {
                        raised: run.raised ? String(run.raised.message) : null,
                        canary_in_consumed_slot: consumed.indexOf(CANARY) !== -1
                    }
                };
            });
        },
        async seeded() {
            return withService({}, async (svc) => {
                const instance = makeInstance({ baseUrl: svc.url });
                /* The hook is TOLD `bare_output`; the stub platform READS
                 * `outputs.text`. The hook writes, re-reads and verifies its own
                 * declared destination perfectly — and returns normally, while
                 * the slot the platform consumes still holds the raw
                 * submission. Nothing in-process can see this; only an outside
                 * observer looking at the consumed slot can, which is why the
                 * instance-side equivalent is Leg 6's COVERAGE half and not a
                 * code change. */
                const run = runHookInExtensionPoint({
                    hookSource: HOOK_SOURCE, instance, input: SUBMITTED,
                    declared: 'bare_output', consumed: 'outputs_text', skill: SKILL
                });
                const consumed = String(run.consumedValue === undefined ? '' : run.consumedValue);
                const row = lastRow(instance);
                const observed = {
                    hook_raised: run.raised ? String(run.raised.message) : null,
                    declared_slot_holds_sanitized:
                        String(run.context.output || '').indexOf('[CANARY_1]') !== -1,
                    canary_in_consumed_slot: consumed.indexOf(CANARY) !== -1,
                    /* And the run looks entirely healthy from the inside: a
                     * covered evidence row, a usable cert_id_partial. That is
                     * the whole danger. */
                    evidence_outcome: row && row.outcome
                };
                return {
                    caught: observed.hook_raised === null &&
                        observed.declared_slot_holds_sanitized === true &&
                        observed.canary_in_consumed_slot === true &&
                        observed.evidence_outcome === 'covered',
                    observed
                };
            });
        }
    },

    {
        id: 'P7-blocked-run-raises-and-publishes-nothing',
        title: 'a blocked decision raises under its own prefix and writes no destination',
        fault: null,
        legs: ['Leg 6, outcome (a) vs a wiring failure'],
        contracts: ['H3-raise-aborts-run', 'C-ERROR-DISCRIMINATOR'],
        /* Not one of the six, but the discriminator Leg 6 depends on: a real
         * block must say `skill run blocked:` and a wiring failure must say
         * `hook could not publish its output:`. An observer who cannot tell
         * them apart scores a broken hook as "blocking works". */
        async good() {
            const port = await closedPort();
            const instance = makeInstance({
                baseUrl: 'http://127.0.0.1:' + port, timeoutMs: 4000
            });
            const run = runHookInExtensionPoint({
                hookSource: HOOK_SOURCE, instance, input: SUBMITTED,
                declared: 'bare_output', consumed: 'bare_output', skill: SKILL
            });
            const message = run.raised ? String(run.raised.message) : '';
            const row = lastRow(instance);
            const observed = {
                raised: message,
                uses_block_prefix: message.indexOf(LucairnSkillGuard.ERROR_PREFIX) === 0,
                uses_wiring_prefix: message.indexOf('hook could not publish its output') !== -1,
                /* The raise exits before the publish, so the slot still holds
                 * what the extension point handed in — the ORIGINAL submitted
                 * text. That is the hook header's own note about outcome (b),
                 * made observable. */
                consumed_slot_still_raw: run.consumedValue === SUBMITTED,
                evidence_outcome: row && row.outcome
            };
            return {
                pass: !!run.raised && observed.uses_block_prefix === true &&
                    observed.uses_wiring_prefix === false &&
                    observed.consumed_slot_still_raw === true &&
                    observed.evidence_outcome === 'blocked',
                observed
            };
        }
    }
];

module.exports = { probes, CANARY, SUBMITTED, SKILL };
