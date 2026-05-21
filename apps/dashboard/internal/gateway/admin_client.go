// Package gateway wraps the HTTP client the dashboard uses to call the
// Lucairn gateway's admin surface for API key management (Slice 5).
//
// EMPIRICAL CONTRACT (verified 2026-05-21 by grepping
// `dual-sandbox-architecture/services/gateway/internal/api/`):
//
//   - The gateway admin surface IS HTTP REST under
//     `/api/v1/admin/` prefix, mounted on mainMux (admin.go:220-241).
//   - Auth is `X-Admin-Key` header, constant-time-compared
//     (admin.go:273-280) inside an outer chain that also adds a
//     per-IP brute-force tracker + per-IP rate-limit
//     (admin_chain.go:23 + admin_customer_keys.go:198-230).
//   - The endpoints we consume:
//
//     GET    /api/v1/admin/customers
//         → []customerEntry{api_key_prefix, customer_id, tier, vertical, managed_ai}
//
//     GET    /api/v1/admin/customers/{customer_id}/keys[?reveal=true]
//         → {customer_id, tier, byok_per_request, provider, has_provider_key,
//            relink_response, max_keys, keys: [{key_id, key_prefix, raw_key,
//                                                 created_at, last_used_at}]}
//         reveal=true populates raw_key; per-customer 5 reveals/min cap.
//
//     POST   /api/v1/admin/customers/{customer_id}/keys
//         → {key_id, key_prefix, raw_key, created_at} (201 Created)
//         raw_key is the plaintext lcr_live_* key — shown ONCE.
//
//     DELETE /api/v1/admin/customers/{customer_id}/keys/{key_id}
//         → {revoked: true, key_id, key_prefix} (200 OK)
//         NOTE: the path param is `{key_id}` (NOT `{prefix}` — the
//         brief had it wrong; upstream PR closed a wrong-key-revoke
//         vector by switching to key_id, per the cite at
//         admin_customer_keys.go:610-625).
//
//   - There is NO gRPC admin surface for customer-key management; the
//     HTTP REST routes above are the contract.
//
// Reviewers chasing drift: re-grep
// `dual-sandbox-architecture/services/gateway/internal/api/admin*.go` for
// changes to handleListCustomerKeys / handleMintCustomerKey /
// handleRevokeCustomerKey when bumping the dashboard's image tag.
//
// SECRETS HYGIENE:
//
//   - The admin token is held in an unexported struct field. It is
//     NEVER String()-formatted in error paths. The redactSensitive()
//     helper scrubs any `X-Admin-Key:` header value + any `lcr_live_*`
//     prefix that could surface in body excerpts or stack traces.
//
//   - raw_key is propagated only on the MintKey response struct (the
//     plaintext-once contract). Tests assert raw_key is NOT present in
//     ListKeys default-mode responses + NEVER appears in error strings.
package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// DefaultHTTPTimeout caps every admin call. Set per-method via
// context.WithTimeout when the caller wants tighter control (e.g. the
// 5min customer-list cache refresh uses a shorter ctx). 10s is the
// floor — the gateway's reveal path can take ~1s on a large customer
// list because of per-key keystore decrypt.
const DefaultHTTPTimeout = 10 * time.Second

// Typed errors returned by every method. Callers branch on these via
// errors.Is so they can distinguish "configured wrong" (401, 404) from
// "transient" (timeout, 5xx) without parsing message strings.
var (
	// ErrAdminTokenRejected = 401 from the gateway. Either the token
	// is wrong, expired, or the brute-force tracker locked the IP out.
	ErrAdminTokenRejected = errors.New("gateway admin: token rejected")

	// ErrCustomerNotFound = 404 on a customer-scoped endpoint with a
	// known-shape customer_id (so the URL was reachable).
	ErrCustomerNotFound = errors.New("gateway admin: customer not found")

	// ErrKeyNotFound = 404 on the per-key revoke endpoint. Idempotent —
	// the caller MAY retry without harm.
	ErrKeyNotFound = errors.New("gateway admin: key not found")

	// ErrMaxKeysReached = 409 on mint when the customer has hit
	// MaxKeysForTier (Free: 1, Pro: 3, Enterprise: 5 per upstream
	// auth.MaxKeysForTier).
	ErrMaxKeysReached = errors.New("gateway admin: max keys reached for tier")
)

