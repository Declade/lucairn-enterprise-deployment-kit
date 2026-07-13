#!/usr/bin/env bash
set -euo pipefail

# Focused custody contract for the Kind public-overlay/private-Secret split.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
GENERATOR="$ROOT/scripts/generate-enterprise-mtls-kind-runtime-values.sh"
SIGNER="$ROOT/scripts/generate-enterprise-mtls-kind-signed-manifest.sh"
CUSTODY="$ROOT/scripts/assert-enterprise-mtls-release-custody.sh"
HARNESS="$ROOT/scripts/test-enterprise-mtls-kind.sh"
TMPDIR="$(mktemp -d)"
PUBLIC="$TMPDIR/public-overlay.yaml"
PRIVATE="$TMPDIR/application-secrets"
trap 'rm -rf "$TMPDIR"' EXIT

# GNU stat first: `stat -f '%Lp'` on GNU exits 1 for a %Lp file arg but still
# prints filesystem info to STDOUT, so a `-f … || -c …` chain captures garbage
# on Linux. BSD `stat -c` fails cleanly (stderr only), so `-c … || -f …` is
# correct on both platforms.
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
value() { awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$1"; }

"$GENERATOR" "$PUBLIC" "$PRIVATE" >"$TMPDIR/generator.out" 2>"$TMPDIR/generator.err"
[ ! -s "$TMPDIR/generator.out" ] && [ ! -s "$TMPDIR/generator.err" ] || { echo "custody generator must be silent" >&2; exit 1; }
[ "$(mode "$PUBLIC")" = 600 ] && [ "$(mode "$PRIVATE")" = 700 ] || { echo "public/private state modes drifted" >&2; exit 1; }

for service in gateway audit id-bridge sandbox-a sandbox-b veil-witness; do
  [ -f "$PRIVATE/$service.env" ] && [ "$(mode "$PRIVATE/$service.env")" = 600 ] || { echo "missing mode-0600 $service env" >&2; exit 1; }
done

ruby -ryaml - "$PUBLIC" "$PRIVATE" <<'RUBY'
overlay = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
expected = %w[veilAuditPublicKey veilBridgePublicKey veilGatewayManifestPublicKey veilGatewayPublicKey veilSandboxBPublicKey veilSanitizerPublicKey veilWitnessPublicKey]
abort "public key roster drift" unless overlay.fetch("kindPublicKeys").keys.sort == expected
abort "Kind public overlay must contain a disposable syntactically valid Vault HTTPS endpoint" unless overlay.dig("global", "secrets", "vault", "endpoint") == "https://vault.kind.invalid"
walk = lambda do |node|
  if node.is_a?(Hash)
    abort "public overlay contains secrets.values" if node["secrets"].is_a?(Hash) && node["secrets"].key?("values")
    node.each_value { |value| walk.call(value) }
  elsif node.is_a?(Array)
    node.each { |value| walk.call(value) }
  end
end
walk.call(overlay)
public_keys = %w[LCR_GATEWAY_PUBLIC_KEY LCR_GATEWAY_MANIFEST_PUBLIC_KEY LCR_WITNESS_MANIFEST_PUBLIC_KEY LCR_WITNESS_PUBLIC_KEY LCR_BRIDGE_PUBLIC_KEY LCR_SANITIZER_PUBLIC_KEY LCR_SANDBOX_B_PUBLIC_KEY LCR_AUDIT_PUBLIC_KEY]
private_values = Dir.children(ARGV.fetch(1)).grep(/\.env\z/).flat_map { |name| File.readlines(File.join(ARGV.fetch(1), name), chomp: true) }.map { |line| key, val = line.split("=", 2); val unless public_keys.include?(key) }.compact
text = File.read(ARGV.fetch(0))
private_values.each { |val| abort "private value in public overlay" if val && !val.empty? && text.include?(val) }
RUBY

ruby - "$PRIVATE" <<'RUBY'
directory = ARGV.fetch(0)
rosters = {
  "gateway" => %w[DSA_LICENSE_KEY DSA_LICENSE_SIGNING_KEY LUCAIRN_LICENSE_KEY LUCAIRN_LICENSE_PUBLIC_KEY DSA_ADMIN_KEY SANDBOX_B_API_KEY LCR_MANIFEST_SIGNING_KEY LCR_GATEWAY_SIGNING_KEY LCR_GATEWAY_PUBLIC_KEY LCR_GATEWAY_MANIFEST_PUBLIC_KEY LCR_WITNESS_MANIFEST_PUBLIC_KEY LCR_WITNESS_PUBLIC_KEY LCR_BRIDGE_PUBLIC_KEY LCR_SANITIZER_PUBLIC_KEY LCR_SANDBOX_B_PUBLIC_KEY LCR_AUDIT_PUBLIC_KEY LCR_AI_SIGNING_KEY DSA_SERVICE_TOKEN GATEWAY_KEYSTORE_KEY CANARY_HMAC_KEY],
  "audit" => %w[DATABASE_URL DATABASE_URL_APP POSTGRES_PASSWORD AUDIT_APP_PASSWORD LCR_SIGNING_KEY DSA_SERVICE_TOKEN],
  "id-bridge" => %w[DATABASE_URL POSTGRES_PASSWORD MASTER_KEY LCR_SIGNING_KEY DSA_BRIDGE_ENCRYPTION_KEY DSA_SERVICE_TOKEN],
  "sandbox-a" => %w[DATABASE_URL POSTGRES_PASSWORD ENCRYPTION_KEY DSA_ADMIN_KEY LCR_SIGNING_KEY DSA_SERVICE_TOKEN CANARY_HMAC_KEY MODEL_AUTH_SECRET],
  "sandbox-b" => %w[SANDBOX_B_REDIS_URL REDIS_PASSWORD ANTHROPIC_API_KEY MISTRAL_API_KEY OPENAI_API_KEY GEMINI_API_KEY LCR_SIGNING_KEY SANDBOX_B_API_KEYS DSA_ADMIN_KEY DSA_MANAGED_AI_KEY DSA_SERVICE_TOKEN DSA_LICENSE_KEY],
  "veil-witness" => %w[DATABASE_URL DATABASE_URL_APP POSTGRES_PASSWORD VEIL_APP_PASSWORD LCR_WITNESS_SIGNING_KEY LCR_WITNESS_KEY_ID]
}
rosters.each { |service, keys| actual = File.readlines(File.join(directory, "#{service}.env"), chomp: true).map { |line| line.split("=", 2).first }; abort "#{service} roster drift" unless actual.sort == keys.sort }
expected_dsn = {
  "audit" => ["DATABASE_URL", /\Apostgres:\/\/dsa:[0-9a-f]{64}@audit-postgresql:5432\/audit\?sslmode=disable\z/],
  "id-bridge" => ["DATABASE_URL", /\Apostgres:\/\/dsa:[0-9a-f]{64}@id-bridge-postgresql:5432\/bridge\?sslmode=disable\z/],
  "sandbox-a" => ["DATABASE_URL", /\Apostgres:\/\/dsa:[0-9a-f]{64}@sandbox-a-postgresql:5432\/sandbox_a\?sslmode=disable\z/],
  "veil-witness" => ["DATABASE_URL", /\Apostgres:\/\/veil:[0-9a-f]{64}@veil-witness-postgresql:5432\/veil\?sslmode=disable\z/]
}
expected_dsn.each do |service, (key, pattern)|
  values = File.readlines(File.join(directory, "#{service}.env"), chomp: true).map { |line| line.split("=", 2) }.to_h
  abort "#{service} bundled database DSN drift" unless values.fetch(key).match?(pattern)
end
RUBY

derive="$ROOT/scripts/derive-veil-pubkey.sh"
public_key() { ruby -ryaml -e 'print YAML.safe_load(File.read(ARGV[0])).fetch("kindPublicKeys").fetch(ARGV[1])' "$PUBLIC" "$1"; }
for pair in \
  'audit LCR_SIGNING_KEY veilAuditPublicKey' \
  'id-bridge LCR_SIGNING_KEY veilBridgePublicKey' \
  'sandbox-a LCR_SIGNING_KEY veilSanitizerPublicKey' \
  'sandbox-b LCR_SIGNING_KEY veilSandboxBPublicKey' \
  'veil-witness LCR_WITNESS_SIGNING_KEY veilWitnessPublicKey' \
  'gateway LCR_GATEWAY_SIGNING_KEY veilGatewayPublicKey' \
  'gateway LCR_MANIFEST_SIGNING_KEY veilGatewayManifestPublicKey'; do
  set -- $pair
  [ "$(printf '%s' "$(value "$PRIVATE/$1.env" "$2")" | "$derive")" = "$(public_key "$3")" ] || { echo "keypair drift: $1" >&2; exit 1; }
done
token="$(value "$PRIVATE/gateway.env" DSA_SERVICE_TOKEN)"
for service in audit id-bridge sandbox-a sandbox-b; do [ "$token" = "$(value "$PRIVATE/$service.env" DSA_SERVICE_TOKEN)" ] || exit 1; done
[ "$(value "$PRIVATE/gateway.env" DSA_ADMIN_KEY)" = "$(value "$PRIVATE/sandbox-a.env" DSA_ADMIN_KEY)" ]
[ "$(value "$PRIVATE/gateway.env" DSA_ADMIN_KEY)" = "$(value "$PRIVATE/sandbox-b.env" DSA_ADMIN_KEY)" ]
[ "$(value "$PRIVATE/gateway.env" SANDBOX_B_API_KEY)" = "$(value "$PRIVATE/sandbox-b.env" SANDBOX_B_API_KEYS)" ]
[ "$(value "$PRIVATE/gateway.env" CANARY_HMAC_KEY)" = "$(value "$PRIVATE/sandbox-a.env" CANARY_HMAC_KEY)" ]
[ "$(value "$PRIVATE/gateway.env" LCR_AI_SIGNING_KEY)" = "$(value "$PRIVATE/sandbox-b.env" LCR_SIGNING_KEY)" ]

# Signer receives public YAML and private files; its host Docker invocation
# must contain only mounts/paths, never the witness seed.
FAKE_BIN="$TMPDIR/fake-bin"
mkdir "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
seed="$(awk -F= '$1 == "LCR_WITNESS_SIGNING_KEY" { sub(/^[^=]*=/, ""); print; exit }' "$PRIVATE/veil-witness.env")"
[[ "$*" != *"$seed"* ]] || exit 91
keys_mount=""
seed_mount=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-v" ]; then
    case "${args[$((i + 1))]}" in
      *:/keys.json:ro) keys_mount="${args[$((i + 1))]}" ;;
      *:/run/secrets/witness-signing-key-hex:ro) seed_mount="${args[$((i + 1))]}" ;;
    esac
  fi
