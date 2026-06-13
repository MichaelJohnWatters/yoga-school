package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/google/uuid"
)

type Notification struct {
	ID        string  `json:"id"`
	Type      string  `json:"type"`
	Title     string  `json:"title"`
	Body      string  `json:"body"`
	CreatedAt string  `json:"created_at"`
	ReadAt    *string `json:"read_at,omitempty"`
}

func (s *Store) NotificationsFeed(ctx context.Context, userID string) ([]Notification, error) {
	const q = `
		SELECT id, type, title, COALESCE(body,''), created_at, read_at
		  FROM notifications
		 WHERE user_id = ?
		 ORDER BY created_at DESC
		 LIMIT 100`
	rows, err := s.db.QueryContext(ctx, q, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Notification, 0)
	for rows.Next() {
		var (
			n      Notification
			readAt sql.NullString
		)
		if err := rows.Scan(&n.ID, &n.Type, &n.Title, &n.Body, &n.CreatedAt, &readAt); err != nil {
			return nil, err
		}
		if readAt.Valid {
			s := readAt.String
			n.ReadAt = &s
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

func (s *Store) MarkNotificationRead(ctx context.Context, userID, notificationID string) error {
	res, err := s.db.ExecContext(ctx, `
		UPDATE notifications
		   SET read_at = COALESCE(read_at, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
		 WHERE id = ? AND user_id = ?`,
		notificationID, userID,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) MarkAllNotificationsRead(ctx context.Context, userID string) (int, error) {
	res, err := s.db.ExecContext(ctx, `
		UPDATE notifications
		   SET read_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE user_id = ? AND read_at IS NULL`,
		userID,
	)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// CheckInPayload is what /me/checkin-code returns.
type CheckInPayload struct {
	Token       string         `json:"token"`
	UserName    string         `json:"user_name"`
	NextClass   *UpcomingBooking `json:"next_class,omitempty"`
}

func (s *Store) CheckInCode(ctx context.Context, userID string) (*CheckInPayload, error) {
	var (
		name  string
		token sql.NullString
	)
	err := s.db.QueryRowContext(ctx,
		`SELECT full_name, checkin_token FROM users WHERE id = ?`,
		userID,
	).Scan(&name, &token)
	if err != nil {
		return nil, err
	}
	out := &CheckInPayload{UserName: name}
	if token.Valid {
		out.Token = token.String
	} else {
		// Mint one on demand (real impl rotates).
		out.Token = "S52-" + uuid.NewString()[:8]
		_, _ = s.db.ExecContext(ctx,
			`UPDATE users SET checkin_token = ? WHERE id = ?`,
			out.Token, userID,
		)
	}
	// Next upcoming class for the chip.
	rows, err := s.UpcomingBookings(ctx, userID)
	if err == nil && len(rows) > 0 {
		out.NextClass = &rows[0]
	}
	return out, nil
}

// JoinWaitlist appends the caller at the end of the queue for a full class.
// Returns the assigned position (1-based).
func (s *Store) JoinWaitlist(ctx context.Context, userID, classID string) (int, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	var dummy int
	err = tx.QueryRowContext(ctx,
		`SELECT 1 FROM classes WHERE id = ? AND status = 'scheduled'`, classID,
	).Scan(&dummy)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, err
	}

	var maxPos sql.NullInt64
	if err := tx.QueryRowContext(ctx,
		`SELECT MAX(position) FROM waitlist_entries WHERE class_id = ?`, classID,
	).Scan(&maxPos); err != nil {
		return 0, err
	}
	pos := 1
	if maxPos.Valid {
		pos = int(maxPos.Int64) + 1
	}

	id := uuid.NewString()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO waitlist_entries (id, class_id, user_id, position)
		    VALUES (?, ?, ?, ?)`,
		id, classID, userID, pos,
	); err != nil {
		// Unique constraint = already on waitlist.
		return 0, fmt.Errorf("already on waitlist: %w", err)
	}
	return pos, tx.Commit()
}