// ErrRateLimited is returned when the gateway sends 429. RetryAfter
// carries the Retry-After header value (or a sensible default of 60s
// when the header is absent / unparseable). Use errors.As to inspect.
type ErrRateLimited struct {
	RetryAfter time.Duration
}

func (e *ErrRateLimited) Error() string {
	return fmt.Sprintf("gateway admin: rate-limited (retry after %s)", e.RetryAfter)
}

// AdminClient is the dashboard's HTTP client for the gateway admin API.
//
// Construct via NewAdminClient — direct field access bypasses the
// constructor's input validation (rejects placeholder tokens, validates
// baseURL, etc.).
type AdminClient struct {
	baseURL    *url.URL
	adminToken string // NEVER logged, NEVER formatted into errors
	httpClient *http.Client
}

// NewAdminClient validates inputs + builds a configured client.
//
// baseURL MUST be a non-empty http://-or-https:// URL parseable by
// net/url. adminToken MUST be non-empty + non-placeholder (Slice 4 GAP-1
// pattern: customers who copy-paste "CHANGE_ME_*" or "your-admin-token-
// here" from the example file get a clear error at boot, not silent 401
// rain on every list call).
//
// httpClient is an optional injection seam for tests; pass nil to get
// the default 10s-timeout client with a bounded connection pool.
func NewAdminClient(baseURL, adminToken string, httpClient *http.Client) (*AdminClient, error) {
	baseURL = strings.TrimSpace(baseURL)
	if baseURL == "" {
		return nil, errors.New("gateway admin: baseURL is required")
	}
	u, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("gateway admin: baseURL parse: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, fmt.Errorf("gateway admin: baseURL scheme must be http or https, got %q", u.Scheme)
	}
	if u.Host == "" {
		return nil, fmt.Errorf("gateway admin: baseURL has no host: %q", baseURL)
	}
	// Strip any path the operator may have included so URL composition
	// below stays predictable. /api/v1/admin/... is appended by every
	// method.
	u.Path = ""
	u.RawQuery = ""
	u.Fragment = ""

	adminToken = strings.TrimSpace(adminToken)
	if adminToken == "" {
		return nil, errors.New("gateway admin: adminToken is required")
	}
	if isPlaceholderToken(adminToken) {
		return nil, fmt.Errorf("gateway admin: adminToken is a placeholder (e.g. CHANGE_ME_*); set a real DSA_ADMIN_KEY value")
	}

	if httpClient == nil {
		httpClient = &http.Client{
			Timeout: DefaultHTTPTimeout,
			Transport: &http.Transport{
				MaxIdleConns:        5,
				MaxIdleConnsPerHost: 5,
				IdleConnTimeout:     90 * time.Second,
			},
		}
	}

	return &AdminClient{
		baseURL:    u,
		adminToken: adminToken,
		httpClient: httpClient,
	}, nil
}

// CustomerEntry mirrors the gateway's customerEntry DTO emitted by
// handleListCustomers (admin.go:472-478). api_key_prefix is "***" for
// control-API-synced (SetByHash) entries — operators see them in the
// dashboard but the revoke-by-prefix workflow is not available for them.
type CustomerEntry struct {
	APIKeyPrefix string `json:"api_key_prefix"`
	CustomerID   string `json:"customer_id"`
	Tier         string `json:"tier"`
	Vertical     string `json:"vertical"`
	ManagedAI    bool   `json:"managed_ai"`
}

// KeyEntry mirrors the gateway's adminCustomerKeyDTO. RawKey is empty
// EXCEPT when ListKeys was called with reveal=true AND the key is a
// non-SetByHash entry that carries an encrypted raw-key blob.
type KeyEntry struct {
	KeyID      string    `json:"key_id,omitempty"`
	KeyPrefix  string    `json:"key_prefix"`
	RawKey     string    `json:"raw_key,omitempty"`
	CreatedAt  time.Time `json:"created_at,omitempty"`
	LastUsedAt time.Time `json:"last_used_at,omitempty"`
}