done
keys_json="${keys_mount%:/keys.json:ro}"
seed_file="${seed_mount%:/run/secrets/witness-signing-key-hex:ro}"
[ -f "$keys_json" ] && [ -f "$seed_file" ] || exit 92
[ "$(stat -c '%a' "$seed_file" 2>/dev/null || stat -f '%Lp' "$seed_file")" = 600 ] || exit 93
[ "$(cat "$seed_file")" = "$seed" ] || exit 94
PUBLIC="$PUBLIC" ruby -rjson -ryaml -e '
  keys = YAML.safe_load(File.read(ENV.fetch("PUBLIC"))).fetch("kindPublicKeys")
  public = %w[veilWitnessPublicKey veilBridgePublicKey veilSanitizerPublicKey veilSandboxBPublicKey veilAuditPublicKey veilGatewayManifestPublicKey].map { |key| keys.fetch(key) }.uniq.sort
  roster = JSON.parse(File.read(ARGV.fetch(0)))
  abort unless roster.length == 7 && roster.map { |item| item.fetch("public_key") }.uniq.sort == public
' "$keys_json"
printf '%s\n' '{"mock":"signed"}'
DOCKER
chmod 0700 "$FAKE_BIN/docker"
PRIVATE="$PRIVATE" PUBLIC="$PUBLIC" PATH="$FAKE_BIN:$PATH" "$SIGNER" "$PUBLIC" "$PRIVATE" "$TMPDIR/signed.json" >"$TMPDIR/signer.out" 2>"$TMPDIR/signer.err"
[ ! -s "$TMPDIR/signer.out" ] && [ ! -s "$TMPDIR/signer.err" ] && [ "$(mode "$TMPDIR/signed.json")" = 600 ] || { echo "signer custody or mode regression" >&2; exit 1; }

