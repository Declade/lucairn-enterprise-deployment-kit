#!/bin/sh
#
# witness-egress-guard.sh — refuse to start the claim emitters when the witness
# they would ship claims to is a LUCAIRN-OPERATED host.
#
# Board T-682. Fable review 2026-08-21 § 2c (HIGH): "the witness-central overlay
# is prose-guarded, not code-guarded". This file is the code guard.
#
# ── THE DEFECT THIS CLOSES ────────────────────────────────────────────────────
#
# `contrib/witness-central/docker-compose.witness-central.yml` repoints every
# claim emitter at a witness the device operator does not run, via
# LUCAIRN_CENTRAL_WITNESS_ADDR. One of those claims is the sanitizer's
# PII_SANITIZED, and it carries `redaction_manifest_body` — the
# placeholder→original map. That is the single most sensitive artifact the
# product produces: with it, every placeholder in every certified turn can be
# resolved back to the real value.
#
# docs/WITNESS_CENTRAL_RUNBOOK.md § 1 says the central witness must be "their
# own instance on a server the consultant does not administer". Nothing enforced
# it. An operator who set
#
#     LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu:50057
#
# got a working install that streams the placeholder→original map to LUCAIRN.
# That directly contradicts the product's non-negotiable promise — "no raw
# identity data leaves your environment" (Enterprise self-hosted) — and it did
# so with no error, no warning, and no line in any log.
#
# ── THE MECHANISM ─────────────────────────────────────────────────────────────
#
# This script runs as a run-once preflight service that every claim emitter
# declares `depends_on: condition: service_completed_successfully`. It reads the
# same two operator-facing variables the emitters read, extracts the HOSTNAME
# from each, and exits non-zero when that hostname is (or is a subdomain of) a
# domain Lucairn operates. A non-zero exit means `docker compose up` fails and
# the emitters never start, so no claim is ever submitted.
#
#   LUCAIRN_CENTRAL_WITNESS_ADDR       claim hop  (:50057) — carries
#                                      redaction_manifest_body
#   LUCAIRN_CENTRAL_WITNESS_CERT_ADDR  certificate hop (:50058) — GetCertificate
#                                      / ExportCertificates return certificates
#                                      that carry redaction_manifest_body, so
#                                      this address is checked too
#   LUCAIRN_DASHBOARD_WITNESS_ENDPOINT the dashboard's own dial at the same cert
#                                      port. docs/WITNESS_CENTRAL_RUNBOOK.md § 9
#                                      instructs operators to repoint it at the
#                                      central witness under this overlay, which
#                                      makes it a third named route to a
#                                      Lucairn-operated evidence plane.
#
#   LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS
#                                      the single escape hatch. Exactly "true"
#                                      re-permits it and prints a banner naming
#                                      what is being sent and to whom; exactly
#                                      "false" is the default; ANYTHING ELSE is
#                                      refused rather than guessed at.
#
# ── WHAT THIS IS NOT ──────────────────────────────────────────────────────────
#
# It is NOT a privilege boundary, and it is deliberately not described as one.
# Anyone who can edit the install's compose files or run `docker compose up
# --no-deps sanitizer` can bypass it — the same honest limit T-350 states about
# the migration ceiling. What it buys is that the egress cannot happen by
# ACCIDENT, that every route to it requires a deliberate, differently-named,
# screaming acknowledgement, and that the acknowledgement is written into the
# container log where a reviewer can find it afterwards.
#
# It is also NAME-BASED, not resolution-based. A hostname is compared against a
# list of Lucairn-operated domains; no DNS lookup is performed (the preflight
# must work on an air-gapped install, and a resolver answer is not evidence of
# who operates the host anyway). Consequences, stated rather than papered over:
#
#   * A BARE IP ADDRESS pointing at a Lucairn host is NOT caught. The script
#     prints a NOTICE saying so, so the log records the limit rather than
#     implying a check that did not happen.
#   * A customer CNAME that happens to point at Lucairn infrastructure is not
#     caught either.
#
# ── FAIL-CLOSED ───────────────────────────────────────────────────────────────
#
# A value that is set but from which no hostname can be extracted is REFUSED
# (exit 90). A hatch value that is neither "true" nor "false" is REFUSED (exit
# 95). An unset address is the stock topology and passes — customer.yml pins the
# local `veil-witness:50057` and never consults these variables.

set -eu

LABEL="witness-egress-guard"

