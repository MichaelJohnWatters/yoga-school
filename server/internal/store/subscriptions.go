package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// subscriptionGraceDays pads an entitlement's expiry past the Stripe billing
// period end so a slightly-late renewal webhook doesn't open a gap in access.
// The renewal invoice.paid fires around period end; the grace tolerates the
// webhook landing a little after.
const subscriptionGraceDays = 2

// SubscriptionCheckoutResult is what CreateCheckoutSubscription returns: the
// hosted Checkout URL the browser redirects to, plus our subscription row id so
// the client can poll for activation.
type SubscriptionCheckoutResult struct {
	SubscriptionID string `json:"subscription_id"`
	URL            string `json:"url"`
}

// Subscription is the client/manager view of a membership.
type Subscription struct {
	ID                string `json:"id"`
	ProductID         string `json:"product_id"`
	ProductName       string `json:"product_name"`
	Status            string `json:"status"`
	CancelAtPeriodEnd bool   `json:"cancel_at_period_end"`
	CurrentPeriodEnd  string `json:"current_period_end,omitempty"`
	Currency          string `json:"currency"`
	AmountMinor       int    `json:"amount_minor"`
	UserID            string `json:"user_id,omitempty"`   // populated for admin views
	UserName          string `json:"user_name,omitempty"` // populated for admin views
}

// CreateCheckoutSubscription is the membership buy surface: it ensures a Stripe
// Customer for the buyer, records a pending subscription row, and creates a
// hosted Checkout Session in subscription mode against the product's recurring
// Price. The webhook (checkout.session.completed + invoice.paid) is
// authoritative for activation + granting the rolling unlimited pass.
//
// Requires a configured gateway and a recurring product that has been mirrored
// to Stripe (stripe_price_id set) — otherwise ErrStripeNotConfigured.
func (s *Store) CreateCheckoutSubscription(
	ctx context.Context,
	studioID, userID, productID, successURL, cancelURL string,
) (*SubscriptionCheckoutResult, error) {
	if s.gateway == nil {
		return nil, fmt.Errorf("payments gateway not configured")
	}

	// Validate the product (read-only). Must be recurring + mirrored to Stripe.
	rtx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	prod, err := loadProductForPurchaseTx(ctx, rtx, studioID, productID)
	if err != nil {
		rtx.Rollback()
		return nil, err
	}
	var buyerEmail string
	_ = rtx.QueryRowContext(ctx,
		`SELECT email FROM users WHERE id = ?`, userID).Scan(&buyerEmail)
	rtx.Rollback()

	if prod.billingType != "recurring" {
		return nil, fmt.Errorf("product %s is not a recurring membership", productID)
	}
	if !prod.stripePriceID.Valid || prod.stripePriceID.String == "" {
		return nil, ErrStripeNotConfigured
	}

	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return nil, ErrStripeNotConfigured
		}
		return nil, fmt.Errorf("load stripe keys: %w", err)
	}

	customerID, err := s.ensureStripeCustomer(ctx, keys.SecretKey, studioID, userID, buyerEmail)
	if err != nil {
		return nil, fmt.Errorf("ensure stripe customer: %w", err)
	}

	subID := NewID()
	sess, err := s.gateway.CreateCheckoutSubscription(ctx, keys.SecretKey, payments.SubscriptionCheckoutParams{
		PriceID:        prod.stripePriceID.String,
		CustomerID:     customerID,
		SuccessURL:     successURL,
		CancelURL:      cancelURL,
		IdempotencyKey: subID,
		Metadata: map[string]string{
			"subscription_id": subID,
			"studio_id":       studioID,
			"user_id":         userID,
			"product_id":      productID,
		},
	})
	if err != nil {
		return nil, fmt.Errorf("stripe subscription checkout: %w", err)
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO subscriptions
		  (id, studio_id, user_id, product_id, stripe_customer_id,
		   stripe_checkout_session_id, status, currency, amount_minor)
		  VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)`,
		subID, studioID, userID, productID, customerID, sess.ID,
		prod.currency, prod.priceMinor,
	); err != nil {
		return nil, fmt.Errorf("insert pending subscription: %w", err)
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID, "subscription_checkout",
		"subscription", subID, map[string]any{
			"product_id":   productID,
			"amount_minor": prod.priceMinor,
		}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &SubscriptionCheckoutResult{SubscriptionID: subID, URL: sess.URL}, nil
}

// ensureStripeCustomer returns the studio's cus_… for this student, creating
// (and caching) one on first use so re-subscribing keeps saved cards.
func (s *Store) ensureStripeCustomer(ctx context.Context, secretKey, studioID, userID, email string) (string, error) {
	var existing string
	err := s.db.QueryRowContext(ctx,
		`SELECT stripe_customer_id FROM stripe_customers WHERE studio_id = ? AND user_id = ?`,
		studioID, userID,
	).Scan(&existing)
	if err == nil {
		return existing, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	custID, err := s.gateway.EnsureCustomer(ctx, secretKey, payments.CustomerParams{
		Email:          email,
		Metadata:       map[string]string{"studio_id": studioID, "user_id": userID},
		IdempotencyKey: "customer:" + studioID + ":" + userID,
	})
	if err != nil {
		return "", err
	}
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO stripe_customers (studio_id, user_id, stripe_customer_id)
		  VALUES (?, ?, ?)
		  ON CONFLICT(studio_id, user_id) DO NOTHING`,
		studioID, userID, custID,
	); err != nil {
		return "", err
	}
	return custID, nil
}

