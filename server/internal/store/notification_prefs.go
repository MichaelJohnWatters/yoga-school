package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

// NotificationPrefs is the per-user opt-out map returned by
// GET /me/notifications and accepted (partially) by PATCH. true means "send
// me this kind of notification". A user with no row is treated as all-true.
type NotificationPrefs struct {
	BookingConfirmed bool `json:"booking_confirmed"`
	ClassCancelled   bool `json:"class_cancelled"`
	WaitlistPromoted bool `json:"waitlist_promoted"`
	Promotions       bool `json:"promotions"`
	System           bool `json:"system_msgs"`
}

func defaultPrefs() NotificationPrefs {
	return NotificationPrefs{
		BookingConfirmed: true,
		ClassCancelled:   true,
		WaitlistPromoted: true,
		Promotions:       true,
		System:           true,
	}
}

// MyNotificationPrefs reads the user's current prefs. Lazily returns the
// defaults when no row exists — that matches the schema's "absence = opt
// in to everything" rule and means the GET endpoint never 404s.
func (s *Store) MyNotificationPrefs(ctx context.Context, userID string) (*NotificationPrefs, error) {
	out := defaultPrefs()
	var bc, cc, wp, pr, sm int
	err := s.db.QueryRowContext(ctx, `
		SELECT booking_confirmed, class_cancelled, waitlist_promoted,
		       promotions, system_msgs
		  FROM notification_prefs
		 WHERE user_id = ?`,
		userID,
	).Scan(&bc, &cc, &wp, &pr, &sm)
	if errors.Is(err, sql.ErrNoRows) {
		return &out, nil
	}
	if err != nil {
		return nil, err
	}
	out.BookingConfirmed = bc != 0
	out.ClassCancelled = cc != 0
	out.WaitlistPromoted = wp != 0
	out.Promotions = pr != 0
	out.System = sm != 0
	return &out, nil
}

// NotificationPrefsPatch is the partial-update body for PATCH /me/notifications.
// Each field is a pointer so the caller can flip exactly the toggles they
// touched without sending the rest.
type NotificationPrefsPatch struct {
	BookingConfirmed *bool `json:"booking_confirmed,omitempty"`
	ClassCancelled   *bool `json:"class_cancelled,omitempty"`
	WaitlistPromoted *bool `json:"waitlist_promoted,omitempty"`
	Promotions       *bool `json:"promotions,omitempty"`
	System           *bool `json:"system_msgs,omitempty"`
}

// UpdateNotificationPrefs upserts the row, defaulting any field the caller
// didn't include to the current value (or to the schema default when the
// row doesn't exist yet).
func (s *Store) UpdateNotificationPrefs(ctx context.Context, userID string, p NotificationPrefsPatch) (*NotificationPrefs, error) {
	cur, err := s.MyNotificationPrefs(ctx, userID)
	if err != nil {
		return nil, err
	}
	if p.BookingConfirmed != nil {
		cur.BookingConfirmed = *p.BookingConfirmed
	}
	if p.ClassCancelled != nil {
		cur.ClassCancelled = *p.ClassCancelled
	}
	if p.WaitlistPromoted != nil {
		cur.WaitlistPromoted = *p.WaitlistPromoted
	}
	if p.Promotions != nil {
		cur.Promotions = *p.Promotions
	}
	if p.System != nil {
		cur.System = *p.System
	}
	bi := func(b bool) int {
		if b {
			return 1
		}
		return 0
	}
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO notification_prefs
		    (user_id, booking_confirmed, class_cancelled, waitlist_promoted,
		     promotions, system_msgs, updated_at)
		    VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
		ON CONFLICT(user_id) DO UPDATE SET
		    booking_confirmed = excluded.booking_confirmed,
		    class_cancelled   = excluded.class_cancelled,
		    waitlist_promoted = excluded.waitlist_promoted,
		    promotions        = excluded.promotions,
		    system_msgs       = excluded.system_msgs,
		    updated_at        = strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
		userID,
		bi(cur.BookingConfirmed), bi(cur.ClassCancelled), bi(cur.WaitlistPromoted),
		bi(cur.Promotions), bi(cur.System),
	); err != nil {
		return nil, err
	}
	return cur, nil
}

// userOptedInTx returns true when the user's prefs allow a notification of
// the given `type` value (matches the column name in notification_prefs,
// minus the `_msgs` suffix on system). Called inside each notification-
// inserting transaction before the INSERT runs. "Absence of row" reads as
// "opted in to everything" — same as the GET semantics.
func userOptedInTx(ctx context.Context, tx *sql.Tx, userID, kind string) (bool, error) {
	col := notificationKindColumn(kind)
	if col == "" {
		// Unknown category — default to sending. Better to surface an
		// errant notif than silently drop a flow the prefs UI hasn't been
		// taught yet.
		return true, nil
	}
	var v int
	err := tx.QueryRowContext(ctx,
		"SELECT "+col+" FROM notification_prefs WHERE user_id = ?",
		userID,
	).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	return v != 0, nil
}

// notificationKindColumn maps the notification `type` value used at insert
// sites to the prefs column that gates it. The list intentionally mirrors
// the JSON tags on NotificationPrefs.
func notificationKindColumn(kind string) string {
	switch strings.ToLower(kind) {
	case "booking_confirmed":
		return "booking_confirmed"
	case "class_cancelled":
		return "class_cancelled"
	case "waitlist_promoted":
		return "waitlist_promoted"
	case "promotion", "promotions":
		return "promotions"
	case "system":
		return "system_msgs"
	default:
		return ""
	}
}
