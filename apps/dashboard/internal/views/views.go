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

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
)

//go:embed templates/*.html.tmpl templates/components/*.html.tmpl
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
	}
}

// Renderer holds the parsed template set.
type Renderer struct {
	templates map[string]*template.Template
}

// New parses every page template. Each page template is parsed alongside the
// layout + all components so {{ template "..." }} resolves at runtime.
func New() (*Renderer, error) {
	componentTemplates, err := componentTemplateNames()
	if err != nil {
		return nil, err
	}
	pages := []string{
		"login.html.tmpl",
		"dashboard_home.html.tmpl",
	}
	r := &Renderer{templates: make(map[string]*template.Template)}
	for _, page := range pages {
		t := template.New(page).Funcs(FuncMap())
		files := []string{
			"templates/layout.html.tmpl",
			"templates/" + page,
		}
		files = append(files, componentTemplates...)
		if _, err := t.ParseFS(templateFS, files...); err != nil {
			return nil, fmt.Errorf("parse %s: %w", page, err)
		}
		r.templates[page] = t
	}
	return r, nil
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
type PageData struct {
	Title     string
	User      auth.User
	CSRFToken string
	Flash     string
	NextPath  string
}
