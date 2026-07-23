#!/usr/bin/env bash
# test_digest_pin.sh — tests for B1 Slice 3 (digest-pin + `doctor --strict`).
#
# Covers, WITHOUT docker/crane/skopeo/cosign/GHCR creds (so it runs in the
# static gate like test_sbom.sh):
#   1. bash -n syntax.
#   2. usage() advertises `doctor --strict` and distinguishes it from
#      --strict-runtime.
#   3. parse_image_digests parses the real image-manifest.yaml block: 18 real
#      digests + 7 pending entries (Bash-only, deterministic).
#   4. The manifest digest block stays the SINGLE-SOURCE-of-truth lockstep with
#      keys/image-digests-<tag>.txt for the 13 signed artifacts.
#   5. check_image_digests with a STUB resolver:
#        a. all refs resolve to their recorded digest  -> normal rc=0, strict rc=0.
#        b. one tampered manifest digest               -> normal rc=0 (warn-only),
#                                                         strict rc!=0 (BLOCKS).
#        c. pending entries are SKIPPED in both modes (never block under --strict).
#        d. no resolver on PATH                         -> --strict HARD-ERRORS
#                                                         (rc!=0): it refuses to
#                                                         report a green run it
#                                                         could not verify. Plain
#                                                         doctor SKIPS warn-only.
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
DIGESTS_FILE="$ROOT/keys/image-digests-0.5.4.txt"
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
# 3. parse_image_digests parses the real manifest: 19 real digests + 8 pending.
#    The 19 real-digest entries = 13 signed artifacts (the 12 dsa-* services +
#    lucairn-dashboard, all in keys/image-digests-0.5.4.txt) + ollama/ollama
#    + the dsa-pii-ml sidecar (digest-pinned in image-manifest.yaml at PR #240
#    but NOT in the cosign-signed set — it ships on its own release cadence) +
#    the three third-party images in the Enterprise Kind default topology + the
#    digest-pinned vllm-l3 fast L3 shield (PRD B, opt-in identity-plane runtime).
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
[ "$real_count" = "19" ] \
  || fail "expected 19 real-digest entries (13 signed + ollama + dsa-pii-ml sidecar + 3 Kind dependencies + vllm-l3 shield), got $real_count"
[ "$pending_count" = "8" ] \
  || fail "expected 8 pending entries (qwen ollama model + qwen-awq hf model + 6 runtime), got $pending_count"
# Spot-check the gateway ref maps to its recorded digest.
printf '%s\n' "$PARSED" \
  | grep -q "^ghcr.io/declade/dsa-gateway:0.5.4	sha256:f73e55e0a3d3445d3242d2a73aff7086427da50cbcd2e47e3c8cd4f0fad2bece$" \
  || fail "parse_image_digests did not map the gateway ref to its recorded digest"
echo "digest-pin: parse_image_digests reads 19 real + 8 pending entries ok"

# ---------------------------------------------------------------------------
# 4. Lockstep: every signed artifact in keys/image-digests-0.5.4.txt must appear
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
    || fail "lockstep: $ref $rec is in keys/image-digests-0.5.4.txt but not (identically) in the manifest digest block"
done < "$DIGESTS_FILE"
echo "digest-pin: manifest digest block is in lockstep with keys/image-digests-0.5.4.txt ok"

# ---------------------------------------------------------------------------
# Build an isolated kit ROOT so the CLI's BASH_SOURCE-based ROOT resolution
# locates this test tree (with a controllable manifest), and a stub `crane`
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
  cp "$ROOT/bin/runtime-profile-lib.sh" "$kroot/bin/runtime-profile-lib.sh"
  cp "$src_manifest" "$kroot/image-manifest.yaml"
  printf '1.5.1-dashboard\n' > "$kroot/VERSION"
  cat > "$kroot/bin/drive.sh" <<'DRV'
#!/usr/bin/env bash
set -uo pipefail
envf="$1"; strict="$2"; offline="${3:-0}"
set --                                  # empty args -> sourced `main` is harmless
source "$(dirname "$0")/lucairn" >/dev/null 2>&1
check_image_digests "$envf" "$strict" "$offline"
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

