package imagemanifest

import (
	"testing"
)

func TestParse_EmptyInputReturnsError(t *testing.T) {
	r, err := Parse(nil)
	if err == nil {
		t.Error("Parse(nil) = nil err, want non-nil")
	}
	if r.Digests == nil {
		t.Error("Resolved.Digests should be non-nil (empty map) on error")
	}
}

func TestParse_MalformedReturnsError(t *testing.T) {
	r, err := Parse([]byte("kit_version: [broken"))
	if err == nil {
		t.Error("Parse(malformed) = nil err, want non-nil")
	}
	if r.Digests == nil {
		t.Error("Resolved.Digests should be non-nil empty map on parse error")
	}
}

func TestParse_HappyPath(t *testing.T) {
	yaml := `kit_version: "1.3.0-customer-demo-data"
default_lucairn_image_tag: "0.4.0"
default_lucairn_image_registry: "ghcr.io/declade"
services:
  dsa-gateway:
    image_tag: ""
  dsa-sanitizer:
    image_tag: ""
  dsa-veil-witness:
    image_tag: "0.4.1"
optional_services:
  lucairn-dashboard:
    image_tag: "0.7.0"
  dsa-cert-portal:
    image_tag: ""
`
	r, err := Parse([]byte(yaml))
	if err != nil {
		t.Fatalf("Parse = %v", err)
	}
	if r.KitVersion != "1.3.0-customer-demo-data" {
		t.Errorf("KitVersion = %q", r.KitVersion)
	}
	// dsa-gateway + dsa-sanitizer inherit default tag 0.4.0
	if r.Digests["dsa-gateway"] != "0.4.0" {
		t.Errorf("dsa-gateway = %q, want 0.4.0", r.Digests["dsa-gateway"])
	}
	if r.Digests["dsa-sanitizer"] != "0.4.0" {
		t.Errorf("dsa-sanitizer = %q, want 0.4.0", r.Digests["dsa-sanitizer"])
	}
	// dsa-veil-witness pinned override
	if r.Digests["dsa-veil-witness"] != "0.4.1" {
		t.Errorf("dsa-veil-witness = %q, want 0.4.1", r.Digests["dsa-veil-witness"])
	}
	// lucairn-dashboard pinned in optional_services
	if r.Digests["lucairn-dashboard"] != "0.7.0" {
		t.Errorf("lucairn-dashboard = %q, want 0.7.0", r.Digests["lucairn-dashboard"])
	}
	// dsa-cert-portal optional with empty tag → NOT in digests map
	if _, ok := r.Digests["dsa-cert-portal"]; ok {
		t.Errorf("dsa-cert-portal should NOT be in digests (empty tag opt-in)")
	}
}

func TestParse_DigestPinnedFormat(t *testing.T) {
	yaml := `kit_version: "1.4.0"
default_lucairn_image_tag: "0.4.0"
services:
  dsa-gateway:
    image_tag: "0.5.0"
    image_digest: "sha256:abcdef1234567890"
`
	r, err := Parse([]byte(yaml))
	if err != nil {
		t.Fatalf("Parse = %v", err)
	}
	if r.Digests["dsa-gateway"] != "0.5.0@sha256:abcdef1234567890" {
		t.Errorf("dsa-gateway = %q, want 0.5.0@sha256:abcdef1234567890", r.Digests["dsa-gateway"])
	}
}
