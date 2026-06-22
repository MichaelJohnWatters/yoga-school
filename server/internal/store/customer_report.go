package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// CustomerReport is what GET /admin/reports/customers returns: one row per
// student with spend / attendance aggregated over the selected window, plus
// their current pass status. It's the fixed, curated counterpart to the
// whitelisted report builder — managers reach for this when they want the
// standard "who are my customers" view without composing a query.
type CustomerReport struct {
	Currency string              `json:"currency"`
	Rows     []CustomerReportRow `json:"rows"`
}

type CustomerReportRow struct {
	UserID   string `json:"user_id"`
	FullName string `json:"full_name"`
	Email    string `json:"email"`
	JoinedAt string `json:"joined_at"`
	// Visits and NoShows count past bookings whose class starts in the window.
	Visits     int `json:"visits"`
	NoShows    int `json:"no_shows"`
	SpendMinor int `json:"spend_minor"` // net (amount paid) on completed purchases in window
	// LastSeenAt is the most recent attended class (lifetime, not windowed) so
	// "haven't seen them since March" reads correctly regardless of the filter.
	LastSeenAt      *string `json:"last_seen_at,omitempty"`
	ActivePassLabel string  `json:"active_pass_label"`
}

// customerSortOrders whitelists the ORDER BY clauses so the sort param can be
// interpolated safely (never user SQL).
var customerSortOrders = map[string]string{
	"spend":    "spend DESC, u.full_name ASC",
	"visits":   "visits DESC, u.full_name ASC",
	"no_shows": "no_shows DESC, u.full_name ASC",
	"name":     "u.full_name ASC",
}

// CustomerReportFor returns per-student rows scoped to studioID. The window
// [from, to) bounds spend and visit/no-show counts; sort is one of
// spend|visits|no_shows|name (default spend); q optionally filters by name or
// email.
func (s *Store) CustomerReportFor(ctx context.Context, studioID string, from, to time.Time, sort, q string) (*CustomerReport, error) {
	order, ok := customerSortOrders[sort]
	if !ok {
		order = customerSortOrders["spend"]
	}
	fromS := from.UTC().Format(time.RFC3339)
	toS := to.UTC().Format(time.RFC3339)

	out := &CustomerReport{Rows: []CustomerReportRow{}}
	if err := s.db.QueryRowContext(ctx,
		`SELECT currency FROM studios WHERE id = ?`, studioID,
	).Scan(&out.Currency); err != nil {
		return nil, err
	}

	args := []any{fromS, toS, fromS, toS, fromS, toS, studioID}
	query := `
		SELECT u.id, u.full_name, u.email, u.created_at,
		       (SELECT COUNT(*) FROM bookings b
		          JOIN classes c ON c.id = b.class_id
		         WHERE b.user_id = u.id AND b.status = 'attended'
		           AND c.starts_at >= ? AND c.starts_at < ?) AS visits,
		       (SELECT COUNT(*) FROM bookings b
		          JOIN classes c ON c.id = b.class_id
		         WHERE b.user_id = u.id AND b.status = 'no_show'
		           AND c.starts_at >= ? AND c.starts_at < ?) AS no_shows,
		       (SELECT COALESCE(SUM(p.amount_minor), 0) FROM purchases p
		         WHERE p.user_id = u.id AND p.status = 'completed'
		           AND p.created_at >= ? AND p.created_at < ?) AS spend,
		       (SELECT MAX(c.starts_at) FROM bookings b
		          JOIN classes c ON c.id = b.class_id
		         WHERE b.user_id = u.id AND b.status = 'attended'
		           AND c.starts_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')) AS last_seen
		  FROM users u
		 WHERE u.studio_id = ? AND u.role = 'student'`
	if q != "" {
		query += ` AND (u.full_name LIKE ? OR u.email LIKE ?)`
		args = append(args, "%"+q+"%", "%"+q+"%")
	}
	query += ` ORDER BY ` + order + ` LIMIT 500`

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	ids := make([]any, 0)
	for rows.Next() {
		var (
			r        CustomerReportRow
			lastSeen sql.NullString
		)
		if err := rows.Scan(&r.UserID, &r.FullName, &r.Email, &r.JoinedAt,
			&r.Visits, &r.NoShows, &r.SpendMinor, &lastSeen); err != nil {
			return nil, err
		}
		if lastSeen.Valid {
			v := lastSeen.String
			r.LastSeenAt = &v
		}
		r.ActivePassLabel = "—"
		out.Rows = append(out.Rows, r)
		ids = append(ids, r.UserID)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	labels, err := s.activePassLabels(ctx, studioID, ids)
	if err != nil {
		return nil, err
	}
	for i := range out.Rows {
		if l, ok := labels[out.Rows[i].UserID]; ok {
			out.Rows[i].ActivePassLabel = l
		}
	}
	return out, nil
}

// activePassLabels maps user_id → a concise active-pass label ("Unlimited",
// "5 credits") for the given ids. Users with no active pass are simply absent.
// Mirrors the "best active entitlement" pick used by ListAdminStudents.
func (s *Store) activePassLabels(ctx context.Context, studioID string, ids []any) (map[string]string, error) {
	out := map[string]string{}
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
	q := `
		SELECT user_id, pass_kind, credits_remaining
		  FROM entitlements
		 WHERE studio_id = ?
		   AND status = 'active'
		   AND user_id IN (` + placeholders + `)
		   AND (expires_at IS NULL OR expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now'))
		   AND (pass_kind = 'unlimited' OR credits_remaining > 0)
		 ORDER BY (pass_kind = 'unlimited') DESC, credits_remaining DESC, expires_at ASC`
	args := append([]any{studioID}, ids...)
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			uid, kind string
			credits   sql.NullInt64
		)
		if err := rows.Scan(&uid, &kind, &credits); err != nil {
			return nil, err
		}
		if _, seen := out[uid]; seen {
			continue // first row wins (best pass, per ORDER BY)
		}
		if kind == "unlimited" {
			out[uid] = "Unlimited"
		} else if credits.Valid {
			out[uid] = fmt.Sprintf("%d credits", credits.Int64)
		}
	}
	return out, rows.Err()
}
