package witness

import (
	"fmt"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
)

// ---------------------------------------------------------------------------
// T-600 S3 / T-617 S3 — the CLAIM CEILING on the kit's Cert Inspector.
// ---------------------------------------------------------------------------
//
// PRDs (all Locked, all bind):
//   - Opus Advisor specs/2026-09/prd-2026-09-21-t600-t617-coverage-attestation-stream.md
//     § Slice D (the kit half)
//   - specs/2026-08/prd-2026-08-09-t600-evidence-gated-l3-coverage.md
//     § Problem (the READER-INFERENCE gap), Marc lock 4, § Slice 3
//   - specs/2026-08/prd-2026-08-11-l3-coverage-scope-attestation.md § S3
//
// THE DEFECT THIS FILE CLOSES is not in the witness and not in the sanitizer:
// both record the truth. It is in what a human reads. The inspector rendered a
// bare completeness enum over a record whose own source file says
// (dual-sandbox-architecture services/sanitizer/l3_coverage.py:13-14):
//
//	"Coverage means 'these bytes were submitted to L3 in an untruncated
//	 call', NOT 'L3 found everything'."
//
// T-313 MEASURED the gap: qwen2.5:7b returned parse_status="ok" over a
// COMPLETE coverage manifest at ~19% recall. "full" next to that run is
// literally true about the claim chain and catastrophically misleading about
// the scan. So the words change here, and only here — no verdict moves, and
// this package computes no verdict of its own.
//
// ⚑⚑ PORTED VERBATIM, AND THAT IS THE POINT. Every string below is the one
// the gateway's own reader surfaces render:
//
//	Declade/dual-sandbox-architecture @ db096f5dcd681d56dfca3299337dfef76d6447c3
//	services/gateway/internal/api/veil_l3_coverage_render.go
//
// transformed only mechanically (veilv1 -> witnesspb; three identifiers
// exported for the template). Two surfaces phrasing the same record
// differently is how a caveat quietly stops being carried on the one an
// auditor actually reads — and the first cut of this file proved the failure
// mode from the other direction: it was copied from a WORKING TREE minutes
// before upstream fixed a render overclaim in it, so the kit re-inherited a
// defect the gateway had already closed. Re-sync from a NAMED COMMIT when
// upstream's wording moves; never from a working tree.
//
// ONE DELIBERATE DIVERGENCE (T-881, astra post-merge audit of kit #136,
// finding 2): the `failed`, `unverified` and `absent` evidence branches no
// longer say a partly probed field "carries no evidence", and the unverified
// branch states the request total as its own sentence. Upstream @ db096f5d
// (the commit this file was copied from) still has the old wording; this is a
// kit-side honesty fix ahead of upstream, not drift.
//
// ⚑ UPSTREAM HAS SINCE MOVED: DSA main c66c7a1a rewrote the evidence
// absent-reason wording (every window-level reason phrased "at least one
// window ..." on a field that recorded a window) and the matching
// L3FieldEvidence / cache-reason proto comments. This file ports ONLY the
// cache-reason part of c66c7a1a (hunter MED-1). The next re-sync must merge
// BOTH fixes — this T-881 divergence AND the whole of c66c7a1a — never pick
// one over the other. The vendored proto comment for
// `window_served_from_verdict_cache` in witness.proto is likewise stale
// against main (field-wide wording); it is left untouched here because the
// vendored proto is re-synced, not edited.
//
// ONE DELIBERATE OMISSION: upstream's l3CompletenessShortCaveat /
// l3CompletenessWithShortCaveat pair exists for the gateway PDF's fixed-width
// table cell. The kit dashboard has no such render, so it is not ported. If a
// kit surface ever needs a width-constrained caveat, port that pair too rather
// than inventing a shorter sentence here.
//
// ⛔ THE CEILING IS THE POINT (Marc lock 4, standing). Coverage is NECESSARY
// for a completeness claim and can NEVER be SUFFICIENT. Every render that
// mentions coverage or recall evidence carries L3CoverageCeiling, and the
// overclaim phrases are banned from every string this file can produce —
// pinned by TestL3CoverageNarrative_NeverClaimsCompleteDetection and, because
// a phrase denylist cannot see an overclaim nobody thought of, by the
// NEGATIVE-SHAPE property tests in TestL3EvidenceLine_* that require every
// evidence line to carry the counts it is about.
//
// ⛔ ABSENCE IS NOT INNOCENCE. A missing scope or evidence record renders as
// "scope unavailable" / "recall evidence unavailable", NEVER as "nothing was
// excluded" or "the scan was clean". Every certificate minted before T-617 /
// T-600, and every deployment running the probe in its shipped `off` mode, is
// in exactly that state — which makes the absent case the COMMON case on a
// customer install today, not the edge case.
//
// ⛔ DARK. `L3CoverageScope.drives_claim` (what the SANITIZER did with its
// scope derivation) and `L3CoverageEvidence.drives_verdict` (what the WITNESS
// did with the composition) are both false in every shipped build. While
// either is false the narrative says so in as many words: these lines are
// diagnostic and do not change the verdict. The line disappears on its own
// when both flip — it is keyed on the flags, not on a build constant.
//
// ⛔ DISCLOSURE BOUNDARY. No string this file can produce carries a
// `field_key`, a `receipt_id`, a `source_claim_id` or a `zone` name. Field
// keys are structural paths into the customer's own request
// ("messages[3].content") and zones are open-vocabulary policy wire-names;
// rendering either on an operator page leaks request shape and deployment
// policy for no auditing gain. Reasons and COUNTS say everything C3 requires.

