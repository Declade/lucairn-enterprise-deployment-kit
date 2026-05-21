// Lucairn Enterprise Dashboard.
//
// Self-hosted, single Go binary. Ships inside the
// lucairn-enterprise-deployment-kit. Customer's cluster operates this; no
// telemetry or operational state crosses the customer-vendor boundary.
//
// Slice 1 shipped: auth + shell foundation.
// Slice 2 added: OIDC SSO (opt-in; default OFF).
// Slice 3 adds: cert browser + inspector + audit-grade live validator
//
//	(gates on LUCAIRN_DASHBOARD_AUDIT_DB_URL +
//	 LUCAIRN_DASHBOARD_WITNESS_ENDPOINT; cert pages render
//	 a "not configured" explainer when those are unset).
//
// Design: specs/prd-2026-05-17-enterprise-dashboard.md.
package main

import (
	"context"
	"embed"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/audit"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/config"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/gateway"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/grafana"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/handlers"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/health"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/server"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/store"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed static
var embeddedStatic embed.FS

// version is set at build time via -ldflags "-X main.version=<git-sha>". It
// defaults to "dev" for local builds.
var version = "dev"

func main() {
	listenAddr := flag.String("listen-addr", "", "HTTP listen address (overrides LUCAIRN_DASHBOARD_LISTEN_ADDR)")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		return
	}

	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	if *listenAddr != "" {
		cfg.ListenAddr = *listenAddr
	}

	authenticator, err := auth.NewLocalAuthenticator(cfg.BootstrapEmail, cfg.BootstrapPassword)
	if err != nil {
		log.Fatalf("auth: %v", err)
	}

	sessions := auth.NewMemorySessionStore(8*time.Hour, 60*time.Second)

	// OIDC wiring is conditional. Discovery happens at startup; if the
	// IdP is unreachable we fail-fast rather than silently leaving SSO
	// broken. Operators who want graceful degradation should leave OIDC
	// disabled and rely on the local-admin path.
	var (
		oidcAuth  *auth.OIDCAuthenticator
		oidcState auth.OIDCStateStore
	)
	if cfg.OIDCEnabled {
		// Bounded startup deadline so the dashboard pod readiness signal
		// flips within the k8s default failure threshold even when the
		// IdP is slow to respond to the discovery request.
		discoveryCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		oidcAuth, err = auth.NewOIDCAuthenticator(discoveryCtx, auth.OIDCConfig{
			IssuerURL:    cfg.OIDCIssuerURL,
			ClientID:     cfg.OIDCClientID,
			ClientSecret: cfg.OIDCClientSecret,
			RedirectURL:  cfg.OIDCCallbackURL,
			GroupsClaim:  cfg.OIDCGroupsClaim,
			AdminGroup:   cfg.OIDCAdminGroup,
			ViewerGroup:  cfg.OIDCViewerGroup,
		})
		cancel()
		if err != nil {
			log.Fatalf("oidc: %v", err)
		}
		oidcState = auth.NewMemoryOIDCStateStore(auth.OIDCStateTTL, 60*time.Second)
		log.Printf("oidc enabled (issuer=%s, callback=%s)", cfg.OIDCIssuerURL, cfg.OIDCCallbackURL)
	}

	// Cert browser + inspector wiring (Slice 3).
	//
	// Both pieces are optional. When the operator has not set the audit
	// DB connection string OR the witness endpoint, the cert routes
	// still register but every handler renders a "not configured"
	// explainer instead of falling over. Same opt-in posture as the
	// OIDC trio: register the routes, let the handler decide what to
	// render based on whether deps are populated.
	var (
		certStore  *store.CertStore
		witnessCli *witness.Client
		certs      *handlersCertWiring
	)
	if cfg.AuditDBURL != "" && cfg.WitnessEndpoint != "" {
		ctxStore, cancelStore := context.WithTimeout(context.Background(), 15*time.Second)
		var err error
		certStore, _, err = store.NewCertStore(ctxStore, cfg.AuditDBURL)
		cancelStore()
		if err != nil {
			log.Fatalf("cert store: %v", err)
		}
		witnessCli, err = witness.NewClient(cfg.WitnessEndpoint)
		if err != nil {
			log.Fatalf("witness client: %v", err)
		}
		certs = &handlersCertWiring{store: certStore, witness: witnessCli, configured: true}
		log.Printf("cert browser enabled (db=%s, witness=%s)", redactDSN(cfg.AuditDBURL), cfg.WitnessEndpoint)
	} else {
		certs = &handlersCertWiring{configured: false}
		log.Printf("cert browser disabled (set LUCAIRN_DASHBOARD_AUDIT_DB_URL and LUCAIRN_DASHBOARD_WITNESS_ENDPOINT to enable)")
	}

	// Slice 4 wiring: server-health poller + Grafana JWT signer.
	//
	// Two distinct opt-in semantics:
	//   - HealthServices: ALWAYS-ON BY DEFAULT. Empty string falls back
	//     to the bundled DefaultServicesSpec (12 standard kit services
	//     polled every 10s). The poller is DISABLED only when the value
	//     is the literal string "disabled" — any other value (including
	//     the empty string) starts the poller against the parsed spec.
	//   - GrafanaURL: OFF BY DEFAULT. Empty URL → JWT signer is nil +
	//     the drawer surface stays in the "not configured" state.
	//     /health/grafana-jwt returns 503.
	//
	// The poller's ctx is the same SIGTERM/SIGINT-cancelled ctx the
	// server uses, so a clean shutdown stops all per-service goroutines.
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	var (
		healthPoller      *health.Poller
		healthConfigured  bool
		grafanaSigner     *grafana.Signer
		grafanaCfg        handlers.GrafanaPanelConfig
		grafanaConfigured bool
	)
	{
		// Health surface boot.
		spec := cfg.HealthServices
		// Empty spec → use bundled default; only DISABLE polling when
		// the operator explicitly sets a single literal "disabled" token
		// (case-insensitive — DISABLED, Disabled, disabled all work).
		if strings.EqualFold(strings.TrimSpace(spec), "disabled") {
			log.Printf("health poller disabled via LUCAIRN_DASHBOARD_HEALTH_SERVICES=disabled")
		} else {
			services, err := health.ParseServicesSpec(spec)
			if err != nil {
				log.Fatalf("health: %v", err)
			}
			healthPoller = health.NewPoller(services, health.PollerOpts{
				Interval: time.Duration(cfg.HealthPollIntervalSeconds) * time.Second,
			})
			healthPoller.Start(ctx)
			healthConfigured = true
			log.Printf("health poller started (%d services, interval %ds)", len(services), cfg.HealthPollIntervalSeconds)
		}
	}
	// Slice 5 wiring: API key management against gateway admin HTTP API.
	// Both URL + token must be set together (config-loader already
	// validated the half-wired case); empty → /keys renders the
	// "not configured" explainer.
	var (
		adminClient     *gateway.AdminClient
		keysConfigured  bool
		auditEmitter    audit.Emitter = audit.NewLogEmitter()
	)
	if cfg.GatewayAdminURL != "" && cfg.GatewayAdminToken != "" {
		ac, err := gateway.NewAdminClient(cfg.GatewayAdminURL, cfg.GatewayAdminToken, nil)
		if err != nil {
			log.Fatalf("gateway admin client: %v", err)
		}
		adminClient = ac
		keysConfigured = true
		log.Printf("keys surface enabled (gateway admin=%s)", cfg.GatewayAdminURL)
	} else {
		log.Printf("keys surface disabled (set LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL + LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN to enable)")
	}

	// Slice 6 wiring: audit log browser. The new env var
	// LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL points at postgres-audit
	// (separate from Slice 3's LUCAIRN_DASHBOARD_AUDIT_DB_URL which
	// points at postgres-bridge for certs). When empty → /audit
	// renders the "not configured" explainer.
	var (
		auditStore       *store.AuditStore
		savedFilters     *store.SavedFiltersStore
		auditConfigured  bool
	)
	if cfg.AuditLogDBURL != "" {
		ctxAudit, cancelAudit := context.WithTimeout(context.Background(), 15*time.Second)
		var err error
		// Slice 6 fix-up r1 H3 / DRIFT-006: retain the pgxpool so we
		// can construct DBEmitter against it below. The pool is shared
		// between the audit-events read path (AuditStore) and the
		// audit-events write path (DBEmitter); pgxpool handles
		// concurrent access.
		var auditPool *pgxpool.Pool
		auditStore, auditPool, err = store.NewAuditStore(ctxAudit, cfg.AuditLogDBURL)
		cancelAudit()
		if err != nil {
			log.Fatalf("audit log store: %v", err)
		}
		// Reuse the audit-log pool's Querier for saved filters when no
		// separate saved-filters URL is set. The default makes operator
		// onboarding simpler; a separate role / URL is the opt-in
		// hardening path documented in OPS.md.
		// pgxpool implements the store.Querier interface directly via
		// its Query / QueryRow methods.
		savedFiltersURL := cfg.SavedFiltersDBURL
		if savedFiltersURL == "" {
			savedFiltersURL = cfg.AuditLogDBURL
		}
		ctxSF, cancelSF := context.WithTimeout(context.Background(), 15*time.Second)
		savedFilters, _, err = store.NewSavedFiltersStoreFromURL(ctxSF, savedFiltersURL)
		cancelSF()
		if err != nil {
			log.Printf("saved filters disabled (%v) — apply apps/dashboard/migrations/000001_create_saved_filters.up.sql and restart to enable", err)
			savedFilters = nil
		}
		auditConfigured = true
		// Slice 6 fix-up r1 H3 / DRIFT-006: when the audit-log DB is
		// wired we swap the pod-logs-only LogEmitter for a DBEmitter
		// that INSERTs into audit_events via the audit_app role's
		// existing INSERT grant. The dashboard's own audit-trail
		// browser then surfaces dashboard-emitted events (reveal-raw,
		// csv_export_with_reveal, key.mint_requested, key.revoke_requested)
		// alongside upstream service events. LogEmitter remains the
		// fallback for dev installs that haven't wired AUDIT_LOG_DB_URL.
		if auditPool != nil {
			auditEmitter = audit.NewDBEmitter(auditPool, "dsa-dashboard")
			log.Printf("audit emitter: DBEmitter (writes to audit_events on audit-log DB)")
		}
		log.Printf("audit log browser enabled (db=%s)", redactDSN(cfg.AuditLogDBURL))
	} else {
		log.Printf("audit log browser disabled (set LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL to enable)")
		log.Printf("audit emitter: LogEmitter — pod-logs-only fallback; dashboard-emitted audit events will NOT be queryable via /audit. Set LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL to enable the DBEmitter path.")
	}

	if cfg.GrafanaURL != "" {
		s, err := grafana.NewSigner(cfg.GrafanaJWTSecret, 0, nil)
		if err != nil {
			log.Fatalf("grafana signer: %v", err)
		}
		grafanaSigner = s
		grafanaCfg = handlers.GrafanaPanelConfig{
			BaseURL:              cfg.GrafanaURL,
			GatewayThroughputUID: cfg.GrafanaPanelGatewayUID,
			SanitizerHitRatesUID: cfg.GrafanaPanelSanitizerUID,
			WitnessVerifyRateUID: cfg.GrafanaPanelWitnessUID,
			AuditLogVolumeUID:    cfg.GrafanaPanelAuditUID,
		}
		grafanaConfigured = true
		log.Printf("grafana embed enabled (base=%s)", cfg.GrafanaURL)
	} else {
		log.Printf("grafana embed disabled (set LUCAIRN_DASHBOARD_GRAFANA_URL + LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET to enable)")
	}

	staticFS, err := fs.Sub(embeddedStatic, "static")
	if err != nil {
		log.Fatalf("static fs: %v", err)
	}
	server.SetEmbeddedStatic(staticFS)

	// Bridge *health.Poller into the handlers.HealthPoller interface;
	// when the poller is nil (disabled) pass nil through so server.New's
	// half-wired guard fires only when HealthConfigured is true.
	var healthPollerIface handlers.HealthPoller
	if healthPoller != nil {
		healthPollerIface = healthPoller
	}

	// Cast nil-typed nil into the handlers.AdminClient interface so a
	// pure-nil interface value reaches server.New (signal "not
	// configured" downstream without leaking a typed-nil that breaks
	// `if adminClient != nil` further down the chain).
	var keysAdminIface handlers.AdminClient
	if adminClient != nil {
		keysAdminIface = adminClient
	}

	// Same typed-nil → pure-nil dance for the Slice 6 audit stores.
	var auditStoreIface handlers.AuditReadStore
	if auditStore != nil {
		auditStoreIface = auditStore
	}
	var savedFiltersIface handlers.SavedFiltersReadWriteStore
	if savedFilters != nil {
		savedFiltersIface = savedFilters
	}

	srv, err := server.New(server.Options{
		ListenAddr:        cfg.ListenAddr,
		Version:           version,
		Authenticator:     authenticator,
		Sessions:          sessions,
		OIDCAuthenticator: oidcAuth,
		OIDCState:         oidcState,
		OIDCEnabled:       cfg.OIDCEnabled,
		CertStore:         certs.store,
		WitnessClient:     certs.witness,
		CertConfigured:    certs.configured,
		HealthPoller:      healthPollerIface,
		HealthConfigured:  healthConfigured,
		GrafanaSigner:     grafanaSigner,
		GrafanaConfig:     grafanaCfg,
		GrafanaConfigured: grafanaConfigured,
		KeysAdmin:         keysAdminIface,
		KeysAudit:         auditEmitter,
		KeysConfigured:    keysConfigured,
		AuditStore:        auditStoreIface,
		SavedFilters:      savedFiltersIface,
		AuditEmitter:      auditEmitter,
		AuditConfigured:   auditConfigured,
	})
	if err != nil {
		log.Fatalf("server: %v", err)
	}

	log.Printf("lucairn-dashboard %s listening on %s", version, cfg.ListenAddr)
	if err := srv.Run(ctx); err != nil {
		log.Fatalf("server stopped: %v", err)
	}
	if witnessCli != nil {
		_ = witnessCli.Close()
	}
	log.Printf("lucairn-dashboard shutdown complete")
}

// handlersCertWiring groups the cert-surface deps so main.go's call to
// server.New stays terse.
type handlersCertWiring struct {
	store      *store.CertStore
	witness    *witness.Client
	configured bool
}

// redactDSN strips the user:pass from a libpq URL so the startup log
// surfaces enough connection metadata for operators without leaking
// the read-only password into pod logs.
func redactDSN(s string) string {
	if at := indexLast(s, '@'); at > 0 {
		if scheme := indexAny(s, "://"); scheme > 0 {
			return s[:scheme+3] + "<redacted>" + s[at:]
		}
		return "<redacted>" + s[at:]
	}
	return s
}

func indexLast(s string, c byte) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == c {
			return i
		}
	}
	return -1
}

func indexAny(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
