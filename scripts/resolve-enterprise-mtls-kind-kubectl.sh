#!/usr/bin/env bash
set -euo pipefail

# Resolve the host-provided kubectl used by the disposable Kind harness. This
# intentionally never downloads or provisions an executable: the caller owns
# the tool supply chain. Keep stdout to the resolved absolute path only so the
# harness and its offline contract test can use it safely.

if [ -n "${KUBECTL:-}" ]; then
  case "$KUBECTL" in
    /*) ;;
    *)
      echo "BLOCKED: KUBECTL override must be an absolute path to an executable file." >&2
      exit 2
      ;;
  esac
  if [ ! -f "$KUBECTL" ] || [ ! -x "$KUBECTL" ]; then
    echo "BLOCKED: KUBECTL override is not an executable file: $KUBECTL" >&2
    exit 2
  fi
  printf '%s\n' "$KUBECTL"
  exit 0
fi

resolved="$(command -v kubectl || true)"
if [ -z "$resolved" ] || [ ! -f "$resolved" ] || [ ! -x "$resolved" ]; then
  echo "BLOCKED: kubectl is not installed as an executable file; install it or set KUBECTL=/absolute/path." >&2
  exit 2
fi
case "$resolved" in
  /*) printf '%s\n' "$resolved" ;;
  *)
    resolved_dir="$(cd "$(dirname "$resolved")" && pwd)" || {
      echo "BLOCKED: kubectl PATH resolution could not be made absolute." >&2
      exit 2
    }
    printf '%s/%s\n' "$resolved_dir" "$(basename "$resolved")"
    ;;
esac
