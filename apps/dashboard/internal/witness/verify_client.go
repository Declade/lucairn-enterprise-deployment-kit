// Package witness wraps the gRPC client to the Lucairn Witness's
// VeilCertificateService.
//
// Slice 3 surface:
//   - Verify(certID) does TWO upstream RPCs:
//       1. GetCertificate(certID)        → VeilCertificate envelope
//       2. VerifyCertificate(envelope)   → VerificationResult
//     This is the canonical 2-RPC shape the witness has always served
//     (per `dual-sandbox-architecture/proto/veil/v1/veil.proto`). The
//     previous (pre-fix-up) dashboard called a fictional
//     CertVerifier.VerifyCertificate(cert_id) RPC which empirically
//     returned codes.Unimplemented against a real witness.
//   - 30min in-memory cache (certs are immutable post-creation; the
//     previous 5min TTL was overly conservative for a write-once corpus).
//     The bulk re-verify path bypasses the cache via Invalidate; the
//     per-cert "Re-verify now" button also bypasses via Invalidate.
//   - singleflight on the cache-miss path: N concurrent inspector
//     requests for the same cert ID coalesce to one witness call pair
//     instead of stampeding the witness with N round-trips.
//
// Connection model (v1): plaintext gRPC over the in-cluster service DNS
// (witness.lucairn.svc.cluster.local:50051 by default). Production-grade
// mTLS lands in a future slice; the upgrade path is gated on every
// customer being able to mint a fresh keypair on the kit's CA. Until
// then, in-cluster plaintext + Kubernetes NetworkPolicy isolation is the
// stance. The TODO at the end of NewClient is the authoritative reminder.
package witness

//go:generate protoc --proto_path=. --go_out=pb --go_opt=paths=source_relative --go-grpc_out=pb --go-grpc_opt=paths=source_relative witness.proto

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
	"golang.org/x/sync/singleflight"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// DefaultEndpoint is the in-cluster gRPC address the dashboard dials when
// LUCAIRN_DASHBOARD_WITNESS_ENDPOINT is unset. This matches the kit's
// default witness Service DNS — operators who run with a different
// namespace or Service name MUST override the env var.
const DefaultEndpoint = "witness.lucairn.svc.cluster.local:50051"

// DefaultCacheTTL is the per-cert verify-response cache window. Bumped
// from the historic 5min default to 30min in fix-up r1: certs are
// immutable post-creation (the witness signs the canonical bytes at
// emit-time and never re-signs), so a fresh verify call within a 30min
// window will return the same envelope + the same result. The bulk
// re-verify path bypasses the cache via Invalidate; the per-cert
// "Re-verify now" button also bypasses by calling Invalidate before
// Verify.
const DefaultCacheTTL = 30 * time.Minute

// DefaultRPCTimeout caps each gRPC call (GetCertificate + VerifyCertificate
// share this timeout independently — a slow witness on either call falls
// back to the degraded-mode badge). The witness is expected to respond
// in well under a second for a typical cert; we set a generous 8s ceiling
// so heavy chains (BYOK runs with TSA fetch retries) still resolve.
const DefaultRPCTimeout = 8 * time.Second

// VerifyResult is the dashboard-facing snapshot of a verify round-trip.
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
// Mirrors the per-claim shape derived from the cert's `claims[]` and
// the verification result's `missing_services[]` set so we never leak
// proto types into views/* and the cache is immutable.
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

// VeilCertificateClient is the gRPC client interface the package uses
// against the witness. Aliased here so tests can supply an in-process
// fake without importing the pb package every time, and so the
// regression test that locks the fully-qualified method names dialed
// has a single seam to interpose on.
type VeilCertificateClient = witnesspb.VeilCertificateServiceClient

// Client is the gRPC-backed CertVerifier. It dials the witness's
// VeilCertificateService and sequences GetCertificate + VerifyCertificate
// for each Verify(certID) call.
type Client struct {
	rpc     VeilCertificateClient
	conn    *grpc.ClientConn
	cache   *cache
	timeout time.Duration
	now     func() time.Time
	sf      singleflight.Group
}

// ClientOption tweaks Client construction. Keep additive — options stay
// optional so the call-site in main.go stays terse.
type ClientOption func(*Client)

