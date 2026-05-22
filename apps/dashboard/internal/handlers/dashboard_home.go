// Package-level (handlers) addition for the enterprise dashboard
// home page. The handler lives on Deps (next to LoginGet/LogoutPost)
// but its render payload + MetricsProvider plumbing is here so the
// monolithic handlers.go stays focused on the auth chain.
package handlers

import (
	"context"
	"log"
	"net/http"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/dashboard"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
)

// DemoToggleCookieName is the cookie key the dashboard home page reads
// + writes when the operator flips the in-page demo-data toggle.
// Per-user, session-scoped; survives refresh + navigation within the
// dashboard but doesn't bleed across users (each browser has its own
// jar).
const DemoToggleCookieName = "lucairn_dash_demo_view"

// MetricsProvider is the data source the dashboard-home page reads
// to populate KPI tiles + charts + recent-activity table. Two impls
// at boot time:
//   - liveProvider: wraps the production stores (returns ZeroMetrics
//     when no DB / no gateway / no audit log is wired)
//   - demoProvider: backed by internal/demodata/ fixtures (always
//     returns a non-empty Metrics)
//
// The handler picks per-request based on the DemoToggleCookieName
// cookie. main.go wires both at boot when demo-toggle is enabled;
// the live provider alone when the toggle is disabled.
type MetricsProvider interface {
	Compute(ctx context.Context) dashboard.Metrics
}

// DashboardHomePageData is an alias for views.DashboardHomePageData
// — kept as a type alias so existing callers in this package still
// reference it without a dotted path. The canonical type lives in
// views (next to the template loader + FuncMap) so views_test.go can
// construct a renderable payload without importing handlers (which
// would create a circular import).
type DashboardHomePageData = views.DashboardHomePageData

// DashboardHome renders the enterprise overview. Always renders
// (never errors) — when no stores are wired and demo mode is off,
// the template degrades each tile to a dashed placeholder.
func (d *Deps) DashboardHome(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("dashboard_home: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	demoMode := false
	if d.DemoToggleEnabled {
		if c, err := r.Cookie(DemoToggleCookieName); err == nil && c.Value == "true" {
			demoMode = true
		}
	}

	var m dashboard.Metrics
	switch {
	case demoMode && d.DemoMetrics != nil:
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		m = d.DemoMetrics.Compute(ctx)
		cancel()
	case d.LiveMetrics != nil:
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		m = d.LiveMetrics.Compute(ctx)
		cancel()
	default:
		m = dashboard.ZeroMetrics()
	}

	data := views.DashboardHomePageData{
		PageData: views.PageData{
			Title:      "Home",
			User:       user,
			CSRFToken:  tok,
			ActivePage: "home",
		},
		Metrics:      m,
		DemoMode:     demoMode,
		DemoToggleOK: d.DemoToggleEnabled,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, "dashboard_home.html.tmpl", data); err != nil {
		log.Printf("dashboard_home: render: %v", err)
	}
}

// ToggleDemoMode flips the DemoToggleCookieName cookie's value
// between "true" and "false" and redirects back to /dashboard. POST
// only — GET would let a malicious page CSRF the user via image link.
// CSRF token already validated by the auth-chain middleware.
func (d *Deps) ToggleDemoMode(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if _, ok := auth.CurrentUser(r); !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if !d.DemoToggleEnabled {
		http.Error(w, "demo toggle disabled on this install", http.StatusForbidden)
		return
	}

	currently := false
	if c, err := r.Cookie(DemoToggleCookieName); err == nil && c.Value == "true" {
		currently = true
	}
	target := "true"
	if currently {
		target = "false"
	}
	http.SetCookie(w, &http.Cookie{
		Name:     DemoToggleCookieName,
		Value:    target,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   86400 * 30, // 30 days; per-user view preference
	})
	http.Redirect(w, r, "/dashboard", http.StatusSeeOther)
}
