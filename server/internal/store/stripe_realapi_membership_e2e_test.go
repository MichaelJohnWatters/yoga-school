//go:build stripe_e2e

// Membership round-trip against Stripe's live test API — the automatable half of
// docs/payments-device-test.md §6–§8/§11. No browser, no reader: it creates a
// real subscription server-side, replays Stripe's *actual* invoice.paid event
// through our webhook handler (re-signed with the studio's secret, so the
// payload is exactly what Stripe sent — the faithful test of the PaymentIntent
// capture), then verifies the money side end to end:
//
//  1. invoice.paid → our gateway extracts the PaymentIntent (subscriptions.last_payment_intent_id)
//  2. the paid invoice is recorded as a completed purchases row (revenue/refund/dispute)
//  3. AdminRefundMembership issues a real Stripe refund against that PI
//
// Skips when no Stripe test secret key is in .env. Run with `go test -tags stripe_e2e`.

package store

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	stripe "github.com/stripe/stripe-go/v83"
	"github.com/stripe/stripe-go/v83/client"
	"github.com/stripe/stripe-go/v83/webhook"

	"github.com/studio52/yoga-school/server/internal/payments"
	"github.com/studio52/yoga-school/server/internal/secrets"
)

func TestStripeRealAPI_MembershipE2E(t *testing.T) {
	loadDotenv(t)
	sk := os.Getenv("STRIPE_E2E_SECRET_KEY")
	if sk == "" {
		sk = os.Getenv("STRIPE_SECRET_KEY")
	}
	if sk == "" {
		t.Skip("no Stripe test secret key in .env — skipping live membership e2e")
	}
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	const webhookSecret = "whsec_e2e_membership"
	s.SetSealer(secrets.NewTestSealer())
	wh := webhookSecret
	if _, err := s.UpdateStripeCredentials(ctx, f.studioID, f.studentID,
		StripeCredentialsPatch{SecretKey: &sk, WebhookSecret: &wh}); err != nil {
		t.Fatalf("set creds: %v", err)
	}
	s.SetPaymentGateway(payments.NewStripeGateway())

	sc := &client.API{}
	sc.Init(sk, nil)

	// --- Real Stripe objects: price, customer w/ a test card, subscription ----
	price, err := sc.Prices.New(&stripe.PriceParams{
		Currency:   stripe.String("gbp"),
		UnitAmount: stripe.Int64(8800),
		Recurring:  &stripe.PriceRecurringParams{Interval: stripe.String("month")},
		ProductData: &stripe.PriceProductDataParams{
			Name: stripe.String("E2E Unlimited Monthly"),
		},
	})
	if err != nil {
		t.Fatalf("create price: %v", err)
	}

	cust, err := sc.Customers.New(&stripe.CustomerParams{
		Email: stripe.String("e2e-member@studio52.test"),
	})
	if err != nil {
		t.Fatalf("create customer: %v", err)
	}
	pm, err := sc.PaymentMethods.New(&stripe.PaymentMethodParams{
		Type: stripe.String("card"),
		Card: &stripe.PaymentMethodCardParams{Token: stripe.String("tok_visa")},
	})
	if err != nil {
		t.Fatalf("create payment method: %v", err)
	}
	if _, err := sc.PaymentMethods.Attach(pm.ID, &stripe.PaymentMethodAttachParams{
		Customer: stripe.String(cust.ID),
	}); err != nil {
		t.Fatalf("attach pm: %v", err)
	}
	if _, err := sc.Customers.Update(cust.ID, &stripe.CustomerParams{
		InvoiceSettings: &stripe.CustomerInvoiceSettingsParams{
			DefaultPaymentMethod: stripe.String(pm.ID),
		},
	}); err != nil {
		t.Fatalf("set default pm: %v", err)
	}

	// Our product + a pending subscription row keyed on the real customer, the
	// state CreateCheckoutSubscription would have left before fulfilment.
	productID := NewID()
	mustExec(t, s, `
		INSERT INTO products
		  (id, studio_id, name, price_minor, billing_type, billing_interval, pass_kind,
		   validity_days, stripe_product_id, stripe_price_id)
		VALUES (?, ?, 'E2E Unlimited Monthly', 8800, 'recurring', 'month', 'unlimited', 30, ?, ?)`,
		productID, f.studioID, price.Product.ID, price.ID)
	mustExec(t, s, `
		INSERT INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`,
		productID, f.classTypeID)
	subID := NewID()
	mustExec(t, s, `
		INSERT INTO subscriptions
		  (id, studio_id, user_id, product_id, stripe_customer_id, status, currency, amount_minor)
		VALUES (?, ?, ?, ?, ?, 'pending', 'GBP', 8800)`,
		subID, f.studioID, f.studentID, productID, cust.ID)

	sub, err := sc.Subscriptions.New(&stripe.SubscriptionParams{
		Customer: stripe.String(cust.ID),
		Items:    []*stripe.SubscriptionItemsParams{{Price: stripe.String(price.ID)}},
	})
	if err != nil {
		t.Fatalf("create subscription: %v", err)
	}
	t.Cleanup(func() { _, _ = sc.Subscriptions.Cancel(sub.ID, nil) })
	if sub.LatestInvoice == nil {
		t.Fatal("subscription has no latest invoice")
	}
	invoiceID := sub.LatestInvoice.ID

	// --- Replay Stripe's real invoice.paid event through our webhook handler ---
	raw := findInvoicePaidEvent(t, sc, invoiceID)
	envelope, _ := json.Marshal(map[string]any{
		"id":     "evt_e2e_" + subID,
		"object": "event",
		"type":   "invoice.paid",
		"data":   map[string]any{"object": json.RawMessage(raw)},
	})
	signed := webhook.GenerateTestSignedPayload(&webhook.UnsignedPayload{
		Payload: envelope, Secret: webhookSecret,
	})
	if err := s.HandleStripeEvent(ctx, f.studioID, envelope, signed.Header); err != nil {
		t.Fatalf("HandleStripeEvent(invoice.paid): %v", err)
	}

	// 1. PaymentIntent captured onto the subscription.
	var status string
	var lastPI *string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status, last_payment_intent_id FROM subscriptions WHERE id = ?`, subID,
	).Scan(&status, &lastPI); err != nil {
		t.Fatalf("read subscription: %v", err)
	}
	if status != "active" {
		t.Errorf("subscription status = %q, want active", status)
	}
	if lastPI == nil || len(*lastPI) < 3 || (*lastPI)[:3] != "pi_" {
		t.Fatalf("last_payment_intent_id = %v, want a pi_ (invoice PaymentIntent capture FAILED — "+
			"inspect the invoice.paid payload field path)", lastPI)
	}

	// 2. The invoice was recorded as a completed purchase, keyed on the PI.
	var pcount, pamount int
	s.db.QueryRowContext(ctx,
		`SELECT COUNT(*), COALESCE(MAX(amount_minor),0) FROM purchases WHERE stripe_payment_id = ? AND status = 'completed'`,
		*lastPI).Scan(&pcount, &pamount)
	if pcount != 1 || pamount != 8800 {
		t.Errorf("membership purchase row: count=%d amount=%d, want 1/8800", pcount, pamount)
	}

	// 3. Refund the membership — real Stripe refund against the captured PI.
	if err := s.AdminRefundMembership(ctx, f.studioID, f.instructorID, subID); err != nil {
		t.Fatalf("AdminRefundMembership (real refund): %v", err)
	}
	if n := auditCount(t, s, f.studioID, "subscription_refund"); n != 1 {
		t.Errorf("subscription_refund audit = %d, want 1", n)
	}
}

// findInvoicePaidEvent polls Stripe's Events API for the invoice.paid event of a
// given invoice and returns its raw object JSON (exactly what the webhook
// carries). Events are created asynchronously, so we retry briefly.
func findInvoicePaidEvent(t *testing.T, sc *client.API, invoiceID string) json.RawMessage {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		it := sc.Events.List(&stripe.EventListParams{
			Type: stripe.String("invoice.paid"),
		})
		for it.Next() {
			e := it.Event()
			var obj struct {
				ID string `json:"id"`
			}
			if err := json.Unmarshal(e.Data.Raw, &obj); err == nil && obj.ID == invoiceID {
				return e.Data.Raw
			}
		}
		time.Sleep(1 * time.Second)
	}
	t.Fatalf("no invoice.paid event for invoice %s within timeout", invoiceID)
	return nil
}
