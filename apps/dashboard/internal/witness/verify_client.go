// Package witness wraps the gRPC client to the Lucairn Witness service.
//
// Slice 3 surface:
//   - VerifyCertificate(certID) — round-trips the upstream RPC
//   - 5min in-memory cache keyed by (certID, response.version_hash)
//   - explicit "Re-verify now" path bypasses cache; UI button uses this
//
// Connection model (v1): plaintext gRPC over the in-cluster service DNS
// (witness.lucairn.svc.cluster.local:50051 by default). Production-grade
// mTLS lands in a future slice; the upgrade path is gated on every
// customer being able to mint a fresh keypair on the kit's CA. Until
// then, in-cluster plaintext + Kubernetes NetworkPolicy isolation is the
// stance. The TODO at the end of NewClient is the authoritative reminder.
package witness

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// DefaultEndpoint is the in-cluster gRPC address the dashboard dials when
// LUCAIRN_DASHBOARD_WITNESS_ENDPOINT is unset. This matches the kit's
// default witness Service DNS — operators who run with a different
// namespace or Service name MUST override the env var.
const DefaultEndpoint = "witness.lucairn.svc.cluster.local:50051"

// DefaultCacheTTL is the per-cert verify-response cache window. Picked to
// match the PRD acceptance test ("5min in-memory cache"). The bulk
// re-verify path bypasses the cache; the per-cert "Re-verify now" button
// also bypasses by calling Invalidate before Verify.
const DefaultCacheTTL = 5 * time.Minute

// DefaultRPCTimeout caps each VerifyCertificate gRPC call. The witness is
// expected to respond in well under a second for a typical cert; we set a
// generous 8s ceiling so heavy chains (BYOK runs with TSA fetch retries)
// still resolve.
const DefaultRPCTimeout = 8 * time.Second

// VerifyResult is the dashboard-facing snapshot of a witness response.
// We copy out the fields we surface in the UI so the cache layer holds
// stable Go-native data, not a protobuf message with pointer-y semantics.
type VerifyResult struct {
	CertID            string
	OverallVerdict    string
	Completeness      string
	SignaturesValid   bool
	ByokExempt        bool
	IsolationVerified bool
	TSATimestamp      string
	RekorUUID         string
	PerClaim          []ClaimVerdict
	CertURL           string
	Error             string

	// CachedAt is when this snapshot was first computed. Zero when the
	// caller is reading a fresh round-trip (Verify with a cache-miss).
	CachedAt time.Time
}

// ClaimVerdict is the dashboard-facing per-claim row in the verify result.
// Mirrors witnesspb.PerClaimVerdict but copied so we never leak the
// proto types into views/* and so the cache is immutable.
type ClaimVerdict struct {
	ClaimType            string
	Verdict              string
	PubKeyFingerprint    string
	SignatureHex         string
	CanonicalPayloadHash string
	Error                string
}

// CertVerifier is the verify-side contract the rest of the dashboard
// consumes. Concrete impls: the gRPC-backed Client (production) plus a
// fake/in-memory implementation for unit tests.
type CertVerifier interface {
	Verify(ctx context.Context, certID string) (VerifyResult, error)
	Invalidate(certID string)
}

// Client is the gRPC-backed CertVerifier.
type Client struct {
	rpc      witnesspb.CertVerifierClient
	conn     *grpc.ClientConn
	cache    *cache
	timeout  time.Duration
	now      func() time.Time
}

// ClientOption tweaks Client construction. Keep additive — options stay
// optional so the call-site in main.go stays terse.
type ClientOption func(*Client)

// WithCacheTTL overrides the default 5min cache window. Tests use this
// to assert miss-after-TTL behavior without sleeping.
func WithCacheTTL(d time.Duration) ClientOption {
	return func(c *Client) {
		c.cache = newCache(d, c.now)
	}
}

// WithRPCTimeout overrides DefaultRPCTimeout. Tests use this to assert
// the deadline propagates into the gRPC context.
func WithRPCTimeout(d time.Duration) ClientOption {
	return func(c *Client) {
		c.timeout = d
	}
}

// WithClock injects a deterministic clock for cache-TTL tests.
func WithClock(now func() time.Time) ClientOption {
	return func(c *Client) {
		c.now = now
		c.cache = newCache(c.cache.ttl, now)
	}
}

// NewClient dials the witness endpoint and returns a ready Client. The
// gRPC dial uses a single best-effort connection — gRPC keepalives keep
// it warm. The endpoint string MUST be host:port; no scheme.
//
// TODO(slice-future): mTLS support. v1 ships plaintext gRPC over the
// in-cluster Service DNS; reachability is constrained at the
// NetworkPolicy layer (audit + bridge + sandbox-* mesh). Adding mTLS
// requires a coordinated keypair-mint flow + a customer-side CA bundle;
// that is gated on a separate kit slice with the matching INSTALL.md
// section.
func NewClient(endpoint string, opts ...ClientOption) (*Client, error) {
	if endpoint == "" {
		endpoint = DefaultEndpoint
	}
	// grpc.NewClient defers the actual TCP connect until first RPC; that
	// matches our reachability stance — the dashboard starts even when
	// the witness is temporarily offline, and surfaces the failure on
	// the first verify request rather than refusing to boot.
	conn, err := grpc.NewClient(endpoint, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, fmt.Errorf("witness: dial %s: %w", endpoint, err)
	}
	c := &Client{
		rpc:     witnesspb.NewCertVerifierClient(conn),
		conn:    conn,
		timeout: DefaultRPCTimeout,
		now:     time.Now,
	}
	c.cache = newCache(DefaultCacheTTL, c.now)
	for _, opt := range opts {
		opt(c)
	}
	return c, nil
}

