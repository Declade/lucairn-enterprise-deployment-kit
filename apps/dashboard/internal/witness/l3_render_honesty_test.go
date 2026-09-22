package witness

import (
	"bytes"
	"fmt"
	"html/template"
	"strings"
	"testing"

	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
)

// ---------------------------------------------------------------------------
// Round-2 gate: the render may not say more than its own numbers support.
// ---------------------------------------------------------------------------
//
// These are the kit's copies of the upstream round-2 proofs
// (dual-sandbox-architecture @ db096f5d, veil_l3_coverage_render_test.go).
// They exist here and not only upstream because the kit ships its OWN copy of
// the wording: the first cut of this file was taken from an upstream working
// tree minutes before the overclaim below was fixed there, and nothing in the
// kit would have noticed.
//
// ⚑ WHY A PHRASE DENYLIST IS NOT ENOUGH. TestL3CoverageNarrative_
// NeverClaimsCompleteDetection bans twelve known overclaims; a novel one
// ("no personal data escaped the deep shield") sails straight through it,
// because a denylist can only refuse sentences somebody already thought of.
// The tests below are NEGATIVE-SHAPE instead: every evidence line must carry
// the counts it is about, and the strong clause may never stand beside counts
// that contradict it. An overclaim then has to lie about NUMBERS to pass,
// which is a much harder thing to do by accident.

// caseHonestSubThresholdPass is an HONEST K=4 / threshold=3 record: the field
// passed, and 3 of 4 planted probes came back.
//
// ⚑ NOT FROM THE PRODUCER CORPUS, deliberately. The upstream corpus
// (internal/testutil/testdata) was generated at threshold == K, so it contains
// no sub-threshold pass at all — which is exactly why the overclaim survived
// every fixture the first cut of this PR had. The threshold is a legal
// configuration anywhere in [1, K] (services/sanitizer/l3_evidence_probe.py
// ProbeConfig.armed), so this shape is producible today; it is constructed
// here rather than mined from a corpus that cannot express it.
func caseHonestSubThresholdPass() *witnesspb.L3CoverageEvidence {
	return &witnesspb.L3CoverageEvidence{
		RecordStatus:      "present",
		DerivationVersion: "t600-evidence-v1",
		Rollup:            "verified",
		ComposedGreen:     true,
		ComposedReason:    "scope_and_recall_satisfied",
		Fields: []*witnesspb.L3FieldEvidence{
			{FieldKey: "messages[0].content", Verdict: "passed", CanariesPlanted: 4, CanariesRecovered: 3, Windows: 1, ProbedWindows: 1},
		},
		CanariesPlanted:   4,
		CanariesRecovered: 3,
		FieldsPassed:      1,
	}
}

// caseForgedThinPass is the OTHER sub-threshold shape: 8 planted across 2
// probed windows with only 2 recovered. It sits exactly ON the witness's
// threshold-independent floor (recovered >= probed_windows), so the witness
// ADMITS it — which is precisely why the RENDER must not describe it as
// "every planted probe came back".
func caseForgedThinPass() *witnesspb.L3CoverageEvidence {
	return &witnesspb.L3CoverageEvidence{
		RecordStatus:      "present",
		DerivationVersion: "t600-evidence-v1",
		Rollup:            "verified",
		Fields: []*witnesspb.L3FieldEvidence{
			{FieldKey: "messages[0].content", Verdict: "passed", CanariesPlanted: 8, CanariesRecovered: 2, Windows: 2, ProbedWindows: 2},
		},
		CanariesPlanted:   8,
		CanariesRecovered: 2,
		FieldsPassed:      1,
	}
}