// ⚑ ASCII-ONLY IN ANY STRING THIS FILE RENDERS. Upstream's reason is its .pdf
// render (gofpdf CORE fonts in WinAnsi turn an em dash into mojibake on the
// artifact a customer hands a regulator). The kit dashboard has no such PDF
// path today, so the kit's OWN reason is narrower and worth stating honestly:
// byte-identity with the upstream wording. Keeping the rule means a future kit
// PDF or CSV export inherits a safe corpus, and it makes an upstream re-sync a
// diff of nothing. Enforced by TestL3CoverageNarrative_IsASCIIOnly.
//
// ⚑ NO APOSTROPHES IN ANY STRING THIS FILE RENDERS. Every one of these lines
// lands inside html/template, which escapes `'` to `&#39;` — so a caveat
// written with an apostrophe is present on the page but INVISIBLE to the
// grep-verifiable success criterion the T-600 PRD states, and to any operator
// grepping the served HTML for it. Same for `"` (escaped to `&#34;`), which is
// why l3Quote brackets an out-of-vocabulary token instead of quoting it. The
// phrasing works around the characters rather than relying on everyone
// downstream remembering to unescape.

// L3CoverageCeiling is the one-line claim ceiling. It appears on EVERY surface
// that renders coverage or recall evidence, verbatim.
const L3CoverageCeiling = "Coverage ceiling: this names which protection layers ran over which fields. " +
	"It is never a claim that the scan detected every piece of personal data in the request."

// L3CoverageDiagnosticOnly is rendered while the records drive nothing.
const L3CoverageDiagnosticOnly = "Diagnostic only: the coverage and recall-evidence lines above are recorded for " +
	"measurement and do not yet change the verdict on this certificate."

// L3CompletenessMeaning is the caveat pinned to the completeness verdict word
// itself. `completeness` is a CHAIN property — "every claim the pipeline was
// expected to file is present and verified" — and says nothing about detection
// recall. Rendering the word alone is the reader-inference gap in one cell.
const L3CompletenessMeaning = "completeness describes the CLAIM CHAIN (which pipeline claims are present and " +
	"verified), not detection recall - see coverage below"

