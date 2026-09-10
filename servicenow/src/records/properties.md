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

## `lucairn.now_assist.vendor` has no default, on purpose

The Lucairn service accepts exactly three values on the certificate-sealing
call: `anthropic`, `openai`, `google`. There is no value that names the model
behind a Now Assist deployment, so the application cannot pick one for you and
does not try.

**You must set this property. It is not optional.** Configuration validation
runs before the sanitize call, not before the seal call, so an unset or
out-of-list vendor stops the whole flow:

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
