package compliance

import (
	"encoding/base64"
	"strings"
	"testing"
)

// decodeFixture is the test-side mirror of buildBannedLiteralPattern's
// decoder. Tests reference the fixtures by base64 to keep the source of
// THIS file banned-literal-free (the project-wide grep guard would
// otherwise flag the test as a marketing surface). Same pattern as
// apps/dashboard/internal/views/views_test.go.
func decodeFixture(t *testing.T, encoded string) string {
	t.Helper()
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("decode %q: %v", encoded, err)
	}
	return string(decoded)
}

func TestAssert_EmptyInput(t *testing.T) {
	if err := Assert(""); err != nil {
		t.Errorf("Assert(\"\") = %v, want nil", err)
	}
}

func TestAssert_CleanInput(t *testing.T) {
	// Every clean fragment must NOT trigger. Mixes regulator nouns,
	// section headers, neutral copy.
	clean := []string{
		"Customer compliance summary",
		"Category 1: sanitizer claims under Article 10 and Article 15",
		"Category 2: evidence claims under Article 12 and Article 14",
		"Category 3: inventory claims under Article 10, Article 12, Article 14, Article 15",
		"Date range: 2026-04-01 through 2026-04-30",
		"Total certificates: 1234",
		"Lucairn Enterprise Dashboard",
		"ISO 9001",      // edge: short ISO doesn't match ISO 27001
		"ISO 270010",    // edge: longer suffix doesn't match
		"99.5%",         // edge: lower uptime claim doesn't match 99.9%
		"100% coverage", // edge: 100% doesn't match
		"red carpet",    // edge: "red" alone doesn't match "red team"
		"penetration",   // edge: "penetration" alone doesn't match "penetration test"
		"network configuration",
		"AI Act categorisation",
	}
	for _, s := range clean {
		if err := Assert(s); err != nil {
			t.Errorf("Assert(%q) = %v, want nil", s, err)
		}
	}
}

func TestAssert_TriggersOnEveryBannedLiteral(t *testing.T) {
	// Every entry in the buildBannedLiteralPattern corpus MUST trip
	// the guard in upper, lower, and mixed case. Tests use the same
	// base64 fixtures as the production code so adding a new banned
	// literal to the corpus auto-flows into this test.
	cases := []struct {
		name    string
		encoded string
	}{
		{"soc2", "U09DIDI="},
		{"iso27001", "SVNPIDI3MDAx"},
		{"iso27701", "SVNPIDI3NzAx"},
		{"iso42001", "SVNPIDQyMDAx"},
		{"hipaa", "SElQQUE="},
		{"pci_dss_dash", "UENJLURTUw=="},
		{"pci_dss_space", "UENJIERTUw=="},
		{"e2e_encryption", "RTJFIGVuY3J5cHRpb24="},
		{"end_to_end", "ZW5kLXRvLWVuZCBlbmNyeXB0aW9u"},
		{"encrypted_at_rest", "ZW5jcnlwdGVkIGF0IHJlc3Q="},
		{"pen_test", "cGVuIHRlc3Q="},
		{"penetration_test", "cGVuZXRyYXRpb24gdGVzdA=="},
		{"red_team", "cmVkIHRlYW0="},
		{"mfa", "TUZB"},
		{"multi_factor", "bXVsdGktZmFjdG9yIGF1dGhlbnRpY2F0aW9u"},
		{"regular_audits", "cmVndWxhciBhdWRpdHM="},
		// Retired tier names + retired brand.
		{"solo_free", "U29sbyBGcmVl"},
		{"solo_pro", "U29sbyBQcm8="},
		{"the_veil", "VGhlIFZlaWw="},
		{"theveil", "dGhldmVpbA=="},
		{"dsaveil", "ZHNhdmVpbA=="},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			literal := decodeFixture(t, tc.encoded)

			// Original-case + lower + upper + mixed. The test must trip
			// each one — case-insensitivity is a load-bearing property
			// of the guard.
			variants := []string{
				literal,
				strings.ToLower(literal),
				strings.ToUpper(literal),
				// Mixed case via title-casing the first rune.
				mixCase(literal),
			}
			for _, v := range variants {
				body := "Lucairn compliance report contains " + v + " in section 3."
				if err := Assert(body); err == nil {
					t.Errorf("Assert(...%q...) = nil, want non-nil error", v)
				}
			}
		})
	}
}

