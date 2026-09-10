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
├── src/
│   ├── script_includes/
│   │   ├── LucairnSha256.js         pure-JS SHA-256 (hex) — see "Why pure JS" below
│   │   ├── LucairnConfig.js         properties + per-skill policy, fail-closed defaults
│   │   ├── LucairnEvidence.js       writes evidence rows
│   │   ├── LucairnClient.js         RESTMessageV2 wrapper, never throws
│   │   └── LucairnNowAssistAdapter.js   the entry point: protect() and seal()
│   └── records/
│       ├── tables.md                the two tables, field by field
│       ├── properties.md            every system property
│       └── connection-and-credential-alias.md   alias, connection, credential, REST message
└── test/                            Node unit tests + platform fakes
```

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
{ "cert_id": "cert_…", "cert_url": "https://…/api/v1/veil/certificate/…", "cert_tier": "input-shield" }
```

### Errors

```jsonc
{ "error": "missing_api_key", "message": "…", "hint": "…" }
```

`LucairnClient` treats every non-2xx, every transport error, and every 200 whose
body is not the shape above as a failure. A 200 with an unrecognised shape is
**not** a success: treating it as one would forward whatever came back — possibly
the raw text — as if it had been sanitized.

### Why pure-JS SHA-256

The seal call requires `sha256:<64 lowercase hex>`. The digest helpers documented
for scoped applications return base64, and hex availability differs by release.
Rather than guess a platform API we cannot verify before the instance test,
`LucairnSha256` is self-contained and unit-tested against the FIPS 180-4 vectors
and differentially against Node's own `crypto`. If a hex-capable platform digest
is confirmed during the PDI run, swapping one function body is the whole change.

---

## Known gap: the `vendor` field

The seal call accepts exactly three vendor values: `anthropic`, `openai`,
`google`. **None of them names the model behind a Now Assist deployment.**

The application does not guess. `lucairn.now_assist.vendor` has no default; an
unset value fails validation, and a failed validation fails closed. You must set
it deliberately and record why.

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

3. **Create five Script Includes**, one per file in `src/script_includes/`. Name
   each one after the file (`LucairnSha256`, `LucairnConfig`, `LucairnEvidence`,
   `LucairnClient`, `LucairnNowAssistAdapter`) and paste the file contents
   verbatim. Leave *Client callable* unchecked on all five. The trailing
   `module.exports` guard is inert on the instance — there is no `module` global
   in the platform runtime — and is what lets the same file run under the local
   test harness.

4. **Create the system properties** listed in
   [`src/records/properties.md`](src/records/properties.md). `…api_key` must be
   type **password2**, not string.

5. **Create the connection, credential, alias and REST Message** per
   [`src/records/connection-and-credential-alias.md`](src/records/connection-and-credential-alias.md).

6. **Do not load production data.** Use `fixtures/synthetic-incidents.json`. The
   fixtures are invented, and every fixture email sits on a reserved `.test`
   domain that cannot resolve — there is a unit test asserting that.

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

### Leg 2 — fault injection: connection refused (fail-closed)

Point the connection at a host that will not answer, keeping everything else
identical:

- **rest_message mode:** edit the HTTP(s) Connection record's Connection URL to
  `https://lucairn-does-not-resolve.invalid`.
- **endpoint mode:** set `lucairn.now_assist.base_url` to the same value.

Re-run the Leg 1 script.

**Expect:**
- `allowed=false`, `coverage=uncovered`, `textForSkill` empty
- `r.error.code = lucairn_service_unreachable`
- `r.error.failure_class = connection_refused`
- exactly one new evidence row, `outcome = blocked`, `fail_open_override = false`
- **no seal call is attempted** — `s.sealed=false` with
  `error.code = lucairn_run_not_covered`

The point of this leg is that the block is *observed*, not asserted by a unit
test. Restore the URL afterwards and re-run Leg 1 to confirm you are back to
green.

### Leg 3 — fault injection: timeout (fail-closed)

Set `lucairn.now_assist.timeout_ms` to `1` and re-run the Leg 1 script.

**Expect:** the same block as Leg 2, but with
`r.error.failure_class = timeout` and a `blocked` evidence row whose
`failure_class` is `timeout`. Restore the timeout to `30000` afterwards.

> If the class comes back `unknown` rather than `timeout`, the run was still
> blocked — classification is diagnostic only and never gates the decision. Add
> the observed error text to `LucairnClient.TIMEOUT_MARKERS` and note it in the
> gate record.

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

### Leg 5 — no submitted content in the evidence table

Query the evidence table for the fixture name, the fixture email, and a
placeholder token. **Expect zero rows** for each — evidence rows carry counts,
identifiers and durations, never content.

---

## Run the unit tests locally

No dependencies, no install step. Node 18 or newer:

```bash
cd servicenow
node --test "test/*.test.js"
```

The suite covers the sanitize and seal request shapes, both fault classes,
fail-closed on every failure path, the fail-open override and its evidence row,
the refusal to seal an uncovered run, the refusal to invent a response hash, and
guards asserting that no key or submitted content leaks into a result object or
an evidence row.

These are unit tests against faked platform objects. They constrain the
adapter's own logic; they say nothing about ServiceNow's behaviour. That is what
the PDI runbook above is for.

---

## Versioning

`servicenow/VERSION` tracks the Store application, and moves **independently of
the kit's own `VERSION`**. A kit release does not imply a Store release and a
Store release does not imply a kit release; do not tie the two numbers together
or derive one from the other. When you cut a Store version, record the
ServiceNow instance family and patch level it was built and tested on — the
mechanisms this application depends on are release-sensitive.
