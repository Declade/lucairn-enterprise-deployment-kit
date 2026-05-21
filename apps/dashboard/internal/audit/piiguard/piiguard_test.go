package piiguard

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRedact_Email(t *testing.T) {
	in := "Contact alice@example.com about the issue"
	out := Redact(in)
	if strings.Contains(out, "alice@example.com") {
		t.Fatalf("email survived redaction: %q", out)
	}
	if !strings.Contains(out, MarkerEmail) {
		t.Fatalf("email marker missing: %q", out)
	}
}

func TestRedact_IBAN(t *testing.T) {
	in := "Payment from DE89370400440532013000 received"
	out := Redact(in)
	if strings.Contains(out, "DE89370400440532013000") {
		t.Fatalf("IBAN survived redaction: %q", out)
	}
	if !strings.Contains(out, MarkerIBAN) {
		t.Fatalf("IBAN marker missing: %q", out)
	}
}

func TestRedact_PhoneE164(t *testing.T) {
	in := "Call back on +49 30 12345 67890"
	out := Redact(in)
	if strings.Contains(out, "+49 30 12345 67890") {
		t.Fatalf("phone survived redaction: %q", out)
	}
	if !strings.Contains(out, MarkerPhone) {
		t.Fatalf("phone marker missing: %q", out)
	}
}

func TestRedact_SSN(t *testing.T) {
	in := "SSN 123-45-6789 on file"
	out := Redact(in)
	if strings.Contains(out, "123-45-6789") {
		t.Fatalf("SSN survived redaction: %q", out)
	}
	if !strings.Contains(out, MarkerSSN) {
		t.Fatalf("SSN marker missing: %q", out)
	}
}

func TestRedact_IPv4(t *testing.T) {
	in := "Probe from 192.168.42.17 succeeded"
	out := Redact(in)
	if strings.Contains(out, "192.168.42.17") {
		t.Fatalf("IPv4 survived redaction: %q", out)
	}
	if !strings.Contains(out, MarkerIPv4) {
		t.Fatalf("IP marker missing: %q", out)
	}
}

func TestRedact_IPv6(t *testing.T) {
	in := "Origin: 2001:0db8:85a3:0000:0000:8a2e:0370:7334"
	out := Redact(in)
	if strings.Contains(out, "2001:0db8:85a3:0000:0000:8a2e:0370:7334") {
		t.Fatalf("IPv6 survived redaction: %q", out)
	}
}

func TestRedact_UUID(t *testing.T) {
	in := "request_id=550e8400-e29b-41d4-a716-446655440000"
	out := Redact(in)
	if strings.Contains(out, "550e8400-e29b-41d4-a716-446655440000") {
		t.Fatalf("UUID survived redaction: %q", out)
	}
	if !strings.Contains(out, MarkerUUID) {
		t.Fatalf("UUID marker missing: %q", out)
	}
}

func TestRedact_GermanZipCode(t *testing.T) {
	in := "Adresse: Berliner Str. 5, 10115 Berlin"
	out := Redact(in)
	if strings.Contains(out, "10115") {
		t.Fatalf("German ZIP survived redaction: %q", out)
	}
}

func TestRedact_MRN(t *testing.T) {
	in := "Patient record MRN-1234567 admitted"
	out := Redact(in)
	if strings.Contains(out, "MRN-1234567") {
		t.Fatalf("MRN survived redaction: %q", out)
	}
}

func TestRedact_Aktenzeichen(t *testing.T) {
	in := "Case MK-2026-0001 reviewed"
	out := Redact(in)
	if strings.Contains(out, "MK-2026-0001") {
		t.Fatalf("Aktenzeichen survived redaction: %q", out)
	}
}

func TestRedact_ServiceNowTicket(t *testing.T) {
	in := "Filed INC0012345 with the team"
	out := Redact(in)
	if strings.Contains(out, "INC0012345") {
		t.Fatalf("SNow ticket survived redaction: %q", out)
	}
}

func TestRedact_CanaryToken(t *testing.T) {
	in := "Audit emit included [CANARY:LEAK-PROBE-7] in payload"
	out := Redact(in)
	if strings.Contains(out, "[CANARY:LEAK-PROBE-7]") {
		t.Fatalf("canary survived redaction: %q", out)
	}
	if !strings.Contains(out, MarkerCanaryPhi) {
		t.Fatalf("canary marker missing: %q", out)
	}
}

func TestRedact_EmptyString(t *testing.T) {
	if got := Redact(""); got != "" {
		t.Fatalf("Redact(\"\") = %q, want \"\"", got)
	}
}

