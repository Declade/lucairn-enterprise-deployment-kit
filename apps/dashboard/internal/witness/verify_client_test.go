package witness

import (
	"context"
	"errors"
	"testing"
	"time"

	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
	"google.golang.org/grpc"
)

// fakeRPC is an in-memory implementation of witnesspb.CertVerifierClient.
// It tracks how many times VerifyCertificate is invoked so the cache
// behavior can be asserted.
type fakeRPC struct {
	calls    int
	response *witnesspb.VerifyCertificateResponse
	err      error
}

func (f *fakeRPC) VerifyCertificate(_ context.Context, _ *witnesspb.VerifyCertificateRequest, _ ...grpc.CallOption) (*witnesspb.VerifyCertificateResponse, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	return f.response, nil
}

func newFakeResponse() *witnesspb.VerifyCertificateResponse {
	return &witnesspb.VerifyCertificateResponse{
		OverallVerdict:    "verified",
		Completeness:      "full",
		SignaturesValid:   true,
		ByokExempt:        false,
		IsolationVerified: true,
		TsaTimestamp:      "https://freetsa.org/tsr/123",
		RekorUuid:         "abc-123",
		CertUrl:           "https://example.com/verify/c1",
		PerClaim: []*witnesspb.PerClaimVerdict{
			{ClaimType: "gateway", Verdict: "ok", PubKeyFingerprint: "g-fp-aaaaaaaaaaaaaaaaaa", SignatureHex: "g-sig-aaaaaaaaaaaaaaaaaa"},
			{ClaimType: "bridge", Verdict: "ok", PubKeyFingerprint: "b-fp-aaaaaaaaaaaaaaaaaa", SignatureHex: "b-sig-aaaaaaaaaaaaaaaaaa"},
			{ClaimType: "sanitizer", Verdict: "ok", PubKeyFingerprint: "s-fp-aaaaaaaaaaaaaaaaaa", SignatureHex: "s-sig-aaaaaaaaaaaaaaaaaa"},
			{ClaimType: "sandbox_a", Verdict: "ok", PubKeyFingerprint: "sa-fp", SignatureHex: "sa-sig"},
			{ClaimType: "sandbox_b", Verdict: "ok", PubKeyFingerprint: "sb-fp", SignatureHex: "sb-sig"},
			{ClaimType: "witness", Verdict: "ok", PubKeyFingerprint: "w-fp", SignatureHex: "w-sig"},
		},
	}
}

func TestClient_Verify_CacheMissThenHit(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 5, 18, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	rpc := &fakeRPC{response: newFakeResponse()}
	c := NewClientWithRPC(rpc, WithClock(clock), WithCacheTTL(5*time.Minute))

	first, err := c.Verify(context.Background(), "cert-1")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if first.OverallVerdict != "verified" {
		t.Errorf("verdict: got %q want %q", first.OverallVerdict, "verified")
	}
	if len(first.PerClaim) != 6 {
		t.Fatalf("per-claim: got %d want 6", len(first.PerClaim))
	}
	if first.PerClaim[0].ClaimType != "gateway" {
		t.Errorf("per-claim order: first must be gateway, got %s", first.PerClaim[0].ClaimType)
	}
	if rpc.calls != 1 {
		t.Errorf("rpc calls after miss: got %d want 1", rpc.calls)
	}

	// Second call within TTL: cache hit, rpc.calls stays at 1.
	second, err := c.Verify(context.Background(), "cert-1")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if rpc.calls != 1 {
		t.Errorf("rpc calls after hit: got %d want 1 (cache should serve)", rpc.calls)
	}
	if second.OverallVerdict != first.OverallVerdict {
		t.Errorf("cache returned different value than first")
	}
}

func TestClient_Verify_CacheExpires(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 5, 18, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	rpc := &fakeRPC{response: newFakeResponse()}
	c := NewClientWithRPC(rpc, WithClock(clock), WithCacheTTL(5*time.Minute))

	if _, err := c.Verify(context.Background(), "cert-1"); err != nil {
		t.Fatalf("verify 1: %v", err)
	}
	// Advance the clock past the TTL window.
	now = now.Add(6 * time.Minute)
	if _, err := c.Verify(context.Background(), "cert-1"); err != nil {
		t.Fatalf("verify 2: %v", err)
	}
	if rpc.calls != 2 {
		t.Errorf("rpc calls after TTL expiry: got %d want 2 (cache should miss)", rpc.calls)
	}
}

