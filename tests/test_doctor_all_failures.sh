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
trap 'rm -rf "$TMPDIR"; rm -f "$ROOT/.lucairn-customer-id"' EXIT
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