# ── The blocked set ───────────────────────────────────────────────────────────
#
# Domains Lucairn operates. Matching is exact-or-subdomain, case-insensitive.
#
#   lucairn.eu    primary brand domain; gateway.lucairn.eu et al.
#   lucairn.com   also Lucairn's, currently unrouted — listed BECAUSE it is
#                 unrouted today: the day it starts resolving, an install that
#                 pointed at it must not silently begin working.
#   dsaveil.io    legacy domain, still load-bearing (gateway.dsaveil.io,
#                 vault.dsaveil.io).
#
# Kept as a plain space-separated list so the same literal set can be asserted
# by tests/test_witness_central_egress_guard.sh.
LUCAIRN_OPERATED_DOMAINS="lucairn.eu lucairn.com dsaveil.io"

fatal() {
  echo "[$LABEL] FATAL: $1" >&2
  exit "$2"
}

# Split a gRPC dial target into the host-bearing tokens it contains.
#
# ── WHY THIS RETURNS TWO TOKENS AND NOT ONE ───────────────────────────────────
#
# gRPC's target syntax is `scheme://authority/endpoint`, and for the `dns`
# resolver the AUTHORITY is the name server while the ENDPOINT is the host
# actually dialled (grpc-go `internal/resolver/dns`). All three of these are
# legitimate spellings of the same dial:
#
#   witness.lucairn.eu:50057                       bare  — endpoint only
#   dns:///witness.lucairn.eu:50057                empty authority
#   dns://resolver.example.com/witness.lucairn.eu:50057   authority + endpoint
#
# An earlier revision of this function returned ONE token: whatever sat before
# the first "/". Measured on that revision, the third spelling extracted
# `resolver.example.com` — the DNS SERVER — discarded the Lucairn endpoint
# entirely, and printed
#
#   [witness-egress-guard] OK: checked 1 configured witness address(es); none
#   resolves by name to a Lucairn-operated domain
#
# with exit 0. That is the same fail-open-with-an-OK-line shape as the
# `ADDR=":"` defect this file already fixed once, one syntax variant over: the
# log asserted a check that had been performed on the wrong string.
#
# So both tokens are returned and BOTH are checked, which collapses all three
# spellings above into one rule and removes the question of which half of a
# `dns://a/b` target "counts".
#
# Sets TARGET_AUTHORITY and TARGET_ENDPOINT; either may be the empty string,
# which the caller treats as "not present" rather than as "empty host".
split_target() {
  _t="$1"
  # Strip a scheme, if any: everything up to and including the LAST "://".
  # (Deliberately the LAST — see the parity note above is_plausible_host.)
  case "$_t" in
    *://*) _t="${_t##*://}" ;;
  esac
  # `dns:///host:port` puts the authority after a THIRD slash, i.e. the strip
  # above leaves a leading "/" and an EMPTY authority. Measured before this was
  # handled: the whole value reduced to "" and a `dns:///` target on a Lucairn
  # host was refused as UNPARSEABLE rather than as Lucairn-operated — the right
  # outcome for the wrong reason — while the same legitimate spelling on a
  # customer host was refused outright.
  while :; do
    case "$_t" in
      /*) _t="${_t#/}" ;;
      *) break ;;
    esac
  done
  TARGET_AUTHORITY="${_t%%/*}"
  case "$_t" in
    */*)
      TARGET_ENDPOINT="${_t#*/}"
      TARGET_ENDPOINT="${TARGET_ENDPOINT%%/*}"
      ;;
    *) TARGET_ENDPOINT="" ;;
  esac
}

# Reduce ONE host-bearing token to a comparable hostname.
#
# Handles: a trailing :port, a trailing ?query, an IPv6 literal in brackets
# (`[::1]:50057` -> `::1`), a trailing root dot, and mixed case. Echoes the
# lowercased host, or the empty string when the token reduces to nothing.
normalize_host() {
  _v="$1"
  _v="${_v%%\?*}"
  case "$_v" in
    \[*\]*)
      _v="${_v#\[}"
      _v="${_v%%\]*}"
      ;;
    *)
      # host:port -> host. Only strip a trailing :<digits> so that a value
      # which is itself malformed is not silently truncated into something
      # that looks fine.
      case "$_v" in
        *:*)
          _port="${_v##*:}"
          case "$_port" in
            ''|*[!0-9]*) : ;;          # not a port; leave the value alone
            *) _v="${_v%:*}" ;;
          esac
          ;;
      esac
      ;;
  esac
  # Trailing root dot: `witness.lucairn.eu.` is the same host.
  _v="${_v%.}"
  printf '%s' "$_v" | tr '[:upper:]' '[:lower:]'
}

# Is $1 exactly a blocked domain, or a subdomain of one?
is_lucairn_operated() {
  _host="$1"
  for _d in $LUCAIRN_OPERATED_DOMAINS; do
    [ "$_host" = "$_d" ] && return 0
    case "$_host" in
      *".$_d") return 0 ;;
    esac
  done
  return 1
}

