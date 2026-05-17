package server

import "net/http"

// SecurityHeaders middleware applies the locked baseline header set to every
// response. Slice 4 will relax X-Frame-Options and CSP frame-ancestors when
// Grafana embedding lands; Slice 1 stays DENY / 'none'.
//
// HSTS is gated on `r.TLS != nil`: sending Strict-Transport-Security over a
// plain-HTTP response (typical for the /healthz liveness probe on the
// internal cluster network) is at best wasted, at worst confusing — browsers
// ignore HSTS over HTTP per RFC 6797 § 7.2 but proxies and observability
// scanners flag it. Customers operating the dashboard behind a TLS-
// terminating reverse proxy still receive HSTS on the public-facing
// connections; this gate only affects backend probes.
func SecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		if r.TLS != nil {
			h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		}
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Content-Security-Policy",
			"default-src 'self'; "+
				"img-src 'self' data:; "+
				"style-src 'self' 'unsafe-inline'; "+
				"font-src 'self'; "+
				"frame-ancestors 'none'; "+
				"base-uri 'self'; "+
				"form-action 'self'")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		next.ServeHTTP(w, r)
	})
}
