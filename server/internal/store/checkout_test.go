package store

import (
	"context"
	"errors"
	"testing"

	"github.com/studio52/yoga-school/server/internal/payments"
)

func TestCreateCheckoutPurchase_PendingWithSessionId(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	out, err := s.CreateCheckoutPurchase(ctx, f.studioID, f.studentID, productID, "",
		"https://app.test/success", "https://app.test/cancel", "")
	if err != nil {
		t.Fatalf("CreateCheckoutPurchase: %v", err)
	}
	if out.URL == "" {
		t.Fatal("expected a checkout URL")
	}
	// Server-computed amount (5000) and metadata reached the gateway.
	if g.lastCheckout.AmountMinor != 5000 {
		t.Errorf("amount = %d, want 5000", g.lastCheckout.AmountMinor)
	}
	if g.lastCheckout.SuccessURL != "https://app.test/success" {
		t.Errorf("success url not passed through: %q", g.lastCheckout.SuccessURL)
	}
	if g.lastCheckout.Metadata["purchase_id"] != out.PurchaseID {
		t.Errorf("metadata purchase_id mismatch")
	}
	// Pending purchase holds the session id (cs_…) until completion.
	var stripeID, status string
	s.db.QueryRowContext(ctx,
		`SELECT stripe_payment_id, status FROM purchases WHERE id = ?`, out.PurchaseID).
		Scan(&stripeID, &status)
	if stripeID[:3] != "cs_" || status != "pending" {
		t.Fatalf("expected pending cs_ row, got id=%q status=%q", stripeID, status)
	}
}

func TestConfirmCheckoutSessionForUser_MintsWhenPaid(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	out, _ := s.CreateCheckoutPurchase(ctx, f.studioID, f.studentID, productID, "",
		"https://app.test/success", "https://app.test/cancel", "")
	var sessionID string
	s.db.QueryRowContext(ctx,
		`SELECT stripe_payment_id FROM purchases WHERE id = ?`, out.PurchaseID).Scan(&sessionID)

	// Not paid yet → no mint, completed=false, no error.
	g.checkoutSessionFn = func(_ string) (payments.CheckoutSessionStatus, error) {
		return payments.CheckoutSessionStatus{PaymentStatus: "unpaid"}, nil
	}
	ent, done, err := s.ConfirmCheckoutSessionForUser(ctx, f.studioID, f.studentID, sessionID)
	if err != nil || done || ent != "" {
		t.Fatalf("unpaid: got ent=%q done=%v err=%v, want empty/false/nil", ent, done, err)
	}
	assertPurchaseStatus(t, s, out.PurchaseID, "pending")

	// Paid → mints + completes.
	g.checkoutSessionFn = func(sid string) (payments.CheckoutSessionStatus, error) {
		return payments.CheckoutSessionStatus{PaymentStatus: "paid", IntentID: "pi_" + sid}, nil
	}
	ent, done, err = s.ConfirmCheckoutSessionForUser(ctx, f.studioID, f.studentID, sessionID)
	if err != nil || !done || ent == "" {
		t.Fatalf("paid: got ent=%q done=%v err=%v, want id/true/nil", ent, done, err)
	}
	assertPurchaseStatus(t, s, out.PurchaseID, "completed")

	// Idempotent: a second confirm by the old session id still resolves, even
	// though the webhook swapped stripe_payment_id to the pi_ PaymentIntent —
	// we re-resolve via the session's PaymentIntent and return the same
	// entitlement, so the web success page shows instead of a "not found".
	ent2, done2, err2 := s.ConfirmCheckoutSessionForUser(ctx, f.studioID, f.studentID, sessionID)
	if err2 != nil || !done2 || ent2 != ent {
		t.Fatalf("second confirm: got ent=%q done=%v err=%v, want %q/true/nil",
			ent2, done2, err2, ent)
	}

	// Another user can't confirm someone else's session.
	other := insertOtherStudent(t, s, f.studioID)
	out2, _ := s.CreateCheckoutPurchase(ctx, f.studioID, f.studentID, productID, "",
		"https://app.test/success", "https://app.test/cancel", "")
	var sid2 string
	s.db.QueryRowContext(ctx,
		`SELECT stripe_payment_id FROM purchases WHERE id = ?`, out2.PurchaseID).Scan(&sid2)
	if _, _, err := s.ConfirmCheckoutSessionForUser(ctx, f.studioID, other, sid2); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-user confirm: want ErrNotFound, got %v", err)
	}
}

