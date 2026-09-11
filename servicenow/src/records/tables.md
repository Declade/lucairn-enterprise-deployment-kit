# Tables — Lucairn for Now Assist

Two tables. Both live inside the scoped application. Create them in Studio (or
System Definition → Tables) exactly as specified, then export the update set —
see `../../README.md` § "Build on the PDI".

Neither table stores submitted content, sanitized or raw. That is deliberate:
an evidence row must be safe to read, export and keep for as long as the
customer's retention policy says, without becoming a second copy of the data
the application exists to protect.

---

## 1. `x_lcrn_now_assist_skill_policy` — Protected skill policy

One row per Now Assist skill the application protects. **Absence of a row means
fail-closed**, so the table is an override list, not an enrolment list.

| Column label | Column name | Type | Max len | Default | Notes |
|---|---|---|---|---|---|
| Skill name | `skill_name` | String | 200 | — | Must match the skill name the caller passes to `protect()` **exactly, including case**. Mark **unique**. |
| Active | `active` | True/False | — | `true` | An inactive row is ignored entirely, including its fail-open flag. |
| Fail open | `fail_open` | True/False | — | `false` | `true` = if protection fails, run the skill on **raw** content and write an `uncovered_run` evidence row. |
| Justification | `justification` | String | 1000 | — | Why this skill is allowed to run unprotected. Required by process, not by the platform. |
| Approved by | `approved_by` | Reference → `sys_user` | — | — | Who signed off on the fail-open. |

### Why `skill_name` is compared case-sensitively

A ServiceNow query on a string field is case-insensitive, so a row reading
`incident summarization` would be *selected* by a lookup for
`Incident summarization`. The application re-reads the value off the returned
row and compares it exactly, so that row does **not** apply — the skill stays
fail-closed and a line lands in the system log naming both strings.

That is the safe direction (a near-miss row never turns protection off by
accident) but it is a real way to be confused while debugging: the row is
visibly there and visibly ignored. Copy the skill name rather than retyping it.

### Access control — specified, not suggested, and NOT yet verified

A user who can insert a row here can turn protection off for a skill. That makes
this table a privacy control, and "suggested ACL" is not a specification for one.
Create all of the following (round-1 gate advisory: ACL/outbound-log spec gaps).

> **⚠️ HYPOTHESIS — these rows are a specification to verify on the PDI, not a
> containment property this application has.** Two reasons they are not the same
> thing:
>
> 1. **Server-side script does not go through ACLs.** `GlideRecord` — which is
>    what `LucairnConfig` and `LucairnEvidence` use — is the *non-secure* API:
>    it does not evaluate ACLs. `GlideRecordSecure` does. So the "no role —
>    application code only" rows below describe what a *user* can do through the
>    UI, list, import set and Table API; they say nothing about what any other
>    scoped script running on the instance can do, and they are not what stops
>    this application's own code from writing.
> 2. Nothing here has been executed. No instance has had these ACLs created and
>    then had them tested against a user who should be refused.
>
> **PDI-time verification items** (record the result of each in the gate record;
> an unverified row is not a control):
>
> | # | Verify | How | Expected |
> |---|---|---|---|
> | V1 | The `create` ACL on the policy table refuses a user without `x_lcrn_now_assist_admin` | Impersonate a plain `itil` user, try to insert a `fail_open = true` row from the list view | Refused |
> | V2 | The same refusal holds over the **Table API** | Same user, `POST /api/now/table/x_lcrn_now_assist_skill_policy` | Refused (and refused again with web-service access unchecked) |
> | V3 | The evidence table refuses a hand-written `covered` row to every role | Impersonate the admin role, try to insert directly | Refused |
> | V4 | The application's own code can still insert evidence with those ACLs in place | Re-run Leg 1 | An evidence row lands |
> | V5 | Another scoped application cannot read the evidence table | A second scope's background script does a `GlideRecord` read | Refused by *Application Access*, which is the setting that actually carries this — not the ACLs |
> | V6 | The `lucairn.now_assist.output_destination` property refuses a write from a user without `x_lcrn_now_assist_admin` | Impersonate a plain `itil` user (and separately an `admin` without the application role); try to change the value from the System Properties list AND over `PUT /api/now/table/sys_properties/<sys_id>` | Refused in both surfaces |
>
> V5 is the one to run first if time is short: it is the containment claim most
> likely to be assumed and least likely to be tested.
>
> V6 is the one whose failure is SILENT. A wrong-but-recognised destination value
> does not raise: the hook verifies the destination it was declared, returns
> normally, and the platform consumes a slot that still holds the raw
> submission — no error, no annotation, no differing evidence row. Every other
> row on this list fails loudly; this one fails by publishing un-redacted content
> under a covered verdict. Rationale and the full value table:
> [`properties.md`](properties.md) § "`output_destination` — write authority".

