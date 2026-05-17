package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSecurityHeaders(t *testing.T) {
	final := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	h := SecurityHeaders(final)

	r := httptest.NewRequest(http.MethodGet, "/anything", nil)
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
