package witness

import (
	"context"
	"errors"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
)

// fakeRPC is an in-memory implementation of the upstream
// VeilCertificateServiceClient. It tracks how many times each RPC is
// invoked so cache + singleflight behavior can be asserted.
type fakeRPC struct {
	mu sync.Mutex

	getCalls    int
	verifyCalls int

	// lastRequestID captures the request_id value the most recent
	// GetCertificate call carried on the wire. Used by
	// TestVerify_UsesRequestIDNotCertID to lock the rule that the
	// dashboard's RPC carries the witness's request_id (NOT the
	// operator-facing certificate_id).
	lastRequestID string

	getResp    *witnesspb.VeilCertificate
	verifyResp *witnesspb.VerificationResult

	getErr    error
	verifyErr error

	// optional delay each RPC sleeps for before returning; used to widen
	// the singleflight race window in concurrency tests.
	delay time.Duration
}

func (f *fakeRPC) GetCertificate(_ context.Context, in *witnesspb.GetCertificateRequest, _ ...grpc.CallOption) (*witnesspb.VeilCertificate, error) {
	f.mu.Lock()
	f.getCalls++
	f.lastRequestID = in.GetRequestId()
	f.mu.Unlock()
	if f.delay > 0 {
		time.Sleep(f.delay)
	}
	if f.getErr != nil {
		return nil, f.getErr
	}
	if f.getResp == nil {
		return &witnesspb.VeilCertificate{CertificateId: in.GetRequestId()}, nil
	}
	return f.getResp, nil
}

func (f *fakeRPC) ExportCertificates(_ context.Context, _ *witnesspb.ExportRequest, _ ...grpc.CallOption) (grpc.ServerStreamingClient[witnesspb.VeilCertificate], error) {
	return nil, errors.New("export not used in dashboard")
}

func (f *fakeRPC) VerifyCertificate(_ context.Context, _ *witnesspb.VeilCertificate, _ ...grpc.CallOption) (*witnesspb.VerificationResult, error) {
	f.mu.Lock()
	f.verifyCalls++
	f.mu.Unlock()
	if f.delay > 0 {
		time.Sleep(f.delay)
	}
	if f.verifyErr != nil {
		return nil, f.verifyErr
	}
	if f.verifyResp == nil {
		return &witnesspb.VerificationResult{}, nil
	}
	return f.verifyResp, nil
}

func newFakeCert() *witnesspb.VeilCertificate {
	return &witnesspb.VeilCertificate{
		CertificateId: "cert-1",
		Claims: []*witnesspb.VeilClaim{
			{ClaimType: witnesspb.ClaimType_CLAIM_TYPE_TOKEN_GENERATED, ServiceId: "dsa-bridge", Signature: []byte{0xaa, 0xbb}, CanonicalPayload: []byte{0xcc}},
			{ClaimType: witnesspb.ClaimType_CLAIM_TYPE_PII_SANITIZED, ServiceId: "dsa-sanitizer", Signature: []byte{0xdd, 0xee}, CanonicalPayload: []byte{0xff}},
			{ClaimType: witnesspb.ClaimType_CLAIM_TYPE_INFERENCE_COMPLETED, ServiceId: "dsa-ai", Signature: []byte{0x11, 0x22}, CanonicalPayload: []byte{0x33}},
			{ClaimType: witnesspb.ClaimType_CLAIM_TYPE_EVENTS_RECORDED, ServiceId: "dsa-audit", Signature: []byte{0x44, 0x55}, CanonicalPayload: []byte{0x66}},
		},
		Attestation: &witnesspb.ExternalAttestation{
			Timestamp:       &witnesspb.TimestampAttestation{TimestampToken: []byte{0xaa, 0xbb, 0xcc, 0xdd}},
			TransparencyLog: &witnesspb.TransparencyLogEntry{LogIndex: 99},
		},
	}
}

func newFakeResult() *witnesspb.VerificationResult {
	return &witnesspb.VerificationResult{
		OverallVerdict:    witnesspb.Verdict_VERDICT_VERIFIED,
		Completeness:      witnesspb.Completeness_COMPLETENESS_FULL,
		SignaturesValid:   true,
		ByokExempt:        false,
		IsolationVerified: true,
	}
}