// WithCacheTTL overrides the default cache window. Tests use this
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
		rpc:     witnesspb.NewVeilCertificateServiceClient(conn),
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
func NewClientWithRPC(rpc VeilCertificateClient, opts ...ClientOption) *Client {
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
// round-trip; cache misses sequence GetCertificate + VerifyCertificate
// against the witness with a bounded deadline on each call.
//
// Concurrent calls for the same certID coalesce via singleflight: only
// one upstream pair fires; the rest of the callers receive the same
// result. This closes a real stampede vector when the cache cold-starts
// during a traffic spike (e.g. N bulk-progress tabs polling /certs/{id}
// inspector pages simultaneously).
//
// On gRPC error we return the error; callers render a "Witness
// unreachable" degraded badge rather than crash.
func (c *Client) Verify(ctx context.Context, certID string) (VerifyResult, error) {
	if certID == "" {
		return VerifyResult{}, errors.New("witness: cert_id required")
	}
	if hit, ok := c.cache.get(certID); ok {
		return hit, nil
	}
	v, err, _ := c.sf.Do(certID, func() (any, error) {
		// Re-check under singleflight so the second waiter (post-first-
		// fire) doesn't re-dial.
		if hit, ok := c.cache.get(certID); ok {
			return hit, nil
		}
		// 1. GetCertificate(certID) → VeilCertificate envelope.
		certCtx, certCancel := context.WithTimeout(ctx, c.timeout)
		defer certCancel()
		cert, err := c.rpc.GetCertificate(certCtx, &witnesspb.GetCertificateRequest{RequestId: certID})
		if err != nil {
			return VerifyResult{}, fmt.Errorf("witness: GetCertificate(%s): %w", certID, err)
		}
		// 2. VerifyCertificate(envelope) → VerificationResult.
		verCtx, verCancel := context.WithTimeout(ctx, c.timeout)
		defer verCancel()
		result, err := c.rpc.VerifyCertificate(verCtx, cert)
		if err != nil {
			return VerifyResult{}, fmt.Errorf("witness: VerifyCertificate(%s): %w", certID, err)
		}
		out := mapVerifyResult(certID, cert, result, c.now())
		c.cache.put(certID, out)
		return out, nil
	})
	if err != nil {
		return VerifyResult{}, err
	}
	return v.(VerifyResult), nil
}

// Invalidate evicts certID from the cache. The "Re-verify now" button
// MUST call Invalidate before Verify so the next call dials the witness
// even within the 30min window. Forget the singleflight key too so a
// stuck/long-running first call doesn't pin the cache entry indefinitely.
func (c *Client) Invalidate(certID string) {
	c.cache.delete(certID)
	c.sf.Forget(certID)
}

// mapVerifyResult assembles the dashboard-facing VerifyResult from the
// fetched cert envelope + the VerificationResult returned by
// VerifyCertificate.
//
// Per-claim verdict rule (v1):
//
//	verdict = "ok" iff result.SignaturesValid && !missingServices.Contains(claim_type)
//	verdict = "fail" otherwise
//
// `SignaturesValid` is the overall flag; `MissingServices[]` is the
// per-service drop list (its values are service IDs like "dsa-bridge").
// Deriving per-claim status from these two fields is correct for v1; a
// dedicated per-claim verdict slot in the upstream proto is a follow-up.
func mapVerifyResult(certID string, cert *witnesspb.VeilCertificate, result *witnesspb.VerificationResult, now time.Time) VerifyResult {
	out := VerifyResult{
		CertID:            certID,
		OverallVerdict:    verdictToLower(result.GetOverallVerdict()),
		Completeness:      completenessToLower(result.GetCompleteness()),
		SignaturesValid:   result.GetSignaturesValid(),
		ByokExempt:        result.GetByokExempt(),
		IsolationVerified: result.GetIsolationVerified(),
		CachedAt:          now,
	}
	// TSA + Rekor read from the cert envelope's external attestation.
	// Both fields are bytes/int on the wire; we render strings the UI
	// can copy + drop into a search tool. They are NOT URLs — the
	// inspector template renders TSA as opaque <code>...</code>.
	if att := cert.GetAttestation(); att != nil {
		if ts := att.GetTimestamp(); ts != nil {
			tok := ts.GetTimestampToken()
			if len(tok) > 0 {
				out.TSATimestamp = hex.EncodeToString(tok)
			}
		}
		if tl := att.GetTransparencyLog(); tl != nil {
			// Rekor entry UUID isn't a wire field by itself; the upstream
			// proto carries log_index (int64) + the verifier-side endpoint
			// renders the deep-link from that. For dashboard purposes we
			// use the inclusion_proof hash as the Rekor identifier
			// fallback — the witness CertServer always populates one or
			// the other on a successful anchor.
			if li := tl.GetLogIndex(); li != 0 {
				out.RekorUUID = fmt.Sprintf("%d", li)
			} else if ip := tl.GetInclusionProof(); len(ip) > 0 {
				out.RekorUUID = hex.EncodeToString(ip)
			}
		}
	}
	// Per-claim verdict derivation. Order surfaces in the upstream's
	// natural per-claim order (gateway/bridge/sanitizer/sandbox-*/witness
	// is determined by emit time on the witness side; we don't re-sort).
	missing := map[string]struct{}{}
	for _, ms := range result.GetMissingServices() {
		missing[strings.ToLower(strings.TrimSpace(ms))] = struct{}{}
	}
	for _, claim := range cert.GetClaims() {
		ct := claimTypeToLower(claim.GetClaimType())
		serviceID := strings.ToLower(strings.TrimSpace(claim.GetServiceId()))
		verdict := "ok"
		if !result.GetSignaturesValid() {
			verdict = "fail"
		} else if _, dropped := missing[ct]; dropped {
			verdict = "fail"
		} else if _, dropped := missing[serviceID]; dropped {
			verdict = "fail"
		}
		out.PerClaim = append(out.PerClaim, ClaimVerdict{
			ClaimType:            ct,
			Verdict:              verdict,
			PubKeyFingerprint:    "", // not in upstream cert envelope; reserved for a future witness-side promotion
			SignatureHex:         hex.EncodeToString(claim.GetSignature()),
			CanonicalPayloadHash: hex.EncodeToString(claim.GetCanonicalPayload()),
		})
	}
	return out
}

// verdictToLower maps the proto enum into the dashboard-facing lowercase
// string the templates already match on (eq "verified", eq "partial",
// eq "failed"). The enum's String() form is "VERDICT_VERIFIED" so we
// strip the prefix + lowercase. BYOK_EXEMPT runs surface as "verified"
// per CLAUDE.md § BYOK_EXEMPT — the byok_exempt field on the result
// carries the exemption flag separately for badge rendering.
func verdictToLower(v witnesspb.Verdict) string {
	switch v {
	case witnesspb.Verdict_VERDICT_VERIFIED:
		return "verified"
	case witnesspb.Verdict_VERDICT_PARTIAL:
		return "partial"
	case witnesspb.Verdict_VERDICT_FAILED:
		return "failed"
	default:
		return ""
	}
}

// completenessToLower maps the proto enum to the dashboard-facing string
// the inspector template's <span>{{ .Result.Completeness }}</span>
// renders.
func completenessToLower(c witnesspb.Completeness) string {
	switch c {
	case witnesspb.Completeness_COMPLETENESS_FULL:
		return "full"
	case witnesspb.Completeness_COMPLETENESS_PARTIAL:
		return "partial"
	default:
		return ""
	}
}

// claimTypeToLower maps the proto claim-type enum to the lowercase
// shorthand the per-claim chain template renders. The enum's String()
// form is "CLAIM_TYPE_TOKEN_GENERATED" → we map to "bridge" /
// "sanitizer" / etc to match the existing 6-row chain template.
func claimTypeToLower(t witnesspb.ClaimType) string {
	switch t {
	case witnesspb.ClaimType_CLAIM_TYPE_TOKEN_GENERATED:
		return "bridge"
	case witnesspb.ClaimType_CLAIM_TYPE_PII_SANITIZED:
		return "sanitizer"
	case witnesspb.ClaimType_CLAIM_TYPE_INFERENCE_COMPLETED:
		return "inference"
	case witnesspb.ClaimType_CLAIM_TYPE_EVENTS_RECORDED:
		return "audit"
	default:
		return strings.ToLower(strings.TrimPrefix(t.String(), "CLAIM_TYPE_"))
	}
}

// cache is the in-memory verify-response store.
//
// Locking: sync.RWMutex; reads are vastly more common than writes once
// a tab is browsed. TTL is sliding-from-write — a cached entry expires
// DefaultCacheTTL after it was put, regardless of how often it is read.
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
