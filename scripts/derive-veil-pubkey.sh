#!/usr/bin/env bash
#
# Derive the Ed25519 public key (64-char hex) from a 32-byte hex seed
# (the VEIL_*_SIGNING_KEY value generated with `openssl rand -hex 32`).
#
# Usage:
#   scripts/derive-veil-pubkey.sh <64-char-hex-seed>   # legacy argv form
#   printf '%s' "$SEED" | scripts/derive-veil-pubkey.sh # stdin form (preferred)
#
# SEC-04 (hardening 2026-05-28): the seed is an Ed25519 PRIVATE-key seed.
# Passing it as `$1` exposes it in the process argument list (`ps auxww`,
# `/proc/<pid>/cmdline`) of any local user for the lifetime of the call.
# The stdin form keeps the secret off the argument list entirely. The argv
# form is retained for backward compatibility (existing INSTALL.md one-liners
# + the catch-all renderer fallback) but the bundled render-values.sh now
# feeds the seed via stdin.
#
# Example (stdin, preferred):
#   $ SEED=$(openssl rand -hex 32)
#   $ printf '%s' "$SEED" | scripts/derive-veil-pubkey.sh
#
# Example (legacy argv):
#   $ echo "LCR_AUDIT_PUBLIC_KEY=$(scripts/derive-veil-pubkey.sh "$SEED")"
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

# Accept the seed from argv ($1) OR, when no argument is given, from stdin.
# The stdin form (preferred) keeps the private-key seed off the process
# argument list. We strip a single trailing newline so `printf '%s' "$SEED"`
# and `echo "$SEED"` both work.
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [<64-char-hex-seed>]   (or pipe the seed on stdin)" >&2
  exit 2
elif [ "$#" -eq 1 ]; then
  seed_hex="$1"
else
  # No argv seed: read it from stdin. `read -r` drops the trailing newline.
  if [ -t 0 ]; then
    echo "error: no seed argument and stdin is a terminal; pipe the 64-char hex seed or pass it as \$1" >&2
    exit 2
  fi
  IFS= read -r seed_hex || true
fi

if ! printf '%s' "$seed_hex" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  echo "error: input must be 64 hex characters (32 bytes); got: ${#seed_hex} chars" >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required" >&2
  exit 2
}

python3 - "$seed_hex" <<'PY'
# We deliberately use the cryptography library's older
# `public_bytes(Encoding.Raw, PublicFormat.Raw)` API rather than the
# newer `public_bytes_raw()` shortcut. The shortcut was added in
# cryptography 40.0 (May 2023); the older API works back to
# cryptography 2.6 (Feb 2019, when Ed25519 was added). Ubuntu 22.04 LTS's apt-installed
# `python3-cryptography` package is 3.4.8 — old enough that
# `public_bytes_raw` is an AttributeError. The Encoding/PublicFormat
# form pulls in two extra imports but works on every cryptography
# version a customer is likely to have installed via apt.
import binascii, sys
seed = binascii.unhexlify(sys.argv[1])
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    pub = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
except Exception:
    try:
        from nacl.signing import SigningKey
        pub = bytes(SigningKey(seed).verify_key)
    except Exception as e:
        sys.stderr.write(
            "error: neither 'cryptography' (>=2.6) nor 'pynacl' is installed.\n"
            "  On Ubuntu 22.04 the apt-installed python3-cryptography (3.4.8) works.\n"
            "  Otherwise: pip install cryptography  (preferred)\n"
            f"  underlying error: {e}\n"
        )
        sys.exit(2)
print(binascii.hexlify(pub).decode())
PY
