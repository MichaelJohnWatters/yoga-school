package store

import (
	"context"
	"testing"
)

// A stub (manual / comp / seeded) membership can be cancelled, resumed, and
// refunded entirely locally — no gateway is set, so any real Stripe call would
// nil-panic. Proves the sub_stub_ / pi_stub_ bypass.
func TestStubSubscription_ManagedWithoutStripe(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t) // deliberately NO SetPaymentGateway
	f := newFixture(t, s)
	productID := seedRecurringProduct(t, s, f)
	entID := f.insertEntitlement(t, s, "unlimited", 0)
	subID := NewID()
	mustExec(t, s, `
		INSERT INTO subscriptions
		  (id, studio_id, user_id, product_id, stripe_customer_id, stripe_subscription_id,
		   status, cancel_at_period_end, current_period_end, last_payment_intent_id,
		   entitlement_id, currency, amount_minor)
		VALUES (?, ?, ?, ?, 'cus_stub', 'sub_stub_test', 'active', 0,
		        strftime('%Y-%m-%dT%H:%M:%fZ','now','+30 days'), 'pi_stub_test', ?, 'GBP', 8800)`,
		subID, f.studioID, f.studentID, productID, entID)

	cancelFlag := func() int {
		var n int
		s.db.QueryRowContext(ctx,
			`SELECT cancel_at_period_end FROM subscriptions WHERE id=?`, subID).Scan(&n)
		return n
	}

	// Cancel at renewal — no Stripe, just flips the flag.
	if err := s.AdminCancelSubscription(ctx, f.studioID, f.instructorID, subID, false); err != nil {
		t.Fatalf("cancel at renewal: %v", err)
	}
	if cancelFlag() != 1 {
		t.Error("cancel_at_period_end should be 1 after cancel-at-renewal")
	}

	// Resume — clears it.
	if err := s.AdminResumeSubscription(ctx, f.studioID, f.instructorID, subID); err != nil {
		t.Fatalf("resume: %v", err)
	}
	if cancelFlag() != 0 {
		t.Error("cancel_at_period_end should be 0 after resume")
	}

	// Refund & cancel — local cancel + expire, refund no-ops (pi_stub_).
	if err := s.AdminRefundMembership(ctx, f.studioID, f.instructorID, subID); err != nil {
		t.Fatalf("refund: %v", err)
	}
	var subStat string
	s.db.QueryRowContext(ctx, `SELECT status FROM subscriptions WHERE id=?`, subID).Scan(&subStat)
	if subStat != "canceled" {
		t.Errorf("subscription status = %q, want canceled", subStat)
	}
	if st := entitlementStatus(t, s, entID); st != "expired" {
		t.Errorf("entitlement status = %q, want expired", st)
	}
	if n := auditCount(t, s, f.studioID, "subscription_refund"); n != 1 {
		t.Errorf("subscription_refund audit = %d, want 1", n)
	}
}
