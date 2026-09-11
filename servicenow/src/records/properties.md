# System properties — Lucairn for Now Assist

Create each of these as a scoped system property (`sys_properties`) inside the
application. Names are read by `LucairnConfig` (`../script_includes/LucairnConfig.js`).

| Property | Type | Default | Required | Purpose |
|---|---|---|---|---|
| `lucairn.now_assist.transport` | string | `rest_message` | no | `rest_message` (shipping mode, uses the Connection & Credential alias) or `endpoint` (bring-up fallback) |
| `lucairn.now_assist.rest_message_name` | string | `Lucairn Service` | rest_message mode | Name of the outbound REST Message record |
| `lucairn.now_assist.rest_fn_sanitize` | string | `sanitizeOnly` | rest_message mode | REST Message function that posts to the sanitize path |
| `lucairn.now_assist.rest_fn_seal` | string | `sealCert` | rest_message mode | REST Message function that posts to the seal path |
| `lucairn.now_assist.base_url` | string | *(empty)* | endpoint mode | Base URL of the Lucairn service. Must be `https`. |
| `lucairn.now_assist.api_key` | **password2** | *(empty)* | endpoint mode | The customer's own `lcr_live_` key. Encrypted at rest. |
| `lucairn.now_assist.timeout_ms` | integer | `45000` | no | Per-call HTTP timeout. Non-numeric or non-positive values fall back to the default. |
| `lucairn.now_assist.client_id` | string | `lucairn-for-now-assist` | no | Provenance string echoed into the certificate |
| `lucairn.now_assist.vendor` | string | *(none — see below)* | **yes** | Vendor family recorded on the certificate |
| `lucairn.now_assist.output_destination` | string | `bare_output` | only if the hook is wired | Which destination the GenAI preprocessor hook publishes its sanitized text to. One of `bare_output`, `outputs_text`, `api_set_output`, `global_output`. **Administrator-only writes — see § write authority below.** |

## `lucairn.now_assist.output_destination` — one destination, declared

Only the paste-in hook (`../hooks/genai-preprocessor.js`) reads this property;
the Script Includes ignore it. If you have not wired the hook, leave it unset.

The hook publishes the sanitized text to **exactly one** destination — the one
this property names — then reads that destination back and compares. Anything
short of an exact match raises, and **no other destination is written,
attempted, or consulted**.

| Value | The hook writes and reads back |
|---|---|
| `bare_output` *(default)* | the bare `output` identifier, in whatever scope the extension point declares it |
| `outputs_text` | `outputs.text` on an output container object |
| `api_set_output` | `api.setOutput(v)`, read back with `api.getOutput()` |
| `global_output` | `globalScope.output` — for an extension point that pre-declares no `output` binding at all. Verified by re-reading the bare identifier. |

**All four are unproven hypotheses.** None has been observed on an instance, and
the default is only a guess about which guess is likeliest. Leg 6 step 7 of
`../../README.md` § Verify on the PDI is where an observation replaces it.

Why it is a property and not a search: an earlier version tried the four shapes
in order and used the first that verified. That can verify one destination while
the platform consumes a *different* one that still holds the raw submission —
reproduced in both directions (a frozen `outputs.text` refusing the write while
a writable bare `output` "succeeded"; and a working `api` pair being used while
the consumed bare binding rejected the write and kept the raw text). Verifying a
write answers *"did my write land here"*, never *"is here what gets consumed"*.
Only this property answers the second question. Round-5 gate finding
(`Opus Advisor/specs/2026-09/gate-2026-09-10-kit-pr133-s1.md`).

Consequences worth knowing before you set it:

- An unrecognised value — a typo — **raises**. It does not fall back to the
  default, because publishing somewhere the operator did not choose is the whole
  class this design removes.
- If the property cannot be read at all, the hook **raises** rather than
  assuming the default.
- Under the default `bare_output`, an extension point that pre-declares no
  `output` binding raises with `hook could not publish its output`. That is a
  wiring finding: set `global_output` if the instance really works that way.
- Every wiring failure says `hook could not publish its output:`; only a real
  block says `skill run blocked:`. Leg 6 needs exactly one discriminator.
- A *recognised but wrong* value does **not** raise. See the next section — it
  is the one case here that is not fail-closed.

### `output_destination` — write authority

**Administrator-only writes.** Restrict `write` (and `create`) on this
`sys_properties` record to `x_lcrn_now_assist_admin`, the same role that governs
the skill-policy table, and grant it the way you would grant any other privacy
control: named individuals, recorded, reviewed.

