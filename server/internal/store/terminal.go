package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// TerminalReader is a smart card reader registered to a studio for in-person
// (Stripe Terminal) payments. We cache only the ids — the hardware and card
// data live in Stripe.
type TerminalReader struct {
	ReaderID   string `json:"reader_id"`
	LocationID string `json:"location_id"`
	Label      string `json:"label"`
	CreatedAt  string `json:"created_at"`
}

// TerminalChargeResult is returned after kicking off an in-person sale. The
// purchase is 'pending'; the reader collects the card and the
// payment_intent.succeeded webhook mints the pass — the same fulfilment path as
// online card sales.
type TerminalChargeResult struct {
	PurchaseID  string `json:"purchase_id"`
	ReaderID    string `json:"reader_id"`
	AmountMinor int    `json:"amount_minor"`
	Currency    string `json:"currency"`
}

// RegisterTerminalReader registers a reader to the studio using the pairing
// code shown on the device. The first reader lazily creates a Stripe Terminal
// Location (named after the studio); later readers reuse it. Audited.
func (s *Store) RegisterTerminalReader(ctx context.Context, studioID, actorID, registrationCode, label string) (*TerminalReader, error) {
	if s.gateway == nil {
		return nil, fmt.Errorf("payments gateway not configured")
	}
	if registrationCode == "" {
		return nil, fmt.Errorf("registration_code is required")
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return nil, ErrStripeNotConfigured
		}
		return nil, fmt.Errorf("load stripe keys: %w", err)
	}

	// Reuse the studio's existing Location if it has one; else create it.
	var locationID string
	err = s.db.QueryRowContext(ctx,
		`SELECT location_id FROM terminal_readers WHERE studio_id = ? LIMIT 1`,
		studioID,
	).Scan(&locationID)
	if errors.Is(err, sql.ErrNoRows) {
		var studioName string
		_ = s.db.QueryRowContext(ctx,
			`SELECT name FROM studios WHERE id = ?`, studioID).Scan(&studioName)
		// Country defaults to GB in the gateway; per-studio country can be
		// threaded later from the studio's merchant settings.
		locationID, err = s.gateway.CreateTerminalLocation(ctx, keys.SecretKey, studioName, "")
		if err != nil {
			return nil, fmt.Errorf("create terminal location: %w", err)
		}
	} else if err != nil {
		return nil, err
	}

	readerID, err := s.gateway.RegisterTerminalReader(ctx, keys.SecretKey, locationID, registrationCode, label)
	if err != nil {
		return nil, fmt.Errorf("register reader: %w", err)
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO terminal_readers (studio_id, reader_id, location_id, label)
		  VALUES (?, ?, ?, ?)`,
		studioID, readerID, locationID, nullableString(label),
	); err != nil {
		return nil, fmt.Errorf("insert reader: %w", err)
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		"terminal_reader_register", "terminal_reader", readerID, map[string]any{
			"label":       label,
			"location_id": locationID,
		}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &TerminalReader{ReaderID: readerID, LocationID: locationID, Label: label}, nil
}

// ListTerminalReaders returns the studio's registered readers.
func (s *Store) ListTerminalReaders(ctx context.Context, studioID string) ([]TerminalReader, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT reader_id, location_id, COALESCE(label,''), created_at
		  FROM terminal_readers WHERE studio_id = ? ORDER BY created_at`,
		studioID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]TerminalReader, 0)
	for rows.Next() {
		var r TerminalReader
		if err := rows.Scan(&r.ReaderID, &r.LocationID, &r.Label, &r.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// RemoveTerminalReader forgets a reader (drops our cached row + audits). It
// leaves the reader registered in Stripe — harmless, and re-adding reuses it.
func (s *Store) RemoveTerminalReader(ctx context.Context, studioID, actorID, readerID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx,
		`DELETE FROM terminal_readers WHERE studio_id = ? AND reader_id = ?`,
		studioID, readerID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		"terminal_reader_remove", "terminal_reader", readerID, nil); err != nil {
		return err
	}
	return tx.Commit()
}

// ChargeInPerson starts an in-person sale: it records a 'pending' purchase,
// creates a card_present PaymentIntent attached to the buyer's Customer, and
// hands it to the reader to collect. Fulfilment is the existing
// payment_intent.succeeded webhook — this never mints the pass directly.
// Mirrors CreatePendingPurchase's server-computed-amount + discount handling.
func (s *Store) ChargeInPerson(ctx context.Context, studioID, actorID, userID, productID, discountCode, readerID string) (*TerminalChargeResult, error) {
	if s.gateway == nil {
		return nil, fmt.Errorf("payments gateway not configured")
	}
	// The reader must belong to this studio.
	var present int
	_ = s.db.QueryRowContext(ctx,
		`SELECT 1 FROM terminal_readers WHERE studio_id = ? AND reader_id = ?`,
		studioID, readerID).Scan(&present)
	if present == 0 {
		return nil, ErrNotFound
	}

	// Validate (read-only). Amount is server-computed, never client-sent.
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
		ctx, rtx, studioID, userID, productID, discountCode, prod.priceMinor)
	if err != nil {
		rtx.Rollback()
		return nil, err
	}
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
	customerID, err := s.ensureStripeCustomer(ctx, keys.SecretKey, studioID, userID, buyerEmail)
	if err != nil {
		return nil, fmt.Errorf("ensure stripe customer: %w", err)
	}
	intent, err := s.gateway.CreateCardPresentIntent(ctx, keys.SecretKey, payments.CardPresentParams{
		AmountMinor:    int64(finalMinor),
		Currency:       prod.currency,
		Customer:       customerID,
		IdempotencyKey: purchaseID,
		Metadata: map[string]string{
			"purchase_id": purchaseID,
			"studio_id":   studioID,
			"user_id":     userID,
		},
	})
	if err != nil {
		return nil, fmt.Errorf("create card_present intent: %w", err)
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
		  (id, studio_id, user_id, product_id, list_price_minor, amount_minor,
		   discount_minor, discount_id, currency,
		   payment_method, initiated_by, actor_role, status, stripe_payment_id)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'card_present', ?, 'manager', 'pending', ?)`,
		purchaseID, studioID, userID, productID,
		prod.priceMinor, finalMinor, discountMinor, discountIDArg, prod.currency,
		actorID, intent.ID,
	); err != nil {
		return nil, fmt.Errorf("insert pending purchase: %w", err)
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		"terminal_charge", "purchase", purchaseID, map[string]any{
			"reader_id":    readerID,
			"product_id":   productID,
			"amount_minor": finalMinor,
			"for_user":     userID,
		}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	// Hand the intent to the reader (network call, outside the write tx). If it
	// fails the purchase stays 'pending' and the reconcile janitor / a webhook
	// payment_intent.payment_failed will void it.
	if err := s.gateway.ProcessPaymentIntentOnReader(ctx, keys.SecretKey, readerID, intent.ID); err != nil {
		return nil, fmt.Errorf("process on reader: %w", err)
	}
	return &TerminalChargeResult{
		PurchaseID:  purchaseID,
		ReaderID:    readerID,
		AmountMinor: finalMinor,
		Currency:    prod.currency,
	}, nil
}

// CancelTerminalCharge aborts a reader's in-progress collection (customer
// walked away / wrong amount). The PaymentIntent cancels, and the existing
// payment_intent.canceled webhook voids the pending purchase.
func (s *Store) CancelTerminalCharge(ctx context.Context, studioID, readerID string) error {
	if s.gateway == nil {
		return fmt.Errorf("payments gateway not configured")
	}
	var present int
	_ = s.db.QueryRowContext(ctx,
		`SELECT 1 FROM terminal_readers WHERE studio_id = ? AND reader_id = ?`,
		studioID, readerID).Scan(&present)
	if present == 0 {
		return ErrNotFound
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return ErrStripeNotConfigured
		}
		return fmt.Errorf("load stripe keys: %w", err)
	}
	return s.gateway.CancelReaderAction(ctx, keys.SecretKey, readerID)
}