func TestCheckoutWebhook_CompletesAndSwapsToIntent(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	out, _ := s.CreateCheckoutPurchase(ctx, f.studioID, f.studentID, productID, "",
		"https://app.test/success", "https://app.test/cancel", "")
	var sessionID string
	s.db.QueryRowContext(ctx,
		`SELECT stripe_payment_id FROM purchases WHERE id = ?`, out.PurchaseID).Scan(&sessionID)

	// checkout.session.completed (paid) → mint + swap stripe_payment_id to PI.
	g.verifyFn = func(_ []byte, _, _ string) (payments.Event, error) {
		return payments.Event{
			ID:        "evt_cs_1",
			Type:      "checkout.session.completed",
			SessionID: sessionID,
			IntentID:  "pi_real_123",
			Status:    "paid",
		}, nil
	}
	if err := s.HandleStripeEvent(ctx, f.studioID, []byte("{}"), "sig"); err != nil {
		t.Fatalf("handle checkout.session.completed: %v", err)
	}
	var stripeID, status string
	s.db.QueryRowContext(ctx,
		`SELECT stripe_payment_id, status FROM purchases WHERE id = ?`, out.PurchaseID).
		Scan(&stripeID, &status)
	if status != "completed" {
		t.Fatalf("status = %q, want completed", status)
	}
	if stripeID != "pi_real_123" {
		t.Fatalf("stripe_payment_id = %q, want the swapped PI", stripeID)
	}
}

func TestCheckoutWebhook_ExpiredVoids(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	out, _ := s.CreateCheckoutPurchase(ctx, f.studioID, f.studentID, productID, "",
		"https://app.test/success", "https://app.test/cancel", "")
	var sessionID string
	s.db.QueryRowContext(ctx,
		`SELECT stripe_payment_id FROM purchases WHERE id = ?`, out.PurchaseID).Scan(&sessionID)

	g.verifyFn = func(_ []byte, _, _ string) (payments.Event, error) {
		return payments.Event{ID: "evt_exp_1", Type: "checkout.session.expired", SessionID: sessionID}, nil
	}
	if err := s.HandleStripeEvent(ctx, f.studioID, []byte("{}"), "sig"); err != nil {
		t.Fatalf("handle expired: %v", err)
	}
	assertPurchaseStatus(t, s, out.PurchaseID, "voided")
}

func TestChargeRefundedWebhook_ReflectsMoneyNotPass(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	// A completed card purchase via PaymentSheet path.
	pending, _ := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "", "")
	g.intents[pending.StripePaymentID] = payments.StatusSucceeded
	entID, _ := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID)

	// charge.refunded (full) for that PaymentIntent.
	g.verifyFn = func(_ []byte, _, _ string) (payments.Event, error) {
		return payments.Event{
			ID:                  "evt_rf_1",
			Type:                "charge.refunded",
			IntentID:            pending.StripePaymentID,
			AmountRefundedMinor: 5000,
			FullyRefunded:       true,
		}, nil
	}
	if err := s.HandleStripeEvent(ctx, f.studioID, []byte("{}"), "sig"); err != nil {
		t.Fatalf("handle charge.refunded: %v", err)
	}
	// Money side reflects refunded...
	var refund int
	var status string
	s.db.QueryRowContext(ctx,
		`SELECT refund_amount_minor, status FROM purchases WHERE id = ?`, pending.PurchaseID).
		Scan(&refund, &status)
	if refund != 5000 || status != "refunded" {
		t.Fatalf("money side: refund=%d status=%q, want 5000/refunded", refund, status)
	}
	// ...but the pass is untouched (money ≠ pass).
	assertEntitlementStatus(t, s, entID, "active")
}
