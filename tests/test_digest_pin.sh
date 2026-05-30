#!/usr/bin/env bash
# test_digest_pin.sh — tests for B1 Slice 3 (digest-pin + `doctor --strict`).
#
# Covers, WITHOUT docker/crane/skopeo/cosign/GHCR creds (so it runs in the
# static gate like test_sbom.sh):
#   1. bash -n syntax.
#   2. usage() advertises `doctor --strict` and distinguishes it from
#      --strict-runtime.
#   3. parse_image_digests parses the real image-manifest.yaml block: 14 real
#      digests + 7 pending entries (Bash-only, deterministic).
#   4. The manifest digest block stays the SINGLE-SOURCE-of-truth lockstep with
#      keys/image-digests-<tag>.txt for the 13 signed artifacts.
#   5. check_image_digests with a STUB resolver:
#        a. all refs resolve to their recorded digest  -> normal rc=0, strict rc=0.
#        b. one tampered manifest digest               -> normal rc=0 (warn-only),
#                                                         strict rc!=0 (BLOCKS).
#        c. pending entries are SKIPPED in both modes (never block under --strict).
#        d. no resolver on PATH                         -> SKIP (strict rc=0): a
#                                                         "cannot verify" host
#                                                         never blocks a fresh
#                                                         install.
#
# The "resolver" is a fake `crane` shim that, for any ref, echoes the digest the
# manifest records for that ref (so a clean manifest => all match). The tamper
# test edits a COPY of the manifest and asserts --strict flips to a block. A
# real registry round-trip (`image_current_digest` over the network) is the
# post-merge Vast edge-verify (PRD § Acceptance / Slice 3) — NOT covered here.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/lucairn"
MANIFEST="$ROOT/image-manifest.yaml"
DIGESTS_FILE="$ROOT/keys/image-digests-0.5.0.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Syntax.
# ---------------------------------------------------------------------------
bash -n "$CLI"
echo "digest-pin: bash -n syntax ok"

# ---------------------------------------------------------------------------
# 2. usage() advertises doctor --strict and distinguishes it from
#    --strict-runtime.
# ---------------------------------------------------------------------------
"$CLI" --help > "$TMP/help.out" 2>&1 || true
grep -q -- "--strict\b" "$TMP/help.out" || fail "usage() does not advertise --strict"
grep -q -- "--strict-runtime" "$TMP/help.out" || fail "usage() lost --strict-runtime"
grep -qi "image DIGEST" "$TMP/help.out" \
  || fail "usage() does not describe --strict as digest enforcement"
echo "digest-pin: usage advertises --strict (distinct from --strict-runtime) ok"

# ---------------------------------------------------------------------------
# 3. parse_image_digests parses the real manifest: 14 real digests + 7 pending.
#    Source the CLI with EMPTY args so the trailing `main "$@"` becomes
#    `main` -> usage (harmless, no exit), making the helper functions callable.
# ---------------------------------------------------------------------------
PARSED="$(
  set --
  source "$CLI" >/dev/null 2>&1
  parse_image_digests "$MANIFEST"
)"
real_count="$(printf '%s\n' "$PARSED" | grep -c $'\tsha256:' || true)"
pending_count="$(printf '%s\n' "$PARSED" | grep -c $'\tPENDING' || true)"
[ "$real_count" = "14" ] \
  || fail "expected 14 real-digest entries (13 signed + ollama), got $real_count"
[ "$pending_count" = "7" ] \
  || fail "expected 7 pending entries (qwen model + 6 runtime), got $pending_count"
# Spot-check the gateway ref maps to its recorded digest.
printf '%s\n' "$PARSED" \
  | grep -q "^ghcr.io/declade/dsa-gateway:0.5.0	sha256:4c969d401356c7ffb9862e38a77a4ffae36a2a27573cb2e61c9cfe280e6d7a8a$" \
  || fail "parse_image_digests did not map the gateway ref to its recorded digest"
echo "digest-pin: parse_image_digests reads 14 real + 7 pending entries ok"