# A stub crane that resolves every ref to its recorded digest EXCEPT one target
# ref, for which it emits NOTHING (exit 1) — modelling the induced-empty/error
# resolution an attacker would force for the single ref they swap. The resolver
# IS present (crane is on PATH), so check_image_digests sees this as UNRESOLVED,
# not "no resolver". This is the fail-OPEN HIGH case.
make_stub_crane_empty_for() {
  # $1 = manifest whose recorded digests the stub echoes; $2 = ref to blank out
  local stub_manifest="$1" target_ref="$2" shim
  shim="$(mktemp -d)"
  cat > "$shim/crane" <<CR
#!/usr/bin/env bash
# crane digest <ref>
ref="\$2"
if [ "\$ref" = "$target_ref" ]; then exit 1; fi   # induced empty/error for the swapped ref
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
printf 'LUCAIRN_IMAGE_TAG=0.5.4\nLUCAIRN_IMAGE_REGISTRY=ghcr.io/declade\n' > "$ENVF"

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
printf '%s' "$out_s" | grep -q "pending=8" \
  || fail "--strict summary should report pending=8"
echo "digest-pin: clean manifest -> normal rc=0 + strict rc=0, pending skipped ok"

# ---------------------------------------------------------------------------
# 5b. Tampered manifest: flip ONE recorded digest. The stub still resolves the
#     ref to its TRUE (original) recorded digest, so the tampered manifest value
#     no longer matches -> normal rc=0 (warn-only) BUT strict rc!=0 (BLOCKS).
# ---------------------------------------------------------------------------
TAMPERED="$TMP/image-manifest.tampered.yaml"
# Replace the gateway digest's first hex char run with a different value.
sed 's#sha256:f73e55e0a3d3445d3242d2a73aff7086427da50cbcd2e47e3c8cd4f0fad2bece#sha256:dead00401356c7ffb9862e38a77a4ffae36a2a27573cb2e61c9cfe280e6d7a8a#' \
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
# 5c. No resolver on PATH.
#       --strict  -> HARD ERROR (non-zero): --strict cannot verify anything
#                    without a resolver, so it must NOT report a green run.
#       plain     -> SKIP (rc=0, warn-only): a fresh install on a host without
#                    docker/crane/skopeo is never blocked by a PLAIN doctor.
#     (HIGH [trailofbits]: distinguish "verified nothing" from "verified all".)
# ---------------------------------------------------------------------------
NORES="$TMP/nores"
mkdir -p "$NORES"
for b in bash awk sed grep cat env mktemp tr head dirname; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$NORES/$b"
done
set +e
out_nr_s="$(PATH="$NORES" "$KROOT_OK/bin/drive.sh" "$ENVF" 1 2>&1)"; rc_nr_s=$?
out_nr_n="$(PATH="$NORES" "$KROOT_OK/bin/drive.sh" "$ENVF" 0 2>&1)"; rc_nr_n=$?
set -e
[ "$rc_nr_s" -ne 0 ] || { printf '%s\n' "$out_nr_s" >&2; fail "no-resolver --strict should HARD ERROR (non-zero), got $rc_nr_s"; }
printf '%s' "$out_nr_s" | grep -qi "requires a digest resolver" \
  || fail "no-resolver --strict should report the resolver requirement"
[ "$rc_nr_n" -eq 0 ] || { printf '%s\n' "$out_nr_n" >&2; fail "no-resolver PLAIN doctor should SKIP (rc=0), got $rc_nr_n"; }
printf '%s' "$out_nr_n" | grep -qi "no registry digest resolver on PATH" \
  || fail "no-resolver plain path should report the skip reason"
echo "digest-pin: no-resolver host -> --strict HARD ERRORS, plain doctor SKIPS ok"

# ---------------------------------------------------------------------------
# 5d. --strict + --offline -> HARD ERROR (non-zero). You cannot enforce LIVE
#     registry digests offline; a resolver IS present here, so the only reason
#     it errors is the offline incompatibility.
# ---------------------------------------------------------------------------
set +e
out_off="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_OK/bin/drive.sh" "$ENVF" 1 1 2>&1)"; rc_off=$?
out_off_plain="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_OK/bin/drive.sh" "$ENVF" 0 1 2>&1)"; rc_off_plain=$?
set -e
[ "$rc_off" -ne 0 ] || { printf '%s\n' "$out_off" >&2; fail "--strict + --offline should HARD ERROR (non-zero), got $rc_off"; }
printf '%s' "$out_off" | grep -qi "incompatible with --offline" \
  || fail "--strict + --offline should report the incompatibility"
[ "$rc_off_plain" -eq 0 ] || { printf '%s\n' "$out_off_plain" >&2; fail "plain --offline doctor should stay rc=0, got $rc_off_plain"; }
echo "digest-pin: --strict + --offline -> hard error; plain --offline rc=0 ok"

