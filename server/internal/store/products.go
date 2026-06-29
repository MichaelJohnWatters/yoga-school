package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

type Product struct {
	ID              string   `json:"id"`
	Name            string   `json:"name"`
	Description     string   `json:"description"`
	PriceMinor      int      `json:"price_minor"`
	Currency        string   `json:"currency"`
	BillingType     string   `json:"billing_type"`
	BillingInterval *string  `json:"billing_interval,omitempty"`
	PassKind        string   `json:"pass_kind"`
	Credits         *int     `json:"credits,omitempty"`
	ValidityDays    *int     `json:"validity_days,omitempty"`
	IsHero          bool     `json:"is_hero"`
	ClassTypeIDs    []string `json:"class_type_ids"`
	DisciplineSet   []string `json:"disciplines"`
}

// ListProducts returns the studio's purchasable products. When
// coversClassTypeID is non-empty, the result is restricted to products that
// include that class type — used by the "buy a pass to take this class"
// flow so the picker only shows passes the student can actually use.
func (s *Store) ListProducts(ctx context.Context, studioID, coversClassTypeID string) ([]Product, error) {
	q := `
		SELECT p.id, p.name, COALESCE(p.description,''), p.price_minor,
		       s.currency, p.billing_type, p.billing_interval, p.pass_kind,
		       p.credits, p.validity_days, p.is_hero
		  FROM products p
		  JOIN studios s ON s.id = p.studio_id
		 WHERE p.studio_id = ? AND p.is_archived = 0`
	args := []any{studioID}
	if coversClassTypeID != "" {
		q += `
		   AND EXISTS (
		     SELECT 1 FROM product_class_types pct
		      WHERE pct.product_id = p.id AND pct.class_type_id = ?
		   )`
		args = append(args, coversClassTypeID)
	}
	q += `
		 ORDER BY p.is_hero DESC, p.display_order ASC, p.created_at ASC`
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	products := make([]Product, 0)
	for rows.Next() {
		var (
			p        Product
			credits  sql.NullInt64
			validity sql.NullInt64
			interval sql.NullString
			heroInt  int
		)
		if err := rows.Scan(
			&p.ID, &p.Name, &p.Description, &p.PriceMinor,
			&p.Currency, &p.BillingType, &interval, &p.PassKind,
			&credits, &validity, &heroInt,
		); err != nil {
			return nil, err
		}
		if credits.Valid {
			n := int(credits.Int64)
			p.Credits = &n
		}
		if validity.Valid {
			n := int(validity.Int64)
			p.ValidityDays = &n
		}
		if interval.Valid {
			v := interval.String
			p.BillingInterval = &v
		}
		p.IsHero = heroInt != 0
		products = append(products, p)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Hydrate class type coverage in one pass.
	if len(products) == 0 {
		return products, nil
	}
	const j = `
		SELECT pct.product_id, ct.id, COALESCE(ct.discipline,'')
		  FROM product_class_types pct
		  JOIN class_types ct ON ct.id = pct.class_type_id
		 WHERE pct.product_id IN (SELECT id FROM products WHERE studio_id = ?)`
	jrows, err := s.db.QueryContext(ctx, j, studioID)
	if err != nil {
		return nil, err
	}
	defer jrows.Close()
	cov := map[string][]string{}
	dis := map[string]map[string]struct{}{}
	for jrows.Next() {
		var pid, ctID, discipline string
		if err := jrows.Scan(&pid, &ctID, &discipline); err != nil {
			return nil, err
		}
		cov[pid] = append(cov[pid], ctID)
		if discipline != "" {
			if dis[pid] == nil {
				dis[pid] = map[string]struct{}{}
			}
			dis[pid][discipline] = struct{}{}
		}
	}
	for i := range products {
		products[i].ClassTypeIDs = cov[products[i].ID]
		for d := range dis[products[i].ID] {
			products[i].DisciplineSet = append(products[i].DisciplineSet, d)
		}
	}
	return products, nil
}

// GetProduct returns one product's full detail (terms, credits, validity,
// billing, class type coverage). Used by GET /products/{id}.
func (s *Store) GetProduct(ctx context.Context, studioID, productID string) (*Product, error) {
	const q = `
		SELECT p.id, p.name, COALESCE(p.description,''), p.price_minor,
		       s.currency, p.billing_type, p.billing_interval, p.pass_kind,
		       p.credits, p.validity_days, p.is_hero
		  FROM products p
		  JOIN studios s ON s.id = p.studio_id
		 WHERE p.id = ? AND p.studio_id = ? AND p.is_archived = 0`
	var (
		p        Product
		credits  sql.NullInt64
		validity sql.NullInt64
		interval sql.NullString
		heroInt  int
	)
	err := s.db.QueryRowContext(ctx, q, productID, studioID).Scan(
		&p.ID, &p.Name, &p.Description, &p.PriceMinor,
		&p.Currency, &p.BillingType, &interval, &p.PassKind,
		&credits, &validity, &heroInt,
	)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if credits.Valid {
		n := int(credits.Int64)
		p.Credits = &n
	}
	if validity.Valid {
		n := int(validity.Int64)
		p.ValidityDays = &n
	}
	if interval.Valid {
		v := interval.String
		p.BillingInterval = &v
	}
	p.IsHero = heroInt != 0

	// Coverage.
	jrows, err := s.db.QueryContext(ctx, `
		SELECT ct.id, COALESCE(ct.discipline,'')
		  FROM product_class_types pct
		  JOIN class_types ct ON ct.id = pct.class_type_id
		 WHERE pct.product_id = ?`, productID)
	if err != nil {
		return nil, err
	}
	defer jrows.Close()
	discSet := map[string]struct{}{}
	for jrows.Next() {
		var ctID, discipline string
		if err := jrows.Scan(&ctID, &discipline); err != nil {
			return nil, err
		}
		p.ClassTypeIDs = append(p.ClassTypeIDs, ctID)
		if discipline != "" {
			discSet[discipline] = struct{}{}
		}
	}
	for d := range discSet {
		p.DisciplineSet = append(p.DisciplineSet, d)
	}
	return &p, nil
}

// productForPurchase holds the snapshot fields CreatePurchase /
// CreatePendingPurchase both need. Kept package-private — only the
// purchase paths read it.
type productForPurchase struct {
	name, currency, billingType, passKind string
	priceMinor                            int
	credits, validityDays                 sql.NullInt64
	stripePriceID                         sql.NullString
}

// loadProductForPurchaseTx fetches the product + studio currency in a
// single round-trip. Errors with a wrapped message that callers can
// surface verbatim to the API.
func loadProductForPurchaseTx(ctx context.Context, tx *sql.Tx, studioID, productID string) (*productForPurchase, error) {
	out := &productForPurchase{}
	if err := tx.QueryRowContext(ctx, `
		SELECT p.name, s.currency, p.billing_type, p.pass_kind,
		       p.price_minor, p.credits, p.validity_days, p.stripe_price_id
		  FROM products p
		  JOIN studios s ON s.id = p.studio_id
		 WHERE p.id = ? AND p.studio_id = ? AND p.is_archived = 0`,
		productID, studioID,
	).Scan(&out.name, &out.currency, &out.billingType, &out.passKind,
		&out.priceMinor, &out.credits, &out.validityDays, &out.stripePriceID,
	); err != nil {
		return nil, fmt.Errorf("product lookup: %w", err)
	}
	return out, nil
}

// insertEntitlementSnapshotTx mints an entitlement row + class-type
// coverage from the product snapshot. Returns the new entitlement id.
// Snapshots are deliberate — a later product edit must not rewrite this
// row's coverage or terms.
func insertEntitlementSnapshotTx(ctx context.Context, tx *sql.Tx, studioID, userID, productID string, prod *productForPurchase) (string, error) {
	entitlementID := NewID()
	var creditsTotal, creditsRemaining any
	if prod.credits.Valid {
		creditsTotal = int(prod.credits.Int64)
		creditsRemaining = int(prod.credits.Int64)
	}
	var expiresAt any
	if prod.validityDays.Valid {
		expiresAt = time.Now().UTC().
			Add(time.Duration(prod.validityDays.Int64) * 24 * time.Hour).
			Format(time.RFC3339)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO entitlements
		  (id, studio_id, user_id, source_product_id, pass_kind, label,
		   credits_total, credits_remaining, expires_at, status)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')`,
		entitlementID, studioID, userID, productID, prod.passKind, prod.name,
		creditsTotal, creditsRemaining, expiresAt,
	); err != nil {
		return "", fmt.Errorf("insert entitlement: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO entitlement_class_types (entitlement_id, class_type_id)
		  SELECT ?, class_type_id FROM product_class_types WHERE product_id = ?`,
		entitlementID, productID,
	); err != nil {
		return "", fmt.Errorf("snapshot class types: %w", err)
	}
	return entitlementID, nil
}

// CreatePurchase records a purchase + entitlement synchronously. Use this
// for payment methods that don't need a confirmation step: cash, comp,
// card_present, dev_stub. For Stripe card payments call CreatePendingPurchase
// then ConfirmPurchase once the PaymentIntent reports succeeded.
//
// discountCode is optional — pass "" to skip. When set, it's validated
// inside the same tx as the purchase insert so a code that's exhausted
// between check and write can't slip through. Returns a BookingError
// with the discount_* codes from validateAndApplyDiscountTx if the code
// is invalid, expired, or used up.
func (s *Store) CreatePurchase(
	ctx context.Context,
	studioID, userID, productID, paymentMethod, discountCode string,
) (string, string, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()

	prod, err := loadProductForPurchaseTx(ctx, tx, studioID, productID)
	if err != nil {
		return "", "", err
	}
	discountID, discountMinor, err := validateAndApplyDiscountTx(
		ctx, tx, studioID, userID, productID, discountCode, prod.priceMinor,
	)
	if err != nil {
		return "", "", err
	}
	finalMinor := prod.priceMinor - discountMinor

	entitlementID, err := insertEntitlementSnapshotTx(ctx, tx, studioID, userID, productID, prod)
	if err != nil {
		return "", "", err
	}
	purchaseID := NewID()
	var discountIDArg any
	if discountID != "" {
		discountIDArg = discountID
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO purchases
		  (id, studio_id, user_id, product_id, list_price_minor, amount_minor,
		   discount_minor, discount_id, currency,
		   payment_method, initiated_by, actor_role, status,
		   resulting_entitlement_id)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'student', 'completed', ?)`,
		purchaseID, studioID, userID, productID,
		prod.priceMinor, finalMinor, discountMinor, discountIDArg, prod.currency,
		paymentMethod, userID, entitlementID,
	); err != nil {
		return "", "", fmt.Errorf("insert purchase: %w", err)
	}
	// Audit the purchase so it lands on the activity log alongside other
	// student-initiated events. Records the human-readable product name +
	// what they actually paid (after any discount) so the log doesn't
	// need to follow IDs to render the row.
	if err := writePurchaseAuditTx(ctx, s, tx, studioID, userID, purchaseID, prod,
		finalMinor, discountMinor, discountCode, paymentMethod, false); err != nil {
		return "", "", err
	}
	return purchaseID, entitlementID, tx.Commit()
}

// writePurchaseAuditTx is the shared audit emitter for the three
// purchase paths (sync CreatePurchase, pending CreatePendingPurchase,
// confirm ConfirmPurchase). pending=true tags rows where the money
// hasn't settled yet (Stripe intent created but not confirmed) — the
// confirm path writes a separate purchase_confirm row when it succeeds.
func writePurchaseAuditTx(
	ctx context.Context,
	s *Store,
	tx *sql.Tx,
	studioID, userID, purchaseID string,
	prod *productForPurchase,
	finalMinor, discountMinor int,
	discountCode, paymentMethod string,
	pending bool,
) error {
	action := "purchase"
	if pending {
		action = "purchase_pending"
	}
	detail := map[string]any{
		"product_name":   prod.name,
		"pass_kind":      prod.passKind,
		"amount_minor":   finalMinor,
		"currency":       prod.currency,
		"payment_method": paymentMethod,
	}
	if discountMinor > 0 {
		detail["discount_minor"] = discountMinor
	}
	if discountCode != "" {
		detail["discount_code"] = discountCode
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		action, "purchase", purchaseID, detail); err != nil {
		return fmt.Errorf("audit %s: %w", action, err)
	}
	return nil
}

// ============================================================================
// STRIPE WIRING
// ============================================================================
//
// Card payments flow through the studio's Stripe account via the
// payments.Gateway wired on the Store (SetPaymentGateway). When the gateway is
// nil (local dev / tests) the dev_stub path takes over: CreatePendingPurchase
// mints placeholder pi_stub_ ids and ConfirmPurchase skips verification.
//
// Lifecycle:
//   1. CreatePendingPurchase → gateway.CreateIntent (idempotency key =
//      purchase_id) → returns client_secret for Stripe.js / PaymentSheet.
//   2. Stripe collects + confirms the card on the client.
//   3a. Webhook payment_intent.succeeded → ConfirmPurchaseByIntent  (authoritative)
//   3b. Client POST /confirm → ConfirmPurchase (verifies via gateway.GetIntent,
//       then finalises) — optimistic, just for instant UX.
//   Both 3a and 3b call finalizePendingTx and are idempotent: they converge on
//   one entitlement no matter the order or how many times they fire.
//
// Multi-tenant: keys are resolved per call via LoadStripeKeysForUse — there is
// no process-global stripe.Key.
// ============================================================================

// PendingPurchaseResult is what CreatePendingPurchase returns. The client
// uses ClientSecret with Stripe.js (Elements, PaymentSheet) to collect card
// details, then calls POST /purchases/{id}/confirm.
type PendingPurchaseResult struct {
	PurchaseID      string `json:"purchase_id"`
	AmountMinor     int    `json:"amount_minor"`
	Currency        string `json:"currency"`
	StripePaymentID string `json:"stripe_payment_id"`
	ClientSecret    string `json:"client_secret"`
	// StripeCustomerID (cus_…) is the buyer's Customer the intent is attached
	// to. The client pairs it with an ephemeral key to show saved cards in the
	// PaymentSheet. Empty on the dev_stub path (no gateway).
	StripeCustomerID string `json:"stripe_customer_id,omitempty"`
}

// CreatePendingPurchase records a purchase in 'pending' state without
// minting the entitlement. Production replaces the stub stripe_payment_id +
// client_secret with values from a real Stripe PaymentIntents.Create call —
// the slot is intentional so wiring in the SDK later is a one-file change.
//
// Until then, the dev stub lets the rest of the system (clients, tests,
// reports) talk to the intent flow end-to-end.
func (s *Store) CreatePendingPurchase(
	ctx context.Context,
	studioID, userID, productID, paymentMethod, discountCode, enrollmentID string,
) (*PendingPurchaseResult, error) {
	// Phase 1 — validate (read-only). We resolve the product, currency and
	// discount up front so the amount we hand Stripe is server-computed, never
	// trusted from the client. Pending purchases don't count toward a
	// discount's usage (that's counted on 'completed' rows in
	// validateAndApplyDiscountTx), so doing this read separately from the
	// insert below can't leak a single-use code.
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
	// Buyer email → the PaymentIntent's receipt_email so Stripe's receipt
	// reaches them. Read in the same read tx; a missing row leaves it blank.
	var buyerEmail string
	_ = rtx.QueryRowContext(ctx,
		`SELECT email FROM users WHERE id = ?`, userID).Scan(&buyerEmail)
	rtx.Rollback()
	finalMinor := prod.priceMinor - discountMinor

	purchaseID := NewID()

	// Phase 2 — create the PaymentIntent. Done outside any DB transaction so
	// the (single-connection) SQLite write lock isn't held across a network
	// call. The gateway is nil in dev/tests → dev_stub placeholders. The
	// purchase_id doubles as the Stripe idempotency key, so a double-tap or
	// retry returns the same intent instead of charging twice.
	var stripePaymentID, clientSecret, stripeCustomerID string
	if s.gateway != nil {
		keys, err := s.LoadStripeKeysForUse(ctx, studioID)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				return nil, ErrStripeNotConfigured
			}
			return nil, fmt.Errorf("load stripe keys: %w", err)
		}
		// Attach the buyer's Customer so the PaymentSheet can show their saved
		// cards and offer to save this one. Reuses the same (studio,user)→cus_
		// cache the subscription flow created.
		stripeCustomerID, err = s.ensureStripeCustomer(ctx, keys.SecretKey, studioID, userID, buyerEmail)
		if err != nil {
			return nil, fmt.Errorf("ensure stripe customer: %w", err)
		}
		intent, err := s.gateway.CreateIntent(ctx, keys.SecretKey, payments.IntentParams{
			AmountMinor:    int64(finalMinor),
			Currency:       prod.currency,
			IdempotencyKey: purchaseID,
			Email:          buyerEmail,
			Customer:       stripeCustomerID,
			Metadata: map[string]string{
				"purchase_id": purchaseID,
				"studio_id":   studioID,
				"user_id":     userID,
			},
		})
		if err != nil {
			return nil, fmt.Errorf("stripe create intent: %w", err)
		}
		stripePaymentID, clientSecret = intent.ID, intent.ClientSecret
	} else {
		// The "_stub" tag makes it easy to grep dev DBs for rows created
		// without a real Stripe account, and lets ConfirmPurchase skip the
		// PaymentIntent.Get verification for them.
		stripePaymentID = "pi_stub_" + NewID()
		clientSecret = stripePaymentID + "_secret_" + NewID()
	}

	// Phase 3 — record the pending purchase + audit row.
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
		paymentMethod, userID, stripePaymentID,
	); err != nil {
		return nil, fmt.Errorf("insert pending purchase: %w", err)
	}
	// Pending audit row so the activity log shows the intent even if the
	// confirm step never lands. A successful confirm later writes a
	// separate `purchase` row keyed to the same purchase_id.
	if err := writePurchaseAuditTx(ctx, s, tx, studioID, userID, purchaseID, prod,
		finalMinor, discountMinor, discountCode, paymentMethod, true); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &PendingPurchaseResult{
		PurchaseID:       purchaseID,
		AmountMinor:      finalMinor,
		Currency:         prod.currency,
		StripePaymentID:  stripePaymentID,
		ClientSecret:     clientSecret,
		StripeCustomerID: stripeCustomerID,
	}, nil
}

