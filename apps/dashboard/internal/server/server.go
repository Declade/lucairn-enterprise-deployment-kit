// Package server assembles the dashboard's HTTP server, middleware chain,
// and static asset handlers. Slice 1 ships /login, /logout, /dashboard,
// /healthz and the embedded /static/* tree.
package server

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/handlers"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
)

// Options configures a Server.
//
// OIDC fields are optional. When OIDCAuthenticator is nil the server runs
// in Slice 1 mode (local-admin only) — the /auth/oidc/* routes are not
// mounted and the login template sees OIDCEnabled=false. When all three
// (Authenticator/State/Enabled) are populated the OIDC routes wire in
// and the login page renders the SSO block.
//
// Local admin login continues to work in BOTH modes. There is no way to
// disable the local form in v1; that is a deliberate operational
// fallback for bootstrap + IdP-outage scenarios.
type Options struct {
	ListenAddr        string
	Version           string
	Authenticator     auth.Authenticator
	Sessions          auth.SessionStore
	StaticFS          fs.FS // optional override for tests
	OIDCAuthenticator *auth.OIDCAuthenticator
	OIDCState         auth.OIDCStateStore
	OIDCEnabled       bool
}

// Server bundles the HTTP server and its lifecycle.
type Server struct {
	httpServer *http.Server
}

// New builds a configured Server ready to Run.
func New(opts Options) (*Server, error) {
	if opts.Authenticator == nil {
		return nil, errors.New("server: authenticator is required")
	}
	if opts.Sessions == nil {
		return nil, errors.New("server: session store is required")
	}
	if opts.ListenAddr == "" {
		return nil, errors.New("server: listen addr is required")
	}
	renderer, err := views.New()
	if err != nil {
		return nil, fmt.Errorf("server: load views: %w", err)
	}
	deps := &handlers.Deps{
		Renderer:      renderer,
		Authenticator: opts.Authenticator,
		Sessions:      opts.Sessions,
		SessionTTL:    8 * time.Hour,
		OIDCEnabled:   opts.OIDCEnabled,
	}
	// Slice 2: OIDC wiring is opt-in. The Options validation below
	// requires the OIDC trio to be set together OR omitted together —
	// half-wired OIDC is a config error caught at New(), not a runtime
	// surprise mid-login.
	if opts.OIDCEnabled {
		if opts.OIDCAuthenticator == nil {
			return nil, errors.New("server: OIDCEnabled requires OIDCAuthenticator")
		}
		if opts.OIDCState == nil {
			return nil, errors.New("server: OIDCEnabled requires OIDCState")
		}
	}
	var oidcDeps *handlers.OIDCDeps
	if opts.OIDCEnabled {
		oidcDeps = &handlers.OIDCDeps{
			Authenticator: opts.OIDCAuthenticator,
			State:         opts.OIDCState,
			Sessions:      opts.Sessions,
			SessionTTL:    8 * time.Hour,
			Renderer:      renderer,
		}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthzHandler(opts.Version))
	// Slash-variant redirects. The auth-middleware allowlist (FX-17) accepts
	// /healthz/ and /login/ so liveness probes and hand-typed URLs survive the
	// gate, but the mux only registered the canonical paths — meaning the
	// allowed requests fell through to the catch-all 404. 308 preserves method
	// + body for probe POSTs (some k8s liveness configs POST) and the same
	// redirect serves operators who type the URL by hand.
	mux.Handle("/healthz/", http.RedirectHandler("/healthz", http.StatusPermanentRedirect))
	mux.Handle("/login/", http.RedirectHandler("/login", http.StatusPermanentRedirect))
	mux.HandleFunc("/login", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			deps.LoginGet(w, r)
		case http.MethodPost:
			deps.LoginPost(w, r)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})
	mux.HandleFunc("/logout", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		deps.LogoutPost(w, r)
	})
	if oidcDeps != nil {
		// Slash-variant redirects mirror /login + /healthz so an
		// IdP-configured callback URL with a trailing slash + an operator
		// typing the kickoff URL by hand both survive the gate. 308
		// preserves method + body for the POST kickoff.
		mux.HandleFunc("/auth/oidc/login", oidcDeps.LoginRedirect)
		mux.Handle("/auth/oidc/login/", http.RedirectHandler("/auth/oidc/login", http.StatusPermanentRedirect))
		mux.HandleFunc("/auth/oidc/callback", oidcDeps.Callback)
		mux.Handle("/auth/oidc/callback/", http.RedirectHandler("/auth/oidc/callback", http.StatusPermanentRedirect))
	}
	mux.HandleFunc("/dashboard", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		deps.DashboardHome(w, r)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		http.Redirect(w, r, "/dashboard", http.StatusFound)
	})

	staticFS, err := pickStaticFS(opts.StaticFS)
	if err != nil {
		return nil, err
	}
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.FS(staticFS))))

	chain := SecurityHeaders(
		auth.LoadSession(opts.Sessions)(
			auth.RequireSession()(mux),
		),
	)

	return &Server{
		httpServer: &http.Server{
			Addr:              opts.ListenAddr,
			Handler:           chain,
			ReadHeaderTimeout: 10 * time.Second,
			ReadTimeout:       30 * time.Second,
			WriteTimeout:      60 * time.Second,
			IdleTimeout:       2 * time.Minute,
		},
	}, nil
}

// Run starts listening until ctx is cancelled. On cancel a graceful shutdown
// is attempted with a 30s deadline; any error is returned.
func (s *Server) Run(ctx context.Context) error {
	errCh := make(chan error, 1)
	go func() {
		if err := s.httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
			return
		}
		errCh <- nil
	}()
	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return s.httpServer.Shutdown(shutdownCtx)
}

// Handler exposes the configured handler for testing.
func (s *Server) Handler() http.Handler { return s.httpServer.Handler }