# ---------------------------------------------------------------------------
# 4. Lockstep: every signed artifact in keys/image-digests-0.5.0.txt must appear
#    in the manifest digest block with the IDENTICAL digest (the manifest folds
#    in the cosign-signed digests; drift here breaks --strict vs verify-images).
# ---------------------------------------------------------------------------
while IFS= read -r line; do
  line="${line%%#*}"
  ref="${line%% *}"; rec="${line##* }"
  ref="${ref#"${ref%%[![:space:]]*}"}"; ref="${ref%"${ref##*[![:space:]]}"}"
  [ -n "$ref" ] || continue
  case "$rec" in sha256:*) ;; *) continue ;; esac
  printf '%s\n' "$PARSED" | grep -q "^${ref}	${rec}$" \
    || fail "lockstep: $ref $rec is in keys/image-digests-0.5.0.txt but not (identically) in the manifest digest block"
done < "$DIGESTS_FILE"
echo "digest-pin: manifest digest block is in lockstep with keys/image-digests-0.5.0.txt ok"

# ---------------------------------------------------------------------------
# Build an isolated kit ROOT so the CLI's ROOT="$(cd "$(dirname "$0")/..")"
# resolves to our test tree (with a controllable manifest), and a stub `crane`
# resolver that maps each ref to the digest a GIVEN manifest records for it.
# A driver script under $KROOT/bin sources the CLI with empty args and calls
# check_image_digests, so we exercise the real code path (env-tag override,
# resolver dispatch, strict gating) without a live registry.
# ---------------------------------------------------------------------------
make_kit_root() {
  # $1 = manifest file to install at <root>/image-manifest.yaml
  local src_manifest="$1" kroot
  kroot="$(mktemp -d)"
  mkdir -p "$kroot/bin"
  cp "$CLI" "$kroot/bin/lucairn"
  cp "$src_manifest" "$kroot/image-manifest.yaml"
  printf '1.5.1-dashboard\n' > "$kroot/VERSION"
  cat > "$kroot/bin/drive.sh" <<'DRV'
#!/usr/bin/env bash
set -uo pipefail
envf="$1"; strict="$2"
set --                                  # empty args -> sourced `main` is harmless
source "$(dirname "$0")/lucairn" >/dev/null 2>&1
check_image_digests "$envf" "$strict"
DRV
  chmod +x "$kroot/bin/drive.sh"
  printf '%s' "$kroot"
}