# Purely syntactic: does this look like a bare IPv4/IPv6 literal?
#
# ── WHY THE IPv6 ARM IS A GRAMMAR AND NOT A CHARACTER CLASS ───────────────────
#
# This predicate now decides whether a colon-bearing token is a host at all
# (see is_plausible_host), so "anything made of hex digits and colons" is no
# longer a safe answer. MEASURED while writing this round's MED-1 fix: with the
# old `^[0-9a-f:]+$` class, LUCAIRN_CENTRAL_WITNESS_ADDR=":" was classified as
# an IPv6 literal, printed the bare-IP NOTICE, and exited 0 — reintroducing the
# very fail-open-on-garbage defect this file was written to close, from the
# opposite side. So the arm below is an actual IPv6 grammar: a full eight-group
# form, or exactly one "::" compression, and at least one hex digit present.
# ":" and ":::" are not IPv6 literals and are refused as unparseable, which is
# also what the Helm twin does with them.
#
# NOT accepted (fail-closed, same as before this round): IPv4-mapped forms such
# as `::ffff:192.0.2.1`, which carry dots. They exit 90 rather than pass — an
# operator who needs one can write the plain IPv4 address or a name.
looks_like_ip() {
  case "$1" in
    *:*)
      # A token of pure punctuation names nothing.
      case "$1" in
        *[0-9a-f]*) : ;;
        *) return 1 ;;
      esac
      printf '%s' "$1" | grep -qE '^[0-9a-f]{1,4}(:[0-9a-f]{1,4}){7}$' && return 0
      printf '%s' "$1" | grep -qE '^([0-9a-f]{1,4}(:[0-9a-f]{1,4})*)?::([0-9a-f]{1,4}(:[0-9a-f]{1,4})*)?$' && return 0
      return 1 ;;
    [0-9]*.[0-9]*.[0-9]*.[0-9]*)
      # Reject 1.2.3.4.example.com — only 4 all-numeric labels count.
      printf '%s' "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' && return 0
      return 1 ;;
  esac
  return 1
}

# Is this a plausible hostname or IP literal at all?
#
# This exists because the extractor is deliberately forgiving and a forgiving
# extractor fails OPEN on garbage. Measured before this check existed:
# LUCAIRN_CENTRAL_WITNESS_ADDR=":" survived extraction as the host ":", matched
# nothing in the blocked list, and the guard printed OK — a value that cannot
# name any host was treated as "checked and fine". A value this script cannot
# recognise as a host must be refused, not waved through.
#
# ── WHY A RESIDUAL COLON IS AN IPv6 QUESTION, NOT A CHARSET ONE ───────────────
#
# normalize_host() strips exactly ONE trailing `:<digits>`. Anything with a
# colon still in it afterwards is therefore one of two things and nothing else:
# a real IPv6 literal, or a value the parser could not reduce to a host.
# Measured when this predicate merely listed `:` in its charset:
#
#   LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu:50057:50057
#     -> host `witness.lucairn.eu:50057` -> matched no blocked domain (the
#        suffix test is anchored on the whole string) -> "OK: checked 1", exit 0
#
# i.e. a Lucairn host waved through with a clean OK line. So a name-shaped token
# with a leftover colon is refused (exit 90), and only a token that is ITSELF an
# IP literal is allowed to carry colons. That also repairs the mirror defect —
# `[::1]:50057` extracts to `::1`, which the old first-char `[a-z0-9]` class
# rejected as implausible, so a bracketed IPv6 literal exited 90 while the
# comment above split_target claimed brackets were handled.
is_plausible_host() {
  case "$1" in
    *:*)
      looks_like_ip "$1" && return 0
      return 1 ;;
  esac
  printf '%s' "$1" | grep -qE '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$'
}

# ── PARITY NOTE: scheme-strip direction (deliberate, documented) ──────────────
#
# This script strips up to and including the LAST "://"; the Helm twin
# (charts/lucairn/templates/_validators.tpl :: validators.witnessHosts) does the
# same, via a greedy `^.*://+`. They were NOT the same before this round: the
# Helm regex was anchored non-greedily at the FIRST "://", so a pathological
# value carrying two schemes —
#
#   https://evil.example/redirect?url=http://lucairn.eu:50057
#
# — reduced to `lucairn.eu` here (refuse) and to `evil.example` there (render).
# Both are defensible readings of a string that is not a valid gRPC target
# either way, but "defensible on each side" is exactly the twin-drift this
# guard exists to not have: a value refused by Compose must not install under
# Helm. Aligned on the LAST "://" because that is the over-blocking direction,
# and an over-block on a malformed target costs an operator one edit while an
# under-block costs them the manifest bodies.

