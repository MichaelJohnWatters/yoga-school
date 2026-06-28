package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/studio52/yoga-school/server/internal/payments"
	"github.com/studio52/yoga-school/server/internal/secrets"
)

// AdminProduct extends the public Product with manager-only fields.
type AdminProduct struct {
	Product
	IsArchived   bool              `json:"is_archived"`
	DisplayOrder int               `json:"display_order"`
	Usage        AdminProductUsage `json:"usage"`
}

type AdminProductUsage struct {
	ActivePasses int     `json:"active_passes"`
	RevenueMinor int     `json:"revenue_minor"`
	LastSale     *string `json:"last_sale,omitempty"`
}

// ListAdminProducts returns every product (including archived) with usage stats.
func (s *Store) ListAdminProducts(ctx context.Context, studioID string) ([]AdminProduct, error) {
	const q = `
		SELECT p.id, p.name, COALESCE(p.description,''), p.price_minor,
		       s.currency, p.billing_type, p.billing_interval, p.pass_kind,
		       p.credits, p.validity_days, p.is_hero,
		       p.is_archived, p.display_order
		  FROM products p
		  JOIN studios s ON s.id = p.studio_id
		 WHERE p.studio_id = ?
		 ORDER BY p.is_archived ASC, p.is_hero DESC, p.display_order ASC, p.created_at ASC`
	rows, err := s.db.QueryContext(ctx, q, studioID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]AdminProduct, 0)
	for rows.Next() {
		var (
			p        AdminProduct
			credits  sql.NullInt64
			validity sql.NullInt64
			interval sql.NullString
			heroInt  int
			archInt  int
		)
		if err := rows.Scan(
			&p.ID, &p.Name, &p.Description, &p.PriceMinor,
			&p.Currency, &p.BillingType, &interval, &p.PassKind,
			&credits, &validity, &heroInt, &archInt, &p.DisplayOrder,
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
		p.IsArchived = archInt != 0
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := s.hydrateAdminProductExtras(ctx, studioID, out); err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Store) hydrateAdminProductExtras(ctx context.Context, studioID string, products []AdminProduct) error {
	if len(products) == 0 {
		return nil
	}
	const jq = `
		SELECT pct.product_id, ct.id, COALESCE(ct.discipline,'')
		  FROM product_class_types pct
		  JOIN class_types ct ON ct.id = pct.class_type_id
		 WHERE pct.product_id IN (SELECT id FROM products WHERE studio_id = ?)`
	jrows, err := s.db.QueryContext(ctx, jq, studioID)
	if err != nil {
		return err
	}
	defer jrows.Close()
	covers := map[string][]string{}
	disc := map[string]map[string]struct{}{}
	for jrows.Next() {
		var pid, ctID, discipline string
		if err := jrows.Scan(&pid, &ctID, &discipline); err != nil {
			return err
		}
		covers[pid] = append(covers[pid], ctID)
		if discipline != "" {
			if disc[pid] == nil {
				disc[pid] = map[string]struct{}{}
			}
			disc[pid][discipline] = struct{}{}
		}
	}

	const uq = `
		SELECT product_id,
		       COUNT(*) AS purchases,
		       COALESCE(SUM(amount_minor), 0) AS revenue,
		       MAX(created_at) AS last_sale
		  FROM purchases
		 WHERE studio_id = ? AND status = 'completed'
		 GROUP BY product_id`
	urows, err := s.db.QueryContext(ctx, uq, studioID)
	if err != nil {
		return err
	}
	defer urows.Close()
	usage := map[string]AdminProductUsage{}
	for urows.Next() {
		var (
			pid       string
			purchases int
			revenue   int
			lastSale  sql.NullString
		)
		if err := urows.Scan(&pid, &purchases, &revenue, &lastSale); err != nil {
			return err
		}
		u := AdminProductUsage{
			ActivePasses: purchases, // proxy until we track active entitlements per product
			RevenueMinor: revenue,
		}
		if lastSale.Valid {
			s := lastSale.String
			u.LastSale = &s
		}
		usage[pid] = u
	}

	// Refine ActivePasses to count only currently-active entitlements.
	const eq = `
		SELECT source_product_id, COUNT(*)
		  FROM entitlements
		 WHERE studio_id = ? AND status = 'active' AND source_product_id IS NOT NULL
		 GROUP BY source_product_id`
	erows, err := s.db.QueryContext(ctx, eq, studioID)
	if err != nil {
		return err
	}
	defer erows.Close()
	active := map[string]int{}
	for erows.Next() {
		var pid string
		var n int
		if err := erows.Scan(&pid, &n); err != nil {
			return err
		}
		active[pid] = n
	}

	for i := range products {
		products[i].ClassTypeIDs = covers[products[i].ID]
		for d := range disc[products[i].ID] {
			products[i].DisciplineSet = append(products[i].DisciplineSet, d)
		}
		u := usage[products[i].ID]
		if a, ok := active[products[i].ID]; ok {
			u.ActivePasses = a
		} else {
			u.ActivePasses = 0
		}
		products[i].Usage = u
	}
	return nil
}

// AdminProductInput is the body for POST + PATCH /admin/products.
type AdminProductInput struct {
	Name            *string  `json:"name,omitempty"`
	Description     *string  `json:"description,omitempty"`
	PriceMinor      *int     `json:"price_minor,omitempty"`
	BillingType     *string  `json:"billing_type,omitempty"`
	BillingInterval *string  `json:"billing_interval,omitempty"`
	PassKind        *string  `json:"pass_kind,omitempty"`
	Credits         *int     `json:"credits,omitempty"`
	ValidityDays    *int     `json:"validity_days,omitempty"`
	IsHero          *bool    `json:"is_hero,omitempty"`
	DisplayOrder    *int     `json:"display_order,omitempty"`
	ClassTypeIDs    []string `json:"class_type_ids,omitempty"`
}

func (s *Store) CreateAdminProduct(ctx context.Context, studioID, actorID string, in AdminProductInput) (string, error) {
	required := []struct {
		name string
		ok   bool
	}{
		{"name", in.Name != nil && strings.TrimSpace(*in.Name) != ""},
		{"price_minor", in.PriceMinor != nil},
		{"billing_type", in.BillingType != nil},
		{"pass_kind", in.PassKind != nil},
	}
	for _, r := range required {
		if !r.ok {
			return "", fmt.Errorf("%s is required", r.name)
		}
	}
	if *in.BillingType != "one_time" && *in.BillingType != "recurring" {
		return "", errors.New("billing_type must be one_time|recurring")
	}
	if *in.PassKind != "credit" && *in.PassKind != "unlimited" {
		return "", errors.New("pass_kind must be credit|unlimited")
	}

	// Recurring products bill on an interval (default monthly). One-time
	// products carry no interval.
	var interval any
	intervalStr := ""
	if *in.BillingType == "recurring" {
		intervalStr = "month"
		if in.BillingInterval != nil {
			intervalStr = *in.BillingInterval
		}
		if intervalStr != "month" && intervalStr != "year" {
			return "", errors.New("billing_interval must be month|year")
		}
		interval = intervalStr
	}

	id := NewID()

	// Mirror a recurring product into the studio's Stripe account as a
	// Product + recurring Price before persisting, so the row carries the
	// price id the subscription checkout charges against. Skipped (ids left
	// null, backfilled on a later save) when Stripe isn't configured yet.
	stripeProductID, stripePriceID, err := s.mirrorRecurringPrice(
		ctx, studioID, *in.BillingType, *in.Name, *in.PriceMinor, intervalStr)
	if err != nil {
		return "", err
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	hero := 0
	if in.IsHero != nil && *in.IsHero {
		hero = 1
	}
	order := 0
	if in.DisplayOrder != nil {
		order = *in.DisplayOrder
	}
	var description any
	if in.Description != nil {
		description = *in.Description
	}
	var credits any
	if *in.PassKind == "credit" && in.Credits != nil {
		credits = *in.Credits
	}
	var validity any
	if in.ValidityDays != nil {
		validity = *in.ValidityDays
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO products
		  (id, studio_id, name, description, price_minor, billing_type, billing_interval,
		   pass_kind, credits, validity_days, is_hero, display_order, is_archived,
		   stripe_product_id, stripe_price_id)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
		id, studioID, *in.Name, description, *in.PriceMinor, *in.BillingType, interval,
		*in.PassKind, credits, validity, hero, order,
		nullableStr(stripeProductID), nullableStr(stripePriceID),
	)
	if err != nil {
		return "", err
	}
	if err := s.replaceProductClassTypes(ctx, tx, id, in.ClassTypeIDs); err != nil {
		return "", err
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID, "product_create", "product", id, map[string]any{
		"name":         *in.Name,
		"price_minor":  *in.PriceMinor,
		"billing_type": *in.BillingType,
		"pass_kind":    *in.PassKind,
	}); err != nil {
		return "", err
	}
	return id, tx.Commit()
}

func (s *Store) UpdateAdminProduct(ctx context.Context, studioID, actorID, productID string, in AdminProductInput) error {
	// Load current state up front so we can decide whether the Stripe Price
	// needs (re)creating. Stripe Prices are immutable, so any price/interval
	// change — or first-time recurring — mints a new Price and archives the
	// old one. Done before the write tx so the network call doesn't hold the
	// single-writer SQLite lock.
	var (
		curBillingType   string
		curPriceMinor    int
		curName          string
		curInterval      sql.NullString
		curStripePriceID sql.NullString
	)
	if err := s.db.QueryRowContext(ctx, `
		SELECT billing_type, price_minor, name, billing_interval, stripe_price_id
		  FROM products WHERE id = ? AND studio_id = ?`,
		productID, studioID,
	).Scan(&curBillingType, &curPriceMinor, &curName, &curInterval, &curStripePriceID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}

	effBillingType := curBillingType
	if in.BillingType != nil {
		effBillingType = *in.BillingType
	}
	effPrice := curPriceMinor
	if in.PriceMinor != nil {
		effPrice = *in.PriceMinor
	}
	effName := curName
	if in.Name != nil {
		effName = *in.Name
	}
	effInterval := curInterval.String
	if in.BillingInterval != nil {
		effInterval = *in.BillingInterval
	}
	if effBillingType == "recurring" {
		if effInterval == "" {
			effInterval = "month"
		}
		if effInterval != "month" && effInterval != "year" {
			return errors.New("billing_interval must be month|year")
		}
	}

	// (Re)mirror to Stripe when recurring and the price/interval changed, the
	// product just became recurring, or it was never mirrored.
	var newStripeProductID, newStripePriceID string
	remirror := effBillingType == "recurring" && (curStripePriceID.String == "" ||
		(in.PriceMinor != nil && *in.PriceMinor != curPriceMinor) ||
		(in.BillingInterval != nil && *in.BillingInterval != curInterval.String) ||
		(in.BillingType != nil && curBillingType != "recurring"))
	if remirror {
		pid, prid, err := s.mirrorRecurringPrice(ctx, studioID, effBillingType, effName, effPrice, effInterval)
		if err != nil {
			return err
		}
		newStripeProductID, newStripePriceID = pid, prid
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	set := []string{}
	args := []any{}
	if in.Name != nil {
		set = append(set, "name = ?")
		args = append(args, *in.Name)
	}
	if in.Description != nil {
		set = append(set, "description = ?")
		args = append(args, *in.Description)
	}
	if in.PriceMinor != nil {
		set = append(set, "price_minor = ?")
		args = append(args, *in.PriceMinor)
	}
	if in.BillingType != nil {
		if *in.BillingType != "one_time" && *in.BillingType != "recurring" {
			return errors.New("billing_type must be one_time|recurring")
		}
		set = append(set, "billing_type = ?")
		args = append(args, *in.BillingType)
	}
	if effBillingType == "recurring" {
		set = append(set, "billing_interval = ?")
		args = append(args, effInterval)
	} else if in.BillingType != nil { // switched to one_time
		set = append(set, "billing_interval = NULL")
	}
	if remirror {
		set = append(set, "stripe_product_id = ?", "stripe_price_id = ?")
		args = append(args, nullableStr(newStripeProductID), nullableStr(newStripePriceID))
	}
	if in.PassKind != nil {
		if *in.PassKind != "credit" && *in.PassKind != "unlimited" {
			return errors.New("pass_kind must be credit|unlimited")
		}
		set = append(set, "pass_kind = ?")
		args = append(args, *in.PassKind)
		// Null out credits when switching to unlimited.
		if *in.PassKind == "unlimited" {
			set = append(set, "credits = NULL")
		}
	}
	if in.Credits != nil {
		set = append(set, "credits = ?")
		args = append(args, *in.Credits)
	}
	if in.ValidityDays != nil {
		set = append(set, "validity_days = ?")
		args = append(args, *in.ValidityDays)
	}
	if in.IsHero != nil {
		v := 0
		if *in.IsHero {
			v = 1
		}
		set = append(set, "is_hero = ?")
		args = append(args, v)
	}
	if in.DisplayOrder != nil {
		set = append(set, "display_order = ?")
		args = append(args, *in.DisplayOrder)
	}
	if len(set) > 0 {
		args = append(args, productID, studioID)
		q := "UPDATE products SET "
		for i, sq := range set {
			if i > 0 {
				q += ", "
			}
			q += sq
		}
		q += " WHERE id = ? AND studio_id = ?"
		res, err := tx.ExecContext(ctx, q, args...)
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return ErrNotFound
		}
	}
	if in.ClassTypeIDs != nil {
		if err := s.replaceProductClassTypes(ctx, tx, productID, in.ClassTypeIDs); err != nil {
			return err
		}
	}
	// Always include the product's current name on the audit row so a
	// price-only edit still reads as "PRODUCT EDIT · 10-pack" rather
	// than dropping the subject.
	var currentName string
	_ = tx.QueryRowContext(ctx,
		`SELECT name FROM products WHERE id = ?`, productID,
	).Scan(&currentName)
	detail := map[string]any{"name": currentName}
	if in.Name != nil {
		detail["name"] = *in.Name
	}
	if in.PriceMinor != nil {
		detail["price_minor"] = *in.PriceMinor
	}
	if in.BillingType != nil {
		detail["billing_type"] = *in.BillingType
	}
	if in.PassKind != nil {
		detail["pass_kind"] = *in.PassKind
	}
	if in.Credits != nil {
		detail["credits"] = *in.Credits
	}
	if in.ValidityDays != nil {
		detail["validity_days"] = *in.ValidityDays
	}
	if in.IsHero != nil {
		detail["is_hero"] = *in.IsHero
	}
	if in.ClassTypeIDs != nil {
		detail["class_type_ids"] = in.ClassTypeIDs
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID, "product_update", "product", productID, detail); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	// Deactivate the superseded Stripe Price (best-effort: the repoint is
	// already committed, so a stale active Price is harmless cosmetic clutter).
	if remirror && curStripePriceID.String != "" {
		if keys, err := s.stripeKeys(ctx, studioID); err == nil {
			_ = s.gateway.ArchivePrice(ctx, keys.SecretKey, curStripePriceID.String)
		}
	}
	return nil
}

// mirrorRecurringPrice creates a Stripe Product + recurring Price for a
// recurring product and returns their ids. Returns ("","",nil) for one-time
// products or when Stripe isn't configured yet (so the product still saves and
// can be backfilled on a later edit once keys exist).
func (s *Store) mirrorRecurringPrice(ctx context.Context, studioID, billingType, name string, priceMinor int, interval string) (string, string, error) {
	if billingType != "recurring" || s.gateway == nil {
		return "", "", nil
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		if errors.Is(err, ErrNotFound) || errors.Is(err, secrets.ErrNoMasterKey) {
			return "", "", nil // not configured — defer mirroring
		}
		return "", "", fmt.Errorf("load stripe keys: %w", err)
	}
	var currency string
	if err := s.db.QueryRowContext(ctx,
		`SELECT currency FROM studios WHERE id = ?`, studioID).Scan(&currency); err != nil {
		return "", "", err
	}
	return s.gateway.CreateRecurringPrice(ctx, keys.SecretKey, payments.PriceParams{
		ProductName: name,
		AmountMinor: int64(priceMinor),
		Currency:    currency,
		Interval:    interval,
	})
}

// nullableStr maps "" → nil so an empty id stores as SQL NULL.
func nullableStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func (s *Store) replaceProductClassTypes(ctx context.Context, tx *sql.Tx, productID string, ids []string) error {
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM product_class_types WHERE product_id = ?`, productID,
	); err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO product_class_types (product_id, class_type_id)
			    VALUES (?, ?)`, productID, id,
		); err != nil {
			return err
		}
	}
	return nil
}