# ---------------------------------------------------------------------------
# 5e. Induced-empty resolution (the fail-OPEN HIGH). The resolver IS present but
#     returns NOTHING for the ONE ref an attacker swapped -> UNRESOLVED.
#       --strict -> FAIL-CLOSED (non-zero): a verifier was available and could
#                   not confirm a ref it was told to enforce.
#       plain    -> warn-only (rc=0).
# ---------------------------------------------------------------------------
GW_REF="ghcr.io/declade/dsa-gateway:0.5.4"
SHIM_EMPTY="$(make_stub_crane_empty_for "$MANIFEST" "$GW_REF")"
# The crane stub MUST be the SOLE resolver image_current_digest can find. We
# cannot append :/usr/bin:/bin here: on a box where a REAL docker/crane/skopeo
# lives in a system bin dir, the production resolver (which probes `have docker`
# FIRST) would resolve the swapped ref for REAL and the induced-empty condition
# would never trigger -> 5e false-fails (the original `:/usr/bin:/bin` bug found
# by the Vast verify; the production enforcement itself is correct). So build an
# isolated PATH that contains ONLY the crane stub + symlinks to the coreutils
# the verify path needs (mirrors the curated $NORES dir in 5c) — and NO real
# docker/crane/skopeo. This makes the stub the deterministic sole resolver on
# ANY box (macOS bash 3.2 AND Linux with docker in /usr/bin).
for b in bash awk sed grep cat env mktemp tr head tail dirname; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$SHIM_EMPTY/$b"
done
EMPTY_PATH="$SHIM_EMPTY"
set +e
out_ur_s="$(PATH="$EMPTY_PATH" "$KROOT_OK/bin/drive.sh" "$ENVF" 1 2>&1)"; rc_ur_s=$?
out_ur_n="$(PATH="$EMPTY_PATH" "$KROOT_OK/bin/drive.sh" "$ENVF" 0 2>&1)"; rc_ur_n=$?
set -e
[ "$rc_ur_s" -ne 0 ] || { printf '%s\n' "$out_ur_s" >&2; fail "induced-empty --strict should FAIL-CLOSED (non-zero), got $rc_ur_s"; }
printf '%s' "$out_ur_s" | grep -qi "UNRESOLVED" \
  || fail "induced-empty --strict should report UNRESOLVED for the swapped ref"
printf '%s' "$out_ur_s" | grep -qi "could not be resolved while a resolver was present" \
  || fail "induced-empty --strict should announce the fail-closed reason"
[ "$rc_ur_n" -eq 0 ] || { printf '%s\n' "$out_ur_n" >&2; fail "induced-empty plain doctor should stay rc=0 (warn), got $rc_ur_n"; }
rm -rf "$SHIM_EMPTY"
echo "digest-pin: induced-empty resolution -> --strict FAILS-CLOSED, plain warns ok"

# ---------------------------------------------------------------------------
# 5f. Cardinality floor: --strict must verify > 0 refs. A manifest whose every
#     non-pending entry is set pending -> verified==0 -> distinct FAIL message.
# ---------------------------------------------------------------------------
ALLPEND="$TMP/image-manifest.allpending.yaml"
# Append "pending: true" semantics by replacing every recorded digest line with
# a pending marker (same indentation). Awk over the digests block only.
awk '
  /^image_digests:[[:space:]]*$/ { print; inblock=1; next }
  inblock && /^[^[:space:]#]/ { inblock=0 }
  inblock && /^[[:space:]]*digest:[[:space:]]*"sha256:/ {
    ind=$0; sub(/[^[:space:]].*$/, "", ind); print ind "pending: true"; next
  }
  { print }
' "$MANIFEST" > "$ALLPEND"
KROOT_ALLPEND="$(make_kit_root "$ALLPEND")"
set +e
out_cf="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_ALLPEND/bin/drive.sh" "$ENVF" 1 2>&1)"; rc_cf=$?
out_cf_n="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_ALLPEND/bin/drive.sh" "$ENVF" 0 2>&1)"; rc_cf_n=$?
set -e
[ "$rc_cf" -ne 0 ] || { printf '%s\n' "$out_cf" >&2; fail "cardinality-floor --strict (verified==0) should FAIL (non-zero), got $rc_cf"; }
printf '%s' "$out_cf" | grep -qi "verified no recorded digests" \
  || fail "cardinality-floor --strict should use the DISTINCT 'verified no recorded digests' message"