// ===== Webhook fulfilment (authoritative) ================================

// ActivateSubscriptionBySession links a pending subscription row to its Stripe
// subscription id when checkout.session.completed (mode=subscription) lands. It
// does not grant the entitlement — that's invoice.paid's job, so a single code
// path owns granting/extending. Idempotent; ErrNotFound when no row matches.
func (s *Store) ActivateSubscriptionBySession(ctx context.Context, studioID, sessionID, subscriptionID, customerID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var rowID, status string
	err = tx.QueryRowContext(ctx, `
		SELECT id, status FROM subscriptions
		 WHERE studio_id = ? AND stripe_checkout_session_id = ?`,
		studioID, sessionID,
	).Scan(&rowID, &status)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	newStatus := status
	if status == "pending" {
		newStatus = "active"
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE subscriptions
		   SET stripe_subscription_id = COALESCE(stripe_subscription_id, ?),
		       stripe_customer_id     = COALESCE(NULLIF(?, ''), stripe_customer_id),
		       status                 = ?,
		       updated_at             = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ?`,
		subscriptionID, customerID, newStatus, rowID,
	); err != nil {
		return fmt.Errorf("link subscription: %w", err)
	}
	return tx.Commit()
}

// RecordInvoicePaid is the authoritative grant/renew: on every paid invoice it
// (re)grants the rolling unlimited entitlement and extends its expiry to the new
// billing-period end (+grace). Tolerates event ordering — if it lands before
// checkout.session.completed, it resolves the still-pending row by customer and
// links the subscription id itself. Idempotent.
func (s *Store) RecordInvoicePaid(ctx context.Context, studioID string, evt payments.Event) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	rowID, userID, productID, entID, err := findSubscriptionForInvoiceTx(ctx, tx, studioID, evt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}

	// Link the subscription id if this invoice resolved a still-pending row.
	if evt.SubscriptionID != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE subscriptions SET stripe_subscription_id = COALESCE(stripe_subscription_id, ?)
			 WHERE id = ?`, evt.SubscriptionID, rowID); err != nil {
			return fmt.Errorf("link sub on invoice: %w", err)
		}
	}

	// Compute the new expiry from the billing-period end (+grace), falling
	// back to the product's validity window if the event carried no period.
	var expiresAt string
	if evt.CurrentPeriodEnd > 0 {
		expiresAt = time.Unix(evt.CurrentPeriodEnd, 0).UTC().
			AddDate(0, 0, subscriptionGraceDays).Format(time.RFC3339)
	}

	if entID == "" {
		// First paid invoice → mint the rolling unlimited pass.
		prod, err := loadProductForPurchaseTx(ctx, tx, studioID, productID)
		if err != nil {
			return err
		}
		newEnt, err := insertEntitlementSnapshotTx(ctx, tx, studioID, userID, productID, prod)
		if err != nil {
			return err
		}
		entID = newEnt
		if expiresAt == "" {
			// No period end on the event — keep the validity-day expiry the
			// snapshot already set.
			expiresAt = ""
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE subscriptions SET entitlement_id = ? WHERE id = ?`,
			entID, rowID); err != nil {
			return fmt.Errorf("link entitlement: %w", err)
		}
	}

	// (Re)activate + extend the entitlement. Resetting status to 'active' is
	// required because SweepEntitlements flips an expired unlimited pass to
	// 'expired'; a renewal landing after that must revive it.
	if expiresAt != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE entitlements SET expires_at = ?, status = 'active' WHERE id = ?`,
			expiresAt, entID); err != nil {
			return fmt.Errorf("extend entitlement: %w", err)
		}
	} else {
		if _, err := tx.ExecContext(ctx, `
			UPDATE entitlements SET status = 'active' WHERE id = ?`, entID); err != nil {
			return fmt.Errorf("reactivate entitlement: %w", err)
		}
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE subscriptions
		   SET status = 'active', current_period_end = COALESCE(?, current_period_end),
		       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ?`,
		nullableTime(evt.CurrentPeriodEnd), rowID,
	); err != nil {
		return fmt.Errorf("activate subscription: %w", err)
	}
	return tx.Commit()
}

// RecordInvoiceFailed marks the subscription past_due and revokes access
// immediately: the linked entitlement is expired the moment a renewal fails.
// Stripe still runs its dunning retries; a retry that succeeds fires
// invoice.paid, which reactivates + re-extends the pass. If dunning ultimately
// gives up, customer.subscription.deleted finalises the cancellation.
func (s *Store) RecordInvoiceFailed(ctx context.Context, studioID string, evt payments.Event) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var rowID, entID string
	err = tx.QueryRowContext(ctx, `
		SELECT id, COALESCE(entitlement_id,'') FROM subscriptions
		 WHERE studio_id = ? AND stripe_subscription_id = ?`,
		studioID, evt.SubscriptionID,
	).Scan(&rowID, &entID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE subscriptions
		   SET status = 'past_due',
		       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ? AND status NOT IN ('canceled','incomplete_expired')`,
		rowID); err != nil {
		return fmt.Errorf("mark past_due: %w", err)
	}
	if entID != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE entitlements SET status = 'expired'
			 WHERE id = ? AND status = 'active'`, entID); err != nil {
			return fmt.Errorf("revoke entitlement on failed renewal: %w", err)
		}
		// Immediate cut: also cancel the seats they already booked on this
		// membership (mirrors the manager Void path). A later successful retry
		// reactivates the pass but does NOT restore these seats — they'd
		// re-book (and the freed seats may be gone).
		if err := cancelFutureBookingsTx(ctx, tx, entID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// cancelFutureBookingsTx cancels a member's still-upcoming bookings funded by an
// entitlement (classes that haven't started yet). Same shape as VoidEntitlement
// so payment-failure and manager-void revoke access consistently.
func cancelFutureBookingsTx(ctx context.Context, tx *sql.Tx, entitlementID string) error {
	if _, err := tx.ExecContext(ctx, `
		UPDATE bookings
		   SET status = 'cancelled',
		       cancelled_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE entitlement_id = ?
		   AND status = 'booked'
		   AND EXISTS (
		     SELECT 1 FROM classes c
		      WHERE c.id = bookings.class_id
		        AND c.starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
		   )`, entitlementID); err != nil {
		return fmt.Errorf("cancel future bookings: %w", err)
	}
	return nil
}

// UpdateSubscriptionStatus reflects customer.subscription.updated: status,
// cancel-at-period-end flag, and period end. Does not touch the entitlement
// (invoice.paid owns access); a flip to canceled is handled by .deleted.
func (s *Store) UpdateSubscriptionStatus(ctx context.Context, studioID string, evt payments.Event) error {
	status := mapStripeSubStatus(evt.SubscriptionStatus)
	cancelFlag := 0
	if evt.CancelAtPeriodEnd {
		cancelFlag = 1
	}
	res, err := s.db.ExecContext(ctx, `
		UPDATE subscriptions
		   SET status = ?, cancel_at_period_end = ?,
		       current_period_end = COALESCE(?, current_period_end),
		       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE studio_id = ? AND stripe_subscription_id = ?`,
		status, cancelFlag, nullableTime(evt.CurrentPeriodEnd),
		studioID, evt.SubscriptionID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// CancelSubscriptionRecord reflects customer.subscription.deleted: the
// subscription is fully canceled. Access ends at the period end already set on
// the entitlement (Stripe deletes at period end when canceled-at-period-end, or
// immediately otherwise — in which case we expire the pass now).
func (s *Store) CancelSubscriptionRecord(ctx context.Context, studioID string, evt payments.Event) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var rowID, entID string
	var periodEnd sql.NullString
	err = tx.QueryRowContext(ctx, `
		SELECT id, COALESCE(entitlement_id,''), current_period_end
		  FROM subscriptions
		 WHERE studio_id = ? AND stripe_subscription_id = ?`,
		studioID, evt.SubscriptionID,
	).Scan(&rowID, &entID, &periodEnd)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE subscriptions
		   SET status = 'canceled',
		       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ?`, rowID); err != nil {
		return err
	}
	// If the period already lapsed (immediate cancel), expire access now;
	// otherwise the entitlement's expires_at already bounds it. Bookings within
	// the paid period are deliberately kept — a clean cancellation honours the
	// classes the member already reserved for the time they paid for. (A failed
	// renewal is the path that revokes seats; see RecordInvoiceFailed.)
	if entID != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE entitlements
			   SET status = 'expired'
			 WHERE id = ? AND status = 'active'
			   AND (expires_at IS NULL OR expires_at <= strftime('%Y-%m-%dT%H:%M:%fZ','now'))`,
			entID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// findSubscriptionForInvoiceTx resolves the subscription row for an invoice
// event: first by the Stripe subscription id, then (when the activation event
// hasn't linked it yet) by the customer's pending row. Returns sql.ErrNoRows
// when nothing matches.
func findSubscriptionForInvoiceTx(ctx context.Context, tx *sql.Tx, studioID string, evt payments.Event) (rowID, userID, productID, entID string, err error) {
	scan := func(q string, args ...any) error {
		var e sql.NullString
		row := tx.QueryRowContext(ctx, q, args...)
		if err := row.Scan(&rowID, &userID, &productID, &e); err != nil {
			return err
		}
		entID = e.String
		return nil
	}
	if evt.SubscriptionID != "" {
		err = scan(`
			SELECT id, user_id, product_id, entitlement_id FROM subscriptions
			 WHERE studio_id = ? AND stripe_subscription_id = ?`,
			studioID, evt.SubscriptionID)
		if err == nil || !errors.Is(err, sql.ErrNoRows) {
			return
		}
	}
	if evt.CustomerID != "" {
		err = scan(`
			SELECT id, user_id, product_id, entitlement_id FROM subscriptions
			 WHERE studio_id = ? AND stripe_customer_id = ? AND status = 'pending'
			 ORDER BY created_at DESC LIMIT 1`,
			studioID, evt.CustomerID)
		return
	}
	err = sql.ErrNoRows
	return
}

// ===== Student-facing reads + mutations =================================

// ListMySubscriptions returns a student's memberships, newest first.
func (s *Store) ListMySubscriptions(ctx context.Context, studioID, userID string) ([]Subscription, error) {
	return s.querySubscriptions(ctx, `
		SELECT sub.id, sub.product_id, p.name, sub.status, sub.cancel_at_period_end,
		       COALESCE(sub.current_period_end,''), sub.currency, sub.amount_minor,
		       '', ''
		  FROM subscriptions sub
		  JOIN products p ON p.id = sub.product_id
		 WHERE sub.studio_id = ? AND sub.user_id = ?
		 ORDER BY sub.created_at DESC`, studioID, userID)
}

// CancelMySubscription schedules an end-of-period cancellation (access
// continues until the paid period ends). The webhook reflects the final state.
func (s *Store) CancelMySubscription(ctx context.Context, studioID, userID, subID string) error {
	return s.cancelSubscription(ctx, studioID, userID, subID, true)
}

// ResumeMySubscription clears a pending end-of-period cancellation.
func (s *Store) ResumeMySubscription(ctx context.Context, studioID, userID, subID string) error {
	stripeSubID, _, err := s.loadOwnedSubscription(ctx, studioID, userID, subID)
	if err != nil {
		return err
	}
	keys, err := s.stripeKeys(ctx, studioID)
	if err != nil {
		return err
	}
	if err := s.gateway.ResumeSubscription(ctx, keys.SecretKey, stripeSubID); err != nil {
		return fmt.Errorf("resume subscription: %w", err)
	}
	_, err = s.db.ExecContext(ctx, `
		UPDATE subscriptions SET cancel_at_period_end = 0,
		       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ?`, subID)
	return err
}

// BillingPortalURL returns a Stripe billing-portal link for the student to
// update their card / manage the membership. Requires an existing customer.
func (s *Store) BillingPortalURL(ctx context.Context, studioID, userID, returnURL string) (string, error) {
	if s.gateway == nil {
		return "", fmt.Errorf("payments gateway not configured")
	}
	var customerID string
	err := s.db.QueryRowContext(ctx,
		`SELECT stripe_customer_id FROM stripe_customers WHERE studio_id = ? AND user_id = ?`,
		studioID, userID).Scan(&customerID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	keys, err := s.stripeKeys(ctx, studioID)
	if err != nil {
		return "", err
	}
	return s.gateway.CreateBillingPortalSession(ctx, keys.SecretKey, customerID, returnURL)
}

// ReconcileSubscriptions is the membership safety net — the webhook is the
// authoritative path, this catches anything it missed (an outage, a studio
// mis-config, a dropped event). Two parts:
//
//  1. Expire abandoned checkouts: pending rows never linked to a Stripe
//     subscription, older than the threshold (student opened Checkout, walked
//     away). Pure DB sweep.
//  2. Reconcile live state against Stripe for rows where a webhook may have
//     been missed: a renewal is overdue (active but current_period_end passed
//     the threshold ago), or the row is past_due / linked-but-pending. We fetch
//     the subscription from Stripe and converge through the same idempotent
//     handlers the webhook uses, so a missed event self-heals (just slower).
//
// Targeted on purpose — a healthy monthly sub is only polled around its renewal,
// not every tick. Returns the number of rows touched.
func (s *Store) ReconcileSubscriptions(ctx context.Context, olderThan time.Duration) (int, error) {
	cutoff := time.Now().UTC().Add(-olderThan).Format(time.RFC3339)

	res, err := s.db.ExecContext(ctx, `
		UPDATE subscriptions
		   SET status = 'incomplete_expired',
		       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE status = 'pending'
		   AND stripe_subscription_id IS NULL
		   AND created_at < ?`, cutoff)
	if err != nil {
		return 0, err
	}
	touched, _ := res.RowsAffected()

	if s.gateway == nil {
		return int(touched), nil
	}

	// Rows where a webhook may have been missed.
	rows, err := s.db.QueryContext(ctx, `
		SELECT studio_id, stripe_subscription_id, stripe_customer_id
		  FROM subscriptions
		 WHERE stripe_subscription_id IS NOT NULL
		   AND ( (status = 'active' AND current_period_end IS NOT NULL AND current_period_end < ?)
		      OR status = 'past_due'
		      OR status = 'pending' )`, cutoff)
	if err != nil {
		return int(touched), err
	}
	type stale struct{ studioID, subID, customerID string }
	var pending []stale
	for rows.Next() {
		var st stale
		if err := rows.Scan(&st.studioID, &st.subID, &st.customerID); err != nil {
			rows.Close()
			return int(touched), err
		}
		pending = append(pending, st)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return int(touched), err
	}

	keyCache := map[string]string{} // studioID → secret key
	for _, st := range pending {
		secret, ok := keyCache[st.studioID]
		if !ok {
			keys, err := s.LoadStripeKeysForUse(ctx, st.studioID)
			if err != nil {
				continue // studio's keys gone/unconfigured — skip, try next tick
			}
			secret = keys.SecretKey
			keyCache[st.studioID] = secret
		}
		live, err := s.gateway.GetSubscription(ctx, secret, st.subID)
		if err != nil {
			continue // transient — next tick retries
		}
		evt := payments.Event{
			SubscriptionID:     st.subID,
			CustomerID:         st.customerID,
			SubscriptionStatus: live.Status,
			CurrentPeriodEnd:   live.CurrentPeriodEnd,
			CancelAtPeriodEnd:  live.CancelAtPeriodEnd,
		}
		if s.reconcileSubscriptionToState(ctx, st.studioID, evt) {
			touched++
		}
	}
	return int(touched), nil
}

// reconcileSubscriptionToState converges one subscription onto its live Stripe
// status by reusing the idempotent webhook handlers. Returns whether it acted.
func (s *Store) reconcileSubscriptionToState(ctx context.Context, studioID string, evt payments.Event) bool {
	switch mapStripeSubStatus(evt.SubscriptionStatus) {
	case "active":
		// Re-grant/extend the pass to the live period end + sync the
		// cancel-at-period-end flag. Both are idempotent no-ops when already
		// in sync (the common case once the webhook has run).
		_ = s.RecordInvoicePaid(ctx, studioID, evt)
		_ = s.UpdateSubscriptionStatus(ctx, studioID, evt)
	case "past_due":
		_ = s.RecordInvoiceFailed(ctx, studioID, evt)
	case "canceled":
		_ = s.CancelSubscriptionRecord(ctx, studioID, evt)
	default: // incomplete_expired / unknown → just reflect the status
		_ = s.UpdateSubscriptionStatus(ctx, studioID, evt)
	}
	return true
}

// ===== Admin =============================================================

// AdminListSubscriptions returns every membership for the studio (with student
// names), newest first.
func (s *Store) AdminListSubscriptions(ctx context.Context, studioID string) ([]Subscription, error) {
	return s.querySubscriptions(ctx, `
		SELECT sub.id, sub.product_id, p.name, sub.status, sub.cancel_at_period_end,
		       COALESCE(sub.current_period_end,''), sub.currency, sub.amount_minor,
		       sub.user_id, u.full_name
		  FROM subscriptions sub
		  JOIN products p ON p.id = sub.product_id
		  JOIN users u ON u.id = sub.user_id
		 WHERE sub.studio_id = ?
		 ORDER BY sub.created_at DESC`, studioID)
}

// AdminCancelSubscription cancels a membership on the student's behalf (manager
// flow). immediate=false cancels at period end (access continues); immediate=true
// cancels now and revokes access + upcoming bookings — used from the "Payments
// needing attention" screen for a member whose payment was disputed or who
// stopped paying. Audited.
func (s *Store) AdminCancelSubscription(ctx context.Context, studioID, actorID, subID string, immediate bool) error {
	var ownerID, entID string
	if err := s.db.QueryRowContext(ctx,
		`SELECT user_id, COALESCE(entitlement_id,'') FROM subscriptions WHERE studio_id = ? AND id = ?`,
		studioID, subID).Scan(&ownerID, &entID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if err := s.cancelSubscription(ctx, studioID, ownerID, subID, !immediate); err != nil {
		return err
	}
	if immediate {
		// Mark canceled now + revoke the pass and any upcoming seats.
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if _, err := tx.ExecContext(ctx, `
			UPDATE subscriptions SET status = 'canceled',
			       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
			 WHERE id = ?`, subID); err != nil {
			return err
		}
		if entID != "" {
			if _, err := tx.ExecContext(ctx, `
				UPDATE entitlements SET status = 'expired' WHERE id = ? AND status = 'active'`,
				entID); err != nil {
				return err
			}
			if err := cancelFutureBookingsTx(ctx, tx, entID); err != nil {
				return err
			}
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return s.WriteAudit(ctx, studioID, actorID, "subscription_cancel",
		"subscription", subID, map[string]any{"on_behalf_of": ownerID, "immediate": immediate})
}

// ===== shared helpers ====================================================

func (s *Store) cancelSubscription(ctx context.Context, studioID, userID, subID string, atPeriodEnd bool) error {
	stripeSubID, _, err := s.loadOwnedSubscription(ctx, studioID, userID, subID)
	if err != nil {
		return err
	}
	keys, err := s.stripeKeys(ctx, studioID)
	if err != nil {
		return err
	}
	if err := s.gateway.CancelSubscription(ctx, keys.SecretKey, stripeSubID, atPeriodEnd); err != nil {
		return fmt.Errorf("cancel subscription: %w", err)
	}
	_, err = s.db.ExecContext(ctx, `
		UPDATE subscriptions SET cancel_at_period_end = 1,
		       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ?`, subID)
	return err
}

// loadOwnedSubscription returns the Stripe subscription id for a row the user
// owns. ErrNotFound when missing or not theirs; a clear error when the row was
// never linked to Stripe (still pending checkout).
func (s *Store) loadOwnedSubscription(ctx context.Context, studioID, userID, subID string) (stripeSubID, status string, err error) {
	var sub sql.NullString
	err = s.db.QueryRowContext(ctx, `
		SELECT stripe_subscription_id, status FROM subscriptions
		 WHERE studio_id = ? AND user_id = ? AND id = ?`,
		studioID, userID, subID,
	).Scan(&sub, &status)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrNotFound
	}
	if err != nil {
		return "", "", err
	}
	if !sub.Valid || sub.String == "" {
		return "", status, fmt.Errorf("subscription not yet active")
	}
	return sub.String, status, nil
}

func (s *Store) stripeKeys(ctx context.Context, studioID string) (*DecryptedStripeKeys, error) {
	if s.gateway == nil {
		return nil, fmt.Errorf("payments gateway not configured")
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return nil, ErrStripeNotConfigured
		}
		return nil, fmt.Errorf("load stripe keys: %w", err)
	}
	return keys, nil
}

func (s *Store) querySubscriptions(ctx context.Context, query string, args ...any) ([]Subscription, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Subscription, 0)
	for rows.Next() {
		var sub Subscription
		var cancel int
		if err := rows.Scan(&sub.ID, &sub.ProductID, &sub.ProductName, &sub.Status,
			&cancel, &sub.CurrentPeriodEnd, &sub.Currency, &sub.AmountMinor,
			&sub.UserID, &sub.UserName); err != nil {
			return nil, err
		}
		sub.CancelAtPeriodEnd = cancel == 1
		out = append(out, sub)
	}
	return out, rows.Err()
}

// nullableTime renders a unix-seconds timestamp as an RFC3339 string for SQL,
// or nil when zero (so COALESCE keeps the existing value).
func nullableTime(unix int64) any {
	if unix <= 0 {
		return nil
	}
	return time.Unix(unix, 0).UTC().Format(time.RFC3339)
}

// mapStripeSubStatus collapses Stripe's subscription statuses onto the set our
// schema allows.
func mapStripeSubStatus(stripeStatus string) string {
	switch stripeStatus {
	case "active", "trialing":
		return "active"
	case "past_due", "unpaid":
		return "past_due"
	case "canceled":
		return "canceled"
	case "incomplete_expired":
		return "incomplete_expired"
	default:
		return "pending"
	}
}
