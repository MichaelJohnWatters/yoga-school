package store

import (
	"context"
	"testing"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// A membership-backed entitlement surfaces its subscription (id, renewal,
// cancel flag) in MyEntitlements so the manager student page can offer cancel
// instead of a billing-leaking void.
func TestMyEntitlements_SurfacesMembership(t *testing.T) {
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
	})

	find := func() EntitlementWalletItem {
		items, err := s.MyEntitlements(ctx, f.studentID)
		if err != nil {
			t.Fatalf("MyEntitlements: %v", err)
		}
		for _, it := range items {
			if it.SubscriptionID != nil {
				return it
			}
		}
		t.Fatal("no membership-backed entitlement found")
		return EntitlementWalletItem{}
	}

	it := find()
	if it.SubscriptionID == nil || *it.SubscriptionID != out.SubscriptionID {
		t.Errorf("subscription_id = %v, want %s", it.SubscriptionID, out.SubscriptionID)
	}
	if it.RenewsAt == nil || *it.RenewsAt == "" {
		t.Error("expected renews_at to be set")
	}
	if it.CancelAtPeriodEnd {
		t.Error("cancel_at_period_end should be false before cancelling")
	}

	// Schedule cancel at renewal → the flag flips, subscription stays active.
	if err := s.AdminCancelSubscription(ctx, f.studioID, f.instructorID, out.SubscriptionID, false); err != nil {
		t.Fatalf("cancel at renewal: %v", err)
	}
	if it := find(); !it.CancelAtPeriodEnd {
		t.Error("cancel_at_period_end should be true after scheduling cancel")
	}
}
