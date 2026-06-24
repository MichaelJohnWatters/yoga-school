package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

type Notification struct {
	ID        string  `json:"id"`
	Type      string  `json:"type"`
	Title     string  `json:"title"`
	Body      string  `json:"body"`
	// Raw JSON-encoded payload — the client decodes per-type fields it
	// needs (e.g. chat_message carries conversation_id for tap routing).
	Payload   string  `json:"payload"`
	CreatedAt string  `json:"created_at"`
	ReadAt    *string `json:"read_at,omitempty"`
}

func (s *Store) NotificationsFeed(ctx context.Context, userID string) ([]Notification, error) {
	const q = `
		SELECT id, type, title, COALESCE(body,''),
		       COALESCE(payload,'{}'), created_at, read_at
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
		if err := rows.Scan(&n.ID, &n.Type, &n.Title, &n.Body,
			&n.Payload, &n.CreatedAt, &readAt); err != nil {
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

// DeleteNotification removes a single notification owned by userID (the
// swipe-to-dismiss action). Scoped to user_id so one user can't clear
// another's bell; ErrNotFound when nothing matches so the handler 404s.
// Not audited — clearing your own feed is high-frequency and carries no
// managerial significance, like the unaudited read-tracking.
func (s *Store) DeleteNotification(ctx context.Context, userID, notificationID string) error {
	res, err := s.db.ExecContext(ctx, `
		DELETE FROM notifications WHERE id = ? AND user_id = ?`,
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

// ClearReadNotifications deletes every already-read notification for userID,
// returning how many were removed. Unread rows are deliberately left alone
// so a bulk "clear" can never silently drop something the user hasn't seen.
func (s *Store) ClearReadNotifications(ctx context.Context, userID string) (int, error) {
	res, err := s.db.ExecContext(ctx, `
		DELETE FROM notifications WHERE user_id = ? AND read_at IS NOT NULL`,
		userID,
	)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// CheckInPayload is what /me/checkin-code returns.
//
// Under the per-booking single-use scheme, Token is the next upcoming
// booking's admission token — the same value the QR encodes. BookingID
// surfaces alongside so the client can tell the manager which class the QR
// is for if it lands on a screen showing multiple bookings.
//
// When the student has no upcoming bookings, Token is empty and BookingID
// is empty; the client should show a "no upcoming class" empty state.
type CheckInPayload struct {
	Token     string           `json:"token"`
	BookingID string           `json:"booking_id,omitempty"`
	UserName  string           `json:"user_name"`
	NextClass *UpcomingBooking `json:"next_class,omitempty"`
}

func (s *Store) CheckInCode(ctx context.Context, userID string) (*CheckInPayload, error) {
	var name string
	if err := s.db.QueryRowContext(ctx,
		`SELECT full_name FROM users WHERE id = ?`, userID,
	).Scan(&name); err != nil {
		return nil, err
	}
	out := &CheckInPayload{UserName: name}

	// Surface the next upcoming booking's token. A future iteration could
	// return a list so the student can swipe through multiple QRs in one
	// session; for now "the next one up" matches the existing sheet.
	rows, err := s.UpcomingBookings(ctx, userID)
	if err != nil {
		return nil, err
	}
	if len(rows) > 0 {
		out.NextClass = &rows[0]
		var token sql.NullString
		if err := s.db.QueryRowContext(ctx,
			`SELECT checkin_token FROM bookings WHERE id = ?`, rows[0].ID,
		).Scan(&token); err != nil {
			return nil, err
		}
		if token.Valid {
			out.Token = token.String
			out.BookingID = rows[0].ID
		}
	}
	return out, nil
}

// JoinWaitlist appends the caller at the end of the queue for a full class.
// Returns the assigned position (1-based). Refuses with [ErrAlreadyBooked]
// when the caller already has a live booking on the class, and with
// [ErrAlreadyOnWaitlist] when they already hold a queue slot — the UI uses
// these to render the right CTA instead of a duplicate-entry server error.
func (s *Store) JoinWaitlist(ctx context.Context, userID, classID string) (int, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	// Pull studio_id + title from the class row so we can audit + scope
	// correctly. Title goes onto the audit row so the activity log reads
	// "WAITLIST JOIN · Vinyasa Flow" instead of an opaque class id.
	var studioID, classTitle string
	err = tx.QueryRowContext(ctx,
		`SELECT studio_id, COALESCE(title,'')
		   FROM classes WHERE id = ? AND status = 'scheduled'`,
		classID,
	).Scan(&studioID, &classTitle)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, err
	}

	// Refuse if the caller is already booked on this class — they have the
	// seat, the queue is for people who don't.
	var existingBookingID sql.NullString
	if err := tx.QueryRowContext(ctx, `
		SELECT id FROM bookings
		 WHERE class_id = ? AND user_id = ? AND status = 'booked'
		 LIMIT 1`,
		classID, userID,
	).Scan(&existingBookingID); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if existingBookingID.Valid {
		return 0, ErrAlreadyBooked
	}

	// Refuse if the caller is already actively waiting — the partial
	// uq_waitlist_active_per_user index catches this at the DB level too,
	// but the typed error is friendlier for the UI than a wrapped SQL
	// one. Historical 'promoted' / 'left' rows for the same user don't
	// block a fresh join.
	var existingWaitID sql.NullString
	if err := tx.QueryRowContext(ctx, `
		SELECT id FROM waitlist_entries
		 WHERE class_id = ? AND user_id = ? AND status = 'waiting'
		 LIMIT 1`,
		classID, userID,
	).Scan(&existingWaitID); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if existingWaitID.Valid {
		return 0, ErrAlreadyOnWaitlist
	}

	// Position is the next slot in the active queue (not the full history).
	var maxPos sql.NullInt64
	if err := tx.QueryRowContext(ctx, `
		SELECT MAX(position) FROM waitlist_entries
		 WHERE class_id = ? AND status = 'waiting'`,
		classID,
	).Scan(&maxPos); err != nil {
		return 0, err
	}
	pos := 1
	if maxPos.Valid {
		pos = int(maxPos.Int64) + 1
	}

	id := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO waitlist_entries (id, class_id, user_id, position)
		    VALUES (?, ?, ?, ?)`,
		id, classID, userID, pos,
	); err != nil {
		return 0, fmt.Errorf("insert waitlist entry: %w", err)
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"waitlist_join", "class", classID, map[string]any{
			"position":    pos,
			"class_title": classTitle,
		}); err != nil {
		return 0, err
	}
	return pos, tx.Commit()
}

