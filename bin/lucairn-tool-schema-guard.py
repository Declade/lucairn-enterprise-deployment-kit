#!/usr/bin/env python3
"""lucairn-tool-schema-guard.py — offline dry-run of the gateway's T-14 tool-schema PII guard.

T-498, PRD specs/2026-08/prd-2026-08-04-kit-release-readiness-t14-residuals.md
(Slice B4).  Invoked only by `bin/lucairn doctor --tools`; not a supported
standalone entry point.

WHY THIS EXISTS
---------------
The kit ships `GATEWAY_TOOL_SCHEMA_GUARD=refuse` (T-493, 2026-08-04) — the
guard enforces from the FIRST routed turn, with no observation window.  That
decision was taken on a false-positive estimate computed by ARITHMETIC over
random hex (a 32-hex ServiceNow sys_id matches the IBAN SHAPE ~5.5% of the
time; ~0.0555% once T-497 gated the matcher on the ISO 7064 MOD 97-10
checksum), not by MEASUREMENT over real customer tool schemas.

This script is what converts that bet into a fact for a given install.  Point it
at the tool declarations your clients actually send and it reports what the
gateway WOULD refuse, before any request is routed and without running `log`
mode in production.

WHAT IT MIRRORS, AND FROM WHERE
-------------------------------
Ported from `Declade/dual-sandbox-architecture` `origin/main` at `08e1afb6b`
(T-497, "gate the IBAN matcher on the ISO 7064 mod-97 checksum in BOTH guards"):

    services/gateway/internal/api/tool_schema_pii_guard.go   (the walk)
    services/gateway/internal/api/iban_checksum.go           (mod-97)
    services/gateway/internal/api/tool_name_pii_guard.go     (the three regexes)

Mirrored in full: the three matchers and their ORDER (IBAN -> email ->
digit-run, a fall-through, never an early clean return); the mod-97 checksum
with its three-way verdict and its fail-CLOSED "cannot evaluate" branch; the
NFKC + invisible-rune + non-ASCII-digit canonicalisation pass; the three scan
contexts (identifier / prose / value) with sticky value context and the
name-keyed-schema-map carve-out; bare-number scanning outside the structural
numeric keyword allowlist, including in prose position (T-496); the type-aware
structural exemption with composition inference to depth 4 and its fail-closed
poisoning of malformed/truncated declarations (T-495); exact decimal expansion
of numeric literals; duplicate-object-key, trailing-content and undecodable-array
detection; the depth (32) and node (200000) budgets; and the three operator
modes.

⚑ THIS IS A DIAGNOSTIC, NOT A CONTROL.  The gateway is the enforcement point.
A clean report here means "the guard as shipped at 08e1afb6b would forward this
payload", NOT "this payload is free of personal data" — same honesty rule the
guard's own header states about itself.

STATED DIVERGENCES (each one measured; read the DIRECTION on each)
------------------------------------------------------------------
0. ⚑ THE MODE VERDICT IS TAKEN FROM A REAL SECOND WALK, NOT FROM FILTERING
   THE FIRST ONE.  This is written first because getting it wrong is the one
   way this script can say CLEAN where the gateway says 400, and an earlier
   revision DID get it wrong.

   `refuse_high_confidence` is not "the findings, minus the digit-run ones".
   The gateway re-walks the whole payload with the digit-run matcher DISABLED
   and lets that second verdict decide (checkToolSchemaPII, guard.go:2018-2031).
   Those two formulations look equivalent and are not, because suppressing a
   matcher lets the strict walk reach code the permissive walk short-circuits
   past — toolSchemaScanNumber returns on the digit-run hit BEFORE it expands
   the literal, so a number like `12345678901e999999999` is a low-confidence
   digit-run hit permissively and a fail-closed `bounds_exceeded` REFUSAL
   strictly.  Filtering reports that payload clean under
   `refuse_high_confidence`; the gateway 400s it.

   So this script runs BOTH walks, exactly as the gateway does, and each mode's
   verdict comes from its own walk:
       refuse                 <=> the permissive walk found anything
       refuse_high_confidence <=> the strict walk found anything
       log                    <=> never refuses
   Findings surfaced only by the strict walk are reported and labelled as such.

1. FIRST FINDING vs EVERY FINDING.  Each gateway walk returns the FIRST problem
   and stops; an operator fixing one hit at a time would need one run per
   finding.  Each walk here enumerates every PII finding in the same
   deterministic order (object keys sorted, arrays in index order), so the
   gateway's verdict for that walk is always this script's FIRST finding from
   it.  A malformed or bounds finding still TERMINATES its walk here exactly as
   it does in the gateway — a declaration the guard could not finish reading is
   one it cannot clear, and continuing past it would invent structure that was
   never read.

1a. DETAIL STRINGS.  `detail=` is byte-identical to the gateway's for every
   finding class.  Where this script can say something more useful about an
   undecodable payload it appends a separate `parser:` clause AFTER the
   detail, rather than widening the field — a diagnostic that quietly reworded
   the control's own vocabulary would break `grep` parity for no gain.

2. UNICODE VERSION.  Go 1.26.2 carries Unicode 15.0.0; this script uses the
   host CPython's tables (3.14 = Unicode 16.0).  Measured against the Go
   tables at 08e1afb6b:
     - invisible-rune set: CPython's Cf/Mn/Me plus the hardcoded
       _EXTRA_INVISIBLE_RANGES below reproduce Go's union exactly, EXCEPT for
       36 codepoints that are Mn only in Unicode 16.  This script strips them,
       Go does not => this script can see a digit run the gateway would not.
     - non-ASCII decimal digit fold: CPython's fold is a strict SUPERSET of
       Go's with identical values (verified over all 0x110000 codepoints; 80
       extra codepoints, 0 disagreements) => same direction.
   Both Unicode deltas make this script report MORE than the gateway, never
   less.  They are the ONLY divergences whose direction is "over-report"; do
   not generalise that phrase to the list as a whole (an earlier revision of
   this header did, and divergence 0 above is what falsified it).

3. INDEX UNITS.  Go's regexp indexes bytes, `re` indexes code points.  The
   candidate SUBSTRINGS enumerated are identical (verified against Go for the
   `(?i)` classes, which in both engines admit U+017F and U+212A into
   `[A-Za-z]`); only the integer offsets differ, and no verdict reads them.
   Any candidate that is not pure ASCII is `inapplicable` => fail-closed in
   both implementations, so the byte/rune distinction cannot reach a verdict.

4. NO VALUE IS EVER PRINTED, and by default no client-authored key is either.
   Findings render the POINTER SKELETON (schema keywords and array indices
   verbatim, every other key segment as a sha256-8 fingerprint), which is what
   the gateway is allowed to write to a log sink.  `--reveal-pointers` prints
   the caller-facing pointer instead — the same string the gateway puts in its
   400 body — for the local fix loop.  That output contains your own property
   names; do not paste it into a support bundle.

   ⚑ ONE PLACE THIS IS STRICTER THAN THE GATEWAY, on purpose.  A key that
   ITSELF matched a matcher is fingerprinted in the caller-facing pointer too —
   not only in the skeleton — and so is every DESCENDANT pointer that passes
   through it.  The gateway never faces this: it returns at the key hit, so no
   later pointer can carry the offending key.  Enumerating every finding does
   face it, and a report whose finding 1 fingerprints a key while finding 2
   spells it out in full would defeat finding 1.  See `_redactions`.

Stdlib only.  Python 3.8+.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import unicodedata

# ---------------------------------------------------------------------------
# Matchers — byte-for-byte the three regexes from tool_name_pii_guard.go.
# No new or looser pattern is introduced here, and none may be added: see the
# "THERE IS NO OPAQUE-ID EXEMPTION" warning in tool_schema_pii_guard.go.
# ---------------------------------------------------------------------------

IBAN_RE = re.compile(
    r"(?:^|[^A-Za-z0-9])([A-Za-z]{2}[0-9]{2}[A-Za-z0-9]{11,30})(?:[^A-Za-z0-9]|$)",
    re.IGNORECASE,
)
EMAIL_RE = re.compile(r"[a-zA-Z0-9._%+\-]{1,64}@[a-zA-Z0-9.\-]{1,253}\.[a-zA-Z]{2,}")
TEN_DIGIT_RUN_RE = re.compile(r"(?:^|[^0-9])([0-9]{10,})(?:[^0-9]|$)")

IBAN_RE_MIN_LEN = 15
TEN_DIGIT_RUN_RE_MIN_LEN = 10

MATCHER_IBAN = "IBAN"
MATCHER_EMAIL = "email"
MATCHER_DIGIT_RUN = "10plus_digit_run"

# ---------------------------------------------------------------------------
# ISO 7064 MOD 97-10 — iban_checksum.go
#
# A CHECKSUM ON THE TRUE-POSITIVE CLASS, NOT A CONTENT EXEMPTION.  It answers
# "is this string actually a member of the class the IBAN matcher claims to
# recognise?" and on "no" withholds ONLY that label; the string still goes on
# to the email and digit-run matchers.  An attacker cannot make a real IBAN
# fail its own check digits.  Never convert a checksum failure into an early
# clean return — that is the rejected whole-string exemption wearing arithmetic.
# ---------------------------------------------------------------------------

CHECKSUM_FAILED = 0
CHECKSUM_PASSED = 1
CHECKSUM_INAPPLICABLE = 2


def iban_candidate_checksum(candidate: str) -> int:
    """Mirror of ibanCandidateChecksum.

    Go iterates BYTES and returns `inapplicable` on any byte >= 0x80, so a
    verdict is only ever reached on a pure-ASCII candidate, where a byte is a
    character.  The ASCII guard below therefore makes this exactly equivalent.
    """
    if len(candidate) < IBAN_RE_MIN_LEN:
        return CHECKSUM_INAPPLICABLE
    if not candidate.isascii():
        # Go: any byte >= 0x80 hits the default branch. ISO 7064 is defined
        # over A-Z and 0-9 only, so no evidence exists either way and the shape
        # verdict must stand. FAIL CLOSED.
        return CHECKSUM_INAPPLICABLE
    rem = 0
    n = len(candidate)
    for i in range(n):
        c = candidate[(i + 4) % n]
        if "0" <= c <= "9":
            rem = (rem * 10 + (ord(c) - 48)) % 97
        elif "A" <= c <= "Z":
            rem = (rem * 100 + (ord(c) - 65) + 10) % 97
        elif "a" <= c <= "z":
            rem = (rem * 100 + (ord(c) - 97) + 10) % 97
        else:
            return CHECKSUM_INAPPLICABLE
    return CHECKSUM_PASSED if rem == 1 else CHECKSUM_FAILED


def contains_checksum_valid_iban(s: str) -> bool:
    """Mirror of containsChecksumValidIBAN.

    EVERY candidate is checked, not the first: a decoy IBAN-shaped run placed
    ahead of a real IBAN must not consume the verdict.  The loop resumes at the
    END OF THE CAPTURE rather than the end of the match, because the regex's
    boundaries are consuming (RE2 has no lookaround) and a shared separator
    would otherwise be eaten as one match's right anchor and be unavailable as
    the next one's left anchor.
    """
    if not IBAN_RE.search(s):
        return False
    pos = 0
    while pos < len(s):
        m = IBAN_RE.search(s, pos)
        if m is None:
            return False
        start, end = m.start(1), m.end(1)
        if iban_candidate_checksum(s[start:end]) != CHECKSUM_FAILED:
            return True
        pos = end
    return False


# ---------------------------------------------------------------------------
# Canonicalisation — canonicalizeForMatching + foldForMatching
# ---------------------------------------------------------------------------

# Go's invisible set is Cf | Mn | Me | Other_Default_Ignorable_Code_Point |
# Variation_Selector.  CPython exposes the first three via
# unicodedata.category(); the ranges below are the exact remainder, dumped from
# Go 1.26.2 (Unicode 15.0.0) and diffed codepoint-by-codepoint against
# CPython's Cf/Mn/Me.  U+FE00-FE0F and U+E0100-E01EF are already Mn and so are
# not repeated here.
#
# ⚑ These are the Hangul-filler class the guard's header calls out: U+115F,
# U+1160, U+3164 and U+FFA0 all render blank and all NFKC-fold to U+1160, but
# none of them is Cf/Mn/Me.  Omitting them reopens "49151<U+3164>12345678".
_EXTRA_INVISIBLE_RANGES = (
    (0x115F, 0x1160),
    (0x2065, 0x2065),
    (0x3164, 0x3164),
    (0xFFA0, 0xFFA0),
    (0xFFF0, 0xFFF8),
    (0x1171E, 0x1171E),
    (0xE0000, 0xE0000),
    (0xE0002, 0xE001F),
    (0xE0080, 0xE00FF),
    (0xE01F0, 0xE0FFF),
)


def _is_invisible_rune(ch: str) -> bool:
    if unicodedata.category(ch) in ("Cf", "Mn", "Me"):
        return True
    cp = ord(ch)
    for lo, hi in _EXTRA_INVISIBLE_RANGES:
        if lo <= cp <= hi:
            return True
    return False


def _fold_for_matching(s: str) -> str:
    out = []
    for ch in s:
        if ord(ch) < 0x80:
            out.append(ch)
            continue
        if _is_invisible_rune(ch):
            continue
        if unicodedata.category(ch) == "Nd":
            # NFKC does NOT fold Arabic-Indic / Extended Arabic-Indic /
            # Devanagari digits — they carry no compatibility decomposition
            # (SEC-003). unicodedata.decimal() is the direct equivalent of Go's
            # offset arithmetic over unicode.Nd, and was verified to agree on
            # every codepoint Go folds.
            try:
                out.append(str(unicodedata.decimal(ch)))
                continue
            except (TypeError, ValueError):  # pragma: no cover - Nd always decimal
                pass
        out.append(ch)
    return "".join(out)


def canonicalize_for_matching(s: str):
    """Return (canonical_form, changed).

    NOT done, deliberately: stripping spaces, hyphens or dots.  Those are
    VISIBLE separators and folding them would merge ordinary prose into digit
    runs.  U+00A0 NBSP is NFKC-mapped to an ordinary space and then treated as
    one, so a space-grouped IBAN is NOT detected — the guard's stated trade.
    """
    if s.isascii():
        return s, False
    normalized = unicodedata.normalize("NFKC", s)
    out = _fold_for_matching(normalized)
    if out == s:
        return s, False
    return out, True


# ---------------------------------------------------------------------------
# Scan contexts
# ---------------------------------------------------------------------------

CTX_IDENTIFIER = 0
CTX_PROSE = 1
CTX_VALUE = 2

_PROSE_KEYS = ("description", "title", "summary", "$comment")
_VALUE_KEYS = ("default", "const", "enum", "example", "examples")

_NAME_KEYED_SCHEMA_MAPS = frozenset(
    (
        "properties",
        "patternProperties",
        "$defs",
        "definitions",
        "dependentSchemas",
        "dependentRequired",
        # draft-07 `dependencies` is load-bearing: omitting it was a working
        # evasion of the digit-run matcher (external adversarial review, HIGH, 2026-08-03).
        "dependencies",
        "$vocabulary",
    )
)

_STRUCTURAL_NUMERIC_KEYWORDS = frozenset(
    (
        "minimum",
        "maximum",
        "exclusiveMinimum",
        "exclusiveMaximum",
        "multipleOf",
        "minLength",
        "maxLength",
        "minItems",
        "maxItems",
        "minProperties",
        "maxProperties",
        "minContains",
        "maxContains",
    )
)


def ctx_for_key(key: str, parent: int) -> int:
    # VALUE CONTEXT IS STICKY: once inside instance data, a key named
    # "description" is a developer-chosen field name, not schema documentation.
    if parent == CTX_VALUE:
        return CTX_VALUE
    if key in _PROSE_KEYS:
        return CTX_PROSE
    if key in _VALUE_KEYS:
        return CTX_VALUE
    return CTX_IDENTIFIER


def structural_keyword_applies_to(kw: str, decl) -> bool:
    present, malformed, names = decl
    if malformed:
        return False  # fail closed: a malformed type buys no exemption
    if not present or not names:
        return True  # undeclared type cannot contradict the keyword
    if kw in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"):
        return "number" in names or "integer" in names
    if kw in ("minLength", "maxLength"):
        return "string" in names
    if kw in ("minItems", "maxItems", "minContains", "maxContains"):
        return "array" in names
    if kw in ("minProperties", "maxProperties"):
        return "object" in names
    return True


def matcher_class(s: str, ctx: int) -> str:
    if not s:
        return ""
    if len(s) >= IBAN_RE_MIN_LEN and contains_checksum_valid_iban(s):
        return MATCHER_IBAN
    if "@" in s and EMAIL_RE.search(s):
        return MATCHER_EMAIL
    # Prose is exempt from the digit-run matcher (T-485, accepted 2026-08-04):
    # real MCP descriptions carry 13-digit millisecond epochs and sys_ids.
    if ctx == CTX_PROSE:
        return ""
    if len(s) >= TEN_DIGIT_RUN_RE_MIN_LEN and TEN_DIGIT_RUN_RE.search(s):
        return MATCHER_DIGIT_RUN
    return ""


def classify_one_string(s: str, ctx: int, allow_digit_run: bool) -> str:
    """Mirror of classifyOneString.

    The ONLY thing that may suppress a verdict here is the operator mode. No
    content-derived exemption belongs in this function — see the "THERE IS NO
    OPAQUE-ID EXEMPTION" warning in tool_schema_pii_guard.go for what happened
    the last time one did.
    """
    c = matcher_class(s, ctx)
    if c == MATCHER_DIGIT_RUN and not allow_digit_run:
        return ""
    return c


def scan_string(s: str, ctx: int, allow_digit_run: bool) -> str:
    c = classify_one_string(s, ctx, allow_digit_run)
    if c:
        return c
    canonical, changed = canonicalize_for_matching(s)
    if changed:
        return classify_one_string(canonical, ctx, allow_digit_run)
    return ""


# ---------------------------------------------------------------------------
# Exact decimal expansion — expandJSONNumber
#
# MATCH WHAT THE CONSUMER WILL SEE, not what the sender happened to type:
# `49151.12345678e8` has no ten-digit run as a literal, but sandbox-b decodes it
# to 4915112345678.0 and hands that to the provider SDK.
# ---------------------------------------------------------------------------

MAX_EXPANDED_NUMBER_DIGITS = 1024

EXPAND_OK = 0
EXPAND_TOO_LONG = 1
EXPAND_NOT_A_NUMBER = 2


def expand_json_number(lit: str):
    s = lit
    if s == "":
        return "", EXPAND_NOT_A_NUMBER
    if s[0] in "-+":
        s = s[1:]
    exp = 0
    i = -1
    for j, ch in enumerate(s):
        if ch in "eE":
            i = j
            break
    if i >= 0:
        try:
            exp = int(s[i + 1 :])
        except ValueError:
            return "", EXPAND_TOO_LONG
        s = s[:i]
    dot = s.find(".")
    if dot >= 0:
        int_part, frac_part = s[:dot], s[dot + 1 :]
    else:
        int_part, frac_part = s, ""
    digits = int_part + frac_part
    if digits == "":
        return "", EXPAND_NOT_A_NUMBER
    for ch in digits:
        if not ("0" <= ch <= "9"):
            return "", EXPAND_NOT_A_NUMBER

    # SEC-005: zero times any power of ten is zero, so 0e999999999 expands to
    # "0" and must not trip the clamp below.
    if digits.strip("0") == "":
        return "0", EXPAND_OK

    if (
        len(digits) > MAX_EXPANDED_NUMBER_DIGITS
        or exp > MAX_EXPANDED_NUMBER_DIGITS
        or exp < -2 * MAX_EXPANDED_NUMBER_DIGITS
    ):
        return "", EXPAND_TOO_LONG

    point = len(int_part) + exp
    if point > MAX_EXPANDED_NUMBER_DIGITS:
        return "", EXPAND_TOO_LONG
    if point < 0 and -point + len(digits) > MAX_EXPANDED_NUMBER_DIGITS:
        return "", EXPAND_TOO_LONG

    if point <= 0:
        whole = "0"
        frac = "0" * (-point) + digits
    elif point >= len(digits):
        whole = digits + "0" * (point - len(digits))
        frac = ""
    else:
        whole = digits[:point]
        frac = digits[point:]
    whole = whole.lstrip("0")
    if whole == "":
        whole = "0"
    frac = frac.rstrip("0")
    if frac == "":
        return whole, EXPAND_OK
    return whole + "." + frac, EXPAND_OK


def scan_number(lit: str, allow_digit_run: bool):
    """Return (matcher_class, overlong).  Mirror of toolSchemaScanNumber.

    ⚑ THE EARLY RETURN ON THE FIRST LINE IS WHY THE TWO MODES NEED TWO WALKS
    (see divergence 0 in the module header).  With the digit-run matcher ON, a
    literal carrying a 10+-digit run returns HERE and the expansion below is
    never attempted; with it OFF, the same literal falls through and may be
    reported as an over-long expansion, which is a fail-closed BOUNDS refusal
    in every refusing mode.  Same input, different finding CLASS, depending on
    a flag — so `refuse_high_confidence` cannot be computed by filtering the
    permissive walk's output.
    """
    c = classify_one_string(lit, CTX_VALUE, allow_digit_run)
    if c:
        return c, False
    expanded, status = expand_json_number(lit)
    if status == EXPAND_TOO_LONG:
        return "", True
    if status == EXPAND_OK and expanded != lit:
        return classify_one_string(expanded, CTX_VALUE, allow_digit_run), False
    return "", False


# ---------------------------------------------------------------------------
# A strict JSON parser
#
# Written rather than reached for because `json` cannot answer three questions
# this dry-run needs answered the way the gateway answers them:
#   - the SOURCE TEXT of every numeric literal (json.Number's whole point;
#     without it a 16-digit default comes back as a float and loses digits),
#   - which objects carried a DUPLICATE KEY (the decoded map cannot show one,
#     which is exactly why the gateway scans the raw token stream too), and
#   - a rejection of the non-standard spellings CPython accepts by default
#     (NaN / Infinity / -Infinity), which Go's encoding/json calls malformed.
#
# Bytes are decoded UTF-8 with errors="replace", matching Go's decoder, which
# substitutes U+FFFD for invalid UTF-8 rather than failing.
# ---------------------------------------------------------------------------

# The doctor's own parse-depth ceiling. Go's encoding/json refuses beyond 10000
# levels; anything past the guard's own maxToolSchemaDepth (32) is a bounds
# REFUSAL there anyway, so any nesting this rejects would have been refused by
# the gateway regardless — the verdict coincides, only the `kind` label differs.
# Kept far below CPython's recursion limit so a deep payload reports cleanly
# instead of raising.
MAX_PARSE_DEPTH = 400

_WS = " \t\n\r"
_ESCAPES = {'"': '"', "\\": "\\", "/": "/", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t"}
_NUMBER_RE = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")


class JSONParseError(Exception):
    pass


class _Parser:
    def __init__(self, text: str):
        self.t = text
        self.i = 0

    def ws(self):
        t, n = self.t, len(self.t)
        while self.i < n and t[self.i] in _WS:
            self.i += 1

    def parse_value(self, depth: int):
        if depth > MAX_PARSE_DEPTH:
            raise JSONParseError("nesting deeper than %d levels" % MAX_PARSE_DEPTH)
        self.ws()
        if self.i >= len(self.t):
            raise JSONParseError("unexpected end of input")
        c = self.t[self.i]
        if c == "{":
            return self.parse_object(depth)
        if c == "[":
            return self.parse_array(depth)
        if c == '"':
            return ("str", self.parse_string())
        if self.t.startswith("true", self.i):
            self.i += 4
            return ("bool", True)
        if self.t.startswith("false", self.i):
            self.i += 5
            return ("bool", False)
        if self.t.startswith("null", self.i):
            self.i += 4
            return ("null", None)
        m = _NUMBER_RE.match(self.t, self.i)
        if m is None or m.end() == self.i:
            raise JSONParseError("invalid JSON token")
        self.i = m.end()
        return ("num", m.group(0))

    def parse_object(self, depth: int):
        self.i += 1  # '{'
        pairs = []
        self.ws()
        if self.i < len(self.t) and self.t[self.i] == "}":
            self.i += 1
            return ("obj", pairs)
        while True:
            self.ws()
            if self.i >= len(self.t) or self.t[self.i] != '"':
                raise JSONParseError("object key must be a string")
            k = self.parse_string()
            self.ws()
            if self.i >= len(self.t) or self.t[self.i] != ":":
                raise JSONParseError("missing ':' after object key")
            self.i += 1
            pairs.append((k, self.parse_value(depth + 1)))
            self.ws()
            if self.i >= len(self.t):
                raise JSONParseError("unexpected end of input inside object")
            if self.t[self.i] == ",":
                self.i += 1
                continue
            if self.t[self.i] == "}":
                self.i += 1
                return ("obj", pairs)
            raise JSONParseError("expected ',' or '}' in object")

    def parse_array(self, depth: int):
        self.i += 1  # '['
        items = []
        self.ws()
        if self.i < len(self.t) and self.t[self.i] == "]":
            self.i += 1
            return ("arr", items)
        while True:
            items.append(self.parse_value(depth + 1))
            self.ws()
            if self.i >= len(self.t):
                raise JSONParseError("unexpected end of input inside array")
            if self.t[self.i] == ",":
                self.i += 1
                continue
            if self.t[self.i] == "]":
                self.i += 1
                return ("arr", items)
            raise JSONParseError("expected ',' or ']' in array")

    def parse_string(self) -> str:
        self.i += 1  # opening quote
        out = []
        t, n = self.t, len(self.t)
        while True:
            if self.i >= n:
                raise JSONParseError("unterminated string")
            c = t[self.i]
            if c == '"':
                self.i += 1
                return "".join(out)
            if c == "\\":
                self.i += 1
                if self.i >= n:
                    raise JSONParseError("unterminated escape")
                e = t[self.i]
                if e in _ESCAPES:
                    out.append(_ESCAPES[e])
                    self.i += 1
                    continue
                if e != "u":
                    raise JSONParseError("invalid escape sequence")
                cp = self._hex4()
                if 0xD800 <= cp <= 0xDBFF and t.startswith("\\u", self.i):
                    save = self.i
                    self.i += 1  # step onto 'u' for _hex4's own +1
                    low = self._hex4()
                    if 0xDC00 <= low <= 0xDFFF:
                        out.append(chr(0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)))
                        continue
                    self.i = save
                if 0xD800 <= cp <= 0xDFFF:
                    # Go substitutes U+FFFD for an unpaired surrogate.
                    out.append("�")
                else:
                    out.append(chr(cp))
                continue
            if ord(c) < 0x20:
                raise JSONParseError("unescaped control character in string")
            out.append(c)
            self.i += 1

    def _hex4(self) -> int:
        # self.i is on 'u'; consume it plus four hex digits.
        h = self.t[self.i + 1 : self.i + 5]
        if len(h) != 4:
            raise JSONParseError("truncated \\u escape")
        try:
            cp = int(h, 16)
        except ValueError:
            raise JSONParseError("invalid \\u escape") from None
        self.i += 5
        return cp


def parse_json(text: str):
    """Parse exactly one value; return (node, trailing_text)."""
    p = _Parser(text)
    node = p.parse_value(0)
    p.ws()
    return node, text[p.i :]


def as_map(node):
    """Decoded object view: LAST occurrence of a duplicated key wins, matching
    encoding/json's map[string]any decode."""
    return dict(node[1])


