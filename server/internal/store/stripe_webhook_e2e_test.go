package store

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"testing"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// signStripePayload produces a Stripe-Signature header the real
// webhook.ConstructEvent will accept: t=<ts>,v1=<hex hmac-sha256 of "ts.body">.
func signStripePayload(secret string, payload []byte, ts int64) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(fmt.Sprintf("%d.%s", ts, payload)))
	return fmt.Sprintf("t=%d,v1=%s", ts, hex.EncodeToString(mac.Sum(nil)))
}

// TestWebhookE2E_RealSignature_CheckoutCompleted drives the webhook through the
// REAL gateway (payments.NewStripeGateway) — real signature verification, real
// Stripe event JSON parsing — and asserts a hosted-Checkout purchase is
// fulfilled. This is the part of the integration most likely to silently break
// (signature scheme, event shape), exercised without a network call to Stripe.
func TestWebhookE2E_RealSignature_CheckoutCompleted(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID) // webhook secret = whsec_test_123
	s.SetPaymentGateway(payments.NewStripeGateway())
	productID := seedTenPack(t, s, f)

	// Simulate a created Checkout Session: a pending purchase holding the cs_ id.
	const sessionID = "cs_test_e2e_123"
	purchaseID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO purchases
		  (id, studio_id, user_id, product_id, list_price_minor, amount_minor,
		   currency, payment_method, initiated_by, actor_role, status, stripe_payment_id)
		  VALUES (?, ?, ?, ?, 5000, 5000, 'GBP', 'card', ?, 'student', 'pending', ?)`,
		purchaseID, f.studioID, f.studentID, productID, f.studentID, sessionID,
	); err != nil {
		t.Fatalf("seed pending purchase: %v", err)
	}

	// A real Stripe-shaped checkout.session.completed payload (payment_intent
	// arrives as a string id; the SDK's expandable type handles that).
	payload := []byte(fmt.Sprintf(`{
		"id": "evt_e2e_1",
		"object": "event",
		"type": "checkout.session.completed",
		"data": { "object": {
			"id": %q,
			"object": "checkout.session",
			"payment_status": "paid",
			"payment_intent": "pi_e2e_real_456"
		}}
	}`, sessionID))
	sig := signStripePayload("whsec_test_123", payload, time.Now().Unix())

	if err := s.HandleStripeEvent(ctx, f.studioID, payload, sig); err != nil {
		t.Fatalf("HandleStripeEvent (real signature): %v", err)
	}

	// Fulfilled: completed, entitlement minted, session id swapped for the PI.
	var status, stripeID string
	var entitlement string
	s.db.QueryRowContext(ctx,
		`SELECT status, stripe_payment_id, COALESCE(resulting_entitlement_id,'') FROM purchases WHERE id = ?`,
		purchaseID).Scan(&status, &stripeID, &entitlement)
	if status != "completed" {
		t.Fatalf("status = %q, want completed", status)
	}
	if stripeID != "pi_e2e_real_456" {
		t.Fatalf("stripe_payment_id = %q, want swapped PI", stripeID)
	}
	if entitlement == "" {
		t.Fatal("no entitlement minted")
	}

	// A tampered signature must be rejected (proves verification is live).
	if err := s.HandleStripeEvent(ctx, f.studioID, payload, "t=1,v1=deadbeef"); err == nil {
		t.Fatal("expected a bad-signature error")
	}
}