| Operation | Required role | Why |
|---|---|---|
| `read` | `x_lcrn_now_assist_admin`, `x_lcrn_now_assist_auditor` | An auditor must be able to see which skills are fail-open without being able to change it. |
| `create` | `x_lcrn_now_assist_admin` | Inserting a `fail_open = true` row IS turning protection off. Creating must be as restricted as writing — an unspecified create ACL is the most common way a "write-protected" table turns out not to be. |
| `write` | `x_lcrn_now_assist_admin` | Flipping `fail_open` on an existing row. |
| `delete` | `x_lcrn_now_assist_admin` | Deleting a row returns the skill to fail-closed — safe in direction, but it erases the `justification` and `approved_by` that recorded the decision. |

Application access (the *Application Access* tab on the table record):

- **Accessible from:** *This application scope only*.
- **Can read / Can create / Can update / Can delete from other scopes:** all
  **unchecked**. No other scope has business writing a Lucairn policy row.
- **Allow access to this table via web services:** **unchecked** — a policy row
  should not be flippable over the Table API.

Grant `x_lcrn_now_assist_admin` the way you would grant any other privacy
control: named individuals, recorded, reviewed.

---

## 2. `x_lcrn_now_assist_evidence` — Run evidence

One row per protected skill run. Insert-only in normal operation; the
application updates a row exactly once, to attach certificate identifiers after
the skill has responded.

| Column label | Column name | Type | Max len | Notes |
|---|---|---|---|---|
| Outcome | `outcome` | Choice | 40 | `covered` · `blocked` · `uncovered_run` (see below) |
| Skill | `skill` | String | 200 | Now Assist skill name |
| Failure class | `failure_class` | Choice | 40 | `none` · `connection_refused` · `timeout` · `http_error` · `contract_error` · `config_error` · `unknown` |
| Message | `message` | String | 1000 | Short diagnostic. Never contains submitted content. |
| Correlation ID | `correlation_id` | String | 64 | Ties `protect()` and `seal()` together and into instance logs |
| Certificate ID | `cert_id` | String | 100 | Populated on a successful seal |
| Certificate URL | `cert_url` | URL | 1024 | Populated on a successful seal |
| Partial certificate ID | `cert_id_partial` | String | 100 | Returned by the sanitize call; consumed by the seal call |
| Duration (ms) | `duration_ms` | Integer | — | Wall clock of the sanitize call |
| Seal duration (ms) | `seal_duration_ms` | Integer | — | Wall clock of the seal call |
| Seal outcome | `seal_outcome` | Choice | 40 | `not_attempted` · `sealed` · `failed` (see below) |
| Seal failure class | `seal_failure_class` | Choice | 40 | Same value set as `failure_class`. `none` unless `seal_outcome = failed`. |
| Seal message | `seal_message` | String | 500 | Typed diagnostic for a failed seal. Never contains submitted content — see "What never lands here". |
| Redactions | `redaction_total` | Integer | — | Sum across all categories in the manifest |
| Layers active | `layers_active` | String | 255 | Comma-joined list reported by the sanitizer |
| Fail-open override | `fail_open_override` | True/False | — | `true` only on an `uncovered_run` row |
| Recorded at | `recorded_at` | String | 40 | Display-format timestamp written by the application |

### Outcome values, and what each one actually means

| Value | Meaning |
|---|---|
| `covered` | The sanitizer processed the submitted fields before the skill ran. If `cert_id` is set, an input-shield certificate exists for that run. |
| `blocked` | Protection could not be completed and the run was stopped. Nothing was sent to the skill. |
| `uncovered_run` | Protection could not be completed, the skill is configured fail-open, and **the run proceeded on raw content**. This row is the audit trail for that decision. |

