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

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/audit"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/compliance"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/grafana"
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

	// Slice 4 server-health + Grafana embed surface. When HealthConfigured
	// is true, HealthPoller MUST be non-nil. When GrafanaConfigured is
	// true, GrafanaSigner + GrafanaConfig MUST be populated. Half-wired
	// states are caught at New() so a "missing signer mid-request" path
	// is not reachable in production.
	HealthPoller      handlers.HealthPoller
	HealthConfigured  bool
	GrafanaSigner     *grafana.Signer
	GrafanaConfig     handlers.GrafanaPanelConfig
	GrafanaConfigured bool

	// Slice 5 — API key management against the gateway admin HTTP API.
	// Half-wired states (KeysConfigured=true but KeysAdmin nil) fail-closed
	// at New(), mirroring the Slice 3 + Slice 4 pattern.
	KeysAdmin      handlers.AdminClient
	KeysAudit      audit.Emitter
	KeysConfigured bool

	// Slice 6 — audit log browser. AuditStore is the read-only audit
	// DB layer; SavedFilters is the per-user filter persistence
	// (may be nil — the surface still renders without it).
	// AuditEmitter mirrors KeysAudit — used for the paired
	// audit.reveal_raw + audit.csv_export_with_reveal events.
	// Half-wired AuditConfigured=true but AuditStore=nil fail-closes
	// at New().
	AuditStore      handlers.AuditReadStore
	SavedFilters    handlers.SavedFiltersReadWriteStore
	AuditEmitter    audit.Emitter
	AuditConfigured bool

	// Slice 7 — compliance PDF export. Aggregator wraps the cert DB
	// (Slice 3) + audit-log DB (Slice 6) pools; either may be nil
	// when the corresponding surface is unconfigured (the aggregator
	// returns zero-value counts for that population).
	// ComplianceConfigured is the honesty bit: false renders the
	// "not configured" explainer + POST returns 404. Admin-only
	// (RequireRole gate at the mux level — viewers see 404).
	//
	// KitVersion + DashboardVersion + ImageDigests are the static
	// metadata embedded on every PDF cover page so the customer's
	// evidence chain documents what kit + image set produced the
	// artefact.
	ComplianceAggregator     *compliance.Aggregator
	ComplianceConfigured     bool
	ComplianceKitVersion     string
	ComplianceImageDigests   map[string]string
	ComplianceMaxWindowDays  int
	ComplianceDefaultCustomer string
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
	// Slice 4 health + Grafana surface validation. Mirrors the OIDC /
	// cert-surface pattern: half-wired states fail-closed at boot.
	if opts.HealthConfigured && opts.HealthPoller == nil {
		return nil, errors.New("server: HealthConfigured requires HealthPoller")
	}
	if opts.GrafanaConfigured {
		if opts.GrafanaSigner == nil {
			return nil, errors.New("server: GrafanaConfigured requires GrafanaSigner")
		}
		if strings.TrimSpace(opts.GrafanaConfig.BaseURL) == "" {
			return nil, errors.New("server: GrafanaConfigured requires GrafanaConfig.BaseURL")
		}
	}
	// Slice 5 keys surface validation — same half-wired guard.
	if opts.KeysConfigured && opts.KeysAdmin == nil {
		return nil, errors.New("server: KeysConfigured requires KeysAdmin")
	}
	// Slice 6 audit surface validation — same half-wired guard.
	if opts.AuditConfigured && opts.AuditStore == nil {
		return nil, errors.New("server: AuditConfigured requires AuditStore")
	}
	// Slice 7 compliance surface validation — same half-wired guard.
	// ComplianceConfigured=true but Aggregator=nil would crash the
	// /compliance/export handler at first POST; fail-closed at New().
	if opts.ComplianceConfigured && opts.ComplianceAggregator == nil {
		return nil, errors.New("server: ComplianceConfigured requires ComplianceAggregator")
	}
	healthDeps := &handlers.HealthDeps{
		Renderer:          renderer,
		Poller:            opts.HealthPoller,
		GrafanaSigner:     opts.GrafanaSigner,
		GrafanaConfig:     opts.GrafanaConfig,
		HealthConfigured:  opts.HealthConfigured,
		GrafanaConfigured: opts.GrafanaConfigured,
	}
	keysDeps := handlers.NewKeysDeps(renderer, opts.KeysAdmin, opts.KeysAudit, opts.KeysConfigured)
	var certDeps *handlers.CertsDeps
	var bulkDeps *handlers.BulkReverifyDeps
	if opts.CertConfigured {
		certDeps = &handlers.CertsDeps{
			Renderer:   renderer,
			Store:      opts.CertStore,
			Verifier:   opts.WitnessClient,
			Configured: true,
		}
		// Bulk worker needs the audit-DB resolver so cert_id values from
		// the browser checkboxes get translated to the witness's
		// request_id keys before driving Verify (witness lookup key is
		// request_id, per upstream cert_server.go:44-53).
		bulkDeps = handlers.NewBulkReverifyDeps(opts.WitnessClient, renderer, opts.CertStore)
	} else {
		// Unconfigured mode: deps still get rendered but every handler
		// short-circuits to the not-configured page.
		certDeps = &handlers.CertsDeps{
			Renderer:   renderer,
			Configured: false,
		}
		bulkDeps = handlers.NewBulkReverifyDeps(nil, renderer, nil)
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
		// Inspector + validator + reverify routing.
		//  /certs/{id}            → InspectorHandler (GET)
		//  /certs/{id}/validator  → ValidatorHandler (GET; audit-grade
		//                           deep-link, claim chain only)
		//  /certs/{id}/reverify   → ReverifyHandler  (POST)
		if strings.HasSuffix(path, "/reverify") {
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			certDeps.ReverifyHandler(w, r)
			return
		}
		if strings.HasSuffix(path, "/validator") {
			if r.Method != http.MethodGet {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			certDeps.ValidatorHandler(w, r)
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

	// Slice 4 server-health + Grafana embed routes. Both auth-gated (the
	// middleware allowlist is unchanged — only /healthz, /login, /static
	// and /auth/oidc/* are public). Operator opens /health, sees the
	// service-card grid, optionally clicks into the drawer which POSTs to
	// /health/grafana-jwt for a freshly-minted token.
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		healthDeps.HealthOverviewHandler(w, r)
	})
	mux.Handle("/health/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch path {
		case "/health/":
			http.Redirect(w, r, "/health", http.StatusPermanentRedirect)
			return
		case "/health/grafana-jwt":
			healthDeps.HealthGrafanaJWTHandler(w, r)
			return
		case "/health/grafana-jwt/":
			http.Redirect(w, r, "/health/grafana-jwt", http.StatusPermanentRedirect)
			return
		}
		http.NotFound(w, r)
	}))

	// Slice 6 — audit log browser. Both viewer and admin can access;
	// PII redaction is render-time. Admin "Reveal raw" is an
	// admin-only POST that emits a paired audit.reveal_raw event.
	// CSV export with `?reveal=true` is also admin-only.
	auditDeps := handlers.NewAuditDeps(renderer, opts.AuditStore, opts.SavedFilters, opts.AuditEmitter, opts.AuditConfigured)
	mux.HandleFunc("/audit", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		auditDeps.BrowserHandler(w, r)
	})
	mux.Handle("/audit/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch path {
		case "/audit/":
			http.Redirect(w, r, "/audit", http.StatusPermanentRedirect)
			return
		case "/audit/export.csv":
			if r.Method != http.MethodGet {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			auditDeps.CSVExportHandler(w, r)
			return
		case "/audit/export.csv/":
			http.Redirect(w, r, "/audit/export.csv", http.StatusPermanentRedirect)
			return
		case "/audit/saved-filters":
			switch r.Method {
			case http.MethodGet:
				auditDeps.SavedFiltersGet(w, r)
				return
			case http.MethodPost:
				auditDeps.SavedFiltersPost(w, r)
				return
			default:
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
		}
		// /audit/saved-filters/{name} — DELETE-as-POST (form action
		// with hidden _method=delete).
		if strings.HasPrefix(path, "/audit/saved-filters/") {
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			auditDeps.SavedFiltersDelete(w, r)
			return
		}
		// /audit/{event_id}/reveal-raw — admin reveal POST
		if strings.HasSuffix(path, "/reveal-raw") {
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			auditDeps.RevealRawHandler(w, r)
			return
		}
		// /audit/{event_id} — detail GET.
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		auditDeps.DetailHandler(w, r)
	}))

	// Slice 5 — API key management. Admin-only. The middleware
	// (RequireRole) returns 404 for viewers per the locked Slice 1
	// pattern (apps/dashboard/internal/auth/middleware.go:77-91 +
	// middleware_test.go::TestRequireRole_NotFoundForWrongRole). The
	// handler also fail-closes internally as defense-in-depth.
	keysMux := http.NewServeMux()
	keysMux.HandleFunc("/keys", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		keysDeps.BrowserHandler(w, r)
	})
	keysMux.Handle("/keys/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch path {
		case "/keys/":
			http.Redirect(w, r, "/keys", http.StatusPermanentRedirect)
			return
		case "/keys/mint":
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			keysDeps.MintHandler(w, r)
			return
		case "/keys/mint/":
			http.Redirect(w, r, "/keys/mint", http.StatusPermanentRedirect)
			return
		case "/keys/bulk-revoke":
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			keysDeps.BulkRevokeHandler(w, r)
			return
		case "/keys/bulk-revoke/":
			http.Redirect(w, r, "/keys/bulk-revoke", http.StatusPermanentRedirect)
			return
		}
		// /keys/{key_id}/revoke
		if strings.HasSuffix(path, "/revoke") {
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			keysDeps.RevokeHandler(w, r)
			return
		}
		http.NotFound(w, r)
	}))
	mux.Handle("/keys", auth.RequireRole(auth.RoleAdmin, keysMux))
	mux.Handle("/keys/", auth.RequireRole(auth.RoleAdmin, keysMux))

	// Slice 7 — compliance PDF export. Admin-only (RequireRole 404s
	// viewers per the locked Slice 1 pattern). The /compliance GET
	// renders the form; /compliance/export POST returns PDF bytes
	// after fail-closed banned-literal + audit-emit gates fire.
	complianceDeps := handlers.NewComplianceDeps(
		renderer,
		opts.ComplianceAggregator,
		opts.AuditEmitter,
		opts.ComplianceKitVersion,
		opts.Version,
		opts.ComplianceImageDigests,
		opts.ComplianceMaxWindowDays,
		opts.ComplianceDefaultCustomer,
		opts.ComplianceConfigured,
	)
	complianceMux := http.NewServeMux()
	complianceMux.HandleFunc("/compliance", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		complianceDeps.ExportPage(w, r)
	})
	complianceMux.Handle("/compliance/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/compliance/":
			http.Redirect(w, r, "/compliance", http.StatusPermanentRedirect)
			return
		case "/compliance/export":
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			complianceDeps.ExportPDF(w, r)
			return
		case "/compliance/export/":
			http.Redirect(w, r, "/compliance/export", http.StatusPermanentRedirect)
			return
		}
		http.NotFound(w, r)
	}))
	mux.Handle("/compliance", auth.RequireRole(auth.RoleAdmin, complianceMux))
	mux.Handle("/compliance/", auth.RequireRole(auth.RoleAdmin, complianceMux))

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