# ── The hatch. Strict boolean, no guessing. ──────────────────────────────────
#
# An egress escape hatch must not have an ambiguous value. Compose passes plain
# strings with no YAML parser to consult, so "True"/"yes"/"on"/"1" are REFUSED
# rather than silently treated as off (leaving the operator believing the hatch
# is open when it is not) or as on (the far worse direction). The Helm twin is
# deliberately different — Helm's own parser turns those spellings into real
# booleans before any template runs — and that asymmetry is documented in
# contrib/witness-central/witness-central.env.example rather than papered over.
ACK="${LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS:-false}"
case "$ACK" in
  true|false) ;;
  *) fatal "LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS must be exactly 'true' or 'false' (got '${ACK}'). Lowercase, unquoted, no other spelling — 'True', 'yes', 'on' and '1' are refused, not interpreted. Starting NO services. See docs/WITNESS_CENTRAL_RUNBOOK.md § \"The Lucairn-operated-witness guard\"." 95 ;;
esac

blocked=""
checked=0

NL='
'

# The three operator-facing addresses that name a witness this install talks to.
#
#   LUCAIRN_CENTRAL_WITNESS_ADDR        claim hop (:50057) — carries
#                                       redaction_manifest_body outbound.
#   LUCAIRN_CENTRAL_WITNESS_CERT_ADDR   certificate hop (:50058) — GetCertificate
#                                       / ExportCertificates serve the same
#                                       payload back.
#   LUCAIRN_DASHBOARD_WITNESS_ENDPOINT  the dashboard's own cert-port dial.
#                                       docs/WITNESS_CENTRAL_RUNBOOK.md § 9
#                                       tells operators to repoint it at the
#                                       central witness under this overlay
#                                       ("Point the dashboard at the central
#                                       witness (LUCAIRN_DASHBOARD_WITNESS_ENDPOINT)"),
#                                       so it is a third route by which an
#                                       install's evidence plane becomes a
#                                       Lucairn-operated one — named in the
#                                       runbook, and unchecked until this round.
for _var in LUCAIRN_CENTRAL_WITNESS_ADDR LUCAIRN_CENTRAL_WITNESS_CERT_ADDR LUCAIRN_DASHBOARD_WITNESS_ENDPOINT; do
  eval "_val=\${$_var:-}"
  [ -n "$_val" ] || continue
  checked=$((checked + 1))

  # A newline in the value is refused outright rather than parsed. `grep` is
  # LINE-oriented, so is_plausible_host() answers about SOME line of a
  # multi-line value, not about the value. Measured before this check:
  #
  #   LUCAIRN_CENTRAL_WITNESS_ADDR='witness.lucairn.eu:50057<LF>safe.example.com:50057'
  #     -> the port-strip left `witness.lucairn.eu:50057<LF>safe.example.com`,
  #        grep matched the SECOND line, the whole-string suffix test matched no
  #        blocked domain, and the guard printed OK and exited 0.
  #
  # No witness address has a newline in it, so there is nothing to parse and
  # everything to lose by trying.
  case "$_val" in
    *"$NL"*)
      fatal "${_var} contains a newline. A witness address is a single host:port token; a multi-line value cannot be checked line-safely and is refused rather than parsed. Fix the value in your env file (a stray line continuation or a pasted block is the usual cause)." 90
      ;;
  esac

  split_target "$_val"

  # Check the authority AND the endpoint. See split_target's header: for a
  # `dns://authority/endpoint` target the endpoint is the host actually dialled,
  # and checking only one of the two is how `dns://resolver.example.com/witness.lucairn.eu:50057`
  # used to earn a clean OK line.
  _seen=0
  for _cand in "$TARGET_AUTHORITY" "$TARGET_ENDPOINT"; do
    [ -n "$_cand" ] || continue
    _seen=$((_seen + 1))
    _host="$(normalize_host "$_cand")"
    if [ -z "$_host" ] || ! is_plausible_host "$_host"; then
      fatal "${_var}='${_val}' is set but no hostname could be extracted from it (the token '${_cand}' reduced to '${_host}'). Refusing to start rather than guessing which witness the claims would go to — a value this guard cannot parse is a value it cannot check, and passing it would report a check that did not happen. Expected host:port, e.g. witness.example.eu:50057." 90
    fi

    if is_lucairn_operated "$_host"; then
      # NEWLINE-separated, deliberately: each entry contains spaces, so a
      # space-separated accumulator would word-split into unreadable fragments
      # exactly when the operator most needs to read it.
      blocked="${blocked}${blocked:+$NL}${_var}=${_val} (host ${_host})"
    elif looks_like_ip "$_host"; then
      echo "[$LABEL] NOTICE: ${_var} names a bare IP address (${_host}). This guard is NAME-based and performs no DNS or ownership lookup, so it cannot tell whether that address belongs to Lucairn. Verify it yourself — docs/WITNESS_CENTRAL_RUNBOOK.md § 1 requires a witness the operator of this device does not administer." >&2
    fi
  done

  if [ "$_seen" -eq 0 ]; then
    fatal "${_var}='${_val}' is set but contains no host token at all. Refusing to start rather than guessing which witness the claims would go to. Expected host:port, e.g. witness.example.eu:50057." 90
  fi
