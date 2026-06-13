package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/google/uuid"
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

func (s *Store) ListProducts(ctx context.Context, studioID string) ([]Product, error) {
	const q = `
		SELECT p.id, p.name, COALESCE(p.description,''), p.price_minor,
		       s.currency, p.billing_type, p.pass_kind,
		       p.credits, p.validity_days, p.is_hero
		  FROM products p
		  JOIN studios s ON s.id = p.studio_id
		 WHERE p.studio_id = ? AND p.is_archived = 0
		 ORDER BY p.is_hero DESC, p.display_order ASC, p.created_at ASC`
	rows, err := s.db.QueryContext(ctx, q, studioID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	products := make([]Product, 0)
	for rows.Next() {
		var (
			p          Product
			credits    sql.NullInt64
			validity   sql.NullInt64
			heroInt    int
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

// CreatePurchase creates a purchase + the resulting entitlement, all in one
// transaction. The Stripe flow is stubbed in dev — payment_method='dev_stub'
// is auto-completed. Returns (purchaseID, entitlementID).
func (s *Store) CreatePurchase(
	ctx context.Context,
	studioID, userID, productID, paymentMethod string,
) (string, string, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()

	var (
		name, currency, billingType, passKind string
		priceMinor                            int
		credits, validityDays                 sql.NullInt64
	)
	err = tx.QueryRowContext(ctx, `
		SELECT p.name, s.currency, p.billing_type, p.pass_kind,
		       p.price_minor, p.credits, p.validity_days
		  FROM products p
		  JOIN studios s ON s.id = p.studio_id
		 WHERE p.id = ? AND p.studio_id = ? AND p.is_archived = 0`,
		productID, studioID,
	).Scan(&name, &currency, &billingType, &passKind, &priceMinor, &credits, &validityDays)
	if err != nil {
		return "", "", fmt.Errorf("product lookup: %w", err)
	}

	purchaseID := uuid.NewString()
	entitlementID := uuid.NewString()

	// Insert entitlement first (snapshots pass kind + credits + validity).
	var creditsTotal, creditsRemaining any
	if credits.Valid {
		creditsTotal = int(credits.Int64)
		creditsRemaining = int(credits.Int64)
	}
	var expiresAt any
	if validityDays.Valid {
		expiresAt = time.Now().UTC().Add(time.Duration(validityDays.Int64) * 24 * time.Hour).Format(time.RFC3339)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO entitlements
		  (id, studio_id, user_id, source_product_id, pass_kind, label,
		   credits_total, credits_remaining, expires_at, status)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')`,
		entitlementID, studioID, userID, productID, passKind, name,
		creditsTotal, creditsRemaining, expiresAt,
	); err != nil {
		return "", "", fmt.Errorf("insert entitlement: %w", err)
	}

	// Snapshot class type coverage onto the new entitlement.
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO entitlement_class_types (entitlement_id, class_type_id)
		  SELECT ?, class_type_id FROM product_class_types WHERE product_id = ?`,
		entitlementID, productID,
	); err != nil {
		return "", "", fmt.Errorf("snapshot class types: %w", err)
	}

	// Insert purchase.
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO purchases
		  (id, studio_id, user_id, product_id, amount_minor, currency,
		   payment_method, initiated_by, actor_role, status,
		   resulting_entitlement_id)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'student', 'completed', ?)`,
		purchaseID, studioID, userID, productID, priceMinor, currency,
		paymentMethod, userID, entitlementID,
	); err != nil {
		return "", "", fmt.Errorf("insert purchase: %w", err)
	}

	return purchaseID, entitlementID, tx.Commit()
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