printf '%s' "$out_cf" | grep -q "verified=0" \
  || fail "cardinality-floor summary should report verified=0"
[ "$rc_cf_n" -eq 0 ] || { printf '%s\n' "$out_cf_n" >&2; fail "cardinality-floor plain doctor should stay rc=0, got $rc_cf_n"; }
rm -rf "$KROOT_ALLPEND"
echo "digest-pin: cardinality floor -> --strict FAILS when verified==0 (distinct msg) ok"

# ---------------------------------------------------------------------------
# 5g. INVALID — a present-but-malformed recorded digest (truncated hex). The
#     digest LINE is present but the value fails ^sha256:[0-9a-f]{64}$ -> INVALID
#     (a manifest-integrity error, NOT a pending slot).
#       --strict -> FAIL-CLOSED. plain -> warn (rc=0).
# ---------------------------------------------------------------------------
MALFORMED="$TMP/image-manifest.malformed.yaml"
# Truncate the gateway digest's hex to 8 chars (still starts sha256: but invalid).
sed 's#digest: "sha256:f73e55e0a3d3445d3242d2a73aff7086427da50cbcd2e47e3c8cd4f0fad2bece"#digest: "sha256:7662f955"#' \
  "$MANIFEST" > "$MALFORMED"
! diff -q "$MANIFEST" "$MALFORMED" >/dev/null || fail "malformed sed did not modify the manifest"
# Sanity: the parser must mark this entry INVALID (not PENDING, not a digest).
INV_PARSE="$(
  set --
  source "$CLI" >/dev/null 2>&1
  parse_image_digests "$MALFORMED"
)"
printf '%s\n' "$INV_PARSE" | grep -q "^${GW_REF}	INVALID$" \
  || fail "parser should mark a malformed gateway digest as INVALID (got: $(printf '%s\n' "$INV_PARSE" | grep "$GW_REF"))"
KROOT_MAL="$(make_kit_root "$MALFORMED")"
set +e
out_inv_s="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_MAL/bin/drive.sh" "$ENVF" 1 2>&1)"; rc_inv_s=$?
out_inv_n="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_MAL/bin/drive.sh" "$ENVF" 0 2>&1)"; rc_inv_n=$?
set -e
[ "$rc_inv_s" -ne 0 ] || { printf '%s\n' "$out_inv_s" >&2; fail "malformed-digest --strict should FAIL-CLOSED (non-zero), got $rc_inv_s"; }
printf '%s' "$out_inv_s" | grep -qi "INVALID manifest entry" \
  || fail "malformed-digest --strict should report the INVALID entry"
[ "$rc_inv_n" -eq 0 ] || { printf '%s\n' "$out_inv_n" >&2; fail "malformed-digest plain doctor should stay rc=0 (warn), got $rc_inv_n"; }
rm -rf "$KROOT_MAL"
echo "digest-pin: INVALID (malformed digest) -> --strict FAILS-CLOSED, plain warns ok"

# ---------------------------------------------------------------------------
# 5h. INVALID — digest + pending:true CONTRADICTION. An entry carrying BOTH a
#     valid digest AND pending: true must NOT silently honor the later line ->
#     INVALID. --strict fails closed.
# ---------------------------------------------------------------------------
CONTRA="$TMP/image-manifest.contradiction.yaml"
# Add a `pending: true` line right after the gateway digest, at the SAME indent.
awk '
  /^[[:space:]]*digest:[[:space:]]*"sha256:f73e55e0a3d3445d3242d2a73aff7086427da50cbcd2e47e3c8cd4f0fad2bece"/ {
    print
    ind=$0; sub(/[^[:space:]].*$/, "", ind); print ind "pending: true"; next
  }
  { print }
' "$MANIFEST" > "$CONTRA"
! diff -q "$MANIFEST" "$CONTRA" >/dev/null || fail "contradiction awk did not modify the manifest"
CON_PARSE="$(
  set --
  source "$CLI" >/dev/null 2>&1
  parse_image_digests "$CONTRA"
)"
printf '%s\n' "$CON_PARSE" | grep -q "^${GW_REF}	INVALID$" \
  || fail "parser should mark a digest+pending contradiction as INVALID (got: $(printf '%s\n' "$CON_PARSE" | grep "$GW_REF"))"