This is not tidiness. Setting this property to a *recognised but wrong* value
silently un-protects every run of every protected skill on the instance: the
hook verifies the destination it was declared, does it perfectly, returns
normally — and the destination the platform actually consumes still holds the
raw submission. There is no error, no annotation, and no evidence row that looks
any different. Round-6 gate finding
(`Opus Advisor/specs/2026-09/gate-2026-09-10-kit-pr133-s1.md`).

Unrecognised values and an unreadable property both raise, so a *typo* is
fail-closed and visible. A wrong-but-valid value is not, which is exactly why
write access is a control and not a preference:

| | What happens | Observable |
|---|---|---|
| Unset | documented default `bare_output` | — |
| Unrecognised (typo) | **raises**, no publish | `hook could not publish its output:` |
| Unreadable property | **raises**, no publish | `hook could not publish its output:` |
| Recognised, and the one this extension point exposes | sanitized text published and verified | a sanitized summary |
| **Recognised, but NOT the one consumed** | **returns normally; the model runs on RAW** | **none from the hook — only a summary containing un-redacted content** |

Two consequences to act on, not just to know:

- **Verify it on the PDI before any production claim.** `../../README.md`
  § Leg 6, coverage half, is the only check that distinguishes the last two rows
  — and the Leg 6 record must name the destination value it ran with.
- **Track the ACL like the others.** Verification item **V6** in
  [`tables.md`](tables.md) § "PDI-time verification items"; an unverified row is
  not a control.

## `lucairn.now_assist.vendor` has no default, on purpose

The Lucairn service accepts exactly three values on the certificate-sealing
call: `anthropic`, `openai`, `google`. There is no value that names the model
behind a Now Assist deployment, so the application cannot pick one for you and
does not try.

**You must set this property. It is not optional.** Configuration validation
runs on BOTH calls — before the sanitize call in `protect()` and again in
`seal()` — so an unset or out-of-list vendor stops the whole flow at the first
step rather than merely costing you a certificate at the last one:

| Skill's policy | With `vendor` unset | What the operator sees |
|---|---|---|
| default (no policy row) | **every run of every protected skill is BLOCKED** | `lucairn_config_error`, `blocked` evidence rows, no summaries |
| `fail_open = true` | the run proceeds on **RAW content**, uncertified | `uncovered_run` evidence rows, `fail_open_override = true` |

In neither case is anything sanitized, and in neither case does a certificate
exist. An earlier version of this file said "leave it unset and run without
certificate sealing — sanitization still works; only the certificate is
missing." **That was wrong in both directions**, and an administrator following
it would have configured either a total outage or an unprotected pipeline while
believing content was being redacted. Round-1 gate finding 6
(`Opus Advisor/specs/2026-09/gate-2026-09-10-kit-pr133-s1.md`).

Set it to the vendor family that actually backs the deployment you are
protecting, and record why you chose it. If none of the three is honest for your
deployment, that is a blocker to raise — not a configuration to ship. Extending
the accepted set is a change to the Lucairn service's own contract; see
`../../README.md` § "Known gap: the vendor field".

## `lucairn.now_assist.api_key` — handling

- Type must be **password2** so the value is encrypted at rest, not `string`.
- In the shipping (`rest_message`) transport the key lives in the credential
  record instead, and this property stays empty.
- The key never appears in an evidence row, a log line, or an error message —
  `LucairnClient` builds every result object without it, and there is a unit
  test asserting that (`../../test/client.test.js`).
- Read access to `sys_properties` should be restricted to the application's
  admin role.

## Setting them from a background script

```javascript
// Run in the application scope, Studio → Scripts - Background.
gs.setProperty('lucairn.now_assist.vendor', 'openai');
gs.setProperty('lucairn.now_assist.timeout_ms', '45000');
```

## Why the timeout default is 45 s

The Lucairn service's own request budget is 90 s, and the comparable Lucairn
demo path has been measured at 4–7 s, or about 9.6 s with the heaviest sanitizer
layer on. A 30 s client timeout therefore sat close enough to the observed worst
case that a slow-but-healthy call could be abandoned — and an abandoned call is
a *blocked skill run*, because the adapter is fail-closed. 45 s sits above the
measured worst case and well inside the service budget. Lower it only if you
have measured your own instance's round trip and prefer a faster block.