// L3CoverageNarrative is the rendered plain-language coverage story. Every
// field is a complete sentence or empty; a consumer renders the non-empty ones
// in order and is never required to compose text of its own.
type L3CoverageNarrative struct {
	// Scope answers "which fields did the deep shield RUN on" (proto field 13).
	// Never empty.
	Scope string
	// Evidence answers "did it FIND the planted probes" (proto field 14).
	// Never empty.
	Evidence string
	// Composed states the locked composition rule's output. Empty when no
	// evidence record was readable (there is nothing composed to report).
	Composed string
	// Diagnostic is L3CoverageDiagnosticOnly while either record drives
	// nothing, empty after both flip.
	Diagnostic string
	// Ceiling is L3CoverageCeiling. Never empty.
	Ceiling string

	// ScopeStatus / EvidenceStatus / EvidenceRollup are the raw closed-
	// vocabulary tokens, so a machine consumer can switch without parsing
	// prose. They carry no field keys, receipt ids, source claim ids or zone
	// names — see buildPublicSummaryL3Coverage for why that matters on the
	// unauthenticated surface.
	ScopeStatus    string
	EvidenceStatus string
	EvidenceRollup string
	// DrivesVerdict mirrors L3CoverageEvidence.drives_verdict. False in every
	// shipped build.
	DrivesVerdict bool
}

// l3RecordStatusMeaning renders a record_status token in plain words. The
// vocabulary is shared by L3CoverageScope and L3CoverageEvidence and pinned
// equal across them by TestL3Evidence_StatusVocabularyMatchesTheScopeRecord in
// the witness.
func l3RecordStatusMeaning(status string) string {
	switch status {
	case "absent":
		return "this certificate carries no such record (the sanitizer that minted it predates the feature, " +
			"or the deployment has it switched off)"
	case "malformed":
		return "the witness was handed a record and REFUSED it, so none of it is reproduced"
	case "unsupported_derivation":
		return "the record was produced by a rule version this witness build does not know, so it is not reproduced"
	case "not_checked":
		return "the claim chain did not authenticate, so the record was never examined"
	case "":
		return "unknown provenance (this certificate was minted or re-verified by a witness build that predates the record)"
	default:
		return "unrecognised record state " + l3Quote(status)
	}
}

// l3Quote marks an out-of-vocabulary token so an unexpected value is visibly a
// token rather than prose the reader might mistake for a finding.
//
// ⚑ SQUARE BRACKETS, NOT QUOTE MARKS (bug-hunter M1). `"` is one of the five
// characters html/template escapes (to &#34;), so a quoted token made its own
// narrative line un-greppable in the served page — and the greppability test
// never exercised this path, because every fixture used in-vocabulary tokens.
// Brackets survive escaping untouched. The unknown-token fixture in
// l3RenderCases now drives this function on the real render path.
func l3Quote(s string) string { return "[" + s + "]" }

// l3ExclusionReasonMeaning renders one L3ExcludedField.reason in plain words.
// Closed vocabulary (proto L3ExcludedField.reason); an unknown token is
// rendered verbatim rather than dropped — silently omitting an exclusion
// reason is the C3 overclaim.
func l3ExclusionReasonMeaning(reason string) string {
	switch reason {
	case "l3_not_configured":
		return "no deep shield is configured on this deployment"
	case "caller_skipped":
		return "the caller asked for no deep scan"
	case "shallow_zone_bypasses_l3":
		return "the typed-message contract routes shallow-zone fields around the deep shield"
	case "zone_policy_skip":
		return "the zone policy excludes the deep shield for that zone"
	default:
		return l3Quote(reason)
	}
}

// l3ScopeReasonMeaning renders L3CoverageScope.reason in plain words.
func l3ScopeReasonMeaning(reason string) string {
	switch reason {
	case "all_eligible_fields_covered":
		return "every eligible field was covered"
	case "no_eligible_field":
		return "no field on this request was eligible for the deep shield"
	case "eligible_field_not_covered":
		return "at least one eligible field has no coverage evidence at all"
	case "unattributed_degrade":
		return "a deep-shield degradation named no field, so the whole request is treated as uncovered"
	case "":
		return "no reason recorded"
	default:
		return l3Quote(reason)
	}
}

