#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$ROOT/scripts/resolve-enterprise-mtls-kind-kubectl.sh"
HARNESS="$ROOT/scripts/test-enterprise-mtls-kind.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

[ -x "$RESOLVER" ] || {
  echo "missing executable Kind kubectl resolver" >&2
  exit 1
}

FAKE_BIN="$TMPDIR/fake-bin"
CALLS="$TMPDIR/calls"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
exit 0
KUBECTL
cat > "$FAKE_BIN/not-executable" <<'KUBECTL'
#!/usr/bin/env bash
exit 0
KUBECTL
cat > "$FAKE_BIN/kind" <<'TOOL'
#!/usr/bin/env bash
printf 'kind %s\n' "$*" >> "$KIND_RESOLVER_CALLS"
exit 91
TOOL
cat > "$FAKE_BIN/docker" <<'TOOL'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$KIND_RESOLVER_CALLS"
exit 91
TOOL
cat > "$FAKE_BIN/curl" <<'TOOL'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$KIND_RESOLVER_CALLS"
exit 91
TOOL
chmod 0700 "$FAKE_BIN/kubectl" "$FAKE_BIN/kind" "$FAKE_BIN/docker" "$FAKE_BIN/curl"

resolved="$(PATH="$FAKE_BIN:$PATH" "$RESOLVER")"
[ "$resolved" = "$FAKE_BIN/kubectl" ] || {
  echo "Kind kubectl resolver did not resolve executable kubectl from PATH" >&2
  exit 1
}

explicit="$TMPDIR/explicit-kubectl"
cp "$FAKE_BIN/kubectl" "$explicit"
chmod 0700 "$explicit"
resolved="$(KUBECTL="$explicit" PATH="$FAKE_BIN:$PATH" "$RESOLVER")"
[ "$resolved" = "$explicit" ] || {
  echo "Kind kubectl resolver did not preserve a valid explicit override" >&2
  exit 1
}

for invalid in "$FAKE_BIN/not-executable" 'relative/kubectl'; do
  if KUBECTL="$invalid" PATH="$FAKE_BIN:$PATH" "$RESOLVER" >"$TMPDIR/invalid.stdout" 2>"$TMPDIR/invalid.stderr"; then
    echo "Kind kubectl resolver accepted invalid override: $invalid" >&2
    exit 1
  fi
  [ ! -s "$TMPDIR/invalid.stdout" ] || {
    echo "Kind kubectl resolver printed an invalid override on stdout" >&2
    exit 1
  }
done

EMPTY_PATH="$TMPDIR/empty-path"
mkdir -p "$EMPTY_PATH"
if PATH="$EMPTY_PATH" /bin/bash "$RESOLVER" >"$TMPDIR/absent.stdout" 2>"$TMPDIR/absent.stderr"; then
  echo "Kind kubectl resolver accepted an absent kubectl" >&2
  exit 1
fi
grep -Fq 'kubectl is not installed as an executable file' "$TMPDIR/absent.stderr" \
  || { echo "Kind kubectl resolver missing absent-tool error" >&2; exit 1; }

# The harness resolves kubectl before it creates state, checks Kind/Docker, or
# installs its cleanup trap. A resolver failure therefore must cause no Kind,
# Docker, or network-tool invocation.
: > "$CALLS"
if KUBECTL="$FAKE_BIN/not-executable" PATH="$FAKE_BIN:$PATH" KIND_RESOLVER_CALLS="$CALLS" "$HARNESS" \
  >"$TMPDIR/harness.stdout" 2>"$TMPDIR/harness.stderr"; then
  echo "Kind harness accepted a non-executable kubectl override" >&2
  exit 1
fi
[ ! -s "$CALLS" ] || {
  cat "$CALLS" >&2
  echo "Kind harness performed a Kind, Docker, or network action after resolver failure" >&2
  exit 1
}
grep -Fq 'KUBECTL override is not an executable file' "$TMPDIR/harness.stderr" \
  || { echo "Kind harness did not surface resolver failure" >&2; exit 1; }

echo "enterprise mTLS Kind kubectl resolver: contract ok"