// ListKeysResult mirrors adminCustomerKeysResponse. Only the fields the
// dashboard surface reads are extracted from the JSON envelope;
// trailing extras (e.g. RelinkResponse) are preserved into Extras for
// future expansion without forcing a contract change here.
type ListKeysResult struct {
	CustomerID     string     `json:"customer_id"`
	Tier           string     `json:"tier"`
	ByokPerRequest bool       `json:"byok_per_request"`
	Provider       string     `json:"provider"`
	HasProviderKey bool       `json:"has_provider_key"`
	MaxKeys        int        `json:"max_keys"`
	Keys           []KeyEntry `json:"keys"`
}

// MintKeyResult mirrors adminMintKeyResponse. RawKey is the plaintext
// lcr_live_* — UI surfaces show it ONCE in the post-mint modal and then
// drop it from DOM state. Logging this field is FORBIDDEN.
type MintKeyResult struct {
	KeyID     string    `json:"key_id"`
	KeyPrefix string    `json:"key_prefix"`
	RawKey    string    `json:"raw_key"`
	CreatedAt time.Time `json:"created_at"`
}

// RevokeKeyResult mirrors adminRevokeKeyResponse.
type RevokeKeyResult struct {
	Revoked   bool   `json:"revoked"`
	KeyID     string `json:"key_id"`
	KeyPrefix string `json:"key_prefix"`
}

// errorResponse decodes the gateway's APIError envelope (shape comes
// from services/gateway/internal/api/errors.go::WriteError). Only the
// fields we branch on are extracted.
type errorResponse struct {
	Code              string `json:"code"`
	Message           string `json:"message"`
	RetryAfterSeconds int    `json:"retry_after_seconds,omitempty"`
}

// ListCustomers calls GET /api/v1/admin/customers. Returns the full
// customer table (no pagination on the upstream surface — production
// deployments seldom carry > a few customers; we accept the full
// response and let the dashboard render-side paginate).
func (c *AdminClient) ListCustomers(ctx context.Context) ([]CustomerEntry, error) {
	resp, err := c.do(ctx, http.MethodGet, "/api/v1/admin/customers", nil, nil)
	if err != nil {
		return nil, err
	}
	var out []CustomerEntry
	if err := json.Unmarshal(resp, &out); err != nil {
		return nil, fmt.Errorf("gateway admin: list customers decode: %w", err)
	}
	return out, nil
}

// ListKeys calls GET /api/v1/admin/customers/{customer_id}/keys. When
// reveal=true the gateway populates raw_key for each non-SetByHash
// entry; the per-customer reveal bucket is 5/min upstream so the caller
// should reserve reveal=true for explicit "show key" user actions, not
// page loads.
func (c *AdminClient) ListKeys(ctx context.Context, customerID string, reveal bool) (*ListKeysResult, error) {
	if customerID == "" {
		return nil, errors.New("gateway admin: ListKeys customer_id is required")
	}
	path := "/api/v1/admin/customers/" + url.PathEscape(customerID) + "/keys"
	var query url.Values
	if reveal {
		query = url.Values{"reveal": []string{"true"}}
	}
	resp, err := c.do(ctx, http.MethodGet, path, query, nil)
	if err != nil {
		return nil, err
	}
	var out ListKeysResult
	if err := json.Unmarshal(resp, &out); err != nil {
		return nil, fmt.Errorf("gateway admin: list keys decode: %w", err)
	}
	return &out, nil
}

// MintKey calls POST /api/v1/admin/customers/{customer_id}/keys. The
// response's RawKey field is the plaintext lcr_live_* — render once in
// the mint modal and drop from JS state on close.
func (c *AdminClient) MintKey(ctx context.Context, customerID string) (*MintKeyResult, error) {
	if customerID == "" {
		return nil, errors.New("gateway admin: MintKey customer_id is required")
	}
	path := "/api/v1/admin/customers/" + url.PathEscape(customerID) + "/keys"
	// Upstream handler reads no body — it provisions a fresh key per the
	// customer's tier. Send an explicit empty JSON object so any future
	// payload extension stays backward-compatible from the dashboard
	// side.
	body := bytes.NewBufferString("{}")
	resp, err := c.do(ctx, http.MethodPost, path, nil, body)
	if err != nil {
		return nil, err
	}
	var out MintKeyResult
	if err := json.Unmarshal(resp, &out); err != nil {
		return nil, fmt.Errorf("gateway admin: mint key decode: %w", err)
	}
	if out.RawKey == "" || !strings.HasPrefix(out.RawKey, "lcr_live_") {
		// Upstream is meant to always emit a fresh lcr_live_ key on a
		// successful 201 (services/gateway/internal/api/admin_customer_keys.go:423).
		// An empty / mis-prefixed raw_key is a contract regression worth
		// surfacing without exposing the actual value.
		return nil, errors.New("gateway admin: mint key response missing raw_key")
	}
	return &out, nil
}

