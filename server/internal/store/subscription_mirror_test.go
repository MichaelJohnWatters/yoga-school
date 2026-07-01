package store

import (
	"context"
	"testing"
)

// A recurring product with no mirrored Stripe Price can't be checked out by a
// student — minting the Price is a manager action, never a side effect of a
// purchase. Checkout refuses (ErrMembershipNotReady) and creates nothing.
func TestSubscriptionCheckout_RefusesWhenPriceMissing(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)

	// Recurring product with NO stripe ids.
	productID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO products
		  (id, studio_id, name, price_minor, billing_type, billing_interval, pass_kind, validity_days)
		  VALUES (?, ?, 'Unlimited Monthly', 8800, 'recurring', 'month', 'unlimited', 30)`,
		productID, f.studioID); err != nil {
		t.Fatalf("seed product: %v", err)
	}

	if _, err := s.CreateCheckoutSubscription(ctx, f.studioID, f.studentID, productID,
		"https://app/ok", "https://app/no"); err != ErrMembershipNotReady {
		t.Fatalf("checkout err = %v, want ErrMembershipNotReady", err)
	}

	// No Price was minted as a side effect of the student's attempt.
	if g.lastPrice.ProductName != "" {
		t.Error("student checkout must not create a Stripe Price")
	}
	var priceID *string
	s.db.QueryRowContext(ctx,
		`SELECT stripe_price_id FROM products WHERE id = ?`, productID).Scan(&priceID)
	if priceID != nil && *priceID != "" {
		t.Errorf("product should still have no Price, got %q", *priceID)
	}
}
