// Package handlers wires the dashboard's HTTP handlers. Slice 1 ships
// login + logout + dashboard home + healthz. Each handler is keep-the-thin —
// auth + render + small redirect logic.
package handlers

import (
	"errors"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
)

// Deps groups the runtime collaborators handler funcs need.
//
// OIDCEnabled is a single bool the login surface reads to decide whether
// to render the "Sign in with SSO" block + divider. The flag is set ONCE
// at server start-up (when main.go has resolved the OIDC config + built
// an OIDCAuthenticator); flipping it without a restart is intentionally
// not supported in v1. Wiring it via Deps keeps the handler shape simple
// — every login render passes through LoginGet / renderLoginError, both
// of which lift the value into PageData uniformly.
type Deps struct {
	Renderer      *views.Renderer
	Authenticator auth.Authenticator
	Sessions      auth.SessionStore
	SessionTTL    time.Duration
	OIDCEnabled   bool

	// Dashboard home (overview) metrics providers. LiveMetrics wraps
	// the production stores; DemoMetrics wraps internal/demodata/.
	// Either may be nil — DashboardHome falls back to ZeroMetrics
	// when neither is wired, and falls back to LiveMetrics when
	// demo-toggle is on but DemoMetrics is nil. DemoToggleEnabled
	// is the install-time switch that exposes the in-page toggle
	// to operators; false hides the button entirely.
	LiveMetrics       MetricsProvider
	DemoMetrics       MetricsProvider
	DemoToggleEnabled bool
}

// LoginGet renders the login form.
func (d *Deps) LoginGet(w http.ResponseWriter, r *http.Request) {
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("login_get: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if _, ok := auth.CurrentUser(r); ok {
		http.Redirect(w, r, "/dashboard", http.StatusFound)
		return
	}
	data := views.PageData{
		Title:       "Sign in",
		CSRFToken:   tok,
		NextPath:    sanitizeNext(r.URL.Query().Get("next")),
		OIDCEnabled: d.OIDCEnabled,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, "login.html.tmpl", data); err != nil {
		log.Printf("login_get: render: %v", err)
	}
}

// LoginPost validates credentials and starts a session on success.
func (d *Deps) LoginPost(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if err := auth.VerifyToken(r); err != nil {
		d.renderLoginError(w, r, "Session expired. Please try again.")
		return
	}
	email := strings.TrimSpace(r.PostFormValue("email"))
	password := r.PostFormValue("password")
	user, err := d.Authenticator.Authenticate(email, password)
	if err != nil {
		if !errors.Is(err, auth.ErrInvalidCredentials) {
			log.Printf("login_post: unexpected auth error: %v", err)
		}
		d.renderLoginError(w, r, "Invalid email or password.")
		return
	}
	// Invalidate any pre-existing session ID before minting a new one.
	// Without this, an attacker who pinned a known session cookie on the
	// victim's browser (e.g. via a subdomain XSS or network injection prior
	// to first login) could "ride" the post-login session under the
	// attacker-known ID — the classic session-fixation pattern. Cookie
	// rotation closes that window on every successful authentication.
	if existing, err := r.Cookie(auth.SessionCookieName); err == nil && existing.Value != "" {
		d.Sessions.Delete(existing.Value)
	}
	sess, err := d.Sessions.Create(user)
	if err != nil {
		log.Printf("login_post: session create: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	auth.SetSessionCookie(w, sess.ID, d.SessionTTL)
	next := sanitizeNext(r.PostFormValue("next"))
	if next == "" {
		next = "/dashboard"
	}
	http.Redirect(w, r, next, http.StatusFound)
}

// LogoutPost destroys the session and redirects to /login.
func (d *Deps) LogoutPost(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if err := auth.VerifyToken(r); err != nil {
		http.Error(w, "csrf failure", http.StatusForbidden)
		return
	}
	if sess, ok := auth.CurrentSession(r); ok {
		d.Sessions.Delete(sess.ID)
	}
	auth.ClearSessionCookie(w)
	http.Redirect(w, r, "/login", http.StatusFound)
}

// DashboardHome is implemented on Deps in dashboard_home.go (the
// enterprise overview page); the placeholder body below remained from
// pre-overview Slice 1. Now redirects to the new implementation so
// any vestigial caller surface still works.
//
// Deprecated: use the canonical DashboardHome in dashboard_home.go.
func (d *Deps) dashboardHomeOriginalDeprecated(w http.ResponseWriter, r *http.Request) {
}

func (d *Deps) renderLoginError(w http.ResponseWriter, r *http.Request, msg string) {
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("login_post: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusUnauthorized)
	data := views.PageData{
		Title:       "Sign in",
		Flash:       msg,
		CSRFToken:   tok,
		NextPath:    sanitizeNext(r.PostFormValue("next")),
		OIDCEnabled: d.OIDCEnabled,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, "login.html.tmpl", data); err != nil {
		log.Printf("login_error_render: %v", err)
	}
}

// sanitizeNext keeps only same-origin relative paths. Anything containing a
// scheme, host, or backslash is dropped.
func sanitizeNext(s string) string {
	if s == "" {
		return ""
	}
	if strings.ContainsAny(s, "\\\r\n") {
		return ""
	}
	u, err := url.Parse(s)
	if err != nil {
		return ""
	}
	if u.IsAbs() || u.Host != "" {
		return ""
	}
	if !strings.HasPrefix(u.Path, "/") {
		return ""
	}
	if strings.HasPrefix(u.Path, "//") {
		return ""
	}
	return u.RequestURI()
}
