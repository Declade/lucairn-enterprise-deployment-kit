#!/usr/bin/env bash
set -uo pipefail

# T-1479 (kit customer install fix, slice 3, PRD criterion 3).
#  A. doctor lists every failed check in one run (it used to stop at the
#     first one, so a customer fixed failures one run at a time; 21 Nov:
#     five offline runs, each showing one new failure).
#  B. the image check reaches a plain-HTTP registry on a loopback address
#     the way `docker pull` does (21 Nov: every image "not pullable" from a
#     127.0.0.1:5000 mirror that docker pull used), and a missing image there
#     still fails; a non-loopback registry the daemon does not list as
#     insecure never gets --insecure.
# RED on origin/main 0ec6138 (A: one failure line, B: loopback refs fail).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
# Fix round 1 (G9): the trap removes only the temp dir. The released-kit
# fixture (and the .lucairn-customer-id doctor writes into it) lives there; if
# the fixture copy fails, ROOT is still the real checkout and must not be touched.
trap 'rm -rf "$TMPDIR"' EXIT
# shellcheck source=lib/test-helpers.sh
. "$ROOT/tests/lib/test-helpers.sh"
REAL_ROOT="$ROOT"
lucairn_use_released_kit "$TMPDIR"
FAILS=0
ok() { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1" >&2; FAILS=$((FAILS + 1)); }

echo "A. doctor lists every failure in one run"
ENV_FILE="$TMPDIR/customer.env"
init_args=(--dev --runtime-mode local-runtime --local-runtime llama-cpp
  --model-name acme-support-llm --model-file acme-support-q4.gguf --model-path .
  --output "$ENV_FILE" --skip-doctor)
"$ROOT/bin/lucairn-init" --confirm-no-registry-volume "${init_args[@]}" >/dev/null 2>&1 \
  || "$ROOT/bin/lucairn-init" "${init_args[@]}" >/dev/null 2>&1
if "$ROOT/bin/lucairn" doctor --env "$ENV_FILE" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check > "$TMPDIR/clean.out" 2>&1; then
  ok "fixture: the untouched init env passes offline"
else
  bad "fixture: the untouched init env passes offline ($(grep -i failed "$TMPDIR/clean.out" | head -2 | tr '\n' ' '))"
fi
# Two independent faults, in two different checks.
sed -i.bak -e '/^GATEWAY_KEYSTORE_KEY=/d' "$ENV_FILE" && rm -f "$ENV_FILE.bak"
printf 'GATEWAY_KEYSTORE_KEY=c2hvcnQta2V5LW5vdC0zMi1ieXRlcw==\nGATEWAY_SANITIZER_PROTOCOL=Delta\n' >> "$ENV_FILE"
rc=0
"$ROOT/bin/lucairn" doctor --env "$ENV_FILE" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check > "$TMPDIR/two.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "two faults -> non-zero exit ($rc)" || bad "two faults -> doctor exited 0"
grep -qi "GATEWAY_KEYSTORE_KEY" "$TMPDIR/two.out" && ok "first fault reported (keystore key not 32 bytes)" || bad "first fault not reported"
grep -q "GATEWAY_SANITIZER_PROTOCOL must be delta or whole" "$TMPDIR/two.out" && ok "second fault reported in the same run" || bad "second fault not reported in the same run (doctor stopped at the first)"
grep -q '^doctor: failed' "$TMPDIR/two.out" && ok "closing line says doctor: failed" || bad "no closing 'doctor: failed' line"
! grep -q '^doctor: ok' "$TMPDIR/two.out" && ok "no 'doctor: ok' on a failing run" || bad "'doctor: ok' printed on a failing run"

echo "C. after a failure, no check sends a credential or writes (fix round 1, G4)"
# Dashboard enabled with an admin URL and an audit database: a clean run sends
# X-Admin-Key and runs the INSERT/DELETE probe (control); with a bad keystore
# key neither may happen. curl, psql and pg_isready are stubs that log calls.
DASH_ENV="$TMPDIR/dash.env"
"$ROOT/bin/lucairn-init" --confirm-no-registry-volume "${init_args[@]/$ENV_FILE/$DASH_ENV}" >/dev/null 2>&1 \
  || "$ROOT/bin/lucairn-init" "${init_args[@]/$ENV_FILE/$DASH_ENV}" >/dev/null 2>&1
cat >> "$DASH_ENV" <<'EOV'
LUCAIRN_DASHBOARD_ENABLED=true
LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD=t1479-dash-bootstrap-plant
LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL=http://gw.example.internal:8080
LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN=t1479adminkeyplant0123456789abcdef0123456789
LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL=postgres://audit_app:t1479-audit-pw-plant@db.example.internal:5432/audit
EOV
CSTUB="$TMPDIR/cstub"; mkdir -p "$CSTUB"
for t in curl psql pg_isready; do
  cat > "$CSTUB/$t" <<EOS
#!/usr/bin/env bash
{ printf '$t %s\n' "\$*"; case " \$* " in *" @- "*) cat ;; esac; } >> "$TMPDIR/calls.log"
[ "$t" = curl ] && printf 200
exit 0
EOS
  chmod +x "$CSTUB/$t"