func TestRedact_NoInfiniteLoopOnSelfMatch(t *testing.T) {
	// Marker shapes MUST NOT re-match. Verify each declared marker is
	// inert vs. every rule's pattern. If a marker matched its own
	// rule (or any rule), the second pass would still find it and
	// the cursor would re-advance over the same byte range — a
	// halt-class regression.
	markers := []string{
		MarkerEmail, MarkerIBAN, MarkerPhone, MarkerSSN, MarkerIPv4,
		MarkerIPv6, MarkerUUID, MarkerGermanZip, MarkerUSDate,
		MarkerGermanTax, MarkerMRN, MarkerAktenZ, MarkerSNTicket,
		MarkerCreditCard, MarkerCanaryPhi,
	}
	for _, m := range markers {
		out := Redact(m)
		if out != m {
			t.Fatalf("marker %q changed under redaction: got %q", m, out)
		}
		// Second pass must be a fixpoint.
		out2 := Redact(out)
		if out2 != out {
			t.Fatalf("marker %q not a redaction fixpoint: %q -> %q", m, out, out2)
		}
	}
}

func TestRedact_AlreadyRedactedTextIsFixpoint(t *testing.T) {
	in := "from [EMAIL] called [PHONE]"
	got := Redact(in)
	if got != in {
		t.Fatalf("already-redacted text changed: %q -> %q", in, got)
	}
}

func TestRedact_PIIPatternsCorpus(t *testing.T) {
	// Synthetic PII corpus — assert each row has zero raw PII after
	// redaction. The corpus uses obviously-fake personas (Bob Example,
	// Carol Sample) to avoid accidentally embedding real PII.
	corpus := []struct {
		name string
		text string
		raw  string // the substring that MUST NOT appear after redaction
	}{
		{"email_within_sentence", "Email from bob@example.com received", "bob@example.com"},
		{"iban_within_payment", "Wire from DE44500105175407324931 cleared", "DE44500105175407324931"},
		{"phone_internl", "Reached at +44 20 7946 0958 last night", "+44 20 7946 0958"},
		{"ipv4_log", "From 10.0.0.42 at 14:02", "10.0.0.42"},
		{"uuid_query", "?request_id=11111111-2222-3333-4444-555555555555", "11111111-2222-3333-4444-555555555555"},
		{"ssn_dashed", "Form B SSN 987-65-4321", "987-65-4321"},
		{"mrn_dashed", "Visit MRN-2023123 charted", "MRN-2023123"},
	}
	for _, row := range corpus {
		t.Run(row.name, func(t *testing.T) {
			out := Redact(row.text)
			if strings.Contains(out, row.raw) {
				t.Fatalf("raw %q survived in %q", row.raw, out)
			}
		})
	}
}

func TestRedactJSON_NestedStructuresRedacted(t *testing.T) {
	raw := json.RawMessage(`{"actor":"alice@example.com","payload":{"ip":"192.168.1.1","tags":["uuid:550e8400-e29b-41d4-a716-446655440000","unrelated"]},"count":7}`)
	out, err := RedactJSON(raw)
	if err != nil {
		t.Fatalf("RedactJSON err: %v", err)
	}
	if strings.Contains(string(out), "alice@example.com") {
		t.Fatalf("nested email survived: %s", out)
	}
	if strings.Contains(string(out), "192.168.1.1") {
		t.Fatalf("nested IP survived: %s", out)
	}
	if strings.Contains(string(out), "550e8400-e29b-41d4-a716-446655440000") {
		t.Fatalf("nested UUID survived: %s", out)
	}
	if !strings.Contains(string(out), `"count":7`) {
		t.Fatalf("numeric leaf lost: %s", out)
	}
}

func TestRedactJSON_MalformedFallsBackToFlatRedact(t *testing.T) {
	// Not valid JSON. Falls back to Redact() over the raw bytes.
	raw := json.RawMessage(`not really json: contact alice@example.com`)
	out, err := RedactJSON(raw)
	if err != nil {
		t.Fatalf("RedactJSON err: %v", err)
	}
	if strings.Contains(string(out), "alice@example.com") {
		t.Fatalf("email survived malformed-JSON fallback: %s", out)
	}
}

func TestRedactJSON_EmptyReturnsEmpty(t *testing.T) {
	out, err := RedactJSON(nil)
	if err != nil {
		t.Fatalf("RedactJSON(nil) err: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("RedactJSON(nil) returned %q", out)
	}
}

func TestRedactJSON_PreservesNonStringLeaves(t *testing.T) {
	raw := json.RawMessage(`{"ok":true,"count":42,"score":1.5,"missing":null}`)
	out, err := RedactJSON(raw)
	if err != nil {
		t.Fatalf("RedactJSON err: %v", err)
	}
	if !strings.Contains(string(out), `"ok":true`) {
		t.Fatalf("bool lost: %s", out)
	}
	if !strings.Contains(string(out), `"count":42`) {
		t.Fatalf("int lost: %s", out)
	}
	if !strings.Contains(string(out), `"missing":null`) {
		t.Fatalf("null lost: %s", out)
	}
}
