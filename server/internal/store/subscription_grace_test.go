package store

import (
	"context"
	"testing"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// The membership pass expiry honours the studio's configurable
// subscription_grace_days, not a hardcoded constant.
func TestRecordInvoicePaid_UsesConfiguredGraceDays(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedRecurringProduct(t, s, f)

	// Set a distinctive grace window via the manager settings path.
	grace := 7
	if err := s.UpdateStudioConfig(ctx, f.studioID, f.studentID,
		StudioConfigPatch{SubscriptionGraceDays: &grace}); err != nil {
		t.Fatalf("set grace: %v", err)
	}

	out, err := s.CreateCheckoutSubscription(ctx, f.studioID, f.studentID, productID,
		"https://app/ok", "https://app/no")
	if err != nil {
		t.Fatalf("checkout: %v", err)
	}
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_sess", Type: "checkout.session.completed", SessionMode: "subscription",
		SessionID: "cs_" + out.SubscriptionID, SubscriptionID: "sub_1", CustomerID: "cus_x",
	})

	periodEnd := time.Now().UTC().AddDate(0, 0, 30).Truncate(time.Second)
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_inv1", Type: "invoice.paid", SubscriptionID: "sub_1", CustomerID: "cus_x",
		InvoiceBillingReason: "subscription_create", CurrentPeriodEnd: periodEnd.Unix(),
	})

	_, _, entID := subStatus(t, s, out.SubscriptionID)
	if entID == "" {
		t.Fatal("expected an entitlement")
	}
	got := entitlementExpiry(t, s, entID).Truncate(time.Second)
	want := periodEnd.AddDate(0, 0, grace)
	if !got.Equal(want) {
		t.Errorf("expiry = %s, want period end + %d days = %s", got, grace, want)
	}
}
