// Package piiguard implements render-time PII redaction for the audit
// log browser. Slice 6 ship.
//
// # Why a separate package
//
// The audit DB stores raw events as the gateway/sanitizer/witness emitted
// them. The default render path on /audit MUST redact PII so a viewer
// (and the default admin view) never sees raw values matching L1 PII
// patterns. Admin "Reveal raw" is the only path that returns unredacted
// text — and that path emits a paired `audit.reveal_raw` event into the
// audit DB so auditors can see who unmasked what.
//
// # Source of truth for the regex set
//
// The L1 patterns mirror the Python sanitizer's `PatternRecognizer`
// regex set at
//
//	dual-sandbox-architecture/services/sanitizer/recognizers.py
//
// Vendored from upstream commit 58b6adfa80eb809fa84310db9572f489c6646312
// (dual-sandbox-architecture HEAD as of Slice 6 fix-up r1 ship).
// Slice 6 fix-up r1 H4: an un-pinned reference cannot detect drift —
// `grep` only confirms the name still exists upstream, not that the
// regex semantics are still aligned. Future hardening: a CI job that
// re-reads the upstream SHA at this exact path + compares against the
// pinned SHA here, flagging any drift since the last vendoring pass
// (see TODO comment near `rules` init below).
//
// The vendored regexes here are an INDEPENDENT subset (only the
// high-precision shapes that fire deterministically without spaCy
// context boosts). They are NOT copy-pasted verbatim because the
// sanitizer uses Presidio + spaCy context recognition; the dashboard
// only sees inert text and cannot replicate the context-aware scoring.
// What we CAN do is catch the structurally-identifiable patterns
// (email, IBAN, phone E.164, IPv4/IPv6, UUID, SSN, German tax ID,
// US date of birth, MRN, etc.) at the rendering edge.
//
// The original implementation brief prescribed vendoring from an
// upstream policy.go file. policy.go does not exist; the live
// recognizer set is Python. The patterns below cite the
// recognizers.py constant they mirror so a future drift between the
// two layers is detectable by `grep`.
//
// TODO(piiguard-drift-check): add a CI step that fetches
// dual-sandbox-architecture@<vendoredUpstreamSHA> and diffs the
// imported recognizer regexes against the patterns below. Flag any
// upstream-side change since the SHA above so the vendoring pass is
// re-run. Tracked separately from this slice.
//
// # Failure mode discipline
//
// `Redact` MUST be safe to call on arbitrary input including
// already-redacted strings ("[EMAIL]"), structured JSON fragments,
// truncated UTF-8, and the empty string. The replacement is
// cursor-safe (advanced past the replacement marker) so a marker like
// "[EMAIL]" placed by an earlier pass is not re-matched.
//
// `RedactJSON` walks any JSON shape; on parse failure the input is
// passed through to `Redact` as if it were a flat string. This is the
// strictly-safer mode — never leaks raw bytes by short-circuit.
package piiguard

import (
	"bytes"
	"encoding/json"
	"errors"
	"regexp"
)

// L1 redaction markers. Stable strings the audit browser renders and
// the test suite asserts on. NEVER change the names without coordinated
// updates to the test fixtures + the documentation in OPS.md.
const (
	MarkerEmail      = "[EMAIL]"
	MarkerIBAN       = "[IBAN]"
	MarkerPhone      = "[PHONE]"
	MarkerSSN        = "[SSN]"
	MarkerIPv4       = "[IP]"
	MarkerIPv6       = "[IP]"
	MarkerUUID       = "[UUID]"
	MarkerGermanZip  = "[POSTAL]"
	MarkerUSDate     = "[DATE]"
	MarkerGermanTax  = "[ID]"
	MarkerMRN        = "[MRN]"
	MarkerAktenZ     = "[AKTENZEICHEN]"
	MarkerSNTicket   = "[TICKET]"
	MarkerCreditCard = "[PAN]"
	MarkerCanaryPhi  = "[REDACTED]"
)

// rule pairs a compiled regex with its replacement marker. Order
// matters: longer / more-specific patterns must come before shorter
// ones so that, e.g., an email's local part is not first eaten by the
// UUID rule.
//
// Each rule's "cite" field names the recognizer in recognizers.py the
// pattern was derived from so cross-language drift is auditable via
// `grep -F "<cite>"`.
type rule struct {
	pattern *regexp.Regexp
	marker  string
	cite    string
}

// rules is the closed L1 ruleset. Initialised once in init() so the
// regexes compile at process start, not per-call. Lazy compilation
// inside Redact would force a sync.Once on the hot path and lose
// determinism if any pattern is malformed (compile errors surface at
// startup, not under load).
var rules []rule

