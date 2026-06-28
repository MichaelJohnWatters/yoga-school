package store

import (
	"context"
	"testing"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// TestRecordDispute_FlagsPurchaseAndAlertsManagers proves a chargeback is
// recorded on the matching purchase, the manager is notified, the pass is NOT
// auto-revoked (money ≠ pass), and the row surfaces on the attention screen.
func TestRecordDispute_FlagsPurchaseAndAlertsManagers(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)

	// A manager to receive the alert.
	mgrID := NewID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO users (id, studio_id, role, email, full_name)
		 VALUES (?, ?, 'manager', 'mgr@test.com', 'Manager')`, mgrID, f.studioID); err != nil {
		t.Fatal(err)
	}

	// A completed card purchase → real pi_ + entitlement.
	productID := seedTenPack(t, s, f)
	pending, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	g.intents[pending.StripePaymentID] = payments.StatusSucceeded
	entID, err := s.ConfirmPurchaseByIntent(ctx, f.studioID, pending.StripePaymentID)
	if err != nil {
		t.Fatalf("confirm: %v", err)
	}

	// Chargeback arrives.
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_dp1", Type: "charge.dispute.created", IntentID: pending.StripePaymentID,
		DisputeStatus: "needs_response", DisputeReason: "fraudulent", DisputeAmountMinor: 5000,
	})

	// Purchase flagged; pass deliberately kept.
	var dispStatus, entStatus string
	s.db.QueryRowContext(ctx, `SELECT COALESCE(dispute_status,'') FROM purchases WHERE id=?`,
		pending.PurchaseID).Scan(&dispStatus)
	if dispStatus != "needs_response" {
		t.Fatalf("dispute_status = %q, want needs_response", dispStatus)
	}
	s.db.QueryRowContext(ctx, `SELECT status FROM entitlements WHERE id=?`, entID).Scan(&entStatus)
	if entStatus != "active" {
		t.Fatalf("entitlement = %q, want active (dispute must NOT auto-revoke)", entStatus)
	}

	// Manager got a notification.
	var notifs int
	s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM notifications WHERE user_id=? AND type='payment_dispute'`, mgrID).
		Scan(&notifs)
	if notifs != 1 {
		t.Fatalf("manager notifications = %d, want 1", notifs)
	}

	// Surfaces on the attention screen with the entitlement to revoke.
	items, err := s.AdminListPaymentsAttention(ctx, f.studioID)
	if err != nil {
		t.Fatalf("attention list: %v", err)
	}
	if len(items) != 1 || items[0].Kind != "dispute" || items[0].EntitlementID != entID {
		t.Fatalf("attention items = %+v, want one dispute carrying entitlement %s", items, entID)
	}

	// Resolved (won) → drops off the attention list.
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_dp2", Type: "charge.dispute.closed", IntentID: pending.StripePaymentID,
		DisputeStatus: "won",
	})
	items, _ = s.AdminListPaymentsAttention(ctx, f.studioID)
	if len(items) != 0 {
		t.Fatalf("resolved dispute should drop off, got %+v", items)
	}
}

// TestAdminListPaymentsAttention_IncludesPastDueMembership proves a failed
// renewal shows up as an actionable row carrying the subscription to cancel.
func TestAdminListPaymentsAttention_IncludesPastDueMembership(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedRecurringProduct(t, s, f)
	out, _ := s.CreateCheckoutSubscription(ctx, f.studioID, f.studentID, productID, "a", "b")
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "e1", Type: "checkout.session.completed", SessionMode: "subscription",
		SessionID: "cs_" + out.SubscriptionID, SubscriptionID: "sub_1", CustomerID: "cus_x",
	})
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "e2", Type: "invoice.payment_failed", SubscriptionID: "sub_1",
	})

	items, err := s.AdminListPaymentsAttention(ctx, f.studioID)
	if err != nil {
		t.Fatalf("attention: %v", err)
	}
	if len(items) != 1 || items[0].Kind != "past_due_membership" ||
		items[0].SubscriptionID != out.SubscriptionID {
		t.Fatalf("want one past_due_membership for %s, got %+v", out.SubscriptionID, items)
	}

	// Manager cancels immediately → subscription canceled, and Stripe was told
	// to cancel now (not at period end).
	if err := s.AdminCancelSubscription(ctx, f.studioID, f.studentID, out.SubscriptionID, true); err != nil {
		t.Fatalf("immediate cancel: %v", err)
	}
	if st, _, _ := subStatus(t, s, out.SubscriptionID); st != "canceled" {
		t.Fatalf("status = %q, want canceled", st)
	}
	if g.cancelAtEnd["sub_1"] {
		t.Fatal("immediate cancel should pass atPeriodEnd=false to Stripe")
	}
	// And it drops off the attention list.
	after, _ := s.AdminListPaymentsAttention(ctx, f.studioID)
	if len(after) != 0 {
		t.Fatalf("canceled membership should drop off attention, got %+v", after)
	}
}