// ArchiveProduct soft-deletes — existing entitlements untouched.
func (s *Store) ArchiveProduct(ctx context.Context, studioID, actorID, productID string) error {
	// Snapshot the product name BEFORE archiving so the audit row can
	// render "PRODUCT ARCHIVED · 10-pack" rather than an opaque id.
	var name string
	_ = s.db.QueryRowContext(ctx,
		`SELECT name FROM products WHERE id = ? AND studio_id = ?`,
		productID, studioID,
	).Scan(&name)
	res, err := s.db.ExecContext(ctx,
		`UPDATE products SET is_archived = 1 WHERE id = ? AND studio_id = ?`,
		productID, studioID,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "product_archive", "product", productID,
		map[string]any{"name": name})
	return nil
}

type ClassType struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Discipline string `json:"discipline"`
}

func (s *Store) ListClassTypes(ctx context.Context, studioID string) ([]ClassType, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, name, COALESCE(discipline,'')
		  FROM class_types
		 WHERE studio_id = ?
		 ORDER BY name ASC`,
		studioID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ClassType, 0)
	for rows.Next() {
		var c ClassType
		if err := rows.Scan(&c.ID, &c.Name, &c.Discipline); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

type ClassTypeInput struct {
	Name       string `json:"name"`
	Discipline string `json:"discipline"`
}

func (s *Store) CreateClassType(ctx context.Context, studioID, actorID string, in ClassTypeInput) (string, error) {
	name := strings.TrimSpace(in.Name)
	if name == "" {
		return "", fmt.Errorf("name is required")
	}
	id := NewID()
	disc := sql.NullString{String: strings.TrimSpace(in.Discipline), Valid: in.Discipline != ""}
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO class_types (id, studio_id, name, discipline)
		     VALUES (?, ?, ?, ?)`,
		id, studioID, name, disc,
	); err != nil {
		return "", err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "class_type_create", "class_type", id, map[string]any{
		"name":       name,
		"discipline": in.Discipline,
	})
	return id, nil
}

