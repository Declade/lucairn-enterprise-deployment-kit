package witness

import (
	"context"
	"fmt"
	"net"
	"strings"
	"testing"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/testutil"
	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// ---------------------------------------------------------------------------
// T-600 S3 / T-617 S3 — the vendored proto actually decodes fields 13 + 14.
// ---------------------------------------------------------------------------
//
// ⚑ THE FAILURE THIS CLOSES IS SILENT. A consumer whose vendored schema stops
// at field 9 does not error on a certificate carrying 13 and 14: proto3 drops
// unknown fields, and the page renders "unavailable" over a record that was
// right there on the wire. Constructing the message in-process would not catch
// it either — the encode and the decode would share the same (stale) schema.
// These tests therefore serve the records over a REAL gRPC connection from a
// server built on the same vendored stubs and assert the client's rendered
// narrative carries what the server sent.

// l3ShapeServer serves one scripted VerificationResult over bufconn.
type l3ShapeServer struct {
	witnesspb.UnimplementedVeilCertificateServiceServer
	result *witnesspb.VerificationResult
}

func (s *l3ShapeServer) GetCertificate(_ context.Context, _ *witnesspb.GetCertificateRequest) (*witnesspb.VeilCertificate, error) {
	return newFakeCert(), nil
}

func (s *l3ShapeServer) VerifyCertificate(_ context.Context, _ *witnesspb.VeilCertificate) (*witnesspb.VerificationResult, error) {
	return s.result, nil
}

// verifyOverWire dials a bufconn witness serving `result` and returns what the
// dashboard's own client made of it.
func verifyOverWire(t *testing.T, result *witnesspb.VerificationResult) VerifyResult {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	witnesspb.RegisterVeilCertificateServiceServer(srv, &l3ShapeServer{result: result})
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient(
		"passthrough://bufnet",
		grpc.WithContextDialer(func(_ context.Context, _ string) (net.Conn, error) { return lis.Dial() }),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	c := NewClientWithRPC(witnesspb.NewVeilCertificateServiceClient(conn))
	out, err := c.Verify(context.Background(), "req-l3-roundtrip")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	return out
}

// TestVerify_L3CoverageFieldsRoundTripOverTheWire proves the vendored schema
// decodes BOTH new fields and that the client turns them into the operator
// narrative. The per-field evidence rows come from the upstream producer
// corpus (see l3_fixtures_test.go).
func TestVerify_L3CoverageFieldsRoundTripOverTheWire(t *testing.T) {
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

	got := verifyOverWire(t, &witnesspb.VerificationResult{
		OverallVerdict:     witnesspb.Verdict_VERDICT_PARTIAL,
		Completeness:       witnesspb.Completeness_COMPLETENESS_FULL,
		SignaturesValid:    true,
		IsolationVerified:  true,
		L3CoverageScope:    scope,
		L3CoverageEvidence: ev,
	})

	if got.L3Coverage.ScopeStatus != "present" {
		t.Errorf("scope record did not survive the wire: status=%q", got.L3Coverage.ScopeStatus)
	}
	if got.L3Coverage.EvidenceStatus != "present" {
		t.Errorf("evidence record did not survive the wire: status=%q", got.L3Coverage.EvidenceStatus)
	}
	if got.L3Coverage.EvidenceRollup != "verified" {
		t.Errorf("rollup: got %q want verified", got.L3Coverage.EvidenceRollup)
	}
	if got.L3Coverage.DrivesVerdict {
		t.Errorf("drives_verdict must be false in every shipped build")
	}
	if !strings.Contains(got.L3Coverage.Scope, "covered 2 of 2 fields eligible for it") {
		t.Errorf("scope line lost the counts: %q", got.L3Coverage.Scope)
	}
	if !strings.Contains(got.L3Coverage.Scope, "1 field(s) were excluded by policy: 1 x the zone policy excludes the deep shield for that zone") {
		t.Errorf("scope line lost the exclusion ledger: %q", got.L3Coverage.Scope)
	}
	if !strings.Contains(got.L3Coverage.Evidence, "Coverage evidence check passed (16/16 probes recovered)") {
		t.Errorf("evidence line lost the counts: %q", got.L3Coverage.Evidence)
	}
	// ⛔ A cert can carry a granted scope + passing evidence and still be
	// PARTIAL — the records are dark. Assert the pair, so a future change
	// that quietly couples them fails here.
	if got.OverallVerdict != "partial" {
		t.Errorf("verdict must be untouched by the records: got %q", got.OverallVerdict)
	}
	if got.CompletenessDisplay == "Full" || got.CompletenessDisplay == "full" {
		t.Errorf("completeness must never render as the bare word: %q", got.CompletenessDisplay)
	}
	if !strings.HasPrefix(got.CompletenessDisplay, "Full - ") {
		t.Errorf("completeness display: got %q", got.CompletenessDisplay)
	}
}

// TestVerify_ToleratesCertificatesWithoutTheL3Fields is the compatibility half:
// every certificate minted by a pre-#607/#608 witness carries NEITHER field.
// That must render as "unavailable" — never an error, never a clean bill of
// health.
func TestVerify_ToleratesCertificatesWithoutTheL3Fields(t *testing.T) {
	t.Parallel()
	got := verifyOverWire(t, &witnesspb.VerificationResult{
		OverallVerdict:    witnesspb.Verdict_VERDICT_VERIFIED,
		Completeness:      witnesspb.Completeness_COMPLETENESS_PARTIAL,
		SignaturesValid:   true,
		IsolationVerified: true,
	})

	if got.Error != "" {
		t.Fatalf("a legacy certificate must not produce a verify error: %q", got.Error)
	}
	if got.OverallVerdict != "verified" {
		t.Errorf("verdict: got %q want verified", got.OverallVerdict)
	}
	if got.L3Coverage.ScopeStatus != "absent" || got.L3Coverage.EvidenceStatus != "absent" {
		t.Errorf("missing records must read absent; got scope=%q evidence=%q",
			got.L3Coverage.ScopeStatus, got.L3Coverage.EvidenceStatus)
	}
	if !strings.HasPrefix(got.L3Coverage.Scope, "Coverage scope unavailable -") {
		t.Errorf("scope line: got %q", got.L3Coverage.Scope)
	}
	if !strings.HasPrefix(got.L3Coverage.Evidence, "Recall evidence unavailable -") {
		t.Errorf("evidence line: got %q", got.L3Coverage.Evidence)
	}
	if got.L3Coverage.Composed != "" {
		t.Errorf("nothing composes over an absent record: %q", got.L3Coverage.Composed)
	}
	if got.L3Coverage.Ceiling != L3CoverageCeiling {
		t.Errorf("the ceiling must be carried on a legacy certificate too")
	}
	for _, s := range []string{got.L3Coverage.Scope, got.L3Coverage.Evidence} {
		assertNoBannedPhrase(t, "legacy-cert", s)
	}
}

// TestVerify_L3RecordsAreTwoDISTINCTFields serves a scope record and an
// evidence record carrying DIFFERENT statuses and asserts each lands in its own
// slot. It catches a vendored schema that crossed the two messages over or
// dropped one.
//
// ⚑ NON-COVERAGE, stated because the obvious reading is wrong: this cannot
// catch a renumber, because the bufconn server is built from the SAME vendored
// stubs as the client — a consistent renumber encodes and decodes happily.
// Agreement with UPSTREAM numbers is asserted from the descriptor instead, by
// TestL3Descriptor_MatchesUpstreamFieldNumbers.
func TestVerify_L3RecordsAreTwoDISTINCTFields(t *testing.T) {
	t.Parallel()
	got := verifyOverWire(t, &witnesspb.VerificationResult{
		SignaturesValid: true,
		L3CoverageScope: &witnesspb.L3CoverageScope{
			RecordStatus: "unsupported_derivation",
		},
		L3CoverageEvidence: &witnesspb.L3CoverageEvidence{
			RecordStatus: "malformed",
		},
	})
	if got.L3Coverage.ScopeStatus != "unsupported_derivation" {
		t.Errorf("scope record decoded wrong: status = %q", got.L3Coverage.ScopeStatus)
	}
	if got.L3Coverage.EvidenceStatus != "malformed" {
		t.Errorf("evidence record decoded wrong: status = %q", got.L3Coverage.EvidenceStatus)
	}
	if !strings.Contains(got.L3Coverage.Scope, "produced by a rule version this witness build does not know") {
		t.Errorf("scope line: got %q", got.L3Coverage.Scope)
	}
	if !strings.Contains(got.L3Coverage.Evidence, "REFUSED it") {
		t.Errorf("evidence line: got %q", got.L3Coverage.Evidence)
	}
}

// upstreamL3Field is one upstream field declaration: name, scalar kind,
// cardinality and — for message fields — the target message's full name.
type upstreamL3Field struct {
	name    string
	kind    protoreflect.Kind
	card    protoreflect.Cardinality
	message string // full name of the target message; "" for scalar fields
}

// Shorthands so the table below reads like the .proto it transcribes.
func l3Str(name string) upstreamL3Field {
	return upstreamL3Field{name, protoreflect.StringKind, protoreflect.Optional, ""}
}
func l3Bool(name string) upstreamL3Field {
	return upstreamL3Field{name, protoreflect.BoolKind, protoreflect.Optional, ""}
}
func l3U32(name string) upstreamL3Field {
	return upstreamL3Field{name, protoreflect.Uint32Kind, protoreflect.Optional, ""}
}
func l3Msg(name, msg string) upstreamL3Field {
	return upstreamL3Field{name, protoreflect.MessageKind, protoreflect.Optional, msg}
}
func l3RepMsg(name, msg string) upstreamL3Field {
	return upstreamL3Field{name, protoreflect.MessageKind, protoreflect.Repeated, msg}
}
func l3RepStr(name string) upstreamL3Field {
	return upstreamL3Field{name, protoreflect.StringKind, protoreflect.Repeated, ""}
}

// upstreamL3Fields is the field table transcribed from the vendoring source:
//
//	Declade/dual-sandbox-architecture @ 91941304fd3ba30779d81121c37c436a631f4089
//	proto/veil/v1/veil.proto
//
// It is the INDEPENDENT REFERENCE for the drift test below — a literal copy of
// what upstream declares, not something read back out of the generated stubs.
// Wire compatibility with a live witness rests entirely on these numbers AND
// their encodings, and a vendored copy is exactly the artifact that drifts
// silently.
//
// ⚑ T-881 (astra post-merge audit of kit #136, finding 3): the table used to
// carry names only, so `uint32` -> `fixed32` (same name, same number, same Go
// type, DIFFERENT wire encoding) passed. It now pins kind, cardinality and
// message target for every field; upstream is proto3 with no `optional`
// keyword, so every singular field is protoreflect.Optional.
var upstreamL3Fields = map[string]map[int32]upstreamL3Field{
	"dsa.veil.v1.VerificationResult": {
		13: l3Msg("l3_coverage_scope", "dsa.veil.v1.L3CoverageScope"),
		14: l3Msg("l3_coverage_evidence", "dsa.veil.v1.L3CoverageEvidence"),
	},
	"dsa.veil.v1.L3CoverageEvidence": {
		1: l3Str("record_status"), 2: l3Str("derivation_version"), 3: l3Bool("drives_verdict"),
		4: l3Str("rollup"), 5: l3Bool("composed_green"), 6: l3Str("composed_reason"),
		7: l3RepMsg("fields", "dsa.veil.v1.L3FieldEvidence"),
		8: l3U32("canaries_planted"), 9: l3U32("canaries_recovered"),
		10: l3U32("fields_passed"), 11: l3U32("fields_failed"), 12: l3U32("fields_absent"),
	},
	"dsa.veil.v1.L3FieldEvidence": {
		1: l3Str("field_key"), 2: l3Str("verdict"), 3: l3Str("reason"),
		4: l3U32("canaries_planted"), 5: l3U32("canaries_recovered"),
		6: l3U32("windows"), 7: l3U32("probed_windows"),
	},
	"dsa.veil.v1.L3CoverageScope": {
		1: l3Str("record_status"), 2: l3Str("derivation_version"), 3: l3Bool("drives_claim"),
		4: l3Bool("granted"), 5: l3Str("reason"), 6: l3U32("eligible_count"),
		7: l3RepMsg("covered", "dsa.veil.v1.L3CoveredField"),
		8: l3RepStr("eligible_not_covered"),
		9: l3RepMsg("excluded", "dsa.veil.v1.L3ExcludedField"),
	},
	"dsa.veil.v1.L3CoveredField": {
		1: l3Str("field_key"), 2: l3Str("via"), 3: l3Str("receipt_id"), 4: l3Str("source_claim_id"),
	},
	"dsa.veil.v1.L3ExcludedField": {
		1: l3Str("field_key"), 2: l3Str("zone"), 3: l3Str("reason"),
	},
}

// checkL3FieldAgainstUpstream returns every way fd disagrees with want.
// Split out so the mutation control can prove each comparison bites.
func checkL3FieldAgainstUpstream(fd protoreflect.FieldDescriptor, want upstreamL3Field) []string {
	var errs []string
	if string(fd.Name()) != want.name {
		errs = append(errs, fmt.Sprintf("name %q, upstream %q", fd.Name(), want.name))
	}
	if fd.Kind() != want.kind {
		errs = append(errs, fmt.Sprintf("kind %v, upstream %v", fd.Kind(), want.kind))
	}
	if fd.Cardinality() != want.card {
		errs = append(errs, fmt.Sprintf("cardinality %v, upstream %v", fd.Cardinality(), want.card))
	}
	var gotMsg string
	if fd.Message() != nil {
		gotMsg = string(fd.Message().FullName())
	}
	if gotMsg != want.message {
		errs = append(errs, fmt.Sprintf("message target %q, upstream %q", gotMsg, want.message))
	}
	return errs
}

// TestL3Descriptor_MatchesUpstreamFieldNumbers asserts the vendored schema
// agrees with upstream on every field number and name the L3 records use, and
// that the two VerificationResult slots point at the right message types.
//
// ⚑ THIS IS THE ONE THAT CATCHES A RENUMBER. Every in-process or bufconn test
// encodes and decodes with the same stubs, so it cannot notice that both ends
// moved together; only a comparison against upstream's own numbers can.
func TestL3Descriptor_MatchesUpstreamFieldNumbers(t *testing.T) {
	t.Parallel()
	msgs := map[string]proto.Message{
		"dsa.veil.v1.VerificationResult": (*witnesspb.VerificationResult)(nil),
		"dsa.veil.v1.L3CoverageEvidence": (*witnesspb.L3CoverageEvidence)(nil),
		"dsa.veil.v1.L3FieldEvidence":    (*witnesspb.L3FieldEvidence)(nil),
		"dsa.veil.v1.L3CoverageScope":    (*witnesspb.L3CoverageScope)(nil),
		"dsa.veil.v1.L3CoveredField":     (*witnesspb.L3CoveredField)(nil),
		"dsa.veil.v1.L3ExcludedField":    (*witnesspb.L3ExcludedField)(nil),
	}
	checked := 0
	for full, want := range upstreamL3Fields {
		m, ok := msgs[full]
		if !ok {
			t.Fatalf("no vendored message registered for %s", full)
		}
		md := m.ProtoReflect().Descriptor()
		if string(md.FullName()) != full {
			t.Fatalf("vendored message full name: got %q want %q", md.FullName(), full)
		}
		if got, wantN := md.Fields().Len(), len(want); full != "dsa.veil.v1.VerificationResult" && got != wantN {
			t.Errorf("%s: vendored schema declares %d fields, upstream %d", full, got, wantN)
		}
		for num, spec := range want {
			fd := md.Fields().ByNumber(protowire.Number(num))
			if fd == nil {
				t.Errorf("%s: field number %d is missing from the vendored schema (upstream calls it %q)", full, num, spec.name)
				continue
			}
			for _, e := range checkL3FieldAgainstUpstream(fd, spec) {
				t.Errorf("%s field %d: %s", full, num, e)
			}
			checked++
		}
	}
	if checked != 37 {
		t.Fatalf("checked %d fields (name+kind+cardinality+message), want 37 — the reference table changed shape", checked)
	}

	// The two VerificationResult slots' MESSAGE targets are now pinned by the
	// table itself (matching numbers over the wrong type decodes into garbage).
	vr := (*witnesspb.VerificationResult)(nil).ProtoReflect().Descriptor()

	// Fields 10-12 are deliberately NOT vendored (see the gap note in
	// witness.proto). Pin that so a future partial sync is a conscious edit
	// rather than an accident — and so the gap note cannot go stale.
	for _, num := range []int32{10, 11, 12} {
		if fd := vr.Fields().ByNumber(protowire.Number(num)); fd != nil {
			t.Errorf("VerificationResult field %d (%q) is now vendored — update the gap note in witness.proto", num, fd.Name())
		}
	}
}

// TestL3Descriptor_GuardCatchesEncodingDrift is the mutation control for the
// guard above (T-881): the exact drift astra reproduced — `uint32` ->
// `fixed32` on canaries_recovered, same name and number and Go type — must be
// reported, as must a cardinality flip and a wrong message target.
func TestL3Descriptor_GuardCatchesEncodingDrift(t *testing.T) {
	t.Parallel()
	ev := (*witnesspb.L3CoverageEvidence)(nil).ProtoReflect().Descriptor()
	vr := (*witnesspb.VerificationResult)(nil).ProtoReflect().Descriptor()
	cases := []struct {
		name string
		fd   protoreflect.FieldDescriptor
		want upstreamL3Field
	}{
		{"uint32 declared fixed32 upstream", ev.Fields().ByNumber(9),
			upstreamL3Field{"canaries_recovered", protoreflect.Fixed32Kind, protoreflect.Optional, ""}},
		{"singular declared repeated upstream", ev.Fields().ByNumber(4),
			upstreamL3Field{"rollup", protoreflect.StringKind, protoreflect.Repeated, ""}},
		{"repeated declared singular upstream", ev.Fields().ByNumber(7),
			upstreamL3Field{"fields", protoreflect.MessageKind, protoreflect.Optional, "dsa.veil.v1.L3FieldEvidence"}},
		{"wrong message target", vr.Fields().ByNumber(13),
			upstreamL3Field{"l3_coverage_scope", protoreflect.MessageKind, protoreflect.Optional, "dsa.veil.v1.L3CoverageEvidence"}},
	}
	for _, tc := range cases {
		if tc.fd == nil {
			t.Fatalf("%s: fixture field missing", tc.name)
		}
		if errs := checkL3FieldAgainstUpstream(tc.fd, tc.want); len(errs) == 0 {
			t.Errorf("%s: guard accepted a drifted declaration", tc.name)
		}
	}
	// And the real table is accepted field by field (control the other way).
	if errs := checkL3FieldAgainstUpstream(ev.Fields().ByNumber(9), upstreamL3Fields["dsa.veil.v1.L3CoverageEvidence"][9]); len(errs) != 0 {
		t.Errorf("guard rejects the true declaration: %v", errs)
	}
}