# ---------------------------------------------------------------------------
# Type declaration — schemaTypeDecl / parseTypeKeyword / composition inference
#
# ABSENT AND MALFORMED MUST NOT SHARE A REPRESENTATION. Absent GRANTS the
# structural exemption; malformed must REFUSE it. Collapsing the two was itself
# a bypass, three times over.
# ---------------------------------------------------------------------------

# decl = (present, malformed, names:set)
_DECL_ABSENT = (False, False, frozenset())
_DECL_MALFORMED = (True, True, frozenset())

MAX_COMPOSITION_INFERENCE_DEPTH = 4
_COMPOSITION_KEYWORDS = ("allOf", "anyOf", "oneOf")


def parse_type_keyword(node):
    kind = node[0]
    if kind == "str":
        return (True, False, frozenset((node[1],)))
    if kind == "arr":
        items = node[1]
        if not items:
            return _DECL_MALFORMED  # `type: []` — the spec requires >= 1 entry
        names = set()
        for it in items:
            if it[0] != "str":
                # One non-string member poisons the whole declaration rather
                # than being skipped: skipping is what let `type:[7]` read as
                # undeclared.
                return _DECL_MALFORMED
            names.add(it[1])
        return (True, False, frozenset(names))
    # null / number / bool / object
    return _DECL_MALFORMED