// StripeEphemeralKey mints an ephemeral key scoped to the buyer's Stripe
// Customer, for the mobile PaymentSheet's saved-cards UI. stripeVersion is the
// mobile SDK's pinned API version (sent by the client). Returns
// ErrStripeNotConfigured when the studio has no keys.
func (s *Store) StripeEphemeralKey(ctx context.Context, studioID, userID, email, stripeVersion string) (string, error) {
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
	customerID, err := s.ensureStripeCustomer(ctx, keys.SecretKey, studioID, userID, email)
	if err != nil {
		return "", fmt.Errorf("ensure stripe customer: %w", err)
	}
	return s.gateway.CreateEphemeralKey(ctx, keys.SecretKey, customerID, stripeVersion)
}

// ConfirmPurchase finalises a pending purchase: mints the entitlement +
// coverage, flips status='completed', back-links the entitlement onto the
// purchase row. Idempotent on the happy path — a second confirm on an
// already-completed row returns the same entitlement id without writing
// extra rows. Refuses 'refunded' / 'voided' purchases with a clear error.
//
// In production this should also verify the underlying Stripe PaymentIntent
// reports status=succeeded before flipping. With STRIPE_SECRET_KEY unset we
// trust the caller (the request flow itself proves the dev_stub path was
// taken).
func (s *Store) ConfirmPurchase(ctx context.Context, studioID, userID, purchaseID string) (string, error) {
	// Read the minimal state needed to decide whether to verify with Stripe.
	// Done before the write tx so any PaymentIntent.Get network call doesn't
	// hold the SQLite write lock.
	var (
		status, stripePaymentID string
		existingEntitlement     sql.NullString
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT status, COALESCE(stripe_payment_id,''), resulting_entitlement_id
		  FROM purchases
		 WHERE id = ? AND studio_id = ? AND user_id = ?`,
		purchaseID, studioID, userID,
	).Scan(&status, &stripePaymentID, &existingEntitlement)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if status == "completed" && existingEntitlement.Valid {
		// Idempotent re-confirm — caller (or a webhook race) gets the same id.
		return existingEntitlement.String, nil
	}
	if status != "pending" {
		return "", fmt.Errorf("cannot confirm purchase in status %q", status)
	}

	// Verify the PaymentIntent actually succeeded before minting. Without this
	// a client could POST /confirm without ever having paid. Skipped for
	// dev_stub rows (pi_stub_…) and when no gateway is wired.
	if s.gateway != nil && !strings.HasPrefix(stripePaymentID, "pi_stub_") {
		keys, err := s.LoadStripeKeysForUse(ctx, studioID)
		if err != nil {
			return "", fmt.Errorf("load stripe keys: %w", err)
		}
		intent, err := s.gateway.GetIntent(ctx, keys.SecretKey, stripePaymentID)
		if err != nil {
			return "", fmt.Errorf("stripe lookup: %w", err)
		}
		if intent.Status != payments.StatusSucceeded {
			return "", fmt.Errorf("payment not succeeded (status=%s)", intent.Status)
		}
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	entitlementID, err := finalizePendingTx(ctx, s, tx, studioID, userID, purchaseID, "confirm")
	if err != nil {
		return "", err
	}
	return entitlementID, tx.Commit()
}

// ConfirmPurchaseByIntent is the authoritative, webhook-driven fulfilment
// path. The signed payment_intent.succeeded event is already proof of payment,
// so this skips the PaymentIntent.Get re-fetch the client path does. It
// resolves the purchase (and its owner) from the Stripe PaymentIntent id, then
// finalises through the same idempotent helper. Returns ErrNotFound when no
// purchase matches the intent (e.g. an event for a different system).
func (s *Store) ConfirmPurchaseByIntent(ctx context.Context, studioID, intentID string) (string, error) {
	var userID, purchaseID string
	err := s.db.QueryRowContext(ctx, `
		SELECT user_id, id FROM purchases
		 WHERE studio_id = ? AND stripe_payment_id = ?`,
		studioID, intentID,
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
	entitlementID, err := finalizePendingTx(ctx, s, tx, studioID, userID, purchaseID, "webhook")
	if err != nil {
		return "", err
	}
	return entitlementID, tx.Commit()
}

// VoidPurchaseByIntent marks a still-pending purchase 'voided' — used by the
// webhook on payment_intent.payment_failed / .canceled, and by the janitor for
// abandoned intents. Only pending rows are touched: a completed purchase
// (payment already settled) is left alone, and a re-delivered void event is a
// no-op. No discount release is needed — usage is only counted on 'completed'
// rows, so a voided pending purchase never held a code.
func (s *Store) VoidPurchaseByIntent(ctx context.Context, studioID, intentID, reason string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var userID, purchaseID, status string
	err = tx.QueryRowContext(ctx, `
		SELECT user_id, id, status FROM purchases
		 WHERE studio_id = ? AND stripe_payment_id = ?`,
		studioID, intentID,
	).Scan(&userID, &purchaseID, &status)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if status != "pending" {
		return nil // already completed/voided — nothing to do.
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE purchases SET status = 'voided' WHERE id = ?`, purchaseID,
	); err != nil {
		return fmt.Errorf("void purchase: %w", err)
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"purchase_void", "purchase", purchaseID, map[string]any{
			"reason": reason,
		}); err != nil {
		return fmt.Errorf("audit purchase_void: %w", err)
	}
	return tx.Commit()
}

