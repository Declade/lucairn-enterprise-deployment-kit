// Package imagemanifest loads image-manifest.yaml at startup so the
// compliance PDF cover page can render the pinned image set the kit
// shipped with. The manifest sits at the kit root; the dashboard binary
// can't reach the filesystem at runtime (PSS read-only root + the kit
// directory isn't mounted into the pod), so the YAML is embedded at
// build time via go:embed.
//
// The embedded path is `image-manifest.yaml` at the apps/dashboard
// source root. The Makefile's image-build target copies the kit's
// canonical image-manifest.yaml into apps/dashboard/ as part of the
// pre-build step so the binary's view always reflects the kit release.
// When the manifest isn't present (e.g. local dev `go test` not run via
// the Makefile) the loader returns an empty map and the PDF cover
// falls back to "Image manifest unavailable" copy.
//
// Future ext: digests (sha256@...) once the kit's release flow pins
// images by digest, not tag. The loader's struct shape already
// tolerates a future "image_digest:" field per service.
package imagemanifest

import (
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"
)

// manifestShape mirrors the slice of image-manifest.yaml the dashboard
// reads. Other fields (sanitizer_config_path, sanitizer_config_compat,
// etc.) are ignored — the dashboard only renders tags + digests.
type manifestShape struct {
	KitVersion              string                    `yaml:"kit_version"`
	DefaultLucairnImageTag  string                    `yaml:"default_lucairn_image_tag"`
	DefaultLucairnRegistry  string                    `yaml:"default_lucairn_image_registry"`
	Services                map[string]serviceEntry   `yaml:"services"`
	OptionalServices        map[string]serviceEntry   `yaml:"optional_services"`
}

type serviceEntry struct {
	ImageTag    string `yaml:"image_tag"`
	ImageDigest string `yaml:"image_digest"` // reserved for future digest-pinning
}

// Resolved is the dashboard's projection of the manifest.
//
// KitVersion mirrors manifestShape.KitVersion (the cover page renders
// this verbatim).
//
// Digests maps "service-name" → "tag" (or "tag@sha256:..." when the
// kit eventually pins by digest). The map is the populated subset
// of services + optional_services with non-empty image_tag,
// falling back to default_lucairn_image_tag when a service's
// image_tag is empty (matches the doctor's resolution semantics).
type Resolved struct {
	KitVersion string
	Digests    map[string]string
}

// Parse parses a raw image-manifest.yaml byte slice and returns the
// dashboard's projection. An empty or unparseable input returns an
// empty Resolved (Digests = empty map) plus the parse error if any.
// The caller should log the error + use the empty Resolved so the
// PDF cover renders the "Image manifest unavailable" fallback instead
// of crashing the binary.
func Parse(raw []byte) (Resolved, error) {
	if len(raw) == 0 {
		return Resolved{Digests: map[string]string{}}, fmt.Errorf("imagemanifest: empty input")
	}
	var m manifestShape
	if err := yaml.Unmarshal(raw, &m); err != nil {
		return Resolved{Digests: map[string]string{}}, fmt.Errorf("imagemanifest: parse: %w", err)
	}

	out := Resolved{
		KitVersion: strings.TrimSpace(m.KitVersion),
		Digests:    map[string]string{},
	}

	resolveTag := func(svc serviceEntry) string {
		if strings.TrimSpace(svc.ImageDigest) != "" {
			return fmt.Sprintf("%s@%s", svc.ImageTag, svc.ImageDigest)
		}
		if strings.TrimSpace(svc.ImageTag) != "" {
			return svc.ImageTag
		}
		return m.DefaultLucairnImageTag
	}

	for name, svc := range m.Services {
		out.Digests[name] = resolveTag(svc)
	}
	for name, svc := range m.OptionalServices {
		// Optional services only land in the cover map when they have
		// an explicit tag — otherwise they're not part of the install.
		if strings.TrimSpace(svc.ImageTag) != "" || strings.TrimSpace(svc.ImageDigest) != "" {
			out.Digests[name] = resolveTag(svc)
		}
	}
	return out, nil
}
