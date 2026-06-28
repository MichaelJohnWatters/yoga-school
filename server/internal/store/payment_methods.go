package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// lookupStripeCustomer returns the studio's cached cus_… for the user, or ""
// (no error) when they don't have one yet. Unlike ensureStripeCustomer it never
// creates one — used by read/detach paths that shouldn't mint a customer just
// to find they have no cards.
func (s *Store) lookupStripeCustomer(ctx context.Context, studioID, userID string) (string, error) {
	var id string
	err := s.db.QueryRowContext(ctx,
		`SELECT stripe_customer_id FROM stripe_customers WHERE studio_id = ? AND user_id = ?`,
		studioID, userID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// ListMyPaymentMethods returns the user's saved cards. Empty (not an error)
// when they have no Stripe customer yet — e.g. they've never bought anything.
func (s *Store) ListMyPaymentMethods(ctx context.Context, studioID, userID string) ([]payments.PaymentMethod, error) {
	if s.gateway == nil {
		return nil, fmt.Errorf("payments gateway not configured")
	}
	custID, err := s.lookupStripeCustomer(ctx, studioID, userID)
	if err != nil {
		return nil, err
	}
	if custID == "" {
		return []payments.PaymentMethod{}, nil
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return nil, ErrStripeNotConfigured
		}
		return nil, fmt.Errorf("load stripe keys: %w", err)
	}
	return s.gateway.ListPaymentMethods(ctx, keys.SecretKey, custID)
}

// SetupIntentForCard creates a SetupIntent to save a card with no charge — the
// native PaymentSheet "Add card" surface. Ensures the customer first and
// returns its id too (the PaymentSheet needs it alongside an ephemeral key).
func (s *Store) SetupIntentForCard(ctx context.Context, studioID, userID, email string) (clientSecret, customerID string, err error) {
	if s.gateway == nil {
		return "", "", fmt.Errorf("payments gateway not configured")
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return "", "", ErrStripeNotConfigured
		}
		return "", "", fmt.Errorf("load stripe keys: %w", err)
	}
	custID, err := s.ensureStripeCustomer(ctx, keys.SecretKey, studioID, userID, email)
	if err != nil {
		return "", "", err
	}
	secret, err := s.gateway.CreateSetupIntent(ctx, keys.SecretKey, custID)
	if err != nil {
		return "", "", err
	}
	return secret, custID, nil
}

// SetupCheckoutForCard creates a hosted setup-mode Checkout to save a card —
// the web "Add card" surface. Returns the URL to redirect the browser to.
func (s *Store) SetupCheckoutForCard(ctx context.Context, studioID, userID, email, successURL, cancelURL string) (string, error) {
	if s.gateway == nil {
		return "", fmt.Errorf("payments gateway not configured")
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return "", ErrStripeNotConfigured
		}
		return "", fmt.Errorf("load stripe keys: %w", err)
	}
	custID, err := s.ensureStripeCustomer(ctx, keys.SecretKey, studioID, userID, email)
	if err != nil {
		return "", err
	}
	return s.gateway.CreateSetupCheckoutSession(ctx, keys.SecretKey, custID, successURL, cancelURL)
}

// DetachMyPaymentMethod removes one of the user's saved cards. ErrNotFound when
// they have no customer; the gateway verifies the card is actually theirs
// before detaching, so a forged id can't remove someone else's card.
func (s *Store) DetachMyPaymentMethod(ctx context.Context, studioID, userID, paymentMethodID string) error {
	if s.gateway == nil {
		return fmt.Errorf("payments gateway not configured")
	}
	custID, err := s.lookupStripeCustomer(ctx, studioID, userID)
	if err != nil {
		return err
	}
	if custID == "" {
		return ErrNotFound
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return ErrStripeNotConfigured
		}
		return fmt.Errorf("load stripe keys: %w", err)
	}
	return s.gateway.DetachPaymentMethod(ctx, keys.SecretKey, custID, paymentMethodID)
}
