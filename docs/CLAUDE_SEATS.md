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
calls Anthropic).

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

1. Sign in to Claude Code with the company seat once (`claude`, then `/login`).
2. Point Claude Code at the gateway and give it the personal Lucairn key as a
   header (the seat sign-in already uses the `Authorization` header):

   ```bash
   export ANTHROPIC_BASE_URL=https://lucairn.internal.example   # your reverse proxy, INSTALL.md § "Reverse proxy"
   export ANTHROPIC_CUSTOM_HEADERS="X-DSA-Key: $(cat ~/.lucairn/key)"
   claude
   ```

   Keep the key file mode 0600. Do not put the key into a shared or managed
   settings file: `bin/lucairn config-pack` refuses credentials in header maps
   on purpose, so the seat lane is set per user, not through the config pack.

## Check it works

The gateway log at start says the lane is on (`oauth-passthrough: …`). One
Claude Code turn through the gateway answers normally and gets a certificate
(`bin/lucairn logs --env customer.env --service gateway --tail 50`).

## Switching it off

Set `LUCAIRN_CLAUDE_SEAT_LANE=false` (or delete the line) and run
`bin/lucairn up --env customer.env`; the gateway and Sandbox B are recreated
and refuse seat sign-ins again.
