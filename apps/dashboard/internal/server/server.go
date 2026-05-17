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
type Options struct {
	ListenAddr    string
	Version       string
	Authenticator auth.Authenticator
	Sessions      auth.SessionStore
	StaticFS      fs.FS // optional override for tests
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
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthzHandler(opts.Version))
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
