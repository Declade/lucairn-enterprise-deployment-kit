package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testAdminToken = "test-admin-token-1234567890abcdef"

func newTestServer(t *testing.T, handler http.HandlerFunc) (*httptest.Server, *AdminClient) {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	cli, err := NewAdminClient(srv.URL, testAdminToken, srv.Client())
	if err != nil {
		t.Fatalf("NewAdminClient: %v", err)
	}
	return srv, cli
}

func TestNewAdminClient_RejectsEmptyBaseURL(t *testing.T) {
	t.Parallel()
	_, err := NewAdminClient("", testAdminToken, nil)
	if err == nil {
		t.Fatal("expected error on empty baseURL")
	}
}

func TestNewAdminClient_RejectsBadScheme(t *testing.T) {
	t.Parallel()
	_, err := NewAdminClient("ftp://gateway", testAdminToken, nil)
	if err == nil {
		t.Fatal("expected error on non-http scheme")
	}
}

func TestNewAdminClient_RejectsEmptyToken(t *testing.T) {
	t.Parallel()
	_, err := NewAdminClient("http://gateway:8080", "", nil)
	if err == nil {
		t.Fatal("expected error on empty token")
	}
}

func TestNewAdminClient_RejectsPlaceholderTokens(t *testing.T) {
	t.Parallel()
	cases := []string{
		"CHANGE_ME_to_real_gateway_admin_token",
		"change_me",
		"REPLACE_ME_aaaaaaaaa",
		"REPLACE_WITH_DSA_ADMIN_KEY",
		"your-admin-token-here",
		"placeholder",
		"TODO_replace_me",
	}
	for _, tok := range cases {
		_, err := NewAdminClient("http://gateway:8080", tok, nil)
		if err == nil {
			t.Errorf("placeholder %q should be rejected", tok)
		}
	}
}

func TestNewAdminClient_AcceptsRealLooking(t *testing.T) {
	t.Parallel()
	_, err := NewAdminClient("http://gateway:8080", "5a82c1f0a7b3d4e5f6a7b8c9d0e1f2a3", nil)
	if err != nil {
		t.Errorf("real-looking token rejected: %v", err)
	}
}

func TestListCustomers_Success(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/admin/customers" {
			t.Errorf("path=%s", r.URL.Path)
		}
		if got := r.Header.Get("X-Admin-Key"); got != testAdminToken {
			t.Errorf("X-Admin-Key=%q want %q", got, testAdminToken)
		}
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Errorf("Accept=%q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode([]CustomerEntry{
			{APIKeyPrefix: "lcr_live_abcd1234", CustomerID: "cust_a", Tier: "enterprise"},
			{APIKeyPrefix: "***", CustomerID: "cust_b", Tier: "free"},
		})
	})
	got, err := cli.ListCustomers(context.Background())
	if err != nil {
		t.Fatalf("ListCustomers: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 customers, got %d", len(got))
	}
	if got[0].CustomerID != "cust_a" {
		t.Errorf("first customer = %+v", got[0])
	}
}

func TestListCustomers_Unauthorized(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"code":"admin_unauthorized","message":"Valid admin key is required."}`)
	})
	_, err := cli.ListCustomers(context.Background())
	if !errors.Is(err, ErrAdminTokenRejected) {
		t.Fatalf("want ErrAdminTokenRejected, got %v", err)
	}
}

func TestListCustomers_RateLimited_WithRetryAfter(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = io.WriteString(w, `{"code":"rate_limited","message":"too many","retry_after_seconds":17}`)
	})
	_, err := cli.ListCustomers(context.Background())
	var rl *ErrRateLimited
	if !errors.As(err, &rl) {
		t.Fatalf("want ErrRateLimited, got %v", err)
	}
	if rl.RetryAfter != 17*time.Second {
		t.Errorf("RetryAfter=%s want 17s", rl.RetryAfter)
	}
}

func TestListCustomers_RateLimited_HeaderFallback(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "42")
		w.WriteHeader(http.StatusTooManyRequests)
	})
	_, err := cli.ListCustomers(context.Background())
	var rl *ErrRateLimited
	if !errors.As(err, &rl) || rl.RetryAfter != 42*time.Second {
		t.Fatalf("want 42s RateLimited, got %v", err)
	}
}

func TestListKeys_Default(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		wantPath := "/api/v1/admin/customers/cust_a/keys"
		if r.URL.Path != wantPath {
			t.Errorf("path=%q want %q", r.URL.Path, wantPath)
		}
		if r.URL.Query().Get("reveal") != "" {
			t.Errorf("reveal query should be absent, got %q", r.URL.RawQuery)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{
			"customer_id":"cust_a",
			"tier":"enterprise",
			"byok_per_request":true,
			"provider":"anthropic",
			"has_provider_key":false,
			"max_keys":5,
			"keys":[
				{"key_id":"k_aaaa","key_prefix":"lcr_live_aaaa1111","created_at":"2026-05-20T08:00:00Z"},
				{"key_id":"k_bbbb","key_prefix":"lcr_live_bbbb2222","created_at":"2026-05-21T08:00:00Z"}
			]
		}`)
	})
	got, err := cli.ListKeys(context.Background(), "cust_a", false)
	if err != nil {
		t.Fatalf("ListKeys: %v", err)
	}
	if got.MaxKeys != 5 {
		t.Errorf("MaxKeys=%d", got.MaxKeys)
	}
	if len(got.Keys) != 2 {
		t.Fatalf("len(Keys)=%d", len(got.Keys))
	}
	if got.Keys[0].RawKey != "" {
		t.Errorf("default ListKeys leaked raw_key: %+v", got.Keys[0])
	}
}

