package witness

import (
	"strings"
	"testing"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/testutil"
	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
)

// bannedClaimPhrases are the overclaims T-600 Marc lock 4 forbids on every
// reader surface. They are matched case-insensitively against every string the
// narrative builder can produce.
//
// ⚑ "Full" is deliberately NOT in this list as a substring — the word appears
// legitimately inside "Full — completeness describes the CLAIM CHAIN …". The
// BARE-"Full" regression is pinned separately by
// TestL3CompletenessWithCaveat_BareWordIsGone and by the handler render tests.
var bannedClaimPhrases = []string{
	"all pii",
	"complete detection",
	"everything was scanned",
	"everything was found",
	"all personal data",
	"nothing was missed",
	"completely sanitized",
	"completely sanitised",
	"fully protected",
	"complete protection",
	"all pii removed",
	"the scan was clean",
}

func assertNoBannedPhrase(t *testing.T, label, s string) {
	t.Helper()
	low := strings.ToLower(s)
	for _, p := range bannedClaimPhrases {
		if !strings.Contains(low, p) {
			continue
		}
		// "This is NOT a statement that the scan was clean." is a NEGATION of
		// the banned phrase, not the claim. Allow the phrase only inside that
		// exact refusal wording.
		if p == "the scan was clean" && strings.Contains(low, "not a statement that the scan was clean") {
			continue
		}
		t.Errorf("%s: banned overclaim %q present in %q", label, p, s)
	}
}

func narrativeStrings(n L3CoverageNarrative) map[string]string {
	return map[string]string{
		"Scope":      n.Scope,
		"Evidence":   n.Evidence,
		"Composed":   n.Composed,
		"Diagnostic": n.Diagnostic,
		"Ceiling":    n.Ceiling,
	}
}

// ---------------------------------------------------------------------------
// (i) scope present + granted, evidence present + passed.
// ---------------------------------------------------------------------------

func TestL3Narrative_ScopeAndEvidencePassed(t *testing.T) {
	t.Parallel()
	ev := mustEvidence(t, "passed")
	ev.ComposedGreen = true
	ev.ComposedReason = "scope_and_recall_satisfied"
	scope := testutil.L3ScopeGranted([]string{"messages[0].content", "messages[1].content"}, nil)

	n := BuildL3CoverageNarrative(scope, ev)

	if !strings.Contains(n.Scope, "The deep shield covered 2 of 2 fields eligible for it") {
		t.Errorf("scope line missing the covered/eligible count: %q", n.Scope)
	}
	if !strings.Contains(n.Scope, "no field was excluded by policy") {
		t.Errorf("scope line missing the exclusion ledger: %q", n.Scope)
	}
	if !strings.Contains(n.Scope, "Scope check: granted") {
		t.Errorf("scope line missing the grant verdict: %q", n.Scope)
	}
	// Marc lock 4 wording, verbatim shape: the CHECK passed, K/K probes.
	if !strings.Contains(n.Evidence, "Coverage evidence check passed (16/16 probes recovered) across 2 field(s).") {
		t.Errorf("evidence line is not the lock-4 wording: %q", n.Evidence)
	}
	if !strings.Contains(n.Composed, "GRANTED") {
		t.Errorf("composed line should report GRANTED: %q", n.Composed)
	}
	if n.Diagnostic != L3CoverageDiagnosticOnly {
		t.Errorf("diagnostic note must be present while the records drive nothing; got %q", n.Diagnostic)
	}
	if n.Ceiling != L3CoverageCeiling {
		t.Errorf("ceiling must be carried verbatim; got %q", n.Ceiling)
	}
	for label, s := range narrativeStrings(n) {
		assertNoBannedPhrase(t, label, s)
	}
}

// ---------------------------------------------------------------------------
// (ii) evidence FAILED — a measured recall miss.
// ---------------------------------------------------------------------------

func TestL3Narrative_EvidenceFailed(t *testing.T) {
	t.Parallel()
	ev := mustEvidence(t, "failed")
	ev.ComposedGreen = false
	ev.ComposedReason = "evidence_failed"
	scope := testutil.L3ScopeGranted([]string{"messages[0].content", "messages[1].content"}, nil)

	n := BuildL3CoverageNarrative(scope, ev)

	if ev.GetRollup() != "failed" {
		t.Fatalf("fixture rollup: got %q want failed", ev.GetRollup())
	}
	if !strings.Contains(n.Evidence, "Coverage evidence check FAILED - 1 field(s) returned fewer planted probes than required") {
		t.Errorf("evidence line must report the measured miss: %q", n.Evidence)
	}
	if !strings.Contains(n.Evidence, "(13/16 recovered across the request; 1 field(s) passed, 0 carry no evidence)") {
		t.Errorf("evidence line must carry the producer's counts: %q", n.Evidence)
	}
	if !strings.Contains(n.Evidence, "A measured miss is positive evidence of a recall gap.") {
		t.Errorf("evidence line must say what a miss means: %q", n.Evidence)
	}
	if !strings.Contains(n.Composed, "NOT granted") ||
		!strings.Contains(n.Composed, "a recall check on one field MISSED") {
		t.Errorf("composed line must refuse and say why: %q", n.Composed)
	}
	if n.Ceiling != L3CoverageCeiling {
		t.Errorf("ceiling must be carried on a FAILED render too; got %q", n.Ceiling)
	}
	for label, s := range narrativeStrings(n) {
		assertNoBannedPhrase(t, label, s)
	}
}

