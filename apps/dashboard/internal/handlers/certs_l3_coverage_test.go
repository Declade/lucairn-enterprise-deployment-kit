package handlers

import (
	"errors"
	"html"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/store"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/testutil"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness"
	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
)

// ---------------------------------------------------------------------------
// T-600 S3 / T-617 S3 — what the Cert Inspector actually puts on the page.
// ---------------------------------------------------------------------------
//
// PRDs: Opus Advisor specs/2026-09/prd-2026-09-21-t600-t617-coverage-
// attestation-stream.md § Slice D; specs/2026-08/prd-2026-08-09-t600-evidence-
// gated-l3-coverage.md Marc lock 4 + § Slice 3.
//
// These render the REAL template through the REAL handler. The narrative comes
// from witness.BuildL3CoverageNarrative over records whose per-field rows are
// the upstream producer corpus (internal/testutil), so the page under test is
// the page an operator sees over a record the sanitizer can actually emit.

// inspectorBody drives the inspector handler over one VerifyResult and returns
// the rendered HTML with entities decoded, so assertions read the sentence the
// operator reads rather than "&#39;".
func inspectorBody(t *testing.T, res witness.VerifyResult) string {
	raw, _ := inspectorBodies(t, res)
	return raw
}

// inspectorBodies drives the inspector handler over one VerifyResult and
// returns (rawHTML, unescapedHTML).
//
// ⚑ THE RAW BODY IS THE ONE THAT MATTERS (round-2 MED-5). The first cut of
// this file html.UnescapeString()d the body before every assertion, so no test
// could see what the page actually SERVES — an apostrophe silently became
// &#39; and the T-600 PRD's grep-verifiable criterion was satisfied only after
// a decoding step no operator performs. Assertions now run on the RAW bytes;
// the unescaped copy exists only for the handful of checks about structure
// (the completeness cell) rather than about served text.
func inspectorBodies(t *testing.T, res witness.VerifyResult) (string, string) {
	t.Helper()
	st := &stubStore{getRow: store.CertSummary{
		ID:         "veil_abcdef12-1234-5678-9abc-def012345678",
		RequestID:  "req_abcd-1234",
		CustomerID: "cust-1",
		CreatedAt:  time.Now(),
		Verdict:    "partial",
	}}
	d := newDeps(t, st, &stubVerifier{result: res})
	rec := httptest.NewRecorder()
	d.InspectorHandler(rec, fakeSessionRequest("GET", "/certs/veil_abcdef12-1234-5678-9abc-def012345678", ""))
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d want 200", rec.Code)
	}
	return rec.Body.String(), html.UnescapeString(rec.Body.String())
}

// resultWith builds the VerifyResult the witness client would produce for the
// given records — same two calls mapVerifyResult makes.
func resultWith(completeness string, scope *witnesspb.L3CoverageScope, ev *witnesspb.L3CoverageEvidence) witness.VerifyResult {
	return witness.VerifyResult{
		OverallVerdict:      "partial",
		Completeness:        completeness,
		CompletenessDisplay: witness.L3CompletenessWithCaveat(completeness),
		SignaturesValid:     true,
		IsolationVerified:   true,
		L3Coverage:          witness.BuildL3CoverageNarrative(scope, ev),
	}
}

func mustEvidence(t *testing.T, scenario string) *witnesspb.L3CoverageEvidence {
	t.Helper()
	ev, err := testutil.L3EvidenceFromProducer(scenario)
	if err != nil {
		t.Fatalf("producer fixture %q: %v", scenario, err)
	}
	return ev
}

// assertCeilingAndNoOverclaim is the invariant every inspector render must
// satisfy, whatever the records say.
func assertCeilingAndNoOverclaim(t *testing.T, body string) {
	t.Helper()
	// ⛔ RAW BODY. `body` is what the handler SERVES, un-decoded. If a
	// narrative string ever grows an apostrophe or a quote mark, it lands here
	// as &#39; / &#34; and this Contains fails — which is the point.
	if !strings.Contains(body, witness.L3CoverageCeiling) {
		t.Errorf("the coverage ceiling is missing from the SERVED page (check for HTML-escaped characters)")
	}
	for _, banned := range []string{
		"all PII", "complete detection", "everything was scanned",
		"everything was found", "nothing was missed", "complete protection",
	} {
		if strings.Contains(strings.ToLower(body), strings.ToLower(banned)) {
			t.Errorf("rendered page carries the banned overclaim %q", banned)
		}
	}
	// The bare completeness word must never stand alone in its cell.
	//
	// ⚑ Scoped to the COMPLETENESS cell on purpose. "partial" also appears as
	// the overall-verdict pill, where a bare word is correct — a page-wide
	// substring ban would fail on an honest render and teach the next person
	// to delete the assertion.
	cell := completenessCell(t, html.UnescapeString(body))
	for _, bare := range []string{"full", "Full", "partial", "Partial", "unspecified", "Unspecified"} {
		if strings.TrimSpace(cell) == bare {
			t.Errorf("the completeness cell is the bare word %q — that IS the defect", bare)
		}
	}
	if !strings.Contains(cell, witness.L3CompletenessMeaning) {
		t.Errorf("the completeness cell dropped the caveat: %q", cell)
	}
	// Disclosure boundary: no field keys, receipt ids, source claim ids or
	// zone names on an operator page.
	for _, leak := range []string{"messages[", "rcpt_", "clm_", "operator_note"} {
		if strings.Contains(body, leak) {
			t.Errorf("rendered page leaks %q", leak)
		}
	}
}