func TestClient_Verify_CacheMissThenHit(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 5, 18, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	rpc := &fakeRPC{getResp: newFakeCert(), verifyResp: newFakeResult()}
	c := NewClientWithRPC(rpc, WithClock(clock), WithCacheTTL(5*time.Minute))

	first, err := c.Verify(context.Background(), "cert-1")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if first.OverallVerdict != "verified" {
		t.Errorf("verdict: got %q want %q", first.OverallVerdict, "verified")
	}
	if len(first.PerClaim) != 4 {
		t.Fatalf("per-claim: got %d want 4 (matches newFakeCert claims)", len(first.PerClaim))
	}
	if rpc.getCalls != 1 || rpc.verifyCalls != 1 {
		t.Errorf("rpc calls after miss: got get=%d verify=%d want 1+1", rpc.getCalls, rpc.verifyCalls)
	}

	// Second call within TTL: cache hit, calls stay at 1+1.
	second, err := c.Verify(context.Background(), "cert-1")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if rpc.getCalls != 1 || rpc.verifyCalls != 1 {
		t.Errorf("rpc calls after hit: got get=%d verify=%d want 1+1 (cache should serve)", rpc.getCalls, rpc.verifyCalls)
	}
	if second.OverallVerdict != first.OverallVerdict {
		t.Errorf("cache returned different value than first")
	}
}

func TestClient_Verify_CacheExpires(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 5, 18, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	rpc := &fakeRPC{getResp: newFakeCert(), verifyResp: newFakeResult()}
	c := NewClientWithRPC(rpc, WithClock(clock), WithCacheTTL(5*time.Minute))

	if _, err := c.Verify(context.Background(), "cert-1"); err != nil {
		t.Fatalf("verify 1: %v", err)
	}
	// Advance the clock past the TTL window.
	now = now.Add(6 * time.Minute)
	if _, err := c.Verify(context.Background(), "cert-1"); err != nil {
		t.Fatalf("verify 2: %v", err)
	}
	if rpc.getCalls != 2 || rpc.verifyCalls != 2 {
		t.Errorf("rpc calls after TTL expiry: got get=%d verify=%d want 2+2", rpc.getCalls, rpc.verifyCalls)
	}
}

func TestClient_Invalidate_BypassesCache(t *testing.T) {
	t.Parallel()
	rpc := &fakeRPC{getResp: newFakeCert(), verifyResp: newFakeResult()}
	c := NewClientWithRPC(rpc)
	if _, err := c.Verify(context.Background(), "cert-1"); err != nil {
		t.Fatalf("verify 1: %v", err)
	}
	c.Invalidate("cert-1")
	if _, err := c.Verify(context.Background(), "cert-1"); err != nil {
		t.Fatalf("verify 2: %v", err)
	}
	if rpc.getCalls != 2 || rpc.verifyCalls != 2 {
		t.Errorf("rpc calls after Invalidate: got get=%d verify=%d want 2+2", rpc.getCalls, rpc.verifyCalls)
	}
}

func TestClient_Verify_EmptyRequestIDRejected(t *testing.T) {
	t.Parallel()
	rpc := &fakeRPC{getResp: newFakeCert(), verifyResp: newFakeResult()}
	c := NewClientWithRPC(rpc)
	if _, err := c.Verify(context.Background(), ""); err == nil {
		t.Errorf("expected error on empty request_id")
	}
	if rpc.getCalls != 0 || rpc.verifyCalls != 0 {
		t.Errorf("rpc.calls: got get=%d verify=%d want 0+0 (no round-trip should fire on empty request_id)", rpc.getCalls, rpc.verifyCalls)
	}
}

func TestClient_Verify_GetCertificateErrorPropagates(t *testing.T) {
	t.Parallel()
	rpc := &fakeRPC{getErr: errors.New("connection refused")}
	c := NewClientWithRPC(rpc)
	_, err := c.Verify(context.Background(), "cert-1")
	if err == nil {
		t.Fatalf("expected propagated error")
	}
	if !strings.Contains(err.Error(), "GetCertificate") {
		t.Errorf("err must name GetCertificate path: %v", err)
	}
	if rpc.verifyCalls != 0 {
		t.Errorf("verifyCalls must be 0 when GetCertificate fails first: got %d", rpc.verifyCalls)
	}
}

func TestClient_Verify_VerifyCertificateErrorPropagates(t *testing.T) {
	t.Parallel()
	rpc := &fakeRPC{getResp: newFakeCert(), verifyErr: errors.New("witness rejected envelope")}
	c := NewClientWithRPC(rpc)
	_, err := c.Verify(context.Background(), "cert-1")
	if err == nil {
		t.Fatalf("expected propagated error")
	}
	if !strings.Contains(err.Error(), "VerifyCertificate") {
		t.Errorf("err must name VerifyCertificate path: %v", err)
	}
}

