package store

import (
	"context"
	"testing"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// Each paid membership invoice is recorded as a completed purchase (so it shows
// in revenue + is refundable/reflectable), keyed on the PaymentIntent so a
// redelivered event can't double-count.
func TestRecordInvoicePaid_RecordsPurchase(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedRecurringProduct(t, s, f)

	out, err := s.CreateCheckoutSubscription(ctx, f.studioID, f.studentID, productID, "a", "b")
	if err != nil {
		t.Fatalf("checkout: %v", err)
	}
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_sess", Type: "checkout.session.completed", SessionMode: "subscription",
		SessionID: "cs_" + out.SubscriptionID, SubscriptionID: "sub_1", CustomerID: "cus_x",
	})
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_inv1", Type: "invoice.paid", SubscriptionID: "sub_1", CustomerID: "cus_x",
		InvoiceBillingReason: "subscription_create",
		CurrentPeriodEnd:     time.Now().UTC().AddDate(0, 0, 30).Unix(),
		IntentID:             "pi_inv_1",
	})

	count := func(pi string) int {
		var n int
		s.db.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM purchases WHERE stripe_payment_id = ? AND status = 'completed'`,
			pi).Scan(&n)
		return n
	}
	if count("pi_inv_1") != 1 {
		t.Fatalf("expected 1 completed purchase for the invoice, got %d", count("pi_inv_1"))
	}
	var amount int
	var entLinked string
	if err := s.db.QueryRowContext(ctx,
		`SELECT amount_minor, COALESCE(resulting_entitlement_id,'') FROM purchases WHERE stripe_payment_id = 'pi_inv_1'`,
	).Scan(&amount, &entLinked); err != nil {
		t.Fatalf("read purchase: %v", err)
	}
	if amount != 8800 {
		t.Errorf("purchase amount = %d, want 8800", amount)
	}
	if entLinked == "" {
		t.Error("purchase should link the granted entitlement")
	}

	// Renewal with a new PI → a second purchase row.
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_inv2", Type: "invoice.paid", SubscriptionID: "sub_1", CustomerID: "cus_x",
		InvoiceBillingReason: "subscription_cycle",
		CurrentPeriodEnd:     time.Now().UTC().AddDate(0, 0, 60).Unix(),
		IntentID:             "pi_inv_2",
	})
	if count("pi_inv_2") != 1 {
		t.Errorf("renewal should record its own purchase, got %d", count("pi_inv_2"))
	}

	var total int
	s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM purchases WHERE user_id = ? AND status = 'completed'`, f.studentID).Scan(&total)
	if total != 2 {
		t.Errorf("expected 2 membership purchases, got %d", total)
	}
}
