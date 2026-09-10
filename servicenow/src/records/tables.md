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
| Skill name | `skill_name` | String | 200 | — | Must match the skill name the caller passes to `protect()`. Mark **unique**. |
| Active | `active` | True/False | — | `true` | An inactive row is ignored entirely, including its fail-open flag. |
| Fail open | `fail_open` | True/False | — | `false` | `true` = if protection fails, run the skill on **raw** content and write an `uncovered_run` evidence row. |
| Justification | `justification` | String | 1000 | — | Why this skill is allowed to run unprotected. Required by process, not by the platform. |
| Approved by | `approved_by` | Reference → `sys_user` | — | — | Who signed off on the fail-open. |

Application access: **not** accessible from other scopes for write. Only the
application's own code and an administrator should change a policy row.

Suggested ACL: write restricted to a dedicated `x_lcrn_now_assist_admin` role.
A user who can flip `fail_open` can turn protection off for a skill, so treat
that role the way you would treat any other privacy control.

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

A `covered` row with an empty `cert_id` means the sanitize step succeeded but
the certificate was not sealed — the content was still protected; only the
certificate is missing.

### What an evidence row is not

An evidence row is an instance-local record of what this application did. It is
not a certificate, and it is not an attestation about ServiceNow's own
inference. The certificate — when there is one — attests exactly one thing: the
sanitizer processed the submitted fields before the skill ran.

### Retention

No retention rule ships with the application. Decide one with the customer and
add a table-rotation or scheduled-cleanup job to match their policy.
