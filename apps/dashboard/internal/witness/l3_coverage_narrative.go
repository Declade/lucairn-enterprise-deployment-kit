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
// bare completeness enum — `{{ .Result.Completeness }}` — over a record whose
// own source file says (dual-sandbox-architecture services/sanitizer/
// l3_coverage.py:13-14):
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
// ⛔ THE CEILING IS THE POINT (Marc lock 4, standing). Coverage is NECESSARY
// for a completeness claim and can NEVER be SUFFICIENT. Every render that
// mentions coverage or recall evidence carries L3CoverageCeiling, and the
// phrases "all PII", "complete detection", "everything was scanned" and
// "everything was found" are banned from every string this file can produce —
// pinned by TestL3CoverageNarrative_NeverClaimsCompleteDetection.
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
// This mirrors the boundary the upstream public summary already holds.
//
// SAME WORDS AS UPSTREAM. The strings below are the ones the gateway's own
// reader surfaces render (dual-sandbox-architecture services/gateway/internal/
// api/veil_l3_coverage_render.go). Two surfaces phrasing the same record
// differently is how a caveat quietly stops being carried on the one an
// auditor actually reads.

// L3CoverageCeiling is the one-line claim ceiling. It appears on EVERY surface
// that renders coverage or recall evidence, verbatim.
const L3CoverageCeiling = "Coverage ceiling: this names which protection layers ran over which fields. " +
	"It is never a claim that the scan detected every piece of personal data in the request."

// L3CoverageDiagnosticOnly is rendered while the records drive nothing.
const L3CoverageDiagnosticOnly = "Diagnostic only: the coverage and recall-evidence lines above are recorded for " +
	"measurement and do not yet change this certificate's verdict."

// L3CompletenessMeaning is the caveat pinned to the completeness verdict word
// itself. `completeness` is a CHAIN property — "every claim the pipeline was
// expected to file is present and verified" — and says nothing about detection
// recall. Rendering the word alone is the reader-inference gap in one cell.
const L3CompletenessMeaning = "completeness describes the CLAIM CHAIN (which pipeline claims are present and " +
	"verified), not detection recall — see coverage below"

// L3CoverageNarrative is the rendered plain-language coverage story. Every
// field is a complete sentence or empty; the template renders the non-empty
// ones in order and is never required to compose text of its own.
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
	// Ceiling is L3CoverageCeiling. Never empty — the template keys the whole
	// coverage block on it, so an empty Ceiling means "no narrative was built"
	// (a zero-value VerifyResult on the witness-unreachable path), never "the
	// ceiling did not apply".
	Ceiling string

	// ScopeStatus / EvidenceStatus / EvidenceRollup are the raw closed-
	// vocabulary tokens, so an operator can read the machine state without
	// parsing prose. They carry no field keys, receipt ids, source claim ids
	// or zone names.
	ScopeStatus    string
	EvidenceStatus string
	EvidenceRollup string
	// DrivesVerdict mirrors L3CoverageEvidence.drives_verdict. False in every
	// shipped build.
	DrivesVerdict bool
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

// L3CompletenessWithCaveat renders the completeness verdict word with the
// caveat that stops it being read as a detection claim.
//
// ⛔ THE BARE WORD IS THE DEFECT. `{{ .Result.Completeness }}` alone was the
// string in inspector.html.tmpl; the T-600 PRD's grep-verifiable success
// criterion is that it is gone. The template renders THIS, never the raw
// enum string on its own.
func L3CompletenessWithCaveat(completeness string) string {
	word := capitalizeFirst(completeness)
	if word == "" {
		word = "Unspecified"
	}
	return word + " — " + L3CompletenessMeaning
}

func capitalizeFirst(s string) string {
	if s == "" {
		return ""
	}
	r, size := utf8.DecodeRuneInString(s)
	return string(unicode.ToUpper(r)) + s[size:]
}

// l3RecordStatusMeaning renders a record_status token in plain words. The
// vocabulary is shared by L3CoverageScope and L3CoverageEvidence and pinned
// equal across them upstream by
// TestL3Evidence_StatusVocabularyMatchesTheScopeRecord.
func l3RecordStatusMeaning(status string) string {
	switch status {
	case "absent":
		return "this certificate carries no such record — the sanitizer that minted it predates the feature, " +
			"or the deployment has it switched off"
	case "malformed":
		return "the witness was handed a record and REFUSED it, so none of it is reproduced"
	case "unsupported_derivation":
		return "the record was produced by a rule version this witness build does not know, so it is not reproduced"
	case "not_checked":
		return "the claim chain did not authenticate, so the record was never examined"
	case "":
		return "unknown — this certificate was minted or re-verified by a witness build that predates the record"
	default:
		return "unrecognised record state " + l3Quote(status)
	}
}