def has_unread_composition(m) -> bool:
    """Same readability criterion as the collector, or the same node gets
    opposite verdicts on either side of the depth horizon.  A boolean-only
    composition declares nothing and contains nothing, so there is nothing to
    truncate; a malformed keyword IS unread and fails closed."""
    for kw in _COMPOSITION_KEYWORDS:
        raw = m.get(kw)
        if raw is None:
            continue
        if raw[0] != "arr" or not raw[1]:
            return True  # malformed — unreadable, so fail closed
        for b in raw[1]:
            if b[0] != "bool":
                return True  # a real branch we are declining to descend into
    return False


def collect_composition_types(m, depth: int, out: list) -> None:
    if out[0][1]:  # already malformed
        return
    if depth > MAX_COMPOSITION_INFERENCE_DEPTH:
        if has_unread_composition(m):
            # T-495: the walk is stopping with composition unread, so it does
            # not know the declared type. Not knowing must never read as "no
            # type declared" — that is the state that grants the exemption.
            out[0] = _DECL_MALFORMED
        return
    for kw in _COMPOSITION_KEYWORDS:
        raw = m.get(kw)
        if raw is None:
            continue
        if raw[0] != "arr" or not raw[1]:
            # Same class as T-495: `allOf:"x"` / `{}` / `[]` are not schemas an
            # SDK emits, and each read as "no composition here" => UNDECLARED
            # => exemption granted for free.
            out[0] = _DECL_MALFORMED
            return
        for b in raw[1]:
            if b[0] == "bool":
                # `true`/`false` ARE schemas (2019-09, 2020-12) that declare
                # nothing. A legal branch contributing nothing is not ignorance.
                continue
            if b[0] != "obj":
                out[0] = _DECL_MALFORMED
                return
            bm = as_map(b)
            if "type" in bm:
                d = parse_type_keyword(bm["type"])
                if d[1]:
                    out[0] = _DECL_MALFORMED
                    return
                present, malformed, names = out[0]
                out[0] = (True, malformed, frozenset(names) | d[2])
            collect_composition_types(bm, depth + 1, out)
            if out[0][1]:
                return


