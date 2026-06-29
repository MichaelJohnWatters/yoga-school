package store

import (
	"context"
	"testing"
)

// A student can't sign up for the same membership twice: a live (active/past_due)
// subscription blocks a second checkout, but a pending row (abandoned checkout)
// and other students are unaffected.
func TestSubscriptionCheckout_BlocksDuplicate(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedRecurringProduct(t, s, f)

	// Existing active subscription to this product → second checkout refused.
	mustExec(t, s, `
		INSERT INTO subscriptions
		  (id, studio_id, user_id, product_id, stripe_customer_id, status, currency, amount_minor)
		VALUES (?, ?, ?, ?, 'cus_x', 'active', 'GBP', 8800)`,
		NewID(), f.studioID, f.studentID, productID)

	if _, err := s.CreateCheckoutSubscription(
		ctx, f.studioID, f.studentID, productID, "a", "b"); err != ErrAlreadySubscribed {
		t.Fatalf("duplicate checkout err = %v, want ErrAlreadySubscribed", err)
	}

	// A different student is unaffected.
	other := insertOtherStudent(t, s, f.studioID)
	if _, err := s.CreateCheckoutSubscription(
		ctx, f.studioID, other, productID, "a", "b"); err != nil {
		t.Fatalf("other student should be allowed: %v", err)
	}

	// A student whose only row is pending (abandoned checkout) can retry.
	third := insertOtherStudent(t, s, f.studioID)
	mustExec(t, s, `
		INSERT INTO subscriptions
		  (id, studio_id, user_id, product_id, stripe_customer_id, status, currency, amount_minor)
		VALUES (?, ?, ?, ?, 'cus_y', 'pending', 'GBP', 8800)`,
		NewID(), f.studioID, third, productID)
	if _, err := s.CreateCheckoutSubscription(
		ctx, f.studioID, third, productID, "a", "b"); err != nil {
		t.Fatalf("pending row should not block retry: %v", err)
	}
}