// ---------------------------------------------------------------------------
// (iii) BOTH records absent — every pre-T-617/T-600 certificate.
// ---------------------------------------------------------------------------

func TestL3Narrative_BothRecordsAbsent(t *testing.T) {
	t.Parallel()
	n := BuildL3CoverageNarrative(nil, nil)

	if !strings.HasPrefix(n.Scope, "Coverage scope unavailable -") {
		t.Errorf("absent scope must render as unavailable: %q", n.Scope)
	}
	if !strings.Contains(n.Scope, "This is NOT a statement that nothing was excluded or that every field was covered.") {
		t.Errorf("absent scope must refuse the innocence reading: %q", n.Scope)
	}
	if !strings.HasPrefix(n.Evidence, "Recall evidence unavailable -") {
		t.Errorf("absent evidence must render as unavailable: %q", n.Evidence)
	}
	if !strings.Contains(n.Evidence, "This is NOT a statement that the scan was clean.") {
		t.Errorf("absent evidence must refuse the innocence reading: %q", n.Evidence)
	}
	if n.Composed != "" {
		t.Errorf("nothing was composed over an absent record; got %q", n.Composed)
	}
	if n.ScopeStatus != "absent" || n.EvidenceStatus != "absent" {
		t.Errorf("nil records must report status absent; got scope=%q evidence=%q", n.ScopeStatus, n.EvidenceStatus)
	}
	if n.Ceiling != L3CoverageCeiling {
		t.Errorf("ceiling must be carried on an ABSENT render too; got %q", n.Ceiling)
	}
	for label, s := range narrativeStrings(n) {
		assertNoBannedPhrase(t, label, s)
	}
}

// TestL3Narrative_AbsentIsNotTheSameAsNotChecked pins the distinction the
// upstream proto refuses to collapse: a record that was never examined (the
// chain did not authenticate) must not read like a record that was not there.
func TestL3Narrative_AbsentIsNotTheSameAsNotChecked(t *testing.T) {
	t.Parallel()
	absent := BuildL3CoverageNarrative(nil, nil)
	notChecked := BuildL3CoverageNarrative(
		&witnesspb.L3CoverageScope{RecordStatus: "not_checked"},
		&witnesspb.L3CoverageEvidence{RecordStatus: "not_checked"},
	)
	if absent.Scope == notChecked.Scope {
		t.Errorf("absent and not_checked scope must not render identically: %q", absent.Scope)
	}
	if !strings.Contains(notChecked.Scope, "did not authenticate") {
		t.Errorf("not_checked scope must name the authentication failure: %q", notChecked.Scope)
	}
	for label, s := range narrativeStrings(notChecked) {
		assertNoBannedPhrase(t, label, s)
	}
}

// ---------------------------------------------------------------------------
// (iv) receipt-covered — the reason that fires MORE as caching succeeds.
// ---------------------------------------------------------------------------