func TestListKeys_Reveal_SetsQuery(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("reveal") != "true" {
			t.Errorf("reveal query missing: %s", r.URL.RawQuery)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"customer_id":"cust_a","tier":"pro","keys":[{"key_id":"k","key_prefix":"lcr_live_abcd","raw_key":"lcr_live_abcd1234567890abcdef1234567890abcd"}]}`)
	})
	got, err := cli.ListKeys(context.Background(), "cust_a", true)
	if err != nil {
		t.Fatalf("ListKeys reveal: %v", err)
	}
	if got.Keys[0].RawKey == "" {
		t.Errorf("reveal=true should populate RawKey")
	}
}

func TestListKeys_CustomerNotFound(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"code":"customer_not_found","message":"No API keys registered for this customer."}`)
	})
	_, err := cli.ListKeys(context.Background(), "cust_missing", false)
	if !errors.Is(err, ErrCustomerNotFound) {
		t.Fatalf("want ErrCustomerNotFound, got %v", err)
	}
}

func TestMintKey_Success(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("method=%s", r.Method)
		}
		if r.URL.Path != "/api/v1/admin/customers/cust_a/keys" {
			t.Errorf("path=%s", r.URL.Path)
		}
		if r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("Content-Type=%q", r.Header.Get("Content-Type"))
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"key_id":"k_new","key_prefix":"lcr_live_newprefix","raw_key":"lcr_live_newprefix1234567890abcdef1234567890","created_at":"2026-05-21T09:00:00Z"}`)
	})
	got, err := cli.MintKey(context.Background(), "cust_a")
	if err != nil {
		t.Fatalf("MintKey: %v", err)
	}
	if got.KeyID != "k_new" || got.KeyPrefix != "lcr_live_newprefix" {
		t.Errorf("MintKey response = %+v", got)
	}
	if !strings.HasPrefix(got.RawKey, "lcr_live_") {
		t.Errorf("RawKey shape wrong: %s", got.RawKey)
	}
}

func TestMintKey_MissingRawKey_Errors(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		// Simulate upstream contract regression — no raw_key.
		_, _ = io.WriteString(w, `{"key_id":"k","key_prefix":"lcr_live_xxx"}`)
	})
	_, err := cli.MintKey(context.Background(), "cust_a")
	if err == nil || !strings.Contains(err.Error(), "missing raw_key") {
		t.Errorf("want 'missing raw_key' error, got %v", err)
	}
}

func TestMintKey_MaxKeysReached(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_, _ = io.WriteString(w, `{"code":"max_keys_reached","message":"Customer already has 5 active keys; revoke one first.","max_keys":5}`)
	})
	_, err := cli.MintKey(context.Background(), "cust_a")
	if !errors.Is(err, ErrMaxKeysReached) {
		t.Fatalf("want ErrMaxKeysReached, got %v", err)
	}
}

func TestRevokeKey_Success(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete {
			t.Errorf("method=%s", r.Method)
		}
		wantPath := "/api/v1/admin/customers/cust_a/keys/k_target"
		if r.URL.Path != wantPath {
			t.Errorf("path=%q want %q", r.URL.Path, wantPath)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"revoked":true,"key_id":"k_target","key_prefix":"lcr_live_target12"}`)
	})
	got, err := cli.RevokeKey(context.Background(), "cust_a", "k_target")
	if err != nil {
		t.Fatalf("RevokeKey: %v", err)
	}
	if !got.Revoked {
		t.Errorf("want revoked=true")
	}
	if got.KeyID != "k_target" {
		t.Errorf("KeyID=%s", got.KeyID)
	}
}

