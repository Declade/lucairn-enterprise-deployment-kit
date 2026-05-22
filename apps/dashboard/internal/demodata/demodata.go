// Package demodata provides in-memory fixture implementations of the
// dashboard's store + gateway-client interfaces. Wired only when
// LUCAIRN_DASHBOARD_DEMO_MODE=true is set (see main.go boot path).
//
// Goal: a single binary that, with one env var, renders the full
// dashboard surface area (certs / audit / keys / health / compliance /
// dashboard-home / login) populated with realistic synthetic data so a
// prospect / reviewer / new operator can SEE what the dashboard looks
// like without standing up the backing postgres-bridge + postgres-audit
// + gateway-admin stack.
//
// All fixtures are deterministic — `time.Now()` is the only non-deterministic
// input (so timestamps drift forward with wall clock). Cert + audit + key IDs
// are stable across boots so the demo URLs stay valid.
//
// NOT FOR PRODUCTION USE. The package's existence in the binary adds ~10
// KiB of fixture data; the demo paths are only activated when the env
// flag is set, so production installs that never set it pay zero runtime
// cost beyond the embedded fixtures.
package demodata

import (
	"fmt"
	"time"
)

// SeedTime anchors the demo data's timeline. All fixture rows are
// generated relative to this point so the displayed dates "move with
// the dashboard" rather than freezing at some build-time constant.
// Demo data spans the 30 days ending at SeedTime().
func SeedTime() time.Time {
	return time.Now().UTC()
}

// demoCustomerID is the single fictional customer all demo fixtures
// belong to. Matches the cover-page sampleInput() in
// internal/compliance/templates/cover_test.go so the compliance PDF
// surface tells a coherent story end-to-end.
const demoCustomerID = "cust_acme_corp_demo"

// formatCertID generates a stable cert-id string for fixture position i.
// Hex-y looking so it matches the production cert-id shape.
func formatCertID(i int) string {
	return fmt.Sprintf("cert_demo_%08x", i*0x9e3779b9&0xffffffff)
}

// formatRequestID does the same for request-ids — pattern matches the
// gateway-emitted form (request_id is what witness.GetCertificate looks
// up by). Demo certs link to demo audit events via this string.
func formatRequestID(i int) string {
	return fmt.Sprintf("req_demo_%08x", (i+1)*0x9e3779b9&0xffffffff)
}