// TestVerify_UsesRequestIDNotCertID is the load-bearing regression that
// locks the rule: the witness's GetCertificate RPC carries the WITNESS
// request_id, NOT the operator-facing certificate_id.
//
// Why this matters: upstream's CertServer.GetCertificate at
// dual-sandbox-architecture/services/veil-witness/internal/server/
// cert_server.go:44-53 looks up by request_id; the DB index is on
// request_id (store.go:88-93). The assembler at assembler.go:89-92 mints
// certificate_id and request_id as DIFFERENT values per row. If the
// dashboard's Verify call ever falls back to passing the cert_id, every
// production lookup returns codes.NotFound and the inspector + validator
// pages quietly degrade to the "Witness unreachable" badge.
func TestVerify_UsesRequestIDNotCertID(t *testing.T) {
	t.Parallel()
	rpc := &fakeRPC{getResp: newFakeCert(), verifyResp: newFakeResult()}
	c := NewClientWithRPC(rpc)

	const requestID = "req_aaaa-1111-bbbb-2222-cccccccccccc"
	// IMPORTANT: this value would be "veil_<uuid>" in production; the
	// caller MUST resolve it from CertSummary.RequestID before invoking
	// Verify. We pass the request_id directly here to assert the wire
	// payload carries the same string verbatim.
	if _, err := c.Verify(context.Background(), requestID); err != nil {
		t.Fatalf("verify: %v", err)
	}
	rpc.mu.Lock()
	got := rpc.lastRequestID
	rpc.mu.Unlock()
	if got != requestID {
		t.Fatalf("GetCertificate.request_id: got %q want %q (witness RPC must carry request_id, NOT certificate_id)", got, requestID)
	}
	// Defensive: ensure the captured value is NOT "veil_…" shape, which
	// would mean a caller leaked the operator-facing cert_id into the
	// RPC. The fixture above uses "req_…" so a substring check is enough.
	if strings.HasPrefix(got, "veil_") {
		t.Errorf("RPC request_id must not be a 'veil_<uuid>' certificate_id; got %q", got)
	}
}

func TestClient_Verify_PreservesByokExemptAndIsolationVerified(t *testing.T) {
	t.Parallel()
	rpc := &fakeRPC{
		getResp: newFakeCert(),
		verifyResp: &witnesspb.VerificationResult{
			OverallVerdict:    witnesspb.Verdict_VERDICT_VERIFIED,
			Completeness:      witnesspb.Completeness_COMPLETENESS_PARTIAL,
			SignaturesValid:   true,
			ByokExempt:        true,
			IsolationVerified: true,
		},
	}
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
	if d := time.Until(deadline); d > 500*time.Millisecond {
		t.Errorf("rpc deadline too far in future: %v", d)
	}
}

func TestClient_Verify_SingleflightCoalescesConcurrentMisses(t *testing.T) {
	t.Parallel()
	// Use a small delay so the goroutines all enqueue before the first
	// flight completes. Without singleflight, getCalls would be 8.
	rpc := &fakeRPC{getResp: newFakeCert(), verifyResp: newFakeResult(), delay: 30 * time.Millisecond}
	c := NewClientWithRPC(rpc)

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = c.Verify(context.Background(), "cert-stampede")
		}()
	}
	wg.Wait()
	if rpc.getCalls != 1 {
		t.Errorf("singleflight: getCalls got %d want 1 (concurrent misses for same key must coalesce)", rpc.getCalls)
	}
	if rpc.verifyCalls != 1 {
		t.Errorf("singleflight: verifyCalls got %d want 1", rpc.verifyCalls)
	}
}

// methodCaptureInterceptor records the fully-qualified gRPC method name
// for every unary call routed through it.
type methodCaptureInterceptor struct {
	methods []string
	mu      sync.Mutex
}

func (m *methodCaptureInterceptor) Intercept(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
	m.mu.Lock()
	m.methods = append(m.methods, method)
	m.mu.Unlock()
	return invoker(ctx, method, req, reply, cc, opts...)
}

// upstreamShapeServer implements the upstream VeilCertificateServiceServer
// so the bufconn-backed Client can complete a real round-trip. We don't
// care about the response content here — only that the right method
// names get dialed.
type upstreamShapeServer struct {
	witnesspb.UnimplementedVeilCertificateServiceServer
}

func (s *upstreamShapeServer) GetCertificate(_ context.Context, _ *witnesspb.GetCertificateRequest) (*witnesspb.VeilCertificate, error) {
	return newFakeCert(), nil
}

func (s *upstreamShapeServer) VerifyCertificate(_ context.Context, _ *witnesspb.VeilCertificate) (*witnesspb.VerificationResult, error) {
	return newFakeResult(), nil
}