// completenessCell extracts the rendered Completeness row's VALUE, so the
// bare-word assertion reads the one cell the T-600 defect lived in rather than
// the whole page.
func completenessCell(t *testing.T, body string) string {
	t.Helper()
	const label = `<span class="lc-text-muted">Completeness</span>`
	i := strings.Index(body, label)
	if i < 0 {
		t.Fatalf("no Completeness row on the rendered page")
	}
	rest := body[i+len(label):]
	j := strings.Index(rest, "</div>")
	if j < 0 {
		t.Fatalf("Completeness row is not closed")
	}
	cell := rest[:j]
	cell = strings.ReplaceAll(cell, "<span>", "")
	cell = strings.ReplaceAll(cell, "</span>", "")
	cell = strings.ReplaceAll(cell, `<span class="lc-text-muted">`, "")
	return strings.TrimSpace(cell)
}

// (i) scope present + granted, evidence present + passed.
func TestInspectorHandler_RendersScopeAndPassingEvidence(t *testing.T) {
	t.Parallel()
	ev := mustEvidence(t, "passed")
	ev.ComposedGreen = true
	ev.ComposedReason = "scope_and_recall_satisfied"
	scope := testutil.L3ScopeGranted(
		[]string{"messages[0].content", "messages[1].content"},
		[]*witnesspb.L3ExcludedField{
			{FieldKey: "messages[2].content", Zone: "operator_note", Reason: "zone_policy_skip"},
		},
	)

	body := inspectorBody(t, resultWith("full", scope, ev))

	if !strings.Contains(body, "The deep shield covered 2 of 2 fields eligible for it") {
		t.Errorf("scope row missing from the page")
	}
	if !strings.Contains(body, "1 field(s) were excluded by policy: 1 x the zone policy excludes the deep shield for that zone") {
		t.Errorf("exclusion ledger missing from the page")
	}
	if !strings.Contains(body, "Coverage evidence check passed (16/16 probes recovered) across 2 field(s).") {
		t.Errorf("lock-4 evidence wording missing from the page")
	}
	if !strings.Contains(body, "Full - "+witness.L3CompletenessMeaning) {
		t.Errorf("completeness caveat missing from the page")
	}
	if !strings.Contains(body, witness.L3CoverageDiagnosticOnly) {
		t.Errorf("the diagnostic-only note must render while the records drive nothing")
	}
	// The raw machine state the narrative struct promises an operator.
	if !strings.Contains(body, "scope=present") || !strings.Contains(body, "evidence=present") ||
		!strings.Contains(body, "rollup=verified") || !strings.Contains(body, "drives_verdict=false") {
		t.Errorf("the raw record-state row is missing or incomplete on the page")
	}
	assertCeilingAndNoOverclaim(t, body)
}

// (ii) evidence FAILED.
func TestInspectorHandler_RendersFailedEvidence(t *testing.T) {
	t.Parallel()
	ev := mustEvidence(t, "failed")
	ev.ComposedGreen = false
	ev.ComposedReason = "evidence_failed"
	scope := testutil.L3ScopeGranted([]string{"messages[0].content", "messages[1].content"}, nil)

	body := inspectorBody(t, resultWith("full", scope, ev))

	if !strings.Contains(body, "Coverage evidence check FAILED - 1 field(s) returned fewer planted probes than required") {
		t.Errorf("failed-evidence wording missing from the page")
	}
	if !strings.Contains(body, "A measured miss is positive evidence of a recall gap.") {
		t.Errorf("the page must say what a measured miss means")
	}
	if !strings.Contains(body, "Composed completeness rule (scope AND recall AND named exclusions): NOT granted") {
		t.Errorf("composed rule must refuse on the page")
	}
	// ⚑ The verdict is untouched — a FAILED recall check next to a "Full"
	// completeness word is the DESIGNED dark-period shape, and it is exactly
	// why the caveat has to be on the page.
	if !strings.Contains(body, "Full - "+witness.L3CompletenessMeaning) {
		t.Errorf("completeness caveat missing on a failed-evidence render")
	}
	assertCeilingAndNoOverclaim(t, body)
}

