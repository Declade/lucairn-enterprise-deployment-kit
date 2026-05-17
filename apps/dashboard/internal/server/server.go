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
	"strings"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/handlers"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/store"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness"
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

	// Slice 3 cert surface. When CertConfigured is true, CertStore and
	// WitnessClient MUST both be non-nil; the server.New constructor
	// validates this so a half-wired surface is caught at boot rather
	// than at first request. When CertConfigured is false, the cert
	// routes still register and render a "not configured" explainer.
	CertStore      *store.CertStore
	WitnessClient  *witness.Client
	CertConfigured bool
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

	// Slice 3 cert surface validation: half-wired CertConfigured is a
	// config error caught at New(), not a runtime surprise mid-request.
	if opts.CertConfigured {
		if opts.CertStore == nil {
			return nil, errors.New("server: CertConfigured requires CertStore")
		}
		if opts.WitnessClient == nil {
			return nil, errors.New("server: CertConfigured requires WitnessClient")
		}
	}
	var certDeps *handlers.CertsDeps
	var bulkDeps *handlers.BulkReverifyDeps
	if opts.CertConfigured {
		certDeps = &handlers.CertsDeps{
			Renderer:   renderer,
			Store:      opts.CertStore,
			Verifier:   opts.WitnessClient,
			Configured: true,
		}
		bulkDeps = handlers.NewBulkReverifyDeps(opts.WitnessClient, renderer)
	} else {
		// Unconfigured mode: deps still get rendered but every handler
		// short-circuits to the not-configured page.
		certDeps = &handlers.CertsDeps{
			Renderer:   renderer,
			Configured: false,
		}
		bulkDeps = handlers.NewBulkReverifyDeps(nil, renderer)
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

	// Slice 3 cert routes. All gated through the auth chain below.
	mux.HandleFunc("/certs", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		certDeps.BrowserHandler(w, r)
	})
	// Trailing-slash form: redirect to canonical path so probes /
	// hand-typed URLs survive (FX-17 pattern from Slice 1).
	mux.Handle("/certs/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// /certs/.csv → CSV export; /certs/bulk-reverify → bulk POST.
		// All other paths dispatch to the inspector + reverify routing
		// below; the trailing-slash-only path redirects to /certs.
		path := r.URL.Path
		if path == "/certs/" {
			http.Redirect(w, r, "/certs", http.StatusPermanentRedirect)
			return
		}
		// Bulk-reverify subtree.
		if path == "/certs/bulk-reverify" {
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			bulkDeps.BulkReverifyHandler(w, r)
			return
		}
		if strings.HasPrefix(path, "/certs/bulk-reverify/") {
			bulkDeps.BulkReverifyProgressHandler(w, r)
			return
		}
		// Inspector + reverify routing: /certs/{id} and /certs/{id}/reverify.
		if strings.HasSuffix(path, "/reverify") {
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			certDeps.ReverifyHandler(w, r)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		certDeps.InspectorHandler(w, r)
	}))
	mux.HandleFunc("/certs.csv", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		certDeps.CSVExportHandler(w, r)
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
