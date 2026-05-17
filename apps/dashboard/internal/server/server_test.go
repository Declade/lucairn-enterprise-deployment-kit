package server

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"testing/fstest"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
)

// TestSlashVariantRoutesRedirect locks the contract that /healthz/ and /login/
// (trailing slash) are served by the mux via 308 redirects to their canonical
// no-slash paths. Without these handlers, the auth-middleware allowlist for
// the slash variants (FX-17) passes the request through the gate but the mux
// falls through to the catch-all 404 — silently breaking liveness probes that
// happen to be configured with the slash form.
func TestSlashVariantRoutesRedirect(t *testing.T) {
	store := auth.NewMemorySessionStore(time.Hour, time.Hour)
	defer store.Close()

	srv, err := New(Options{
		ListenAddr:    "127.0.0.1:0",
		Version:       "test",
		Authenticator: stubAuthenticator{},
		Sessions:      store,
		StaticFS:      fstest.MapFS{},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	h := srv.Handler()

	cases := []struct {
		path string
		want string
	}{
		{"/healthz/", "/healthz"},
		{"/login/", "/login"},
	}
	for _, tc := range cases {
		r := httptest.NewRequest(http.MethodGet, tc.path, nil)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != http.StatusPermanentRedirect {
			t.Errorf("path %s: expected 308, got %d", tc.path, w.Code)
		}
		if loc := w.Header().Get("Location"); loc != tc.want {
			t.Errorf("path %s: expected Location %q, got %q", tc.path, tc.want, loc)
		}
	}
}

// stubAuthenticator is a minimal Authenticator implementation that always
// rejects. server_test only exercises route registration so authn calls are
// never reached.
type stubAuthenticator struct{}

func (stubAuthenticator) Authenticate(_, _ string) (auth.User, error) {
	return auth.User{}, auth.ErrInvalidCredentials
}