// l3EvidenceAbsentReasonMeaning renders one L3FieldEvidence.reason in plain
// words. Closed vocabulary (proto L3FieldEvidence.reason).
//
// ⚑ THE CACHE REASON IS A WINDOW FACT WHEN THE FIELD RECORDED A WINDOW (T-881
// round 1, hunter MED-1; wording ported from upstream DSA c66c7a1a
// veil_l3_coverage_render.go). The producer names the FIRST unprobed window's
// reason for the whole field, while the field's other windows may have run
// inference and had their probes come back. The field-wide wording "so no
// inference ran" then sat in the same sentence as recovered probes, which
// require inference. For a field that recorded at least one window
// (`windowScoped`) the cache reason is phrased per window; the field-wide
// wording is kept only where no window was recorded.
func l3EvidenceAbsentReasonMeaning(reason string, windowScoped bool) string {
	if windowScoped && reason == "window_served_from_verdict_cache" {
		return "at least one window was served from the deep shield verdict cache, so no inference ran on that window"
	}
	switch reason {
	case "probe_off":
		return "the recall probe is not armed on this deployment"
	case "no_l3_window":
		return "the deep shield ran no window on that field"
	case "window_below_probe_floor":
		return "the text was shorter than the window size the probe overhead was measured at"
	case "window_served_from_verdict_cache":
		return "the result was served from the deep shield verdict cache, so no inference ran"
	case "output_headroom_clipped":
		return "the model output budget could not hold the probe without starving the real scan"
	case "no_prompt_assembly_seam":
		return "that scan path has no seam at which a probe could be planted"
	default:
		return l3Quote(reason)
	}
}

// l3ComposedReasonMeaning renders L3CoverageEvidence.composed_reason in plain
// words. Closed vocabulary (proto L3CoverageEvidence.composed_reason).
func l3ComposedReasonMeaning(reason string) string {
	switch reason {
	case "scope_and_recall_satisfied":
		return "every eligible field was covered, every covered field had its recall check come back, " +
			"and the exclusions and receipts are named"
	case "scope_unavailable":
		return "the scope record is missing or was refused, so the first half of the rule cannot be evaluated"
	case "evidence_unavailable":
		return "no recall evidence was carried on this certificate"
	case "evidence_failed":
		return "a recall check on one field MISSED: the deep shield did not return the probes planted in it"
	case "scope_not_granted":
		return "the scope record itself did not grant"
	case "evidence_absent_for_covered_field":
		return "a field the scope record says was freshly scanned carries no passing recall evidence"
	case "evidence_on_excluded_field":
		return "the two records disagree - the scope record calls a field policy-excluded while the " +
			"evidence record carries a scan verdict for it"
	case "receipt_covered_evidence_not_in_chain":
		return "a field was covered by a NAMED RECEIPT from an earlier turn, so no inference ran on those " +
			"bytes this turn and the recall evidence for them lives on the source claim, not here"
	case "":
		return "nothing was composed"
	default:
		return l3Quote(reason)
	}
}

// BuildL3CoverageNarrative renders the plain-language coverage story from the
// two unsigned witness records. Both arguments may be nil — that IS the common
// case on every pre-T-617 / pre-T-600 certificate, and it renders as
// "unavailable", never as a clean bill of health.
func BuildL3CoverageNarrative(scope *witnesspb.L3CoverageScope, ev *witnesspb.L3CoverageEvidence) L3CoverageNarrative {
	n := L3CoverageNarrative{
		Ceiling:        L3CoverageCeiling,
		ScopeStatus:    scope.GetRecordStatus(),
		EvidenceStatus: ev.GetRecordStatus(),
		EvidenceRollup: ev.GetRollup(),
		DrivesVerdict:  ev.GetDrivesVerdict(),
	}
	if scope == nil {
		// A nil message and an explicit "absent" are the same fact to a
		// reader; render them identically rather than inventing a third
		// wording for "the proto field was not set".
		n.ScopeStatus = "absent"
	}
	if ev == nil {
		n.EvidenceStatus = "absent"
	}

	n.Scope = buildL3ScopeLine(scope, n.ScopeStatus)
	n.Evidence = buildL3EvidenceLine(ev, n.EvidenceStatus)
	n.Composed = buildL3ComposedLine(ev, n.EvidenceStatus)

	// The dark note is keyed on the FLAGS, not on a build constant, so it
	// disappears by itself on the day the flip lands rather than needing a
	// second wording change nobody remembers to make.
	if !scope.GetDrivesClaim() || !ev.GetDrivesVerdict() {
		n.Diagnostic = L3CoverageDiagnosticOnly
	}
	return n
}