### Seal outcome values

| Value | Meaning |
|---|---|
| `not_attempted` | `seal()` was never called for this run, or the run was never eligible (blocked / uncovered). |
| `sealed` | An input-shield certificate exists; `cert_id` and `cert_url` are populated. |
| `failed` | `seal()` was called and did not produce a certificate. `seal_failure_class` and `seal_message` say what happened. |

A `covered` row with an empty `cert_id` means the sanitize step succeeded but
the certificate was not sealed — the content was still protected; only the
certificate is missing. `seal_outcome` is what distinguishes "nobody ever tried
to seal this" from "sealing was tried and failed"; without it the two are the
same empty `cert_id`.

**There is no retry.** `cert_id_partial` is claimed atomically by the first seal
call that reaches the service, so a second attempt with the same value returns
404. Recovering a certificate means a fresh sanitize-only + seal flow over the
same content — and if the skill has already run, that flow certifies a new
submission, not the one that went uncertified. The `failed` row is the durable
record of the gap.

### What never lands here

`message` and `seal_message` are built from a fixed vocabulary in
`../script_includes/LucairnClient.js` (`REASON`, `STAGE`, `API_ERROR_CODES`)
plus an HTTP status code. Exception text, transport-error text and upstream
response bodies are read to *classify* a failure and then discarded — they are
never interpolated into a stored value. That is deliberate: the round-1 gate
probe fed the adapter an exception containing both a request body and a bearer
token, and both were persisted verbatim into an evidence row. The canary tests
in `../../test/client.test.js` and `../../test/adapter.test.js` assert on the
stored value, not on the returned one.

### What an evidence row is not

An evidence row is an instance-local record of what this application did. It is
not a certificate, and it is not an attestation about ServiceNow's own
inference. The certificate — when there is one — attests exactly one thing: the
sanitizer processed the submitted fields before the skill ran.

### Access control — evidence table

| Operation | Required role | Why |
|---|---|---|
| `read` | `x_lcrn_now_assist_admin`, `x_lcrn_now_assist_auditor` | An auditor reads evidence; that is the role's entire purpose. |
| `create` | *(no role — application code only)* | Rows are written by `LucairnEvidence` running in the application scope. Nobody should be able to hand-write an evidence row: a forged `covered` row is a forged claim that content was sanitized. |
| `write` | *(no role — application code only)* | The application updates a row exactly once, to record the seal outcome. |
| `delete` | *(no role)* | Deleting evidence removes the record of an unprotected run. If a retention rule is needed, implement it as a scheduled job under the application's own identity — not as a delete permission on a role. |

Application access: **This application scope only**; all cross-scope
read/create/update/delete **unchecked**; web-service access **unchecked**.

The same ⚠️ applies here as to the policy table above: these rows are a
specification awaiting PDI verification (items V3–V5), and "no role" constrains
users, not server-side script — `GlideRecord` is the non-secure API and does not
evaluate ACLs. Until V3–V5 have been run and recorded, do not describe the
evidence table as tamper-proof in any customer-facing material; describe it as
"insert-only by the application, with ACLs specified".

### ⚠️ Outbound HTTP logging can defeat all of the above

ServiceNow's own outbound-request logging is independent of anything this
application does. At log level **`all`**, the platform records outbound request
and response **bodies** — which for this integration means the submitted text on
its way to the sanitizer, in a platform log table with its own ACLs, retention
and export paths. The evidence table can be spotless while the payload sits in
an HTTP log.

- Keep outbound HTTP logging at **`elevated`** or lower for the Lucairn REST
  Message in any instance carrying real data.
- If you raise it to `all` to debug the round trip, do it on a non-production
  instance with synthetic fixtures only, and lower it again afterwards.
- Record the level you ran at in the gate record — a run at `all` is not
  evidence that the pipeline keeps content out of the instance.

Reference: ServiceNow's outbound HTTP request logging documentation
(`https://developer.servicenow.com/blog.do?p=/post/outbound-http-request-logging-in-detail/`).

### Retention

No retention rule ships with the application. Decide one with the customer and
add a table-rotation or scheduled-cleanup job to match their policy.
