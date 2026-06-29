package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// CheckoutResult is what CreateCheckoutPurchase returns. The client redirects
// the browser to URL; PurchaseID lets the success page confirm/poll.
type CheckoutResult struct {
	PurchaseID string `json:"purchase_id"`
	URL        string `json:"url"`
}

// ErrStripeNotConfigured is returned by the card payment paths when the studio
// has no Stripe keys saved yet. Kept distinct from a generic not-found so the
// API surfaces a clear "add your keys" message instead of a bare 404 — the
// usual cause once the dev_stub fallback was removed.
var ErrStripeNotConfigured = errors.New(
	"Stripe is not configured for this studio — add the keys in Settings → Stripe")

// CreateCheckoutPurchase is the web payment surface: it records a pending
// purchase and creates a hosted Stripe Checkout Session, returning the URL the
// browser redirects to. The pending purchase stores the session id (cs_…) in
// stripe_payment_id until checkout.session.completed swaps it for the real
// PaymentIntent. Mirrors CreatePendingPurchase's server-computed-amount and
// discount handling; differs only in the Stripe surface (Checkout vs Intent).
//
// Requires a configured gateway — there's no dev_stub for the redirect flow
// (local dev uses the dev_stub instant path instead).
func (s *Store) CreateCheckoutPurchase(
	ctx context.Context,
	studioID, userID, productID, discountCode, successURL, cancelURL, enrollmentID string,
) (*CheckoutResult, error) {
	if s.gateway == nil {
		return nil, fmt.Errorf("payments gateway not configured")
	}

	// Validate (read-only) — amount is server-computed, never client-sent.
	rtx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	prod, err := loadProductForPurchaseTx(ctx, rtx, studioID, productID)
	if err != nil {
		rtx.Rollback()
		return nil, err
	}
	discountID, discountMinor, err := validateAndApplyDiscountTx(
		ctx, rtx, studioID, userID, productID, discountCode, prod.priceMinor,
	)
	if err != nil {
		rtx.Rollback()
		return nil, err
	}
	// Buyer email prefills Stripe's hosted Checkout page (customer_email).
	// Read inside the same read tx; a missing row just leaves it blank.
	var buyerEmail string
	_ = rtx.QueryRowContext(ctx,
		`SELECT email FROM users WHERE id = ?`, userID).Scan(&buyerEmail)
	rtx.Rollback()
	finalMinor := prod.priceMinor - discountMinor

	purchaseID := NewID()

	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return nil, ErrStripeNotConfigured
		}
		return nil, fmt.Errorf("load stripe keys: %w", err)
	}
	sess, err := s.gateway.CreateCheckoutSession(ctx, keys.SecretKey, payments.CheckoutParams{
		AmountMinor:    int64(finalMinor),
		Currency:       prod.currency,
		ProductName:    prod.name,
		SuccessURL:     successURL,
		CancelURL:      cancelURL,
		IdempotencyKey: purchaseID,
		Email:          buyerEmail,
		Metadata: map[string]string{
			"purchase_id": purchaseID,
			"studio_id":   studioID,
			"user_id":     userID,
		},
	})
	if err != nil {
		return nil, fmt.Errorf("stripe checkout session: %w", err)
	}

	var discountIDArg any
	if discountID != "" {
		discountIDArg = discountID
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO purchases
		  (id, studio_id, user_id, product_id, enrollment_id, list_price_minor, amount_minor,
		   discount_minor, discount_id, currency,
		   payment_method, initiated_by, actor_role, status,
		   stripe_payment_id)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'student', 'pending', ?)`,
		purchaseID, studioID, userID, productID, nullableString(enrollmentID),
		prod.priceMinor, finalMinor, discountMinor, discountIDArg, prod.currency,
		"card", userID, sess.ID,
	); err != nil {
		return nil, fmt.Errorf("insert pending checkout purchase: %w", err)
	}
	if err := writePurchaseAuditTx(ctx, s, tx, studioID, userID, purchaseID, prod,
		finalMinor, discountMinor, discountCode, "card", true); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &CheckoutResult{PurchaseID: purchaseID, URL: sess.URL}, nil
}

// ConfirmPurchaseBySession fulfils a hosted-Checkout purchase from the
// checkout.session.completed webhook. It resolves the pending purchase by the
// session id, swaps stripe_payment_id from the session (cs_…) to the real
// PaymentIntent (pi_…) so refunds can target it, then finalises through the
// same idempotent helper the other paths use. ErrNotFound when no purchase
// matches the session.
func (s *Store) ConfirmPurchaseBySession(ctx context.Context, studioID, sessionID, paymentIntentID string) (string, error) {
	var userID, purchaseID string
	err := s.db.QueryRowContext(ctx, `
		SELECT user_id, id FROM purchases
		 WHERE studio_id = ? AND stripe_payment_id = ?`,
		studioID, sessionID,
	).Scan(&userID, &purchaseID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	if paymentIntentID != "" {
		if _, err := tx.ExecContext(ctx,
			`UPDATE purchases SET stripe_payment_id = ? WHERE id = ?`,
			paymentIntentID, purchaseID,
		); err != nil {
			return "", fmt.Errorf("link payment intent: %w", err)
		}
	}
	entitlementID, err := finalizePendingTx(ctx, s, tx, studioID, userID, purchaseID, "checkout")
	if err != nil {
		return "", err
	}
	return entitlementID, tx.Commit()
}

// ConfirmCheckoutSessionForUser is the WEB optimistic-confirm path — parity
// with the mobile /confirm. On returning from hosted Checkout the client calls
// this with the session id; we verify the session is paid against Stripe and
// mint the pass immediately rather than waiting on the webhook (which stays the
// authoritative backstop). This makes a web purchase complete even when no
// webhook is configured (e.g. local dev) and removes the race where the browser
// returns before the webhook lands.
//
// Returns (entitlementID, completed=true) once minted; ("", false, nil) when
// payment isn't settled yet (the client should keep polling); ErrNotFound when
// no pending purchase matches the session for this user (e.g. the webhook
// already fulfilled it and swapped cs_→pi_ — the client falls back to its
// entitlement poll).
func (s *Store) ConfirmCheckoutSessionForUser(ctx context.Context, studioID, userID, sessionID string) (string, bool, error) {
	if s.gateway == nil {
		return "", false, fmt.Errorf("payments gateway not configured")
	}
	lookup := func(payID string) (ownerID, status string, entID sql.NullString, err error) {
		err = s.db.QueryRowContext(ctx, `
			SELECT user_id, status, resulting_entitlement_id
			  FROM purchases WHERE studio_id = ? AND stripe_payment_id = ?`,
			studioID, payID,
		).Scan(&ownerID, &status, &entID)
		return
	}
	ownerID, status, entID, err := lookup(sessionID)
	if errors.Is(err, sql.ErrNoRows) {
		// The checkout.session.completed webhook may have already fulfilled this
		// and swapped stripe_payment_id from the cs_ session id to the pi_
		// PaymentIntent (so refunds can target it) — leaving the cs_ lookup
		// empty. Re-resolve via the session's PaymentIntent so we still return
		// the minted entitlement instead of a misleading "unknown".
		keys, kerr := s.LoadStripeKeysForUse(ctx, studioID)
		if kerr != nil {
			if errors.Is(kerr, ErrNotFound) {
				return "", false, ErrStripeNotConfigured
			}
			return "", false, fmt.Errorf("load stripe keys: %w", kerr)
		}
		sess, serr := s.gateway.GetCheckoutSession(ctx, keys.SecretKey, sessionID)
		if serr != nil {
			return "", false, fmt.Errorf("retrieve checkout session: %w", serr)
		}
		if sess.IntentID == "" {
			return "", false, ErrNotFound
		}
		ownerID, status, entID, err = lookup(sess.IntentID)
		if errors.Is(err, sql.ErrNoRows) {
			return "", false, ErrNotFound
		}
	}
	if err != nil {
		return "", false, err
	}
	// Ownership: a student may only confirm their own checkout.
	if ownerID != userID {
		return "", false, ErrNotFound
	}
	if status == "completed" {
		return entID.String, true, nil // idempotent — already fulfilled
	}
	if status != "pending" {
		return "", false, fmt.Errorf("purchase is %s", status)
	}

	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return "", false, ErrStripeNotConfigured
		}
		return "", false, fmt.Errorf("load stripe keys: %w", err)
	}
	st, err := s.gateway.GetCheckoutSession(ctx, keys.SecretKey, sessionID)
	if err != nil {
		return "", false, fmt.Errorf("retrieve checkout session: %w", err)
	}
	if st.PaymentStatus != "paid" {
		return "", false, nil // not settled yet — async method or still processing
	}
	entitlementID, err := s.ConfirmPurchaseBySession(ctx, studioID, sessionID, st.IntentID)
	if err != nil {
		return "", false, err
	}
	return entitlementID, true, nil
}

// ReflectStripeRefund records a refund that happened in Stripe (e.g. a manager
// refunded from the Dashboard) on the money side of the purchase. It does NOT
// touch the entitlement — consistent with RefundPurchase, money and pass are
// separate decisions. Idempotent: re-reflecting the same cumulative amount is a
// no-op. The pass stays until a manager explicitly voids it.
func (s *Store) ReflectStripeRefund(ctx context.Context, studioID, intentID string, amountRefundedMinor int64, fully bool) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var purchaseID, userID, status string
	var alreadyRefunded int
	err = tx.QueryRowContext(ctx, `
		SELECT id, user_id, status, refund_amount_minor
		  FROM purchases WHERE studio_id = ? AND stripe_payment_id = ?`,
		studioID, intentID,
	).Scan(&purchaseID, &userID, &status, &alreadyRefunded)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if int(amountRefundedMinor) <= alreadyRefunded {
		return nil // nothing new to record
	}
	newStatus := status
	if fully {
		newStatus = "refunded"
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE purchases
		   SET refund_amount_minor = ?,
		       refunded_at = COALESCE(refunded_at, strftime('%Y-%m-%dT%H:%M:%fZ','now')),
		       status = ?
		 WHERE id = ?`,
		amountRefundedMinor, newStatus, purchaseID,
	); err != nil {
		return fmt.Errorf("reflect refund: %w", err)
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"purchase_refund", "purchase", purchaseID, map[string]any{
			"total_refunded": amountRefundedMinor,
			"final_status":   newStatus,
			"via":            "stripe_dashboard",
		}); err != nil {
		return fmt.Errorf("audit reflect refund: %w", err)
	}
	return tx.Commit()
}
