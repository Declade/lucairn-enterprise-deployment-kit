# Connection & Credential alias + outbound REST Message

The shipping transport. The customer's own `lcr_live_` key lives in a credential
record; the platform injects it, and no application code ever reads it.

> **Status: hypothesis until the PDI run.** Every record shape below is written
> from the documented ServiceNow model, not from an executed instance test. The
> falsifier is the verification runbook in `../../README.md` § "Verify on the
> PDI" — Leg 1 either produces a `cert_id_partial` or it does not. If alias
> resolution turns out to behave differently on the target release, switch
> `lucairn.now_assist.transport` to `endpoint`, prove the round trip that way,
> and record what actually happened here.

> ### 🔴 UNRESOLVED: does a RESTMessage even carry API-key authentication?
>
> This is a sharper doubt than the general banner above, and it was raised
> against a specific claim in this file: that setting a REST Message's
> *Authentication type* to a Connection & Credential alias makes the platform
> inject an `Authorization: Bearer …` header from an API Key credential.
>
> **The published documentation does not support that.** ServiceNow's outbound
> REST authentication page describes custom/API-key authentication in terms of
> **Flow Designer REST steps**, not the `sn_ws.RESTMessageV2` API this
> application uses. So the recipe in § 4 may be one of:
>
>   1. correct on the target release and simply under-documented;
>   2. correct only with an API Key authentication profile attached (§ "If the
>      alias does not supply an Authorization header" below);
>   3. **not supported at all** for `RESTMessageV2`, in which case the shipping
>      transport for this application is `endpoint` mode, or a Flow-based
>      carrier, and the design changes.
>
> Outcome 3 is a design change, not a configuration tweak — treat it that way
> and open a design pass rather than working around it. Do not describe the
> alias transport as "the shipping mode" in any customer-facing material until
> Leg 1 has returned HTTP 200 through it on a named instance family and patch
> level, and the gate record says so.
>
> Reference: ServiceNow outbound REST authentication documentation
> (`https://www.servicenow.com/docs/r/api-reference/web-services/c_OutboundRESTAuth.html`)
> and the scoped GlideRecord API reference
> (`https://www.servicenow.com/docs/r/api-reference/server-api-reference/c_GlideRecordScopedAPI.html`).
> Raised by the round-1 gate (astra advisory, `connection-and-credential-alias.md:73`).

---

## 1. Credential — the customer's API key

**Table:** `sys_auth_credential` (API Key Credentials)
**Navigate:** Connections & Credentials → Credentials → New → *API Key Credentials*

| Field | Value |
|---|---|
| Name | `Lucairn API key` |
| API key | the customer's own `lcr_live_…` key |
| Application | Lucairn for Now Assist |

The key is stored encrypted. Do not paste it into a system property, an update
set, a script, or this repository.

## 2. Connection — where the calls go

**Table:** `sys_http_connection` (HTTP(s) Connection)
**Navigate:** Connections & Credentials → Connections → New → *HTTP(s) Connection*

| Field | Value |
|---|---|
| Name | `Lucairn service` |
| Connection alias | *(the alias created in step 3)* |
| Credential | `Lucairn API key` |
| Connection URL | the base URL for the customer's Lucairn account, e.g. `https://<lucairn-host>` |
| Use MID server | as the customer's network policy requires |
| Application | Lucairn for Now Assist |

The Connection URL is the **base**. The two paths are appended by the REST
Message functions in step 4.

## 3. Alias — the indirection point

**Table:** `sys_alias` (type: Connection and Credential)
**Navigate:** Connections & Credentials → Connection & Credential Aliases → New

| Field | Value |
|---|---|
| Name | `Lucairn service` |
| Type | Connection and Credential |
| Connection type | HTTP |
| Application | Lucairn for Now Assist |

Why an alias rather than a hard-coded URL: the customer can point a
non-production instance at a non-production Lucairn account without touching
the application, and the credential stays out of every exported artefact.

## 4. Outbound REST Message + two functions

**Table:** `sys_rest_message` / `sys_rest_message_fn`
**Navigate:** System Web Services → Outbound → REST Message → New

### REST Message

| Field | Value |
|---|---|
| Name | `Lucairn Service` |
| Authentication type | **Connection & Credential alias** — ⚠️ unresolved, see the red banner above |
| Connection alias | `Lucairn service` (step 3) |
| Application | Lucairn for Now Assist |

The name must match `lucairn.now_assist.rest_message_name` (default
`Lucairn Service`).

### Function `sanitizeOnly`

| Field | Value |
|---|---|
| Name | `sanitizeOnly` |
| HTTP method | POST |
| Endpoint | `${connection_url}/api/v1/sanitize-only` |

### Function `sealCert`

| Field | Value |
|---|---|
| Name | `sealCert` |
| HTTP method | POST |
| Endpoint | `${connection_url}/api/v1/sensitive-mode/seal-cert` |

The application sets `Content-Type`, `Accept`, the request body and the HTTP
timeout at call time, so no HTTP Headers rows are needed on either function.

### If the alias does not supply an Authorization header

Some releases expect the API-key credential to be paired with an API Key
authentication profile that names the header. If Leg 1 of the verification
runbook returns HTTP 401, add one:

**Table:** `sys_auth_profile_apikey`

| Field | Value |
|---|---|
| Name | `Lucairn bearer` |
| Send API key as | Request header |
| Header name | `Authorization` |
| Prefix / template | `Bearer ` (note the trailing space) |

…and reference it from the connection record. Record the outcome in the gate
record either way — this is one of the things the PDI run exists to settle.

---

## 5. Roles

| Role | Grants |
|---|---|
| `x_lcrn_now_assist_admin` | Read/create/write/delete on the skill policy table (i.e. the ability to turn a skill fail-open), read on evidence, read on the application's properties |
| `x_lcrn_now_assist_auditor` | Read-only on the evidence table and the skill policy table |

Neither role gets create, write or delete on the evidence table — those rows are
written by application code only. The full per-operation ACL specification is in
`tables.md` § "Access control"; create it as specified rather than treating the
table's default access as sufficient.

Nobody needs read access to the credential record for the application to work.
