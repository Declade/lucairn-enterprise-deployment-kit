#!/usr/bin/env bash
# bootstrap-sanitizer-core-mtls.sh — the deploy-local CA and the four leaves
# the new sanitizer core needs on a Compose install (kit 2.0, PRD
# prd-2026-11-02-kit-2-0-new-core.md K1).
#
# The new Go sanitizer core (`sanitizer-core` in docker-compose.customer.yml)
# never talks plaintext:
#
#   gateway  -> core    :8790   verified mTLS. The core serves its own leaf
#                               (SAN dsa-sanitizer-core) and refuses any client
#                               leaf without the DNS SAN dsa-gateway.
#   core     -> witness :50057  verified TLS with a client leaf. With
#                               DSA_ENV=production the core refuses to start
#                               unless this hop is mTLS (DSA #946). The core
#                               pins the witness name dsa-veil-witness, so the
#                               witness must present a leaf from the SAME CA.
#
# On the hosted service the core's witness hop once ran without its client
# settings and every PII_SANITIZED claim was dropped silently at the TLS
# handshake (window 2026-10-31, amendment A9). This script exists so a kit
# install never starts in that state: it writes every file the compose file
# mounts, and `bin/lucairn doctor` refuses an install where one is missing.
#
# Usage (run once, before the first `docker compose up`, as root if you can):
#
#   sudo scripts/bootstrap-sanitizer-core-mtls.sh            # default dirs
#   sudo scripts/bootstrap-sanitizer-core-mtls.sh /opt/lucairn/certs/sanitizer-core-mtls \
#        /opt/lucairn/secrets/sanitizer-core-mtls-ca
#
# The default directory is <kit>/.certs/sanitizer-core-mtls (in an extracted
# customer bundle: install/.certs/sanitizer-core-mtls), which is the compose
# default of SANITIZER_CORE_MTLS_HOST_DIR. If you pass another directory, set
# SANITIZER_CORE_MTLS_HOST_DIR to it in customer.env.
#
# The deploy CA (its private key signs every leaf) lives OUTSIDE that tree, in
# a 0700 directory no container mounts (kit round 2: the gateway mounts the
# whole ./.certs at /certs, so a CA under ./.certs/sanitizer-core-mtls was
# readable inside the gateway). For the default layout <dir>/.certs/
# sanitizer-core-mtls the CA directory is <dir>/.secrets/sanitizer-core-mtls-ca;
# for any other cert directory it is the sibling <cert dir>-ca. Pass another one
# as the second argument (or SANITIZER_CORE_MTLS_CA_DIR, which `bin/lucairn
# doctor` also reads from customer.env): a folder outside the cert directory
# that no container mounts (not under SANDBOX_B_CERT_DIR or
# LCR_WITNESS_MTLS_HOST_DIR; the doctor fails otherwise). A CA left in
# <cert dir>/ca by an earlier version of this script is moved there on the
# next run.
#
# Layout (each service directory is mounted read-only into ONE container):
#
#   <CA dir>/ca.crt  <CA dir>/ca.key              the deploy-local CA (root-only 0700
#                                                directory when run as root)
#   sanitizer-core/ca.crt                        -> sanitizer-core:/etc/sanitizer-core-mtls
#   sanitizer-core/dsa-sanitizer-core.{crt,key}  core server leaf  (serverAuth; SAN dsa-sanitizer-core,
#                                                sanitizer-core, localhost, 127.0.0.1)
#   sanitizer-core/witness-client.{crt,key}      core -> witness client leaf (clientAuth; CN + SAN
#                                                dsa-sanitizer = the claim service the witness's
#                                                latched claim allowlist names)
#   gateway/ca.crt                               -> gateway:/etc/sanitizer-core-mtls
#   gateway/dsa-gateway.{crt,key}                gateway -> core client leaf (clientAuth; SAN dsa-gateway)
#   veil-witness/ca.crt                          -> veil-witness:/etc/sanitizer-core-mtls
#   veil-witness/dsa-veil-witness.{crt,key}      witness :50057 server leaf (serverAuth; SAN
#                                                dsa-veil-witness, veil-witness, witness)
#
# The witness serves that leaf on :50057 and :50058 through GRPC_TLS_CERT_FILE /
# GRPC_TLS_KEY_FILE (legacy transport TLS: server-authenticated, it does not ask
# for client certificates). Every other kit emitter keeps working unchanged:
# without its own GRPC_TLS_CERT_FILE a client does not verify the server leaf,
# so replacing the witness's auto-generated self-signed leaf with a CA-signed
# one changes nothing for them.
#
# Keys: ECDSA P-256 (the same curve as the hosted mesh leaves), mode 0600.
# Every Lucairn image runs as uid 10001. Run as root and this script hands each
# service directory to that uid (LUCAIRN_CONTAINER_UID overrides it, e.g. for a
# user-namespace-remapped daemon). On Linux an ordinary user is REFUSED before
# anything is written (a 0600 key owned by your own user is unreadable inside
# the container and the witness and the core refuse to start), unless
# LUCAIRN_CONTAINER_UID is set to your own uid (you declare that the image user
# maps to you: Docker Desktop for Linux, a remapped daemon). On macOS an
# ordinary user is fine: Docker Desktop maps file ownership.
#
# Idempotent: a file that exists is never regenerated, so a re-run never
# rotates a key. To rotate, delete the leaf (or the whole directory) and re-run,
# then recreate the containers that mount it. A leaf without its CA is refused.
#
# Folders (kit round 2, R1): every folder this script creates on the way to the
# cert directory is 0755, so the gateway (uid 10001) can still traverse a
# ./.certs it mounts at /certs and read the witness-signed manifest there; every
# folder it creates on the way to the CA directory is 0700. Run with sudo, the
# folders it created (except the CA directory and the service directories) are
# handed back to the user who ran sudo (SUDO_UID/SUDO_GID), so that user can
# still copy the signed manifest into ./.certs and write the registry DSN file
# under ./.secrets without sudo.
#
# Environment overrides:
#   SANITIZER_CORE_MTLS_CA_DIR  the CA directory (same as the second argument)
#   CA_DAYS                 CA validity in days    (default 3650)
#   LEAF_DAYS               leaf validity in days  (default 365; `bin/lucairn doctor`
#                           fails 30 days before a leaf expires)
#   LUCAIRN_CONTAINER_UID   owner uid of the service dirs when run as root (default 10001)
#   OPENSSL                 openssl binary (default: openssl on PATH)

