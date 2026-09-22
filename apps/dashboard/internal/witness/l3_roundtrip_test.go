package witness

import (
	"context"
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

// upstreamL3Fields is the field table transcribed from the vendoring source:
//
//	Declade/dual-sandbox-architecture @ 91941304fd3ba30779d81121c37c436a631f4089
//	proto/veil/v1/veil.proto
//
// It is the INDEPENDENT REFERENCE for the drift test below — a literal copy of
// what upstream declares, not something read back out of the generated stubs.
// Wire compatibility with a live witness rests entirely on these numbers, and
// a vendored copy is exactly the artifact that drifts silently.
var upstreamL3Fields = map[string]map[int32]string{
	"dsa.veil.v1.VerificationResult": {
		13: "l3_coverage_scope",
		14: "l3_coverage_evidence",
	},
	"dsa.veil.v1.L3CoverageEvidence": {
		1: "record_status", 2: "derivation_version", 3: "drives_verdict",
		4: "rollup", 5: "composed_green", 6: "composed_reason", 7: "fields",
		8: "canaries_planted", 9: "canaries_recovered",
		10: "fields_passed", 11: "fields_failed", 12: "fields_absent",
	},
	"dsa.veil.v1.L3FieldEvidence": {
		1: "field_key", 2: "verdict", 3: "reason",
		4: "canaries_planted", 5: "canaries_recovered",
		6: "windows", 7: "probed_windows",
	},
	"dsa.veil.v1.L3CoverageScope": {
		1: "record_status", 2: "derivation_version", 3: "drives_claim",
		4: "granted", 5: "reason", 6: "eligible_count", 7: "covered",
		8: "eligible_not_covered", 9: "excluded",
	},
	"dsa.veil.v1.L3CoveredField": {
		1: "field_key", 2: "via", 3: "receipt_id", 4: "source_claim_id",
	},
	"dsa.veil.v1.L3ExcludedField": {
		1: "field_key", 2: "zone", 3: "reason",
	},
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
		for num, name := range want {
			fd := md.Fields().ByNumber(protowire.Number(num))
			if fd == nil {
				t.Errorf("%s: field number %d is missing from the vendored schema (upstream calls it %q)", full, num, name)
				continue
			}
			if string(fd.Name()) != name {
				t.Errorf("%s: field %d is %q in the vendored schema, %q upstream", full, num, fd.Name(), name)
			}
			checked++
		}
	}
	if checked != 37 {
		t.Fatalf("checked %d field numbers, want 37 — the reference table changed shape", checked)
	}

	// The two VerificationResult slots must point at the right MESSAGE types;
	// matching numbers over the wrong type still decodes into garbage.
	vr := (*witnesspb.VerificationResult)(nil).ProtoReflect().Descriptor()
	for num, wantType := range map[int32]string{
		13: "dsa.veil.v1.L3CoverageScope",
		14: "dsa.veil.v1.L3CoverageEvidence",
	} {
		fd := vr.Fields().ByNumber(protowire.Number(num))
		if fd == nil {
			t.Fatalf("VerificationResult field %d missing", num)
		}
		if fd.Message() == nil || string(fd.Message().FullName()) != wantType {
			t.Errorf("VerificationResult field %d type: got %v want %s", num, fd.Message(), wantType)
		}
	}

	// Fields 10-12 are deliberately NOT vendored (see the gap note in
	// witness.proto). Pin that so a future partial sync is a conscious edit
	// rather than an accident — and so the gap note cannot go stale.
	for _, num := range []int32{10, 11, 12} {
		if fd := vr.Fields().ByNumber(protowire.Number(num)); fd != nil {
			t.Errorf("VerificationResult field %d (%q) is now vendored — update the gap note in witness.proto", num, fd.Name())
		}
	}
}
