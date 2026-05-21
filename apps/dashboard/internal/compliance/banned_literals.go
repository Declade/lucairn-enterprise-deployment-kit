// Package compliance renders Lucairn's AI-Act compliance PDF export
// surface and its supporting machinery (date-window aggregation,
// render-time banned-literal guard, cover-page composer).
//
// banned_literals.go is the load-bearing fail-closed enforcement layer.
// EVERY text-render path inside pdf.go calls Assert(text) BEFORE writing
// to the PDF. On detection Assert returns a non-nil error; the caller
// returns a 500 to the operator and NO PDF bytes are written. This
// mirrors Slice 6's reveal-raw + csv_export_with_reveal fail-closed
// invariance: if a banned-literal claim would land in the customer's
// compliance evidence, the dashboard refuses to produce the artefact
// rather than tolerate the false claim.
//
// The corpus is sourced VERBATIM from the project's locked
// "Mechanism allowlist — forbidden in legal copy" set documented in
// the project root CLAUDE.md; any change to this corpus MUST originate
// there first. The literals themselves live as base64-encoded fragments
// below so the source file does NOT contain the verbatim banned strings
// (otherwise the project-wide grep guard would flag this file). Same
// pattern as apps/dashboard/internal/views/views_test.go's
// banned-literal regex builder.
//
// Match semantics:
//   - Case-insensitive (`HIPAA` and `hipaa` and `Hipaa` all match)
//   - Substring with word-boundary awareness for tokens that have
//     common false-positive risk (e.g. "ISO 27001" must NOT match
//     "ISO 9001" or "ISO 270010" — anchored to the exact phrase)
//   - Allowlist exception for "encrypted at rest" applies ONLY to
//     OPS-doc operational claims about K8s Secret encryption-at-rest
//     infra. The PDF render never opts into the exception — fail-closed
//     for customer-facing PDF copy is the right default; if a future
//     section of the PDF needs an infra-level encryption-at-rest claim
//     it ships with explicit scoping copy + a follow-up PR adjusting
//     the exception rules here.
package compliance

import (
	"encoding/base64"
	"fmt"
	"regexp"
	"strings"
)

// bannedLiteralPattern is the compiled regex matching every banned
// literal from CLAUDE.md § "Mechanism allowlist". Built from
// base64-encoded fragments so this file itself contains no banned
// strings.
//
// Word-boundary semantics: most entries wrap with `\b...\b` so
// "ISO 27001" doesn't match the substring inside "ISO 270010" or
// "ISOTONIC 27001x". A small set of entries (regex fragments that
// include their own anchors, like the TLS character class) opt out
// of the auto-wrap; see boundedAlternatives + rawAlternatives.
var bannedLiteralPattern = buildBannedLiteralPattern()

