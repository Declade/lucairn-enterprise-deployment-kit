# The falsification probe kit — runbook

```bash
cd servicenow
node probes/run-probes.js          # human-readable, exit 1 on any failure
node probes/run-probes.js --json   # the same verdicts, machine-readable
```

It also runs inside the kit's own gate, as `test/probes.test.js`, so a probe
that stops catching its fault fails `make test` rather than rotting quietly.

---

## What this kit is for

The adapter's unit tests prove what the code does with a decision. They cannot
prove that the decision is *reached* when a real socket is refused, a real
response arrives too late, or an audit row genuinely fails to store. Each of
those used to be a scripted object returning a string we wrote.

So the probes seed **real faults** against **documented-shape stubs** and check
that the fail-closed outcome actually happens:

- **Real refusal** — a port that was bound long enough to learn its number and
  then released, so the connection is genuinely refused by the kernel.
- **Real timeout** — a stub that accepts the connection and answers well past
  the budget. (README § Leg 3 warns against `timeout_ms = 1` for the same
  reason: a budget that expires before the socket opens records a *setting*, not
  an observed timeout.)
- **Both transport-error modes** — `RESTMessageV2` raises on some releases and
  returns an error-flagged response on others, and neither is verified for the
  target release. A probe that exercised one would have tested one release
  family's behaviour and reported it as the adapter's.

## The rule every probe obeys

Each probe is a **pair**:

| half | what it does | what must happen |
|---|---|---|
| `good()` | the fault is **not** seeded | the probe reports **no** finding |
| `seeded()` | the fault **is** seeded | the probe **catches** it |

A probe that fires on the good path is an alarm, and an alarm that is always on
proves nothing when it goes off. A probe that misses its own seeded fault is
decoration. The runner fails the kit unless **both** halves behave — which is
what makes "the probes catch these faults" a measured statement.

## The probes

| Probe | Seeded fault | Caught by observing | Settles on an instance at |
|---|---|---|---|
| `P0-good-path` | — (the good path itself) | covered run on all four destinations, sanitized text in the consumed slot, `input-shield` certificate minted and recorded | Leg 0, Leg 1, Leg 6 coverage half |
| `P1-missing-vendor` | missing vendor | blocked run, `lucairn_config_error`, a `blocked` row, **no request made at all**, and a message that names the property to set | Leg 1 |
| `P2-unsupported-vendor` | unsupported vendor | blocked run, `lucairn_config_error`, and a message that lists the three accepted values instead of mapping onto one | Leg 1 |
| `P3-connection-refused` | connection refusal | blocked run in **both** transport-error modes, empty `textForSkill`, a `blocked` row — and, per mode, every attempt reaching the socket layer with the kernel's own `ECONNREFUSED` and **zero arrivals** | Leg 2a / 2b |
| `P4-timeout` | timeout | blocked run in both modes — and, per mode, the request genuinely **arriving** (delta exactly 1) with the worker's timeout path firing, which is what separates a timeout from a refusal | Leg 3a |
| `P5-evidence-write-failure` | evidence-write failure | a fail-open override that BLOCKS with `lucairn_uncovered_run_unauditable`, and writes no row at all | Leg 4b |
| `P5b-covered-run-without-evidence-row` | evidence-write failure, certificate half | `sealed: false`, `lucairn_evidence_row_missing`, **and no seal call made** — the one-shot `cert_id_partial` is not spent on a refusal | Leg 4b, check 2 |
| `P5c-premature-seal-detection` | a seal request reaching the service anyway | the same detector P5b trusts must **see** an injected seal call | Leg 4b, check 2 |
| `P6-wrong-but-recognised-destination` | wrong-but-recognized output destination | the hook returns **normally**, its declared slot holds the sanitized text, and the **consumed** slot still holds the raw submission with the canary intact | Leg 6 coverage half |
| `P7-blocked-run-raises-and-publishes-nothing` | — | the raise carries `skill run blocked:` and **not** `hook could not publish its output:`, and the destination was never written | Leg 6, outcome (a) vs a wiring failure |