# A stub crane that resolves every ref to the digest recorded in $STUB_MANIFEST.
# `crane digest <ref>` -> echo recorded digest, or a sentinel "missing" digest if
# the ref is not in the manifest (so we model an unresolvable/floating ref).
make_stub_crane() {
  # $1 = manifest whose recorded digests the stub should echo back
  local stub_manifest="$1" shim
  shim="$(mktemp -d)"
  cat > "$shim/crane" <<CR
#!/usr/bin/env bash
# crane digest <ref>
ref="\$2"
rec="\$(awk -v want="\$ref" '
  /^[[:space:]]*ref:[[:space:]]*/ { r=\$0; sub(/^[[:space:]]*ref:[[:space:]]*/,"",r); gsub(/"/,"",r); cur=r; next }
  /^[[:space:]]*digest:[[:space:]]*/ { d=\$0; sub(/^[[:space:]]*digest:[[:space:]]*/,"",d); gsub(/"/,"",d); if (cur==want) { print d; exit } }
' "$stub_manifest")"
if [ -n "\$rec" ]; then echo "\$rec"; else echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"; fi
CR
  chmod +x "$shim/crane"
  printf '%s' "$shim"
}

ENVF="$TMP/customer.env"
printf 'LUCAIRN_IMAGE_TAG=0.5.0\nLUCAIRN_IMAGE_REGISTRY=ghcr.io/declade\n' > "$ENVF"

# ---------------------------------------------------------------------------
# 5a. Clean manifest: stub resolves every ref to the recorded digest -> all
#     match -> normal rc=0 AND strict rc=0.
# ---------------------------------------------------------------------------
KROOT_OK="$(make_kit_root "$MANIFEST")"
SHIM_OK="$(make_stub_crane "$MANIFEST")"

set +e
out_n="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_OK/bin/drive.sh" "$ENVF" 0 2>&1)"; rc_n=$?
out_s="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_OK/bin/drive.sh" "$ENVF" 1 2>&1)"; rc_s=$?
set -e
[ "$rc_n" -eq 0 ] || fail "clean manifest normal mode should rc=0, got $rc_n"
[ "$rc_s" -eq 0 ] || { printf '%s\n' "$out_s" >&2; fail "clean manifest --strict should rc=0 (all match), got $rc_s"; }
printf '%s' "$out_s" | grep -q "image digest: ok (ghcr.io/declade/dsa-gateway" \
  || fail "clean --strict should report gateway ok"
printf '%s' "$out_s" | grep -q "mismatched=0" \
  || fail "clean --strict summary should report mismatched=0"
# pending entries must be skipped (present + counted) even under --strict.
printf '%s' "$out_s" | grep -q "ollama://qwen2.5:7b pending" \
  || fail "qwen2.5 model should be reported pending"
printf '%s' "$out_s" | grep -q "pending=7" \
  || fail "--strict summary should report pending=7"
echo "digest-pin: clean manifest -> normal rc=0 + strict rc=0, pending skipped ok"

# ---------------------------------------------------------------------------
# 5b. Tampered manifest: flip ONE recorded digest. The stub still resolves the
#     ref to its TRUE (original) recorded digest, so the tampered manifest value
#     no longer matches -> normal rc=0 (warn-only) BUT strict rc!=0 (BLOCKS).
# ---------------------------------------------------------------------------
TAMPERED="$TMP/image-manifest.tampered.yaml"
# Replace the gateway digest's first hex char run with a different value.
sed 's#sha256:4c969d401356c7ffb9862e38a77a4ffae36a2a27573cb2e61c9cfe280e6d7a8a#sha256:dead00401356c7ffb9862e38a77a4ffae36a2a27573cb2e61c9cfe280e6d7a8a#' \
  "$MANIFEST" > "$TAMPERED"
# Sanity: the tamper actually changed the file.
! diff -q "$MANIFEST" "$TAMPERED" >/dev/null || fail "tamper sed did not modify the manifest"

KROOT_BAD="$(make_kit_root "$TAMPERED")"
# Stub resolves against the ORIGINAL (true) manifest -> the true gateway digest,
# which now differs from the tampered manifest value installed in KROOT_BAD.
set +e
out_bn="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_BAD/bin/drive.sh" "$ENVF" 0 2>&1)"; rc_bn=$?
out_bs="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_BAD/bin/drive.sh" "$ENVF" 1 2>&1)"; rc_bs=$?
set -e
[ "$rc_bn" -eq 0 ] || fail "tampered manifest normal mode should still rc=0 (warn-only), got $rc_bn"
[ "$rc_bs" -ne 0 ] || fail "tampered manifest --strict should BLOCK (non-zero), got $rc_bs"
printf '%s' "$out_bn" | grep -qi "image digest mismatch: ghcr.io/declade/dsa-gateway" \
  || fail "tampered normal mode should WARN on the gateway mismatch"
printf '%s' "$out_bs" | grep -qi "MISMATCH (ghcr.io/declade/dsa-gateway" \
  || fail "tampered --strict should report the gateway MISMATCH"
printf '%s' "$out_bs" | grep -qi "failing closed" \
  || fail "tampered --strict should announce failing closed"
echo "digest-pin: tampered digest -> normal rc=0 (warn) + strict BLOCKS (non-zero) ok"

# ---------------------------------------------------------------------------
# 5c. No resolver on PATH -> SKIP (do not block, even --strict). "cannot verify"
#     is not "verified mismatch"; a fresh install on a host without
#     docker/crane/skopeo must never be blocked by --strict.
# ---------------------------------------------------------------------------
NORES="$TMP/nores"
mkdir -p "$NORES"
for b in bash awk sed grep cat env mktemp tr head dirname; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$NORES/$b"
done
set +e
out_nr="$(PATH="$NORES" "$KROOT_OK/bin/drive.sh" "$ENVF" 1 2>&1)"; rc_nr=$?
set -e
[ "$rc_nr" -eq 0 ] || { printf '%s\n' "$out_nr" >&2; fail "no-resolver --strict should SKIP (rc=0), got $rc_nr"; }
printf '%s' "$out_nr" | grep -qi "no registry digest resolver on PATH" \
  || fail "no-resolver path should report the skip reason"
echo "digest-pin: no-resolver host -> --strict SKIPS (never blocks a fresh install) ok"

rm -rf "$KROOT_OK" "$KROOT_BAD" "$SHIM_OK"
echo "lucairn digest-pin tests: ok"
