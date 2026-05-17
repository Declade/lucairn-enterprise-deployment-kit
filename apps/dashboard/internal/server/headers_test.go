package server

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSecurityHeaders_TLS(t *testing.T) {
	final := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	h := SecurityHeaders(final)

	r := httptest.NewRequest(http.MethodGet, "/anything", nil)
	// Mark the request as TLS-bearing so the HSTS gate fires. Empty
	// ConnectionState satisfies r.TLS != nil — that is the predicate
	// SecurityHeaders inspects.
	r.TLS = &tls.ConnectionState{}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	cases := []struct {
		header  string
		want    string
		partial bool
	}{
		{"Strict-Transport-Security", "max-age=31536000; includeSubDomains", false},
		{"X-Content-Type-Options", "nosniff", false},
		{"X-Frame-Options", "DENY", false},
		{"Referrer-Policy", "strict-origin-when-cross-origin", false},
		{"Permissions-Policy", "camera=(), microphone=(), geolocation=()", false},
		{"Content-Security-Policy", "default-src 'self'", true},
		{"Content-Security-Policy", "frame-ancestors 'none'", true},
	}
	for _, c := range cases {
		got := w.Header().Get(c.header)
		if c.partial {
			if !strings.Contains(got, c.want) {
				t.Errorf("%s missing %q (got %q)", c.header, c.want, got)
			}
		} else {
			if got != c.want {
				t.Errorf("%s: want %q got %q", c.header, c.want, got)
			}
		}
	}
}

// TestSecurityHeaders_PlainHTTP_NoHSTS asserts the FX-4 hardening: HSTS is
// suppressed on non-TLS requests so plain-HTTP backend probes and reverse-
// proxy health checks do not carry a header browsers would ignore anyway.
// The other five baseline headers MUST remain on every response.
func TestSecurityHeaders_PlainHTTP_NoHSTS(t *testing.T) {
	final := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	h := SecurityHeaders(final)

	r := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	// r.TLS intentionally nil — mimics a plain-HTTP probe.
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	if got := w.Header().Get("Strict-Transport-Security"); got != "" {
		t.Errorf("HSTS must NOT be set on plain HTTP responses, got %q", got)
	}
	// The other baseline headers MUST still be present.
	for header, want := range map[string]string{
		"X-Content-Type-Options": "nosniff",
		"X-Frame-Options":        "DENY",
		"Referrer-Policy":        "strict-origin-when-cross-origin",
		"Permissions-Policy":     "camera=(), microphone=(), geolocation=()",
	} {
		if got := w.Header().Get(header); got != want {
			t.Errorf("%s: want %q got %q (must be set on plain-HTTP too)", header, want, got)
		}
	}
	if got := w.Header().Get("Content-Security-Policy"); !strings.Contains(got, "frame-ancestors 'none'") {
		t.Errorf("CSP must still be set on plain-HTTP; got %q", got)
	}
}