// TestVerify_RealUpstreamServiceShape locks the contract that the
// dashboard dials the upstream `dsa.veil.v1.VeilCertificateService`
// service with its TWO real RPCs (GetCertificate + VerifyCertificate),
// NOT the previous (invented) `lucairn.witness.v1.CertVerifier` shape.
//
// This is the regression test the contract-drift-detector PR review
// would have caught earlier. If a future hand-edit reverts the proto to
// a renamed service, or someone re-collapses to a single RPC, this test
// fails loudly at unit-test time.
func TestVerify_RealUpstreamServiceShape(t *testing.T) {
	t.Parallel()
	const bufSize = 1 << 20
	lis := bufconn.Listen(bufSize)
	srv := grpc.NewServer()
	witnesspb.RegisterVeilCertificateServiceServer(srv, &upstreamShapeServer{})
	go func() {
		if err := srv.Serve(lis); err != nil {
			t.Logf("bufconn serve: %v", err)
		}
	}()
	t.Cleanup(srv.Stop)

	interceptor := &methodCaptureInterceptor{}
	dialer := func(_ context.Context, _ string) (net.Conn, error) {
		return lis.Dial()
	}
	conn, err := grpc.NewClient(
		"passthrough://bufnet",
		grpc.WithContextDialer(dialer),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithUnaryInterceptor(interceptor.Intercept),
	)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	rpc := witnesspb.NewVeilCertificateServiceClient(conn)
	c := NewClientWithRPC(rpc)
	if _, err := c.Verify(context.Background(), "cert-shape"); err != nil {
		t.Fatalf("verify: %v", err)
	}

	interceptor.mu.Lock()
	defer interceptor.mu.Unlock()
	if len(interceptor.methods) != 2 {
		t.Fatalf("expected 2 unary calls (GetCertificate + VerifyCertificate); got %v", interceptor.methods)
	}
	want := []string{
		"/dsa.veil.v1.VeilCertificateService/GetCertificate",
		"/dsa.veil.v1.VeilCertificateService/VerifyCertificate",
	}
	for i, w := range want {
		if interceptor.methods[i] != w {
			t.Errorf("call %d: got %q want %q", i, interceptor.methods[i], w)
		}
	}
}

// TestVerify_NoLegacyCertVerifierShape is a belt-and-braces guard: even
// if the regenerated stubs accidentally register a deprecated service
// name alongside the new one, this test fails. Forbidden substrings
// cover the previous invented `lucairn.witness.v1.CertVerifier` shape.
func TestVerify_NoLegacyCertVerifierShape(t *testing.T) {
	t.Parallel()
	const bufSize = 1 << 20
	lis := bufconn.Listen(bufSize)
	srv := grpc.NewServer()
	witnesspb.RegisterVeilCertificateServiceServer(srv, &upstreamShapeServer{})
	go func() {
		_ = srv.Serve(lis)
	}()
	t.Cleanup(srv.Stop)
	interceptor := &methodCaptureInterceptor{}
	dialer := func(_ context.Context, _ string) (net.Conn, error) {
		return lis.Dial()
	}
	conn, err := grpc.NewClient(
		"passthrough://bufnet",
		grpc.WithContextDialer(dialer),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithUnaryInterceptor(interceptor.Intercept),
	)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	c := NewClientWithRPC(witnesspb.NewVeilCertificateServiceClient(conn))
	if _, err := c.Verify(context.Background(), "cert-shape"); err != nil {
		t.Fatalf("verify: %v", err)
	}
	interceptor.mu.Lock()
	defer interceptor.mu.Unlock()
	for _, m := range interceptor.methods {
		for _, banned := range []string{"CertVerifier", "lucairn.witness.v1"} {
			if strings.Contains(m, banned) {
				t.Errorf("dialed method %q must not contain legacy fragment %q", m, banned)
			}
		}
	}
}

type captureCtxRPC struct {
	lastCtxMu sync.Mutex
	lastCtx   context.Context

	atomicCalls atomic.Int32
}

func (c *captureCtxRPC) GetCertificate(ctx context.Context, _ *witnesspb.GetCertificateRequest, _ ...grpc.CallOption) (*witnesspb.VeilCertificate, error) {
	c.lastCtxMu.Lock()
	c.lastCtx = ctx
	c.lastCtxMu.Unlock()
	c.atomicCalls.Add(1)
	return newFakeCert(), nil
}

func (c *captureCtxRPC) ExportCertificates(_ context.Context, _ *witnesspb.ExportRequest, _ ...grpc.CallOption) (grpc.ServerStreamingClient[witnesspb.VeilCertificate], error) {
	return nil, errors.New("export not used")
}

func (c *captureCtxRPC) VerifyCertificate(ctx context.Context, _ *witnesspb.VeilCertificate, _ ...grpc.CallOption) (*witnesspb.VerificationResult, error) {
	c.lastCtxMu.Lock()
	c.lastCtx = ctx
	c.lastCtxMu.Unlock()
	c.atomicCalls.Add(1)
	return newFakeResult(), nil
}