// TestL3CoverageEvidenceLine_StrongClauseRequiresFullRecovery is the H1
// RED-PROOF: the sentence after the counts may only claim every planted probe
// came back when the counts say so.
//
// MUTATION KILL: make the clause unconditional (the shape that shipped at
// c0750c2) and the two sub-threshold subtests go RED on a rendered string that
// contradicts its own numbers.
func TestL3CoverageEvidenceLine_StrongClauseRequiresFullRecovery(t *testing.T) {
	t.Parallel()
	const strong = "every planted probe came back"
	const weak = "every probed window met the recall threshold in force"

	passed := mustEvidence(t, "passed")

	cases := []struct {
		name       string
		ev         *witnesspb.L3CoverageEvidence
		wantStrong bool
		wantCounts string
	}{
		{"full recovery earns the strong clause", passed, true, "(16/16 probes recovered)"},
		{"honest K=4 threshold=3 does not", caseHonestSubThresholdPass(), false, "(3/4 probes recovered)"},
		{"thin pass on the witness floor does not", caseForgedThinPass(), false, "(2/8 probes recovered)"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			line := buildL3EvidenceLine(tc.ev, "present")
			if !strings.Contains(line, tc.wantCounts) {
				t.Fatalf("counts %q missing from %q", tc.wantCounts, line)
			}
			hasStrong := strings.Contains(line, strong)
			if hasStrong != tc.wantStrong {
				t.Errorf("strong clause present = %v, want %v.\nline: %s", hasStrong, tc.wantStrong, line)
			}
			if !tc.wantStrong && !strings.Contains(line, weak) {
				t.Errorf("sub-threshold pass did not carry the threshold-safe clause.\nline: %s", line)
			}
			// THE INVARIANT, independent of which branch ran: the strong
			// clause may never stand next to counts that contradict it.
			if hasStrong && tc.ev.GetCanariesRecovered() != tc.ev.GetCanariesPlanted() {
				t.Errorf("render asserts %q while its own counts say %d of %d",
					strong, tc.ev.GetCanariesRecovered(), tc.ev.GetCanariesPlanted())
			}
		})
	}
}

// TestL3CoverageEvidenceLine_AbsentRollupDoesNotDenyThePlant is the second
// round-2 RED-PROOF. A field whose windows were only PARTLY probed is `absent`
// with canaries_planted > 0, so "no field carried a recall probe" was a false
// sentence about a real, producible record.
//
// MUTATION KILL: restore that sentence and this goes RED.
func TestL3CoverageEvidenceLine_AbsentRollupDoesNotDenyThePlant(t *testing.T) {
	t.Parallel()
	ev := &witnesspb.L3CoverageEvidence{
		RecordStatus: "present",
		Rollup:       "absent",
		Fields: []*witnesspb.L3FieldEvidence{
			// Probes WERE planted; the field is absent because a window went
			// unprobed, not because nothing was planted.
			{FieldKey: "messages[0].content", Verdict: "absent", Reason: "window_below_probe_floor",
				CanariesPlanted: 4, CanariesRecovered: 4, Windows: 2, ProbedWindows: 1},
		},
		CanariesPlanted:   4,
		CanariesRecovered: 4,
		FieldsAbsent:      1,
	}
	line := buildL3EvidenceLine(ev, "present")
	if strings.Contains(line, "no field carried a recall probe") {
		t.Errorf("absent rollup denies a plant that the record itself reports (%d planted).\nline: %s",
			ev.GetCanariesPlanted(), line)
	}
	if !strings.Contains(line, "usable recall-evidence verdict") {
		t.Errorf("absent rollup does not say what absent means.\nline: %s", line)
	}
}

// evidenceGrid is every evidence shape the property tests below sweep: the
// producer corpus (real shapes) plus the two sub-threshold shapes the corpus
// cannot express.
func evidenceGrid(t *testing.T) map[string]*witnesspb.L3CoverageEvidence {
	t.Helper()
	out := map[string]*witnesspb.L3CoverageEvidence{
		"sub_threshold_honest": caseHonestSubThresholdPass(),
		"sub_threshold_thin":   caseForgedThinPass(),
	}
	for _, scenario := range []string{
		"passed", "failed", "mixed", "partial", "probe_off",
		"absent_cached", "absent_below_floor", "absent_no_window",
		"absent_headroom_clipped", "absent_no_prompt_seam", "empty",
	} {
		out[scenario] = mustEvidence(t, scenario)
	}
	return out
}

// TestL3EvidenceLine_AlwaysCarriesItsCounts is the NEGATIVE-SHAPE guard: a
// present evidence record that reports ANY probe activity must render the
// numbers it is talking about. A sentence with no numbers is exactly the shape
// an overclaim takes — "the deep shield found everything" needs no counts, and
// a denylist of phrases is blind to the one nobody wrote down yet.
//
// MUTATION KILL: drop the count arguments from any Fprintf branch, or replace
// a branch with a bare reassurance, and this goes RED.
func TestL3EvidenceLine_AlwaysCarriesItsCounts(t *testing.T) {
	t.Parallel()
	for name, ev := range evidenceGrid(t) {
		t.Run(name, func(t *testing.T) {
			line := buildL3EvidenceLine(ev, "present")
			if line == "" {
				t.Fatal("present record rendered an empty evidence line")
			}
			if ev.GetCanariesPlanted() == 0 && ev.GetFieldsPassed() == 0 {
				// Nothing was probed and nothing passed: the honest line names
				// no counts, and must instead say the verdict is unusable.
				if !strings.Contains(line, "usable recall-evidence verdict") {
					t.Errorf("record with no probe activity must say so, got: %s", line)
				}
				return
			}
			want := fmt.Sprintf("%d/%d", ev.GetCanariesRecovered(), ev.GetCanariesPlanted())
			if !strings.Contains(line, want) {
				t.Errorf("evidence line omits the counts it is about (want %q): %s", want, line)
			}
		})
	}
}

