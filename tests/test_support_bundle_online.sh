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
  # Loud NOT RUN with exit 0, as the kit's other docker-dependent tests do
  # (scripts/run-tests.sh then lists the file as passed): this is NOT a pass.
  echo "  ## NOT RUN — docker compose CLI not available: the online support bundle (PRD criterion 5) was NOT tested here; this is NOT a pass (test_support_bundle_online)" >&2
  # Fix round 2 (B10): in CI a missing Compose must not read as a pass.
  if [ -n "${CI:-}" ]; then exit 1; fi
  exit 0
fi
REAL_DOCKER="$(command -v docker)"
TMPDIR="$(mktemp -d)"
# Fix round 1 (G9): the trap removes only the temp dir. The released-kit
# fixture (and the .lucairn-customer-id doctor writes into it) lives there; if
# the fixture copy fails, ROOT is still the real checkout and must not be touched.
trap 'rm -rf "$TMPDIR"' EXIT
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
SECRET_SUFFIX='T1479SuffixPlant7c4d'
SECRET_DSN='t1479-dsn-plant-pw-5c2e91'
SECRET_BEARER='t1479-stderr-bearer-plant-88aa'
PERSON_HOME='alex.quellenhof'

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
warn_secrets() {
  printf 'time="2026-11-21T07:50:01Z" level=warning msg="The \\\\"%s\\\\" variable is not set. Defaulting to a blank string."\n' '$SECRET_SUFFIX' >&2
  printf 'level=warning msg="ignoring DSA_LICENSE_KEY=%s"\n' '$SECRET_LICENSE' >&2
  printf 'level=warning msg="unreachable postgres://dsa:%s@db.internal:5432/audit"\n' '$SECRET_DSN' >&2
  printf 'level=warning msg="upstream answered for Authorization: Bearer %s"\n' '$SECRET_BEARER' >&2
  printf 'time="2026-11-21T07:50:01Z" level=warning msg="/home/%s/kit/docker-compose.customer.yml: the attribute version is obsolete"\n' '$PERSON_HOME' >&2
}
if [ -n "\${SHIM_CONFIG_FAIL:-}" ] && [ "\$is_compose" = 1 ] && [ "\$sub" = config ] && [ "\$has_format" = 0 ]; then
  echo 'service "gateway" refers to undefined volume x' >&2; exit 1
fi
if [ -n "\${SHIM_CONFIG_EMPTY:-}" ] && [ "\$is_compose" = 1 ] && [ "\$sub" = config ] && [ "\$has_format" = 0 ]; then
  exit 0
fi
if [ "\$is_compose" = 0 ] && [ "\${1:-}" = ps ]; then
  printf 'NAMES\tIMAGE\tSTATUS\tPORTS\nkit-gateway-1\tdsa-gateway:1.1.1\tUp (owner %s)\t127.0.0.1:8080\n' '$PERSON_EMAIL'
  exit 0
fi
if [ "\$is_compose" = 1 ] && [ "\$sub" = ps ]; then
  warn_secrets  # Fix round 2 (B1): 2.40.x warns on ps too
  echo "NAME SERVICE STATUS"; echo "kit-gateway-1 gateway running"; exit 0
fi
if [ "\$is_compose" = 1 ] && [ "\$sub" = logs ]; then
  warn_secrets  # Fix round 2 (B1): and on logs
  echo "gateway-1 | level=info msg=upstream authorization=\"Bearer $SECRET_LOG\" contact=$PERSON_EMAIL"
  echo "gateway-1  | container-stderr-line-kept" >&2
  exit 0