set -euo pipefail

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The compose default (./.certs/sanitizer-core-mtls) resolves against the
# Compose project directory: the kit root, or install/ of an extracted
# customer bundle (final-read H2: the bundle ships this script).
PROJECT_DIR="$KIT_ROOT"
if [ ! -f "$KIT_ROOT/docker-compose.customer.yml" ] && [ -f "$KIT_ROOT/install/docker-compose.customer.yml" ]; then
  PROJECT_DIR="$KIT_ROOT/install"
fi
DEFAULT_CERT_DIR="${PROJECT_DIR}/.certs/sanitizer-core-mtls"
CERT_DIR="${1:-$DEFAULT_CERT_DIR}"
CA_DIR="${2:-${SANITIZER_CORE_MTLS_CA_DIR:-}}"
CA_DAYS="${CA_DAYS:-3650}"
LEAF_DAYS="${LEAF_DAYS:-365}"
CONTAINER_UID="${LUCAIRN_CONTAINER_UID:-10001}"
OPENSSL="${OPENSSL:-openssl}"

log() { printf '[bootstrap-sanitizer-core-mtls] %s\n' "$*"; }
die() { printf '[bootstrap-sanitizer-core-mtls] ERROR: %s\n' "$*" >&2; exit 1; }

command -v "$OPENSSL" >/dev/null 2>&1 || die "openssl not found"
case "$CA_DAYS$LEAF_DAYS$CONTAINER_UID" in
  *[!0-9]*) die "CA_DAYS, LEAF_DAYS and LUCAIRN_CONTAINER_UID must be whole numbers" ;;
esac

# Final-read M2: on a Linux Docker host the image user (uid $CONTAINER_UID)
# cannot read a 0600 key owned by another uid, and the witness and the core
# exit on that read error (kit 1.x needed no key file: the witness generated
# its own leaf). Only root can hand the keys to that uid, so an ordinary user
# is refused here BEFORE anything is written — unless they declared that the
# image user maps to their own uid (LUCAIRN_CONTAINER_UID=$(id -u), e.g.
# Docker Desktop for Linux, whose file sharing maps ownership, or a
# user-namespace-remapped daemon whose mapping lands on that uid). macOS (and
# Docker Desktop's ownership mapping there) needs neither.
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" != "0" ] && [ "$CONTAINER_UID" != "$(id -u)" ]; then
  die "on Linux the keys must belong to uid $CONTAINER_UID (the user every Lucairn image runs as), and only root can hand them over; a 0600 key owned by $(id -un) is unreadable in the containers and the witness and the core refuse to start. Re-run with sudo: sudo $0 '$CERT_DIR'. If the image user maps to your own uid (Docker Desktop for Linux, a user-namespace-remapped daemon), declare it: LUCAIRN_CONTAINER_UID=$(id -u) $0 '$CERT_DIR'. Nothing was written"