def declared_schema_types(m):
    if "type" in m:
        return parse_type_keyword(m["type"])
    out = [_DECL_ABSENT]
    collect_composition_types(m, 0, out)
    return out[0]


# ---------------------------------------------------------------------------
# Pointer rendering — PII-safe by construction
# ---------------------------------------------------------------------------

POINTER_ROOT = "/tools"
MAX_LOGGED_POINTER_LEN = 512

_POINTER_KEYWORDS = frozenset(
    (
        "tools", "name", "description", "title", "summary",
        "input_schema", "inputSchema", "function", "parameters",
        "properties", "patternProperties", "additionalProperties",
        "propertyNames", "items", "prefixItems", "additionalItems",
        "contains", "enum", "default", "const", "example",
        "examples", "type", "required", "format", "pattern",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
        "multipleOf", "minLength", "maxLength", "minItems",
        "maxItems", "uniqueItems", "minProperties", "maxProperties",
        "anyOf", "oneOf", "allOf", "not", "if", "then",
        "else", "$schema", "$ref", "$id", "$defs",
        "$comment", "definitions", "cache_control", "strict",
        "type_", "input", "deprecated", "readOnly", "writeOnly",
    )
)


def escape_pointer_segment(s: str) -> str:
    # Order matters: "~" before "/", or the "~1" produced for a slash is
    # re-escaped into "~01".
    return s.replace("~", "~0").replace("/", "~1")


