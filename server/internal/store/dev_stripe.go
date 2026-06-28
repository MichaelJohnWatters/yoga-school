package store

import (
	"context"
	"fmt"
)

// ConfigureTestStripeKeys is a dev/test-only helper that points a studio at the
// given Stripe test keys, so integration tests can exercise the real Checkout
// flow against Stripe test mode. It picks a manager in the studio as the audit
// actor. Requires the server to have a Sealer (STRIPE_KEY_ENC_MASTER set) —
// otherwise secret writes are refused, surfacing a clear error to the caller.
func (s *Store) ConfigureTestStripeKeys(ctx context.Context, studioID, secretKey, publishableKey, webhookSecret string) error {
	var actorID string
	if err := s.db.QueryRowContext(ctx,
		`SELECT id FROM users WHERE studio_id = ? AND role = 'manager' LIMIT 1`,
		studioID,
	).Scan(&actorID); err != nil {
		return fmt.Errorf("find manager for %s: %w", studioID, err)
	}
	mode := "test"
	patch := StripeCredentialsPatch{Mode: &mode}
	if secretKey != "" {
		patch.SecretKey = &secretKey
	}
	if publishableKey != "" {
		patch.PublishableKey = &publishableKey
	}
	if webhookSecret != "" {
		patch.WebhookSecret = &webhookSecret
	}
	_, err := s.UpdateStripeCredentials(ctx, studioID, actorID, patch)
	return err
}