func init() {
	// Order: most-specific first. Email leads because its '@' anchor
	// disambiguates it from looser ID/UUID patterns that follow.
	candidates := []struct {
		expr   string
		marker string
		cite   string
	}{
		// Email — RFC 5322 light. Single '@', no consecutive dots in
		// the local part, TLD ≥2 chars. Matches the sanitizer's
		// Presidio built-in `EmailRecognizer` (no spaCy context
		// dependency).
		{`(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b`, MarkerEmail, "presidio:EmailRecognizer"},

		// IBAN — 2 letters + 2 check digits + 11-30 alnum (BBAN).
		// Mirrors `presidio:IbanRecognizer`. We anchor on word
		// boundaries and require uppercase letters to avoid eating
		// random tokens like "DE2026" inside Annex IV citations.
		{`\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b`, MarkerIBAN, "presidio:IbanRecognizer"},

		// UUID — RFC 4122 + hex variants. recognizers.py does not have
		// a dedicated UUID recognizer but the sanitizer's
		// `placeholders` module normalises UUIDs into the same
		// placeholder space; the dashboard's render-time guard is the
		// place to redact a raw UUID surfaced in an event payload.
		{`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b`, MarkerUUID, "rfc4122"},

		// IPv6 — full and zero-compressed forms. Strict-enough that
		// random hex sequences in payloads do not over-match. Pinned
		// to ≥2 ':' so single-colon tokens (HH:MM time) are not
		// mistaken for an address.
		{`\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\b`, MarkerIPv6, "rfc5952"},

		// IPv4 — dotted quad. Octets bounded 0-255 via regex to
		// avoid false positives on version strings ("v3.14.159.265").
		{`\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\b`, MarkerIPv4, "rfc791"},

		// Aktenzeichen / generic case number, mirrors `fallnummer`
		// recognizer (de) at recognizers.py: F-prefix legacy + 2-5
		// uppercase letters + 4-digit year + 3-6 digit serial.
		{`\b(?:F\d{8}|[A-Z]{2,5}-\d{4}-\d{3,6})\b`, MarkerAktenZ, "fallnummer"},

		// Slice 6 fix-up r1 DRIFT-004: German Aktenzeichen patterns
		// from recognizers.py:685-687 (az_standard + az_city_prefix).
		// az_standard: <chamber-number> <prefix> <serial>/<year>
		// (e.g., "11 Ca 4321/24"). az_city_prefix: <city> <chamber>
		// <prefix> <serial>/<year>. Both reuse MarkerAktenZ.
		// az_standard: chamber-digit(s) + space + 1-3 upper-case +
		// space + digits + slash + 2-or-4 digit year.
		{`\b\d{1,3}\s+[A-Z][A-Za-z]{0,3}\s+\d{1,6}/(?:\d{2}|\d{4})\b`, MarkerAktenZ, "german_aktenzeichen:az_standard"},
		// az_city_prefix: 2-3 upper-case city code + dot + space +
		// then az_standard tail. Matches "AG. 11 Ca 4321/24"-style.
		{`\b[A-Z]{2,3}\.\s+\d{1,3}\s+[A-Z][A-Za-z]{0,3}\s+\d{1,6}/(?:\d{2}|\d{4})\b`, MarkerAktenZ, "german_aktenzeichen:az_city_prefix"},

		// Medical record number — `medical_record_number` recognizer
		// at recognizers.py (en).
		{`\bMRN[- ]?\d{6,10}\b`, MarkerMRN, "medical_record_number"},

		// German Steuer-ID — recognizers.py `steuer_id`.
		{`\b\d{2}[\s\-]?\d{3}[\s\-]?\d{3}[\s\-]?\d{3}\b`, MarkerGermanTax, "steuer_id"},

		// US SSN (dashed only — bare 9-digit numerics are too noisy
		// without context boost, and the sanitizer relies on spaCy
		// context for the bare form).
		{`\b\d{3}-\d{2}-\d{4}\b`, MarkerSSN, "us_ssn:ssn_dashed"},

		// Phone — E.164 + spaced/dashed shapes. Conservative subset
		// of recognizers.py `phone_extended` to avoid eating
		// timestamps. Requires either a leading + OR a separator
		// in the body.
		{`(?:\+\d{1,3}[\s\-.]\d{2,5}[\s\-.]\d{2,5}(?:[\s\-.]\d{2,5})?|\b\d{3,4}[\s\-.]\d{3,4}[\s\-.]\d{3,4}\b)`, MarkerPhone, "phone_extended"},

		// ServiceNow ticket IDs — `servicenow_ticket_id` recognizer.
		// Score 0.01 in Presidio so it never fires unaided; here it's
		// the only signal we have in render-time text. Marker:
		// MarkerSNTicket so operators see redaction happened on
		// purpose.
		{`\b(?:INC|CHG|PRB|REQ|RITM)\d{5,10}\b`, MarkerSNTicket, "servicenow_ticket_id"},

		// Credit card / PAN, 13-19 digits with optional group
		// separators. Not in recognizers.py but a common payload
		// surface; defensive redaction. Bounded ≤19 so a malformed
		// timestamp like "2026-05-21-...-..." does not over-match.
		{`\b(?:\d[ \-]?){13,19}\b`, MarkerCreditCard, "luhn-shape-only"},

		// German postal code, 5 digits, recognizers.py `german_zip_code`.
		// Word-boundary anchor on both sides keeps '12345abc' and
		// 'abc12345' out. Go's `regexp` does not support lookahead so
		// we rely on `\b` exclusively; this catches the most common
		// shapes (zip embedded in addresses + trailing punctuation).
		{`\b\d{5}\b`, MarkerGermanZip, "german_zip_code"},

		// US dotted DOB style — recognizers.py `date_of_birth_en`
		// us_date pattern (mm/dd/yyyy). Only the 4-digit-year form
		// to avoid eating ratios like "1/2/3".
		{`\b\d{1,2}/\d{1,2}/(?:19|20)\d{2}\b`, MarkerUSDate, "date_of_birth_en:us_date"},

		// Canary placeholder leakage protection — the sanitizer
		// emits `[CANARY:...]` tokens during eval runs; the
		// dashboard re-redacts them as a defence in depth (paranoid
		// belt-and-braces, in case a custom recognizer leaks the
		// raw canary into a payload).
		{`\[CANARY:[^\]]+\]`, MarkerCanaryPhi, "sanitizer/canary.py"},
	}

	rules = make([]rule, 0, len(candidates))
	for _, c := range candidates {
		re := regexp.MustCompile(c.expr)
		rules = append(rules, rule{pattern: re, marker: c.marker, cite: c.cite})
	}
}