// buildBannedLiteralPattern decodes the base64 corpus + assembles a
// single case-insensitive regex. Each alternative is wrapped with
// `(?:^|[^A-Za-z0-9])` left and `(?:$|[^A-Za-z0-9])` right boundary
// anchors so substring false-matches like "ISO 270010" don't trip
// the "ISO 27001" entry. We use a manual boundary expression rather
// than `\b` because `\b` treats `%` and `.` as word-boundary
// transitions, which mis-classifies entries like "99.9%" (where the
// literal ends at `%`, a non-word char — meaning `\b` would already
// be satisfied without an explicit transition character).
//
// Entries listed in rawAlternatives skip the boundary wrap because
// they contain their own internal anchoring or character classes
// (the TLS regex fragment is already shape-anchored).
func buildBannedLiteralPattern() *regexp.Regexp {
	// Decoded list (for reviewers): the banned literals from CLAUDE.md
	// § "Locked decisions" → "Mechanism allowlist — forbidden in legal
	// copy". Decode any entry with `echo <value> | base64 -d`. The list
	// MUST stay in sync with the global guard at
	// apps/dashboard/internal/views/views_test.go::buildBannedLiteralPattern
	// — those 11 phrases plus the additional retired-brand + retired-
	// tier-name surface area Slice 7 must also guard against.
	boundedEncoded := []string{
		// SOC 2
		"U09DIDI=",
		// ISO 27001
		"SVNPIDI3MDAx",
		// ISO 27701
		"SVNPIDI3NzAx",
		// ISO 42001
		"SVNPIDQyMDAx",
		// HIPAA
		"SElQQUE=",
		// PCI-DSS
		"UENJLURTUw==",
		// PCI DSS (space variant)
		"UENJIERTUw==",
		// encrypted at rest
		"ZW5jcnlwdGVkIGF0IHJlc3Q=",
		// penetration test
		"cGVuZXRyYXRpb24gdGVzdA==",
		// pen test
		"cGVuIHRlc3Q=",
		// red team
		"cmVkIHRlYW0=",
		// MFA
		"TUZB",
		// multi-factor authentication
		"bXVsdGktZmFjdG9yIGF1dGhlbnRpY2F0aW9u",
		// end-to-end encryption
		"ZW5kLXRvLWVuZCBlbmNyeXB0aW9u",
		// E2E encryption
		"RTJFIGVuY3J5cHRpb24=",
		// regular audits
		"cmVndWxhciBhdWRpdHM=",
		// Pro+
		"UHJvXCs=",
		// pro_plus
		"cHJvX3BsdXM=",
		// Solo Free (retired tier name)
		"U29sbyBGcmVl",
		// Solo Pro (retired tier name)
		"U29sbyBQcm8=",
		// The Veil (retired brand)
		"VGhlIFZlaWw=",
		// theveil
		"dGhldmVpbA==",
		// dsaveil (retired domain)
		"ZHNhdmVpbA==",
	}

	// rawEncoded entries are emitted into the alternation WITHOUT the
	// boundary wrap. Used for fragments that include their own anchors
	// or non-alphanumeric trailing characters (e.g. "99.9%") where the
	// boundary char-class would refuse to match because the % is
	// already a non-alphanumeric.
	rawEncoded := []string{
		// TLS 1.2 / TLS 1.3 (regex fragment with character class)
		"VExTIDFcLlsyM10=",
		// 99.9%
		"OTlcLjkl",
		// 99.99%
		"OTlcLjk5JQ==",
	}

	const leftBoundary = "(?:^|[^A-Za-z0-9])"
	const rightBoundary = "(?:$|[^A-Za-z0-9])"

	parts := make([]string, 0, len(boundedEncoded)+len(rawEncoded))
	for _, e := range boundedEncoded {
		decoded, err := base64.StdEncoding.DecodeString(e)
		if err != nil {
			panic("compliance: invalid banned-literal fixture: " + err.Error())
		}
		parts = append(parts, leftBoundary+string(decoded)+rightBoundary)
	}
	for _, e := range rawEncoded {
		decoded, err := base64.StdEncoding.DecodeString(e)
		if err != nil {
			panic("compliance: invalid banned-literal raw fixture: " + err.Error())
		}
		parts = append(parts, string(decoded))
	}

	expr := "(?i)(" + strings.Join(parts, "|") + ")"
	return regexp.MustCompile(expr)
}

// Assert returns nil when text contains zero banned literals; otherwise
// returns an error with the offending literal + its position in the
// input. Position is reported as a byte offset, NOT a rune offset —
// the caller is the PDF renderer which is itself byte-oriented (fpdf
// emits Latin-1-encoded PDF text strings).
//
// Empty input returns nil (a no-op write produces no banned text).
//
// The exposed contract: ALL caller paths inside pdf.go MUST treat a
// non-nil return as a fail-closed signal — return the error up the
// stack so the handler can 500 the operator. NEVER swallow the error
// "best-effort". The compliance PDF's value is that customer counsel
// can quote from it directly; a single banned-literal slip would
// undermine the whole artefact.
func Assert(text string) error {
	if text == "" {
		return nil
	}
	loc := bannedLiteralPattern.FindStringIndex(text)
	if loc == nil {
		return nil
	}
	return fmt.Errorf("compliance: banned literal detected at byte offset %d: %q", loc[0], text[loc[0]:loc[1]])
}

// AssertSection returns nil when text is banned-literal-free; otherwise
// wraps the underlying Assert error with the named section so the
// handler-level log line can pinpoint which section of the PDF the
// fail-closed origin lives in. Used by pdf.go's per-section renderers.
func AssertSection(section, text string) error {
	if err := Assert(text); err != nil {
		return fmt.Errorf("compliance pdf: section %q: %w", section, err)
	}
	return nil
}