func TestRevokeKey_NotFound(t *testing.T) {
	t.Parallel()
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"code":"key_not_found","message":"No matching key for this customer + key_id."}`)
	})
	_, err := cli.RevokeKey(context.Background(), "cust_a", "k_missing")
	if !errors.Is(err, ErrKeyNotFound) {
		t.Fatalf("want ErrKeyNotFound, got %v", err)
	}
}

func TestRevokeKey_RequiresKeyID(t *testing.T) {
	t.Parallel()
	cli, err := NewAdminClient("http://gateway:8080", testAdminToken, nil)
	if err != nil {
		t.Fatalf("NewAdminClient: %v", err)
	}
	_, err = cli.RevokeKey(context.Background(), "cust_a", "")
	if err == nil {
		t.Fatal("want error on empty key_id")
	}
}

func TestDo_RawKey_NeverInError(t *testing.T) {
	t.Parallel()
	// Simulate a gateway returning an error body that accidentally
	// contains a raw key. The wrapped error must redact it.
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, `internal: collision lcr_live_abcdef0123456789abcdef0123456789`)
	})
	_, err := cli.ListCustomers(context.Background())
	if err == nil {
		t.Fatal("want error")
	}
	if strings.Contains(err.Error(), "abcdef0123456789abcdef0123456789") {
		t.Errorf("raw key bytes leaked in error: %v", err)
	}
	if !strings.Contains(err.Error(), "lcr_live_***") {
		t.Errorf("redacted marker missing: %v", err)
	}
}

func TestDo_AdminTokenHeader_NeverInError(t *testing.T) {
	t.Parallel()
	// Simulate a gateway whose 5xx body echoes back the X-Admin-Key
	// header. The wrapped error must redact it.
	_, cli := newTestServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = io.WriteString(w, "Bad gateway, headers: X-Admin-Key: "+testAdminToken+"\n")
	})
	_, err := cli.ListCustomers(context.Background())
	if err == nil {
		t.Fatal("want error")
	}
	if strings.Contains(err.Error(), testAdminToken) {
		t.Errorf("admin token leaked in error: %v", err)
	}
}

func TestDo_RespectsCtxCancel(t *testing.T) {
	t.Parallel()
	// httptest.NewServer's handler runs in its own goroutine; the
	// handler waits on the request context which is server-side, NOT
	// the client-side context. Use a hang-then-write pattern with a
	// generous server-side timeout so the test ends cleanly even when
	// the server doesn't observe a transport close immediately.
	done := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-done:
		case <-time.After(2 * time.Second):
		}
		// Best-effort write — client may already be gone.
		_, _ = w.Write([]byte("{}"))
	}))
	defer func() {
		close(done)
		srv.Close()
	}()
	cli, err := NewAdminClient(srv.URL, testAdminToken, srv.Client())
	if err != nil {
		t.Fatalf("NewAdminClient: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, err = cli.ListCustomers(ctx)
	if err == nil {
		t.Fatal("want context-deadline error")
	}
	if !strings.Contains(err.Error(), "deadline") && !strings.Contains(err.Error(), "context") {
		t.Errorf("want context-deadline-related error, got %v", err)
	}
}

func TestRedactSensitive_HandlesEmpty(t *testing.T) {
	t.Parallel()
	if got := redactSensitive(""); got != "" {
		t.Errorf("redactSensitive('')=%q", got)
	}
}

func TestRedactSensitive_PreservesNonSensitive(t *testing.T) {
	t.Parallel()
	in := "dial tcp gateway:8080: connection refused"
	if got := redactSensitive(in); got != in {
		t.Errorf("redactSensitive mutated benign string: %q", got)
	}
}

func TestRedactSensitive_NoInfiniteLoopOnSelfMatch(t *testing.T) {
	t.Parallel()
	// Regression: the replacement string "lcr_live_***" itself contains
	// the lcr_live_ prefix. A naive `strings.Index(s, marker)` loop
	// re-finds the substitution and spins forever. The cursor-advance
	// guard MUST keep this O(n) and convergent.
	in := "x lcr_live_aaaa bbbb lcr_live_cccc done"
	got := redactSensitive(in)
	if strings.Count(got, "lcr_live_") != 2 {
		t.Errorf("expected exactly 2 lcr_live_ markers, got %q", got)
	}
	if strings.Contains(got, "aaaa") || strings.Contains(got, "cccc") {
		t.Errorf("raw hex bytes leaked: %q", got)
	}
}

func TestRedactSensitive_BothPatternsInOne(t *testing.T) {
	t.Parallel()
	in := "headers: X-Admin-Key: super-secret-456, body: token=lcr_live_abc12345"
	got := redactSensitive(in)
	if strings.Contains(got, "super-secret-456") {
		t.Errorf("admin token not scrubbed: %q", got)
	}
	if strings.Contains(got, "abc12345") {
		t.Errorf("lcr_live_ hex not scrubbed: %q", got)
	}
}
