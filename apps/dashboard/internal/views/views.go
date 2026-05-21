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
	"net/url"
	"strings"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
)

//go:embed templates/*.html.tmpl templates/components/*.html.tmpl templates/certs/*.html.tmpl templates/health/*.html.tmpl templates/keys/*.html.tmpl templates/audit/*.html.tmpl
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
		// joinStrings glues a []string with ", " for redisplay inside
		// filter inputs. Empty slice → empty string (the form input
		// renders as placeholder-only).
		"joinStrings": func(values []string) string {
			return strings.Join(values, ", ")
		},
		// formatDateTimeLocal renders a *time.Time in the
		// `YYYY-MM-DDTHH:MM` shape the HTML5 `<input type=datetime-local>`
		// expects. nil or zero returns the empty string (the input
		// renders as unset).
		"formatDateTimeLocal": func(t *time.Time) string {
			if t == nil || t.IsZero() {
				return ""
			}
			return t.UTC().Format("2006-01-02T15:04")
		},
		// filterURL serialises an audit filter into a URL query string
		// fragment so the pagination + CSV-export buttons carry the
		// current filter across without JS. The template caller passes
		// `.Filter` (a FilterReader-satisfying value) as the argument.
		"filterURL": func(f FilterReader) string {
			return serializeFilter(f)
		},
		// savedFilterURL is identical to filterURL but accepts a
		// SavedFilterReader (the SavedFilter row carries its filter
		// indirectly via the .Filter field). Templates call:
		// {{ savedFilterURL . }} inside a `range .SavedFilters`.
		"savedFilterURL": func(sf SavedFilterReader) string {
			return serializeFilter(sf.SavedFilterReader())
		},
		// intList builds a []int from the supplied varargs. Slice 6
		// fix-up r1 UX-M2: the audit page-size dropdown iterates over
		// {{ range $size := (intList 50 100 200) }} to render a stable
		// allowlist without leaking int literals into the template.
		"intList": func(values ...int) []int { return values },
		// relativeAge renders a "5 min ago" / "2 hours ago" / "3 days
		// ago" string. Slice 6 fix-up r1 UX-M3: operators triaging a
		// busy audit log scan timestamps relatively. The template
		// renders the absolute timestamp as the body + relativeAge in
		// the title= attribute (or vice-versa) — both visible without
		// JS.
		"relativeAge": func(t time.Time) string {
			if t.IsZero() {
				return ""
			}
			now := time.Now().UTC()
			d := now.Sub(t.UTC())
			if d < 0 {
				// Future timestamp; happens when clocks drift. Render
				// the absolute form rather than "-5 min ago".
				return t.UTC().Format("2006-01-02 15:04 UTC")
			}
			switch {
			case d < time.Minute:
				return "just now"
			case d < time.Hour:
				return fmt.Sprintf("%d min ago", int(d/time.Minute))
			case d < 24*time.Hour:
				return fmt.Sprintf("%d hours ago", int(d/time.Hour))
			default:
				return fmt.Sprintf("%d days ago", int(d/(24*time.Hour)))
			}
		},
	}
}

// FilterReader is the read-only contract template helpers consume to
// serialise an audit filter into a URL query string. Both
// auditPageData.Filter (the in-memory filter for the current page)
// and SavedFilter.Filter (the persisted shape) implement this via
// store.AuditFilter's AuditFilterShape method.
type FilterReader interface {
	AuditFilterShape() (eventTypes, sourceServices, actors []string, requestID, payloadContains string, from, to *time.Time)
}

// SavedFilterReader is the read-only contract template helpers consume
// for SavedFilter rows; the helper extracts the embedded filter via
// SavedFilterReader() so the same serialiser handles both shapes.
type SavedFilterReader interface {
	SavedFilterReader() FilterReader
}

func serializeFilter(f FilterReader) string {
	if f == nil {
		return ""
	}
	eventTypes, sourceServices, actors, requestID, payloadContains, from, to := f.AuditFilterShape()
	v := url.Values{}
	if len(eventTypes) > 0 {
		v.Set("event_type", strings.Join(eventTypes, ","))
	}
	if len(sourceServices) > 0 {
		v.Set("source_service", strings.Join(sourceServices, ","))
	}
	if len(actors) > 0 {
		v.Set("actor", strings.Join(actors, ","))
	}
	if requestID != "" {
		v.Set("request_id", requestID)
	}
	if payloadContains != "" {
		v.Set("payload_contains", payloadContains)
	}
	if from != nil && !from.IsZero() {
		v.Set("from", from.UTC().Format(time.RFC3339))
	}
	if to != nil && !to.IsZero() {
		v.Set("to", to.UTC().Format(time.RFC3339))
	}
	return v.Encode()
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
		// Slice 5 adds the API-key management surface. The mint-modal
		// partial is collected via keysPartialTemplateNames() alongside the
		// browser page so the post-mint render (which embeds the modal)
		// can resolve `{{ template "keys-mint-modal" . }}`.
		{name: "keys/browser.html.tmpl", path: "templates/keys/browser.html.tmpl"},
		// Slice 6 adds the audit-log browser + detail surface.
		{name: "audit/browser.html.tmpl", path: "templates/audit/browser.html.tmpl"},
		{name: "audit/detail.html.tmpl", path: "templates/audit/detail.html.tmpl"},
	}
	// Slice 4: health pages reference a sibling partial (drawer.html.tmpl)
	// alongside the overview page. Collect them once + thread into every
	// page's parse list so the partial's `{{ define "health-drawer" }}`
	// block is available regardless of which page is being rendered.
	healthPartials, err := healthPartialTemplateNames()
	if err != nil {
		return nil, err
	}
	// Slice 5: same pattern as health — collect every non-page partial
	// under templates/keys/ so the browser page can resolve
	// `{{ template "keys-mint-modal" . }}` without enumerating the
	// partial in the pages list.
	keysPartials, err := keysPartialTemplateNames()
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
		files = append(files, keysPartials...)
		if _, err := t.ParseFS(templateFS, files...); err != nil {
			return nil, fmt.Errorf("parse %s: %w", page.name, err)
		}
		r.templates[page.name] = t
	}
	return r, nil
}

// keysPartialTemplateNames returns every file under templates/keys/
// EXCEPT the named page templates (browser.html.tmpl). Mirrors
// healthPartialTemplateNames so the mint-modal partial joins every
// page's parse set without per-page enumeration.
func keysPartialTemplateNames() ([]string, error) {
	entries, err := fs.ReadDir(templateFS, "templates/keys")
	if err != nil {
		return nil, err
	}
	skip := map[string]struct{}{
		"browser.html.tmpl": {},
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if _, ok := skip[e.Name()]; ok {
			continue
		}
		names = append(names, "templates/keys/"+e.Name())
	}
	return names, nil
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
