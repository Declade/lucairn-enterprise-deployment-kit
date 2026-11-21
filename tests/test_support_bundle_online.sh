#!/usr/bin/env bash
set -euo pipefail

# T-1479 (kit customer install fix, slice 3, PRD criterion 5): the ONLINE
# support bundle (no --offline) must be produced, and must hold none of the
# secrets or the person name planted in the settings file.
#
# Shown on 21 Nov 2026 (Ubuntu 24.04, Docker Compose 2.40.3): every online
# bundle was refused with "redacted/compose-resolved.yml cannot be decoded
# exactly as yaml by Docker Compose: line 16", also on an untouched init env.
# Cause: support_bundle() captured `docker compose config 2>&1`, and Compose
# 2.40.x prints one "level=warning ... VEIL_* variable is not set" line on
# stderr for every nested `${LCR_X:-${VEIL_X}}` fallback (Compose 5 does not).
# Those lines became the head of the YAML file and the decoded scan refused it.
# Every other bundle test runs --offline, which never collects `config`.
#
# This host's Compose may not warn, so a docker shim adds such warning lines on
# stderr to every plain `compose ... config` (as 2.40.x does) and answers
# `ps` / `logs` / `docker ps` with fixed text that carries the plants (no
# daemon needed). Everything else, including the decoded scan's own
# `config --format json` calls, goes to the real Docker Compose.
# RED on origin/main 0ec6138 (refused, line N); GREEN with the fix.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "  NOT RUN — docker compose CLI not available (test_support_bundle_online)"
  exit 0
fi
REAL_DOCKER="$(command -v docker)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"; rm -f "$ROOT/.lucairn-customer-id"' EXIT
# shellcheck source=lib/test-helpers.sh
. "$ROOT/tests/lib/test-helpers.sh"
lucairn_use_released_kit "$TMPDIR"

# Distinctive synthetic plants (never real values).
SECRET_LICENSE='lcr_enterprise_t1479_plant_9f3c2a7d51'
SECRET_SIGNING='t1479-license-signing-plant-7be04c'
SECRET_SB='sk-t1479-sandbox-b-plant-c81d5e0a2f'
SECRET_LOG='t1479-log-token-plant-04aa9e7731'
PERSON_EMAIL='erika.quellenhof@customer.example'
PERSON='quellenhof'

ENV_FILE="$TMPDIR/customer.env"
init_args=(--dev --runtime-mode local-runtime --local-runtime llama-cpp
  --model-name acme-support-llm --model-file acme-support-q4.gguf --model-path .
  --output "$ENV_FILE" --skip-doctor)
"$ROOT/bin/lucairn-init" --confirm-no-registry-volume "${init_args[@]}" >/dev/null 2>&1 \
  || "$ROOT/bin/lucairn-init" "${init_args[@]}" >/dev/null 2>&1
sed -i.bak -e '/^DSA_LICENSE_KEY=/d' -e '/^DSA_LICENSE_SIGNING_KEY=/d' -e '/^SANDBOX_B_API_KEY=/d' "$ENV_FILE" && rm -f "$ENV_FILE.bak"
{
  printf 'DSA_LICENSE_KEY=%s\n' "$SECRET_LICENSE"
  printf 'DSA_LICENSE_SIGNING_KEY=%s\n' "$SECRET_SIGNING"
  printf 'SANDBOX_B_API_KEY=%s\n' "$SECRET_SB"
  printf 'LUCAIRN_OPS_CONTACT=%s\n' "$PERSON_EMAIL"
} >> "$ENV_FILE"

SHIM="$TMPDIR/shim"
mkdir -p "$SHIM"
cat > "$SHIM/docker" <<SHIMEOF
#!/usr/bin/env bash
real='$REAL_DOCKER'
is_compose=0 sub="" has_format=0
for a in "\$@"; do
  case "\$a" in
    compose) is_compose=1 ;;
    --format|--format=*) has_format=1 ;;
    config|ps|logs) [ -n "\$sub" ] || sub="\$a" ;;
  esac
