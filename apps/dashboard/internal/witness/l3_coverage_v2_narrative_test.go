package witness

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
	"strconv"
	"strings"
	"testing"

	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
)

func l3GatewaySource(t *testing.T, path string) *ast.File {
	t.Helper()
	f, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func l3GatewayFunction(t *testing.T, file *ast.File, name string) *ast.FuncDecl {
	t.Helper()
	for _, decl := range file.Decls {
		if fn, ok := decl.(*ast.FuncDecl); ok && fn.Name.Name == name {
			return fn
		}
	}
	t.Fatalf("missing gateway parity function %s", name)
	return nil
}

func l3GatewayString(expr ast.Expr) string {
	switch e := expr.(type) {
	case *ast.BasicLit:
		if e.Kind == token.STRING {
			s, _ := strconv.Unquote(e.Value)
			return s
		}
	case *ast.BinaryExpr:
		if e.Op == token.ADD {
			return l3GatewayString(e.X) + l3GatewayString(e.Y)
		}
	}
	return ""
}

const l3GatewayFixture = "testdata/l3_gateway_53cf109b.go.txt"

func l3GatewayOutcomePhrases(t *testing.T) map[string]string {
	t.Helper()
	fn := l3GatewayFunction(t, l3GatewaySource(t, l3GatewayFixture), "l3RecallReasonMeaning")
	out := map[string]string{}
	ast.Inspect(fn, func(n ast.Node) bool {
		if c, ok := n.(*ast.CaseClause); ok && len(c.List) == 1 {
			out[l3GatewayString(c.List[0])] = l3GatewayString(c.Body[0].(*ast.ReturnStmt).Results[0])
		}
		return true
	})
	if len(out) != 24 {
		t.Fatalf("gateway outcome count: got %d, want 24", len(out))
	}
	return out
}

func l3GatewayFormat(t *testing.T, name, prefix string) string {
	t.Helper()
	fn := l3GatewayFunction(t, l3GatewaySource(t, l3GatewayFixture), name)
	var format string
	ast.Inspect(fn, func(n ast.Node) bool {
		if call, ok := n.(*ast.CallExpr); ok && len(call.Args) > 0 {
			if s := l3GatewayString(call.Args[0]); strings.HasPrefix(s, prefix) {
				format = s
			}
		}
		return true
	})
	if format == "" {
		t.Fatalf("missing gateway format %q", prefix)
	}
	return format
}

// RED-PROOF: unchanged reader failed parity; deliberate outcome, field-phrase and label mutations failed three parity subtests; restored.
func TestL3V2Render_GatewayParity(t *testing.T) {
	fixture := l3GatewaySource(t, l3GatewayFixture)
	reader := l3GatewaySource(t, "l3_coverage_narrative.go")
	for _, name := range []string{
		"l3RecallReasonMeaning", "l3EvidenceAbsentReasonMeaning", "l3ComposedReasonMeaning",
		"l3CheckedWindowsPhrase", "buildL3ComposedLine",
	} {
		t.Run(name, func(t *testing.T) {
			var want, got bytes.Buffer
			for _, entry := range []struct {
				buf  *bytes.Buffer
				file *ast.File
			}{{&want, fixture}, {&got, reader}} {
				if err := printer.Fprint(entry.buf, token.NewFileSet(), l3GatewayFunction(t, entry.file, name).Body); err != nil {
					t.Fatal(err)
				}
			}
			if got.String() != want.String() {
				t.Errorf("%s differs from gateway 53cf109b", name)
			}
		})
	}
	for _, decl := range fixture.Decls {
		if gen, ok := decl.(*ast.GenDecl); ok && gen.Tok == token.CONST {
			for _, spec := range gen.Specs {
				v := spec.(*ast.ValueSpec)
				want := l3GatewayString(v.Values[0])
				var ev *witnesspb.L3CoverageEvidence
				if v.Names[0].Name == "l3RecallDiagnosticOnly" {
					_, ev = caseL3V2ShortAndPassed()
				}
				if got := BuildL3CoverageNarrative(nil, ev).Diagnostic; got != want {
					t.Errorf("%s: got %q, want %q", v.Names[0], got, want)
				}
			}
		}
	}
}

// RED-PROOF: unchanged reader failed all five rollups; scan_disabled plus verified printed a passed sentence (D1).
func TestL3V2Render_NoLegacyEvidence(t *testing.T) {
	for _, rollup := range []string{"verified", "failed", "unverified", "absent", "synthetic-unknown"} {
		t.Run(rollup, func(t *testing.T) {
			scope, ev := caseL3V2ShortAndPassed()
			ev.Rollup, ev.ComposedGreen, ev.ComposedReason = rollup, false, "scan_disabled"
			ev.Fields, ev.FieldsAbsent = ev.Fields[:1], 0
			n := BuildL3CoverageNarrative(scope, ev)
			want := fmt.Sprintf(l3GatewayFormat(t, "buildL3EvidenceLine", "Recall evidence records"), 4, 4, "1 checked text window", "")
			if n.Evidence != want {
				t.Errorf("v2 evidence: %q, want %q", n.Evidence, want)
			}
			if n.Composed != "Recall check not passed - "+l3GatewayOutcomePhrases(t)["scan_disabled"]+"." {
				t.Errorf("denied v2 label: %q", n.Composed)
			}
			if strings.Contains(n.Evidence+" "+n.Composed, "check passed") {
				t.Errorf("D1: denied record has a passed sentence: %+v", n)
			}
		})
	}
}

// RED-PROOF: unchanged reader failed all six version/window cases by echoing outcome or hostile field text.
func TestL3V2Render_UnknownReasons(t *testing.T) {
	const hostile = "synthetic verified all personal data found <b>"
	for _, version := range []string{"", "t600-evidence-v1", "t600-evidence-v2"} {
		for _, windows := range []uint32{0, 1} {
			t.Run(fmt.Sprintf("%s/windows=%d", version, windows), func(t *testing.T) {
				scope, ev := caseL3V2ShortAndPassed()
				ev.DerivationVersion = version
				ev.ComposedGreen, ev.ComposedReason = false, "synthetic-unknown-outcome"
				ev.Fields[1].Reason, ev.Fields[1].Windows = hostile, windows
				ev.Rollup = "absent"
				n := BuildL3CoverageNarrative(scope, ev)
				if n.Composed != "Recall check unavailable." {
					t.Errorf("unknown outcome: %q", n.Composed)
				}
				if !strings.Contains(n.Evidence, "for a reason this build does not recognise") {
					t.Errorf("missing safe field reason: %q", n.Evidence)
				}
				for _, banned := range []string{"verified", "all personal data found", "synthetic-unknown-outcome", hostile} {
					if strings.Contains(n.Evidence+" "+n.Composed, banned) {
						t.Errorf("recall lines expose %q", banned)
					}
				}
				// An unknown field reason must leave the known record outcome readable.
				ev.ComposedReason = "scan_disabled"
				n = BuildL3CoverageNarrative(scope, ev)
				if strings.Contains(n.Composed, "unavailable") {
					t.Errorf("unknown field reason discarded known outcome: %q", n.Composed)
				}
			})
		}
	}
}

// G003: a passed field beside a covered, unchecked below-floor field.
func caseL3V2ShortAndPassed() (*witnesspb.L3CoverageScope, *witnesspb.L3CoverageEvidence) {
	scope := &witnesspb.L3CoverageScope{
		RecordStatus: "present", Granted: true, Reason: "all_eligible_fields_covered", EligibleCount: 2,
		Covered: []*witnesspb.L3CoveredField{
			{FieldKey: "synthetic.passed", Via: "scan"},
			{FieldKey: "synthetic.short", Via: "scan"},
		},
	}
	ev := &witnesspb.L3CoverageEvidence{
		RecordStatus: "present", DerivationVersion: "t600-evidence-v2", Rollup: "unverified",
		ComposedGreen: true, ComposedReason: "scope_and_recall_satisfied",
		CanariesPlanted: 4, CanariesRecovered: 4, FieldsPassed: 1, FieldsAbsent: 1,
		Fields: []*witnesspb.L3FieldEvidence{
			{FieldKey: "synthetic.passed", Verdict: "passed", Windows: 1, ProbedWindows: 1, CanariesPlanted: 4, CanariesRecovered: 4},
			{FieldKey: "synthetic.short", Verdict: "absent", Windows: 1, Reason: "window_below_probe_floor"},
		},
	}
	return scope, ev
}

// RED-PROOF: unchanged reader failed the 23 denial subtests; the granting token is pinned by ShortFieldBesidePass.
func TestL3V2Render_OutcomePhrases(t *testing.T) {
	for reason, phrase := range l3GatewayOutcomePhrases(t) {
		t.Run(reason, func(t *testing.T) {
			if reason == "scope_and_recall_satisfied" {
				return // The granting outcome uses the four sentences pinned below.
			}
			scope, ev := caseL3V2ShortAndPassed()
			ev.ComposedGreen, ev.ComposedReason = false, reason
			line := BuildL3CoverageNarrative(scope, ev).Composed
			if line != "Recall check not passed - "+phrase+"." || strings.Contains(line, reason) {
				t.Errorf("outcome %s: %q; want phrase %q without raw token", reason, line, phrase)
			}
		})
	}
}

// RED-PROOF: unchanged reader emitted GRANTED instead of the four-sentence singular/plural label.
func TestL3V2Render_ShortFieldBesidePass(t *testing.T) {
	scope, ev := caseL3V2ShortAndPassed()
	n := BuildL3CoverageNarrative(scope, ev)
	want := fmt.Sprintf(l3GatewayFormat(t, "buildL3ComposedLine", "Recall check passed:"), 4, 4, "1 checked text window")
	if n.Composed != want {
		t.Errorf("pass wording: %q, want %q", n.Composed, want)
	}
	for _, line := range []string{n.Evidence, n.Composed} {
		for _, phrase := range []string{"every covered field passed", "verified", "signed by the witness"} {
			if strings.Contains(strings.ToLower(line), phrase) {
				t.Errorf("unexpected %q in %q", phrase, line)
			}
		}
	}
	if !strings.Contains(n.Evidence, "at least one window was shorter") {
		t.Errorf("missing short-window reason: %q", n.Evidence)
	}
	if n.Ceiling != L3CoverageCeiling {
		t.Errorf("ceiling changed: %q", n.Ceiling)
	}
	// G006 also counts a checked window on a partly checked field.
	ev.Fields[1].Windows, ev.Fields[1].ProbedWindows = 2, 1
	ev.Fields[1].CanariesPlanted, ev.Fields[1].CanariesRecovered = 4, 4
	ev.CanariesPlanted, ev.CanariesRecovered = 8, 8
	if line := BuildL3CoverageNarrative(scope, ev).Composed; !strings.Contains(line, "(8 of 8) across 2 checked text windows.") {
		t.Errorf("partly checked field missing from window count: %q", line)
	}
	ev.Fields[0].Windows, ev.Fields[0].ProbedWindows = 2, 2
	ev.Fields[0].CanariesPlanted, ev.Fields[0].CanariesRecovered = 8, 8
	ev.CanariesPlanted, ev.CanariesRecovered = 12, 12
	if line := BuildL3CoverageNarrative(scope, ev).Composed; !strings.Contains(line, "(12 of 12) across 3 checked text windows.") {
		t.Errorf("plural window count: %q", line)
	}
}

// RED-PROOF: unchanged reader granted forged older formats and did not refuse unknown outcomes or unreadable grants.
func TestL3V2Render_LabelGate(t *testing.T) {
	for _, version := range []string{"", "t600-evidence-1", "t600-evidence-v1", "synthetic-unknown-version", "t600-evidence-v2"} {
		for _, reason := range []string{"scope_and_recall_satisfied", "synthetic-unknown-outcome", "evidence_failed", ""} {
			scope, ev := caseL3V2ShortAndPassed()
			ev.DerivationVersion, ev.ComposedReason = version, reason
			line := BuildL3CoverageNarrative(scope, ev).Composed
			wantPass := version == "t600-evidence-v2" && reason == "scope_and_recall_satisfied"
			if strings.Contains(line, "Recall check passed") != wantPass {
				t.Errorf("version %q reason %q: %q", version, reason, line)
			}
			if version == "t600-evidence-v2" && (reason == "" || reason == "synthetic-unknown-outcome") && line != "Recall check unavailable." {
				t.Errorf("unknown outcome: %q", line)
			}
			if version != "t600-evidence-v2" && (strings.Contains(line, "passed") || strings.Contains(line, "GRANTED") || line != "Recall check unavailable: this certificate carries an older record format.") {
				t.Errorf("unknown outcome with asserted green: %q", line)
			}
		}
	}
	for _, status := range []string{"", "absent", "malformed", "not_checked", "unsupported_derivation"} {
		scope, ev := caseL3V2ShortAndPassed()
		ev.RecordStatus = status
		if line := BuildL3CoverageNarrative(scope, ev).Composed; line != "Recall check unavailable." {
			t.Errorf("status %q: %q", status, line)
		}
	}
}

// RED-PROOF: unchanged reader emitted GRANTED for unequal counts, zero probes and zero checked windows.
func TestL3V2Render_CountsDoNotOverstateRecovery(t *testing.T) {
	for _, counts := range [][3]uint32{{4, 3, 1}, {0, 0, 0}, {4, 4, 0}} {
		scope, ev := caseL3V2ShortAndPassed()
		ev.CanariesPlanted, ev.CanariesRecovered, ev.Fields[0].ProbedWindows = counts[0], counts[1], counts[2]
		if line := BuildL3CoverageNarrative(scope, ev).Composed; line != "Recall check unavailable." {
			t.Errorf("counts %v: %q", counts, line)
		}
	}
}

// RED-PROOF: unchanged reader failed all three new reasons in both field and window forms.
func TestL3V2Render_FieldReasons(t *testing.T) {
	cases := []struct{ reason, field, window string }{
		{"scan_incomplete", "the field has no completed recall check for some of its text", "at least one window has no completed recall check"},
		{"scan_off", "the deep scan was switched off for this field", "at least one window was not scanned because the deep scan was switched off"},
		{"content_cache_without_evidence", "the field was reused from an earlier scan of identical text, without usable recall evidence", "at least one window was reused from an earlier scan of identical text, without usable recall evidence"},
	}
	for _, tc := range cases {
		t.Run(tc.reason, func(t *testing.T) {
			for _, window := range []bool{false, true} {
				want := tc.field
				if window {
					want = tc.window
				}
				if got := l3EvidenceAbsentReasonMeaning(tc.reason, window); got != want {
					t.Errorf("window=%t: got %q, want %q", window, got, want)
				}
			}
		})
	}
}

// RED-PROOF: unchanged reader called the v2 evidence unverified for every tested outcome/grant combination.
func TestL3V2Render_NoBannedPhrases(t *testing.T) {
	for reason := range l3GatewayOutcomePhrases(t) {
		for _, green := range []bool{false, true} {
			scope, ev := caseL3V2ShortAndPassed()
			ev.ComposedReason, ev.ComposedGreen = reason, green
			n := BuildL3CoverageNarrative(scope, ev)
			if strings.Contains(strings.ToLower(n.Evidence+" "+n.Composed), "verified") {
				t.Errorf("outcome %s describes the recall check as verified", reason)
			}
			body := strings.Join([]string{n.Scope, n.Evidence, n.Composed, n.Diagnostic, n.Ceiling}, " ")
			body = strings.ToLower(strings.ReplaceAll(body, "This does not say that all personal data in the request was found, and text that was not checked is outside this statement.", ""))
			for _, banned := range []string{"all personal data", "every identifier", "fully verified", "guarantee", "signed by the witness"} {
				if strings.Contains(body, banned) {
					t.Errorf("outcome %s contains %q", reason, banned)
				}
			}
		}
	}
}

// RED-PROOF: unchanged reader failed all eight shape/flag cases with its diagnostic-only sentence.
func TestL3V2Render_VerdictSeparation(t *testing.T) {
	for _, shape := range []string{"v2", "legacy", "absent", "nil"} {
		for _, drives := range []bool{false, true} {
			t.Run(shape+"/drives="+map[bool]string{false: "false", true: "true"}[drives], func(t *testing.T) {
				scope, ev := caseL3V2ShortAndPassed()
				scope.DrivesClaim = !drives
				ev.DrivesVerdict = drives
				switch shape {
				case "legacy":
					ev.DerivationVersion = "t600-evidence-v1"
				case "absent":
					ev = &witnesspb.L3CoverageEvidence{RecordStatus: "absent", DrivesVerdict: drives}
				case "nil":
					ev = nil
				}
				n := BuildL3CoverageNarrative(scope, ev)
				want := "The recall-check result above is separate from the certificate verdict and does not change it."
				if shape == "absent" || shape == "nil" {
					want = "The coverage and recall-evidence lines above are separate from the certificate verdict and do not change it."
				}
				if drives && ev != nil {
					want = ""
				}
				if n.Diagnostic != want {
					t.Errorf("separation: %q, want %q", n.Diagnostic, want)
				}
			})
		}
	}
}

// RED-PROOF: unchanged reader emitted GRANTED for all 12 contradictory field/count shapes.
func TestL3V2Render_FieldConsistency(t *testing.T) {
	cases := map[string]func(*witnesspb.L3CoverageEvidence){
		"failed field":           func(ev *witnesspb.L3CoverageEvidence) { ev.Fields[0].Verdict = "failed" },
		"failed count":           func(ev *witnesspb.L3CoverageEvidence) { ev.FieldsFailed = 1 },
		"no passed fields":       func(ev *witnesspb.L3CoverageEvidence) { ev.FieldsPassed = 0 },
		"passed count mismatch":  func(ev *witnesspb.L3CoverageEvidence) { ev.FieldsPassed = 2 },
		"incomplete beside pass": func(ev *witnesspb.L3CoverageEvidence) { ev.Fields[1].Reason = "scan_incomplete" },
		"absent without windows": func(ev *witnesspb.L3CoverageEvidence) { ev.Fields[1].Windows = 0 },
		"unknown verdict":        func(ev *witnesspb.L3CoverageEvidence) { ev.Fields[1].Verdict = "synthetic-unknown" },
		"planted sum mismatch":   func(ev *witnesspb.L3CoverageEvidence) { ev.Fields[0].CanariesPlanted = 3 },
		"recovered sum mismatch": func(ev *witnesspb.L3CoverageEvidence) { ev.Fields[0].CanariesRecovered = 3 },
		"record totals mismatch": func(ev *witnesspb.L3CoverageEvidence) { ev.CanariesPlanted, ev.CanariesRecovered = 8, 8 },
		"missing fields":         func(ev *witnesspb.L3CoverageEvidence) { ev.Fields = nil },
		"nil field":              func(ev *witnesspb.L3CoverageEvidence) { ev.Fields = append(ev.Fields, nil) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			scope, ev := caseL3V2ShortAndPassed()
			mutate(ev)
			if got := BuildL3CoverageNarrative(scope, ev).Composed; got != "Recall check unavailable." {
				t.Errorf("contradictory fields: %q", got)
			}
		})
	}
}

