package store

import (
	"context"
	"database/sql"
	"time"
)

// EntitlementWalletItem is one row in /me/entitlements — active or history.
type EntitlementWalletItem struct {
	ID               string   `json:"id"`
	Label            string   `json:"label"`
	PassKind         string   `json:"pass_kind"`
	Status           string   `json:"status"`
	CreditsTotal     *int     `json:"credits_total,omitempty"`
	CreditsRemaining *int     `json:"credits_remaining,omitempty"`
	ExpiresAt        string   `json:"expires_at,omitempty"`
	CreatedAt        string   `json:"created_at"`
	Disciplines      []string `json:"disciplines"`
	// Lets the buy flow detect "you already own this pass" warnings.
	SourceProductID *string `json:"source_product_id,omitempty"`
}

// MyEntitlements returns the caller's entitlements, freshest first.
// Status reflects current reality (re-derived from expiry / credits).
func (s *Store) MyEntitlements(ctx context.Context, userID string) ([]EntitlementWalletItem, error) {
	const q = `
		SELECT e.id, e.label, e.pass_kind, e.status,
		       e.credits_total, e.credits_remaining,
		       COALESCE(e.expires_at,''), e.created_at,
		       e.source_product_id
		  FROM entitlements e
		 WHERE e.user_id = ?
		 ORDER BY (e.status = 'active') DESC, e.created_at DESC`
	rows, err := s.db.QueryContext(ctx, q, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]EntitlementWalletItem, 0)
	ids := []any{}
	for rows.Next() {
		var (
			it       EntitlementWalletItem
			creditsT sql.NullInt64
			creditsR sql.NullInt64
			srcProd  sql.NullString
		)
		if err := rows.Scan(&it.ID, &it.Label, &it.PassKind, &it.Status,
			&creditsT, &creditsR, &it.ExpiresAt, &it.CreatedAt, &srcProd); err != nil {
			return nil, err
		}
		if srcProd.Valid {
			s := srcProd.String
			it.SourceProductID = &s
		}
		if creditsT.Valid {
			n := int(creditsT.Int64)
			it.CreditsTotal = &n
		}
		if creditsR.Valid {
			n := int(creditsR.Int64)
			it.CreditsRemaining = &n
		}
		// Lazy "depleted/expired" rederivation — DB row may still say active
		// because we haven't wired a sweep job yet.
		now := time.Now().UTC()
		if it.Status == "active" {
			if it.ExpiresAt != "" {
				if t, err := time.Parse(time.RFC3339, it.ExpiresAt); err == nil && t.Before(now) {
					it.Status = "expired"
				}
			}
			if it.Status == "active" && it.PassKind == "credit" && it.CreditsRemaining != nil && *it.CreditsRemaining <= 0 {
				it.Status = "depleted"
			}
		}
		out = append(out, it)
		ids = append(ids, it.ID)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Hydrate discipline coverage in one pass.
	if len(ids) == 0 {
		return out, nil
	}
	placeholders := ""
	for i := range ids {
		if i > 0 {
			placeholders += ","
		}
		placeholders += "?"
	}
	jq := `
		SELECT ect.entitlement_id, COALESCE(ct.discipline,'')
		  FROM entitlement_class_types ect
		  JOIN class_types ct ON ct.id = ect.class_type_id
		 WHERE ect.entitlement_id IN (` + placeholders + `)`
	jrows, err := s.db.QueryContext(ctx, jq, ids...)
	if err != nil {
		return nil, err
	}
	defer jrows.Close()
	seen := map[string]map[string]struct{}{}
	for jrows.Next() {
		var eid, d string
		if err := jrows.Scan(&eid, &d); err != nil {
			return nil, err
		}
		if d == "" {
			continue
		}
		if seen[eid] == nil {
			seen[eid] = map[string]struct{}{}
		}
		seen[eid][d] = struct{}{}
	}
	for i := range out {
		for d := range seen[out[i].ID] {
			out[i].Disciplines = append(out[i].Disciplines, d)
		}
	}
	return out, nil
}

// MyPurchase is one row in /purchases?scope=mine.
type MyPurchase struct {
	ID            string `json:"id"`
	ProductName   string `json:"product_name"`
	AmountMinor   int    `json:"amount_minor"`
	Currency      string `json:"currency"`
	PaymentMethod string `json:"payment_method"`
	Status        string `json:"status"`
	CreatedAt     string `json:"created_at"`
	// PassAwarded is true when this purchase actually minted an entitlement
	// (resulting_entitlement_id is set). Distinguishes a completed/refunded
	// row that put a pass in the wallet from a pending/voided one that never
	// did — so the history can say so plainly rather than implying a pass.
	PassAwarded bool `json:"pass_awarded"`
}

