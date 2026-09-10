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
| `lucairn.now_assist.timeout_ms` | integer | `30000` | no | Per-call HTTP timeout. Non-numeric or non-positive values fall back to the default. |
| `lucairn.now_assist.client_id` | string | `lucairn-for-now-assist` | no | Provenance string echoed into the certificate |
| `lucairn.now_assist.vendor` | string | *(none — see below)* | **yes** | Vendor family recorded on the certificate |

## `lucairn.now_assist.vendor` has no default, on purpose

The Lucairn service accepts exactly three values on the certificate-sealing
call: `anthropic`, `openai`, `google`. There is no value that names the model
behind a Now Assist deployment, so the application cannot pick one for you and
does not try. An unset value fails validation, and a failed validation fails
closed.

Set it to the vendor family that actually backs the deployment you are
protecting, and record why you chose it. If none of the three is honest for your
deployment, do not guess — leave it unset and run without certificate sealing
until the value set is extended. Sanitization still works; only the certificate
is missing. See `../../README.md` § "Known gap: the vendor field".

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
gs.setProperty('lucairn.now_assist.timeout_ms', '30000');
```
