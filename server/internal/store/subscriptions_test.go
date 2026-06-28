package store

import (
	"context"
	"testing"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// seedRecurringProduct inserts a recurring/unlimited product already mirrored to
// Stripe (stripe_price_id set), covering the fixture's class type.
func seedRecurringProduct(t *testing.T, s *Store, f fixture) string {
	t.Helper()
	id := NewID()
	ctx := context.Background()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO products
		  (id, studio_id, name, price_minor, billing_type, billing_interval, pass_kind,
		   validity_days, stripe_product_id, stripe_price_id)
		  VALUES (?, ?, 'Unlimited Monthly', 8800, 'recurring', 'month', 'unlimited',
		          30, 'prod_x', 'price_x')`, id, f.studioID); err != nil {
		t.Fatalf("seed recurring product: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`,
		id, f.classTypeID); err != nil {
		t.Fatalf("seed product class type: %v", err)
	}
	return id
}

func subStatus(t *testing.T, s *Store, subID string) (status string, periodEnd, entID string) {
	t.Helper()
	var pe, e *string
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT status, current_period_end, entitlement_id FROM subscriptions WHERE id = ?`,
		subID).Scan(&status, &pe, &e); err != nil {
		t.Fatalf("read sub: %v", err)
	}
	if pe != nil {
		periodEnd = *pe
	}
	if e != nil {
		entID = *e
	}
	return
}

// TestSubscriptionLifecycle drives the full membership flow through the
// authoritative webhook path: checkout → activate → first invoice (grant) →
// renewal (extend) → expired-then-renew (reactivate) → cancel.
func TestSubscriptionLifecycle(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedRecurringProduct(t, s, f)

	// 1. Checkout → pending row, charges against the product's recurring Price.
	out, err := s.CreateCheckoutSubscription(ctx, f.studioID, f.studentID, productID,
		"https://app/ok", "https://app/no")
	if err != nil {
		t.Fatalf("checkout: %v", err)
	}
	if g.lastSubCheckout.PriceID != "price_x" {
		t.Fatalf("checkout used price %q, want price_x", g.lastSubCheckout.PriceID)
	}
	if st, _, _ := subStatus(t, s, out.SubscriptionID); st != "pending" {
		t.Fatalf("status = %q, want pending", st)
	}
	sessionID := "cs_" + out.SubscriptionID // fakeGateway derives the cs id from the key

	// 2. checkout.session.completed (subscription) → linked + active, no grant yet.
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_sess", Type: "checkout.session.completed", SessionMode: "subscription",
		SessionID: sessionID, SubscriptionID: "sub_1", CustomerID: "cus_x",
	})
	if st, _, ent := subStatus(t, s, out.SubscriptionID); st != "active" || ent != "" {
		t.Fatalf("after activate: status=%q ent=%q, want active/empty", st, ent)
	}

	// 3. invoice.paid (initial) → mints + extends the unlimited pass.
	period1 := time.Now().UTC().AddDate(0, 0, 30).Unix()
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_inv1", Type: "invoice.paid", SubscriptionID: "sub_1", CustomerID: "cus_x",
		InvoiceBillingReason: "subscription_create", CurrentPeriodEnd: period1,
	})
	_, _, entID := subStatus(t, s, out.SubscriptionID)
	if entID == "" {
		t.Fatal("expected entitlement minted on first invoice")
	}
	exp1 := entitlementExpiry(t, s, entID)
	wantMin := time.Unix(period1, 0).UTC()
	if exp1.Before(wantMin) {
		t.Fatalf("expiry %s should be >= period end %s (incl. grace)", exp1, wantMin)
	}
	if st := entitlementStatus(t, s, entID); st != "active" {
		t.Fatalf("entitlement status %q, want active", st)
	}

	// 4. Renewal: a later period end extends the same entitlement.
	period2 := time.Now().UTC().AddDate(0, 0, 60).Unix()
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_inv2", Type: "invoice.paid", SubscriptionID: "sub_1", CustomerID: "cus_x",
		InvoiceBillingReason: "subscription_cycle", CurrentPeriodEnd: period2,
	})
	_, _, entID2 := subStatus(t, s, out.SubscriptionID)
	if entID2 != entID {
		t.Fatalf("renewal minted a new entitlement %q (want same %q)", entID2, entID)
	}
	if exp2 := entitlementExpiry(t, s, entID); !exp2.After(exp1) {
		t.Fatalf("renewal did not extend expiry: %s !> %s", exp2, exp1)
	}

	// 5. Expired-then-renew: sweep flips it to expired, the next invoice revives it.
	if _, err := s.db.ExecContext(ctx,
		`UPDATE entitlements SET status='expired', expires_at=? WHERE id=?`,
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339), entID); err != nil {
		t.Fatal(err)
	}
	period3 := time.Now().UTC().AddDate(0, 0, 90).Unix()
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_inv3", Type: "invoice.paid", SubscriptionID: "sub_1", CustomerID: "cus_x",
		InvoiceBillingReason: "subscription_cycle", CurrentPeriodEnd: period3,
	})
	if st := entitlementStatus(t, s, entID); st != "active" {
		t.Fatalf("renewal after expiry left status %q, want active", st)
	}

	// 6. Student cancels at period end.
	if err := s.CancelMySubscription(ctx, f.studioID, f.studentID, out.SubscriptionID); err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if len(g.canceledSubs) != 1 || g.canceledSubs[0] != "sub_1" || !g.cancelAtEnd["sub_1"] {
		t.Fatalf("expected at-period-end cancel of sub_1, got %+v / %+v", g.canceledSubs, g.cancelAtEnd)
	}
	var cancelFlag int
	s.db.QueryRowContext(ctx, `SELECT cancel_at_period_end FROM subscriptions WHERE id=?`,
		out.SubscriptionID).Scan(&cancelFlag)
	if cancelFlag != 1 {
		t.Fatal("cancel_at_period_end not set")
	}

	// 7. customer.subscription.deleted → canceled.
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_del", Type: "customer.subscription.deleted", SubscriptionID: "sub_1",
		SubscriptionStatus: "canceled",
	})
	if st, _, _ := subStatus(t, s, out.SubscriptionID); st != "canceled" {
		t.Fatalf("after delete: status=%q, want canceled", st)
	}
}

// TestInvoiceFailed_RevokesAccessImmediately proves a failed renewal flips the
// membership to past_due AND expires the pass right away, and that a subsequent
// successful retry (invoice.paid) reactivates it.
func TestInvoiceFailed_RevokesAccessImmediately(t *testing.T) {
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
	// First payment grants the pass.
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "e2", Type: "invoice.paid", SubscriptionID: "sub_1", CustomerID: "cus_x",
		CurrentPeriodEnd: time.Now().UTC().AddDate(0, 0, 30).Unix(),
	})
	_, _, entID := subStatus(t, s, out.SubscriptionID)
	if entID == "" || entitlementStatus(t, s, entID) != "active" {
		t.Fatal("expected an active pass after first payment")
	}

	// Book a future class on this membership — it must be cancelled when the
	// renewal fails (immediate cut).
	futureClass := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	bookingID := f.insertBookedSeat(t, s, futureClass, entID)

	// Renewal fails → past_due + access revoked immediately + seat cancelled.
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "e3", Type: "invoice.payment_failed", SubscriptionID: "sub_1",
	})
	if st, _, _ := subStatus(t, s, out.SubscriptionID); st != "past_due" {
		t.Fatalf("status = %q, want past_due", st)
	}
	if es := entitlementStatus(t, s, entID); es != "expired" {
		t.Fatalf("entitlement status = %q, want expired (access revoked)", es)
	}
	var bookingStatus string
	s.db.QueryRowContext(ctx, `SELECT status FROM bookings WHERE id=?`, bookingID).
		Scan(&bookingStatus)
	if bookingStatus != "cancelled" {
		t.Fatalf("future booking = %q, want cancelled on failed renewal", bookingStatus)
	}

	// A successful retry brings them back.
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "e4", Type: "invoice.paid", SubscriptionID: "sub_1", CustomerID: "cus_x",
		CurrentPeriodEnd: time.Now().UTC().AddDate(0, 0, 60).Unix(),
	})
	if st, _, _ := subStatus(t, s, out.SubscriptionID); st != "active" {
		t.Fatalf("status after retry = %q, want active", st)
	}
	if es := entitlementStatus(t, s, entID); es != "active" {
		t.Fatalf("entitlement after retry = %q, want active", es)
	}
}

func TestReconcileSubscriptions_ExpiresAbandoned(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedRecurringProduct(t, s, f)
	out, _ := s.CreateCheckoutSubscription(ctx, f.studioID, f.studentID, productID, "a", "b")
	// Age the pending (never-linked) row past the threshold.
	s.db.ExecContext(ctx, `UPDATE subscriptions SET created_at = ?`,
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339))

	n, err := s.ReconcileSubscriptions(ctx, 15*time.Minute)
	if err != nil || n != 1 {
		t.Fatalf("reconcile: n=%d err=%v, want 1/nil", n, err)
	}
	if st, _, _ := subStatus(t, s, out.SubscriptionID); st != "incomplete_expired" {
		t.Fatalf("status = %q, want incomplete_expired", st)
	}
}

// TestReconcileSubscriptions_HealsMissedRenewal proves the safety net: when a
// renewal's invoice.paid webhook is missed (the period lapsed but the row is
// still active on the old period), reconcile polls Stripe and re-extends the
// pass from the live state.
func TestReconcileSubscriptions_HealsMissedRenewal(t *testing.T) {
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
		ID: "e2", Type: "invoice.paid", SubscriptionID: "sub_1", CustomerID: "cus_x",
		CurrentPeriodEnd: time.Now().UTC().AddDate(0, 0, 30).Unix(),
	})
	_, _, entID := subStatus(t, s, out.SubscriptionID)
	exp1 := entitlementExpiry(t, s, entID)

	// Simulate a missed renewal: the period lapsed (set current_period_end to
	// the past) but the row is still 'active' on the old period.
	if _, err := s.db.ExecContext(ctx,
		`UPDATE subscriptions SET current_period_end = ? WHERE id = ?`,
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339), out.SubscriptionID); err != nil {
		t.Fatal(err)
	}
	// Stripe's live state: renewed into the next cycle (later than the first
	// period, so the re-extension is observable).
	newPeriod := time.Now().UTC().AddDate(0, 0, 60).Unix()
	g.getSubscriptionFn = func(_ string) (payments.SubscriptionState, error) {
		return payments.SubscriptionState{Status: "active", CurrentPeriodEnd: newPeriod}, nil
	}

	n, err := s.ReconcileSubscriptions(ctx, 15*time.Minute)
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if n == 0 {
		t.Fatal("expected reconcile to touch the overdue subscription")
	}
	if exp2 := entitlementExpiry(t, s, entID); !exp2.After(exp1) {
		t.Fatalf("reconcile did not re-extend the pass: %s !> %s", exp2, exp1)
	}
	if st, _, _ := subStatus(t, s, out.SubscriptionID); st != "active" {
		t.Fatalf("status = %q, want active", st)
	}
}

// TestReconcileSubscriptions_HealsCancellation proves a missed
// customer.subscription.deleted is caught: Stripe says canceled, reconcile
// converges the row.
func TestReconcileSubscriptions_HealsCancellation(t *testing.T) {
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
	// past_due rows are always polled by reconcile.
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "e2", Type: "invoice.payment_failed", SubscriptionID: "sub_1",
	})
	g.getSubscriptionFn = func(_ string) (payments.SubscriptionState, error) {
		return payments.SubscriptionState{Status: "canceled"}, nil
	}
	if _, err := s.ReconcileSubscriptions(ctx, 15*time.Minute); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if st, _, _ := subStatus(t, s, out.SubscriptionID); st != "canceled" {
		t.Fatalf("status = %q, want canceled", st)
	}
}

// TestRecurringProductMirrorsAndRepoints proves CreateAdminProduct mirrors a
// recurring product to Stripe and a price edit repoints to a fresh Price while
// archiving the old one.
func TestRecurringProductMirrorsAndRepoints(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{}
	s.SetPaymentGateway(g)

	name, price, billing, interval := "Gold", 9900, "recurring", "month"
	id, err := s.CreateAdminProduct(ctx, f.studioID, f.studentID, AdminProductInput{
		Name: &name, PriceMinor: &price, BillingType: &billing,
		BillingInterval: &interval, PassKind: strptr("unlimited"),
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	var priceID string
	s.db.QueryRowContext(ctx, `SELECT COALESCE(stripe_price_id,'') FROM products WHERE id=?`, id).Scan(&priceID)
	if priceID == "" {
		t.Fatal("recurring product was not mirrored to a Stripe Price")
	}
	if g.lastPrice.Interval != "month" || g.lastPrice.AmountMinor != 9900 {
		t.Fatalf("mirrored price = %+v", g.lastPrice)
	}

	// Edit the price → new Price, old one archived, row repointed.
	newPrice := 12900
	if err := s.UpdateAdminProduct(ctx, f.studioID, f.studentID, id,
		AdminProductInput{PriceMinor: &newPrice}); err != nil {
		t.Fatalf("update: %v", err)
	}
	var priceID2 string
	s.db.QueryRowContext(ctx, `SELECT COALESCE(stripe_price_id,'') FROM products WHERE id=?`, id).Scan(&priceID2)
	if priceID2 == priceID {
		t.Fatal("price edit did not repoint the Stripe Price")
	}
	if len(g.archivedPrices) != 1 || g.archivedPrices[0] != priceID {
		t.Fatalf("expected old price %q archived, got %+v", priceID, g.archivedPrices)
	}
}

// fireEvent runs one scripted webhook event through HandleStripeEvent.
func fireEvent(t *testing.T, s *Store, g *fakeGateway, studioID string, evt payments.Event) {
	t.Helper()
	g.verifyFn = func(_ []byte, _, _ string) (payments.Event, error) { return evt, nil }
	if err := s.HandleStripeEvent(context.Background(), studioID, []byte("{}"), "sig"); err != nil {
		t.Fatalf("handle %s: %v", evt.Type, err)
	}
}

func entitlementExpiry(t *testing.T, s *Store, entID string) time.Time {
	t.Helper()
	var exp string
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT COALESCE(expires_at,'') FROM entitlements WHERE id=?`, entID).Scan(&exp); err != nil {
		t.Fatalf("read expiry: %v", err)
	}
	ts, err := time.Parse(time.RFC3339, exp)
	if err != nil {
		t.Fatalf("parse expiry %q: %v", exp, err)
	}
	return ts
}

func entitlementStatus(t *testing.T, s *Store, entID string) string {
	t.Helper()
	var st string
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT status FROM entitlements WHERE id=?`, entID).Scan(&st); err != nil {
		t.Fatalf("read status: %v", err)
	}
	return st
}
