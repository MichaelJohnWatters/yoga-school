package store

import (
	"context"
	"testing"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// A delayed-settlement web payment fulfils on checkout.session.async_payment_succeeded.
func TestAsyncPaymentSucceeded_Fulfils(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	out, _ := s.CreateCheckoutPurchase(ctx, f.studioID, f.studentID, productID, "",
		"https://app.test/ok", "https://app.test/no", "")
	var sessionID string
	s.db.QueryRowContext(ctx,
		`SELECT stripe_payment_id FROM purchases WHERE id = ?`, out.PurchaseID).Scan(&sessionID)

	g.verifyFn = func([]byte, string, string) (payments.Event, error) {
		return payments.Event{
			ID: "evt_async", Type: "checkout.session.async_payment_succeeded",
			SessionID: sessionID, IntentID: "pi_async_1", Status: "paid",
		}, nil
	}
	if err := s.HandleStripeEvent(ctx, f.studioID, []byte("{}"), "sig"); err != nil {
		t.Fatalf("webhook: %v", err)
	}
	assertPurchaseStatus(t, s, out.PurchaseID, "completed")
}

// The janitor sweep resolves stale pending web checkouts: paid → fulfil,
// unpaid (past session lifetime) → void.
func TestReconcileStalePendingCheckouts(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	// Two stale pending checkouts, backdated past the 25h window.
	paid, _ := s.CreateCheckoutPurchase(ctx, f.studioID, f.studentID, productID, "",
		"a", "b", "")
	abandoned, _ := s.CreateCheckoutPurchase(ctx, f.studioID, f.studentID, productID, "",
		"a", "b", "")
	old := time.Now().UTC().Add(-30 * time.Hour).Format(time.RFC3339)
	mustExec(t, s, `UPDATE purchases SET created_at = ? WHERE id IN (?, ?)`,
		old, paid.PurchaseID, abandoned.PurchaseID)

	var paidSession string
	s.db.QueryRowContext(ctx,
		`SELECT stripe_payment_id FROM purchases WHERE id = ?`, paid.PurchaseID).Scan(&paidSession)

	g.checkoutSessionFn = func(sid string) (payments.CheckoutSessionStatus, error) {
		if sid == paidSession {
			return payments.CheckoutSessionStatus{PaymentStatus: "paid", IntentID: "pi_" + sid}, nil
		}
		return payments.CheckoutSessionStatus{PaymentStatus: "unpaid"}, nil
	}

	confirmed, voided, err := s.ReconcileStalePendingCheckouts(ctx, 25*time.Hour)
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if confirmed != 1 || voided != 1 {
		t.Errorf("confirmed=%d voided=%d, want 1/1", confirmed, voided)
	}
	assertPurchaseStatus(t, s, paid.PurchaseID, "completed")
	assertPurchaseStatus(t, s, abandoned.PurchaseID, "voided")
}