fi

# Absolute, without a trailing slash (the CA-directory rule and the "inside
# the cert tree" refusal below compare paths as strings).
abs_dir() {
  local d="$1"
  case "$d" in /*) : ;; *) d="$PWD/$d" ;; esac
  while [ "${#d}" -gt 1 ] && [ "${d%/}" != "$d" ]; do d="${d%/}"; done
  printf '%s' "$d"
}
CERT_DIR="$(abs_dir "$CERT_DIR")"
if [ -z "$CA_DIR" ]; then
  # The same rule as `bin/lucairn doctor` (sanitizer_core_ca_dir).
  case "$CERT_DIR" in
    */.certs/sanitizer-core-mtls) CA_DIR="${CERT_DIR%/.certs/sanitizer-core-mtls}/.secrets/sanitizer-core-mtls-ca" ;;
    *) CA_DIR="${CERT_DIR}-ca" ;;
  esac
fi
CA_DIR="$(abs_dir "$CA_DIR")"
case "$CA_DIR/" in
  "$CERT_DIR"/*) die "the CA directory $CA_DIR is inside the cert directory $CERT_DIR, whose folders are mounted into containers; choose a folder outside it. Nothing was written" ;;
esac
case "$CA_DIR/" in
  "$PROJECT_DIR/.certs/"*) die "the CA directory $CA_DIR is inside $PROJECT_DIR/.certs, which the gateway mounts at /certs (SANDBOX_B_CERT_DIR default); choose a folder outside it. Nothing was written" ;;
esac

# Kit round 2, R1: create the folders on the way to the cert directory 0755 and
# those on the way to the CA directory 0700 BEFORE `umask 077`. Under sudo a
# 0700 root-owned ./.certs (what `umask 077; mkdir -p` made) is untraversable
# for the gateway, which mounts it at /certs and reads the witness-signed
# manifest there as uid 10001: permission denied is fatal at boot in every
# DSA_ENV (only a missing file is tolerated), so the gateway crash-looped.
# CREATED_PARENTS = the folders created here that go back to the sudo user.
CREATED_PARENTS=()
make_path() { # <dir> <mode> <hand back: 1|0> — mkdir -p, each new folder <mode>
  local target="$1" mode="$2" back="$3" p missing=()
  p="$target"
  while [ ! -e "$p" ] && [ ! -L "$p" ]; do
    missing=("$p" ${missing[@]+"${missing[@]}"})
    p="$(dirname "$p")"
  done
  [ -d "$p" ] || die "$p is not a directory (on the way to $target)"
  for p in ${missing[@]+"${missing[@]}"}; do
    mkdir -m "$mode" "$p" || die "could not create $p"
    chmod "$mode" "$p"
    [ "$back" = 1 ] && CREATED_PARENTS+=("$p")
  done
  return 0
}
make_path "$CERT_DIR" 0755 1
CA_DIR_EXISTED=1
if [ ! -e "$CA_DIR" ]; then
  CA_DIR_EXISTED=0
  make_path "$(dirname "$CA_DIR")" 0700 1
fi

umask 077
mkdir -p "$CA_DIR" "$CERT_DIR/sanitizer-core" "$CERT_DIR/gateway" "$CERT_DIR/veil-witness"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rand_serial() { printf '0x%s' "$("$OPENSSL" rand -hex 16)"; }

# ── 1. CA ──────────────────────────────────────────────────────────────────
CA_KEY="$CA_DIR/ca.key"
CA_CRT="$CA_DIR/ca.crt"
# A CA that an earlier version of this script wrote into <cert dir>/ca (inside
# the gateway's /certs mount with the default layout) moves out, once.
OLD_CA_DIR="$CERT_DIR/ca"
if [ -e "$OLD_CA_DIR" ]; then
  if [ -e "$CA_KEY" ] || [ -e "$CA_CRT" ]; then
    die "a CA exists in both $OLD_CA_DIR and $CA_DIR - refusing to guess which one signed the leaves; keep the one that did (openssl verify -CAfile <ca.crt> $CERT_DIR/gateway/dsa-gateway.crt) and delete the other"
  fi
  [ -f "$OLD_CA_DIR/ca.key" ] && [ -f "$OLD_CA_DIR/ca.crt" ] \
    || die "half a CA in $OLD_CA_DIR (key and certificate must both exist) - refusing to guess"
  cp -p "$OLD_CA_DIR/ca.key" "$CA_KEY" && cp -p "$OLD_CA_DIR/ca.crt" "$CA_CRT" \
    || die "could not copy the CA from $OLD_CA_DIR to $CA_DIR"
  rm -f "$OLD_CA_DIR/ca.key" "$OLD_CA_DIR/ca.crt"
  rmdir "$OLD_CA_DIR" 2>/dev/null || die "$OLD_CA_DIR holds other files besides the CA; the CA moved to $CA_DIR - remove the rest by hand"
  log "moved the CA out of the mounted cert tree: $OLD_CA_DIR -> $CA_DIR"
fi
if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CRT" ]; then
  [ ! -f "$CA_KEY" ] && [ ! -f "$CA_CRT" ] \
    || die "half a CA in $CA_DIR (key and certificate must both exist or both be absent) - refusing to guess"
  for leaf in sanitizer-core/dsa-sanitizer-core sanitizer-core/witness-client gateway/dsa-gateway veil-witness/dsa-veil-witness; do
    [ ! -e "$CERT_DIR/$leaf.crt" ] && [ ! -e "$CERT_DIR/$leaf.key" ] \
      || die "$CERT_DIR/$leaf.* exists but the CA does not - a new CA would not have signed it; delete the directory to start over"
  done
  log "generating the deploy-local CA (ECDSA P-256, ${CA_DAYS} days)"
  "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$CA_KEY"
  cat > "$TMP/ca.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = lucairn-sanitizer-core-deploy-ca
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
CNF
  # -sha256 everywhere: LibreSSL (macOS /usr/bin/openssl) signs ECDSA with SHA-1
  # by default, and Go's TLS stack rejects ECDSA-SHA1 chains outright.
  "$OPENSSL" req -new -x509 -sha256 -key "$CA_KEY" -out "$CA_CRT" -days "$CA_DAYS" \
    -config "$TMP/ca.cnf" -extensions v3_ca -set_serial "$(rand_serial)"
else
  log "CA exists - reusing"
fi

# issue_leaf <relative path without extension> <CN> <EKU> <SAN list>
issue_leaf() {
  local rel="$1" cn="$2" eku="$3" san="$4" key crt
  key="$CERT_DIR/$rel.key"
  crt="$CERT_DIR/$rel.crt"
  if [ -f "$key" ] && [ -f "$crt" ]; then
    log "$rel exists - reusing"
    return 0
  fi
  [ ! -f "$key" ] && [ ! -f "$crt" ] \
    || die "half a leaf at $rel (key and certificate must both exist or both be absent)"
  log "issuing $rel (CN=$cn, $eku, ${LEAF_DAYS} days)"
  "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$key"
  "$OPENSSL" req -new -sha256 -key "$key" -subj "/CN=$cn" -out "$TMP/leaf.csr"
  printf 'basicConstraints = critical, CA:FALSE\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = %s\nsubjectAltName = %s\n' \
    "$eku" "$san" > "$TMP/leaf.ext"
  "$OPENSSL" x509 -req -sha256 -in "$TMP/leaf.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -set_serial "$(rand_serial)" -days "$LEAF_DAYS" -extfile "$TMP/leaf.ext" -out "$crt" 2>/dev/null
  rm -f "$TMP/leaf.csr" "$TMP/leaf.ext"
}

# ── 2. Leaves ──────────────────────────────────────────────────────────────
issue_leaf sanitizer-core/dsa-sanitizer-core dsa-sanitizer-core serverAuth \
  "DNS:dsa-sanitizer-core, DNS:sanitizer-core, DNS:localhost, IP:127.0.0.1"
issue_leaf sanitizer-core/witness-client dsa-sanitizer clientAuth \
  "DNS:dsa-sanitizer"
issue_leaf gateway/dsa-gateway dsa-gateway clientAuth \
  "DNS:dsa-gateway"
issue_leaf veil-witness/dsa-veil-witness dsa-veil-witness serverAuth \
  "DNS:dsa-veil-witness, DNS:veil-witness, DNS:witness"

for svc in sanitizer-core gateway veil-witness; do
  cp "$CA_CRT" "$CERT_DIR/$svc/ca.crt"
done

# ── 3. Verify what was written (the chain and the purpose, per leaf) ─────
for pair in "sanitizer-core/dsa-sanitizer-core:sslserver" "sanitizer-core/witness-client:sslclient" \
            "gateway/dsa-gateway:sslclient" "veil-witness/dsa-veil-witness:sslserver"; do
  rel="${pair%%:*}"; purpose="${pair##*:}"
  "$OPENSSL" verify -CAfile "$CA_CRT" -purpose "$purpose" "$CERT_DIR/$rel.crt" >/dev/null \
    || die "$rel.crt does not verify against $CA_CRT for $purpose"
done

# ── 4. Permissions ─────────────────────────────────────────────────────────
chmod 0600 "$CA_KEY" "$CERT_DIR"/sanitizer-core/*.key "$CERT_DIR"/gateway/*.key "$CERT_DIR"/veil-witness/*.key
chmod 0644 "$CA_CRT" "$CERT_DIR"/sanitizer-core/*.crt "$CERT_DIR"/gateway/*.crt "$CERT_DIR"/veil-witness/*.crt
chmod 0700 "$CA_DIR"
chmod 0755 "$CERT_DIR" "$CERT_DIR/sanitizer-core" "$CERT_DIR/gateway" "$CERT_DIR/veil-witness"

if [ "$(id -u)" = "0" ]; then
  # Directories stay 0755 so the operator (and `bin/lucairn doctor`) can still
  # read the certificates; the keys are 0600 and readable by uid $CONTAINER_UID only.
  chown -R "$CONTAINER_UID:$CONTAINER_UID" "$CERT_DIR/sanitizer-core" "$CERT_DIR/gateway" "$CERT_DIR/veil-witness"
  log "service directories handed to uid $CONTAINER_UID (keys 0600); the CA directory $CA_DIR stays root-only"
  # R1: the folders this run created for the operator (./.certs, the cert
  # directory, ./.secrets) go back to the user who ran sudo, so that user can
  # copy the witness-signed manifest into ./.certs and write the registry DSN
  # file under ./.secrets without sudo. The CA directory and the service
  # directories are not in this list.
  case "${SUDO_UID:-}" in
    ''|0|*[!0-9]*) : ;;
    *)
      _back_gid="${SUDO_GID:-$SUDO_UID}"
      case "$_back_gid" in ''|*[!0-9]*) _back_gid="$SUDO_UID" ;; esac
      for p in ${CREATED_PARENTS[@]+"${CREATED_PARENTS[@]}"}; do
        [ "$p" = "$CA_DIR" ] && continue
        chown "$SUDO_UID:$_back_gid" "$p" || die "could not hand $p back to uid $SUDO_UID"
        log "handed $p back to uid $SUDO_UID (it was created under sudo)"
      done
      ;;
  esac
elif [ "$(uname -s)" = "Linux" ]; then
  # Only reached when LUCAIRN_CONTAINER_UID was declared = this uid (above).
  log "not root: the service keys are owned by $(id -un) (uid $(id -u)), the uid you declared the image user maps to"
else
  log "not root: the service keys are owned by $(id -un). Docker Desktop on $(uname -s) maps file ownership, so the containers can read them."
  log "If you copy this directory to a Linux Docker host, hand it to uid $CONTAINER_UID there:"
  log "  sudo chown -R $CONTAINER_UID:$CONTAINER_UID '$CERT_DIR/sanitizer-core' '$CERT_DIR/gateway' '$CERT_DIR/veil-witness'"
fi

log "done: $CERT_DIR (CA: $CA_DIR, mounted by no container)"
if [ "$CERT_DIR" != "$DEFAULT_CERT_DIR" ]; then
  log "set in customer.env: SANITIZER_CORE_MTLS_HOST_DIR=$CERT_DIR"
fi
if [ -n "${2:-${SANITIZER_CORE_MTLS_CA_DIR:-}}" ]; then
  log "set in customer.env: SANITIZER_CORE_MTLS_CA_DIR=$CA_DIR   (so bin/lucairn doctor checks that no container mounts it)"
fi
log "next: bin/lucairn doctor --env customer.env --offline   (checks every file above)"