func TestClient_Invalidate_BypassesCache(t *testing.T) {
	t.Parallel()
	rpc := &fakeRPC{response: newFakeResponse()}
	c := NewClientWithRPC(rpc)
	if _, err := c.Verify(context.Background(), "cert-1"); err != nil {
		t.Fatalf("verify 1: %v", err)
	}
	c.Invalidate("cert-1")
	if _, err := c.Verify(context.Background(), "cert-1"); err != nil {
		t.Fatalf("verify 2: %v", err)
	}
	if rpc.calls != 2 {
		t.Errorf("rpc calls after Invalidate: got %d want 2", rpc.calls)
	}
}

func TestClient_Verify_EmptyCertIDRejected(t *testing.T) {
	t.Parallel()
	rpc := &fakeRPC{response: newFakeResponse()}
	c := NewClientWithRPC(rpc)
	if _, err := c.Verify(context.Background(), ""); err == nil {
		t.Errorf("expected error on empty cert_id")
	}
	if rpc.calls != 0 {
		t.Errorf("rpc.calls: got %d want 0 (no round-trip should fire on empty cert_id)", rpc.calls)
	}
}

func TestClient_Verify_RPCErrorPropagates(t *testing.T) {
	t.Parallel()
	rpc := &fakeRPC{err: errors.New("connection refused")}
	c := NewClientWithRPC(rpc)
	_, err := c.Verify(context.Background(), "cert-1")
	if err == nil {
		t.Fatalf("expected propagated error")
	}
}

func TestClient_Verify_PreservesByokExemptAndIsolationVerified(t *testing.T) {
	t.Parallel()
	rpc := &fakeRPC{response: &witnesspb.VerifyCertificateResponse{
		OverallVerdict:    "verified",
		Completeness:      "partial",
		SignaturesValid:   true,
		ByokExempt:        true,
		IsolationVerified: true,
		PerClaim: []*witnesspb.PerClaimVerdict{
			{ClaimType: "bridge", Verdict: "ok"},
		},
	}}
	c := NewClientWithRPC(rpc)
	out, err := c.Verify(context.Background(), "cert-byok")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if !out.ByokExempt {
		t.Errorf("ByokExempt must be true on BYOK runs")
	}
	if !out.IsolationVerified {
		t.Errorf("IsolationVerified must remain true on BYOK runs (per dual-sandbox-architecture PR #152)")
	}
	if out.OverallVerdict != "verified" {
		t.Errorf("BYOK cert overall_verdict should be 'verified' (NOT 'failed'), got %q", out.OverallVerdict)
	}
}

func TestClient_Verify_TimeoutPropagatesToContext(t *testing.T) {
	t.Parallel()
	rpc := &captureCtxRPC{}
	c := NewClientWithRPC(rpc, WithRPCTimeout(50*time.Millisecond))
	_, _ = c.Verify(context.Background(), "cert-1")
	if rpc.lastCtx == nil {
		t.Fatalf("captureCtxRPC never observed a ctx")
	}
	deadline, ok := rpc.lastCtx.Deadline()
	if !ok {
		t.Errorf("rpc ctx should carry a deadline")
	}
	// Allow a generous fuzz: the deadline must be roughly within RPC
	// timeout of "now" — we tolerate ±200ms scheduler noise.
	if d := time.Until(deadline); d > 500*time.Millisecond {
		t.Errorf("rpc deadline too far in future: %v", d)
	}
}

type captureCtxRPC struct {
	lastCtx context.Context
}

func (c *captureCtxRPC) VerifyCertificate(ctx context.Context, _ *witnesspb.VerifyCertificateRequest, _ ...grpc.CallOption) (*witnesspb.VerifyCertificateResponse, error) {
	c.lastCtx = ctx
	return &witnesspb.VerifyCertificateResponse{}, nil
}
