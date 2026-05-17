// Lucairn Enterprise Dashboard — Slice 1 (auth + shell foundation).
//
// Self-hosted, single Go binary. Ships inside the
// lucairn-enterprise-deployment-kit. Customer's cluster operates this; no
// telemetry or operational state crosses the customer-vendor boundary.
//
// Design: specs/prd-2026-05-17-enterprise-dashboard.md (internal Lucairn
// planning repo).
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

	staticFS, err := fs.Sub(embeddedStatic, "static")
	if err != nil {
		log.Fatalf("static fs: %v", err)
	}
	server.SetEmbeddedStatic(staticFS)

	srv, err := server.New(server.Options{
		ListenAddr:    cfg.ListenAddr,
		Version:       version,
		Authenticator: authenticator,
		Sessions:      sessions,
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