// finalizePendingTx mints the entitlement, flips the purchase to 'completed',
// back-links it, and writes the completion audit row — all inside the caller's
// transaction. Idempotent: a purchase already 'completed' with an entitlement
// returns that id without rewriting; a non-pending/non-completed status errors.
// The caller is responsible for proving payment first (client path verifies via
// Stripe; webhook path is itself the proof).
func finalizePendingTx(ctx context.Context, s *Store, tx *sql.Tx, studioID, userID, purchaseID, via string) (string, error) {
	var (
		status, productID   string
		existingEntitlement sql.NullString
		enrollmentID        sql.NullString
	)
	err := tx.QueryRowContext(ctx, `
		SELECT status, product_id, resulting_entitlement_id, enrollment_id
		  FROM purchases
		 WHERE id = ? AND studio_id = ? AND user_id = ?`,
		purchaseID, studioID, userID,
	).Scan(&status, &productID, &existingEntitlement, &enrollmentID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if status == "completed" && existingEntitlement.Valid {
		return existingEntitlement.String, nil
	}
	// Terminal states (e.g. a series purchase auto-refunded because the series
	// filled) — nothing to fulfil; treat a re-delivered webhook as a no-op
	// rather than erroring into a Stripe retry loop.
	if status == "refunded" || status == "voided" {
		return "", nil
	}
	if status != "pending" {
		return "", fmt.Errorf("cannot confirm purchase in status %q", status)
	}

	// Series purchase: enroll into the series (sessions booked) instead of
	// minting a standalone pass. Returns ErrSeriesFull if it filled since
	// checkout — the caller refunds.
	if enrollmentID.Valid && enrollmentID.String != "" {
		return enrollIntoSeriesTx(ctx, s, tx, studioID, userID, enrollmentID.String, purchaseID)
	}

	prod, err := loadProductForPurchaseTx(ctx, tx, studioID, productID)
	if err != nil {
		return "", err
	}
	entitlementID, err := insertEntitlementSnapshotTx(ctx, tx, studioID, userID, productID, prod)
	if err != nil {
		return "", err
	}
	// Read the snapshot fields the audit row needs (payment_method +
	// amount_minor + currency live on the purchase row itself).
	var (
		paymentMethod string
		amountMinor   int
		currency      string
	)
	if err := tx.QueryRowContext(ctx, `
		SELECT payment_method, amount_minor, currency
		  FROM purchases WHERE id = ?`, purchaseID,
	).Scan(&paymentMethod, &amountMinor, &currency); err != nil {
		return "", fmt.Errorf("read purchase for audit: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE purchases
		   SET status = 'completed',
		       resulting_entitlement_id = ?
		 WHERE id = ?`,
		entitlementID, purchaseID,
	); err != nil {
		return "", fmt.Errorf("flip purchase to completed: %w", err)
	}
	// Mirror the sync CreatePurchase audit shape so a Stripe-confirmed row
	// shows up identically in the activity log. `via` distinguishes the
	// optimistic client confirm from the authoritative webhook.
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"purchase", "purchase", purchaseID, map[string]any{
			"product_name":   prod.name,
			"pass_kind":      prod.passKind,
			"amount_minor":   amountMinor,
			"currency":       currency,
			"payment_method": paymentMethod,
			"via":            via,
		}); err != nil {
		return "", fmt.Errorf("audit purchase: %w", err)
	}
	return entitlementID, nil
}

// EntitlementSnapshot is the minimal shape returned after a successful
// purchase — used by the success screen.
type EntitlementSnapshot struct {
	ID               string `json:"id"`
	Label            string `json:"label"`
	PassKind         string `json:"pass_kind"`
	CreditsTotal     *int   `json:"credits_total,omitempty"`
	CreditsRemaining *int   `json:"credits_remaining,omitempty"`
	ExpiresAt        string `json:"expires_at,omitempty"`
}

func (s *Store) GetEntitlement(ctx context.Context, id string) (*EntitlementSnapshot, error) {
	var (
		out                EntitlementSnapshot
		creditsT, creditsR sql.NullInt64
		expires            sql.NullString
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT id, label, pass_kind, credits_total, credits_remaining, expires_at
		  FROM entitlements WHERE id = ?`, id,
	).Scan(&out.ID, &out.Label, &out.PassKind, &creditsT, &creditsR, &expires)
	if err != nil {
		return nil, err
	}
	if creditsT.Valid {
		n := int(creditsT.Int64)
		out.CreditsTotal = &n
	}
	if creditsR.Valid {
		n := int(creditsR.Int64)
		out.CreditsRemaining = &n
	}
	if expires.Valid {
		out.ExpiresAt = expires.String
	}
	return &out, nil
}
