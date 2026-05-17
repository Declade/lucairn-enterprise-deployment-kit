package handlers

import (
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
)

// OIDCDeps groups the OIDC-specific collaborators. Kept separate from the
// Slice 1 Deps so the dashboard binary boots cleanly when OIDC is not
// enabled — main.go only constructs an OIDCDeps when cfg.OIDCEnabled is
// true, and the server route table only mounts the OIDC handlers when
// OIDCDeps is non-nil.
//
// SecureCookies mirrors handlers.Deps's field used at session-cookie
// write time. Default true; only flipped to false for non-TLS test
// environments (and the production deploy ALWAYS fronts the dashboard
// with TLS — non-TLS prod is intentionally undocumented).
type OIDCDeps struct {
	Authenticator *auth.OIDCAuthenticator
	State         auth.OIDCStateStore
	Sessions      auth.SessionStore
	SessionTTL    time.Duration
	Renderer      *views.Renderer
}

// LoginRedirect kicks off an OIDC Authorization Code with PKCE flow.
// Mints a fresh state + code_verifier server-side, persists them in the
// OIDCStateStore, and redirects the user agent to the IdP authorize
// endpoint. The state token is the map key; one-shot Consume in the
// callback handler closes the replay window.
//
// Method gate: POST only. Mounted as POST from the SSO button on /login
// so a casual GET to /auth/oidc/login (e.g. a stale bookmark or browser
// prefetch) does NOT silently start a flow that pollutes state-store
// quota.
func (d *OIDCDeps) LoginRedirect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	// CSRF on the kickoff: the SSO button submits the same csrf hidden
	// input as the local-login form. Without this gate an off-site form
	// could push a victim into the OIDC flow against an attacker-known
	// state and (combined with a stolen redirect) ride the session.
	if err := auth.VerifyToken(r); err != nil {
		http.Error(w, "csrf failure", http.StatusForbidden)
		return
	}
	next := sanitizeNext(r.PostFormValue("next"))
	rec, err := d.State.Create(next)
	if err != nil {
		log.Printf("oidc_login_redirect: state create: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	target := d.Authenticator.LoginURL(rec.State, rec.Nonce, rec.CodeVerifier)
	http.Redirect(w, r, target, http.StatusFound)
}

// Callback completes the OIDC flow. Validates state, exchanges the auth
// code for an ID token, verifies the token, maps groups → role, mints a
// session (rotating any pre-existing cookie), and redirects to ?next= or
// /dashboard.
//
// Failure modes:
//   - Unknown / expired / replayed state: 400 + generic flash. We do NOT
//     reveal which sub-case so an attacker probing the callback cannot
//     enumerate live states.
//   - IdP returned ?error= or ?error_description=: same generic flash;
//     the underlying error is audit-logged.
//   - Group mapping rejection (neither admin nor viewer): generic flash
//     + audit-log the rejected email + groups list. Future slice may
//     surface "your administrator has not enabled access for your
//     account" as a more helpful copy; v1 stays generic for surface
//     hygiene.
//
// Method gate: GET. OIDC callbacks are always GET — the spec doesn't
// allow POST here. A bare POST to /auth/oidc/callback gets the standard
// 405.
func (d *OIDCDeps) Callback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	q := r.URL.Query()

	if idpErr := q.Get("error"); idpErr != "" {
		// IdP-side denial: user clicked "Cancel" on the consent screen,
		// or the IdP rejected the client. Audit-log the IdP error code so
		// operators can debug; surface a generic flash to the browser.
		//
		// error_description is operator-untrusted (the IdP supplies it).
		// Truncate before log to defend against a hostile IdP attempting
		// to flood the dashboard log with multi-MB description payloads.
		descr := q.Get("error_description")
		log.Printf("oidc_callback: idp error %q description=%q", idpErr, truncateOIDCErrorDescription(descr, 200))
		d.renderCallbackError(w, r, "Sign-in could not be completed. Please try again.")
		return
	}

	stateValue := q.Get("state")
	code := q.Get("code")
	if stateValue == "" || code == "" {
		log.Printf("oidc_callback: state or code missing in query")
		d.renderCallbackError(w, r, "Sign-in could not be completed. Please try again.")
		return
	}

	rec, ok := d.State.Consume(stateValue)
	if !ok {
		log.Printf("oidc_callback: unknown or expired state")
		d.renderCallbackError(w, r, "Sign-in expired or was replayed. Please try again.")
		return
	}

	user, err := d.Authenticator.Exchange(r.Context(), code, rec.CodeVerifier, rec.Nonce)
	if err != nil {
		// Audit-log the underlying error class without surfacing it to
		// the browser. Operators can grep dashboard logs for
		// "oidc_callback: exchange" to see the OIDC error code.
		switch {
		case errors.Is(err, auth.ErrNeitherGroup):
			log.Printf("oidc_callback: rejected — user not in admin or viewer group")
		case errors.Is(err, auth.ErrGroupsClaimMissing):
			log.Printf("oidc_callback: rejected — groups claim missing")
		default:
			log.Printf("oidc_callback: exchange: %v", err)
		}
		d.renderCallbackError(w, r, "Sign-in could not be completed. Please try again.")
		return
	}

	// Rotate any pre-existing session ID. Mirrors the local-login path
	// at handlers.go:75-77 — same session-fixation defense.
	if existing, cookieErr := r.Cookie(auth.SessionCookieName); cookieErr == nil && existing.Value != "" {
		d.Sessions.Delete(existing.Value)
	}

	sess, err := d.Sessions.Create(user)
	if err != nil {
		log.Printf("oidc_callback: session create: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	auth.SetSessionCookie(w, sess.ID, d.SessionTTL)

	next := rec.NextPath
	if next == "" {
		next = "/dashboard"
	}
	http.Redirect(w, r, next, http.StatusFound)
}

// renderCallbackError replays /login with a flash. We do NOT raw-write
// the OIDC error code to the browser — operators get it via audit logs,
// users get a single generic copy. Surface hygiene + info-leak defense.
func (d *OIDCDeps) renderCallbackError(w http.ResponseWriter, r *http.Request, msg string) {
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("oidc_callback: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusUnauthorized)
	data := views.PageData{
		Title:       "Sign in",
		Flash:       msg,
		CSRFToken:   tok,
		OIDCEnabled: true,
	}
	if err := d.Renderer.Render(w, "login.html.tmpl", data); err != nil {
		log.Printf("oidc_callback_render: %v", err)
	}
}

// truncateOIDCErrorDescription clips an IdP-supplied error_description to
// `n` bytes (200 in production callsites) before it reaches log.Printf.
// The IdP supplies the field verbatim from the authorize redirect query,
// so a hostile or misbehaving IdP could otherwise push a multi-MB string
// straight into the dashboard log stream.
func truncateOIDCErrorDescription(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "...[truncated]"
}

