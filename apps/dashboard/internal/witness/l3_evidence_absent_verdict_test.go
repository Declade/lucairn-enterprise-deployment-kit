package witness

import (
	"strings"
	"testing"

	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
)

// ---------------------------------------------------------------------------
// T-881 — an absent VERDICT is not absent EVIDENCE.
// ---------------------------------------------------------------------------
//
// astra post-merge audit of kit #136, finding 2: the mixed-result branches
// rendered a partly probed field (the producer corpus `partial` scenario:
// 4/4 planted probes recovered, 1 of 2 windows probed, verdict `absent`) as a
// field that "carries no evidence", and credited the passed field with the
// request total 12/12 when it carried 8/8. Every expected string below is the
// EXACT sentence, so any wording drift is a conscious edit.

// casePartlyProbedOnly is the bug-hunter L1 shape: every field is absent, but
// the one field WAS probed and its probes came back.
func casePartlyProbedOnly() *witnesspb.L3CoverageEvidence {
	return &witnesspb.L3CoverageEvidence{
		RecordStatus: "present",
		Rollup:       "absent",
		Fields: []*witnesspb.L3FieldEvidence{
			{FieldKey: "messages[0].content", Verdict: "absent", Reason: "window_below_probe_floor",
				CanariesPlanted: 4, CanariesRecovered: 4, Windows: 2, ProbedWindows: 1},
		},
		CanariesPlanted:   4,
		CanariesRecovered: 4,
		FieldsAbsent:      1,
	}
}

// caseFailedWithPartlyProbed puts the partly probed field into the FAILED
// branch: one pass (8/8), one miss (5/8), one partly probed field (4/4).
func caseFailedWithPartlyProbed() *witnesspb.L3CoverageEvidence {
	return &witnesspb.L3CoverageEvidence{
		RecordStatus: "present",
		Rollup:       "failed",
		Fields: []*witnesspb.L3FieldEvidence{
			{FieldKey: "messages[0].content", Verdict: "passed", CanariesPlanted: 8, CanariesRecovered: 8, Windows: 2, ProbedWindows: 2},
			{FieldKey: "messages[1].content", Verdict: "failed", CanariesPlanted: 8, CanariesRecovered: 5, Windows: 2, ProbedWindows: 2},
			{FieldKey: "messages[2].content", Verdict: "absent", Reason: "window_below_probe_floor",
				CanariesPlanted: 4, CanariesRecovered: 4, Windows: 2, ProbedWindows: 1},
		},
		CanariesPlanted:   20,
		CanariesRecovered: 17,
		FieldsPassed:      1,
		FieldsFailed:      1,
		FieldsAbsent:      1,
	}
}

// caseTwoPartlyProbedOneShort: one pass (8/8) beside TWO partly probed
// fields — one at 4/4 (1 of 2 windows probed, below-floor reason), one at 3/4
// (1 of 3 windows probed, cache reason on a field that recorded windows).
func caseTwoPartlyProbedOneShort() *witnesspb.L3CoverageEvidence {
	return &witnesspb.L3CoverageEvidence{
		RecordStatus: "present",
		Rollup:       "unverified",
		Fields: []*witnesspb.L3FieldEvidence{
			{FieldKey: "messages[0].content", Verdict: "passed", CanariesPlanted: 8, CanariesRecovered: 8, Windows: 2, ProbedWindows: 2},
			{FieldKey: "messages[1].content", Verdict: "absent", Reason: "window_below_probe_floor",
				CanariesPlanted: 4, CanariesRecovered: 4, Windows: 2, ProbedWindows: 1},
			{FieldKey: "messages[2].content", Verdict: "absent", Reason: "window_served_from_verdict_cache",
				CanariesPlanted: 4, CanariesRecovered: 3, Windows: 3, ProbedWindows: 1},
		},
		CanariesPlanted:   16,
		CanariesRecovered: 15,
		FieldsPassed:      1,
		FieldsAbsent:      2,
	}
}

// caseCachedNoWindow: the verdict cache served the whole field and no window
// was recorded for it — the only shape where "no inference ran" is field-wide.
func caseCachedNoWindow() *witnesspb.L3CoverageEvidence {
	return &witnesspb.L3CoverageEvidence{
		RecordStatus: "present",
		Rollup:       "absent",
		Fields: []*witnesspb.L3FieldEvidence{
			{FieldKey: "messages[0].content", Verdict: "absent", Reason: "window_served_from_verdict_cache"},
		},
		FieldsAbsent: 1,
	}
}

