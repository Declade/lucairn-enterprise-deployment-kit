# Tool runner (Preview)

> **Status: Preview.** Opt-in, off by default, on the self-hosted Enterprise
> kit. Interfaces, defaults and limits on this page can change before general
> availability. The runner image is **not published yet**: you build it from a
> source tarball Lucairn provides (see [Build the image](#build-the-image)).

## What it is

The tool runner lets an AI agent work on a ServiceNow instance through a fixed
set of tools instead of a login. The agent connects to the runner over MCP
(Model Context Protocol). The runner holds the ServiceNow credential, applies
your field policy to every call, and answers with schema, configuration values
and the record fields your policy allows.

It runs in your environment, next to the rest of the kit. The ServiceNow
credential stays in your secret store and in the runner's memory. It is not
given to the model, it is not in any container environment, and it does not
reach Lucairn.

## What it promises — and what it does not

The promise is these five statements and nothing more:

1. **Fields your policy marks `never` are never handed to the model.** The
   runner does not even fetch them from ServiceNow. Tables and fields your
   policy does not classify are treated as `never`.
2. **Every write needs a human approval.** A write tool only queues the exact
   change. A person approves or rejects it; nothing is written before that.
3. **Every call gets a signed receipt** — allowed, denied, approved or
   rejected — in a hash-chained store you can verify offline.
4. **Free text is scrubbed, not guaranteed.** Descriptions, notes and free-text
   labels at the `sanitize` tier pass through the gateway's text scan, which is
   a best-effort detector. If the scan is unavailable, the field is withheld.
5. **It only covers what goes through Lucairn tools.** An agent that also has
   a browser session, a shell with a ServiceNow login, or another integration
   is outside this boundary.

Also outside the promise:

- **Scripts are configuration.** Business rules, script includes, ACLs and
  client scripts are shown to the agent in full, including comments a person
  wrote. A script the agent writes can itself move data when ServiceNow runs
  it; the person approving the write is the control.
- **Column and table labels are shown as stored.** A name an admin wrote into
  a label is served.
- **Receipts are not Lucairn certificates.** They are signed with a key you
  hold and are anchored nowhere outside your environment.
- **Counts of non-identifying groups** (state, priority) are not suppressed.
  Groups that can identify a person or team are suppressed below five records.

## How it is deployed

| | Docker Compose | Kubernetes (Helm) |
|---|---|---|
| Switch | `--profile tool-runner` (self-hosted overlay) | `toolRunner.enabled: true` |
| Default | off | off |
| Network | own bridge to the gateway + one egress bridge | own namespace, default-deny, two egress rules |
| Secrets | Docker secrets (files) | Secret volume, or ExternalSecret |
| MCP endpoint | unix socket in the container | unix socket in the pod |
| Published ports | none | none (no Service, no ingress) |
| Root filesystem | read-only, non-root user, all capabilities dropped | same |

### Why a socket and not a port

The MCP endpoint has no authentication of its own: whoever can connect can
call the tools. So it is a unix socket inside the container
(`/run/tool-runner/mcp.sock`, owner-only, on a memory filesystem) and not a
TCP port, not even on loopback. To reach it, the agent host must be allowed to
exec into the runner container — a right you already control.

The agent host's MCP server entry runs the secret-free bridge, which only
copies bytes:

```sh
# Compose
docker compose -f docker-compose.customer.yml -f docker-compose.self-hosted.yml \
  --env-file customer.env exec -T tool-runner \
  lucairn-tool-runner connect --socket /run/tool-runner/mcp.sock

# Kubernetes
kubectl exec -i -n dsa-tool-runner deploy/tool-runner -- \
  lucairn-tool-runner connect --socket /run/tool-runner/mcp.sock
```

Give the agent host a Kubernetes role that allows `pods/exec` in the
`dsa-tool-runner` namespace only.

### Network

The runner may reach two destinations: the kit's gateway (for free-text
scrubbing) and your ServiceNow instance. It is on no network shared with the
sanitizer, the identity plane, the model runtime or the witness.

- **Helm:** the sub-chart creates the namespace `dsa-tool-runner` with a
  default-deny policy and an egress policy: the gateway pod on its HTTP port,
  TCP 443 to `tool-runner.egress.servicenow.cidrs`, and DNS. A NetworkPolicy
  cannot name a host, so you list the address ranges of your instance. The
  render fails when the list is empty, unless you set
  `tool-runner.egress.servicenow.allowAnyHttps: true` on purpose (TCP 443 to
  public addresses only; private and cluster ranges stay closed).
- **Compose:** the runner joins `dsa-tool-runner` (internal, shared only with
  the gateway) and `dsa-tool-runner-egress`. **Compose cannot limit a bridge
  to one destination.** Pin the egress bridge to your ServiceNow instance with
  a host firewall rule or an egress proxy. Until you do, the runner container
  could open connections to other internet hosts.

With the Compose profile off, the gateway is still attached to the (then
empty) internal bridge `dsa-tool-runner`. Nothing else changes.

## ServiceNow service account

Use a **dedicated service account**, not a person's login.

- **Why dedicated.** While a configuration write runs, the account's "current
  update set" preference points at a runner-managed update set. A person
  working under the same login at that moment would capture changes into it.
  The account name is also what `sys_created_by` / `sys_updated_by` show on
  everything the runner writes.
- **Roles.** Read access to the tables your policy serves, and write access to
  the configuration tables the write tools target. Which roles give that is
  your instance's decision. Grant no more.
- **ACL writes need `security_admin` without interactive elevation.** On a
  standard instance `security_admin` is an elevated-privilege role: a REST
  session does not hold it, because elevation is an interactive step in the
  ServiceNow UI. The runner has no elevation step. For the ACL tool to work,
  an instance admin has to make `security_admin` usable without interactive
  elevation for the service account. That changes the instance for every
  holder of the role and does not fit a production instance.
- **Without it, ACL tools refuse.** An approved ACL write ends as refused with
  the category `needs_security_admin` and a reason that says what to change.
  Nothing is written. Every other tool keeps working.

## Writes

- **Production writes are off.** Set the instance class to `dev`, `test` or
  `prod`. On `prod` the runner refuses every write. There is no switch for
  that in this Preview.
- **No approver secret, no write tools.** Write tools exist only when you
  provide an approver secret. Leave it empty for a read-only runner.
- **Approving.** A person lists what is waiting and decides, naming the exact
  action hash. The approver secret is given on standard input:

  ```sh
  docker compose ... exec -T tool-runner lucairn-tool-runner pending \
    --config /run/tool-runner/config.json < ./tool-runner/secrets/approver_secret

  docker compose ... exec -T tool-runner lucairn-tool-runner approve \
    --config /run/tool-runner/config.json --hash <action hash> \
    --approver <your name> < ./tool-runner/secrets/approver_secret
  ```

  Run these as a host user who may read the approver secret file (it belongs
  to the runner uid). `reject` takes the same arguments. `pending` shows the complete change,
  including the full text of a script. An approval covers one hash and expires
  after 15 minutes.
- **Never available:** tools that execute code when called (background
  scripts, fix scripts, scheduled jobs), outbound HTTP or e-mail artefacts,
  user, role or group-membership writes, and system properties.

## Policy

Your admin owns the policy. It is a JSON file on your host, in the same v1
schema the policy editor in the Lucairn account produces — you can export a
policy there and use it here, or write it by hand. **No policy data leaves
your environment:** the kit never uploads the file, and the helpers below run
locally.

```json
{
  "schema": "lucairn-tool-policy/1",
  "connector": "servicenow",
  "presets": {
    "incident": { "level": "strict" },
    "change_request": { "level": "standard",
                        "overrides": { "change_request": { "short_description": "never" } } },
    "task_sla": { "level": "standard" }
  },
  "task_fallback": true,
  "aggregate": { "k_min": 5 }
}
```

Presets: `incident`, `problem`, `problem_task`, `change_request`,
`change_task`, `sc_request`, `sc_req_item`, `sc_task`, `knowledge`, `cmdb_ci`,
`task_sla`, `task`, `config`, `users_groups`. Levels: `strict`, `standard`,
`open` (`users_groups` allows `strict` and `standard` only). Every preset
entry names its level. Field tiers an override can set: `pass`, `sanitize`,
`pseudonym`, `project:email_domain`, `project:age_days`, `never`. Person
fields in `users_groups` accept `sanitize` or `never` only.

### Approve a policy

The runner starts no tools unless the policy file has exactly the digest you
approved.

```sh
bin/lucairn tool-policy validate ./tool-runner/policy.json   # structure, then presets and levels
bin/lucairn tool-policy digest   ./tool-runner/policy.json   # prints the sha256
```

Set the printed value as `LUCAIRN_TOOL_RUNNER_POLICY_SHA256` (Compose) or
`tool-runner.policy.sha256` (Helm), then restart the runner. Keep the digest
under change control: it is the record of which policy was approved.

`validate` checks the structure on the host (needs `python3`). The full check
is the runner's own validator, run from the runner image with no network, a
read-only filesystem and an unprivileged user; it needs `docker` and the
image. Without them it stops with exit code 2 and says the full check was not
run. The equivalent one-liner:

```sh
docker run --rm --network none --read-only --user 10001:10001 \
  -v "$PWD/tool-runner/policy.json:/policy.json:ro" \
  --entrypoint node <registry>/lucairn-tool-runner:0.1.0 \
  /opt/lucairn-kit/entrypoint.mjs --validate-policy /policy.json
```

## Secrets

Four secrets, all files, none of them an environment variable:

| File (Compose) | Helm value | Required | What it is |
|---|---|---|---|
| `servicenow_username`, `servicenow_password` | `secrets.values.servicenowUsername` / `servicenowPassword` | yes | the dedicated service account |
| `signing_key` | `secrets.values.signingKey` | yes | Ed25519 key that signs the receipts |
| `gateway_key` | `secrets.values.gatewayKey` | no | Lucairn key for free-text scrubbing; empty = withheld |
| `approver_secret` | `secrets.values.approverSecret` | no | switches the write tools on; empty = read-only |

```sh
mkdir -p tool-runner/secrets && cd tool-runner/secrets
printf '%s\n' 'svc.lucairn.runner' > servicenow_username
# write the password without leaving it in shell history:
( umask 077; cat > servicenow_password )            # paste, then Ctrl-D
openssl genpkey -algorithm ed25519 -outform DER | base64 | tr -d '\n' > signing_key
: > gateway_key                                     # empty = no scrubbing path
: > approver_secret                                 # empty = no write tools
# to switch write tools on instead:
#   openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' > approver_secret
chmod 0400 ./*
sudo chown 10001:10001 ./*                          # the uid the runner runs as
```

- With Compose, the two optional files must exist; leave them empty to keep
  the feature off.
- The container runs as uid `10001`. The files must be readable by that uid
  and by nobody else. To run as another uid, set `LUCAIRN_TOOL_RUNNER_UID` /
  `LUCAIRN_TOOL_RUNNER_GID` and make the data volume writable for it.
- With Helm, pass secret values with `--set-string` or a values file you do
  not commit, or set `tool-runner.secrets.backend` to `vault`, `aws` or
  `azure` to read the same five properties through an ExternalSecret.
- **Keep a copy of the receipt public key outside the runner.** The runner
  writes one next to its store for convenience; verify receipts against your
  own copy.
- A signing key that is a development default (a repeated-byte, counting or
  published test seed) is refused by `bin/lucairn doctor`, by the Helm render
  and by the runner at start.

How the secrets travel: the container entrypoint reads the mounted files,
passes them to the runner process on its standard input as one line, and
writes none of them to disk. The runner refuses to start when it finds a
variable named `SN_*`, `SNOW_*` or `SERVICENOW_*` in its environment.

## Free-text scrubbing

Fields at the `sanitize` tier and free-text labels are sent, one at a time, to
the gateway's text scan and served as the gateway returns them. With no
gateway URL or no gateway key, those fields are **withheld** — never passed
raw.

**Limit of this Preview:** runner image `0.1.0` accepts only its built-in
Lucairn-hosted gateway origins and stops at start on any other gateway URL,
including the gateway of this kit. On a self-hosted install, leave
`LUCAIRN_TOOL_RUNNER_GATEWAY_URL` / `tool-runner.gateway.url` empty for now:
structure, configuration values the policy passes, pass-tier fields and
aggregates work; sanitize-tier fields and free-text labels are withheld. The
network path from the runner to the kit's gateway is already in place for the
runner release that accepts it.

## Build the image

```sh
# from the kit root; runner-src.tar.gz and its sha256 come from Lucairn
docker build -f apps/tool-runner/Dockerfile \
  --build-arg RUNNER_TARBALL=runner-src.tar.gz \
  --build-arg RUNNER_SHA256=<sha256 of the tarball> \
  -t <registry>/lucairn-tool-runner:0.1.0 .
```

The build verifies the tarball's sha256, installs the runner's runtime
dependencies, records the runner's code digest in the image, and produces a
non-root image on Node 22 LTS. At every start the entrypoint recomputes that
code digest and does not start a runner whose files differ.

`image-manifest.yaml` lists the image as `pending` (unreleased): there is no
published image, no recorded digest and no signature for it yet, so
`doctor --strict` skips it and `verify-images` does not cover it.

## Enable it

### Docker Compose

1. Build and load the image; write the policy and the secret files.
2. In `customer.env`:

   ```sh
   LUCAIRN_TOOL_RUNNER_ENABLED=true
   LUCAIRN_TOOL_RUNNER_INSTANCE_URL=https://example-dev.service-now.com
   LUCAIRN_TOOL_RUNNER_INSTANCE_CLASS=dev
   LUCAIRN_TOOL_RUNNER_PRINCIPAL=servicenow-platform-team@example.test
   LUCAIRN_TOOL_RUNNER_POLICY_FILE=./tool-runner/policy.json
   LUCAIRN_TOOL_RUNNER_POLICY_SHA256=<output of: bin/lucairn tool-policy digest ...>
   LUCAIRN_TOOL_RUNNER_SECRETS_DIR=./tool-runner/secrets
   ```

   Relative paths are resolved against the directory of the first compose
   file, by Compose and by `doctor` alike.
3. `bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline`
4. Start with the extra profile: `--profile tool-runner`.

### Kubernetes (Helm)

```sh
helm upgrade --install lucairn charts/lucairn -f customer-values.yaml \
  --set toolRunner.enabled=true \
  --set tool-runner.instanceUrl=https://example-dev.service-now.com \
  --set tool-runner.instanceClass=dev \
  --set-string tool-runner.principal=servicenow-platform-team@example.test \
  --set-file tool-runner.policy.json=./tool-runner/policy.json \
  --set-string tool-runner.policy.sha256="$(bin/lucairn tool-policy digest ./tool-runner/policy.json)" \
  --set "tool-runner.egress.servicenow.cidrs={<range of your instance>}" \
  --set-string tool-runner.secrets.values.servicenowUsername=... \
  --set-string tool-runner.secrets.values.servicenowPassword=... \
  --set-string tool-runner.secrets.values.signingKey=...
```

The render fails, with a message that names the value, on: a missing instance
class, a policy whose digest is not the configured one, a development-default
signing key, an empty ServiceNow address list, and any `SN_*` variable in the
runner's environment.

## What doctor checks

`bin/lucairn doctor` runs these checks only when the tool runner is opted in.
Otherwise it prints one line, `tool runner: skipped`, and checks nothing.

| Check | Fails when |
|---|---|
| Signing key | the key is missing, is not an Ed25519 key, or is a development default |
| Environment | a `SN_*` / `SNOW_*` / `SERVICENOW_*` variable or the Lucairn key appears in `customer.env`, in a compose file, or (Helm) anywhere in the values |
| Policy | the policy file is missing, or its sha256 is not the configured digest |
| Instance class | it is not set to `dev`, `test` or `prod` |
| Secret files | a required file is missing or empty, or a secret file is readable by every user of the host |

It also warns when no scrubbing path is configured (sanitize-tier fields are
then withheld).

## Receipts

```sh
# once, when you create the signing key: derive the public key and keep it outside the runner
base64 -d < tool-runner/secrets/signing_key | openssl pkey -inform DER -pubout > receipt-signing-key.pub.pem

docker compose ... exec -T tool-runner lucairn-tool-runner verify \
  --db /var/lib/lucairn-tool-runner/receipts.sqlite --pubkey /dev/stdin < receipt-signing-key.pub.pem
```

`verify` checks the chain, the signatures and the store's signed tail, so
receipts removed from the end are detected. A rollback to an older complete
copy of the store is detected only against something you keep outside it: an
exported checkpoint (`lucairn-tool-runner checkpoint`), an expected count, or
the expected last hash. Back up the `tool-runner-data` volume (Compose) or the
`tool-runner-data` claim (Helm) with your other kit data.

## Known limits

- Preview. The image is unreleased, unsigned by Lucairn, and built by you.
- The kit's own gateway is not accepted as a scrubbing origin yet (see above).
- Only `https://<name>.service-now.com` instances. Custom instance host names
  and on-premise ServiceNow installations are not supported.
- Compose cannot pin the runner's egress to one host; you have to.
- Global scope only; scoped ServiceNow applications are not handled.
- Multi-step writes (an ACL with roles, a UI policy with actions) are not
  atomic. A failure part-way is reported with what exists.
- A timeout during a write means the outcome is unknown. The receipt says so
  and the action is not run again.
- One runner per ServiceNow instance and per kit install.
- Anyone who can exec into the runner container can call the tools and, with
  enough privilege on the host, read the runner's memory. Treat exec rights on
  it like access to the ServiceNow service account.