// buildL3ScopeLine renders the SCOPE half (proto field 13).
func buildL3ScopeLine(scope *witnesspb.L3CoverageScope, status string) string {
	if status != "present" {
		return "Coverage scope unavailable - " + l3RecordStatusMeaning(status) +
			". This is NOT a statement that nothing was excluded or that every field was covered."
	}

	eligible := scope.GetEligibleCount()
	covered := scope.GetCovered()
	var viaScan, viaReceipt int
	for _, c := range covered {
		if c.GetVia() == "receipt" {
			viaReceipt++
			continue
		}
		viaScan++
	}

	var b strings.Builder
	fmt.Fprintf(&b, "The deep shield covered %d of %d fields eligible for it", len(covered), eligible)
	if viaReceipt > 0 {
		fmt.Fprintf(&b, " (%d by a fresh scan this turn, %d by a named receipt from an earlier turn)", viaScan, viaReceipt)
	}
	b.WriteString("; ")

	excluded := scope.GetExcluded()
	if len(excluded) == 0 {
		b.WriteString("no field was excluded by policy")
	} else {
		fmt.Fprintf(&b, "%d field(s) were excluded by policy: %s", len(excluded),
			strings.Join(l3ExclusionReasonPhrases(excluded), "; "))
	}
	b.WriteString(". ")

	if notCovered := scope.GetEligibleNotCovered(); len(notCovered) > 0 {
		fmt.Fprintf(&b, "%d eligible field(s) have NO coverage evidence at all. ", len(notCovered))
	}

	if scope.GetGranted() {
		b.WriteString("Scope check: granted - " + l3ScopeReasonMeaning(scope.GetReason()) + ".")
	} else {
		b.WriteString("Scope check: NOT granted - " + l3ScopeReasonMeaning(scope.GetReason()) + ".")
	}
	return b.String()
}

// l3ExclusionReasonPhrases renders the exclusion ledger as "<n> × <reason in
// plain words>" phrases, sorted for stable output.
//
// It names REASONS and COUNTS and deliberately not field keys or zone names.
// field_key is a structural path into the customer's own request
// ("messages[3].content") and `zone` is an OPEN-vocabulary policy wire-name; a
// public, unauthenticated render of either leaks request shape and deployment
// policy. The reason vocabulary is closed and says everything C3 requires — an
// auditor asks WHY a field was excluded, not which array index it sat at.
func l3ExclusionReasonPhrases(excluded []*witnesspb.L3ExcludedField) []string {
	counts := map[string]int{}
	for _, e := range excluded {
		counts[e.GetReason()]++
	}
	reasons := make([]string, 0, len(counts))
	for r := range counts {
		reasons = append(reasons, r)
	}
	sort.Strings(reasons)
	out := make([]string, 0, len(reasons))
	for _, r := range reasons {
		out = append(out, fmt.Sprintf("%d x %s", counts[r], l3ExclusionReasonMeaning(r)))
	}
	return out
}