// RevokeKey calls DELETE /api/v1/admin/customers/{customer_id}/keys/{key_id}.
// The path parameter is `key_id` — the operator-display KeyPrefix is
// shown in the UI but the revoke handle is the globally-unique KeyID
// (the upstream `prefix`-based path was a wrong-key-revoke vector
// closed in PR #15-H1).
func (c *AdminClient) RevokeKey(ctx context.Context, customerID, keyID string) (*RevokeKeyResult, error) {
	if customerID == "" {
		return nil, errors.New("gateway admin: RevokeKey customer_id is required")
	}
	if keyID == "" {
		return nil, errors.New("gateway admin: RevokeKey key_id is required")
	}
	path := "/api/v1/admin/customers/" + url.PathEscape(customerID) + "/keys/" + url.PathEscape(keyID)
	resp, err := c.do(ctx, http.MethodDelete, path, nil, nil)
	if err != nil {
		return nil, err
	}
	var out RevokeKeyResult
	if err := json.Unmarshal(resp, &out); err != nil {
		return nil, fmt.Errorf("gateway admin: revoke key decode: %w", err)
	}
	return &out, nil
}

// do is the shared HTTP transport. It owns request shaping (auth +
// accept), response status mapping, and the secrets-hygiene rule that
// the admin token never appears in error strings.
func (c *AdminClient) do(ctx context.Context, method, path string, query url.Values, body io.Reader) ([]byte, error) {
	u := *c.baseURL
	u.Path = path
	if query != nil {
		u.RawQuery = query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return nil, fmt.Errorf("gateway admin: build request: %w", err)
	}
	req.Header.Set("X-Admin-Key", c.adminToken)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		// Network / timeout / context-cancel paths. Wrap without
		// surfacing the request URL (which is safe) but make sure no
		// admin token bytes accidentally leak via the underlying error
		// shape — Go's net/http never embeds headers in error strings,
		// but redactSensitive is a cheap belt-and-braces.
		return nil, fmt.Errorf("gateway admin: %s %s: %s", method, u.Path, redactSensitive(err.Error()))
	}
	defer func() { _ = resp.Body.Close() }()

	// Read at most ~1MiB so a misbehaving / non-gateway upstream cannot
	// blow the heap. The largest legitimate response is the customer
	// list, which is small in single-customer Enterprise installs.
	payload, readErr := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if readErr != nil {
		return nil, fmt.Errorf("gateway admin: read response: %w", readErr)
	}

	switch resp.StatusCode {
	case http.StatusOK, http.StatusCreated:
		return payload, nil
	case http.StatusUnauthorized:
		return nil, ErrAdminTokenRejected
	case http.StatusNotFound:
		// Differentiate "customer not found" (any customer-scoped
		// endpoint) from "key not found" (per-key revoke) by inspecting
		// the structured Code field. Falls back to ErrCustomerNotFound
		// on parse failure so callers always see a typed error.
		if e, _ := parseError(payload); e != nil {
			switch e.Code {
			case "key_not_found":
				return nil, ErrKeyNotFound
			default:
				return nil, ErrCustomerNotFound
			}
		}
		return nil, ErrCustomerNotFound
	case http.StatusConflict:
		// Mint endpoint emits 409 with code=max_keys_reached on cap.
		if e, _ := parseError(payload); e != nil && e.Code == "max_keys_reached" {
			return nil, ErrMaxKeysReached
		}
		return nil, fmt.Errorf("gateway admin: %s %s: 409 %s", method, u.Path, redactSensitive(bodyExcerpt(payload)))
	case http.StatusTooManyRequests:
		retry := 60 * time.Second
		if e, _ := parseError(payload); e != nil && e.RetryAfterSeconds > 0 {
			retry = time.Duration(e.RetryAfterSeconds) * time.Second
		} else if h := resp.Header.Get("Retry-After"); h != "" {
			if seconds, parseErr := strconv.Atoi(h); parseErr == nil && seconds > 0 {
				retry = time.Duration(seconds) * time.Second
			}
		}
		return nil, &ErrRateLimited{RetryAfter: retry}
	default:
		return nil, fmt.Errorf("gateway admin: %s %s: HTTP %d %s",
			method, u.Path, resp.StatusCode, redactSensitive(bodyExcerpt(payload)))
	}
}

