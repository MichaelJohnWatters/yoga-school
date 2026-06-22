package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

type Product struct {
	ID            string   `json:"id"`
	Name          string   `json:"name"`
	Description   string   `json:"description"`
	PriceMinor    int      `json:"price_minor"`
	Currency      string   `json:"currency"`
	BillingType   string   `json:"billing_type"`
	PassKind      string   `json:"pass_kind"`
	Credits       *int     `json:"credits,omitempty"`
	ValidityDays  *int     `json:"validity_days,omitempty"`
	IsHero        bool     `json:"is_hero"`
	ClassTypeIDs  []string `json:"class_type_ids"`
	DisciplineSet []string `json:"disciplines"`
}

// ListProducts returns the studio's purchasable products. When
// coversClassTypeID is non-empty, the result is restricted to products that
// include that class type — used by the "buy a pass to take this class"
// flow so the picker only shows passes the student can actually use.
func (s *Store) ListProducts(ctx context.Context, studioID, coversClassTypeID string) ([]Product, error) {
	q := `
		SELECT p.id, p.name, COALESCE(p.description,''), p.price_minor,
		       s.currency, p.billing_type, p.pass_kind,
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
			heroInt  int
		)
		if err := rows.Scan(
			&p.ID, &p.Name, &p.Description, &p.PriceMinor,
			&p.Currency, &p.BillingType, &p.PassKind,
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
		       s.currency, p.billing_type, p.pass_kind,
		       p.credits, p.validity_days, p.is_hero
		  FROM products p
		  JOIN studios s ON s.id = p.studio_id
		 WHERE p.id = ? AND p.studio_id = ? AND p.is_archived = 0`
	var (
		p        Product
		credits  sql.NullInt64
		validity sql.NullInt64
		heroInt  int
	)
	err := s.db.QueryRowContext(ctx, q, productID, studioID).Scan(
		&p.ID, &p.Name, &p.Description, &p.PriceMinor,
		&p.Currency, &p.BillingType, &p.PassKind,
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
// STRIPE WIRING — TODO (when the dev Stripe account is set up)
// ============================================================================
//
// Today this file uses a dev_stub: CreatePendingPurchase mints placeholder
// pi_/secret strings; ConfirmPurchase trusts the caller. The intent/confirm
// SHAPE is real and locked in; only the network calls are missing.
//
// Two call sites need real Stripe SDK calls. They're called out inline below.
// Plus three system-level pieces that don't fit in this file:
//
//   1. Add `github.com/stripe/stripe-go/v76` to go.mod.
//
//   2. Per-call key resolution: each call into Stripe needs the studio's
//      secret_key (decrypted via Store.LoadStripeKeysForUse). DO NOT
//      stash a process-global stripe.Key — this is a multi-tenant app
//      and each studio brings its own keys.
//
//      Example shape:
//          keys, err := store.LoadStripeKeysForUse(ctx, studioID)
//          if err != nil { return err }
//          sc := &client.API{}
//          sc.Init(keys.SecretKey, nil)
//          pi, err := sc.PaymentIntents.New(&stripe.PaymentIntentParams{...})
//
//   3. Webhook route: add POST /stripe/webhook (PUBLIC — not behind /admin
//      nor /api/v1/auth). Verifies signature with the studio's
//      webhook_secret, listens for `payment_intent.succeeded` and calls
//      ConfirmPurchase. See cmd/server/main.go for where the route belongs
//      (alongside the existing chi.NewRouter() setup).
//
//   4. Products UI: surface products.stripe_price_id on the product editor
//      screen so studios can paste their `price_…` ids in. The column
//      already exists; only the editor field is missing.
//
//   5. Tests: real-Stripe verification needs either a mocked
//      paymentintent.Client interface (clean) or the Stripe test-mode
//      sandbox (slower, but proves the actual SDK call works). Recommend
//      the interface mock for unit tests + one e2e against the sandbox.
//
// Grep for "STRIPE TODO" to find every inline marker that lines up with
// this list.
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
	studioID, userID, productID, paymentMethod, discountCode string,
) (*PendingPurchaseResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	prod, err := loadProductForPurchaseTx(ctx, tx, studioID, productID)
	if err != nil {
		return nil, err
	}
	discountID, discountMinor, err := validateAndApplyDiscountTx(
		ctx, tx, studioID, userID, productID, discountCode, prod.priceMinor,
	)
	if err != nil {
		return nil, err
	}
	finalMinor := prod.priceMinor - discountMinor
	var discountIDArg any
	if discountID != "" {
		discountIDArg = discountID
	}

	purchaseID := NewID()
	// STRIPE TODO — replace the next 2 lines with a real PaymentIntent.
	//
	//   keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	//   if err != nil { return nil, err }
	//   sc := &client.API{}
	//   sc.Init(keys.SecretKey, nil)
	//   pi, err := sc.PaymentIntents.New(&stripe.PaymentIntentParams{
	//       Amount:      stripe.Int64(int64(prod.priceMinor)),
	//       Currency:    stripe.String(strings.ToLower(prod.currency)),
	//       PaymentMethodTypes: stripe.StringSlice([]string{"card"}),
	//       Metadata: map[string]string{
	//           "purchase_id": purchaseID,
	//           "studio_id":   studioID,
	//           "user_id":     userID,
	//       },
	//   })
	//   stripePaymentID := pi.ID
	//   clientSecret    := pi.ClientSecret
	//
	// The "_stub" tag in the placeholder makes it easy to grep dev DBs
	// for rows that were created before Stripe was wired in.
	stripePaymentID := "pi_stub_" + NewID()
	clientSecret := stripePaymentID + "_secret_" + NewID()

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO purchases
		  (id, studio_id, user_id, product_id, list_price_minor, amount_minor,
		   discount_minor, discount_id, currency,
		   payment_method, initiated_by, actor_role, status,
		   stripe_payment_id)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'student', 'pending', ?)`,
		purchaseID, studioID, userID, productID,
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
		PurchaseID:      purchaseID,
		AmountMinor:     prod.priceMinor,
		Currency:        prod.currency,
		StripePaymentID: stripePaymentID,
		ClientSecret:    clientSecret,
	}, nil
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
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	var (
		status, productID   string
		existingEntitlement sql.NullString
	)
	err = tx.QueryRowContext(ctx, `
		SELECT status, product_id, resulting_entitlement_id
		  FROM purchases
		 WHERE id = ? AND studio_id = ? AND user_id = ?`,
		purchaseID, studioID, userID,
	).Scan(&status, &productID, &existingEntitlement)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if status == "completed" && existingEntitlement.Valid {
		// Idempotent re-confirm — caller (or a retry) gets the same id.
		return existingEntitlement.String, tx.Commit()
	}
	if status != "pending" {
		return "", fmt.Errorf("cannot confirm purchase in status %q", status)
	}

	// STRIPE TODO — verify the PaymentIntent actually succeeded before
	// minting the entitlement. Without this check a malicious client can
	// POST /confirm without ever having paid.
	//
	//   var pi string
	//   _ = tx.QueryRowContext(ctx,
	//       `SELECT COALESCE(stripe_payment_id,'') FROM purchases WHERE id = ?`,
	//       purchaseID,
	//   ).Scan(&pi)
	//   if !strings.HasPrefix(pi, "pi_stub_") { // real PI from Stripe
	//       keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	//       if err != nil { return "", err }
	//       sc := &client.API{}
	//       sc.Init(keys.SecretKey, nil)
	//       resolved, err := sc.PaymentIntents.Get(pi, nil)
	//       if err != nil { return "", fmt.Errorf("stripe lookup: %w", err) }
	//       if resolved.Status != stripe.PaymentIntentStatusSucceeded {
	//           return "", fmt.Errorf("payment not succeeded (status=%s)", resolved.Status)
	//       }
	//   }

	prod, err := loadProductForPurchaseTx(ctx, tx, studioID, productID)
	if err != nil {
		return "", err
	}
	entitlementID, err := insertEntitlementSnapshotTx(ctx, tx, studioID, userID, productID, prod)
	if err != nil {
		return "", err
	}
	// Read the snapshot fields we need for the audit row before flipping
	// status — payment_method + amount_minor + currency are all on the
	// purchase row itself so we don't have to thread them through the
	// caller.
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
	// Mirror the sync CreatePurchase audit shape so a Stripe-confirmed
	// row shows up identically in the activity log. Discount detail isn't
	// available here without re-reading the row — the pending audit row
	// already captured it, so we keep this one focused on "this completed".
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"purchase", "purchase", purchaseID, map[string]any{
			"product_name":   prod.name,
			"pass_kind":      prod.passKind,
			"amount_minor":   amountMinor,
			"currency":       currency,
			"payment_method": paymentMethod,
			"via":            "confirm",
		}); err != nil {
		return "", fmt.Errorf("audit purchase: %w", err)
	}
	return entitlementID, tx.Commit()
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