def fingerprint_segment(s: str) -> str:
    return "<k:%s>" % hashlib.sha256(s.encode("utf-8")).hexdigest()[:8]


def render_pointer(path, redactions=frozenset()) -> str:
    """The caller-facing pointer: the caller's OWN schema path, returned to the
    caller that sent it, which is what makes a refusal actionable.

    `redactions` is the set of key segments that THEMSELVES matched a matcher
    anywhere in this run.  The gateway has no equivalent because it stops at
    the first finding; enumerating every finding means a key fingerprinted in
    one line could otherwise be spelled out in the next one's path, which would
    undo the fingerprint. See divergence 4 in the module header.
    """
    out = [POINTER_ROOT]
    for text, is_key in path:
        out.append("/")
        if is_key and text in redactions:
            out.append(fingerprint_segment(text))
        else:
            out.append(escape_pointer_segment(text) if is_key else text)
    return "".join(out)


def render_log_pointer(path) -> str:
    out = [POINTER_ROOT]
    for text, is_key in path:
        out.append("/")
        if not is_key:
            out.append(text)  # array index, or an already-fingerprinted segment
        elif text in _POINTER_KEYWORDS:
            out.append(text)  # fixed schema vocabulary — carries no client data
        else:
            out.append(fingerprint_segment(text))
    s = "".join(out)
    if len(s) > MAX_LOGGED_POINTER_LEN:
        return s[:MAX_LOGGED_POINTER_LEN] + "...(truncated)"
    return s


