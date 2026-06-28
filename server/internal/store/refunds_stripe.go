package store

import (
	"context"
	"fmt"
	"strings"
)

// issueStripeRefund issues a real Stripe refund for a card-backed purchase.
// It's a no-op for cash / comp / dev_stub purchases (settled out of band) and
// when no gateway is wired (local dev). A checkout purchase is refundable once
// completed — by then its stripe_payment_id has been swapped from the cs_
// session id to the real pi_ intent. idempotencyKey makes a retried refund
// safe (Stripe returns the same refund rather than paying out twice).
func (s *Store) issueStripeRefund(ctx context.Context, studioID, stripePaymentID string, amountMinor int, idempotencyKey string) error {
	if s.gateway == nil ||
		!strings.HasPrefix(stripePaymentID, "pi_") ||
		strings.HasPrefix(stripePaymentID, "pi_stub_") {
		return nil
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		return fmt.Errorf("load stripe keys for refund: %w", err)
	}
	if _, err := s.gateway.Refund(ctx, keys.SecretKey, stripePaymentID, int64(amountMinor), idempotencyKey); err != nil {
		return fmt.Errorf("stripe refund: %w", err)
	}
	return nil
}
