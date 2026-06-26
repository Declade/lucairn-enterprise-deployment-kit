#!/usr/bin/env bash
# tests/lib/test-helpers.sh — shared constants for kit test harness
#
# Source this file at the top of any test script that calls `helm template`
# or `helm lint` to ensure the veil-witness all-zeroes signing-key guard
# passes at render time without weakening the production guard itself.
#
# The guard lives at:
#   charts/lucairn/charts/veil-witness/templates/_validate.tpl:38
#   ({{ fail }} on the all-zeroes placeholder "0000…0000")
#
# TEST_SIGNING_KEY is a fixed, obviously-non-production hex constant. Its
# value is irrelevant; it just satisfies the format check (64 hex chars,
# non-zero). It MUST NOT be the all-zeroes default.
#
# Usage:
#   source "$(dirname "$0")/lib/test-helpers.sh"
#   helm template lucairn charts/lucairn \
#     --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
#     ...

readonly TEST_SIGNING_KEY="1111111111111111111111111111111111111111111111111111111111111111"
