package store

import (
	"context"
	"testing"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// helper: a completed card purchase (PaymentSheet path), returns purchaseID +
// entitlementID + the real PI id.
func completedCardPurchase(t *testing.T, ctx context.Context, s *Store, f fixture, g *fakeGateway, productID string) (string, string, string) {
	t.Helper()
	pending, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "", "")
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	g.intents[pending.StripePaymentID] = payments.StatusSucceeded
	entID, err := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID)
	if err != nil {
		t.Fatalf("confirm: %v", err)
	}
	return pending.PurchaseID, entID, pending.StripePaymentID
}

func TestRefundPurchase_IssuesStripeRefundForCard(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)
	purchaseID, entID, intentID := completedCardPurchase(t, ctx, s, f, g, productID)

	// Partial refund of £20 of the £50 pack.
	if err := s.RefundPurchase(ctx, f.studioID, f.studentID, purchaseID, 2000, "goodwill"); err != nil {
		t.Fatalf("RefundPurchase: %v", err)
	}
	if g.lastRefund.intentID != intentID || g.lastRefund.amountMinor != 2000 {
		t.Fatalf("stripe refund = (%s, %d), want (%s, 2000)", g.lastRefund.intentID, g.lastRefund.amountMinor, intentID)
	}
	// Money recorded, status still completed (partial), pass untouched.
	var refund int
	var status string
	s.db.QueryRowContext(ctx, `SELECT refund_amount_minor, status FROM purchases WHERE id = ?`, purchaseID).
		Scan(&refund, &status)
	if refund != 2000 || status != "completed" {
		t.Fatalf("money: refund=%d status=%q, want 2000/completed", refund, status)
	}
	assertEntitlementStatus(t, s, entID, "active")
}

func TestRefundPurchase_SkipsStripeForCash(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)
	// Synchronous cash purchase (no Stripe intent).
	purchaseID, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "cash", "")
	if err != nil {
		t.Fatalf("cash purchase: %v", err)
	}
	if err := s.RefundPurchase(ctx, f.studioID, f.studentID, purchaseID, 5000, "cash back"); err != nil {
		t.Fatalf("refund cash: %v", err)
	}
	if g.lastRefund.intentID != "" {
		t.Fatalf("cash refund should not call Stripe, got intent %q", g.lastRefund.intentID)
	}
	assertPurchaseStatus(t, s, purchaseID, "refunded")
}

func TestVoidEntitlement_ProratedStripeRefund(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f) // £50, 10 credits
	purchaseID, entID, intentID := completedCardPurchase(t, ctx, s, f, g, productID)

	// Student has spent 4 of 10 classes → 6 unused.
	s.db.ExecContext(ctx, `UPDATE entitlements SET credits_remaining = 6 WHERE id = ?`, entID)

	res, err := s.VoidEntitlement(ctx, f.studioID, f.studentID, entID,
		VoidInput{Refund: "unused", Reason: "moving away"})
	if err != nil {
		t.Fatalf("VoidEntitlement: %v", err)
	}
	// 5000 × 6/10 = 3000 refunded, via Stripe against the PI.
	if res.RefundedMinor != 3000 {
		t.Fatalf("refunded = %d, want 3000", res.RefundedMinor)
	}
	if g.lastRefund.intentID != intentID || g.lastRefund.amountMinor != 3000 {
		t.Fatalf("stripe refund = (%s, %d), want (%s, 3000)", g.lastRefund.intentID, g.lastRefund.amountMinor, intentID)
	}
	// Pass is voided and the money side recorded.
	assertEntitlementStatus(t, s, entID, "voided")
	var refund int
	s.db.QueryRowContext(ctx, `SELECT refund_amount_minor FROM purchases WHERE id = ?`, purchaseID).Scan(&refund)
	if refund != 3000 {
		t.Fatalf("purchase refund_amount_minor = %d, want 3000", refund)
	}
}