KROOT_CON="$(make_kit_root "$CONTRA")"
set +e
out_con_s="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_CON/bin/drive.sh" "$ENVF" 1 2>&1)"; rc_con_s=$?
out_con_n="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_CON/bin/drive.sh" "$ENVF" 0 2>&1)"; rc_con_n=$?
set -e
[ "$rc_con_s" -ne 0 ] || { printf '%s\n' "$out_con_s" >&2; fail "digest+pending --strict should FAIL-CLOSED (non-zero), got $rc_con_s"; }
[ "$rc_con_n" -eq 0 ] || { printf '%s\n' "$out_con_n" >&2; fail "digest+pending plain doctor should stay rc=0 (warn), got $rc_con_n"; }
rm -rf "$KROOT_CON"
echo "digest-pin: INVALID (digest+pending contradiction) -> --strict FAILS-CLOSED, plain warns ok"

# ---------------------------------------------------------------------------
# 5i. Reordered entry: `digest:` BEFORE its `ref:` within the entry. Must NOT
#     silently become a skipped PENDING — the digest associates with the entry
#     (order-independent) and verifies normally under --strict.
# ---------------------------------------------------------------------------
REORDER_PARSE="$(
  set --
  source "$CLI" >/dev/null 2>&1
  cat > "$TMP/reorder.yaml" <<'YML'
image_digests:
  signed_artifacts:
    dsa-gateway:
      digest: "sha256:1111111111111111111111111111111111111111111111111111111111111111"
      ref: "ghcr.io/declade/dsa-gateway:0.5.4"
YML
  parse_image_digests "$TMP/reorder.yaml"
)"
# The reordered entry must resolve to the digest (a real sha256 verdict), NOT
# PENDING and NOT a mis-attributed <no-ref>.
printf '%s\n' "$REORDER_PARSE" \
  | grep -q "^ghcr.io/declade/dsa-gateway:0.5.4	sha256:1111111111111111111111111111111111111111111111111111111111111111$" \
  || fail "digest-before-ref must associate the digest with its ref (got: $REORDER_PARSE)"
printf '%s\n' "$REORDER_PARSE" | grep -q "PENDING" \
  && fail "digest-before-ref must NOT silently become PENDING"
printf '%s\n' "$REORDER_PARSE" | grep -q "<no-ref>" \
  && fail "digest-before-ref must NOT mis-attribute to <no-ref>"
echo "digest-pin: digest-before-ref parses correctly (not a silent PENDING) ok"

# ---------------------------------------------------------------------------
# 5j. Orphan digest with NO matching ref before the next entry -> surfaced as a
#     synthetic <no-ref>\tINVALID line, never silently dropped.
# ---------------------------------------------------------------------------
ORPHAN_PARSE="$(
  set --
  source "$CLI" >/dev/null 2>&1
  cat > "$TMP/orphan.yaml" <<'YML'
image_digests:
  signed_artifacts:
    orphan_no_ref:
      digest: "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    dsa-gateway:
      ref: "ghcr.io/declade/dsa-gateway:0.5.4"
      digest: "sha256:f73e55e0a3d3445d3242d2a73aff7086427da50cbcd2e47e3c8cd4f0fad2bece"
YML
  parse_image_digests "$TMP/orphan.yaml"
)"
printf '%s\n' "$ORPHAN_PARSE" | grep -q "^<no-ref>	INVALID$" \
  || fail "an orphan digest (no ref) must surface as <no-ref>\tINVALID (got: $ORPHAN_PARSE)"
echo "digest-pin: orphan digest (no ref) -> surfaced as <no-ref> INVALID ok"