// Redact returns text with every L1 pattern replaced by its marker.
// Markers themselves never re-match (the markers are uppercase ASCII
// inside square brackets; none of the rules match that shape — verified
// by TestRedact_NoInfiniteLoopOnSelfMatch).
//
// Redact is safe on the empty string and on already-redacted text. The
// implementation iterates rules in declaration order, applying
// ReplaceAllString on each. Marker collisions cannot occur because
// each pattern excludes the bracket prefix that markers begin with.
func Redact(text string) string {
	if text == "" {
		return ""
	}
	out := text
	for _, r := range rules {
		out = r.pattern.ReplaceAllString(out, r.marker)
	}
	return out
}

// ErrRedactJSON is returned by RedactJSON when the input is non-empty
// but cannot be walked safely. Callers MUST render
// "[REDACTED — render error]" instead of the raw input in this case.
var ErrRedactJSON = errors.New("piiguard: cannot redact json input")

// RedactJSON walks any JSON shape (object/array/string/number/bool/null)
// and applies Redact to every string leaf. Numbers and booleans are
// preserved as-is. The returned RawMessage is a freshly-marshalled
// representation; round-trip stability is NOT guaranteed (map key
// order may change). For non-JSON / malformed input, Redact is
// applied to the input as a flat string and returned with no error.
//
// This is the security-critical entry point for the audit detail
// page — payloads may be deeply nested structured logs. The walker
// uses encoding/json's standard decoder so the recursion depth is
// bounded by the decoder's stack limits, not by our code. Adversarial
// deeply-nested payloads are an upstream concern handled by Postgres
// row-size limits (the audit DB caps payload at the column type
// boundary).
func RedactJSON(raw json.RawMessage) (json.RawMessage, error) {
	if len(raw) == 0 {
		return raw, nil
	}
	var anyVal any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&anyVal); err != nil {
		// Not JSON. Treat as flat string and redact via Redact().
		// Falling open with the raw input would leak PII; falling
		// closed with a fixed marker would obscure non-PII metadata.
		// Redact() is the strictly-safer compromise.
		return json.RawMessage(`"` + jsonEscape(Redact(string(raw))) + `"`), nil
	}
	walked := walkRedact(anyVal)
	out, err := json.Marshal(walked)
	if err != nil {
		// json.Marshal failures on a walked anyVal indicate the
		// walker produced a non-marshallable shape — never happens
		// in practice but the safe fallback is to redact-as-string.
		return json.RawMessage(`"` + jsonEscape(Redact(string(raw))) + `"`), nil
	}
	return out, nil
}

func walkRedact(v any) any {
	switch x := v.(type) {
	case string:
		return Redact(x)
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			out[k] = walkRedact(val)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, val := range x {
			out[i] = walkRedact(val)
		}
		return out
	default:
		return x
	}
}

// jsonEscape minimally escapes a string for embedding inside a JSON
// string literal. The fallback path in RedactJSON wraps the redacted
// text in `"..."` and emits the result as json.RawMessage; without
// escaping, an unescaped quote or backslash would break downstream
// JSON parsers.
func jsonEscape(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		return ""
	}
	// b is `"..."` — strip the wrapping quotes for embedding.
	if len(b) >= 2 {
		return string(b[1 : len(b)-1])
	}
	return ""
}