func (s *Store) UpdateClassType(ctx context.Context, studioID, actorID, id string, in ClassTypeInput) error {
	name := strings.TrimSpace(in.Name)
	if name == "" {
		return fmt.Errorf("name is required")
	}
	disc := sql.NullString{String: strings.TrimSpace(in.Discipline), Valid: in.Discipline != ""}
	// Snapshot the prior values BEFORE the UPDATE so a rename or
	// discipline change is observable on the audit row — the activity
	// log can render "TYPE EDIT · Mat Pilates ← Pilates" with both
	// names side-by-side.
	var prevName string
	var prevDisc sql.NullString
	_ = s.db.QueryRowContext(ctx,
		`SELECT name, discipline FROM class_types WHERE id = ? AND studio_id = ?`,
		id, studioID,
	).Scan(&prevName, &prevDisc)
	res, err := s.db.ExecContext(ctx, `
		UPDATE class_types
		   SET name = ?, discipline = ?
		 WHERE id = ? AND studio_id = ?`,
		name, disc, id, studioID,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	detail := map[string]any{
		"name":       name,
		"discipline": in.Discipline,
	}
	if prevName != "" && prevName != name {
		detail["previous_name"] = prevName
	}
	if prevDisc.Valid && prevDisc.String != in.Discipline {
		detail["previous_discipline"] = prevDisc.String
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "class_type_update", "class_type", id, detail)
	return nil
}

// (Keep this import used.)
var _ = json.Marshal
