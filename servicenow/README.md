# Lucairn for Now Assist

A ServiceNow scoped application that sanitizes the fields submitted to a Now
Assist skill before the skill runs, and records what happened on every run.

**Status: prototype skeleton.** The code, the tests and the record
specifications are complete and locally verified. The ServiceNow-side mechanisms
they depend on are **hypotheses until they are executed on an instance** — see
[Verify on the PDI](#verify-on-the-pdi), which is the falsifier for each one.
Nothing here has run against a live instance yet.

PRD: `Opus Advisor/specs/2026-09/prd-2026-09-10-lucairn-for-now-assist-addon.md`,
Slice 1.

---

## What it claims, precisely

When a run is covered, the application obtains an **input-shield certificate**
from the Lucairn service. That certificate attests exactly one thing:

> the sanitizer processed the submitted fields before the skill ran.

It does not attest what ServiceNow's own inference ultimately contained, and it
is not a coverage claim over a whole Now Assist interaction. Do not restate it
more strongly in a demo, a deck, or customer copy.

Evidence rows are separate from certificates. A row says what this application
did on one run — covered, blocked, or ran uncovered. See
[`src/records/tables.md`](src/records/tables.md).

---

## Fail-closed by default

Any failure — the service unreachable, a timeout, a non-2xx, a response shape we
do not recognise, or incomplete configuration — **blocks the skill run** and
writes a `blocked` evidence row.

An administrator can flip one named skill to fail-open by adding a policy row
(`src/records/tables.md` § 1). That skill then runs on **raw** content when
protection fails, and an `uncovered_run` evidence row records the fact.

**The evidence row is the precondition, not a side effect.** What the override
authorises is an *audited* unprotected run. If the `uncovered_run` row cannot be
stored, the run is **blocked** instead — an unprotected run that nobody can find
afterwards is not the thing that was authorised. Leg 4b below measures this.

Why the default is this way round: in Lucairn's other integrations, a client-side
failure is backstopped by the Lucairn service, which still sanitizes before any
model sees the text. That backstop does not exist here — on this path the
adapter is the only layer in front of the model. A silent fail-open would mean
raw content reaching the model with nothing recording that it happened.

Two failure classes are handled and tested separately, because they look
different in an evidence row and lead to different fixes: **connection refused**
(wrong URL, blocked egress, service down) and **timeout** (service reachable but
slow, or the timeout is set too tight).

---

## Layout

```
servicenow/
├── README.md                        this file
├── VERSION                          Store-app version (independent of the kit's VERSION)
├── package.json                     local test harness only; not shipped to an instance
├── fixtures/
│   └── synthetic-incidents.json     invented incidents used by tests and the runbook
├── run-tests.sh                     runs the unit tests inside the kit's `make test`
├── src/
│   ├── script_includes/
│   │   ├── LucairnSha256.js         pure-JS SHA-256 (hex) — see "Why pure JS" below
│   │   ├── LucairnConfig.js         properties + per-skill policy, fail-closed defaults
│   │   ├── LucairnEvidence.js       writes evidence rows
│   │   ├── LucairnClient.js         RESTMessageV2 wrapper, never throws
│   │   ├── LucairnNowAssistAdapter.js   the decision: protect() and seal()
│   │   └── LucairnSkillGuard.js     the outcome: turns a decision into a blocked run
│   ├── hooks/
│   │   └── genai-preprocessor.js    ⚠️ paste-in stub, wiring is a PDI-time step
│   └── records/
│       ├── tables.md                the two tables, field by field
│       ├── properties.md            every system property
│       └── connection-and-credential-alias.md   alias, connection, credential, REST message
└── test/                            Node unit tests + platform fakes
```

### The decision and the outcome are two different files

`LucairnNowAssistAdapter` decides whether a run may proceed and on what text.
`LucairnSkillGuard` turns that decision into what happens to the skill run —
raising when the answer is no, annotating when an override is in force.

They are separate because the first is proven and the second is not. The
adapter's behaviour is exercised by unit tests against faked platform objects.
Whether a raise from a preprocessor hook actually stops a Now Assist skill run
is a **hypothesis** that only an instance can settle: see Leg 6 below, and the
header of `src/script_includes/LucairnSkillGuard.js` for the three possible
outcomes and what each one means for the claim.

### Why the source is `.js` files and not an update-set XML

An update-set XML that names one field wrong imports silently wrong. Nothing in
this directory has been executed on an instance yet, so a hand-written XML would
be a guess dressed up as an artefact. Instead: the sources are complete and
tested, the record specifications are exact, and **you build the app once on the
PDI and export the update set from there** — which is the artefact that then
travels to other instances.

---

## Wire contract

Two calls against the Lucairn service. Both are `POST`, both `application/json`,
both authenticated with the customer's own `lcr_live_` key.

### `POST /api/v1/sanitize-only`

```jsonc
// request
{ "text": "…the submitted fields…", "client_id": "lucairn-for-now-assist" }

// 200
{
  "sanitized_text":     "…with placeholders…",
  "placeholder_map_id": "pmap_…",
  "manifest": {
    "redaction_count":     { "person_name": 1, "email": 1 },
    "categories_triggered": ["person_name", "email"],
    "layers_active":        ["…"],
    "sanitizer_version":    "…"
  },
  "cert_id_partial": "cert_partial_…",
  "expires_at":      "2026-09-10T12:05:00Z"
}
```

`cert_id_partial` is valid for **five minutes** and is consumed by exactly one
seal call. A second seal with the same value returns 404.

### `POST /api/v1/sensitive-mode/seal-cert`

```jsonc
// request
{
  "cert_id_partial":       "cert_partial_…",
  "request_content_hash":  "sha256:<64 lowercase hex>",   // bytes handed to the skill
  "response_content_hash": "sha256:<64 lowercase hex>",   // bytes the skill produced
  "vendor":                "openai",                       // one of: anthropic | openai | google
  "tool_name":             "ServiceNow Now Assist — Incident summarization"
}

// 200
{ "cert_id": "cert_…", "cert_url": "https://…/verify?id=<request_id>", "cert_tier": "input-shield" }
```

`cert_url` is a **public verification page**, `<base>/verify?id=<request_id>` —
not a certificate-retrieval API path. An earlier version of this section showed
`/api/v1/veil/certificate/…`, which is a different endpoint and would have sent
anyone following the doc to the wrong URL. The shape here matches the live
handler (`dual-sandbox-architecture sensitive_mode.go:1541`).

`cert_tier` is always `input-shield` on this endpoint, and the adapter treats any
other value as a contract violation rather than as a better certificate — a
`full-chain` tier asserts an isolated inference path this integration does not
have. See `LucairnNowAssistAdapter.CERT_TIER`.

### Errors

```jsonc
{ "error": "missing_api_key", "message": "…", "hint": "…" }
```

`LucairnClient` treats every non-2xx, every transport error, and every 200 whose
body is not the shape above as a failure. A 200 with an unrecognised shape is
**not** a success: treating it as one would forward whatever came back — possibly
the raw text — as if it had been sanitized. Presence is not enough, either:
`placeholder_map_id: true` and `cert_id_partial: {}` are present and truthy, and
both are rejected. Types and emptiness are checked, not assumed.

**What survives into an evidence row from an error is nothing the service or the
platform wrote.** The `message` on a failure is assembled from a fixed
vocabulary in `LucairnClient` (`REASON`, `STAGE`) plus the HTTP status; the
upstream `error` code is echoed only when it is a member of
`LucairnClient.API_ERROR_CODES`. Exception text and upstream `message` bodies are
read to classify a failure and then discarded — they can contain the submitted
text or an `Authorization` value, and there is no sanitizer for arbitrary
upstream strings, so none is carried.

### Why pure-JS SHA-256

The seal call requires `sha256:<64 lowercase hex>`.

*Hypothesis:* the digest helpers documented for scoped applications return
base64, and hex availability differs by release. That has not been verified on
an instance and is the reason for the choice, not a finding — treat it as
"unverified, so not depended on" rather than as a statement about any particular
release. Rather than guess a platform API we cannot check before the instance
test, `LucairnSha256` is self-contained and unit-tested against the FIPS 180-4
vectors and differentially against Node's own `crypto`. If a hex-capable
platform digest is confirmed during the PDI run, swapping one function body is
the whole change.

`tool_name` is capped at **256 UTF-8 bytes**, which is what the service
enforces. A JavaScript string length counts UTF-16 units, so a character cap
would let 200 non-ASCII characters (400 bytes) through to a guaranteed HTTP 400.
`LucairnClient.capUtf8Bytes` cuts on the byte budget without splitting a
character or a surrogate pair.

---

## Known gap: the `vendor` field

The seal call accepts exactly three vendor values: `anthropic`, `openai`,
`google`. **None of them names the model behind a Now Assist deployment.**

The application does not guess. `lucairn.now_assist.vendor` has no default, and
**it must be set** — validation runs before the sanitize call, not before the
seal call, so an unset vendor does not mean "sanitize without a certificate". It
means every protected run is blocked; and for any skill an administrator has
flipped fail-open, it means the run proceeds on **raw** content with an
`uncovered_run` evidence row. Neither configuration sanitizes anything. The full
table is in [`src/records/properties.md`](src/records/properties.md).

For the PDI plumbing test below, set it to `openai` so the round trip can be
proven end to end, and treat that as a provenance placeholder for the plumbing —
not as a statement about which vendor runs the inference.

Extending the accepted vendor set is a change to the Lucairn service's own
contract and is out of scope here; it needs its own design pass.

---

## Build on the PDI

1. **Create the application.** Studio → Create Application → name
   `Lucairn for Now Assist`. Let ServiceNow assign the scope prefix; it will not
   be `x_lcrn_…` on your instance. Wherever a name in `src/` starts with
   `x_lcrn_now_assist`, substitute your assigned scope:
   - `LucairnConfig.TABLE_SKILL_POLICY` in `src/script_includes/LucairnConfig.js`
   - `LucairnEvidence.TABLE` in `src/script_includes/LucairnEvidence.js`
   - the role names in `src/records/connection-and-credential-alias.md` § 5

2. **Create the two tables** exactly as specified in
   [`src/records/tables.md`](src/records/tables.md).

3. **Create six Script Includes**, one per file in `src/script_includes/`. Name
   each one after the file (`LucairnSha256`, `LucairnConfig`, `LucairnEvidence`,
   `LucairnClient`, `LucairnNowAssistAdapter`, `LucairnSkillGuard`) and paste the
   file contents verbatim. Leave *Client callable* unchecked on all six.

   Each file ends with a `typeof module !== 'undefined'` guard, which is what
   lets the same source run under the local test harness. *Hypothesis:* the
   platform's server-side runtime has no `module` global, so the guard is inert
   there — the guard is written not to depend on that being true (it tests for
   the global rather than assuming its absence), and Leg 1 is what actually
   confirms the file loads.

4. **Create the system properties** listed in
   [`src/records/properties.md`](src/records/properties.md). `…api_key` must be
   type **password2**, not string.

5. **Create the connection, credential, alias and REST Message** per
   [`src/records/connection-and-credential-alias.md`](src/records/connection-and-credential-alias.md).

6. **Do not load production data.** Use `fixtures/synthetic-incidents.json`. The
   fixtures are invented, and every fixture email sits on a reserved `.test`
   domain that cannot resolve — there is a unit test asserting that.

7. **Set the ACLs** exactly as specified in
   [`src/records/tables.md`](src/records/tables.md) § "Access control", for both
   tables. A user who can insert a skill-policy row can turn protection off; a
   user who can insert an evidence row can forge the record of a run.

8. **Check outbound HTTP logging** before any instance carries real data. At log
   level `all` the platform records outbound request and response bodies —
   including the submitted text on its way to the sanitizer — into a platform log
   table this application does not control. `tables.md` § "Outbound HTTP logging"
   has the detail.

9. **The preprocessor hook is wired last**, after Leg 1 is green — see
   `src/hooks/genai-preprocessor.js` § WIRING and Leg 6 below. Everything about
   that hook is a hypothesis; wiring it on top of an unproven round trip makes
   both undiagnosable.

### Export the update set

System Update Sets → Local Update Sets → open the set that captured the work
above → **Mark as Complete** → related link **Export to XML**. Commit the
resulting `sys_remote_update_set_*.xml` alongside this directory once it exists,
with the instance family and patch level recorded in the commit message.

### Import into another instance

Retrieved Update Sets → **Import Update Set from XML** → upload → open the
retrieved set → **Preview Update Set** → resolve any collisions → **Commit
Update Set**. Then redo step 4 (properties) and step 5 (credential) by hand:
neither the API key nor the connection URL should travel inside an update set.

---

## Verify on the PDI

Run these **in order**. Each leg names what you should observe; a leg that does
not produce its observable is a finding, not something to work around. Record
the actual outputs in the gate record.

Legs 0–5 exercise the **adapter**: does the round trip work, and does a failure
block. **Leg 6 is the one that settles the PRD's fail-closed acceptance
criterion**, because it is the only leg that measures a blocked *skill run*
rather than a blocked adapter return. Do not treat Legs 2–4 passing as evidence
that a skill run can be stopped — they are evidence about a different thing.

Set up a shell first. `LUCAIRN_BASE_URL` is the base URL for the Lucairn account
you are testing against; `LUCAIRN_API_KEY` is that account's own `lcr_live_` key.

```bash
export LUCAIRN_BASE_URL="https://…"          # the account's Lucairn service base URL
export LUCAIRN_API_KEY="lcr_live_…"          # never paste this into a ticket or a doc
```

### Leg 0 — the two calls work at all, from a shell

Establishes that the account, the key and the endpoints are fine before any
ServiceNow variable is in play. If Leg 0 fails, nothing after it is diagnostic.

```bash
# 0a — sanitize a synthetic incident description
curl -sS -X POST "$LUCAIRN_BASE_URL/api/v1/sanitize-only" \
  -H "Authorization: Bearer $LUCAIRN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "text": "Reported by Brannagh Oduya-Kestrel (brannagh.oduya-kestrel@northmarrow-example.test, +49 151 0000 1234). Her ThinkPad in office 4.12 shows a firmware error after last night'"'"'s patch. Cost centre CC-88231.",
        "client_id": "lucairn-for-now-assist"
      }' | tee /tmp/lucairn-sanitize.json
```

**Expect:** HTTP 200; `sanitized_text` with the name, email and phone replaced by
bracketed placeholders; a non-empty `cert_id_partial`; `expires_at` about five
minutes out. **Record** the wall-clock time of this call.

```bash
# 0b — seal, within five minutes of 0a
PARTIAL=$(python3 -c 'import json;print(json.load(open("/tmp/lucairn-sanitize.json"))["cert_id_partial"])')
SANITIZED=$(python3 -c 'import json;print(json.load(open("/tmp/lucairn-sanitize.json"))["sanitized_text"],end="")')
RESPONSE_TEXT='Summary: a laptop fails to boot after a patch window; firmware error reported.'

REQ_HASH="sha256:$(printf '%s' "$SANITIZED"      | shasum -a 256 | cut -d' ' -f1)"
RESP_HASH="sha256:$(printf '%s' "$RESPONSE_TEXT" | shasum -a 256 | cut -d' ' -f1)"

curl -sS -X POST "$LUCAIRN_BASE_URL/api/v1/sensitive-mode/seal-cert" \
  -H "Authorization: Bearer $LUCAIRN_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"cert_id_partial\":\"$PARTIAL\",
       \"request_content_hash\":\"$REQ_HASH\",
       \"response_content_hash\":\"$RESP_HASH\",
       \"vendor\":\"openai\",
       \"tool_name\":\"ServiceNow Now Assist — Incident summarization\"}" | tee /tmp/lucairn-seal.json
```

**Expect:** HTTP 200; `cert_tier` = `input-shield`; a `cert_url` that resolves:

```bash
curl -sSI "$(python3 -c 'import json;print(json.load(open("/tmp/lucairn-seal.json"))["cert_url"])')" | head -1
```

### Leg 1 — the same round trip from the PDI

Studio → Scripts - Background, in the application scope:

```javascript
var adapter = new LucairnNowAssistAdapter();
var text = 'Reported by Brannagh Oduya-Kestrel (brannagh.oduya-kestrel@northmarrow-example.test, ' +
           '+49 151 0000 1234). Her ThinkPad in office 4.12 shows a firmware error.';

var t0 = new Date().getTime();
var r = adapter.protect({ skill: 'Incident summarization', text: text });
gs.info('protect -> allowed=' + r.allowed + ' coverage=' + r.coverage +
        ' partial=' + r.certIdPartial + ' ms=' + r.durationMs);
gs.info('sanitized: ' + r.textForSkill);

var s = adapter.seal({
    protectResult: r,
    responseText: 'Summary: a laptop fails to boot after a patch window.'
});
gs.info('seal -> sealed=' + s.sealed + ' cert=' + s.certUrl + ' ms=' + s.durationMs);
gs.info('total wall clock ms: ' + (new Date().getTime() - t0));
```

**Expect:** `allowed=true`, `coverage=covered`, a sanitized string with no
fixture name/email/phone left in it, `sealed=true`, a resolvable `cert_url`.
**Record the total wall clock.** For reference, the comparable Lucairn demo path
measures 4–7 s, and about 9.6 s with the heaviest sanitizer layer on.

Then check the evidence table: exactly one row, `outcome = covered`,
`redaction_total` matching the manifest, `cert_id` and `cert_url` populated.

### Leg 2 — fault injection: the service cannot be reached (fail-closed)

⚠️ **Two different faults, run both.** A `.invalid` hostname never resolves, so
it exercises **DNS failure**; an address that resolves but refuses the TCP
connection exercises **connection refusal**. The adapter labels both
`connection_refused` — a deliberate simplification, since the fail-closed
decision is identical — but they are different network events, they produce
different exception text, and a recipe that runs only one has tested only one.
The round-1 gate flagged the original recipe for conflating them.

Run **2a** and **2b**, keeping everything else identical.

**2a — name resolution fails.** Set the URL to a hostname that cannot resolve:

- **rest_message mode:** edit the HTTP(s) Connection record's Connection URL to
  `https://lucairn-does-not-resolve.invalid`.
- **endpoint mode:** set `lucairn.now_assist.base_url` to the same value.

**2b — the connection is refused.** Set the URL to an address that resolves and
answers with a TCP reset. A closed port on a reachable host is the simplest
one — e.g. `https://127.0.0.1:9` on the instance's own egress path, or any host
you control with nothing listening on the chosen port. Verify from a shell first
that the port really refuses (`nc -vz <host> <port>` should say *refused*, not
*timed out*): a firewall that drops packets silently produces a **timeout**, and
you would be re-running Leg 3 by accident.

Re-run the Leg 1 script after each.

**Expect (both 2a and 2b):**
- `allowed=false`, `coverage=uncovered`, `textForSkill` empty
- `r.error.code = lucairn_service_unreachable`
- `r.error.failure_class = connection_refused`
- exactly one new evidence row, `outcome = blocked`, `fail_open_override = false`
- **no seal call is attempted** — `s.sealed=false` with
  `error.code = lucairn_run_not_covered`

**Record the observed error text for each of 2a and 2b separately.** If either
comes back `unknown` rather than `connection_refused`, the run was still blocked
— classification is diagnostic only and never gates the decision — but add the
observed text to `LucairnClient.REFUSED_MARKERS` and note it in the gate record.

The point of this leg is that the block is *observed*, not asserted by a unit
test. Restore the URL afterwards and re-run Leg 1 to confirm you are back to
green.

### Leg 3 — fault injection: timeout (fail-closed)

⚠️ **Do not settle for `timeout_ms = 1`.** A 1 ms budget can abort before the
socket is even opened, which may surface as a connection-level error rather than
a read timeout — you would have recorded a *setting*, not an observed timeout.

**3a — a controlled slow endpoint (the real case).** Point the connection at an
endpoint that accepts the connection and then delays past the budget. Anything
you control will do; if nothing is available, a host that accepts TCP and never
replies works, provided you have confirmed it accepts rather than refuses.
Set `lucairn.now_assist.timeout_ms` to something short but realistic (e.g.
`2000`) and re-run the Leg 1 script.

**3b — the tight-budget variant.** Restore the real URL, set
`lucairn.now_assist.timeout_ms` to `1`, and re-run. Record what class comes
back. If it is `connection_refused` or `unknown` rather than `timeout`, that is
the expected consequence of 3a existing — note it and move on.

**Expect (3a):** the same block as Leg 2, with `r.error.failure_class = timeout`
and a `blocked` evidence row whose `failure_class` is `timeout`. Restore the
timeout to `45000` afterwards.

> If 3a's class comes back `unknown`, the run was still blocked — classification
> is diagnostic only. Add the observed error text to
> `LucairnClient.TIMEOUT_MARKERS` and note it in the gate record.

### Leg 4 — the fail-open override, and its audit trail

1. Insert a policy row: `skill_name = Incident summarization`, `active = true`,
   `fail_open = true`, with a justification.
2. Re-apply the Leg 2 fault (unreachable host).
3. Re-run the Leg 1 script.

**Expect:**
- `allowed=true`, `coverage=uncovered`
- `textForSkill` is the **raw** input — this is the whole point of the override,
  and the reason it is off by default
- a new evidence row with `outcome = uncovered_run`, `fail_open_override = true`,
  `failure_class = connection_refused`
- `s.sealed=false` with `error.code = lucairn_run_not_covered` — an uncovered
  run cannot be sealed into a certificate

Delete the policy row and restore the URL afterwards. Confirm the skill is back
to fail-closed by re-running Leg 2.

### Leg 4b — the override cannot outlive its own audit trail

Still with the fail-open policy row in place from Leg 4, make the evidence
insert fail: temporarily deny insert on `x_lcrn_now_assist_evidence` (revoke the
application's create ACL, or rename a required column so the insert errors).
Re-apply the Leg 2a fault and re-run the Leg 1 script.

**Expect:** `allowed=false`, `error.code = lucairn_uncovered_run_unauditable`,
`textForSkill` empty — the run is BLOCKED despite the fail-open override.

The override authorises an *audited* unprotected run. With no row there is no
audit, so what the administrator authorised is not what would have happened.
Restore the ACL/column afterwards and re-run Leg 4 to confirm the override works
again.

### Leg 5 — no submitted content in the evidence table

Query the evidence table for the fixture name, the fixture email, and a
placeholder token. **Expect zero rows** for each — evidence rows carry counts,
identifiers and durations, never content.

Then the harder version, which is where the round-1 gate found a real leak:
re-run Leg 2a with an endpoint whose **error response body quotes the request**
(any proxy that echoes the payload in its error page will do), and query the
evidence table again for the fixture name. **Expect zero rows.** The `message`
and `seal_message` fields are built from a fixed vocabulary, never from upstream
text — this leg is what proves that on the instance rather than in a unit test.

### Leg 6 — ⚠️ a blocked SKILL RUN, measured (not a blocked adapter return)

**This is the leg that settles the PRD's S1 fail-closed acceptance criterion.**
Legs 2–4 prove the *adapter* returns `allowed: false`. That is not the
acceptance criterion. The criterion is that the *skill run* is blocked, and
nothing proves that until a hook consumes the decision inside a real skill
execution.

**Prerequisite:** `LucairnSkillGuard` created (Build step 3) and the preprocessor
hook wired per `src/hooks/genai-preprocessor.js` § WIRING.

1. Re-apply the Leg 2a fault (unreachable host).
2. Do **not** run a background script. Open the **product UI** for the protected
   skill — the Now Assist experience an end user would use — and trigger the
   skill on a synthetic incident from `fixtures/synthetic-incidents.json`.
3. Observe what the *user* gets.

**Record which of these actually happened. All three are real outcomes.**

| Outcome | What you observe | What it means |
|---|---|---|
| **(a) blocked** | No summary. An error surfaces to the user, and a `blocked` evidence row exists with a matching `correlation_id`. | The preprocessor lane can enforce. The blocking claim is supported *for this skill, on this instance family and patch level* — say exactly that, and nothing broader. |
| **(b) not blocked** | A summary comes back anyway; the raise was logged and ignored, or swallowed. | **The blocking claim is dead.** The annotation path is the only surviving control. No packaging, deck or customer material may say the preprocessor blocks anything. |
| **(c) never invoked** | No evidence row appears at all for the UI-triggered run. | The hook is not on this skill's execution path. The preprocessor lane does not apply here; the P2 clone lane is the remaining option. |

Also record: the instance family and patch level, the extension-point table that
accepted the script, and which candidate tables did not exist. The mechanism is
release-sensitive and none of this transfers between releases by assumption.

**Falsifier, stated plainly:** if a summary comes back in step 3, the claim
"Lucairn blocks an unprotected Now Assist skill run" is FALSE, regardless of
what the unit tests say. The unit tests prove what this code does with a
decision; they cannot prove what ServiceNow does with this code. Only Leg 6 can,
and only for the skill and release it was run on.

**Then run the coverage half.** Restore the URL, re-run step 2, and check whether
the summary reflects sanitized input. If the model's output contains a fixture
name, the hook did not see all of the prompt — context appended after the hook
would never reach the sanitizer, and a certificate would then attest a fragment.
Note that a summary *omitting* a canary is **not** proof the model never received
it (PRD § Canary methodology); only the seeded-input matrix in Slice 3 can
address that, and it is out of scope for this leg.

---

## Run the unit tests locally

No dependencies, no install step. Node 18 or newer:

```bash
cd servicenow
node --test "test/*.test.js"
```

They also run inside the kit's own gate:

```bash
make test          # from the repository root; includes servicenow/run-tests.sh
```

`run-tests.sh` fails with a visible **`FAIL: NOT RUN`** if Node is absent or too
old, rather than letting the lane disappear. A test lane that cannot run must
not read as a pass.

The suite covers the sanitize and seal request shapes, both fault classes,
fail-closed on every failure path, the fail-open override and its evidence row,
the refusal to seal an uncovered run, the refusal to invent a response hash, and:

- **the evidence row as a precondition** — a fail-open override with a failing
  evidence insert must block, not proceed;
- **dropped query predicates** — a policy table missing a field cannot let
  another skill's override, or an inactive one, apply;
- **the malformed-body matrix** — truthy non-strings, empty strings, missing
  manifest/expiry, and a `cert_tier` other than `input-shield`;
- **error-flag preservation** — a known transport failure whose diagnostic call
  throws stays a failure;
- **diagnostic canaries** — an exception and an upstream error body, both loaded
  with a content canary and a bearer-key canary, asserted against the value
  actually **stored** in the evidence row;
- **the UTF-8 byte boundary** for `tool_name`, including surrogate pairs;
- **platform throws at the entry point** — `gs.getProperty` raising returns a
  blocked result rather than escaping.

Each of those was written against a defect the round-1 review gate found, and
each fails against the code as it was before the fix — a test that cannot fail
is not evidence.

These are unit tests against faked platform objects. They constrain the
adapter's own logic; they say nothing about ServiceNow's behaviour. That is what
the PDI runbook above is for — and Leg 6 in particular, which is the only thing
that can tell you whether a decision to block becomes a blocked skill run.

---

## Versioning

`servicenow/VERSION` tracks the Store application, and moves **independently of
the kit's own `VERSION`**. A kit release does not imply a Store release and a
Store release does not imply a kit release; do not tie the two numbers together
or derive one from the other. When you cut a Store version, record the
ServiceNow instance family and patch level it was built and tested on — the
mechanisms this application depends on are release-sensitive.
