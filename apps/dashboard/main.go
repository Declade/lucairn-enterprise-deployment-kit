// Lucairn Enterprise Dashboard.
//
// Self-hosted, single Go binary. Ships inside the
// lucairn-enterprise-deployment-kit. Customer's cluster operates this; no
// telemetry or operational state crosses the customer-vendor boundary.
//
// Slice 1 shipped: auth + shell foundation.
// Slice 2 adds: OIDC SSO (opt-in; default OFF).
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
	"syscall"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/config"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/server"
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

	staticFS, err := fs.Sub(embeddedStatic, "static")
	if err != nil {
		log.Fatalf("static fs: %v", err)
	}
	server.SetEmbeddedStatic(staticFS)

	srv, err := server.New(server.Options{
		ListenAddr:        cfg.ListenAddr,
		Version:           version,
		Authenticator:     authenticator,
		Sessions:          sessions,
		OIDCAuthenticator: oidcAuth,
		OIDCState:         oidcState,
		OIDCEnabled:       cfg.OIDCEnabled,
	})
	if err != nil {
		log.Fatalf("server: %v", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	log.Printf("lucairn-dashboard %s listening on %s", version, cfg.ListenAddr)
	if err := srv.Run(ctx); err != nil {
		log.Fatalf("server stopped: %v", err)
	}
	log.Printf("lucairn-dashboard shutdown complete")
}