// NewClientWithRPC injects a pre-built gRPC stub. Used by unit tests so
// the deterministic in-process fake never touches a real TCP socket.
// Production code calls NewClient.
func NewClientWithRPC(rpc witnesspb.CertVerifierClient, opts ...ClientOption) *Client {
	c := &Client{
		rpc:     rpc,
		timeout: DefaultRPCTimeout,
		now:     time.Now,
	}
	c.cache = newCache(DefaultCacheTTL, c.now)
	for _, opt := range opts {
		opt(c)
	}
	return c
}

// Close releases the underlying gRPC connection. Safe on a Client built
// via NewClientWithRPC (no-op when conn is nil).
func (c *Client) Close() error {
	if c.conn == nil {
		return nil
	}
	return c.conn.Close()
}

// Verify returns a VerifyResult for certID. Cache hits avoid the
// round-trip; cache misses dial the witness with a bounded deadline.
// On gRPC error we return the error; callers render a "Witness
// unreachable" degraded badge rather than crash.
func (c *Client) Verify(ctx context.Context, certID string) (VerifyResult, error) {
	if certID == "" {
		return VerifyResult{}, errors.New("witness: cert_id required")
	}
	if hit, ok := c.cache.get(certID); ok {
		return hit, nil
	}
	rpcCtx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	resp, err := c.rpc.VerifyCertificate(rpcCtx, &witnesspb.VerifyCertificateRequest{CertId: certID})
	if err != nil {
		return VerifyResult{}, fmt.Errorf("witness: VerifyCertificate(%s): %w", certID, err)
	}
	out := protoToResult(certID, resp, c.now())
	c.cache.put(certID, out)
	return out, nil
}

// Invalidate evicts certID from the cache. The "Re-verify now" button
// MUST call Invalidate before Verify so the next call dials the witness
// even within the 5min window.
func (c *Client) Invalidate(certID string) {
	c.cache.delete(certID)
}

func protoToResult(certID string, resp *witnesspb.VerifyCertificateResponse, now time.Time) VerifyResult {
	out := VerifyResult{
		CertID:            certID,
		OverallVerdict:    resp.GetOverallVerdict(),
		Completeness:      resp.GetCompleteness(),
		SignaturesValid:   resp.GetSignaturesValid(),
		ByokExempt:        resp.GetByokExempt(),
		IsolationVerified: resp.GetIsolationVerified(),
		TSATimestamp:      resp.GetTsaTimestamp(),
		RekorUUID:         resp.GetRekorUuid(),
		CertURL:           resp.GetCertUrl(),
		Error:             resp.GetError(),
		CachedAt:          now,
	}
	pc := resp.GetPerClaim()
	out.PerClaim = make([]ClaimVerdict, 0, len(pc))
	for _, c := range pc {
		out.PerClaim = append(out.PerClaim, ClaimVerdict{
			ClaimType:            c.GetClaimType(),
			Verdict:              c.GetVerdict(),
			PubKeyFingerprint:    c.GetPubKeyFingerprint(),
			SignatureHex:         c.GetSignatureHex(),
			CanonicalPayloadHash: c.GetCanonicalPayloadHash(),
			Error:                c.GetError(),
		})
	}
	return out
}

// cache is the in-memory verify-response store.
//
// Locking: sync.RWMutex; reads are vastly more common than writes once
// a tab is browsed. TTL is sliding-from-write — a cached entry expires
// DefaultCacheTTL after it was put, regardless of how often it is read.
// This matches the PRD acceptance test ("5min in-memory cache").
type cache struct {
	mu  sync.RWMutex
	m   map[string]cacheEntry
	ttl time.Duration
	now func() time.Time
}

type cacheEntry struct {
	val       VerifyResult
	expiresAt time.Time
}

func newCache(ttl time.Duration, now func() time.Time) *cache {
	return &cache{
		m:   make(map[string]cacheEntry),
		ttl: ttl,
		now: now,
	}
}

func (c *cache) get(key string) (VerifyResult, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	entry, ok := c.m[key]
	if !ok {
		return VerifyResult{}, false
	}
	if c.now().After(entry.expiresAt) {
		return VerifyResult{}, false
	}
	return entry.val, true
}

func (c *cache) put(key string, val VerifyResult) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m[key] = cacheEntry{
		val:       val,
		expiresAt: c.now().Add(c.ttl),
	}
}

func (c *cache) delete(key string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.m, key)
}
