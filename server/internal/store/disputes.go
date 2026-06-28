package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// disputeIsOpen reports whether a Stripe dispute status still needs a manager's
// attention (vs already resolved). Anything not in the open set — won, lost,
// charge_refunded, *_closed, "" — drops off the attention list.
func disputeIsOpen(status string) bool {
	switch status {
	case "warning_needs_response", "warning_under_review",
		"needs_response", "under_review":
		return true
	default:
		return false
	}
}

// RecordDispute records a chargeback on the matching purchase and alerts the
// studio's managers. It deliberately does NOT touch the entitlement — money and
// pass are separate, and revoking is a manager decision on the "Payments
// needing attention" screen. Idempotent: a later .updated/.closed just
// overwrites the status. ErrNotFound when no purchase matches the disputed
// charge's PaymentIntent (e.g. a subscription invoice with no purchase row).
func (s *Store) RecordDispute(ctx context.Context, studioID string, evt payments.Event) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var purchaseID, userID string
	err = tx.QueryRowContext(ctx, `
		SELECT id, user_id FROM purchases
		 WHERE studio_id = ? AND stripe_payment_id = ?`,
		studioID, evt.IntentID,
	).Scan(&purchaseID, &userID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE purchases
		   SET dispute_status = ?, dispute_reason = ?, dispute_amount_minor = ?,
		       disputed_at = COALESCE(disputed_at, strftime('%Y-%m-%dT%H:%M:%fZ','now')),
		       dispute_due_at = ?
		 WHERE id = ?`,
		evt.DisputeStatus, evt.DisputeReason, evt.DisputeAmountMinor,
		nullableTime(evt.DisputeDueAt), purchaseID,
	); err != nil {
		return fmt.Errorf("record dispute: %w", err)
	}

	// Alert managers on the opening event only (avoid spamming on every
	// status update). The screen + feed badge carry the rest.
	var notified []string
	if evt.Type == "charge.dispute.created" {
		rows, err := tx.QueryContext(ctx, `
			SELECT id FROM users WHERE studio_id = ? AND role IN ('manager','owner')`,
			studioID)
		if err != nil {
			return err
		}
		var managers []string
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			managers = append(managers, id)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		payload := fmt.Sprintf(`{"purchase_id":"%s","student_id":"%s"}`, purchaseID, userID)
		for _, mgr := range managers {
			if _, err := tx.ExecContext(ctx, `
				INSERT INTO notifications (id, studio_id, user_id, type, title, body, payload)
				   VALUES (?, ?, ?, 'payment_dispute', 'Chargeback opened',
				           'A student disputed a payment — review it in Payments.', ?)`,
				NewID(), studioID, mgr, payload,
			); err != nil {
				return err
			}
			notified = append(notified, mgr)
		}
	}

	if err := tx.Commit(); err != nil {
		return err
	}
	for _, mgr := range notified {
		s.dispatchPush(mgr, "payment_dispute", "Chargeback opened",
			"A student disputed a payment — review it in Payments.", "")
	}
	return nil
}

// PaymentAttentionItem is one row on the manager's "Payments needing attention"
// screen — either an open chargeback or a past-due membership. The action
// fields tell the UI which control to offer: EntitlementID → "Void & revoke
// pass"; SubscriptionID → "Cancel membership".
type PaymentAttentionItem struct {
	Kind           string `json:"kind"` // 'dispute' | 'past_due_membership'
	StudentID      string `json:"student_id"`
	StudentName    string `json:"student_name"`
	ProductName    string `json:"product_name"`
	AmountMinor    int    `json:"amount_minor"`
	Currency       string `json:"currency"`
	Status         string `json:"status"` // dispute status, or 'past_due'
	Detail         string `json:"detail"` // dispute reason / "renewal payment failed"
	OccurredAt     string `json:"occurred_at"`
	DueAt          string `json:"due_at,omitempty"`
	EntitlementID  string `json:"entitlement_id,omitempty"`
	SubscriptionID string `json:"subscription_id,omitempty"`
	AttendedCount  int    `json:"attended_count"`
	UpcomingCount  int    `json:"upcoming_count"`
}

// AdminListPaymentsAttention returns open chargebacks + past-due memberships for
// the studio, newest first — the manager's single place to see "money problems"
// and act (revoke a pass, cancel a membership). Each row carries how many
// classes the student attended / still has booked on the affected pass, so the
// manager sees the real exposure before deciding.
func (s *Store) AdminListPaymentsAttention(ctx context.Context, studioID string) ([]PaymentAttentionItem, error) {
	out := make([]PaymentAttentionItem, 0)

	// Open disputes.
	dRows, err := s.db.QueryContext(ctx, `
		SELECT p.user_id, u.full_name, COALESCE(pr.name,''), p.amount_minor, p.currency,
		       COALESCE(p.dispute_status,''), COALESCE(p.dispute_reason,''),
		       COALESCE(p.disputed_at,''), COALESCE(p.dispute_due_at,''),
		       COALESCE(p.resulting_entitlement_id,''),
		       (SELECT COUNT(*) FROM bookings b WHERE b.entitlement_id = p.resulting_entitlement_id
		          AND b.status = 'attended') AS attended,
		       (SELECT COUNT(*) FROM bookings b JOIN classes c ON c.id = b.class_id
		         WHERE b.entitlement_id = p.resulting_entitlement_id AND b.status = 'booked'
		           AND c.starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')) AS upcoming
		  FROM purchases p
		  JOIN users u ON u.id = p.user_id
		  LEFT JOIN products pr ON pr.id = p.product_id
		 WHERE p.studio_id = ? AND p.dispute_status IS NOT NULL`, studioID)
	if err != nil {
		return nil, err
	}
	defer dRows.Close()
	for dRows.Next() {
		var it PaymentAttentionItem
		var entID string
		if err := dRows.Scan(&it.StudentID, &it.StudentName, &it.ProductName,
			&it.AmountMinor, &it.Currency, &it.Status, &it.Detail,
			&it.OccurredAt, &it.DueAt, &entID, &it.AttendedCount, &it.UpcomingCount); err != nil {
			return nil, err
		}
		if !disputeIsOpen(it.Status) {
			continue // resolved — drop off the attention list
		}
		it.Kind = "dispute"
		if entID != "" {
			it.EntitlementID = entID
		}
		out = append(out, it)
	}
	if err := dRows.Err(); err != nil {
		return nil, err
	}

	// Past-due memberships (a renewal that didn't get paid).
	sRows, err := s.db.QueryContext(ctx, `
		SELECT sub.id, sub.user_id, u.full_name, p.name, sub.amount_minor, sub.currency,
		       sub.updated_at, COALESCE(sub.entitlement_id,'')
		  FROM subscriptions sub
		  JOIN users u ON u.id = sub.user_id
		  JOIN products p ON p.id = sub.product_id
		 WHERE sub.studio_id = ? AND sub.status = 'past_due'`, studioID)
	if err != nil {
		return nil, err
	}
	defer sRows.Close()
	for sRows.Next() {
		var it PaymentAttentionItem
		var entID string
		if err := sRows.Scan(&it.SubscriptionID, &it.StudentID, &it.StudentName,
			&it.ProductName, &it.AmountMinor, &it.Currency, &it.OccurredAt, &entID); err != nil {
			return nil, err
		}
		it.Kind = "past_due_membership"
		it.Status = "past_due"
		it.Detail = "renewal payment failed"
		out = append(out, it)
	}
	if err := sRows.Err(); err != nil {
		return nil, err
	}

	// Newest first across both kinds.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].OccurredAt > out[j-1].OccurredAt; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out, nil
}