// buildL3EvidenceLine renders the RECALL EVIDENCE half (proto field 14).
//
// The granting wording is Marc lock 4, verbatim: "coverage evidence check
// passed (K/K probes recovered)". It says the CHECK passed — never that the
// scan was complete.
func buildL3EvidenceLine(ev *witnesspb.L3CoverageEvidence, status string) string {
	if status != "present" {
		return "Recall evidence unavailable - " + l3RecordStatusMeaning(status) +
			". This is NOT a statement that the scan was clean."
	}

	planted := ev.GetCanariesPlanted()
	recovered := ev.GetCanariesRecovered()
	passed := ev.GetFieldsPassed()
	failed := ev.GetFieldsFailed()
	absent := ev.GetFieldsAbsent()

	switch ev.GetRollup() {
	case "verified":
		// ⚑⚑⚑ THE CLAUSE AFTER THE COUNTS IS GATED ON THE COUNTS (bug-hunter
		// H1). A field passes at `recovered >= threshold`, and the threshold is
		// a legal configuration anywhere in [1, K]
		// (services/sanitizer/l3_evidence_probe.py ProbeConfig.armed). So an
		// HONEST K=4 / threshold=3 record is `passed` at 3 of 4 recovered — and
		// the unconditional wording rendered "passed (3/4 probes recovered) ...
		// every planted probe came back": a false sentence standing next to its
		// own contradicting numbers, which is the exact overclaim the proto
		// comment on L3CoverageEvidence.record_status forbids a reader surface
		// from making. Only `recovered == planted` earns the strong clause.
		//
		// The weak clause is deliberately the one that is true under EVERY
		// configuration: a `passed` field means every probed window met the
		// threshold in force. It does not name the threshold because the
		// threshold is not in the signed record.
		clause := "That means every probed window met the recall threshold in force."
		if recovered == planted && planted > 0 {
			clause = "That means the recall CHECK ran on every field carrying one and every planted probe came back."
		}
		return fmt.Sprintf(
			"Coverage evidence check passed (%d/%d probes recovered) across %d field(s). %s",
			recovered, planted, passed, clause)
	case "failed":
		// ⚑ T-881: "carry no evidence" was FALSE for a partly probed field
		// (planted probes recovered, one window unprobed). The tail now says
		// "no usable verdict" and, where probes were planted, names them.
		return fmt.Sprintf(
			"Coverage evidence check FAILED - %d field(s) returned fewer planted probes than required "+
				"(%d/%d recovered across the request; %d field(s) passed, %d field(s) carry no usable verdict%s). "+
				"A measured miss is positive evidence of a recall gap.",
			failed, recovered, planted, passed, absent, l3NoVerdictDetailSuffix(ev))
	case "unverified":
		// ⚑ T-881 (astra post-merge audit of kit #136, finding 2). Two defects
		// in the upstream-copied wording, both fixed here:
		//   1. "%d field(s) carry no evidence" — a field whose windows were
		//      only PARTLY probed is `absent` with its planted probes
		//      recovered (producer corpus scenario `partial`: 4/4 recovered,
		//      1 of 2 windows probed). It carries measured evidence; what it
		//      lacks is a usable field-level VERDICT.
		//   2. "%d field(s) passed (R/P probes recovered)" printed the
		//      REQUEST totals, which include the partly probed field's
		//      probes, so the passed fields were credited with 12/12 when they
		//      carried 8/8.
		// The request total is its own sentence (T-881 round 1, hunter LOW-2):
		// after "; " it read as one more entry in the why-ledger.
		tally := l3TallyEvidence(ev)
		return fmt.Sprintf(
			"Coverage evidence check is INCOMPLETE - %d field(s) passed (%d/%d probes recovered) and "+
				"%d field(s) carry no usable recall-evidence verdict%s. Across the request: %d/%d probes recovered. "+
				"A partly evidenced request is not a verified one.",
			passed, tally.passedRecovered, tally.passedPlanted, absent, l3NoVerdictDetailSuffix(ev),
			recovered, planted)
	case "absent":
		// ⚑ "no field carried a recall probe" WAS FALSE for a real shape
		// (bug-hunter L1): a field whose windows were only PARTLY probed is
		// `absent` with canaries_planted > 0, so probes were planted and the
		// old sentence denied it. The rollup means no field carries a USABLE
		// verdict, which is what this says.
		//
		// ⚑ T-881: when such a field exists its measured numbers are named,
		// and "Evidence that does not exist is not evidence of success" is
		// reserved for the case where no probe was planted anywhere — beside
		// a 4/4 recovery it would deny evidence the record carries.
		if tally := l3TallyEvidence(ev); tally.partlyProbedFields > 0 {
			return "No field on this request carries a usable recall-evidence verdict" +
				l3NoVerdictDetailSuffix(ev) + ". Probes recovered on a partly probed field are measured " +
				"evidence, not a usable verdict."
		}
		return "No field on this request carries a usable recall-evidence verdict" +
			l3EvidenceAbsentSuffix(ev) + ". Evidence that does not exist is not evidence of success."
	default:
		return "Recall evidence unavailable - the evidence rollup is " + l3Quote(ev.GetRollup()) +
			", which this build does not recognise. This is NOT a statement that the scan was clean."
	}
}

