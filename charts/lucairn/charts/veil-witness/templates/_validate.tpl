{{/*
Render-time validation guards for veil-witness.

Helm renders all templates before applying them; {{ fail }} aborts the
render with a clear message so the operator sees the problem at
`helm template` / `helm install` time rather than at runtime.
*/}}

{{/*
veilWitness.validateSigningKey
──────────────────────────────
Fail-fast on the two most dangerous signing-key misconfigurations:

  1. Empty / missing value  — the witness would start with no signing key,
     silently issuing unsigned or zero-key certificates.
  2. All-zeroes placeholder — the shipped default
     "0000000000000000000000000000000000000000000000000000000000000000"
     is a known-bad key. Any attacker can reproduce it. Every certificate
     signed with it is forgeable.

To generate a real key:
  openssl rand -hex 32
     → 64 hex characters (32 random bytes), e.g.
       a1b2c3d4e5f6...

Then pass it at install time:
  --set "veil-witness.secrets.values.signingKey=$(openssl rand -hex 32)"

Or store it in a sealed secret / Vault and reference it via
veil-witness.secrets.backend = vault | aws | azure (see values.yaml).
*/}}
{{- define "veilWitness.validateSigningKey" -}}
{{- $key := .Values.secrets.values.signingKey | default "" -}}
{{- if not $key -}}
{{- fail "[veil-witness] secrets.values.signingKey is empty or missing. A real Ed25519 signing key is required — every certificate issued by the witness is signed with this key. Generate one with: openssl rand -hex 32" -}}
{{- end -}}
{{- $zeroKey := "0000000000000000000000000000000000000000000000000000000000000000" -}}
{{- if eq $key $zeroKey -}}
{{- fail "[veil-witness] secrets.values.signingKey is the all-zeroes placeholder. This is a known-bad default: every certificate issued under it is trivially forgeable. Generate a real key with: openssl rand -hex 32\nThen pass it via --set \"veil-witness.secrets.values.signingKey=$(openssl rand -hex 32)\" or store it in your secrets backend (vault/aws/azure)." -}}
{{- end -}}
{{- if not (mustRegexMatch "^[0-9a-fA-F]{64}$" $key) -}}
{{- fail "[veil-witness] secrets.values.signingKey must be exactly 64 hex characters (32 bytes, encoded as lowercase or uppercase hex). Generate a valid key with: openssl rand -hex 32" -}}
{{- end -}}
{{- end -}}
