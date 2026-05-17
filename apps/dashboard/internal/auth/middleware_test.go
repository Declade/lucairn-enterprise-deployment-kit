package auth

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRequireSession_DefaultDeny(t *testing.T) {
	store := NewMemorySessionStore(time.Hour, time.Hour)
	defer store.Close()

	final := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	chain := LoadSession(store)(RequireSession()(final))

	r := httptest.NewRequest("GET", "/dashboard", nil)
	w := httptest.NewRecorder()
	chain.ServeHTTP(w, r)

	if w.Code != http.StatusFound {
		t.Errorf("expected 302, got %d", w.Code)
	}
	loc := w.Header().Get("Location")
	if !strings.HasPrefix(loc, "/login") {
		t.Errorf("expected /login redirect, got %q", loc)
	}
	if !strings.Contains(loc, "next=") {
		t.Errorf("expected next= query param in %q", loc)
	}
}

func TestRequireSession_AllowsPublic(t *testing.T) {
	store := NewMemorySessionStore(time.Hour, time.Hour)
	defer store.Close()

	final := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	chain := LoadSession(store)(RequireSession()(final))

	// Trailing-slash variants of /login and /healthz MUST also pass through;
	// liveness probes typed with /healthz/ otherwise redirect to /login and
	// the readiness signal silently fails (FX-17 hardening).
	for _, path := range []string{"/login", "/login/", "/healthz", "/healthz/", "/static/css/x.css"} {
		r := httptest.NewRequest("GET", path, nil)
		w := httptest.NewRecorder()
		chain.ServeHTTP(w, r)
		if w.Code != http.StatusOK {
			t.Errorf("path %s expected 200, got %d", path, w.Code)
		}
	}
}

func TestRequireSession_PassesAuthenticated(t *testing.T) {
	store := NewMemorySessionStore(time.Hour, time.Hour)
	defer store.Close()
	sess, err := store.Create(User{Email: "a@b", Role: RoleAdmin})
	if err != nil {
		t.Fatal(err)
	}

	hit := false
	final := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
		if _, ok := CurrentUser(r); !ok {
			t.Errorf("expected user on context")
		}
		w.WriteHeader(http.StatusOK)
	})
	chain := LoadSession(store)(RequireSession()(final))

	r := httptest.NewRequest("GET", "/dashboard", nil)
	r.AddCookie(&http.Cookie{Name: SessionCookieName, Value: sess.ID})
	w := httptest.NewRecorder()
	chain.ServeHTTP(w, r)
	if !hit {
		t.Fatalf("expected handler to be invoked")
	}
	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
}

func TestRequireRole_NotFoundForWrongRole(t *testing.T) {
	store := NewMemorySessionStore(time.Hour, time.Hour)
	defer store.Close()
	sess, err := store.Create(User{Email: "v@b", Role: RoleViewer})
	if err != nil {
		t.Fatal(err)
	}

	final := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	chain := LoadSession(store)(RequireSession()(RequireRole(RoleAdmin, final)))

	r := httptest.NewRequest("GET", "/keys/list", nil)
	r.AddCookie(&http.Cookie{Name: SessionCookieName, Value: sess.ID})
	w := httptest.NewRecorder()
	chain.ServeHTTP(w, r)
	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404 for viewer hitting admin path, got %d", w.Code)
	}
}
