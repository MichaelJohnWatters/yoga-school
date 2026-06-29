package store

import (
	"context"
	"testing"
)

// A recurring product created before Stripe was configured (e.g. the seeded
// "Unlimited Monthly") has no stripe_price_id. Buying it must mirror the Price
// on the fly, persist it, and charge against the new id — not fail with
// ErrStripeNotConfigured.
func TestSubscriptionCheckout_LazyMirrorsMissingPrice(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)

	// Seed a recurring product with NO stripe ids (the seeded-then-configured
	// situation).
	productID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO products
		  (id, studio_id, name, price_minor, billing_type, billing_interval, pass_kind, validity_days)
		  VALUES (?, ?, 'Unlimited Monthly', 8800, 'recurring', 'month', 'unlimited', 30)`,
		productID, f.studioID); err != nil {
		t.Fatalf("seed product: %v", err)
	}

	out, err := s.CreateCheckoutSubscription(ctx, f.studioID, f.studentID, productID,
		"https://app/ok", "https://app/no")
	if err != nil {
		t.Fatalf("checkout should self-heal, got: %v", err)
	}

	// It minted a Price and charged against it.
	if g.lastSubCheckout.PriceID == "" {
		t.Fatal("checkout did not use a mirrored price id")
	}

	// And persisted it so the next purchase reuses it.
	var priceID, prodID *string
	if err := s.db.QueryRowContext(ctx,
		`SELECT stripe_price_id, stripe_product_id FROM products WHERE id = ?`,
		productID).Scan(&priceID, &prodID); err != nil {
		t.Fatalf("read product: %v", err)
	}
	if priceID == nil || *priceID == "" {
		t.Fatal("stripe_price_id was not persisted after checkout")
	}
	if *priceID != g.lastSubCheckout.PriceID {
		t.Errorf("persisted price %q != charged price %q", *priceID, g.lastSubCheckout.PriceID)
	}
	if out.SubscriptionID == "" {
		t.Error("expected a subscription id")
	}
}
