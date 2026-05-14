# Internal AI-Tools Hygiene

These are vendor-side rules for customer-adjacent work.

## Customer Folder Boundary

Use:

```text
~/Clients/[customer-slug]/
```

for every customer engagement.

## Claude Read Deny

Add deny rules for `~/Clients/**` in:

```text
~/.claude/settings.local.json
```

unless the customer contract explicitly allows the relevant AI tooling path.

## Local LLM Fallback

Install Ollama with Qwen 3 Coder 7B or 30B for sensitive sessions where no data may leave the laptop.

## Dogfood Lucairn

Route Claude Code and Codex through the Lucairn gateway for customer-adjacent work when the DPA permits AI-tool use through a customer-controlled or vendor-controlled privacy gateway.

## Enterprise Zero Retention Trigger

Switch the vendor Anthropic or OpenAI plan to an enterprise zero-retention tier when the first enterprise close lands.