# ---------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------

MAX_TOOL_SCHEMA_DEPTH = 32
MAX_TOOL_SCHEMA_NODES = 200000

KIND_PII = "pii_shape"
KIND_MALFORMED = "malformed_tools"
KIND_BOUNDS = "bounds_exceeded"


class _Terminal(Exception):
    """A malformed or bounds finding — the walk cannot continue past it."""


def make_finding(kind, matcher, detail, path, hint=""):
    """One finding.  The PATH is kept, not a rendered pointer: the caller-facing
    rendering depends on which keys turned out to be PII-shaped ANYWHERE in the
    run, which is not known until every walk has finished."""
    return {
        "kind": kind,
        "matcher": matcher,
        "detail": detail,
        "hint": hint,
        "path": list(path),
        "log_pointer": render_log_pointer(path),
    }


def finding_identity(f):
    """Findings from the two walks are the same finding when they say the same
    thing about the same node."""
    return (f["kind"], f["matcher"], f["detail"], f["log_pointer"])


class Walker:
    """One walk of the declaration tree.

    allow_digit_run carries the scan POLICY, not the operator mode: when False
    the low-confidence 10+-digit-run matcher is disabled for the whole walk.
    The gateway uses that to re-walk a declaration under
    refuse_high_confidence, and this script runs the same two walks so each
    mode's verdict comes from the walk that actually decides it.
    """

    def __init__(self, allow_digit_run=True):
        self.allow_digit_run = allow_digit_run
        self.nodes = 0
        self.path = []
        self.findings = []
        # Keys that themselves matched a matcher. Fed into the caller-facing
        # pointer renderer so a key fingerprinted by one finding is not spelled
        # out by another finding's path.
        self.pii_keys = set()

    def _terminal(self, kind, detail):
        self.findings.append(make_finding(kind, "", detail, self.path))
        raise _Terminal()

    def _key_hit(self, key, matcher):
        # The offending value IS the key, so the pointer's last segment is
        # fingerprinted in BOTH renderings — the report never echoes it back.
        # is_key=False is deliberate: the segment is ALREADY a fingerprint, so
        # neither renderer should escape or re-fingerprint it.
        self.pii_keys.add(key)
        path = self.path + [(fingerprint_segment(key), False)]
        self.findings.append(make_finding(KIND_PII, matcher, "object key", path))

    def walk(self, node, depth, scan, keys_are_names, scan_numbers):
        self.nodes += 1
        if self.nodes > MAX_TOOL_SCHEMA_NODES:
            self._terminal(KIND_BOUNDS, "more than %d nodes" % MAX_TOOL_SCHEMA_NODES)
        if depth > MAX_TOOL_SCHEMA_DEPTH:
            self._terminal(KIND_BOUNDS, "nesting deeper than %d levels" % MAX_TOOL_SCHEMA_DEPTH)

        kind = node[0]
        if kind == "obj":
            m = as_map(node)
            # Deterministic ordering. Python sorts by code point and Go's
            # sort.Strings sorts by UTF-8 byte; UTF-8 preserves code-point
            # order, so the two agree.
            keys = sorted(m.keys())
            declared_types = None
            for k in keys:
                # The KEY itself is a parameter/property name — an identifier.
                # Unchanged by keys_are_names: a property called
                # patient_1234567890 is a hit wherever it appears.
                mc = scan_string(k, CTX_IDENTIFIER, self.allow_digit_run)
                if mc:
                    self._key_hit(k, mc)

                if keys_are_names:
                    # k is an arbitrary NAME, not a keyword. Inherit scan
                    # unchanged so value stickiness holds when a properties map
                    # turns up inside instance data. A name-keyed map's values
                    # are never structural bounds, so numbers under them are data.
                    child = (scan, False, True)
                else:
                    s = ctx_for_key(k, scan)
                    # Inside instance data every key is data, so no keyword —
                    # including `properties` or `maximum` — keeps schema meaning.
                    in_schema = scan != CTX_VALUE
                    child_scan_numbers = True
                    if in_schema and k in _STRUCTURAL_NUMERIC_KEYWORDS:
                        if declared_types is None:
                            declared_types = declared_schema_types(m)
                        if structural_keyword_applies_to(k, declared_types):
                            child_scan_numbers = False
                    child = (s, in_schema and k in _NAME_KEYED_SCHEMA_MAPS, child_scan_numbers)

                self.path.append((k, True))
                try:
                    self.walk(m[k], depth + 1, *child)
                finally:
                    self.path.pop()

        elif kind == "arr":
            for i, elem in enumerate(node[1]):
                # Array elements inherit the enclosing key's context. keys_are_names
                # does NOT propagate through an array — no JSON-Schema keyword
                # introduces an array of name-keyed maps.
                self.path.append((str(i), False))
                try:
                    self.walk(elem, depth + 1, scan, False, scan_numbers)
                finally:
                    self.path.pop()

        elif kind == "str":
            mc = scan_string(node[1], scan, self.allow_digit_run)
            if mc:
                self.findings.append(make_finding(KIND_PII, mc, "string value", self.path))

        elif kind == "num":
            # SEC-004: scanned everywhere the POSITION says this number is data,
            # not only in value context. The literal source text is preserved,
            # so a 13-digit MSISDN is seen as written rather than via a lossy
            # float round-trip — and the literal alone is not enough, because
            # the downstream consumer materialises the decimal expansion.
            if scan_numbers:
                mc, overlong = scan_number(node[1], self.allow_digit_run)
                if overlong:
                    self._terminal(
                        KIND_BOUNDS,
                        "numeric literal expanding beyond %d digits" % MAX_EXPANDED_NUMBER_DIGITS,
                    )
                if mc:
                    self.findings.append(make_finding(KIND_PII, mc, "numeric value", self.path))
        # bool / null carry no PII shape.