`P6` is the important one to read twice. It is the only fault in the list that
the application **cannot detect about itself**: the hook verifies the
destination it was *declared*, does it perfectly, and returns normally while the
destination the platform actually *consumes* still holds the raw submission. No
error, no annotation, no evidence row that looks any different. The probe only
catches it because the stub has ground truth about which slot is consumed — and
an instance does not hand you that. There, the equivalent is Leg 6's **coverage
half** (an allowed run whose summary is visibly sanitized) plus administrator-only
write authority on `lucairn.now_assist.output_destination`. Neither is code.

## What a green run does NOT mean

It does not mean anything about a ServiceNow instance.

The stubs implement the **documented shapes**: the Lucairn wire contract from
`../README.md` § Wire contract (which cites the live handlers by repository,
file and line), and the four extension-point destination hypotheses the hook
enumerates. Every one of the platform shapes is registered as
`instance-pending` in [`../contracts/instance-contracts.json`](../contracts/instance-contracts.json)
and is settled only by the runbook legs in `../README.md` § Verify on the PDI.

**Instance validation pending.** Say that, and nothing broader.

Two boundaries worth stating outright:

1. **Error text is Node's, not Rhino's.** The probes therefore accept on the
   *fail-closed outcome* — a blocked run plus its evidence row — and only
   **record** the failure classification. That is the same rule README § Leg 2
   and § Leg 3 state for the instance: classification is diagnostic and never
   gates the decision, and an unrecognised marker is a gate-record item, not a
   failure.

   What the probes *do* assert, and what they deliberately do not, is worth
   being exact about. A review gate produced two counterexamples against the
   first version of this kit, and both came from asking the wrong witness:

   - **Aggregates cannot attribute.** "Was the connection accepted?" was a
     cumulative arrival count against a stub shared by both transport-error
     modes, so one mode's arrival credited the other — an accepted timeout plus
     a refusal that never arrived scored as a clean timeout catch in both. Every
     arrival is now a **per-attempt delta**.
   - **A classifier is not evidence.** The adapter's failure class is a
     substring match that degrades to `unknown`, which is right for a decision
     that blocks either way and useless as proof. A probe worker that failed to
     *start* produced a blocked run and a transport-looking label, and scored as
     a caught connection refusal. Fault provenance is now **structural**: the
     transport layer reports whether a socket attempt happened at all (`kind`),
     the runtime's own errno (`code`), and whether the timeout path fired — and
     a harness failure can never score as a caught fault.

   The same rule governs absence. A failed telemetry read used to return an
   empty list, so `P5b`'s "no seal call was made" was a subtraction of
   fabricated zeros — it passed while a real seal invocation had gone through.
   Telemetry unavailability is now a loud probe FAILURE, and `P5c` exists so
   that the detector behind every absence claim is itself falsifiable.
2. **There is no `--live` mode, deliberately.** The on-instance work is the
   runbook, executed by hand, with its observables written into a gate record. A
   flag that pretended to run these probes against an instance would be the
   thing this whole directory exists to avoid.

## Layout

```
probes/
├── README.md               this file
├── run-probes.js           the CLI; dry-run is its only mode
├── probes.js               the probe definitions — one good()/seeded() pair each
└── lib/
    ├── service-stub.js         lifecycle for the Lucairn service stub + closedPort()
    ├── service-stub-server.js  that stub, as its own PROCESS (see below)
    ├── sync-http.js            synchronous HTTP + the RESTMessageV2 shim
    └── sync-http-worker.js     one blocking round trip, in a child process
```

**Why two extra processes.** `RESTMessageV2.execute()` blocks on the instance,
so the probe kit blocks its own process for a whole round trip. A stub server
living in that same process could never answer — its event loop is the blocked
one. The first version of the kit deadlocked exactly so. The worker gives the
adapter a genuinely synchronous transport over a real socket; the stub server
gets its own process so it can answer while the caller is blocked.