// TestL3EvidenceLine_StrongClauseNeverBesideContradictingCounts is the same
// invariant as a property over the whole grid rather than three hand-picked
// cases — a future branch added to buildL3EvidenceLine is covered the moment
// its shape enters the grid.
func TestL3EvidenceLine_StrongClauseNeverBesideContradictingCounts(t *testing.T) {
	t.Parallel()
	const strong = "every planted probe came back"
	checked := 0
	for name, ev := range evidenceGrid(t) {
		line := buildL3EvidenceLine(ev, "present")
		checked++
		if !strings.Contains(line, strong) {
			continue
		}
		if ev.GetCanariesRecovered() != ev.GetCanariesPlanted() || ev.GetCanariesPlanted() == 0 {
			t.Errorf("%s: render asserts %q while its own counts say %d of %d.\nline: %s",
				name, strong, ev.GetCanariesRecovered(), ev.GetCanariesPlanted(), line)
		}
	}
	if checked == 0 {
		t.Fatal("grid was empty — the property is vacuous")
	}
}

// TestL3EvidenceLine_CountPropertyIsNotVacuous is the mutation control for the
// two properties above: a deliberately overclaiming renderer must be caught by
// the same assertions, otherwise a typo in them would leave everything GREEN.
func TestL3EvidenceLine_CountPropertyIsNotVacuous(t *testing.T) {
	t.Parallel()
	// The exact defect that shipped at c0750c2, reconstructed: the strong
	// clause, unconditional, beside sub-threshold counts.
	overclaim := func(ev *witnesspb.L3CoverageEvidence) string {
		return fmt.Sprintf("Coverage evidence check passed (%d/%d probes recovered). "+
			"That means the recall CHECK ran on every field carrying one and every planted probe came back.",
			ev.GetCanariesRecovered(), ev.GetCanariesPlanted())
	}
	ev := caseHonestSubThresholdPass()
	line := overclaim(ev)
	if !strings.Contains(line, "every planted probe came back") {
		t.Fatal("the reconstructed defect does not carry the strong clause — the control is wrong")
	}
	if ev.GetCanariesRecovered() == ev.GetCanariesPlanted() {
		t.Fatal("the control fixture is not sub-threshold")
	}
	// The real renderer must NOT produce that string for this record.
	if real := buildL3EvidenceLine(ev, "present"); strings.Contains(real, "every planted probe came back") {
		t.Errorf("the shipped renderer reproduces the defect: %s", real)
	}
}

// TestL3Quote_SurvivesHTMLEscaping is the quoting RED-PROOF at the unit level.
//
// MUTATION KILL: return `"` + s + `"` and this goes RED on the escapable
// character check.
func TestL3Quote_SurvivesHTMLEscaping(t *testing.T) {
	t.Parallel()
	got := l3Quote("some_future_token")
	if strings.ContainsAny(got, "'\"<>&") {
		t.Errorf("l3Quote(%q) = %q contains a character html/template escapes, so the line "+
			"carrying it cannot be grepped out of the served page", "some_future_token", got)
	}
	if !strings.Contains(got, "some_future_token") {
		t.Errorf("l3Quote dropped the token: %q", got)
	}
}

// narrativeGrid sweeps every narrative the builder can produce over the
// evidence grid plus the scope shapes that matter, INCLUDING out-of-vocabulary
// tokens — the only path that reaches l3Quote, and the path the first cut of
// this PR never exercised.
func narrativeGrid(t *testing.T) map[string]L3CoverageNarrative {
	t.Helper()
	out := map[string]L3CoverageNarrative{}
	scope := scopeForGrid()
	for name, ev := range evidenceGrid(t) {
		out["present/"+name] = BuildL3CoverageNarrative(scope, ev)
	}
	out["absent/absent"] = BuildL3CoverageNarrative(nil, nil)
	out["not_checked"] = BuildL3CoverageNarrative(
		&witnesspb.L3CoverageScope{RecordStatus: "not_checked"},
		&witnesspb.L3CoverageEvidence{RecordStatus: "not_checked"},
	)
	// Out-of-vocabulary everything: drives l3Quote on the real render path.
	out["unknown_vocabulary"] = BuildL3CoverageNarrative(
		&witnesspb.L3CoverageScope{
			RecordStatus:       "present",
			Reason:             "some_future_denial_reason",
			EligibleCount:      1,
			EligibleNotCovered: []string{"messages[0].content"},
			Excluded: []*witnesspb.L3ExcludedField{
				{FieldKey: "x", Zone: "z", Reason: "some_future_exclusion_reason"},
			},
		},
		&witnesspb.L3CoverageEvidence{
			RecordStatus:   "present",
			Rollup:         "some_future_rollup",
			ComposedReason: "some_future_composed_reason",
		},
	)
	out["unknown_status"] = BuildL3CoverageNarrative(
		&witnesspb.L3CoverageScope{RecordStatus: "some_future_status"},
		&witnesspb.L3CoverageEvidence{RecordStatus: "some_future_status"},
	)
	return out
}