// l3EvidenceAbsentPhrases renders the absent-reason ledger as "<n> × <reason
// in plain words>" phrases, sorted. Field keys are deliberately not rendered —
// same reasoning as l3ExclusionReasonPhrases.
func l3EvidenceAbsentPhrases(ev *witnesspb.L3CoverageEvidence) []string {
	type group struct {
		reason       string
		windowScoped bool
	}
	counts := map[group]int{}
	for _, f := range ev.GetFields() {
		if f.GetVerdict() != "absent" {
			continue
		}
		counts[group{reason: f.GetReason(), windowScoped: f.GetWindows() > 0}]++
	}
	groups := make([]group, 0, len(counts))
	for g := range counts {
		groups = append(groups, g)
	}
	sort.Slice(groups, func(i, j int) bool {
		if groups[i].reason != groups[j].reason {
			return groups[i].reason < groups[j].reason
		}
		return !groups[i].windowScoped && groups[j].windowScoped
	})
	out := make([]string, 0, len(groups))
	for _, g := range groups {
		out = append(out, fmt.Sprintf("%d x %s", counts[g], l3EvidenceAbsentReasonMeaning(g.reason, g.windowScoped)))
	}
	return out
}

// l3EvidenceTally splits the per-field map by what each field can honestly be
// said to carry (T-881). The witness-computed request totals cannot make this
// split: a partly probed field is `absent` yet contributes to them.
type l3EvidenceTally struct {
	passedPlanted, passedRecovered uint32

	// partlyProbed* sum the `absent` fields on which at least one probe was
	// planted or one window was probed — measured evidence without a usable
	// field-level verdict (L3FieldEvidence: probed_windows < windows forces
	// `absent` rather than `passed`).
	partlyProbedFields                          uint32
	partlyProbedPlanted, partlyProbedRecovered  uint32
	partlyProbedWindows, partlyProbedWithProbes uint32

	// unprobedFields counts the `absent` fields on which nothing was planted:
	// the only fields that truly carry no evidence.
	unprobedFields uint32
}

func l3TallyEvidence(ev *witnesspb.L3CoverageEvidence) l3EvidenceTally {
	var t l3EvidenceTally
	fields := ev.GetFields()
	if len(fields) == 0 {
		// Nothing to attribute: the request totals are all there is. The
		// witness computes them FROM `fields`, so this is only reachable on a
		// record with no per-field entry, where the totals are zero anyway.
		t.passedPlanted = ev.GetCanariesPlanted()
		t.passedRecovered = ev.GetCanariesRecovered()
		t.unprobedFields = ev.GetFieldsAbsent()
		return t
	}
	for _, f := range fields {
		switch f.GetVerdict() {
		case "passed":
			t.passedPlanted += f.GetCanariesPlanted()
			t.passedRecovered += f.GetCanariesRecovered()
		case "absent":
			if f.GetCanariesPlanted() > 0 || f.GetProbedWindows() > 0 {
				t.partlyProbedFields++
				t.partlyProbedPlanted += f.GetCanariesPlanted()
				t.partlyProbedRecovered += f.GetCanariesRecovered()
				t.partlyProbedWindows += f.GetWindows()
				t.partlyProbedWithProbes += f.GetProbedWindows()
			} else {
				t.unprobedFields++
			}
		}
	}
	return t
}