# ---------------------------------------------------------------------------
# 5k. Dashboard enforcement under --strict (Codex r1 BLOCKER fix). The dashboard
#     deploys via LUCAIRN_IMAGE_REGISTRY + its OWN tag var
#     LUCAIRN_DASHBOARD_IMAGE_TAG (docker-compose.customer.yml:630), DISTINCT
#     from the dsa-* LUCAIRN_IMAGE_TAG. digest_resolve_env_ref must apply those
#     overrides so an operator's dashboard tag/registry swap is digest-checked
#     like the dsa-* services — it is one of the 13 signed artifacts.
#
#       (i)  a dashboard tag override whose resolved ref's current digest != the
#            recorded dashboard digest -> --strict FAILS (dashboard IS enforced);
#            plain doctor stays rc=0 (warn-only).
#       (ii) a matching dashboard override (stub echoes the recorded digest for
#            the resolved ref) -> the dashboard counts toward verified++.
# ---------------------------------------------------------------------------
DASH_REF="ghcr.io/declade/lucairn-dashboard:0.8.2"
DASH_DIGEST="$(awk '
  /^[[:space:]]*ref:[[:space:]]*"ghcr.io\/declade\/lucairn-dashboard:0.8.2"/ { hit=1; next }
  hit && /^[[:space:]]*digest:[[:space:]]*/ { d=$0; sub(/^[[:space:]]*digest:[[:space:]]*/,"",d); gsub(/"/,"",d); print d; exit }
' "$MANIFEST")"
[ -n "$DASH_DIGEST" ] || fail "could not read the recorded dashboard digest from the manifest"

# Override the dashboard tag to a tag the stub does NOT know -> the resolved ref
# is ghcr.io/declade/lucairn-dashboard:9.9.9, absent from the stub's manifest, so
# the stub returns the sentinel all-zero digest -> MISMATCH vs the recorded
# dashboard digest -> --strict must BLOCK. (Before the fix, the override was
# ignored, the canonical :0.8.2 ref resolved to its recorded digest, and --strict
# wrongly PASSED — the dashboard was un-enforced.)
ENVF_DASH_SWAP="$TMP/customer.dash-swap.env"
printf 'LUCAIRN_IMAGE_TAG=0.5.4\nLUCAIRN_IMAGE_REGISTRY=ghcr.io/declade\nLUCAIRN_DASHBOARD_IMAGE_TAG=9.9.9\n' > "$ENVF_DASH_SWAP"
set +e
out_dsw_s="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_OK/bin/drive.sh" "$ENVF_DASH_SWAP" 1 2>&1)"; rc_dsw_s=$?
out_dsw_n="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_OK/bin/drive.sh" "$ENVF_DASH_SWAP" 0 2>&1)"; rc_dsw_n=$?
set -e
[ "$rc_dsw_s" -ne 0 ] || { printf '%s\n' "$out_dsw_s" >&2; fail "dashboard tag swap --strict should BLOCK (non-zero) — the dashboard must be enforced, got $rc_dsw_s"; }
printf '%s' "$out_dsw_s" | grep -qi "lucairn-dashboard:9.9.9" \
  || fail "dashboard tag swap --strict should resolve+report the OVERRIDDEN ref (lucairn-dashboard:9.9.9), proving the dashboard tag env var is applied"
printf '%s' "$out_dsw_s" | grep -qi "MISMATCH (ghcr.io/declade/lucairn-dashboard:9.9.9" \
  || fail "dashboard tag swap --strict should report the dashboard MISMATCH"
[ "$rc_dsw_n" -eq 0 ] || { printf '%s\n' "$out_dsw_n" >&2; fail "dashboard tag swap plain doctor should stay rc=0 (warn-only), got $rc_dsw_n"; }
echo "digest-pin: dashboard tag override (digest mismatch) -> --strict BLOCKS, plain warns ok"

