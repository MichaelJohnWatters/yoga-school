package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Discount kinds. Keep in sync with the CHECK constraint in schema.sql.
const (
	DiscountKindPercent    = "percent"     // value 1..100
	DiscountKindFixedMinor = "fixed_minor" // value in currency minor units
	DiscountKindComp       = "comp"        // 100% off; value ignored
)

// Discount is one row in the discounts table — the configured rule, not
// an applied instance. Applied instances live as discount_id + amount on
// individual purchases.
type Discount struct {
	ID                  string  `json:"id"`
	StudioID            string  `json:"studio_id"`
	Code                *string `json:"code,omitempty"` // null = manager-only / ad-hoc
	Kind                string  `json:"kind"`
	Value               int     `json:"value"`
	AppliesToProductID  *string `json:"applies_to_product_id,omitempty"`
	ValidFrom           *string `json:"valid_from,omitempty"` // RFC3339, UTC
	ValidTo             *string `json:"valid_to,omitempty"`
	MaxUses             *int    `json:"max_uses,omitempty"`
	MaxUsesPerUser      *int    `json:"max_uses_per_user,omitempty"`
	Notes               string  `json:"notes,omitempty"`
	CreatedBy           string  `json:"created_by"`
	CreatedAt           string  `json:"created_at"`
	ArchivedAt          *string `json:"archived_at,omitempty"`
	// Live usage stats joined in by ListDiscountsWithStats. Always zero
	// from the bare Get path.
	TimesUsed       int `json:"times_used"`
	TotalGivenMinor int `json:"total_given_minor"`
}

// DiscountCreate is the input shape for CreateDiscount. Pointer fields
// are optional; nil means "no constraint on this dimension".
type DiscountCreate struct {
	Code               *string
	Kind               string
	Value              int
	AppliesToProductID *string
	ValidFrom          *time.Time
	ValidTo            *time.Time
	MaxUses            *int
	MaxUsesPerUser     *int
	Notes              string
}