done

if [ -z "$blocked" ]; then
  if [ "$checked" -eq 0 ]; then
    echo "[$LABEL] OK: no central witness configured (LUCAIRN_CENTRAL_WITNESS_ADDR / LUCAIRN_CENTRAL_WITNESS_CERT_ADDR / LUCAIRN_DASHBOARD_WITNESS_ENDPOINT unset). Claims stay on this host."
  else
    echo "[$LABEL] OK: checked ${checked} configured witness address(es); none resolves by name to a Lucairn-operated domain (${LUCAIRN_OPERATED_DOMAINS})."
  fi
  exit 0
fi

# Iterate the newline-separated accumulator without word-splitting on spaces.
_saved_ifs="$IFS"
IFS='
'

if [ "$ACK" = "true" ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  echo "!! [$LABEL] UNSAFE OVERRIDE ACTIVE" >&2
  echo "!! LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS=true" >&2
  echo "!!" >&2
  echo "!! This install is sending its evidence claims to a LUCAIRN-OPERATED" >&2
  echo "!! witness:" >&2
  for _b in $blocked; do
    echo "!!   ${_b}" >&2
  done
  echo "!!" >&2
  echo "!! WHAT THAT SENDS. The sanitizer's PII_SANITIZED claim carries" >&2
  echo "!! redaction_manifest_body — the placeholder->original map. Everything" >&2
  echo "!! this deployment redacted can be resolved back to the real value by" >&2
  echo "!! whoever holds those claims. The certificate port serves the same" >&2
  echo "!! payload back via GetCertificate / ExportCertificates." >&2
  echo "!!" >&2
  echo "!! For as long as this flag is set, the sentence \"no raw identity data" >&2
  echo "!! leaves your environment\" is NOT TRUE of this install, and Lucairn is" >&2
  echo "!! a processor of every identity value it redacts. If a data-processing" >&2
  echo "!! agreement covering that is not in place, unset this flag." >&2
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  IFS="$_saved_ifs"
  exit 0
fi

echo "" >&2
echo "[$LABEL] REFUSING TO START." >&2
echo "" >&2
echo "  A central witness on a LUCAIRN-OPERATED domain was configured:" >&2
for _b in $blocked; do
  echo "    ${_b}" >&2
done
echo "" >&2
echo "  Claims submitted to that witness include the sanitizer's PII_SANITIZED" >&2
echo "  claim, which carries redaction_manifest_body — the placeholder->original" >&2
echo "  map. Sending it to a witness Lucairn operates would mean every value this" >&2
echo "  deployment redacts leaves your environment in a resolvable form, which is" >&2
echo "  the exact opposite of what the witness-central topology exists to do." >&2
echo "" >&2
echo "  docs/WITNESS_CENTRAL_RUNBOOK.md § 1: the central witness must be \"their" >&2
echo "  own instance on a server the consultant does not administer\" — a host YOU" >&2
echo "  or YOUR CUSTOMER runs, not one Lucairn runs." >&2
echo "" >&2
echo "  FIX: point LUCAIRN_CENTRAL_WITNESS_ADDR (and" >&2
echo "  LUCAIRN_CENTRAL_WITNESS_CERT_ADDR) at your own witness host in" >&2
echo "  contrib/witness-central/witness-central.env." >&2
echo "" >&2
echo "  If you are Lucairn staff running an internal pilot on Lucairn" >&2
echo "  infrastructure, and a data-processing agreement covers the manifest" >&2
echo "  bodies, set" >&2
echo "    LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS=true" >&2
echo "  It is spelled that way on purpose. It is recorded in this log every" >&2
echo "  time the stack starts." >&2
echo "" >&2
echo "  Blocked domains (exact or subdomain): ${LUCAIRN_OPERATED_DOMAINS}" >&2
echo "" >&2
exit 96