func (s *Store) MyPurchases(ctx context.Context, userID string) ([]MyPurchase, error) {
	const q = `
		SELECT pu.id, p.name, pu.amount_minor, pu.currency,
		       pu.payment_method, pu.status, pu.created_at,
		       pu.resulting_entitlement_id
		  FROM purchases pu
		  JOIN products  p ON p.id = pu.product_id
		 WHERE pu.user_id = ?
		 ORDER BY pu.created_at DESC`
	rows, err := s.db.QueryContext(ctx, q, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]MyPurchase, 0)
	for rows.Next() {
		var (
			p           MyPurchase
			entitlement sql.NullString
		)
		if err := rows.Scan(&p.ID, &p.ProductName, &p.AmountMinor, &p.Currency,
			&p.PaymentMethod, &p.Status, &p.CreatedAt, &entitlement); err != nil {
			return nil, err
		}
		p.PassAwarded = entitlement.Valid
		out = append(out, p)
	}
	return out, rows.Err()
}

// AttendanceSummary feeds the Profile stats card + 12-week bar chart.
type AttendanceSummary struct {
	ThisMonth    int   `json:"this_month"`
	AllTime      int   `json:"all_time"`
	WeekStreak   int   `json:"week_streak"`
	WeeklyCounts []int `json:"weekly_counts"` // length 12, oldest → newest
}

// MyAttendance counts the user's "attended" sessions — i.e. bookings whose
// class has already started and that weren't cancelled or marked no_show.
// In the absence of a roster check-in flow yet, "attended" is implied for
// any non-cancelled, non-no_show booking on a class that's already past.
func (s *Store) MyAttendance(ctx context.Context, userID string) (*AttendanceSummary, error) {
	// Resolve the user's studio so we can compute "this month" and "this
	// week" in studio time. A user without a studio (shouldn't happen) or
	// an unparseable timezone falls back to UTC inside StudioLocation.
	var studioID string
	if err := s.db.QueryRowContext(ctx,
		`SELECT studio_id FROM users WHERE id = ?`, userID,
	).Scan(&studioID); err != nil {
		return nil, err
	}
	loc := s.StudioLocation(ctx, studioID)
	now := time.Now()

	// All-time count.
	out := &AttendanceSummary{WeeklyCounts: make([]int, 12)}
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM bookings b
		  JOIN classes c ON c.id = b.class_id
		 WHERE b.user_id = ?
		   AND b.status IN ('booked','attended')
		   AND c.starts_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
		userID,
	).Scan(&out.AllTime); err != nil {
		return nil, err
	}

	// This month — boundary is the 1st of the month in studio time.
	monthStart := startOfMonthIn(now, loc)
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM bookings b
		  JOIN classes c ON c.id = b.class_id
		 WHERE b.user_id = ?
		   AND b.status IN ('booked','attended')
		   AND c.starts_at >= ? AND c.starts_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
		userID, monthStart.UTC().Format(time.RFC3339),
	).Scan(&out.ThisMonth); err != nil {
		return nil, err
	}

	// Per-week histogram, last 12 weeks anchored on Monday in studio time.
	monday := mondayOfIn(now, loc)
	for i := 0; i < 12; i++ {
		weekStart := monday.AddDate(0, 0, -7*(11-i))
		weekEnd := weekStart.AddDate(0, 0, 7)
		var n int
		if err := s.db.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM bookings b
			  JOIN classes c ON c.id = b.class_id
			 WHERE b.user_id = ?
			   AND b.status IN ('booked','attended')
			   AND c.starts_at >= ? AND c.starts_at < ?
			   AND c.starts_at <  strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
			userID,
			weekStart.UTC().Format(time.RFC3339),
			weekEnd.UTC().Format(time.RFC3339),
		).Scan(&n); err != nil {
			return nil, err
		}
		out.WeeklyCounts[i] = n
	}

	// Streak: trailing consecutive weeks with >=1 attended session, starting
	// from the most recent non-empty week (so taking this week off doesn't
	// reset). Counting from index 11 (current week) backwards.
	streak := 0
	started := false
	for i := 11; i >= 0; i-- {
		if out.WeeklyCounts[i] > 0 {
			streak++
			started = true
		} else if started {
			break
		}
	}
	out.WeekStreak = streak
	return out, nil
}

func mondayOf(t time.Time) time.Time {
	offset := (int(t.Weekday()) + 6) % 7 // Mon=0, ..., Sun=6
	return time.Date(t.Year(), t.Month(), t.Day()-offset, 0, 0, 0, 0, time.UTC)
}
