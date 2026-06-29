package store

import (
	"context"
	"errors"
	"fmt"
)

// ErrWebhookSignature means the payload failed Stripe signature verification
// against the studio's webhook secret. The API layer maps it to 400 — a forged
// or malformed event must never be retried or trusted.
var ErrWebhookSignature = errors.New("invalid stripe webhook signature")

// HandleStripeEvent verifies a raw webhook payload against the studio's signing
// secret and applies it. This is the authoritative fulfilment path: even if the
// client never POSTs /confirm, payment_intent.succeeded lands a pass here.
//
// Error contract for the caller:
//   - ErrWebhookSignature → 400 (forged/garbled; do not retry).
//   - any other error     → 5xx so Stripe redelivers. Safe to retry because
//     the underlying confirm/void are idempotent.
//   - nil                 → 200 (handled, deduped, or an event type we ignore).
//
// Dedup: we record each event id in processed_stripe_events and skip ones we've
// already seen. It's an optimisation on top of idempotent fulfilment — a
// redelivery that races the dedup check still can't double-grant, because
// ConfirmPurchaseByIntent converges on a single entitlement.
func (s *Store) HandleStripeEvent(ctx context.Context, studioID string, payload []byte, sigHeader string) error {
	if s.gateway == nil {
		return fmt.Errorf("payments gateway not configured")
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		return fmt.Errorf("load stripe keys for webhook: %w", err)
	}
	if keys.WebhookSecret == "" {
		return fmt.Errorf("studio %s has no webhook secret configured", studioID)
	}

	evt, err := s.gateway.VerifyWebhook(payload, sigHeader, keys.WebhookSecret)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrWebhookSignature, err)
	}

	// Already processed? Cheap no-op.
	var seen int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM processed_stripe_events WHERE event_id = ?`, evt.ID,
	).Scan(&seen); err != nil {
		return fmt.Errorf("dedup lookup: %w", err)
	}
	if seen > 0 {
		return nil
	}

	switch evt.Type {
	case "checkout.session.completed":
		// Subscription checkout → link the membership; the entitlement is
		// granted by invoice.paid (single grant path).
		if evt.SessionMode == "subscription" {
			if err := s.ActivateSubscriptionBySession(ctx, studioID, evt.SessionID,
				evt.SubscriptionID, evt.CustomerID); err != nil &&
				!errors.Is(err, ErrNotFound) {
				return err
			}
			break
		}
		// Web (hosted Checkout) one-time success — authoritative fulfilment.
		// Only act when actually paid (async methods can complete unpaid).
		if evt.Status == "" || evt.Status == "paid" {
			_, err := s.ConfirmPurchaseBySession(ctx, studioID, evt.SessionID, evt.IntentID)
			if errors.Is(err, ErrSeriesFull) {
				// Series filled before payment landed — refund + notify.
				if rerr := s.refundFullEnrollment(ctx, studioID, evt.SessionID, evt.IntentID); rerr != nil {
					return rerr
				}
			} else if err != nil && !errors.Is(err, ErrNotFound) {
				return err
			}
		}
	case "invoice.paid":
		// Membership payment (initial or renewal) → grant/extend the pass.
		if err := s.RecordInvoicePaid(ctx, studioID, evt); err != nil &&
			!errors.Is(err, ErrNotFound) {
			return err
		}
	case "invoice.payment_failed":
		// Dunning — mark past_due; access rides its grace then sweeps.
		if err := s.RecordInvoiceFailed(ctx, studioID, evt); err != nil &&
			!errors.Is(err, ErrNotFound) {
			return err
		}
	case "customer.subscription.updated":
		if err := s.UpdateSubscriptionStatus(ctx, studioID, evt); err != nil &&
			!errors.Is(err, ErrNotFound) {
			return err
		}
	case "customer.subscription.deleted":
		if err := s.CancelSubscriptionRecord(ctx, studioID, evt); err != nil &&
			!errors.Is(err, ErrNotFound) {
			return err
		}
	case "checkout.session.expired":
		// The session lapsed before payment — void the pending purchase. The
		// purchase still holds the session id in stripe_payment_id.
		if err := s.VoidPurchaseByIntent(ctx, studioID, evt.SessionID, evt.Type); err != nil &&
			!errors.Is(err, ErrNotFound) {
			return err
		}
	case "payment_intent.succeeded":
		// Mobile (PaymentSheet) success.
		_, err := s.ConfirmPurchaseByIntent(ctx, studioID, evt.IntentID)
		if errors.Is(err, ErrSeriesFull) {
			if rerr := s.refundFullEnrollment(ctx, studioID, evt.IntentID, evt.IntentID); rerr != nil {
				return rerr
			}
		} else if err != nil && !errors.Is(err, ErrNotFound) {
			return err
		}
	case "payment_intent.payment_failed", "payment_intent.canceled":
		if err := s.VoidPurchaseByIntent(ctx, studioID, evt.IntentID, evt.Type); err != nil &&
			!errors.Is(err, ErrNotFound) {
			return err
		}
	case "charge.refunded":
		// A refund happened in Stripe (likely the Dashboard). Reflect the money
		// side; the pass is left for an explicit manager decision.
		if err := s.ReflectStripeRefund(ctx, studioID, evt.IntentID,
			evt.AmountRefundedMinor, evt.FullyRefunded); err != nil &&
			!errors.Is(err, ErrNotFound) {
			return err
		}
	case "charge.dispute.created", "charge.dispute.updated", "charge.dispute.closed":
		// A chargeback. Record it on the purchase + alert the managers; never
		// auto-revoke the pass (money ≠ pass) — that's a manager decision on the
		// "Payments needing attention" screen.
		if err := s.RecordDispute(ctx, studioID, evt); err != nil &&
			!errors.Is(err, ErrNotFound) {
			return err
		}
	default:
		// Event type we don't act on — still record + 200 it so Stripe stops
		// retrying.
	}

	// Record only after successful handling: if fulfilment 5xx'd above we want
	// Stripe to retry (and the dedup row absent so the retry runs).
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO processed_stripe_events (event_id, studio_id, event_type)
		VALUES (?, ?, ?)
		ON CONFLICT(event_id) DO NOTHING`,
		evt.ID, studioID, evt.Type,
	); err != nil {
		return fmt.Errorf("record processed event: %w", err)
	}
	return nil
}
