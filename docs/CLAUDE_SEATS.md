# Claude Team / Enterprise seats through the gateway

**For:** a firm whose consultants use Claude Code with their company's
**Claude Team or Claude Enterprise seat** instead of an Anthropic API key.
**Not for consumer Claude Pro or Max plans.** Do not route those through the
gateway, and do not switch this setting on for them.

## What the setting does

One line in `customer.env`, off by default:

```bash
LUCAIRN_CLAUDE_SEAT_LANE=true
```

(`bin/lucairn-init --production --runtime-mode managed-byok --claude-seat-lane`
writes it.) The compose files then switch on both halves of the lane:
`GATEWAY_OAUTH_PASSTHROUGH_ENABLED` on the gateway and
`SANDBOX_B_OAUTH_PASSTHROUGH_ENABLED` on Sandbox B. Only the exact value
`true` switches it on. Needs `--runtime-mode managed-byok` (the local Sandbox B
calls Anthropic). Init refuses `--claude-seat-lane` without `--production`: a
`--dev` install runs the internal links without TLS.

With the lane on, a request that carries both a valid Lucairn key **and** the
consultant's own Anthropic sign-in is hidden exactly like any other request,
and Sandbox B sends the hidden request to Anthropic with that sign-in.
Requests without a seat sign-in keep needing a provider key in `customer.env`
(`ANTHROPIC_API_KEY`), as before.

## What you should know before you switch it on

- **The sign-in reaches disk on this server.** For the length of a turn it is
  held in Sandbox B's job store (the Redis service `redis-ai`), which keeps an
  append-only file on a Docker volume. Treat the server's disks and backups
  like a store of the consultants' sign-ins.
- **Keeping consumer plans out is your duty.** The gateway checks only the
  shape of the sign-in token; it cannot tell a Team or Enterprise seat from a
  consumer Pro or Max plan. Hand Lucairn keys only to people who sign in with
  the company seat.
- **Stated limit (images 1.1.1):** the link from the gateway to Sandbox B is
  encrypted, but the gateway does not verify Sandbox B's identity on it, so a
  wrong peer on that internal Docker network could receive the sign-in.

## What each consultant does (Claude Code)

The operator mints one key per consultant (INSTALL.md fast path, step 4,
"One key per consultant": the same customer id, one key per person) and
hands it over on a secure channel of the company's choice (password manager,
a file share only that person can read; never e-mail or chat in clear text).

1. Sign in to Claude Code with the company seat once (`claude`, then `/login`).
2. Store the personal Lucairn key in `~/.lucairn/key`, mode 0600:

   ```bash
   mkdir -p ~/.lucairn && chmod 0700 ~/.lucairn
   install -m 0600 /dev/null ~/.lucairn/key
   # put the key into ~/.lucairn/key (one line), then delete the copy you received
   ```

3. If the gateway's HTTPS certificate comes from a company or own CA (not a
   public one), copy that CA's certificate (`.crt`, never the key) to the
   laptop and point Claude Code at it; without it Claude Code stops with
   `SSL certificate verification failed (UNABLE_TO_VERIFY_LEAF_SIGNATURE)`:

   ```bash
   export NODE_EXTRA_CA_CERTS="$HOME/.lucairn/company-ca.crt"
   ```

   Shown with Claude Code 2.1.325 against a local HTTPS stand-in and against
   the gateway through Caddy on a fresh server (proof run of 22 Nov 2026).
4. Point Claude Code at the gateway and give it the personal Lucairn key as a
   header (the seat sign-in already uses the `Authorization` header):

   ```bash
   export ANTHROPIC_BASE_URL=https://lucairn.internal.example   # your reverse proxy, INSTALL.md § "Reverse proxy"
   export ANTHROPIC_CUSTOM_HEADERS="X-DSA-Key: $(cat ~/.lucairn/key)"
   claude
   ```

   Do not put the key into a shared or managed
   settings file: `bin/lucairn config-pack` refuses credentials in header maps
   on purpose, so the seat lane is set per user, not through the config pack.

## Check it works

Read the setting in the running gateway; it must print
`GATEWAY_OAUTH_PASSTHROUGH_ENABLED=true` (the `oauth-passthrough:` line in the
gateway's start-up log is printed whether the lane is on or off, so it proves
nothing):

```bash
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
  "$(docker ps -q --filter label=com.docker.compose.service=gateway)" | grep '^GATEWAY_OAUTH_PASSTHROUGH_ENABLED='
```

Then one Claude Code turn through the gateway answers normally and gets a
certificate (`bin/lucairn logs --env customer.env --service gateway --tail 50`).

## Switching it off

Set `LUCAIRN_CLAUDE_SEAT_LANE=false` (or delete the line) and run
`bin/lucairn up --env customer.env`; the gateway and Sandbox B are recreated
and refuse seat sign-ins again.