done
if [ "\$is_compose" = 0 ] && [ "\${1:-}" = ps ]; then
  printf 'NAMES\tIMAGE\tSTATUS\tPORTS\nkit-gateway-1\tdsa-gateway:1.1.1\tUp (owner %s)\t127.0.0.1:8080\n' '$PERSON_EMAIL'
  exit 0
fi
if [ "\$is_compose" = 1 ] && [ "\$sub" = ps ]; then
  echo "NAME SERVICE STATUS"; echo "kit-gateway-1 gateway running"; exit 0
fi
if [ "\$is_compose" = 1 ] && [ "\$sub" = logs ]; then
  echo "gateway-1 | level=info msg=upstream authorization=\"Bearer $SECRET_LOG\" contact=$PERSON_EMAIL"
  exit 0
fi
if [ "\$is_compose" = 1 ] && [ "\$sub" = config ] && [ "\$has_format" = 0 ]; then
  "\$real" "\$@"; rc=\$?
  for v in VEIL_WITNESS_PUBLIC_KEY VEIL_AUDIT_PUBLIC_KEY VEIL_SANDBOX_B_PUBLIC_KEY; do
    printf 'time="2026-11-21T07:50:01Z" level=warning msg="The \\\\"%s\\\\" variable is not set. Defaulting to a blank string."\n' "\$v" >&2
  done
  exit \$rc
fi
exec "\$real" "\$@"
SHIMEOF
chmod +x "$SHIM/docker"

OUT="$TMPDIR/bundles"
rc=0
PATH="$SHIM:$PATH" "$ROOT/bin/lucairn" support-bundle \
  --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --output "$OUT" > "$TMPDIR/support.out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: online support-bundle exited $rc:" >&2
  cat "$TMPDIR/support.out" >&2
  exit 1
fi

BUNDLE="$(find "$OUT" -name 'lucairn-support-bundle-*.tar.gz' -print -quit)"
[ -n "$BUNDLE" ] || { echo "FAIL: no archive written" >&2; exit 1; }
tar -tzf "$BUNDLE" > "$TMPDIR/list"
grep -q '/redacted/compose-resolved.yml$' "$TMPDIR/list" || { echo "FAIL: compose-resolved.yml missing" >&2; exit 1; }
grep -q '/redacted/compose-config-messages.txt$' "$TMPDIR/list" || { echo "FAIL: compose-config-messages.txt missing" >&2; exit 1; }

EX="$TMPDIR/extracted"
mkdir -p "$EX"
tar -xzf "$BUNDLE" -C "$EX"
RES="$(find "$EX" -path '*/redacted/compose-resolved.yml' -print -quit)"
MSG="$(find "$EX" -path '*/redacted/compose-config-messages.txt' -print -quit)"
head -1 "$RES" | grep -q '^name: ' || { echo "FAIL: compose-resolved.yml does not start with the project (stderr mixed in?)" >&2; head -3 "$RES" >&2; exit 1; }
! grep -q 'level=warning' "$RES" || { echo "FAIL: Compose warnings inside compose-resolved.yml" >&2; exit 1; }
grep -q 'VEIL_WITNESS_PUBLIC_KEY' "$MSG" || { echo "FAIL: Compose's messages were dropped instead of kept as text" >&2; exit 1; }
grep -q 'kit-gateway-1' "$EX"/*/docker/status.txt || { echo "FAIL: docker status not collected" >&2; exit 1; }

# Criterion 5: 0 hits for every plant, in the archive's bytes and in its files.
hits=0
for p in "$SECRET_LICENSE" "$SECRET_SIGNING" "$SECRET_SB" "$SECRET_LOG" "$PERSON_EMAIL" "$PERSON"; do
  if grep -rqiF -- "$p" "$EX"; then echo "FAIL: planted value found in the bundle: ${p:0:8}..." >&2; hits=$((hits + 1)); fi
  if gzip -dc "$BUNDLE" | grep -qiF -- "$p"; then echo "FAIL: planted value found in the archive bytes: ${p:0:8}..." >&2; hits=$((hits + 1)); fi
done
[ "$hits" -eq 0 ] || exit 1
echo "PASS: online support bundle produced; Compose messages kept apart; 0 hits for 6 plants"