// LeaveWaitlist marks the caller's active queue entry as 'left' (without
// deleting) and re-numbers positions of anyone behind them so the visible
// queue stays a dense 1..N. No-op (returns nil) when the caller wasn't
// actively waiting — leaving twice shouldn't surface as an error to the UI.
//
// The kept row gives the studio an audit trail of "this user joined,
// changed their mind, left at X". A new JoinWaitlist call later inserts a
// fresh row — the partial unique index only spans status='waiting' rows.
func (s *Store) LeaveWaitlist(ctx context.Context, userID, classID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var (
		studioID, classTitle string
		myPos                int
		entryID              string
	)
	err = tx.QueryRowContext(ctx, `
		SELECT c.studio_id, w.id, w.position, COALESCE(c.title,'')
		  FROM waitlist_entries w
		  JOIN classes c ON c.id = w.class_id
		 WHERE w.class_id = ? AND w.user_id = ? AND w.status = 'waiting'
		 LIMIT 1`,
		classID, userID,
	).Scan(&studioID, &entryID, &myPos, &classTitle)
	if errors.Is(err, sql.ErrNoRows) {
		// Idempotent — not actively waiting = nothing to do.
		return nil
	}
	if err != nil {
		return err
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE waitlist_entries
		   SET status = 'left',
		       left_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ?`, entryID,
	); err != nil {
		return err
	}
	// Re-pack positions behind the departed user so the next promote pick
	// reads a contiguous queue. Only active rows take part in queue order.
	if _, err := tx.ExecContext(ctx, `
		UPDATE waitlist_entries
		   SET position = position - 1
		 WHERE class_id = ? AND status = 'waiting' AND position > ?`,
		classID, myPos,
	); err != nil {
		return err
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"waitlist_leave", "class", classID, map[string]any{
			"position":    myPos,
			"class_title": classTitle,
		}); err != nil {
		return err
	}
	return tx.Commit()
}