// l3NoVerdictDetailSuffix explains the fields that carry no usable verdict,
// separating the partly probed ones (named with their measured numbers) from
// the unprobed ones (which truly carry no evidence), followed by the reason
// ledger. Empty when there is no such field. Never names the probe threshold:
// it is not in the signed record.
func l3NoVerdictDetailSuffix(ev *witnesspb.L3CoverageEvidence) string {
	t := l3TallyEvidence(ev)
	var parts []string
	if t.partlyProbedFields > 0 {
		parts = append(parts, fmt.Sprintf(
			"%d field(s) only partly probed (%d/%d planted probes recovered, %d of %d windows probed - not a usable verdict)",
			t.partlyProbedFields, t.partlyProbedRecovered, t.partlyProbedPlanted,
			t.partlyProbedWithProbes, t.partlyProbedWindows))
	}
	if t.unprobedFields > 0 {
		parts = append(parts, fmt.Sprintf("%d field(s) carry no evidence at all", t.unprobedFields))
	}
	if len(parts) == 0 {
		return ""
	}
	out := ": " + strings.Join(parts, "; ")
	if reasons := l3EvidenceAbsentPhrases(ev); len(reasons) > 0 {
		out += "; why: " + strings.Join(reasons, "; ")
	}
	return out
}

// l3EvidenceAbsentSuffix appends the reason ledger to the all-absent wording,
// or nothing when the record recorded no field at all.
func l3EvidenceAbsentSuffix(ev *witnesspb.L3CoverageEvidence) string {
	phrases := l3EvidenceAbsentPhrases(ev)
	if len(phrases) == 0 {
		return ""
	}
	return " (" + strings.Join(phrases, "; ") + ")"
}

// buildL3ComposedLine renders the locked composition rule's output.
//
//	green ⟺ (every ELIGIBLE field is COVERED)
//	      ∧ (every COVERED field's evidence PASSED)
//	      ∧ (exclusions and receipts are NAMED)
//
// Empty when no evidence record was readable: there is then nothing composed
// to report, and printing "not green" over an absent record would read as a
// finding about the scan rather than about the record.
func buildL3ComposedLine(ev *witnesspb.L3CoverageEvidence, status string) string {
	if status != "present" {
		return ""
	}
	if ev.GetComposedGreen() {
		return "Composed completeness rule (scope AND recall AND named exclusions): GRANTED - " +
			l3ComposedReasonMeaning(ev.GetComposedReason()) + "."
	}
	return "Composed completeness rule (scope AND recall AND named exclusions): NOT granted - " +
		l3ComposedReasonMeaning(ev.GetComposedReason()) + "."
}

// L3CompletenessWithCaveat renders the completeness verdict word with the
// caveat that stops it being read as a detection claim.
//
// ⛔ THE BARE WORD IS THE DEFECT. "Full" alone was the string on the public
// summary, the PDF and (as COMPLETENESS_FULL) the DPO page; the T-600 PRD's
// grep-verifiable success criterion is that it is gone. Every caller renders
// THIS, never capitalizeFirst(completeness) on its own.
func L3CompletenessWithCaveat(completeness string) string {
	word := capitalizeFirst(completeness)
	if word == "" {
		word = "Unspecified"
	}
	return word + " - " + L3CompletenessMeaning
}

// capitalizeFirst upper-cases the first rune. Upstream has its own copy in
// package api; kept here rather than exported from there so the two files stay
// independently portable.
func capitalizeFirst(s string) string {
	if s == "" {
		return ""
	}
	r, size := utf8.DecodeRuneInString(s)
	return string(unicode.ToUpper(r)) + s[size:]
}
