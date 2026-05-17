// Package views renders the dashboard's HTML surfaces from embedded
// templates. Slice 1 ships the layout + login + dashboard-home + sidebar +
// topbar + status-dot components. Later slices add cert / health / audit /
// compliance / keys views without changing this loader.
package views

import (
	"embed"
	"fmt"
	"html/template"
	"io"
	"io/fs"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
)

//go:embed templates/*.html.tmpl templates/components/*.html.tmpl templates/certs/*.html.tmpl templates/health/*.html.tmpl
var templateFS embed.FS

// FuncMap exposes helper functions to all templates.
func FuncMap() template.FuncMap {
	return template.FuncMap{
		"hasRole": func(u auth.User, role string) bool {
			return string(u.Role) == role
		},
		// dict assembles an ad-hoc map for sub-template arguments. Keys must
		// be strings; usage: {{ template "statusdot" dict "Status" "ok" "Label" "Live" }}.
		"dict": func(values ...any) (map[string]any, error) {
			if len(values)%2 != 0 {
				return nil, fmt.Errorf("dict requires an even number of arguments, got %d", len(values))
			}
			m := make(map[string]any, len(values)/2)
			for i := 0; i < len(values); i += 2 {
				key, ok := values[i].(string)
				if !ok {
					return nil, fmt.Errorf("dict key at position %d is not a string", i)
				}
				m[key] = values[i+1]
			}
			return m, nil
		},
		// min returns the smaller of two ints. Used by signature_pill to
		// clip the visible signature prefix to ≤16 hex chars without
		// over-running short fingerprints in test fixtures.
		"min": func(a, b int) int {
			if a < b {
				return a
			}
			return b
		},
		// sub subtracts b from a. Used by the pagination renderer to
		// compute "page-1" without escaping into JS.
		"sub": func(a, b int) int { return a - b },
		// add adds b to a. Used by pagination.
		"add": func(a, b int) int { return a + b },
		// formatDate renders a time.Time in a tabular-friendly format.
		// We render in UTC ISO-8601-without-seconds so the audit
		// surface stays jurisdiction-neutral (no local TZ tells).
		"formatDate": func(t time.Time) string {
			if t.IsZero() {
				return ""
			}
			return t.UTC().Format("2006-01-02 15:04 UTC")
		},
	}
}

// Renderer holds the parsed template set.
type Renderer struct {
	templates map[string]*template.Template
}

// New parses every page template. Each page template is parsed alongside the
// layout + all components so {{ template "..." }} resolves at runtime.
//
// Slice 3 adds cert pages under templates/certs/. The shared
// claim_chain partial lives under templates/components/ so it joins
// every page's component set automatically.
func New() (*Renderer, error) {
	componentTemplates, err := componentTemplateNames()
	if err != nil {
		return nil, err
	}
	pages := []pageDef{
		{name: "login.html.tmpl", path: "templates/login.html.tmpl"},
		{name: "dashboard_home.html.tmpl", path: "templates/dashboard_home.html.tmpl"},
		{name: "certs/browser.html.tmpl", path: "templates/certs/browser.html.tmpl"},
		{name: "certs/inspector.html.tmpl", path: "templates/certs/inspector.html.tmpl"},
		{name: "certs/validator.html.tmpl", path: "templates/certs/validator.html.tmpl"},
		{name: "certs/progress.html.tmpl", path: "templates/certs/progress.html.tmpl"},
		{name: "certs/notconfigured.html.tmpl", path: "templates/certs/notconfigured.html.tmpl"},
		// Slice 4 adds the health/overview surface; the drawer + grafana_panel
		// partials are picked up via componentTemplates (templates/components/)
		// + the explicit template files listed here when present in
		// templates/health/.
		{name: "health/overview.html.tmpl", path: "templates/health/overview.html.tmpl"},
	}
	// Slice 4: health pages reference a sibling partial (drawer.html.tmpl)
	// alongside the overview page. Collect them once + thread into every
	// page's parse list so the partial's `{{ define "health-drawer" }}`
	// block is available regardless of which page is being rendered.
	healthPartials, err := healthPartialTemplateNames()
	if err != nil {
		return nil, err
	}
	r := &Renderer{templates: make(map[string]*template.Template)}
	for _, page := range pages {
		t := template.New(page.name).Funcs(FuncMap())
		files := []string{
			"templates/layout.html.tmpl",
			page.path,
		}
		files = append(files, componentTemplates...)
		files = append(files, healthPartials...)
		if _, err := t.ParseFS(templateFS, files...); err != nil {
			return nil, fmt.Errorf("parse %s: %w", page.name, err)
		}
		r.templates[page.name] = t
	}
	return r, nil
}

// healthPartialTemplateNames returns every file under templates/health/
// EXCEPT the named page templates (overview.html.tmpl). The drawer +
// any future health sub-partials are picked up via this helper so the
// pages list above doesn't have to enumerate them.
func healthPartialTemplateNames() ([]string, error) {
	entries, err := fs.ReadDir(templateFS, "templates/health")
	if err != nil {
		return nil, err
	}
	skip := map[string]struct{}{
		"overview.html.tmpl": {},
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if _, ok := skip[e.Name()]; ok {
			continue
		}
		names = append(names, "templates/health/"+e.Name())
	}
	return names, nil
}

// pageDef is one named template the renderer parses at startup. Slice 3
// added the certs/ subdirectory; this struct keeps the lookup name +
// the disk path separate so the cert pages live under a folder.
type pageDef struct {
	name string
	path string
}

// Render writes the named page template using "layout" as the entrypoint.
func (r *Renderer) Render(w io.Writer, name string, data any) error {
	t, ok := r.templates[name]
	if !ok {
		return fmt.Errorf("unknown template: %s", name)
	}
	return t.ExecuteTemplate(w, "layout", data)
}

// RenderString is a test helper.
func (r *Renderer) RenderString(name string, data any) (string, error) {
	var b stringWriter
	if err := r.Render(&b, name, data); err != nil {
		return "", err
	}
	return b.String(), nil
}

type stringWriter struct {
	buf []byte
}

func (w *stringWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	return len(p), nil
}

func (w *stringWriter) String() string {
	return string(w.buf)
}

func componentTemplateNames() ([]string, error) {
	entries, err := fs.ReadDir(templateFS, "templates/components")
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		names = append(names, "templates/components/"+e.Name())
	}
	return names, nil
}

// PageData is the common base struct templates receive.
//
// ActivePage tells the sidebar component which nav item should render as
// active (visual `is-active` class + `aria-current="page"`). Handlers MUST
// set it to the matching slug for the page they are about to render
// (currently only "home"; later slices add "certs", "health", "audit",
// "compliance", "keys"). An empty value leaves the sidebar with no
// active item — appropriate for the login surface.
//
// OIDCEnabled tells the login template whether to render the "Sign in
// with SSO" block + the divider. The local form ALWAYS renders — even
// with OIDC turned on, operators retain the local fallback for bootstrap
// + IdP-outage cases. Slice 2 explicitly does NOT add a way to disable
// local login; that decision is deferred to a future slice if customer
// signals demand it.
type PageData struct {
	Title       string
	User        auth.User
	CSRFToken   string
	Flash       string
	NextPath    string
	ActivePage  string
	OIDCEnabled bool
}