// ListDiscounts returns every discount for a studio, newest first.
// includeArchived=false hides retired rules from the management list.
// Stats columns are populated by a joined COUNT/SUM over purchases.
func (s *Store) ListDiscounts(ctx context.Context, studioID string, includeArchived bool) ([]Discount, error) {
	q := `
		SELECT d.id, d.studio_id, d.code, d.kind, d.value,
		       d.applies_to_product_id, d.valid_from, d.valid_to,
		       d.max_uses, d.max_uses_per_user, COALESCE(d.notes, ''),
		       d.created_by, d.created_at, d.archived_at,
		       (SELECT COUNT(*) FROM purchases p
		          WHERE p.discount_id = d.id
		            AND p.status = 'completed') AS times_used,
		       (SELECT COALESCE(SUM(p.discount_minor), 0) FROM purchases p
		          WHERE p.discount_id = d.id
		            AND p.status = 'completed') AS total_given
		  FROM discounts d
		 WHERE d.studio_id = ?`
	if !includeArchived {
		q += ` AND d.archived_at IS NULL`
	}
	q += ` ORDER BY d.created_at DESC`

	rows, err := s.db.QueryContext(ctx, q, studioID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Discount, 0)
	for rows.Next() {
		d, err := scanDiscountWithStats(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// GetDiscount fetches a single discount by id (no stats — list path does
// that). Returns ErrNotFound for unknown ids or cross-studio access.
func (s *Store) GetDiscount(ctx context.Context, studioID, id string) (*Discount, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT id, studio_id, code, kind, value,
		       applies_to_product_id, valid_from, valid_to,
		       max_uses, max_uses_per_user, COALESCE(notes, ''),
		       created_by, created_at, archived_at,
		       0, 0
		  FROM discounts
		 WHERE id = ? AND studio_id = ?`,
		id, studioID,
	)
	d, err := scanDiscountWithStats(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &d, nil
}

func (s *Store) CreateDiscount(ctx context.Context, studioID, actorID string, in DiscountCreate) (*Discount, error) {
	if err := validateDiscountInput(in); err != nil {
		return nil, err
	}
	id := NewID()
	var (
		codePtr, productPtr, fromPtr, toPtr any
		maxUses, maxPerUser                 any
	)
	if in.Code != nil {
		v := strings.ToUpper(strings.TrimSpace(*in.Code))
		if v == "" {
			return nil, fmt.Errorf("code: cannot be blank")
		}
		codePtr = v
	}
	if in.AppliesToProductID != nil && *in.AppliesToProductID != "" {
		productPtr = *in.AppliesToProductID
	}
	if in.ValidFrom != nil {
		fromPtr = in.ValidFrom.UTC().Format(time.RFC3339)
	}
	if in.ValidTo != nil {
		toPtr = in.ValidTo.UTC().Format(time.RFC3339)
	}
	if in.MaxUses != nil {
		maxUses = *in.MaxUses
	}
	if in.MaxUsesPerUser != nil {
		maxPerUser = *in.MaxUsesPerUser
	}
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO discounts
		  (id, studio_id, code, kind, value, applies_to_product_id,
		   valid_from, valid_to, max_uses, max_uses_per_user,
		   notes, created_by)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, studioID, codePtr, in.Kind, in.Value, productPtr,
		fromPtr, toPtr, maxUses, maxPerUser,
		strings.TrimSpace(in.Notes), actorID,
	); err != nil {
		return nil, fmt.Errorf("insert discount: %w", err)
	}
	auditDetail := map[string]any{
		"kind":  in.Kind,
		"value": in.Value,
	}
	if codePtr != nil {
		auditDetail["code"] = codePtr
	}
	if productPtr != nil {
		auditDetail["applies_to_product_id"] = productPtr
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "discount_create", "discount", id, auditDetail)
	return s.GetDiscount(ctx, studioID, id)
}

// UpdateDiscount overwrites a (non-archived) discount rule with the full input
// shape — the edit UI pre-fills the current values, so every column is set (or
// cleared to NULL) from `in`, avoiding sparse-patch ambiguity. Past purchases
// that already used the discount are unaffected; only future lookups see the
// new terms. Audited discount_update.
func (s *Store) UpdateDiscount(ctx context.Context, studioID, actorID, id string, in DiscountCreate) (*Discount, error) {
	if err := validateDiscountInput(in); err != nil {
		return nil, err
	}
	var (
		codePtr, productPtr, fromPtr, toPtr any
		maxUses, maxPerUser                 any
	)
	if in.Code != nil {
		v := strings.ToUpper(strings.TrimSpace(*in.Code))
		if v == "" {
			return nil, fmt.Errorf("code: cannot be blank")
		}
		codePtr = v
	}
	if in.AppliesToProductID != nil && *in.AppliesToProductID != "" {
		productPtr = *in.AppliesToProductID
	}
	if in.ValidFrom != nil {
		fromPtr = in.ValidFrom.UTC().Format(time.RFC3339)
	}
	if in.ValidTo != nil {
		toPtr = in.ValidTo.UTC().Format(time.RFC3339)
	}
	if in.MaxUses != nil {
		maxUses = *in.MaxUses
	}
	if in.MaxUsesPerUser != nil {
		maxPerUser = *in.MaxUsesPerUser
	}
	res, err := s.db.ExecContext(ctx, `
		UPDATE discounts
		   SET code = ?, kind = ?, value = ?, applies_to_product_id = ?,
		       valid_from = ?, valid_to = ?, max_uses = ?, max_uses_per_user = ?,
		       notes = ?
		 WHERE id = ? AND studio_id = ? AND archived_at IS NULL`,
		codePtr, in.Kind, in.Value, productPtr,
		fromPtr, toPtr, maxUses, maxPerUser,
		strings.TrimSpace(in.Notes), id, studioID,
	)
	if err != nil {
		return nil, fmt.Errorf("update discount: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrNotFound
	}
	auditDetail := map[string]any{"kind": in.Kind, "value": in.Value}
	if codePtr != nil {
		auditDetail["code"] = codePtr
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "discount_update", "discount", id, auditDetail)
	return s.GetDiscount(ctx, studioID, id)
}

// ArchiveDiscount retires a discount. Past purchases that used it stay
// linked — only future code lookups skip it.
func (s *Store) ArchiveDiscount(ctx context.Context, studioID, actorID, id string) error {
	// Snapshot code/kind/value before archiving so the audit reads as
	// "DISCOUNT ARCHIVED · SPRING25 (10%)" without a join. code is
	// optional on no-code (manager-grant) discounts — leave it out
	// when null so the UI doesn't render "code: null".
	var (
		code         sql.NullString
		kind         string
		value        int
	)
	_ = s.db.QueryRowContext(ctx,
		`SELECT code, kind, value FROM discounts
		 WHERE id = ? AND studio_id = ?`,
		id, studioID,
	).Scan(&code, &kind, &value)
	res, err := s.db.ExecContext(ctx, `
		UPDATE discounts
		   SET archived_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ? AND studio_id = ? AND archived_at IS NULL`,
		id, studioID,
	)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	detail := map[string]any{"kind": kind, "value": value}
	if code.Valid {
		detail["code"] = code.String
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "discount_archive", "discount", id, detail)
	return nil
}

// validateDiscountAndApplyTx looks up a discount by code, runs every
// usage/eligibility check inside the existing tx (so they're consistent
// with the purchase insert), and returns the computed discount amount.
//
// Pass an empty code to mean "no discount" — returns nil discount and 0
// off. That keeps the call sites simple (always call this, decide based
// on the result).
//
// Reasons it can fail (all return BookingError with one of these codes):
//   - discount_not_found    code didn't match any active discount
//   - discount_expired      outside valid_from/valid_to window
//   - discount_max_uses     totalUsage >= max_uses
//   - discount_user_max     this user's usage >= max_uses_per_user
//   - discount_wrong_product  rule scoped to a different product
func validateAndApplyDiscountTx(
	ctx context.Context, tx *sql.Tx,
	studioID, userID, productID, code string,
	listPriceMinor int,
) (discountID string, discountMinor int, err error) {
	code = strings.ToUpper(strings.TrimSpace(code))
	if code == "" {
		return "", 0, nil
	}

	var (
		d               Discount
		archivedAt      sql.NullString
		productID2      sql.NullString
		validFrom       sql.NullString
		validTo         sql.NullString
		maxUsesN        sql.NullInt64
		maxUsesPerUserN sql.NullInt64
	)
	err = tx.QueryRowContext(ctx, `
		SELECT id, kind, value, applies_to_product_id,
		       valid_from, valid_to, max_uses, max_uses_per_user,
		       archived_at
		  FROM discounts
		 WHERE studio_id = ? AND UPPER(code) = ?`,
		studioID, code,
	).Scan(&d.ID, &d.Kind, &d.Value, &productID2,
		&validFrom, &validTo, &maxUsesN, &maxUsesPerUserN, &archivedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, &BookingError{
			Code:    "discount_not_found",
			Message: "That code isn't valid.",
		}
	}
	if err != nil {
		return "", 0, err
	}
	if archivedAt.Valid {
		return "", 0, &BookingError{
			Code:    "discount_not_found",
			Message: "That code isn't valid.",
		}
	}

	now := time.Now().UTC()
	if validFrom.Valid {
		t, perr := time.Parse(time.RFC3339, validFrom.String)
		if perr == nil && now.Before(t) {
			return "", 0, &BookingError{
				Code:    "discount_expired",
				Message: "This code isn't active yet.",
			}
		}
	}
	if validTo.Valid {
		t, perr := time.Parse(time.RFC3339, validTo.String)
		if perr == nil && now.After(t) {
			return "", 0, &BookingError{
				Code:    "discount_expired",
				Message: "This code has expired.",
			}
		}
	}
	if productID2.Valid && productID2.String != productID {
		return "", 0, &BookingError{
			Code:    "discount_wrong_product",
			Message: "This code doesn't apply to that product.",
		}
	}
	if maxUsesN.Valid {
		var n int
		if err := tx.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM purchases
			 WHERE discount_id = ? AND status = 'completed'`,
			d.ID,
		).Scan(&n); err != nil {
			return "", 0, err
		}
		if int64(n) >= maxUsesN.Int64 {
			return "", 0, &BookingError{
				Code:    "discount_max_uses",
				Message: "This code has been fully used.",
			}
		}
	}
	if maxUsesPerUserN.Valid {
		var n int
		if err := tx.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM purchases
			 WHERE discount_id = ? AND user_id = ? AND status = 'completed'`,
			d.ID, userID,
		).Scan(&n); err != nil {
			return "", 0, err
		}
		if int64(n) >= maxUsesPerUserN.Int64 {
			return "", 0, &BookingError{
				Code:    "discount_user_max",
				Message: "You've already used this code.",
			}
		}
	}

	discountMinor = computeDiscountMinor(d.Kind, d.Value, listPriceMinor)
	return d.ID, discountMinor, nil
}

func computeDiscountMinor(kind string, value, listPriceMinor int) int {
	switch kind {
	case DiscountKindComp:
		return listPriceMinor
	case DiscountKindPercent:
		// Round half-up so 1.55 → 1.60 on a 10% discount feels right at
		// the receipt level. Operate in int math to avoid float drift.
		// (listPrice * value + 50) / 100 ≈ round-half-up.
		n := (listPriceMinor*value + 50) / 100
		if n > listPriceMinor {
			n = listPriceMinor
		}
		return n
	case DiscountKindFixedMinor:
		if value > listPriceMinor {
			return listPriceMinor // never refund the customer by going negative
		}
		return value
	}
	return 0
}

func validateDiscountInput(in DiscountCreate) error {
	switch in.Kind {
	case DiscountKindPercent:
		if in.Value < 1 || in.Value > 100 {
			return fmt.Errorf("value: percent must be 1..100")
		}
	case DiscountKindFixedMinor:
		if in.Value <= 0 {
			return fmt.Errorf("value: fixed amount must be > 0")
		}
	case DiscountKindComp:
		// value ignored — comp always means 100% off.
	default:
		return fmt.Errorf("kind: must be percent | fixed_minor | comp")
	}
	if in.MaxUses != nil && *in.MaxUses <= 0 {
		return fmt.Errorf("max_uses: must be > 0 when set")
	}
	if in.MaxUsesPerUser != nil && *in.MaxUsesPerUser <= 0 {
		return fmt.Errorf("max_uses_per_user: must be > 0 when set")
	}
	if in.ValidFrom != nil && in.ValidTo != nil && in.ValidTo.Before(*in.ValidFrom) {
		return fmt.Errorf("valid_to: must be after valid_from")
	}
	return nil
}

// scanDiscountWithStats reads a row from a query that selects the full
// Discount column list plus times_used + total_given_minor. Works on
// both *sql.Row (from QueryRow) and *sql.Rows (per-row Scan).
func scanDiscountWithStats(s interface {
	Scan(...any) error
}) (Discount, error) {
	var (
		d                                                  Discount
		code, productID, validFrom, validTo, archived, nts sql.NullString
		maxUses, maxPerUser                                sql.NullInt64
	)
	if err := s.Scan(
		&d.ID, &d.StudioID, &code, &d.Kind, &d.Value,
		&productID, &validFrom, &validTo,
		&maxUses, &maxPerUser, &nts,
		&d.CreatedBy, &d.CreatedAt, &archived,
		&d.TimesUsed, &d.TotalGivenMinor,
	); err != nil {
		return d, err
	}
	if code.Valid {
		v := code.String
		d.Code = &v
	}
	if productID.Valid {
		v := productID.String
		d.AppliesToProductID = &v
	}
	if validFrom.Valid {
		v := validFrom.String
		d.ValidFrom = &v
	}
	if validTo.Valid {
		v := validTo.String
		d.ValidTo = &v
	}
	if maxUses.Valid {
		v := int(maxUses.Int64)
		d.MaxUses = &v
	}
	if maxPerUser.Valid {
		v := int(maxPerUser.Int64)
		d.MaxUsesPerUser = &v
	}
	if nts.Valid {
		d.Notes = nts.String
	}
	if archived.Valid {
		v := archived.String
		d.ArchivedAt = &v
	}
	return d, nil
}

// RefundPurchase refunds money for a completed purchase. For card-backed
// purchases it issues a real Stripe refund against the PaymentIntent; for
// cash/comp/dev_stub it just records the money movement (settled out of band).
// Partial refunds reduce status to 'refunded' only when the cumulative refund
// reaches amount_minor.
//
// Side-effect intentionally limited: this does NOT void the resulting
// entitlement. Refunding $X to the customer is a money operation; the
// pass already in their wallet stays unless ops also runs VoidEntitlement
// — that's a separate decision (e.g. you might refund a customer
// goodwill and let them keep the pass).
func (s *Store) RefundPurchase(
	ctx context.Context,
	studioID, actorID, purchaseID string,
	refundAmountMinor int,
	note string,
) error {
	if refundAmountMinor <= 0 {
		return fmt.Errorf("refund_amount_minor: must be > 0")
	}

	// Validate against the current row before touching Stripe — we must not
	// issue a real refund for an already-refunded or over-refunded purchase.
	var (
		amountMinor      int
		alreadyRefunded  int
		status           string
		userID, userName string
		productName      string
		stripePaymentID  string
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT pu.amount_minor, pu.refund_amount_minor, pu.status,
		       pu.user_id, u.full_name, pr.name, COALESCE(pu.stripe_payment_id,'')
		  FROM purchases pu
		  JOIN users    u  ON u.id  = pu.user_id
		  JOIN products pr ON pr.id = pu.product_id
		 WHERE pu.id = ? AND pu.studio_id = ?`,
		purchaseID, studioID,
	).Scan(&amountMinor, &alreadyRefunded, &status, &userID, &userName, &productName, &stripePaymentID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if status == "refunded" {
		return fmt.Errorf("purchase already refunded")
	}
	if status != "completed" {
		return fmt.Errorf("can only refund completed purchases (status=%s)", status)
	}
	if alreadyRefunded+refundAmountMinor > amountMinor {
		return fmt.Errorf("refund would exceed amount paid")
	}
	newRefundTotal := alreadyRefunded + refundAmountMinor
	newStatus := status
	if newRefundTotal == amountMinor {
		newStatus = "refunded"
	}

	// Real Stripe refund (no-op for non-card). Done before the DB write and
	// outside any transaction — idempotency key keyed on the cumulative total
	// so a retry can't pay out twice.
	if err := s.issueStripeRefund(ctx, studioID, stripePaymentID, refundAmountMinor,
		fmt.Sprintf("%s:refund:%d", purchaseID, newRefundTotal)); err != nil {
		return err
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `
		UPDATE purchases
		   SET refund_amount_minor = ?,
		       refunded_at        = COALESCE(refunded_at, strftime('%Y-%m-%dT%H:%M:%fZ','now')),
		       refunded_by        = ?,
		       refund_note        = ?,
		       status             = ?
		 WHERE id = ?`,
		newRefundTotal, actorID, strings.TrimSpace(note), newStatus, purchaseID,
	); err != nil {
		return err
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		"purchase_refund", "purchase", purchaseID, map[string]any{
			"refund_amount_minor": refundAmountMinor,
			"total_refunded":      newRefundTotal,
			"final_status":        newStatus,
			"note":                note,
			"user_id":             userID,
			"user_name":           userName,
			"product_name":        productName,
		}); err != nil {
		return err
	}
	return tx.Commit()
}