func TestAssert_TLSVersionVariants(t *testing.T) {
	// The TLS character class catches both "TLS 1.2" and "TLS 1.3"
	// because the regex fragment is `TLS 1\.[23]`. Decoded fixture:
	tlsRegex := decodeFixture(t, "VExTIDFcLlsyM10=")
	if tlsRegex != "TLS 1\\.[23]" {
		t.Fatalf("decoded fixture changed shape: %q", tlsRegex)
	}
	for _, body := range []string{
		"All connections use TLS 1.2 transport.",
		"All connections use TLS 1.3 transport.",
		"Our TLS 1.2 stack is hardened.",
		"tls 1.3 deployment",
	} {
		if err := Assert(body); err == nil {
			t.Errorf("Assert(%q) = nil, want non-nil", body)
		}
	}
	// "TLS 1.1" or "TLS 1.0" must NOT match (those aren't claims we
	// ban — they'd be deprecated-version security claims that don't
	// belong in a marketing surface, but they're not in the corpus).
	for _, body := range []string{
		"Disable TLS 1.0 if observed.",
		"TLS 1.1 deprecated.",
	} {
		if err := Assert(body); err != nil {
			t.Errorf("Assert(%q) = %v, want nil (TLS 1.0/1.1 are not in the banned corpus)", body, err)
		}
	}
}

func TestAssert_UptimeSLAVariants(t *testing.T) {
	for _, body := range []string{
		"We guarantee 99.9% uptime.",
		"Service availability: 99.99%",
		"99.9%",
		"99.99%",
	} {
		if err := Assert(body); err == nil {
			t.Errorf("Assert(%q) = nil, want non-nil (uptime SLA claim)", body)
		}
	}
}

func TestAssert_ProPlusRetiredTierName(t *testing.T) {
	// "Pro+" was the retired tier name. The escape in the regex
	// fragment (`Pro\+`) means we only match the exact literal —
	// "Pro" alone is NOT banned (it's the current tier name).
	if err := Assert("The Pro+ tier is now retired."); err == nil {
		t.Errorf("Assert(Pro+) = nil, want non-nil")
	}
	if err := Assert("Customer is on the Pro tier."); err != nil {
		t.Errorf("Assert(Pro alone) = %v, want nil — 'Pro' is the current tier", err)
	}
}

func TestAssert_ReportsByteOffsetAndLiteral(t *testing.T) {
	prefix := "Lucairn report includes "
	literal := decodeFixture(t, "SElQQUE=") // HIPAA
	body := prefix + literal + " coverage."
	err := Assert(body)
	if err == nil {
		t.Fatal("Assert returned nil; want error")
	}
	msg := err.Error()
	if !strings.Contains(msg, "banned literal detected") {
		t.Errorf("error %q missing 'banned literal detected' marker", msg)
	}
	// The byte offset includes the leading boundary char (space at 23)
	// in the matched span. The reported match content also includes
	// the leading boundary char; the literal HIPAA starts at offset 24
	// but the regex's leftBoundary char-class consumes the space at 23.
	if !strings.Contains(msg, "byte offset 23") {
		t.Errorf("error %q missing byte offset 23", msg)
	}
}

func TestAssertSection_WrapsErrorWithSectionName(t *testing.T) {
	literal := decodeFixture(t, "U09DIDI=") // SOC 2
	err := AssertSection("Category 1 Header", "Customer holds "+literal+" certification.")
	if err == nil {
		t.Fatal("AssertSection returned nil; want error")
	}
	if !strings.Contains(err.Error(), `section "Category 1 Header"`) {
		t.Errorf("error %q missing section name", err)
	}
}

func TestAssertSection_PassThroughOnClean(t *testing.T) {
	if err := AssertSection("Cover", "Lucairn compliance summary 2026-04-30"); err != nil {
		t.Errorf("AssertSection(clean) = %v, want nil", err)
	}
}

// mixCase produces a title-case variant of s. ASCII-only — sufficient
// for the corpus which is English-only.
func mixCase(s string) string {
	if s == "" {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	upper := true
	for _, r := range s {
		if upper && r >= 'a' && r <= 'z' {
			b.WriteRune(r - 32)
		} else if !upper && r >= 'A' && r <= 'Z' {
			b.WriteRune(r + 32)
		} else {
			b.WriteRune(r)
		}
		upper = !upper
	}
	return b.String()
}