func TestL3Narrative_ReceiptCoveredEvidenceNotInChain(t *testing.T) {
	t.Parallel()
	// One field freshly scanned, one covered by a named receipt from an
	// earlier turn — so no inference ran on those bytes this turn and no
	// recall evidence for them exists on THIS certificate.
	scope := &witnesspb.L3CoverageScope{
		RecordStatus:      "present",
		DerivationVersion: "t617-scope-v1",
		Granted:           true,
		Reason:            "all_eligible_fields_covered",
		EligibleCount:     2,
		Covered: []*witnesspb.L3CoveredField{
			{FieldKey: "messages[0].content", Via: "scan"},
			{
				FieldKey:      "messages[1].content",
				Via:           "receipt",
				ReceiptId:     "rcpt_9f2c1a",
				SourceClaimId: "clm_0d41ba",
			},
		},
	}
	ev := mustEvidence(t, "partial")
	ev.ComposedGreen = false
	ev.ComposedReason = "receipt_covered_evidence_not_in_chain"

	n := BuildL3CoverageNarrative(scope, ev)

	if !strings.Contains(n.Scope, "(1 by a fresh scan this turn, 1 by a named receipt from an earlier turn)") {
		t.Errorf("scope line must separate fresh scans from receipt reuse: %q", n.Scope)
	}
	if !strings.Contains(n.Composed, "NOT granted") ||
		!strings.Contains(n.Composed, "covered by a NAMED RECEIPT from an earlier turn") {
		t.Errorf("composed line must name the receipt reason: %q", n.Composed)
	}
	// ⛔ DISCLOSURE BOUNDARY: the receipt id and the source claim id are in
	// the record but must never reach the page.
	for label, s := range narrativeStrings(n) {
		if strings.Contains(s, "rcpt_9f2c1a") || strings.Contains(s, "clm_0d41ba") {
			t.Errorf("%s leaks a receipt/source-claim id: %q", label, s)
		}
		if strings.Contains(s, "messages[0].content") || strings.Contains(s, "messages[1].content") {
			t.Errorf("%s leaks a field key: %q", label, s)
		}
		assertNoBannedPhrase(t, label, s)
	}
}

// ---------------------------------------------------------------------------
// Cross-cutting guards.
// ---------------------------------------------------------------------------

// TestL3CoverageNarrative_NeverClaimsCompleteDetection sweeps every branch the
// builder can take — all record statuses, all rollups, every closed-vocabulary
// reason on both records — and asserts (a) no banned overclaim is reachable and
// (b) the ceiling is carried on every single render.
func TestL3CoverageNarrative_NeverClaimsCompleteDetection(t *testing.T) {
	t.Parallel()
	statuses := []string{"", "present", "absent", "malformed", "unsupported_derivation", "not_checked", "weird_new_token"}
	rollups := []string{"", "verified", "failed", "unverified", "absent", "weird_new_rollup"}
	scopeReasons := []string{"", "all_eligible_fields_covered", "no_eligible_field", "eligible_field_not_covered", "unattributed_degrade", "weird_new_reason"}
	composedReasons := []string{
		"", "scope_and_recall_satisfied", "scope_unavailable", "evidence_unavailable",
		"evidence_failed", "scope_not_granted", "evidence_absent_for_covered_field",
		"evidence_on_excluded_field", "receipt_covered_evidence_not_in_chain", "weird_new_composed",
	}
	absentReasons := []string{
		"", "probe_off", "no_l3_window", "window_below_probe_floor",
		"window_served_from_verdict_cache", "output_headroom_clipped",
		"no_prompt_assembly_seam", "weird_new_absent_reason",
	}
	exclusionReasons := []string{
		"", "l3_not_configured", "caller_skipped", "shallow_zone_bypasses_l3",
		"zone_policy_skip", "weird_new_exclusion",
	}

	renders := 0
	sweep := func(scope *witnesspb.L3CoverageScope, ev *witnesspb.L3CoverageEvidence, label string) {
		t.Helper()
		n := BuildL3CoverageNarrative(scope, ev)
		renders++
		if n.Ceiling != L3CoverageCeiling {
			t.Fatalf("%s: ceiling dropped", label)
		}
		if n.Scope == "" || n.Evidence == "" {
			t.Fatalf("%s: empty narrative half", label)
		}
		for field, str := range narrativeStrings(n) {
			assertNoBannedPhrase(t, label+"/"+field, str)
			if strings.Contains(str, "rcpt_x") || strings.Contains(str, "clm_x") ||
				strings.Contains(str, "messages[") || strings.Contains(str, "operator_note") {
				t.Fatalf("%s/%s leaked a field key / receipt id / zone name: %q", label, field, str)
			}
		}
	}

	newScope := func(status, reason, exclusionReason string) *witnesspb.L3CoverageScope {
		return &witnesspb.L3CoverageScope{
			RecordStatus:  status,
			Granted:       reason == "all_eligible_fields_covered",
			Reason:        reason,
			EligibleCount: 2,
			Covered: []*witnesspb.L3CoveredField{
				{FieldKey: "messages[0].content", Via: "scan"},
				{FieldKey: "messages[1].content", Via: "receipt", ReceiptId: "rcpt_x", SourceClaimId: "clm_x"},
			},
			EligibleNotCovered: []string{"messages[2].content"},
			Excluded: []*witnesspb.L3ExcludedField{
				{FieldKey: "messages[3].content", Zone: "operator_note", Reason: exclusionReason},
			},
		}
	}
	newEvidence := func(status, rollup, composedReason, absentReason string) *witnesspb.L3CoverageEvidence {
		return &witnesspb.L3CoverageEvidence{
			RecordStatus:      status,
			DerivationVersion: "t600-evidence-v1",
			Rollup:            rollup,
			ComposedGreen:     composedReason == "scope_and_recall_satisfied",
			ComposedReason:    composedReason,
			CanariesPlanted:   16,
			CanariesRecovered: 12,
			FieldsPassed:      1,
			FieldsFailed:      1,
			FieldsAbsent:      1,
			Fields: []*witnesspb.L3FieldEvidence{
				{FieldKey: "messages[0].content", Verdict: "passed", CanariesPlanted: 8, CanariesRecovered: 8, Windows: 2, ProbedWindows: 2},
				{FieldKey: "messages[1].content", Verdict: "failed", CanariesPlanted: 8, CanariesRecovered: 4, Windows: 2, ProbedWindows: 2},
				{FieldKey: "messages[2].content", Verdict: "absent", Reason: absentReason, Windows: 1},
			},
		}
	}

	// Every SCOPE branch against a present evidence record, and every
	// EVIDENCE branch against a present scope record. Each dimension is
	// swept independently — the two halves are rendered by separate
	// functions that share no state, so a full cross-product would add
	// runtime without adding a reachable branch.
	for _, ss := range statuses {
		for _, sr := range scopeReasons {
			for _, xr := range exclusionReasons {
				sweep(newScope(ss, sr, xr),
					newEvidence("present", "verified", "scope_and_recall_satisfied", ""),
					"scope["+ss+"/"+sr+"/"+xr+"]")
			}
		}
	}
	for _, es := range statuses {
		for _, ru := range rollups {
			for _, cr := range composedReasons {
				for _, ar := range absentReasons {
					sweep(newScope("present", "all_eligible_fields_covered", "zone_policy_skip"),
						newEvidence(es, ru, cr, ar),
						"evidence["+es+"/"+ru+"/"+cr+"/"+ar+"]")
				}
			}
		}
	}
	// Both halves nil (the pre-T-617/T-600 certificate) and the mixed
	// nil/present pairs, which take a different branch than an explicit
	// "absent" status.
	sweep(nil, nil, "nil/nil")
	sweep(newScope("present", "all_eligible_fields_covered", "zone_policy_skip"), nil, "present/nil")
	sweep(nil, newEvidence("present", "verified", "scope_and_recall_satisfied", ""), "nil/present")

	if renders == 0 {
		t.Fatal("matrix rendered nothing — the sweep is vacuous")
	}
	t.Logf("swept %d narrative renders", renders)
}