// l3Quote quotes an out-of-vocabulary token so an unexpected value is visibly
// a token rather than prose the reader might mistake for a finding.
func l3Quote(s string) string { return "\"" + s + "\"" }

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
func l3EvidenceAbsentReasonMeaning(reason string) string {
	switch reason {
	case "probe_off":
		return "the recall probe is not armed on this deployment"
	case "no_l3_window":
		return "the deep shield ran no window on that field"
	case "window_below_probe_floor":
		return "the text was shorter than the size the probe's overhead was measured at"
	case "window_served_from_verdict_cache":
		return "the result was served from the deep shield's verdict cache, so no inference ran"
	case "output_headroom_clipped":
		return "the model's output budget could not hold the probe without starving the real scan"
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
		return "every eligible field was covered, every covered field's recall check came back, " +
			"and the exclusions and receipts are named"
	case "scope_unavailable":
		return "the scope record is missing or was refused, so the first half of the rule cannot be evaluated"
	case "evidence_unavailable":
		return "no recall evidence was carried on this certificate"
	case "evidence_failed":
		return "a field's recall check MISSED — the deep shield did not return the probes planted in it"
	case "scope_not_granted":
		return "the scope record itself did not grant"
	case "evidence_absent_for_covered_field":
		return "a field the scope record says was freshly scanned carries no passing recall evidence"
	case "evidence_on_excluded_field":
		return "the two records disagree — the scope record calls a field policy-excluded while the " +
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

// buildL3ScopeLine renders the SCOPE half (proto field 13).
func buildL3ScopeLine(scope *witnesspb.L3CoverageScope, status string) string {
	if status != "present" {
		return "Coverage scope unavailable — " + l3RecordStatusMeaning(status) +
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
		b.WriteString("Scope check: granted — " + l3ScopeReasonMeaning(scope.GetReason()) + ".")
	} else {
		b.WriteString("Scope check: NOT granted — " + l3ScopeReasonMeaning(scope.GetReason()) + ".")
	}
	return b.String()
}

// l3ExclusionReasonPhrases renders the exclusion ledger as "<n> × <reason in
// plain words>" phrases, sorted for stable output.
//
// It names REASONS and COUNTS and deliberately not field keys or zone names —
// see the DISCLOSURE BOUNDARY note at the top of this file.
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
		out = append(out, fmt.Sprintf("%d × %s", counts[r], l3ExclusionReasonMeaning(r)))
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
		return "Recall evidence unavailable — " + l3RecordStatusMeaning(status) +
			". This is NOT a statement that the scan was clean."
	}

	planted := ev.GetCanariesPlanted()
	recovered := ev.GetCanariesRecovered()
	passed := ev.GetFieldsPassed()
	failed := ev.GetFieldsFailed()
	absent := ev.GetFieldsAbsent()

	switch ev.GetRollup() {
	case "verified":
		return fmt.Sprintf(
			"Coverage evidence check passed (%d/%d probes recovered) across %d field(s). "+
				"That means the recall CHECK ran on every field carrying one and every planted probe came back.",
			recovered, planted, passed)
	case "failed":
		return fmt.Sprintf(
			"Coverage evidence check FAILED — %d field(s) returned fewer planted probes than required "+
				"(%d/%d recovered across the request; %d field(s) passed, %d carry no evidence). "+
				"A measured miss is positive evidence of a recall gap.",
			failed, recovered, planted, passed, absent)
	case "unverified":
		return fmt.Sprintf(
			"Coverage evidence check is INCOMPLETE — %d field(s) passed (%d/%d probes recovered) and "+
				"%d field(s) carry no evidence: %s. A partly evidenced request is not a verified one.",
			passed, recovered, planted, absent, strings.Join(l3EvidenceAbsentPhrases(ev), "; "))
	case "absent":
		return "Coverage evidence check did not run on this request — no field carried a recall probe" +
			l3EvidenceAbsentSuffix(ev) + ". Evidence that does not exist is not evidence of success."
	default:
		return "Recall evidence unavailable — the evidence rollup is " + l3Quote(ev.GetRollup()) +
			", which this build does not recognise. This is NOT a statement that the scan was clean."
	}
}

// l3EvidenceAbsentPhrases renders the absent-reason ledger as "<n> × <reason
// in plain words>" phrases, sorted. Field keys are deliberately not rendered —
// same reasoning as l3ExclusionReasonPhrases.
func l3EvidenceAbsentPhrases(ev *witnesspb.L3CoverageEvidence) []string {
	counts := map[string]int{}
	for _, f := range ev.GetFields() {
		if f.GetVerdict() != "absent" {
			continue
		}
		counts[f.GetReason()]++
	}
	reasons := make([]string, 0, len(counts))
	for r := range counts {
		reasons = append(reasons, r)
	}
	sort.Strings(reasons)
	out := make([]string, 0, len(reasons))
	for _, r := range reasons {
		out = append(out, fmt.Sprintf("%d × %s", counts[r], l3EvidenceAbsentReasonMeaning(r)))
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
		return "Composed completeness rule (scope AND recall AND named exclusions): GRANTED — " +
			l3ComposedReasonMeaning(ev.GetComposedReason()) + "."
	}
	return "Composed completeness rule (scope AND recall AND named exclusions): NOT granted — " +
		l3ComposedReasonMeaning(ev.GetComposedReason()) + "."
}