done
run_dash() { : > "$TMPDIR/calls.log"; PATH="$CSTUB:$PATH" "$ROOT/bin/lucairn" doctor --env "$1" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check > "$2" 2>&1 < /dev/null; }
run_dash "$DASH_ENV" "$TMPDIR/dash-clean.out"
grep -q '^X-Admin-Key: ' "$TMPDIR/calls.log" && grep -q 'INSERT INTO dashboard_saved_filters' "$TMPDIR/calls.log" \
  && ok "control: a clean run sends the admin key and runs the INSERT probe (the stubs are reached)" \
  || bad "control: the clean run did not reach the admin-key request and the INSERT probe ($(grep -i 'dashboard\|doctor:' "$TMPDIR/dash-clean.out" | tail -3 | tr '\n' ' '))"
sed -i.bak -e '/^GATEWAY_KEYSTORE_KEY=/d' "$DASH_ENV" && rm -f "$DASH_ENV.bak"
printf 'GATEWAY_KEYSTORE_KEY=c2hvcnQta2V5LW5vdC0zMi1ieXRlcw==\n' >> "$DASH_ENV"
rc=0; run_dash "$DASH_ENV" "$TMPDIR/dash-bad.out" || rc=$?
[ "$rc" -ne 0 ] && ok "bad keystore key: doctor fails ($rc)" || bad "bad keystore key: doctor exited 0"
! grep -q 'X-Admin-Key' "$TMPDIR/calls.log" && ok "bad keystore key: no admin-key request" || bad "bad keystore key: the admin key was sent"
! grep -q 'INSERT' "$TMPDIR/calls.log" && ok "bad keystore key: no INSERT probe" || bad "bad keystore key: the INSERT probe ran"
[ ! -s "$TMPDIR/calls.log" ] && ok "bad keystore key: no curl, psql or pg_isready call at all" || bad "bad keystore key: calls made: $(cut -c1-80 "$TMPDIR/calls.log" | tr '\n' ' ')"
grep -q '^dashboard: not run (an earlier check failed' "$TMPDIR/dash-bad.out" && ok "bad keystore key: dashboard line says not run" || bad "bad keystore key: no 'dashboard: not run' line"
grep -q '^doctor: failed' "$TMPDIR/dash-bad.out" && ok "bad keystore key: closing line doctor: failed" || bad "bad keystore key: no closing line"

echo "D. a missing certificate file does not end doctor early (fix round 1, G5)"
CERT_ENV="$TMPDIR/cert.env"
"$ROOT/bin/lucairn-init" --confirm-no-registry-volume "${init_args[@]/$ENV_FILE/$CERT_ENV}" >/dev/null 2>&1 \
  || "$ROOT/bin/lucairn-init" "${init_args[@]/$ENV_FILE/$CERT_ENV}" >/dev/null 2>&1