// TestL3CoverageNarrative_BannedPhraseGuardIsNotVacuous is the mutation control
// for the guard above: a string that DOES overclaim must be caught. Without it
// a typo in bannedClaimPhrases would leave every assertion passing silently.
func TestL3CoverageNarrative_BannedPhraseGuardIsNotVacuous(t *testing.T) {
	t.Parallel()
	for _, p := range bannedClaimPhrases {
		probe := &testing.T{}
		assertNoBannedPhrase(probe, "mutation-probe", "Coverage: "+strings.ToUpper(p)+" in this request.")
		if !probe.Failed() {
			t.Errorf("banned phrase %q did not trip the guard", p)
		}
	}
}

// TestL3CompletenessWithCaveat_BareWordIsGone pins the T-600 success criterion
// that the bare verdict word is never the whole string.
func TestL3CompletenessWithCaveat_BareWordIsGone(t *testing.T) {
	t.Parallel()
	for _, c := range []struct{ in, wantWord string }{
		{"full", "Full"},
		{"partial", "Partial"},
		{"", "Unspecified"},
	} {
		got := L3CompletenessWithCaveat(c.in)
		if got == c.wantWord || got == c.in {
			t.Errorf("L3CompletenessWithCaveat(%q) = %q — the bare word is the defect", c.in, got)
		}
		if !strings.HasPrefix(got, c.wantWord+" - ") {
			t.Errorf("L3CompletenessWithCaveat(%q) = %q, want prefix %q", c.in, got, c.wantWord+" - ")
		}
		if !strings.Contains(got, L3CompletenessMeaning) {
			t.Errorf("L3CompletenessWithCaveat(%q) dropped the caveat: %q", c.in, got)
		}
		assertNoBannedPhrase(t, "completeness", got)
	}
}

// mustEvidence builds a witness-shaped evidence record from the upstream
// producer corpus, failing the test rather than returning an error.
func mustEvidence(t *testing.T, scenario string) *witnesspb.L3CoverageEvidence {
	t.Helper()
	ev, err := testutil.L3EvidenceFromProducer(scenario)
	if err != nil {
		t.Fatalf("producer fixture %q: %v", scenario, err)
	}
	return ev
}