fi
if [ "\$is_compose" = 1 ] && [ "\$sub" = config ] && [ "\$has_format" = 0 ]; then
  # Fix round 2 (B10): the real Compose's own warnings are dropped so the
  # count below is exactly the shim's 8 on every Compose version.
  "\$real" "\$@" 2>/dev/null; rc=\$?
  for v in VEIL_WITNESS_PUBLIC_KEY VEIL_AUDIT_PUBLIC_KEY VEIL_SANDBOX_B_PUBLIC_KEY; do
    printf 'time="2026-11-21T07:50:01Z" level=warning msg="The \\\\"%s\\\\" variable is not set. Defaulting to a blank string."\n' "\$v" >&2
  done
  # Fix round 1 (G3): warnings that carry secret material or a name.
  warn_secrets
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
# Fix round 1 (G3): only the number of Compose's message lines and where to
# read them; never their text (8 lines: 3 VEIL_* warnings + 5 secret-bearing).
grep -q 'Docker Compose printed 8 message line(s)' "$MSG" || { echo "FAIL: compose-config-messages.txt does not give the count of Compose's 8 message lines" >&2; cat "$MSG" >&2; exit 1; }
! grep -q 'level=warning' "$MSG" || { echo "FAIL: Compose's warning text shipped in compose-config-messages.txt" >&2; exit 1; }
grep -q 'kit-gateway-1' "$EX"/*/docker/status.txt || { echo "FAIL: docker status not collected" >&2; exit 1; }
# Fix round 2 (B1): ps/logs keep their output, count Compose's own lines, ship no warning text.
grep -q 'kit-gateway-1 gateway running' "$EX"/*/docker/compose-ps.txt || { echo "FAIL: compose ps output missing" >&2; exit 1; }
grep -q 'printed 5 message line(s)' "$EX"/*/docker/compose-ps.txt || { echo "FAIL: compose-ps.txt lacks the count of 5" >&2; cat "$EX"/*/docker/compose-ps.txt >&2; exit 1; }
grep -q 'container-stderr-line-kept' "$EX"/*/logs/compose.log || { echo "FAIL: a container's stderr line was dropped from compose.log" >&2; exit 1; }
grep -q 'printed 5 line(s) of its own' "$EX"/*/logs/compose.log || { echo "FAIL: compose.log lacks the count of 5" >&2; cat "$EX"/*/logs/compose.log >&2; exit 1; }
! grep -rq 'level=warning' "$EX" || { echo "FAIL: Compose warning text shipped in the bundle" >&2; grep -rl 'level=warning' "$EX" >&2; exit 1; }

# Criterion 5: 0 hits for every plant, in the archive's bytes and in its files.
hits=0
for p in "$SECRET_LICENSE" "$SECRET_SIGNING" "$SECRET_SB" "$SECRET_LOG" "$PERSON_EMAIL" "$PERSON" \
  "$SECRET_SUFFIX" "$SECRET_DSN" "$SECRET_BEARER" "$PERSON_HOME"; do
  if grep -rqiF -- "$p" "$EX"; then echo "FAIL: planted value found in the bundle: ${p:0:8}..." >&2; hits=$((hits + 1)); fi
  if gzip -dc "$BUNDLE" | grep -qiF -- "$p"; then echo "FAIL: planted value found in the archive bytes: ${p:0:8}..." >&2; hits=$((hits + 1)); fi
done
[ "$hits" -eq 0 ] || exit 1

# Fix round 2 (B9): a failed `compose config` stops the bundle.
OUT2="$TMPDIR/bundles-fail"
rc=0
SHIM_CONFIG_FAIL=1 PATH="$SHIM:$PATH" "$ROOT/bin/lucairn" support-bundle \
  --env "$ENV_FILE" --compose "$ROOT/docker-compose.customer.yml" \
  --output "$OUT2" > "$TMPDIR/support-fail.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: bundle written although docker compose config failed" >&2; exit 1; }
grep -q 'compose config failed or rendered nothing' "$TMPDIR/support-fail.out" || { echo "FAIL: no clear message for the failed render" >&2; cat "$TMPDIR/support-fail.out" >&2; exit 1; }
[ -z "$(find "$OUT2" -name 'lucairn-support-bundle-*' -print -quit 2>/dev/null)" ] || { echo "FAIL: bundle files left after a failed render" >&2; exit 1; }
# Final fix pass: an empty render with exit 0 stops the bundle too.
OUT3="$TMPDIR/bundles-empty"
rc=0
SHIM_CONFIG_EMPTY=1 PATH="$SHIM:$PATH" "$ROOT/bin/lucairn" support-bundle \
  --env "$ENV_FILE" --compose "$ROOT/docker-compose.customer.yml" \
  --output "$OUT3" > "$TMPDIR/support-empty.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: bundle written although docker compose config rendered nothing" >&2; exit 1; }
grep -q 'compose config failed or rendered nothing (exit 0' "$TMPDIR/support-empty.out" || { echo "FAIL: no clear message for the empty render" >&2; cat "$TMPDIR/support-empty.out" >&2; exit 1; }
[ -z "$(find "$OUT3" -name 'lucairn-support-bundle-*' -print -quit 2>/dev/null)" ] || { echo "FAIL: bundle files left after an empty render" >&2; exit 1; }
echo "PASS: online support bundle produced; Compose messages kept apart; 0 hits for 10 plants; failed and empty renders refused"