sed -i.bak -e '/^GRPC_TLS_CERT_FILE=/d' "$CERT_ENV" && rm -f "$CERT_ENV.bak"
printf 'GRPC_TLS_CERT_FILE=%s\nGATEWAY_SANITIZER_PROTOCOL=Delta\n' "$TMPDIR/no-such-cert.pem" >> "$CERT_ENV"
rc=0
"$ROOT/bin/lucairn" doctor --env "$CERT_ENV" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check > "$TMPDIR/cert.out" 2>&1 < /dev/null || rc=$?
[ "$rc" -ne 0 ] && ok "missing cert: non-zero exit ($rc)" || bad "missing cert: doctor exited 0"
grep -q 'certs: missing GRPC_TLS_CERT_FILE' "$TMPDIR/cert.out" && ok "missing cert reported" || bad "missing cert not reported"
grep -q "GATEWAY_SANITIZER_PROTOCOL must be delta or whole" "$TMPDIR/cert.out" && ok "a later fault is reported in the same run" || bad "doctor ended at the certificate check (later fault not reported)"
grep -q '^doctor: failed' "$TMPDIR/cert.out" && ok "closing line doctor: failed after a certificate failure" || bad "no closing 'doctor: failed' line after a certificate failure"

echo "B. image check against a loopback plain-HTTP mirror"
STUB="$TMPDIR/stub"
mkdir -p "$STUB"
cat > "$STUB/docker" <<'EOF'
#!/usr/bin/env bash
# `manifest inspect` without --insecure: HTTPS only, nothing answers it.
# With --insecure: the mirror holds only the refs in $STUB_PRESENT.
printf '%s\n' "$*" >> "$STUB_LOG"
if [ "$1" = manifest ] && [ "$2" = inspect ]; then
  if [ "$3" = --insecure ]; then grep -qxF -- "$4" "$STUB_PRESENT" && exit 0; fi
  echo "no such manifest: ${*: -1}" >&2; exit 1
fi
if [ "$1" = info ]; then
  [ "${STUB_INFO_FAIL:-0}" = 1 ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
  case "$*" in
    *json*)
      if [ -n "${STUB_REGCFG:-}" ]; then printf '%s\n' "$STUB_REGCFG"
      else printf '%s\n' '{"InsecureRegistryCIDRs":["::1/128","127.0.0.0/8"],"IndexConfigs":{"docker.io":{"Name":"docker.io","Secure":true},"mirror.corp.example:5000":{"Name":"mirror.corp.example:5000","Secure":false}}}'
      fi ;;
    *) printf 'mirror.corp.example:5000\n' ;;
  esac
  exit 0
fi
exit 1
EOF
chmod +x "$STUB/docker"
export STUB_LOG="$TMPDIR/docker.log" STUB_PRESENT="$TMPDIR/present"
printf '%s\n' '127.0.0.1:5000/declade/dsa-gateway:1.1.1' 'localhost:5000/declade/dsa-gateway:1.1.1' \
  '127.0.0.1:5000/declade/dsa-sanitizer-core:1.1.1@sha256:aaaa' 'mirror.corp.example:5000/declade/dsa-gateway:1.1.1' \
  'registry.corp.example/declade/dsa-gateway:1.1.1' 'loopback:5000/declade/dsa-gateway:1.1.1' \
  '[::1]:5000/declade/dsa-gateway:1.1.1' '10.1.2.3:5000/declade/dsa-gateway:1.1.1' \
  '127.0.0.1.evil.example/declade/dsa-gateway:1.1.1' 'localhost.example.com/declade/dsa-gateway:1.1.1' > "$STUB_PRESENT"
eval "$(sed -n '/^image_ref_inspectable()/,/^}/p' "$REAL_ROOT/bin/lucairn")"
if ! declare -F image_ref_inspectable >/dev/null; then
  bad "bin/lucairn has no image_ref_inspectable (the image check uses a bare docker manifest inspect)"