if command -v helm >/dev/null 2>&1; then
  REAL_HELM="$(command -v helm)"
  mkdir "$TMPDIR/helm-bin"
  cat > "$TMPDIR/helm-bin/helm" <<'HELM'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$DOCTOR_ARGV"
exec "$REAL_HELM" "$@"
HELM
  chmod 0700 "$TMPDIR/helm-bin/helm"
  DOCTOR_ARGV="$TMPDIR/doctor-argv" REAL_HELM="$REAL_HELM" PATH="$TMPDIR/helm-bin:$PATH" \
    "$ROOT/bin/lucairn" doctor --values "$CHART/values-prod.yaml" --values "$PUBLIC" --offline >"$TMPDIR/doctor.out"
  grep -Fq 'enterprise mTLS (Helm): production render contract: ok' "$TMPDIR/doctor.out" || { echo "ordered production doctor rejected public overlay" >&2; exit 1; }
  if tr '\0' '\n' < "$TMPDIR/doctor-argv" | grep -Fq '1111111111111111111111111111111111111111111111111111111111111111'; then echo "doctor injected fixed signing literal" >&2; exit 1; fi
  helm template lucairn "$CHART" -f "$CHART/values-prod.yaml" -f "$PUBLIC" >"$TMPDIR/render.yaml"
  ruby -ryaml - "$TMPDIR/render.yaml" <<'RUBY'
documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
external = documents.map { |doc| doc.dig("metadata", "name") if doc["kind"] == "ExternalSecret" }.compact
abort "expected six ExternalSecrets" unless external.length == 6
abort "expected one ClusterSecretStore" unless documents.count { |doc| doc["kind"] == "ClusterSecretStore" } == 1
abort "Helm-owned Secret rendered" if documents.any? { |doc| doc["kind"] == "Secret" }
RUBY
fi

# The API fixture is exactly the two structural v1beta1 CRDs. The harness only
# waits for Established, pre-creates six target Secrets, keeps external
# backends, and does not claim live ESO reconciliation.
ruby -ryaml - "$CHART/tests/fixtures/kind-external-secrets-crds.yaml" <<'RUBY'
docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
abort unless docs.map { |doc| doc.dig("metadata", "name") }.sort == %w[clustersecretstores.external-secrets.io externalsecrets.external-secrets.io]
docs.each { |doc| schema = doc.dig("spec", "versions", 0, "schema", "openAPIV3Schema"); abort unless doc.dig("spec", "versions", 0, "name") == "v1beta1" && schema["type"] == "object" && schema["x-kubernetes-preserve-unknown-fields"] == true }
RUBY
for required in 'apply -f "$EXTERNAL_SECRETS_CRDS"' 'for crd in externalsecrets.external-secrets.io clustersecretstores.external-secrets.io' 'wait --for=condition=Established "crd/$crd"' '--from-env-file=' 'create_application_secret dsa-edge gateway' 'create_application_secret dsa-witness veil-witness' 'helm get values' 'helm get manifest' 'helm get all' 'does not prove live ESO reconciliation'; do grep -Fq -- "$required" "$HARNESS" || { echo "harness omits $required" >&2; exit 1; }; done
if grep -Eq 'RUNTIME_VALUES|secrets\.backend=k8s-native|helm.*APPLICATION_SECRETS' "$HARNESS"; then echo "harness retains secret-bearing Helm bypass" >&2; exit 1; fi
if grep -Eiq 'external-secrets.*(controller|deployment)|wait .*externalsecret|wait .*clustersecretstore' "$HARNESS"; then echo "harness waits for live ESO" >&2; exit 1; fi
grep -Fq 'does not prove live ESO reconciliation' "$ROOT/docs/CUSTOMER_HELM_RUNBOOK.md" || { echo "production runbook omits no-live-ESO boundary" >&2; exit 1; }

mkdir "$TMPDIR/release-private"
printf '%s\n' 'PRIVATE_SENTINEL=do-not-retain-this-private-release-value' >"$TMPDIR/release-private/gateway.env"
printf '%s\n' safe >"$TMPDIR/values"
printf '%s\n' safe >"$TMPDIR/manifest"
printf '%s\n' safe >"$TMPDIR/all"
"$CUSTODY" "$TMPDIR/release-private" "$TMPDIR/values" "$TMPDIR/manifest" "$TMPDIR/all"
printf '%s\n' do-not-retain-this-private-release-value >"$TMPDIR/manifest"
if "$CUSTODY" "$TMPDIR/release-private" "$TMPDIR/values" "$TMPDIR/manifest" "$TMPDIR/all" >"$TMPDIR/custody.out" 2>"$TMPDIR/custody.err"; then echo "custody sweep accepted sentinel" >&2; exit 1; fi
grep -Fq 'Helm manifest output' "$TMPDIR/custody.err" || exit 1

echo "enterprise mTLS Kind custody split: ok"