func TestL3EvidenceLine_AbsentVerdictIsNotAbsentEvidence(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		ev   *witnesspb.L3CoverageEvidence
		want string
	}{
		{
			name: "partial corpus: 8/8 passed + 4/4 on 1 of 2 windows (unverified)",
			ev:   mustEvidence(t, "partial"),
			want: "Coverage evidence check is INCOMPLETE - 1 field(s) passed (8/8 probes recovered) and " +
				"1 field(s) carry no usable recall-evidence verdict: 1 field(s) only partly probed " +
				"(4/4 planted probes recovered, 1 of 2 windows probed - not a usable verdict); " +
				"why: 1 x the text was shorter than the window size the probe overhead was measured at. " +
				"Across the request: 12/12 probes recovered. A partly evidenced request is not a verified one.",
		},
		{
			name: "partly probed field beside a measured miss (failed)",
			ev:   caseFailedWithPartlyProbed(),
			want: "Coverage evidence check FAILED - 1 field(s) returned fewer planted probes than required " +
				"(17/20 recovered across the request; 1 field(s) passed, 1 field(s) carry no usable verdict: " +
				"1 field(s) only partly probed (4/4 planted probes recovered, 1 of 2 windows probed - not a usable verdict); " +
				"why: 1 x the text was shorter than the window size the probe overhead was measured at). " +
				"A measured miss is positive evidence of a recall gap.",
		},
		{
			name: "mixed corpus: unprobed cached field really carries no evidence (failed)",
			ev:   mustEvidence(t, "mixed"),
			want: "Coverage evidence check FAILED - 1 field(s) returned fewer planted probes than required " +
				"(13/16 recovered across the request; 1 field(s) passed, 1 field(s) carry no usable verdict: " +
				"1 field(s) carry no evidence at all; why: 1 x at least one window was served from the deep shield " +
				"verdict cache, so no inference ran on that window). A measured miss is positive evidence of a recall gap.",
		},
		{
			// LOW-1: two partly probed fields, one of them at 3/4. Pins the
			// field count (2, not 1) and that an unrecovered planted probe is
			// never credited as recovered (7/8, not 8/8). MED-1: a partly
			// probed field's cache reason is phrased per window, never "no
			// inference ran" beside probes that came back.
			name: "two partly probed fields, one at 3/4 (unverified)",
			ev:   caseTwoPartlyProbedOneShort(),
			want: "Coverage evidence check is INCOMPLETE - 1 field(s) passed (8/8 probes recovered) and " +
				"2 field(s) carry no usable recall-evidence verdict: 2 field(s) only partly probed " +
				"(7/8 planted probes recovered, 2 of 5 windows probed - not a usable verdict); " +
				"why: 1 x the text was shorter than the window size the probe overhead was measured at; " +
				"1 x at least one window was served from the deep shield verdict cache, so no inference ran on that window. " +
				"Across the request: 15/16 probes recovered. A partly evidenced request is not a verified one.",
		},
		{
			// MED-1: the field-wide cache wording survives ONLY where the
			// field recorded no window.
			name: "cached field with no recorded window keeps the field-wide wording (absent rollup)",
			ev:   caseCachedNoWindow(),
			want: "No field on this request carries a usable recall-evidence verdict " +
				"(1 x the result was served from the deep shield verdict cache, so no inference ran). " +
				"Evidence that does not exist is not evidence of success.",
		},
		{
			name: "only field partly probed (absent rollup)",
			ev:   casePartlyProbedOnly(),
			want: "No field on this request carries a usable recall-evidence verdict: 1 field(s) only partly probed " +
				"(4/4 planted probes recovered, 1 of 2 windows probed - not a usable verdict); " +
				"why: 1 x the text was shorter than the window size the probe overhead was measured at. " +
				"Probes recovered on a partly probed field are measured evidence, not a usable verdict.",
		},
		{
			name: "no probes anywhere (absent rollup) keeps the upstream sentence",
			ev:   mustEvidence(t, "absent_below_floor"),
			want: "No field on this request carries a usable recall-evidence verdict " +
				"(1 x the text was shorter than the window size the probe overhead was measured at). " +
				"Evidence that does not exist is not evidence of success.",
		},
		{
			name: "no field recorded at all (absent rollup)",
			ev:   mustEvidence(t, "empty"),
			want: "No field on this request carries a usable recall-evidence verdict. " +
				"Evidence that does not exist is not evidence of success.",
		},
		{
			name: "threshold passed at 3/4 with threshold 3 (verified, weak clause)",
			ev:   caseHonestSubThresholdPass(),
			want: "Coverage evidence check passed (3/4 probes recovered) across 1 field(s). " +
				"That means every probed window met the recall threshold in force.",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := buildL3EvidenceLine(tc.ev, "present")
			if got != tc.want {
				t.Errorf("evidence line mismatch.\n got: %s\nwant: %s", got, tc.want)
			}
		})
	}
}

// TestL3EvidenceLine_NeverSaysNoEvidenceBesidePlantedProbes is the property
// form over the whole grid plus the T-881 shapes: whenever an absent field had
// probes planted, the line must not describe the absent fields as carrying no
// evidence unless it separately names the partly probed ones with their counts,
// and the no-evidence closing sentence is reserved for records with no plant.
func TestL3EvidenceLine_NeverSaysNoEvidenceBesidePlantedProbes(t *testing.T) {
	t.Parallel()
	grid := evidenceGrid(t)
	grid["t881_partly_probed_only"] = casePartlyProbedOnly()
	grid["t881_failed_with_partly_probed"] = caseFailedWithPartlyProbed()
	grid["t881_two_partly_probed_one_short"] = caseTwoPartlyProbedOneShort()
	sawPartly := 0
	for name, ev := range grid {
		line := buildL3EvidenceLine(ev, "present")
		tally := l3TallyEvidence(ev)
		if tally.partlyProbedFields == 0 {
			continue
		}
		sawPartly++
		if strings.Contains(line, "Evidence that does not exist is not evidence of success") {
			t.Errorf("%s: no-evidence sentence beside %d partly probed field(s).\nline: %s", name, tally.partlyProbedFields, line)
		}
		if !strings.Contains(line, "only partly probed") || !strings.Contains(line, "windows probed") {
			t.Errorf("%s: partly probed field not named with its measured numbers.\nline: %s", name, line)
		}
		if strings.Contains(line, "field(s) carry no evidence") && tally.unprobedFields == 0 {
			t.Errorf("%s: says a field carries no evidence although every absent field was probed.\nline: %s", name, line)
		}
	}
	if sawPartly < 3 {
		t.Fatalf("only %d partly probed shapes in the grid — the property is near-vacuous", sawPartly)
	}
}
