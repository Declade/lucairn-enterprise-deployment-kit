package server

import (
	"net/http"
	"strings"
)

// SecurityHeaders middleware applies the locked baseline header set to every
// response.
//
// Slice 4 (this slice) relaxes X-Frame-Options + CSP `frame-ancestors` for
// the /health surfaces ONLY — those pages embed a Grafana iframe served
// from a different origin (the customer's in-cluster Grafana). The relax
// is scoped per-path; every OTHER route (login, dashboard home, cert
// pages, key management, audit log) keeps the strict DENY / 'none'
// stance from Slice 1.
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
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")

		// Per-route X-Frame-Options + CSP frame-ancestors override.
		// /health and /health/* host an iframe — relax to SAMEORIGIN /
		// 'self'. The path-scoped override is intentional: a future XSS
		// landing on an unrelated route can NOT be reframed by an
		// attacker; only the health overview is reframable, and only by
		// the same origin (so Grafana doesn't accidentally inherit
		// reframing rights at the dashboard level).
		if isHealthSurface(r.URL.Path) {
			h.Set("X-Frame-Options", "SAMEORIGIN")
			h.Set("Content-Security-Policy",
				"default-src 'self'; "+
					"img-src 'self' data:; "+
					"style-src 'self' 'unsafe-inline'; "+
					"font-src 'self'; "+
					"frame-src 'self' https:; "+
					"frame-ancestors 'self'; "+
					"script-src 'self' 'unsafe-inline'; "+
					"base-uri 'self'; "+
					"form-action 'self'; "+
					"connect-src 'self'")
		} else {
			h.Set("X-Frame-Options", "DENY")
			h.Set("Content-Security-Policy",
				"default-src 'self'; "+
					"img-src 'self' data:; "+
					"style-src 'self' 'unsafe-inline'; "+
					"font-src 'self'; "+
					"frame-ancestors 'none'; "+
					"base-uri 'self'; "+
					"form-action 'self'")
		}
		next.ServeHTTP(w, r)
	})
}

// isHealthSurface reports whether the request path is one of the routes
// that needs the relaxed X-Frame-Options + CSP. Pinned to /health
// exclusively — /healthz (k8s liveness JSON) stays under the strict
// baseline because its response is not framable by design.
func isHealthSurface(path string) bool {
	if path == "/health" {
		return true
	}
	return strings.HasPrefix(path, "/health/")
}
