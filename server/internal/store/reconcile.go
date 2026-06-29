package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// ReconcilePendingPurchases is the janitor's safety net for card purchases
// whose fulfilment fell through both the client /confirm and the webhook (a
// dead app AND a missed/mis-configured webhook). It finds pending purchases
// with a real PaymentIntent older than `olderThan`, asks Stripe how each one
// actually resolved, and finishes the job:
//
//   - succeeded                          → ConfirmPurchaseByIntent (mint pass)
//   - processing / requires_capture      → leave (still genuinely in flight)
//   - canceled / requires_* (abandoned)  → VoidPurchaseByIntent
//
// dev_stub rows (pi_stub_…) are skipped — they never had a real intent. Returns
// counts for logging. A nil gateway (local dev without Stripe) is a no-op.
func (s *Store) ReconcilePendingPurchases(ctx context.Context, olderThan time.Duration) (confirmed, voided int, err error) {
	if s.gateway == nil {
		return 0, 0, nil
	}
	cutoff := time.Now().UTC().Add(-olderThan).Format(time.RFC3339)
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, studio_id, stripe_payment_id
		  FROM purchases
		 WHERE status = 'pending'
		   AND stripe_payment_id IS NOT NULL
		   AND stripe_payment_id NOT LIKE 'pi_stub_%'
		   AND created_at < ?`,
		cutoff,
	)
	if err != nil {
		return 0, 0, err
	}
	type pending struct{ studioID, intentID string }
	var todo []pending
	for rows.Next() {
		var id, studioID, intentID string
		if err := rows.Scan(&id, &studioID, &intentID); err != nil {
			rows.Close()
			return confirmed, voided, err
		}
		todo = append(todo, pending{studioID, intentID})
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return confirmed, voided, err
	}
	rows.Close()

	// Cache decrypted keys per studio so a batch of one studio's pending rows
	// doesn't decrypt on every iteration.
	keyCache := map[string]string{}
	secretFor := func(studioID string) (string, error) {
		if k, ok := keyCache[studioID]; ok {
			return k, nil
		}
		keys, err := s.LoadStripeKeysForUse(ctx, studioID)
		if err != nil {
			return "", err
		}
		keyCache[studioID] = keys.SecretKey
		return keys.SecretKey, nil
	}

	for _, p := range todo {
		secret, err := secretFor(p.studioID)
		if err != nil {
			// Can't resolve this studio's keys — skip; next tick retries.
			continue
		}
		intent, err := s.gateway.GetIntent(ctx, secret, p.intentID)
		if err != nil {
			continue
		}
		switch intent.Status {
		case payments.StatusSucceeded:
			if _, err := s.ConfirmPurchaseByIntent(ctx, p.studioID, p.intentID); err != nil &&
				!errors.Is(err, ErrNotFound) {
				continue
			}
			confirmed++
		case "processing", "requires_capture":
			// Still legitimately in flight — leave it for a later tick.
		default:
			// canceled / requires_payment_method / requires_action /
			// requires_confirmation: the customer never completed. Void.
			if err := s.VoidPurchaseByIntent(ctx, p.studioID, p.intentID,
				"reconcile:"+intent.Status); err != nil && !errors.Is(err, ErrNotFound) {
				continue
			}
			voided++
		}
	}
	return confirmed, voided, nil
}

// ReconcileStalePendingCheckouts is the safety net for WEB checkout purchases
// (stripe_payment_id = cs_…) whose checkout.session.expired/completed webhook
// was missed. ReconcilePendingPurchases can't help them — GetIntent doesn't
// accept a session id. For each pending cs_ row older than minAge (use a value
// past Stripe's 24h session lifetime so an unpaid session is definitively
// dead), we ask Stripe how the session resolved: paid → fulfil, otherwise →
// void. A nil gateway is a no-op.
func (s *Store) ReconcileStalePendingCheckouts(ctx context.Context, minAge time.Duration) (confirmed, voided int, err error) {
	if s.gateway == nil {
		return 0, 0, nil
	}
	cutoff := time.Now().UTC().Add(-minAge).Format(time.RFC3339)
	rows, err := s.db.QueryContext(ctx, `
		SELECT studio_id, stripe_payment_id
		  FROM purchases
		 WHERE status = 'pending'
		   AND stripe_payment_id LIKE 'cs_%'
		   AND created_at < ?`,
		cutoff,
	)
	if err != nil {
		return 0, 0, err
	}
	type pending struct{ studioID, sessionID string }
	var todo []pending
	for rows.Next() {
		var p pending
		if err := rows.Scan(&p.studioID, &p.sessionID); err != nil {
			rows.Close()
			return confirmed, voided, err
		}
		todo = append(todo, p)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return confirmed, voided, err
	}
	rows.Close()

	keyCache := map[string]string{}
	for _, p := range todo {
		secret, ok := keyCache[p.studioID]
		if !ok {
			keys, err := s.LoadStripeKeysForUse(ctx, p.studioID)
			if err != nil {
				continue
			}
			secret = keys.SecretKey
			keyCache[p.studioID] = secret
		}
		st, err := s.gateway.GetCheckoutSession(ctx, secret, p.sessionID)
		if err != nil {
			continue
		}
		if st.PaymentStatus == "paid" {
			_, err := s.ConfirmPurchaseBySession(ctx, p.studioID, p.sessionID, st.IntentID)
			if errors.Is(err, ErrSeriesFull) {
				if rerr := s.refundFullEnrollment(ctx, p.studioID, p.sessionID, st.IntentID); rerr != nil {
					continue
				}
			} else if err != nil && !errors.Is(err, ErrNotFound) {
				continue
			}
			confirmed++
			continue
		}
		// Past the session lifetime and not paid → it can never settle. Void.
		if err := s.VoidPurchaseByIntent(ctx, p.studioID, p.sessionID,
			"reconcile:stale_session"); err != nil && !errors.Is(err, ErrNotFound) {
			continue
		}
		voided++
	}
	return confirmed, voided, nil
}

// SweepEntitlements retires the status flags the read path currently derives
// lazily (see wallet.go): active passes past their expiry become 'expired', and
// credit packs with no credits left become 'depleted'. Persisting the status
// keeps reports/queries honest without every reader re-deriving it. Idempotent
// — re-running touches nothing once rows are settled.
func (s *Store) SweepEntitlements(ctx context.Context) (expired, depleted int, err error) {
	now := time.Now().UTC().Format(time.RFC3339)
	res, err := s.db.ExecContext(ctx, `
		UPDATE entitlements
		   SET status = 'expired'
		 WHERE status = 'active'
		   AND expires_at IS NOT NULL
		   AND expires_at < ?`, now)
	if err != nil {
		return 0, 0, fmt.Errorf("sweep expired: %w", err)
	}
	if n, e := res.RowsAffected(); e == nil {
		expired = int(n)
	}
	res, err = s.db.ExecContext(ctx, `
		UPDATE entitlements
		   SET status = 'depleted'
		 WHERE status = 'active'
		   AND pass_kind = 'credit'
		   AND credits_remaining IS NOT NULL
		   AND credits_remaining <= 0`)
	if err != nil {
		return expired, 0, fmt.Errorf("sweep depleted: %w", err)
	}
	if n, e := res.RowsAffected(); e == nil {
		depleted = int(n)
	}
	return expired, depleted, nil
}