// RED-PROOF: unchanged reader failed all nine versionless refusal cases, dropping their composed lines.
func TestL3V2Render_EarlyRefusals(t *testing.T) {
	for reason, status := range map[string]string{
		"chain_not_authenticated":       "not_checked",
		"request_binding_mismatch":      "not_checked",
		"conversation_binding_mismatch": "not_checked",
		"sanitizer_claim_count":         "not_checked",
		"evidence_missing":              "absent",
		"evidence_malformed":            "malformed",
		"evidence_version_missing":      "malformed",
		"evidence_version_mixed":        "malformed",
		"evidence_version_unknown":      "unsupported_derivation",
	} {
		t.Run(reason, func(t *testing.T) {
			ev := &witnesspb.L3CoverageEvidence{RecordStatus: status, ComposedReason: reason}
			n := BuildL3CoverageNarrative(nil, ev)
			phrase := l3GatewayOutcomePhrases(t)[reason]
			if n.Composed != "Recall check not passed - "+phrase+"." {
				t.Errorf("early refusal: %q", n.Composed)
			}
			if n.Evidence != "Recall evidence unavailable - "+phrase+". This is NOT a statement that the scan was clean." {
				t.Errorf("early refusal evidence: %q", n.Evidence)
			}
		})
	}
}

// RED-PROOF: replacing the historical status phrase with synthetic text failed all three historical subtests; restored.
func TestL3V2Render_HistoricalNotCheckedUnchanged(t *testing.T) {
	for _, reason := range []string{"scope_unavailable", "evidence_unavailable", ""} {
		t.Run(reason, func(t *testing.T) {
			ev := &witnesspb.L3CoverageEvidence{RecordStatus: "not_checked", ComposedReason: reason}
			n := BuildL3CoverageNarrative(nil, ev)
			const evidenceAtHEAD = "Recall evidence unavailable - the claim chain did not authenticate, so the record was never examined. This is NOT a statement that the scan was clean."
			if n.Evidence != evidenceAtHEAD || n.Composed != "" {
				t.Errorf("historical wording changed: evidence=%q composed=%q", n.Evidence, n.Composed)
			}
		})
	}
}