func scopeForGrid() *witnesspb.L3CoverageScope {
	return &witnesspb.L3CoverageScope{
		RecordStatus:  "present",
		Granted:       true,
		Reason:        "all_eligible_fields_covered",
		EligibleCount: 2,
		Covered: []*witnesspb.L3CoveredField{
			{FieldKey: "messages[0].content", Via: "scan"},
			{FieldKey: "messages[1].content", Via: "receipt", ReceiptId: "rcpt_x", SourceClaimId: "clm_x"},
		},
		Excluded: []*witnesspb.L3ExcludedField{
			{FieldKey: "messages[2].content", Zone: "operator_note", Reason: "zone_policy_skip"},
		},
	}
}

// TestL3CoverageNarrative_IsGreppableInServedHTML renders every narrative line
// through html/template — the same package the inspector uses — and asserts
// the served bytes still contain the line verbatim.
//
// ⛔ THIS IS THE ONE THAT CATCHES A QUOTE OR AN APOSTROPHE. html/template
// escapes ' " < > &, so a caveat written with one is on the page but invisible
// to the T-600 PRD's grep-verifiable success criterion and to any operator
// grepping the served HTML.
//
// MUTATION KILL: put an apostrophe back into any rendered string, or make
// l3Quote use quote marks, and this goes RED.
func TestL3CoverageNarrative_IsGreppableInServedHTML(t *testing.T) {
	t.Parallel()
	tmpl := template.Must(template.New("cell").Parse(`<span>{{ . }}</span>`))
	for name, n := range narrativeGrid(t) {
		t.Run(name, func(t *testing.T) {
			for label, line := range map[string]string{
				"Scope": n.Scope, "Evidence": n.Evidence, "Composed": n.Composed,
				"Diagnostic": n.Diagnostic, "Ceiling": n.Ceiling,
			} {
				if line == "" {
					continue
				}
				if strings.ContainsAny(line, "'\"<>&") {
					t.Errorf("narrative.%s contains an HTML-escapable character, so it cannot be grepped "+
						"out of the served page: %q", label, line)
				}
				var buf bytes.Buffer
				if err := tmpl.Execute(&buf, line); err != nil {
					t.Fatalf("render: %v", err)
				}
				if !strings.Contains(buf.String(), line) {
					t.Errorf("narrative.%s is not greppable verbatim in the served HTML: %q -> %q",
						label, line, buf.String())
				}
			}
		})
	}
}

// TestL3CoverageNarrative_IsASCIIOnly pins the ASCII rule that keeps the kit
// byte-identical to the upstream wording (and keeps a future kit PDF or CSV
// export from inheriting mojibake).
//
// MUTATION KILL: put an em dash or a multiplication sign back into any
// rendered string and this goes RED, naming the rune.
func TestL3CoverageNarrative_IsASCIIOnly(t *testing.T) {
	t.Parallel()
	check := func(t *testing.T, where, s string) {
		t.Helper()
		for i, r := range s {
			if r > 127 {
				t.Errorf("%s carries non-ASCII rune %q (U+%04X) at byte %d: %q", where, r, r, i, s)
				return
			}
		}
	}
	for name, s := range map[string]string{
		"L3CoverageCeiling":        L3CoverageCeiling,
		"L3CoverageDiagnosticOnly": L3CoverageDiagnosticOnly,
		"L3CompletenessMeaning":    L3CompletenessMeaning,
	} {
		check(t, "constant "+name, s)
	}
	for _, c := range []string{"full", "partial", ""} {
		check(t, "L3CompletenessWithCaveat("+c+")", L3CompletenessWithCaveat(c))
	}
	for name, n := range narrativeGrid(t) {
		check(t, name+"/Scope", n.Scope)
		check(t, name+"/Evidence", n.Evidence)
		check(t, name+"/Composed", n.Composed)
		check(t, name+"/Diagnostic", n.Diagnostic)
		check(t, name+"/Ceiling", n.Ceiling)
	}
}