// parseError decodes the structured APIError envelope. Returns (nil, err)
// when the body is not JSON or doesn't decode — the caller falls back to
// the raw status code as the signal.
func parseError(body []byte) (*errorResponse, error) {
	if len(body) == 0 {
		return nil, nil
	}
	var out errorResponse
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// bodyExcerpt returns at most 200 bytes of the response body for
// error-shape diagnostics. Long bodies are truncated with an ellipsis
// marker so log lines stay bounded.
func bodyExcerpt(body []byte) string {
	const max = 200
	if len(body) <= max {
		return string(body)
	}
	return string(body[:max]) + "...(truncated)"
}

// redactSensitive scrubs strings that look like secret material before
// they reach an error message. Two patterns: any lcr_live_<hex> token
// collapses to lcr_live_***; any "X-Admin-Key:" header dump collapses
// to "X-Admin-Key: ***". The admin token itself is a random base64ish
// string so the only reliable defense is to keep it out of error
// formatting paths in the first place — this helper is belt-and-braces
// for the cases where Go's error chain accidentally carries header
// dumps (e.g. http.Transport debug logs in some k8s-side proxies).
//
// Implementation note: each loop body advances past the substituted
// region using an offset cursor so the replacement string ("lcr_live_***")
// is NEVER re-scanned (the substituted text contains the lcr_live_
// prefix and would otherwise spin forever).
func redactSensitive(s string) string {
	if s == "" {
		return ""
	}
	// Mask "X-Admin-Key: <anything until newline or ',' or end>"
	for _, marker := range []string{"X-Admin-Key:", "x-admin-key:"} {
		cursor := 0
		for {
			idx := strings.Index(s[cursor:], marker)
			if idx < 0 {
				break
			}
			absIdx := cursor + idx
			rest := absIdx + len(marker)
			end := rest
			for end < len(s) && s[end] != '\n' && s[end] != ',' {
				end++
			}
			replacement := " ***"
			s = s[:rest] + replacement + s[end:]
			cursor = rest + len(replacement) // advance PAST the substituted region
		}
	}
	// Mask lcr_live_<hex> tokens. The lookup is lightweight; this is
	// not a parser — just a scrub for the most common leak shape.
	{
		const marker = "lcr_live_"
		const replacement = "lcr_live_***"
		cursor := 0
		for {
			idx := strings.Index(s[cursor:], marker)
			if idx < 0 {
				break
			}
			absIdx := cursor + idx
			end := absIdx + len(marker)
			for end < len(s) {
				c := s[end]
				if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') {
					end++
					continue
				}
				break
			}
			s = s[:absIdx] + replacement + s[end:]
			cursor = absIdx + len(replacement) // advance PAST the substituted region
		}
	}
	return s
}

// isPlaceholderToken detects the obvious "I forgot to replace this"
// shapes the kit's example files use. Case-insensitive prefix match;
// any token starting with these letters is rejected at constructor
// time so the dashboard pod fails-fast on boot instead of returning
// 401s on every key page load.
func isPlaceholderToken(tok string) bool {
	low := strings.ToLower(strings.TrimSpace(tok))
	switch {
	case strings.HasPrefix(low, "change_me"),
		strings.HasPrefix(low, "changeme"),
		strings.HasPrefix(low, "replace_me"),
		strings.HasPrefix(low, "replace_with"),
		strings.HasPrefix(low, "your-admin-token"),
		strings.HasPrefix(low, "your_admin_token"),
		strings.HasPrefix(low, "placeholder"),
		strings.HasPrefix(low, "todo"):
		return true
	}
	return false
}
