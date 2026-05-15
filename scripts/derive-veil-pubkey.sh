#!/usr/bin/env bash
#
# Derive the Ed25519 public key (64-char hex) from a 32-byte hex seed
# (the VEIL_*_SIGNING_KEY value generated with `openssl rand -hex 32`).
#
# Usage:
#   scripts/derive-veil-pubkey.sh <64-char-hex-seed>
#
# Example:
#   $ SEED=$(openssl rand -hex 32)
#   $ echo "VEIL_AUDIT_SIGNING_KEY=$SEED"
#   $ echo "VEIL_AUDIT_PUBLIC_KEY=$(scripts/derive-veil-pubkey.sh "$SEED")"
#
# Why this exists:
#   The `VEIL_*_SIGNING_KEY` env vars are Ed25519 private-key seeds rendered
#   as 64-char hex. The matching `VEIL_*_PUBLIC_KEY` env var MUST be derived
#   from the corresponding signing key — generating it independently
#   (e.g. with another `openssl rand -hex 32`) yields a public key that
#   does NOT match the signing key, and every Veil claim the service signs
#   will be silently rejected by the witness verifier.
#
# Method:
#   Uses Python's `cryptography` library (already required by the
#   bootstrap pipeline in the upstream dual-sandbox-architecture repo)
#   to load the seed via `Ed25519PrivateKey.from_private_bytes` and emit
#   the raw 32-byte public key as 64-char hex. Falls back to `pynacl` if
#   `cryptography` is unavailable.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <64-char-hex-seed>" >&2
  exit 2
fi

seed_hex="$1"

if ! printf '%s' "$seed_hex" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  echo "error: input must be 64 hex characters (32 bytes); got: ${#seed_hex} chars" >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required" >&2
  exit 2
}

python3 - "$seed_hex" <<'PY'
import binascii, sys
seed = binascii.unhexlify(sys.argv[1])
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    pub = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes_raw()
except Exception:
    try:
        from nacl.signing import SigningKey
        pub = bytes(SigningKey(seed).verify_key)
    except Exception as e:
        sys.stderr.write(
            "error: neither 'cryptography' nor 'pynacl' is installed.\n"
            "  pip install cryptography  (preferred)\n"
            f"  underlying error: {e}\n"
        )
        sys.exit(2)
print(binascii.hexlify(pub).decode())
PY