// (iii) both records absent — every pre-T-617/T-600 certificate.
func TestInspectorHandler_RendersBothRecordsAbsent(t *testing.T) {
	t.Parallel()
	body := inspectorBody(t, resultWith("partial", nil, nil))

	if !strings.Contains(body, "Coverage scope unavailable -") {
		t.Errorf("absent scope must render as unavailable")
	}
	if !strings.Contains(body, "This is NOT a statement that nothing was excluded or that every field was covered.") {
		t.Errorf("absent scope must refuse the innocence reading on the page")
	}
	if !strings.Contains(body, "Recall evidence unavailable -") {
		t.Errorf("absent evidence must render as unavailable")
	}
	if !strings.Contains(body, "This is NOT a statement that the scan was clean.") {
		t.Errorf("absent evidence must refuse the innocence reading on the page")
	}
	if strings.Contains(body, "Composed completeness rule") {
		t.Errorf("nothing composes over an absent record — the row must not render")
	}
	// Absent is a TOKEN an operator can read, not just prose.
	if !strings.Contains(body, "scope=absent") || !strings.Contains(body, "evidence=absent") ||
		!strings.Contains(body, "rollup=unset") {
		t.Errorf("the raw record-state row must name the absent state")
	}
	assertCeilingAndNoOverclaim(t, body)
}

// (iv) receipt-covered — the reason that fires MORE as caching succeeds.
func TestInspectorHandler_RendersReceiptCoveredReason(t *testing.T) {
	t.Parallel()
	scope := &witnesspb.L3CoverageScope{
		RecordStatus:      "present",
		DerivationVersion: "t617-scope-v1",
		Granted:           true,
		Reason:            "all_eligible_fields_covered",
		EligibleCount:     2,
		Covered: []*witnesspb.L3CoveredField{
			{FieldKey: "messages[0].content", Via: "scan"},
			{FieldKey: "messages[1].content", Via: "receipt", ReceiptId: "rcpt_9f2c1a", SourceClaimId: "clm_0d41ba"},
		},
	}
	ev := mustEvidence(t, "partial")
	ev.ComposedGreen = false
	ev.ComposedReason = "receipt_covered_evidence_not_in_chain"

	body := inspectorBody(t, resultWith("full", scope, ev))

	if !strings.Contains(body, "(1 by a fresh scan this turn, 1 by a named receipt from an earlier turn)") {
		t.Errorf("the page must separate fresh scans from receipt-backed reuse")
	}
	if !strings.Contains(body, "covered by a NAMED RECEIPT from an earlier turn") {
		t.Errorf("the page must name the receipt reason")
	}
	if !strings.Contains(body, "the recall evidence for them lives on the source claim, not here") {
		t.Errorf("the page must say where the evidence actually is")
	}
	assertCeilingAndNoOverclaim(t, body)
}

// TestInspectorHandler_NoCoverageBlockWhenWitnessUnreachable pins the one case
// where the block is absent: there is no narrative at all, the witness banner
// already says so, and rendering "scope unavailable" there would attribute a
// transport failure to the certificate.
func TestInspectorHandler_NoCoverageBlockWhenWitnessUnreachable(t *testing.T) {
	t.Parallel()
	st := &stubStore{getRow: store.CertSummary{
		ID:         "veil_abcdef12-1234-5678-9abc-def012345678",
		RequestID:  "req_abcd-1234",
		CustomerID: "cust-1",
		CreatedAt:  time.Now(),
	}}
	d := newDeps(t, st, &stubVerifier{err: errors.New("witness gRPC connection refused")})
	rec := httptest.NewRecorder()
	d.InspectorHandler(rec, fakeSessionRequest("GET", "/certs/veil_abcdef12-1234-5678-9abc-def012345678", ""))
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d want 200", rec.Code)
	}
	body := html.UnescapeString(rec.Body.String())
	if !strings.Contains(body, "Witness unreachable.") {
		t.Fatalf("expected the witness-unreachable banner")
	}
	if strings.Contains(body, witness.L3CoverageCeiling) {
		t.Errorf("no coverage block may render when no narrative was built")
	}
	if !strings.Contains(body, ">unavailable<") {
		t.Errorf("the completeness cell must read 'unavailable', not an empty cell")
	}
}
