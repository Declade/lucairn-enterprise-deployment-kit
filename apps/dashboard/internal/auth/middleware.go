package auth

import (
	"net/http"
	"net/url"
	"strings"
)

// PublicPaths is the closed allowlist of paths that do NOT require an
// authenticated session. Everything else is default-deny. New unauthenticated
// surfaces must be added here explicitly — there is no wildcard escape hatch.
var publicPaths = map[string]struct{}{
	"/login":   {},
	"/healthz": {},
}

// publicPrefixes covers static asset trees.
var publicPrefixes = []string{
	"/static/",
}

// LoadSession is a non-blocking middleware that resolves the session cookie
// and stores the matching session on the request context. It does NOT reject
// missing/invalid sessions — RequireSession does.
func LoadSession(store SessionStore) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			c, err := r.Cookie(SessionCookieName)
			if err == nil && c.Value != "" {
				if sess, ok := store.Get(c.Value); ok {
					store.Touch(c.Value)
					r = withSession(r, sess)
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

// RequireSession enforces the default-deny rule. Unauthenticated requests
// against non-public paths get 302'd to /login with the next= query set.
func RequireSession() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if isPublicPath(r.URL.Path) {
				next.ServeHTTP(w, r)
				return
			}
			if _, ok := CurrentSession(r); ok {
				next.ServeHTTP(w, r)
				return
			}
			redirectToLogin(w, r)
		})
	}
}

// RequireRole gates a handler on the user's role. Authenticated users without
// the required role get a 404 (not 403) so the resource appears not to exist.
// PRD § Slice 1: "viewer cannot access /keys/* (404 — not 403)".
func RequireRole(role Role, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, ok := CurrentUser(r)
		if !ok {
			redirectToLogin(w, r)
			return
		}
		if u.Role != role {
			http.NotFound(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func isPublicPath(path string) bool {
	if _, ok := publicPaths[path]; ok {
		return true
	}
	for _, prefix := range publicPrefixes {
		if strings.HasPrefix(path, prefix) {
			return true
		}
	}
	return false
}

func redirectToLogin(w http.ResponseWriter, r *http.Request) {
	target := "/login"
	if r.URL.Path != "" && r.URL.Path != "/login" {
		q := url.Values{}
		q.Set("next", r.URL.RequestURI())
		target += "?" + q.Encode()
	}
	http.Redirect(w, r, target, http.StatusFound)
}