def detect_duplicate_keys(node, path, out, pii_keys):
    """PARSER-DIFFERENTIAL GUARD.  The bytes forwarded are the original raw
    payload, but what is SCANNED is the decoded value, and a decoder that keeps
    the last occurrence of a duplicated key hides whatever the earlier ones
    said from every matcher.  Duplicate keys never appear in a tool schema
    emitted by a real client, so rejecting them costs nothing."""
    kind = node[0]
    if kind == "obj":
        seen = set()
        for k, v in node[1]:
            child = path + [(k, True)]
            if k in seen:
                # The duplicated key may itself be PII-shaped; record it so the
                # caller-facing rendering fingerprints it like any other key hit.
                if scan_string(k, CTX_IDENTIFIER, True):
                    pii_keys.add(k)
                out.append(
                    make_finding(
                        KIND_MALFORMED, "", "duplicate object key in a tool declaration", child
                    )
                )
                return True
            seen.add(k)
            if detect_duplicate_keys(v, child, out, pii_keys):
                return True
    elif kind == "arr":
        for i, elem in enumerate(node[1]):
            if detect_duplicate_keys(elem, path + [(str(i), False)], out, pii_keys):
                return True
    return False


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

MODE_REFUSE = "refuse"
MODE_LOG = "log"
MODE_REFUSE_HIGH_CONFIDENCE = "refuse_high_confidence"
VALID_MODES = (MODE_LOG, MODE_REFUSE, MODE_REFUSE_HIGH_CONFIDENCE)


def scan_payload(tools):
    """Run BOTH gateway walks over the tools array.

    Returns (permissive_findings, strict_findings, pii_keys).

    ⚑ The pre-walk stages — undecodable array, trailing content, duplicate
    object key — sit above the policy flag in the gateway
    (scanDeclaredToolSchemasWithPolicy runs them before it builds a walker), so
    they belong to BOTH results.  The caller adds them.

    ⚑ `refuse_high_confidence` relaxes ONE MATCHER, not the posture: every
    fail-closed malformed/bounds finding still refuses in that mode, because a
    declaration the guard could not finish reading is one it cannot clear.
    That is why the strict walk keeps its bounds checks — and why running it,
    rather than filtering the permissive result, is the only faithful model
    (see divergence 0 in the module header).
    """
    permissive = Walker(allow_digit_run=True)
    try:
        permissive.walk(tools, 0, CTX_IDENTIFIER, False, True)
    except _Terminal:
        pass
    strict = Walker(allow_digit_run=False)
    try:
        strict.walk(tools, 0, CTX_IDENTIFIER, False, True)
    except _Terminal:
        pass
    return permissive.findings, strict.findings, permissive.pii_keys | strict.pii_keys


def refusing_modes(finding, permissive_ids, strict_ids):
    """Which modes reject a request BECAUSE OF this finding.

    Derived from which WALK produced it, never from a predicate over its
    matcher class — the two are not the same question (divergence 0).
    """
    ident = finding_identity(finding)
    modes = []
    if ident in permissive_ids:
        modes.append(MODE_REFUSE)
    if ident in strict_ids:
        modes.append(MODE_REFUSE_HIGH_CONFIDENCE)
    return modes


# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------