else
  probe() { PATH="$STUB:$PATH" image_ref_inspectable "$1"; }
  probe 127.0.0.1:5000/declade/dsa-gateway:1.1.1 && ok "loopback mirror image found" || bad "loopback mirror image not found"
  probe localhost:5000/declade/dsa-gateway:1.1.1 && ok "localhost mirror image found" || bad "localhost mirror image not found"
  probe '127.0.0.1:5000/declade/dsa-sanitizer-core:1.1.1@sha256:aaaa' && ok "loopback digest-pinned ref found" || bad "loopback digest-pinned ref not found"
  probe 127.0.0.1:5000/declade/dsa-gateway:9.9.9 && bad "missing tag on the loopback mirror passed" || ok "missing tag on the loopback mirror still fails"
  probe '127.0.0.1:5000/declade/dsa-sanitizer-core:1.1.1@sha256:bbbb' && bad "wrong digest on the loopback mirror passed" || ok "wrong digest on the loopback mirror still fails"
  probe mirror.corp.example:5000/declade/dsa-gateway:1.1.1 && ok "registry the daemon lists as insecure found" || bad "daemon-listed insecure registry not found"
  : > "$STUB_LOG"
  probe registry.corp.example/declade/dsa-gateway:1.1.1 && bad "a secure registry was asked over --insecure" || ok "a registry the daemon does not list as insecure is not retried insecurely"
  ! grep -q -- '--insecure registry.corp.example' "$STUB_LOG" && ok "no --insecure call for it" || bad "--insecure call for a secure registry"
  probe '[::1]:5000/declade/dsa-gateway:1.1.1' && ok "[::1] mirror image found" || bad "[::1] mirror image not found"
  # Fix round 1 (G1): a host NAME is never loopback, whatever it is called;
  # each is asked over HTTPS only (log-based: the refs are on the mirror, so
  # an --insecure call would have found them).
  for h in loopback:5000 127.0.0.1.evil.example localhost.example.com; do
    : > "$STUB_LOG"
    probe "$h/declade/dsa-gateway:1.1.1" && bad "$h: a host name was reached over --insecure" || ok "$h: not found over HTTPS, not retried"
    ! grep -q -- "--insecure $h/" "$STUB_LOG" && ok "$h: no --insecure call" || bad "$h: --insecure call for a host name"
  done
  # Fix round 1 (G2): the daemon's own answer decides (IndexConfigs and
  # InsecureRegistryCIDRs of docker info), never a built-in loopback rule.
  probe 10.1.2.3:5000/declade/dsa-gateway:1.1.1 && bad "10.1.2.3 retried insecurely without a daemon CIDR" || ok "10.1.2.3 without a daemon CIDR: not retried"
  STUB_REGCFG='{"InsecureRegistryCIDRs":["10.0.0.0/8"],"IndexConfigs":{}}' probe 10.1.2.3:5000/declade/dsa-gateway:1.1.1 \
    && ok "registry allowed by the daemon's CIDR list only: found" || bad "registry allowed by the daemon's CIDR list only: not found"
  : > "$STUB_LOG"
  STUB_REGCFG='{"InsecureRegistryCIDRs":[],"IndexConfigs":{"docker.io":{"Name":"docker.io","Secure":true}}}' probe 127.0.0.1:5000/declade/dsa-gateway:1.1.1 \
    && bad "engine with an empty insecure list (29.10): loopback accepted although docker pull refuses it" || ok "engine with an empty insecure list: loopback not retried insecurely"
  ! grep -q -- '--insecure' "$STUB_LOG" && ok "empty insecure list: no --insecure call" || bad "empty insecure list: --insecure call"
  : > "$STUB_LOG"
  STUB_INFO_FAIL=1 probe 127.0.0.1:5000/declade/dsa-gateway:1.1.1 && bad "daemon answer unreadable: retried insecurely" || ok "daemon answer unreadable: not retried insecurely"
  ! grep -q -- '--insecure' "$STUB_LOG" && ok "daemon answer unreadable: no --insecure call" || bad "daemon answer unreadable: --insecure call"
fi

echo ""
if [ "$FAILS" -eq 0 ]; then echo "PASS: doctor all-failures + loopback image check"; else echo "$FAILS check(s) FAILED"; exit 1; fi
