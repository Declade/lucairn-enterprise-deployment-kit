{{/*
Render-time guards for the tool runner. `fail` stops `helm template` /
`helm install` with a message that names the value to set, so a
misconfiguration is seen before anything is applied.
*/}}

{{- define "tool-runner.requireString" -}}
{{- $raw := .value -}}
{{- if and (not (kindIs "invalid" $raw)) (not (typeIs "string" $raw)) -}}
{{- fail (printf "[tool-runner] %s must be a YAML string, but a %s was given. Quote it (--set-string \"%s=...\")." .path (kindOf $raw) .path) -}}
{{- end -}}
{{- $value := (default "" $raw | toString | trim) -}}
{{- if not $value -}}
{{- fail (printf "[tool-runner] %s is empty. %s" .path .why) -}}
{{- end -}}
{{- if mustRegexMatch "(?i)^(change[-_ ]?me|placeholder|todo|replace[-_ ]?with)" $value -}}
{{- fail (printf "[tool-runner] %s is still a shipped placeholder, not a real value. %s" .path .why) -}}
{{- end -}}
{{- end -}}

{{/*
The receipt signing key: base64 of an Ed25519 private key in PKCS8 DER form
(16-byte header + 32-byte seed = 48 bytes = 64 base64 characters). Refused:
anything else, and seeds that are published or trivially guessable — all
bytes equal, counting up or down, or the RFC 8032 test vector. The
container entrypoint and `bin/lucairn doctor` apply the same rule.
*/}}
{{- define "tool-runner.validateSigningKey" -}}
{{- $key := (default "" . | toString | trim) -}}
{{- $path := "tool-runner.secrets.values.signingKey" -}}
{{- if not (mustRegexMatch "^MC4CAQAwBQYDK2VwBCIEI[A-Za-z0-9+/]{43}$" $key) -}}
{{- fail (printf "[tool-runner] %s is not an Ed25519 private key (base64 of PKCS8 DER). Generate one: openssl genpkey -algorithm ed25519 -outform DER | base64 | tr -d '\\n'" $path) -}}
{{- end -}}
{{- $hex := (printf "%x" (b64dec $key)) -}}
{{- $seed := (substr 32 96 $hex) -}}
{{- $devDefault := false -}}
{{- $known := list
      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
      "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
      "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
      "201f1e1d1c1b1a191817161514131211100f0e0d0c0b0a090807060504030201"
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" -}}
{{- if has $seed $known -}}{{- $devDefault = true -}}{{- end -}}
{{- $first := (substr 0 2 $seed) -}}
{{- if eq $seed (repeat 32 $first) -}}{{- $devDefault = true -}}{{- end -}}
{{- if $devDefault -}}
{{- fail (printf "[tool-runner] %s is a development default (a repeated-byte, counting or published test seed). Anyone can sign receipts with it. Generate a real key: openssl genpkey -algorithm ed25519 -outform DER | base64 | tr -d '\\n'" $path) -}}
{{- end -}}
{{- end -}}

{{/* Entry point, included from templates/namespace.yaml (the first resource of this sub-chart). */}}
{{- define "tool-runner.validate" -}}
{{- if not (mustRegexMatch "^https://[a-z0-9-]+\\.service-now\\.com/?$" (default "" .Values.instanceUrl | toString)) -}}
{{- fail "[tool-runner] tool-runner.instanceUrl must be an https://<name>.service-now.com URL." -}}
{{- end -}}
{{- if not (has (default "" .Values.instanceClass | toString) (list "dev" "test" "prod")) -}}
{{- fail "[tool-runner] tool-runner.instanceClass must be set to dev, test or prod. There is no default: write tools run on dev and test only, and the runner has to be told which kind of instance it talks to." -}}
{{- end -}}
{{- include "tool-runner.requireString" (dict "path" "tool-runner.principal" "value" .Values.principal "why" "It is the identity every receipt names.") -}}
{{- $policy := (default "" .Values.policy.json | toString) -}}
{{- if not (trim $policy) -}}
{{- fail "[tool-runner] tool-runner.policy.json is empty. Pass your policy file: --set-file tool-runner.policy.json=./policy.json" -}}
{{- end -}}
{{- $want := (default "" .Values.policy.sha256 | toString | lower) -}}
{{- if not (mustRegexMatch "^[0-9a-f]{64}$" $want) -}}
{{- fail "[tool-runner] tool-runner.policy.sha256 must be the sha256 of the policy file (64 hex characters). Print it with: bin/lucairn tool-policy digest ./policy.json" -}}
{{- end -}}
{{- if ne (sha256sum $policy) $want -}}
{{- fail (printf "[tool-runner] policy digest mismatch: tool-runner.policy.json has sha256 %s but tool-runner.policy.sha256 is %s. Review the policy file, then set the digest of the file you approved." (sha256sum $policy) $want) -}}
{{- end -}}
{{- $gw := (default "" .Values.gateway.url | toString) -}}
{{- if and $gw (not (mustRegexMatch "^https?://[A-Za-z0-9.-]+(:[0-9]{2,5})?/?$" $gw)) -}}
{{- fail "[tool-runner] tool-runner.gateway.url must be an http(s) origin without a path, or empty." -}}
{{- end -}}
{{- $sn := .Values.egress.servicenow -}}
{{- if and (not $sn.cidrs) (not $sn.allowAnyHttps) -}}
{{- fail "[tool-runner] tool-runner.egress.servicenow.cidrs is empty. List the CIDR ranges of your ServiceNow instance so the NetworkPolicy can allow exactly those on TCP 443, or set tool-runner.egress.servicenow.allowAnyHttps=true to allow TCP 443 to any public address on purpose." -}}
{{- end -}}
{{- if not (has .Values.secrets.backend (list "k8s-native" "vault" "aws" "azure")) -}}
{{- fail "[tool-runner] tool-runner.secrets.backend must be k8s-native, vault, aws or azure." -}}
{{- end -}}
{{- if eq .Values.secrets.backend "k8s-native" -}}
{{- $sv := (default (dict) .Values.secrets.values) -}}
{{- include "tool-runner.requireString" (dict "path" "tool-runner.secrets.values.servicenowUsername" "value" $sv.servicenowUsername "why" "It is the dedicated ServiceNow service account the runner signs in with.") -}}
{{- include "tool-runner.requireString" (dict "path" "tool-runner.secrets.values.servicenowPassword" "value" $sv.servicenowPassword "why" "It is the password of the dedicated ServiceNow service account. Pass it with --set-string or move this sub-chart to an external secrets backend.") -}}
{{- include "tool-runner.requireString" (dict "path" "tool-runner.secrets.values.signingKey" "value" $sv.signingKey "why" "It signs every receipt. Generate one: openssl genpkey -algorithm ed25519 -outform DER | base64 | tr -d '\\n'") -}}
{{- include "tool-runner.validateSigningKey" $sv.signingKey -}}
{{- $approver := (default "" $sv.approverSecret | toString) -}}
{{- if and $approver (not (mustRegexMatch "^[A-Za-z0-9_-]{43,128}$" $approver)) -}}
{{- fail "[tool-runner] tool-runner.secrets.values.approverSecret must be base64url, at least 43 characters, or empty (no write tools)." -}}
{{- end -}}
{{- end -}}
{{- /* Nothing may put a ServiceNow or Lucairn-key variable into the pod environment. */ -}}
{{- range $k, $_ := (default (dict) .Values.extraEnv) -}}
{{- if or (mustRegexMatch "(?i)^(SN|SNOW|SERVICENOW)_" $k) (eq (upper $k) "LUCAIRN_TOOL_RUNNER_GATEWAY_KEY") -}}
{{- fail (printf "[tool-runner] tool-runner.extraEnv.%s is refused: a ServiceNow credential or the Lucairn key never travels in the environment. Use tool-runner.secrets." $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}