// RED-PROOF: unchanged reader failed all 11 status/grant combinations instead of returning unavailable.
func TestL3V2Render_ContradictoryGrant(t *testing.T) {
	for _, status := range []string{"present", "not_checked", "malformed", "absent", "unsupported_derivation", ""} {
		for _, green := range []bool{false, true} {
			if status == "present" && green {
				continue
			}
			scope, ev := caseL3V2ShortAndPassed()
			ev.RecordStatus, ev.ComposedGreen = status, green
			if got := BuildL3CoverageNarrative(scope, ev).Composed; got != "Recall check unavailable." {
				t.Errorf("status=%q green=%t: %q", status, green, got)
			}
		}
	}
}

// RED-PROOF: unchanged reader used Composed completeness rule instead of Composed coverage rule.
func TestL3V2Render_LegacyDenialPrefix(t *testing.T) {
	ev := &witnesspb.L3CoverageEvidence{
		RecordStatus: "present", DerivationVersion: "t600-evidence-v1", ComposedReason: "evidence_unavailable",
	}
	want := "Composed coverage rule (scope AND recall AND named exclusions): NOT granted - no recall evidence was carried on this certificate."
	if got := BuildL3CoverageNarrative(nil, ev).Composed; got != want {
		t.Errorf("legacy denial: %q, want %q", got, want)
	}
}