def extract_tools(root):
    """Locate the tools value.  Returns (node, provenance) or (None, reason).

    Accepted shapes, in order:
      1. a bare JSON array — the `tools` value exactly as the client sends it,
         which is what the gateway guards;
      2. {"tools": [...]}          — an Anthropic / OpenAI request body;
      3. {"result": {"tools": []}} — an MCP `tools/list` JSON-RPC response.

    ⚑ THE FALL-THROUGH IS A GUARD VERDICT, NOT AN OPERATOR ERROR, and the
    distinction is the whole point of this function's shape.

    A payload that is neither an array nor a recognised wrapper — a bare JSON
    object, a string, a number, a boolean — is still a perfectly good answer to
    the question this tool asks, because those bytes ARE the tools value and
    the gateway's own verdict on them is known: `json.Decode` into `[]any`
    fails, so it reports `malformed_tools` and REFUSES (fail-closed,
    mode-governed; tool_schema_pii_guard.go:1826-1837).  Reporting that as "I
    could not find a tools array" would answer a different question and, worse,
    would exit as an input error rather than as the refusal it predicts.  So
    those shapes are returned AS the tools value and fall into the caller's
    existing non-array branch, which produces exactly the gateway's finding.

    What stays a genuine operator error is the one case where the payload
    announces a shape and then does not carry it: a `result` OBJECT with no
    `tools` member inside it.  There the operator plainly meant the MCP
    response shape, and the honest answer is "that response contains no tools
    array", not a refusal for a payload the gateway would never see.
    """
    # scanDeclaredToolSchemasWithPolicy returns nil for "", "null" and "[]"
    # BEFORE it decodes anything: a request that declares no tools has nothing
    # for the guard to clear or refuse. A `"tools": null` member is the ordinary
    # spelling of that in a real request body, so it must not read as malformed.
    no_tools = ("arr", [])
    if root[0] == "null":
        return no_tools, "explicit null (no tools declared)"
    if root[0] == "arr":
        return root, "top-level array"
    if root[0] == "obj":
        m = as_map(root)
        if "tools" in m:
            t = m["tools"]
            return (no_tools if t[0] == "null" else t), '"tools" member'
        if "result" in m and m["result"][0] == "obj":
            rm = as_map(m["result"])
            if "tools" in rm:
                t = rm["tools"]
                return (no_tools if t[0] == "null" else t), 'MCP "result.tools" member'
            return None, (
                'the payload has a "result" object but no "tools" member inside it, '
                "so it carries no tool declarations to check — supply an MCP "
                "tools/list response that actually lists tools"
            )
    return root, (
        'payload itself, read as the tools value — it is not an array and carries no "tools" member'
    )


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="lucairn-tool-schema-guard.py",
        description="Offline dry-run of the gateway tool-schema PII guard (T-498).",
    )
    ap.add_argument("--tools-file", required=True, help='path to the tools payload, or "-" for stdin')
    ap.add_argument("--mode", default=MODE_REFUSE, help="log | refuse | refuse_high_confidence")
    ap.add_argument(
        "--reveal-pointers",
        action="store_true",
        help="print caller-facing pointers (contain your own property names) instead of skeletons",
    )
    args = ap.parse_args(argv)

    try:
        sys.stdout.reconfigure(errors="backslashreplace")
    except (AttributeError, ValueError):  # pragma: no cover - 3.6 and earlier
        pass

    mode = args.mode if args.mode in VALID_MODES else MODE_REFUSE

    if args.tools_file == "-":
        raw = sys.stdin.buffer.read()
        source = "stdin"
    else:
        try:
            with open(args.tools_file, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            print("tools payload: failed (%s)" % exc, file=sys.stderr)
            return 2
        source = args.tools_file

    # Go's decoder substitutes U+FFFD for invalid UTF-8 rather than failing.
    text = raw.decode("utf-8", errors="replace")

    # `pre` holds the findings the gateway produces ABOVE the policy flag —
    # undecodable array, trailing content, duplicate object key. They belong to
    # BOTH walks, so they are prepended to both result sets.
    pre = []
    pii_keys = set()
    tool_count = None
    provenance = ""

    if text.strip() == "":
        print("tools payload: failed (%s is empty)" % source, file=sys.stderr)
        return 2

    def root_finding(detail, hint=""):
        # `detail` is the gateway's own string, verbatim; anything this script
        # can add goes in `hint` so grep parity on detail= is preserved.
        return make_finding(KIND_MALFORMED, "", detail, [], hint)

    try:
        root, trailing = parse_json(text)
    except JSONParseError as exc:
        # The gateway reports exactly this for a tools value it cannot decode,
        # and it is fail-CLOSED: mode-governed, never a silent pass.
        pre.append(
            root_finding("not a decodable JSON array of tool declarations", "parser: %s" % exc)
        )
        root = None
        trailing = ""

    # Walk results, empty until the pre-walk stages clear. The gateway returns
    # an undecodable/trailing/duplicate-key finding BEFORE it builds a walker,
    # so a payload that trips one of those is never walked at all.
    walked_permissive, walked_strict = [], []

    if root is not None:
        tools, provenance = extract_tools(root)
        if tools is None:
            print("tools payload: failed (%s)" % provenance, file=sys.stderr)
            return 2
        if tools[0] != "arr":
            # A tools value the gateway cannot decode as an array is a
            # fail-CLOSED guard finding, not an input error — it refuses in
            # every refusing mode. The hint names WHICH bytes were read as the
            # tools value, because that is the part an operator has to act on.
            pre.append(
                root_finding(
                    "not a decodable JSON array of tool declarations",
                    "read from the %s" % provenance,
                )
            )
        elif trailing.strip() != "" and root is tools:
            # json.Unmarshal rejects trailing content; a streaming decoder does
            # not. `[{...}]{"smuggled":"…"}` would decode cleanly here while the
            # upstream provider's parser might read it differently.
            tool_count = len(tools[1])
            pre.append(root_finding("trailing content after the tools array"))
        elif trailing.strip() != "":
            # A wrapper shape (request body / MCP response) with junk after it is
            # not a tools payload the gateway would ever see — an input error,
            # not a guard finding.
            print(
                "tools payload: failed (trailing content after the top-level value in %s)" % source,
                file=sys.stderr,
            )
            return 2
        else:
            tool_count = len(tools[1])
            if not detect_duplicate_keys(tools, [], pre, pii_keys):
                walked_permissive, walked_strict, walk_keys = scan_payload(tools)
                pii_keys |= walk_keys

    permissive = pre + walked_permissive
    strict = pre + walked_strict

    # ---- report -----------------------------------------------------------
    if tool_count is not None:
        print("tools payload: ok (%s, %d tool declaration(s), from the %s)" % (source, tool_count, provenance))
    else:
        print("tools payload: read (%s) — the guard could not decode it; see the finding below" % source)
    print("tool-schema guard mode: %s" % mode)

    permissive_ids = {finding_identity(f) for f in permissive}
    strict_ids = {finding_identity(f) for f in strict}

    # Report the permissive walk's findings (the operator's fix list), then any
    # finding only the strict walk reaches. The latter is a small but real class
    # — a numeric literal whose digit-run hit hides an over-long expansion — and
    # omitting it is exactly how a dry-run comes to say CLEAN where the gateway
    # 400s under refuse_high_confidence.
    ordered = list(permissive)
    for f in strict:
        if finding_identity(f) not in permissive_ids:
            ordered.append(f)

    for idx, f in enumerate(ordered, start=1):
        where = (
            render_pointer(f["path"], pii_keys) if args.reveal_pointers else f["log_pointer"]
        )
        modes = refusing_modes(f, permissive_ids, strict_ids)
        note = ""
        if finding_identity(f) not in permissive_ids:
            note = " [surfaced only with the digit-run matcher off]"
        print(
            "tool-schema guard: finding %d: kind=%s matcher=%s detail=%s at %s — refused under: %s%s%s"
            % (
                idx,
                f["kind"],
                f["matcher"] or "-",
                f["detail"],
                where,
                ", ".join(modes) if modes else "(none — observed and forwarded in every mode)",
                note,
                (" (%s)" % f["hint"]) if f["hint"] else "",
            )
        )

    print(
        "tool-schema guard: %d finding(s); %d would 400 under `refuse`, %d under "
        "`refuse_high_confidence`, 0 under `log`" % (len(ordered), len(permissive), len(strict))
    )
    if ordered and not args.reveal_pointers:
        print(
            "tool-schema guard: locations are pointer SKELETONS (client-authored key segments "
            "fingerprinted, matched values never printed). Re-run with --reveal-pointers for the "
            "caller-facing pointers; that output names your own schema properties, so keep it local."
        )

    # Each mode's verdict comes from ITS OWN walk, never from filtering the
    # other one's output — see divergence 0 in the module header.
    if mode == MODE_LOG:
        would_refuse = False
    elif mode == MODE_REFUSE:
        would_refuse = bool(permissive)
    else:
        would_refuse = bool(strict)
    if would_refuse:
        print(
            "tool-schema guard: FAIL (mode `%s` would reject this tools payload with HTTP 400 "
            "on the FIRST routed turn)" % mode
        )
        print(
            "tool-schema guard: fix the offending declarations, or set "
            "GATEWAY_TOOL_SCHEMA_GUARD / gateway.toolSchemaGuard to `log` for a BOUNDED "
            "observation window (see OPS.md § \"Tool-schema PII guard\")"
        )
        return 1

    if ordered:
        print("tool-schema guard: ok (mode `%s` would forward this tools payload; findings above are observations)" % mode)
    else:
        print("tool-schema guard: ok (mode `%s` would forward this tools payload)" % mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
