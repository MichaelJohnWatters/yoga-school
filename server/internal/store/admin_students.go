package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// StudentSummary is one row in GET /admin/students.
type StudentSummary struct {
	ID                 string  `json:"id"`
	FullName           string  `json:"full_name"`
	Email              string  `json:"email"`
	PhotoURL           *string `json:"photo_url,omitempty"`
	ActivePassLabel    string  `json:"active_pass_label"`
	ActivePassDetail   string  `json:"active_pass_detail"` // "3 of 5 left · expires 12 Aug"
	HasActivePass      bool    `json:"has_active_pass"`
	LastVisit          *string `json:"last_visit,omitempty"`
	CreatedAt          string  `json:"created_at"`
}

func (s *Store) ListAdminStudents(ctx context.Context, studioID, query string) ([]StudentSummary, []int, error) {
	args := []any{studioID, "student"}
	q := `
		SELECT u.id, u.full_name, u.email, u.photo_url, u.created_at,
		       (SELECT MAX(c.starts_at) FROM bookings b
		           JOIN classes c ON c.id = b.class_id
		          WHERE b.user_id = u.id
		            AND b.status IN ('booked','attended')
		            AND c.starts_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')
		       ) AS last_visit
		  FROM users u
		 WHERE u.studio_id = ?
		   AND u.role = ?`
	if query != "" {
		q += ` AND (u.full_name LIKE ? OR u.email LIKE ?)`
		args = append(args, "%"+query+"%", "%"+query+"%")
	}
	q += ` ORDER BY u.full_name ASC LIMIT 500`

	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	out := make([]StudentSummary, 0)
	ids := make([]any, 0)
	for rows.Next() {
		var (
			st    StudentSummary
			photo sql.NullString
			lv    sql.NullString
		)
		if err := rows.Scan(&st.ID, &st.FullName, &st.Email, &photo, &st.CreatedAt, &lv); err != nil {
			return nil, nil, err
		}
		if photo.Valid {
			p := photo.String
			st.PhotoURL = &p
		}
		if lv.Valid {
			p := lv.String
			st.LastVisit = &p
		}
		out = append(out, st)
		ids = append(ids, st.ID)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	if len(out) == 0 {
		return out, []int{0, 0}, nil
	}

	// Hydrate "active pass" summary per student. We pick the best active
	// entitlement: unlimited > most credits remaining > furthest expiry.
	placeholders := ""
	for i := range ids {
		if i > 0 {
			placeholders += ","
		}
		placeholders += "?"
	}
	eq := `
		SELECT user_id, label, pass_kind, credits_remaining, expires_at
		  FROM entitlements
		 WHERE studio_id = ?
		   AND status = 'active'
		   AND user_id IN (` + placeholders + `)
		   AND (expires_at IS NULL OR expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now'))
		   AND (pass_kind = 'unlimited' OR credits_remaining > 0)
		 ORDER BY (pass_kind = 'unlimited') DESC, credits_remaining DESC, expires_at ASC`
	eqArgs := append([]any{studioID}, ids...)
	erows, err := s.db.QueryContext(ctx, eq, eqArgs...)
	if err != nil {
		return nil, nil, err
	}
	defer erows.Close()
	best := map[string]struct {
		label    string
		kind     string
		credits  *int
		expires  string
	}{}
	for erows.Next() {
		var (
			uid, label, kind string
			credits          sql.NullInt64
			expires          sql.NullString
		)
		if err := erows.Scan(&uid, &label, &kind, &credits, &expires); err != nil {
			return nil, nil, err
		}
		if _, seen := best[uid]; seen {
			continue
		}
		var c *int
		if credits.Valid {
			n := int(credits.Int64)
			c = &n
		}
		exp := ""
		if expires.Valid {
			exp = expires.String
		}
		best[uid] = struct {
			label   string
			kind    string
			credits *int
			expires string
		}{label, kind, c, exp}
	}

	for i := range out {
		b, ok := best[out[i].ID]
		if !ok {
			continue
		}
		out[i].ActivePassLabel = b.label
		out[i].HasActivePass = true
		parts := []string{}
		if b.kind == "credit" && b.credits != nil {
			parts = append(parts, fmt.Sprintf("%d left", *b.credits))
		} else if b.kind == "unlimited" {
			parts = append(parts, "Unlimited")
		}
		if b.expires != "" {
			if t, err := time.Parse(time.RFC3339, b.expires); err == nil {
				parts = append(parts, "expires "+t.Format("2 Jan"))
			}
		}
		out[i].ActivePassDetail = stringJoin(parts, " · ")
	}

	counts := []int{len(out), 0}
	for _, st := range out {
		if st.HasActivePass {
			counts[1]++
		}
	}
	return out, counts, nil
}

func stringJoin(parts []string, sep string) string {
	switch len(parts) {
	case 0:
		return ""
	case 1:
		return parts[0]
	}
	r := parts[0]
	for _, p := range parts[1:] {
		r += sep + p
	}
	return r
}

// StudentDetail is what GET /admin/students/{id} returns.
type StudentDetail struct {
	ID            string                 `json:"id"`
	FullName      string                 `json:"full_name"`
	Email         string                 `json:"email"`
	PhotoURL      *string                `json:"photo_url,omitempty"`
	CreatedAt     string                 `json:"created_at"`
	Entitlements  []EntitlementWalletItem `json:"entitlements"`
	Purchases     []MyPurchase            `json:"purchases"`
	UpcomingClasses []UpcomingBooking     `json:"upcoming"`
}

func (s *Store) GetAdminStudent(ctx context.Context, studioID, userID string) (*StudentDetail, error) {
	var d StudentDetail
	var photo sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT id, full_name, email, photo_url, created_at
		  FROM users WHERE id = ? AND studio_id = ? AND role = 'student'`,
		userID, studioID,
	).Scan(&d.ID, &d.FullName, &d.Email, &photo, &d.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if photo.Valid {
		p := photo.String
		d.PhotoURL = &p
	}

	if d.Entitlements, err = s.MyEntitlements(ctx, userID); err != nil {
		return nil, err
	}
	if d.Purchases, err = s.MyPurchases(ctx, userID); err != nil {
		return nil, err
	}
	if d.UpcomingClasses, err = s.UpcomingBookings(ctx, userID); err != nil {
		return nil, err
	}
	return &d, nil
}

// ===== money mutators =====================================================

// GrantPassInput is the body for POST /admin/students/{id}/grant.
type GrantPassInput struct {
	ProductID     string `json:"product_id"`
	PaymentMethod string `json:"payment_method"`
	AmountMinor   *int   `json:"amount_minor,omitempty"`
	Note          string `json:"note,omitempty"`
}

type GrantPassResult struct {
	PurchaseID     string `json:"purchase_id"`
	EntitlementID  string `json:"entitlement_id"`
}

func (s *Store) GrantPass(ctx context.Context, studioID, actorID, studentID string, in GrantPassInput) (*GrantPassResult, error) {
	switch in.PaymentMethod {
	case "cash", "card", "card_present", "transfer", "comp", "dev_stub":
	default:
		return nil, fmt.Errorf("payment_method must be cash|card|card_present|transfer|comp")
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
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
		  FROM products p JOIN studios s ON s.id = p.studio_id
		 WHERE p.id = ? AND p.studio_id = ? AND p.is_archived = 0`,
		in.ProductID, studioID,
	).Scan(&name, &currency, &billingType, &passKind, &priceMinor, &credits, &validityDays)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("product not found")
	}
	if err != nil {
		return nil, err
	}
	amount := priceMinor
	if in.AmountMinor != nil {
		amount = *in.AmountMinor
	}

	purchaseID := uuid.NewString()
	entitlementID := uuid.NewString()
	var creditsT, creditsR any
	if credits.Valid {
		creditsT = int(credits.Int64)
		creditsR = int(credits.Int64)
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
		entitlementID, studioID, studentID, in.ProductID, passKind, name,
		creditsT, creditsR, expiresAt,
	); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO entitlement_class_types (entitlement_id, class_type_id)
		  SELECT ?, class_type_id FROM product_class_types WHERE product_id = ?`,
		entitlementID, in.ProductID,
	); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO purchases
		  (id, studio_id, user_id, product_id, amount_minor, currency,
		   payment_method, initiated_by, actor_role, status, resulting_entitlement_id)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'manager', 'completed', ?)`,
		purchaseID, studioID, studentID, in.ProductID, amount, currency,
		in.PaymentMethod, actorID, entitlementID,
	); err != nil {
		return nil, err
	}

	// Audit.
	if err := s.writeAuditTx(ctx, tx, studioID, actorID, "cash_grant", "entitlement", entitlementID, map[string]any{
		"student_id":     studentID,
		"product_id":     in.ProductID,
		"amount_minor":   amount,
		"payment_method": in.PaymentMethod,
		"note":           in.Note,
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &GrantPassResult{PurchaseID: purchaseID, EntitlementID: entitlementID}, nil
}

type AdjustCreditsInput struct {
	Delta  int    `json:"delta"`
	Reason string `json:"reason"`
}

func (s *Store) AdjustCredits(ctx context.Context, studioID, actorID, entitlementID string, in AdjustCreditsInput) error {
	if in.Delta == 0 {
		return fmt.Errorf("delta must be non-zero")
	}
	if in.Reason == "" {
		return fmt.Errorf("reason is required")
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var (
		kind     string
		current  sql.NullInt64
		total    sql.NullInt64
		userID   string
		owned    int
	)
	err = tx.QueryRowContext(ctx, `
		SELECT e.pass_kind, e.credits_remaining, e.credits_total, e.user_id,
		       COUNT(*) OVER ()
		  FROM entitlements e
		 WHERE e.id = ? AND e.studio_id = ?`,
		entitlementID, studioID,
	).Scan(&kind, &current, &total, &userID, &owned)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if kind != "credit" {
		return fmt.Errorf("only credit-kind passes can be adjusted")
	}
	if !current.Valid {
		return fmt.Errorf("entitlement has no credits field")
	}
	next := int(current.Int64) + in.Delta
	if next < 0 {
		return fmt.Errorf("would go below zero")
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE entitlements SET credits_remaining = ? WHERE id = ?`,
		next, entitlementID,
	); err != nil {
		return err
	}

	if err := s.writeAuditTx(ctx, tx, studioID, actorID, "credit_adjust", "entitlement", entitlementID, map[string]any{
		"student_id": userID,
		"delta":      in.Delta,
		"before":     current.Int64,
		"after":      next,
		"reason":     in.Reason,
	}); err != nil {
		return err
	}
	return tx.Commit()
}

type VoidInput struct {
	Refund string `json:"refund"` // none | unused | full
	Reason string `json:"reason"`
}

type VoidResult struct {
	RefundedMinor int    `json:"refunded_minor"`
	Currency      string `json:"currency"`
}

func (s *Store) VoidEntitlement(ctx context.Context, studioID, actorID, entitlementID string, in VoidInput) (*VoidResult, error) {
	if in.Reason == "" {
		return nil, fmt.Errorf("reason is required")
	}
	switch in.Refund {
	case "none", "unused", "full":
	default:
		return nil, fmt.Errorf("refund must be none|unused|full")
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var (
		userID, status, kind string
		credR, credT         sql.NullInt64
	)
	err = tx.QueryRowContext(ctx, `
		SELECT user_id, status, pass_kind, credits_remaining, credits_total
		  FROM entitlements WHERE id = ? AND studio_id = ?`,
		entitlementID, studioID,
	).Scan(&userID, &status, &kind, &credR, &credT)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if status == "voided" {
		return nil, fmt.Errorf("already voided")
	}

	// Look up the purchase for amount + currency.
	var amount int
	var currency, paymentMethod, purchaseID string
	err = tx.QueryRowContext(ctx, `
		SELECT id, amount_minor, currency, payment_method
		  FROM purchases WHERE resulting_entitlement_id = ?`,
		entitlementID,
	).Scan(&purchaseID, &amount, &currency, &paymentMethod)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	// Compute refund amount.
	refunded := 0
	switch in.Refund {
	case "full":
		refunded = amount
	case "unused":
		if kind == "credit" && credR.Valid && credT.Valid && credT.Int64 > 0 {
			refunded = int(int64(amount) * credR.Int64 / credT.Int64)
		} else {
			refunded = amount // unlimited fallback: refund full
		}
	}

	// Cancel upcoming bookings that used this entitlement.
	if _, err := tx.ExecContext(ctx, `
		UPDATE bookings
		   SET status = 'cancelled',
		       cancelled_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE entitlement_id = ?
		   AND status = 'booked'
		   AND EXISTS (
		     SELECT 1 FROM classes c
		      WHERE c.id = bookings.class_id
		        AND c.starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
		   )`,
		entitlementID,
	); err != nil {
		return nil, err
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE entitlements SET status = 'voided' WHERE id = ?`,
		entitlementID,
	); err != nil {
		return nil, err
	}
	if purchaseID != "" {
		newStatus := "voided"
		if refunded > 0 {
			newStatus = "refunded"
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE purchases SET status = ? WHERE id = ?`,
			newStatus, purchaseID,
		); err != nil {
			return nil, err
		}
	}

	if err := s.writeAuditTx(ctx, tx, studioID, actorID, "void", "entitlement", entitlementID, map[string]any{
		"student_id":      userID,
		"refund_option":   in.Refund,
		"refunded_minor":  refunded,
		"payment_method":  paymentMethod,
		"reason":          in.Reason,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &VoidResult{RefundedMinor: refunded, Currency: currency}, nil
}

func (s *Store) writeAuditTx(ctx context.Context, tx *sql.Tx, studioID, actorID, action, targetType, targetID string, detail map[string]any) error {
	b, err := json.Marshal(detail)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO audit_log (id, studio_id, actor_id, action, target_type, target_id, detail)
		     VALUES (?, ?, ?, ?, ?, ?, ?)`,
		uuid.NewString(), studioID, actorID, action, targetType, targetID, string(b),
	)
	return err
}