# Matching dashboard override: a stub that ALSO echoes the recorded dashboard
# digest for the OVERRIDDEN ref (ghcr.io/declade/lucairn-dashboard:9.9.9). This
# proves the dashboard counts toward verified++ (cardinality floor) once its
# resolved ref matches — i.e. the env-resolved dashboard ref flows through the
# normal verify path exactly like the dsa-* services.
SHIM_DASH_OK="$(mktemp -d)"
cat > "$SHIM_DASH_OK/crane" <<CR
#!/usr/bin/env bash
# crane digest <ref> — echo the recorded digest for any ref, AND map the
# overridden dashboard ref to the recorded dashboard digest.
ref="\$2"
if [ "\$ref" = "ghcr.io/declade/lucairn-dashboard:9.9.9" ]; then echo "$DASH_DIGEST"; exit 0; fi
rec="\$(awk -v want="\$ref" '
  /^[[:space:]]*ref:[[:space:]]*/ { r=\$0; sub(/^[[:space:]]*ref:[[:space:]]*/,"",r); gsub(/"/,"",r); cur=r; next }
  /^[[:space:]]*digest:[[:space:]]*/ { d=\$0; sub(/^[[:space:]]*digest:[[:space:]]*/,"",d); gsub(/"/,"",d); if (cur==want) { print d; exit } }
' "$MANIFEST")"
if [ -n "\$rec" ]; then echo "\$rec"; else echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"; fi
CR
chmod +x "$SHIM_DASH_OK/crane"
set +e
out_dok_s="$(PATH="$SHIM_DASH_OK:/usr/bin:/bin" "$KROOT_OK/bin/drive.sh" "$ENVF_DASH_SWAP" 1 2>&1)"; rc_dok_s=$?
set -e
[ "$rc_dok_s" -eq 0 ] || { printf '%s\n' "$out_dok_s" >&2; fail "matching dashboard override --strict should rc=0 (verified), got $rc_dok_s"; }
printf '%s' "$out_dok_s" | grep -qi "image digest: ok (ghcr.io/declade/lucairn-dashboard:9.9.9" \
  || fail "matching dashboard override --strict should report the resolved dashboard ref ok (counts toward verified++)"
rm -rf "$SHIM_DASH_OK"
echo "digest-pin: matching dashboard override -> --strict verifies the dashboard (counts toward floor) ok"

# ---------------------------------------------------------------------------
# 5l. ollama-identity OLLAMA_IMAGE enforcement under --strict (C5 fail-OPEN fix).
#     The self-hosted L3 PII-plane runtime deploys via OLLAMA_IMAGE
#     (docker-compose.self-hosted.yml:202: ${OLLAMA_IMAGE:-ollama/ollama:latest}).
#     Before the fix, OLLAMA_IMAGE was NEVER consulted: --strict resolved the
#     canonical immutable ollama/ollama:0.6.2 tag, matched the recorded digest,
#     and reported GREEN for an image the operator was NOT running (a mutable
#     :latest). That is a FALSE-GREEN in a verify-or-fail gate.
#
#       (i)   UNPINNED override (OLLAMA_IMAGE=ollama/ollama:latest) -> --strict
#             FAILS CLOSED (non-zero): a mutable tag cannot be digest-verified;
#             plain doctor stays rc=0 (warn-only).
#       (ii)  recorded-DIGEST-pinned override -> --strict resolves THAT image and
#             counts it toward verified++ (rc=0).
#       (iii) NO override -> the canonical immutable recorded ollama tag is
#             verified honestly (rc=0), unchanged behavior.
# ---------------------------------------------------------------------------
OLLAMA_REF="ollama/ollama:0.6.2"
OLLAMA_DIGEST="$(awk '
  /^[[:space:]]*ref:[[:space:]]*"ollama\/ollama:0.6.2"/ { hit=1; next }
  hit && /^[[:space:]]*digest:[[:space:]]*/ { d=$0; sub(/^[[:space:]]*digest:[[:space:]]*/,"",d); gsub(/"/,"",d); print d; exit }
' "$MANIFEST")"
[ -n "$OLLAMA_DIGEST" ] || fail "could not read the recorded ollama-identity digest from the manifest"

# (i) UNPINNED override -> fail-closed. SHIM_OK resolves ollama/ollama:0.6.2 to
# its recorded digest, but the resolver is NEVER reached for an unpinned override
# (the resolver short-circuits to the __UNPINNED_OVERRIDE__ fail-closed path), so
# the stub's behavior is irrelevant here.
ENVF_OLLAMA_LATEST="$TMP/customer.ollama-latest.env"
printf 'LUCAIRN_IMAGE_TAG=0.5.4\nLUCAIRN_IMAGE_REGISTRY=ghcr.io/declade\nOLLAMA_IMAGE=ollama/ollama:latest\n' > "$ENVF_OLLAMA_LATEST"
set +e
out_ol_s="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_OK/bin/drive.sh" "$ENVF_OLLAMA_LATEST" 1 2>&1)"; rc_ol_s=$?
out_ol_n="$(PATH="$SHIM_OK:/usr/bin:/bin" "$KROOT_OK/bin/drive.sh" "$ENVF_OLLAMA_LATEST" 0 2>&1)"; rc_ol_n=$?
set -e
[ "$rc_ol_s" -ne 0 ] || { printf '%s\n' "$out_ol_s" >&2; fail "unpinned OLLAMA_IMAGE=ollama/ollama:latest --strict should FAIL-CLOSED (non-zero) — the false-green class is the C5 bug, got $rc_ol_s"; }
printf '%s' "$out_ol_s" | grep -qi "OLLAMA_IMAGE override (ollama/ollama:latest) is unpinned" \
  || fail "unpinned OLLAMA_IMAGE --strict should name the unpinned override in the MISMATCH message"
printf '%s' "$out_ol_s" | grep -qi "failing closed" \
  || fail "unpinned OLLAMA_IMAGE --strict should announce failing closed"
# CRITICAL: --strict must NOT report the canonical ollama:0.6.2 ref as ok while
# an override is in force (that WAS the false-green).
printf '%s' "$out_ol_s" | grep -qi "image digest: ok (ollama/ollama:0.6.2 " \
  && fail "unpinned OLLAMA_IMAGE --strict must NOT silently pass the canonical ollama/ollama:0.6.2 ref (the false-green)"
[ "$rc_ol_n" -eq 0 ] || { printf '%s\n' "$out_ol_n" >&2; fail "unpinned OLLAMA_IMAGE plain doctor should stay rc=0 (warn-only), got $rc_ol_n"; }
echo "digest-pin: unpinned OLLAMA_IMAGE override -> --strict FAILS-CLOSED, plain warns ok (C5 false-green closed)"

# (ii) recorded-DIGEST-pinned override -> verified++. A stub that ALSO echoes the
# recorded ollama digest for the digest-pinned override ref proves the operator's
# pinned image flows through the normal verify path and counts toward the floor.
OLLAMA_PIN="ollama/ollama:0.6.2@${OLLAMA_DIGEST}"
ENVF_OLLAMA_PIN="$TMP/customer.ollama-pin.env"
printf 'LUCAIRN_IMAGE_TAG=0.5.4\nLUCAIRN_IMAGE_REGISTRY=ghcr.io/declade\nOLLAMA_IMAGE=%s\n' "$OLLAMA_PIN" > "$ENVF_OLLAMA_PIN"
SHIM_OLLAMA_OK="$(mktemp -d)"
cat > "$SHIM_OLLAMA_OK/crane" <<CR
#!/usr/bin/env bash
# crane digest <ref> — echo the recorded digest for any ref, AND map the
# digest-pinned ollama override ref to the recorded ollama digest.
ref="\$2"
if [ "\$ref" = "$OLLAMA_PIN" ]; then echo "$OLLAMA_DIGEST"; exit 0; fi
rec="\$(awk -v want="\$ref" '
  /^[[:space:]]*ref:[[:space:]]*/ { r=\$0; sub(/^[[:space:]]*ref:[[:space:]]*/,"",r); gsub(/"/,"",r); cur=r; next }
  /^[[:space:]]*digest:[[:space:]]*/ { d=\$0; sub(/^[[:space:]]*digest:[[:space:]]*/,"",d); gsub(/"/,"",d); if (cur==want) { print d; exit } }
' "$MANIFEST")"
if [ -n "\$rec" ]; then echo "\$rec"; else echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"; fi
CR
chmod +x "$SHIM_OLLAMA_OK/crane"
set +e
out_opin_s="$(PATH="$SHIM_OLLAMA_OK:/usr/bin:/bin" "$KROOT_OK/bin/drive.sh" "$ENVF_OLLAMA_PIN" 1 2>&1)"; rc_opin_s=$?
set -e
[ "$rc_opin_s" -eq 0 ] || { printf '%s\n' "$out_opin_s" >&2; fail "recorded-digest-pinned OLLAMA_IMAGE --strict should rc=0 (verified), got $rc_opin_s"; }
printf '%s' "$out_opin_s" | grep -qiF "image digest: ok ($OLLAMA_PIN @ $OLLAMA_DIGEST)" \
  || fail "recorded-digest-pinned OLLAMA_IMAGE --strict should report the pinned ollama ref ok (counts toward verified++)"
rm -rf "$SHIM_OLLAMA_OK"
echo "digest-pin: recorded-digest-pinned OLLAMA_IMAGE override -> --strict verifies it (counts toward floor) ok"

# (iii) NO override -> canonical immutable recorded ollama tag verified honestly.
# The 5a clean run already exercises rc=0 with no OLLAMA_IMAGE in $ENVF; assert
# the ollama-identity line is reported ok there so we lock the unchanged path.
printf '%s' "$out_s" | grep -qi "image digest: ok (ollama/ollama:0.6.2 " \
  || fail "with NO OLLAMA_IMAGE override, --strict should verify the canonical ollama/ollama:0.6.2 ref ok (unchanged honest path)"
echo "digest-pin: no OLLAMA_IMAGE override -> canonical ollama ref verified honestly ok"

rm -rf "$KROOT_OK" "$KROOT_BAD" "$SHIM_OK"
echo "lucairn digest-pin tests: ok"
