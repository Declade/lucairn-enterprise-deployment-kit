package demodata

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/gateway"
)

// DemoAdminClient implements handlers.AdminClient. Holds 3 fictional
// customers + a mutable per-customer key set. Mint / Revoke mutate the
// in-memory map so the demo /keys surface responds to operator actions.
type DemoAdminClient struct {
	mu        sync.Mutex
	customers []gateway.CustomerEntry
	keys      map[string][]gateway.KeyEntry // customer_id → keys
}

// NewAdminClient seeds 3 customers + a handful of keys each.
func NewAdminClient() *DemoAdminClient {
	now := SeedTime()
	customers := []gateway.CustomerEntry{
		{
			APIKeyPrefix: "lcr_live_acme",
			CustomerID:   "cust_acme_corp_demo",
			Tier:         "enterprise",
			Vertical:     "finance",
			ManagedAI:    false,
		},
		{
			APIKeyPrefix: "lcr_live_bgmbh",
			CustomerID:   "cust_beispiel_gmbh",
			Tier:         "pro",
			Vertical:     "healthcare",
			ManagedAI:    true,
		},
		{
			APIKeyPrefix: "lcr_live_dev",
			CustomerID:   "cust_dev_sandbox",
			Tier:         "developer",
			Vertical:     "general",
			ManagedAI:    true,
		},
	}
	keys := map[string][]gateway.KeyEntry{
		"cust_acme_corp_demo": {
			{KeyID: "k_acme_001", KeyPrefix: "lcr_live_acme_001", CreatedAt: now.Add(-30 * 24 * time.Hour), LastUsedAt: now.Add(-1 * time.Hour)},
			{KeyID: "k_acme_002", KeyPrefix: "lcr_live_acme_002", CreatedAt: now.Add(-7 * 24 * time.Hour), LastUsedAt: now.Add(-12 * time.Minute)},
		},
		"cust_beispiel_gmbh": {
			{KeyID: "k_bgmbh_001", KeyPrefix: "lcr_live_bgmbh_001", CreatedAt: now.Add(-14 * 24 * time.Hour), LastUsedAt: now.Add(-3 * time.Hour)},
		},
		"cust_dev_sandbox": {
			{KeyID: "k_dev_001", KeyPrefix: "lcr_live_dev_001", CreatedAt: now.Add(-2 * 24 * time.Hour), LastUsedAt: time.Time{}},
		},
	}
	return &DemoAdminClient{
		customers: customers,
		keys:      keys,
	}
}

// ListCustomers implements handlers.AdminClient.
func (c *DemoAdminClient) ListCustomers(ctx context.Context) ([]gateway.CustomerEntry, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]gateway.CustomerEntry, len(c.customers))
	copy(out, c.customers)
	return out, nil
}

// ListKeys implements handlers.AdminClient. reveal toggles between
// prefix-only + full raw-key reveal; demo always shows the prefix.
// (Production semantics reveal the FULL key only on initial mint; demo
// does not regenerate raw keys post-mint, so the reveal path returns
// blank RawKey values — consistent with production behaviour after a
// key has been minted and the one-shot reveal has expired.)
func (c *DemoAdminClient) ListKeys(ctx context.Context, customerID string, reveal bool) (*gateway.ListKeysResult, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cust, ok := c.findCustomer(customerID)
	if !ok {
		return nil, fmt.Errorf("demo admin: customer not found: %s", customerID)
	}
	keys := c.keys[customerID]
	out := make([]gateway.KeyEntry, len(keys))
	copy(out, keys)
	return &gateway.ListKeysResult{
		CustomerID:     customerID,
		Tier:           cust.Tier,
		ByokPerRequest: cust.ManagedAI,
		Provider:       "anthropic",
		HasProviderKey: cust.ManagedAI,
		MaxKeys:        10,
		Keys:           out,
	}, nil
}

// MintKey implements handlers.AdminClient. Appends a new key to the
// in-memory map + returns the raw key (one-shot — subsequent ListKeys
// shows prefix only). Mutates the demo state so an operator clicking
// "Mint key" sees the list grow on refresh.
func (c *DemoAdminClient) MintKey(ctx context.Context, customerID string) (*gateway.MintKeyResult, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.findCustomer(customerID); !ok {
		return nil, errors.New("demo admin: customer not found")
	}
	now := SeedTime()
	idx := len(c.keys[customerID]) + 1
	keyID := fmt.Sprintf("k_demo_%s_%03d", shortCust(customerID), idx)
	prefix := fmt.Sprintf("lcr_live_demo_%03d", idx)
	raw := fmt.Sprintf("%s_dn0tu5e1nprodemod3m0secret%02d", prefix, idx)
	c.keys[customerID] = append(c.keys[customerID], gateway.KeyEntry{
		KeyID:     keyID,
		KeyPrefix: prefix,
		CreatedAt: now,
	})
	return &gateway.MintKeyResult{
		KeyID:     keyID,
		KeyPrefix: prefix,
		RawKey:    raw,
		CreatedAt: now,
	}, nil
}

// RevokeKey implements handlers.AdminClient. Removes the key from the
// in-memory map.
func (c *DemoAdminClient) RevokeKey(ctx context.Context, customerID, keyID string) (*gateway.RevokeKeyResult, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	keys := c.keys[customerID]
	for i, k := range keys {
		if k.KeyID == keyID {
			out := &gateway.RevokeKeyResult{
				Revoked:   true,
				KeyID:     keyID,
				KeyPrefix: k.KeyPrefix,
			}
			c.keys[customerID] = append(keys[:i], keys[i+1:]...)
			return out, nil
		}
	}
	return &gateway.RevokeKeyResult{Revoked: false, KeyID: keyID}, nil
}

func (c *DemoAdminClient) findCustomer(customerID string) (gateway.CustomerEntry, bool) {
	for _, cust := range c.customers {
		if cust.CustomerID == customerID {
			return cust, true
		}
	}
	return gateway.CustomerEntry{}, false
}

func shortCust(customerID string) string {
	// "cust_acme_corp_demo" → "acme"
	if len(customerID) > 5 && customerID[:5] == "cust_" {
		rest := customerID[5:]
		for i, ch := range rest {
			if ch == '_' {
				return rest[:i]
			}
		}
		return rest
	}
	return customerID
}
