package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Roster is the payload for GET /admin/classes/{id}/roster.
type Roster struct {
	Class    RosterClassHeader   `json:"class"`
	Counts   RosterCounts        `json:"counts"`
	Booked   []RosterBookingRow  `json:"booked"`
	Waitlist []RosterWaitlistRow `json:"waitlist"`
}

type RosterClassHeader struct {
	ID             string `json:"id"`
	Title          string `json:"title"`
	StartsAt       string `json:"starts_at"`
	EndsAt         string `json:"ends_at"`
	RoomName       string `json:"room_name"`
	InstructorName string `json:"instructor_name"`
	Capacity       int    `json:"capacity"`
}

type RosterCounts struct {
	Booked        int `json:"booked"`
	Unmarked      int `json:"unmarked"`
	Present       int `json:"present"`
	NoShow        int `json:"no_show"`
	LateCancelled int `json:"late_cancelled"`
}

type RosterBookingRow struct {
	BookingID string  `json:"booking_id"`
	UserID    string  `json:"user_id"`
	FullName  string  `json:"full_name"`
	PhotoURL  *string `json:"photo_url,omitempty"`
	PassLabel string  `json:"pass_label"`
	// PassKind is 'credit' or 'unlimited'. The admin "remove from
	// class" sheet uses this to hide the refund-choice toggle on
	// unlimited bookings (nothing to refund — the seat is just released).
	PassKind string `json:"pass_kind"`
	// Status is one of: booked | attended | no_show | late_cancelled.
	// late_cancelled rows are bookings the student cancelled inside the
	// studio's free-cancel window — the pass was still consumed, so we
	// keep them on the roster as a separate group.
	Status    string `json:"status"`
	IsPlusOne bool   `json:"is_plus_one"`
	// PlusOneName is the friend's name on +1 rows (empty on primary rows).
	// ParentBookingID points to the booker's primary booking — the UI
	// uses both to nest the +1 visually under the member who brought them.
	PlusOneName     string  `json:"plus_one_name,omitempty"`
	ParentBookingID string  `json:"parent_booking_id,omitempty"`
	AttendanceVia   *string `json:"attendance_via,omitempty"`
	CancelledAt     *string `json:"cancelled_at,omitempty"`
}

type RosterWaitlistRow struct {
	UserID   string `json:"user_id"`
	FullName string `json:"full_name"`
	Position int    `json:"position"`
}

func (s *Store) RosterFor(ctx context.Context, studioID, classID string) (*Roster, error) {
	var h RosterClassHeader
	err := s.db.QueryRowContext(ctx, `
		SELECT c.id, COALESCE(c.title,''), c.starts_at, c.ends_at,
		       r.name, i.full_name, c.capacity
		  FROM classes c
		  JOIN rooms r ON r.id = c.room_id
		  JOIN users i ON i.id = c.instructor_id
		 WHERE c.id = ? AND c.studio_id = ?`,
		classID, studioID,
	).Scan(&h.ID, &h.Title, &h.StartsAt, &h.EndsAt, &h.RoomName, &h.InstructorName, &h.Capacity)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	out := &Roster{Class: h, Booked: []RosterBookingRow{}, Waitlist: []RosterWaitlistRow{}}

	// Bookings — non-cancelled rows plus late cancellations. Late cancels
	// still consumed the pass, so they belong on the roster, but they don't
	// occupy a seat against capacity — the studio can promote a waitlist
	// student into that empty spot. The outcome column is set at write time
	// (CancelBooking) so we don't recompute the cutoff window here.
	rows, err := s.db.QueryContext(ctx, `
		SELECT b.id, u.id, u.full_name, u.photo_url,
		       COALESCE(e.label, ''),
		       e.pass_kind,
		       CASE
		         WHEN b.outcome = 'cancelled_late_burned' THEN 'late_cancelled'
		         ELSE b.status
		       END AS status,
		       b.is_plus_one,
		       COALESCE(b.plus_one_name, ''),
		       COALESCE(b.parent_booking_id, ''),
		       b.attendance_marked_by, b.cancelled_at
		  FROM bookings b
		  JOIN users u        ON u.id = b.user_id
		  JOIN entitlements e ON e.id = b.entitlement_id
		 WHERE b.class_id = ?
		   AND (b.status != 'cancelled'
		        OR b.outcome = 'cancelled_late_burned')
		 ORDER BY (b.status = 'cancelled') ASC, b.created_at ASC`,
		classID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			r               RosterBookingRow
			photo, via, cAt sql.NullString
			plusOneInt      int
		)
		if err := rows.Scan(&r.BookingID, &r.UserID, &r.FullName, &photo,
			&r.PassLabel, &r.PassKind, &r.Status, &plusOneInt,
			&r.PlusOneName, &r.ParentBookingID,
			&via, &cAt); err != nil {
			return nil, err
		}
		if photo.Valid {
			s := photo.String
			r.PhotoURL = &s
		}
		if via.Valid {
			s := via.String
			r.AttendanceVia = &s
		}
		if cAt.Valid {
			s := cAt.String
			r.CancelledAt = &s
		}
		r.IsPlusOne = plusOneInt != 0
		out.Booked = append(out.Booked, r)
		switch r.Status {
		case "booked":
			out.Counts.Unmarked++
			out.Counts.Booked++
		case "attended":
			out.Counts.Present++
			out.Counts.Booked++
		case "no_show":
			out.Counts.NoShow++
			out.Counts.Booked++
		case "late_cancelled":
			out.Counts.LateCancelled++
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Waitlist — active queue only. Promoted/left rows live on for audit
	// but the roster's queue card shows the people still in line.
	wrows, err := s.db.QueryContext(ctx, `
		SELECT u.id, u.full_name, w.position
		  FROM waitlist_entries w
		  JOIN users u ON u.id = w.user_id
		 WHERE w.class_id = ? AND w.status = 'waiting'
		 ORDER BY w.position ASC`,
		classID,
	)
	if err != nil {
		return nil, err
	}
	defer wrows.Close()
	for wrows.Next() {
		var w RosterWaitlistRow
		if err := wrows.Scan(&w.UserID, &w.FullName, &w.Position); err != nil {
			return nil, err
		}
		out.Waitlist = append(out.Waitlist, w)
	}
	return out, wrows.Err()
}

// ScanResult is what /admin/checkin/scan returns on success.
type ScanResult struct {
	BookingID  string `json:"booking_id"`
	UserID     string `json:"user_id"`
	UserName   string `json:"user_name"`
	ClassID    string `json:"class_id"`
	ClassTitle string `json:"class_title"`
	WasAlready bool   `json:"was_already_attended"`
}

// ScanError carries a specific reason for a refused scan. Maps to a 409 in
// the API layer (or 404 for invalid_token).
type ScanError struct{ Code, Message string }

func (e *ScanError) Error() string { return e.Message }

// Check-in window — the manager scanner only accepts a booking's token
// from this much before the class starts to this much after it ends. Outside
// the window the scan is refused with code "outside_checkin_window". These
// are sensible defaults; making them studio-configurable is a follow-up.
const (
	checkinOpenMinutesBefore = 30
	checkinCloseMinutesAfter = 10
)

// CheckinScan resolves a single-use booking token. The token alone
// identifies the booking, the user, and the class — the caller doesn't have
// to know which class is being scanned. Returns a ScanError with a typed
// code for the caller to surface:
//
//	invalid_token            — token doesn't match any booking
//	was_cancelled            — booking was cancelled
//	outside_checkin_window   — class hasn't opened yet, or has fully closed
//
// On the first successful mark the token is consumed (set NULL) so a
// screenshot of the QR can't be reused. Re-scans of an already-attended
// booking are idempotent — they return WasAlready=true without writing
// another audit row.
func (s *Store) CheckinScan(ctx context.Context, studioID, actorID, token string) (*ScanResult, error) {
	if token == "" {
		return nil, &ScanError{Code: "invalid_token", Message: "token is required"}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Resolve token → booking + class + user. Restrict to the manager's
	// studio so a leaked token from another tenant can't be used here.
	var (
		bookingID, userID, userName, classID, classTitle string
		status, startsAtStr, endsAtStr                   string
	)
	err = tx.QueryRowContext(ctx, `
		SELECT b.id, b.user_id, u.full_name, b.status,
		       c.id, COALESCE(c.title,''), c.starts_at, c.ends_at
		  FROM bookings b
		  JOIN users   u ON u.id = b.user_id
		  JOIN classes c ON c.id = b.class_id
		 WHERE b.checkin_token = ?
		   AND b.studio_id     = ?`,
		token, studioID,
	).Scan(&bookingID, &userID, &userName, &status,
		&classID, &classTitle, &startsAtStr, &endsAtStr)
	if errors.Is(err, sql.ErrNoRows) {
		// Either the token doesn't exist, or it was already consumed on a
		// previous successful scan. Both surface as invalid_token — a
		// "rescan after consume" intentionally looks the same as "made-up
		// token" so a screenshot can't be distinguished from a fake.
		return nil, &ScanError{Code: "invalid_token", Message: "no booking matches that code"}
	}
	if err != nil {
		return nil, err
	}
	if status == "cancelled" {
		return nil, &ScanError{Code: "was_cancelled", Message: "booking was cancelled"}
	}

	// Enforce the check-in window — same shape a real desk runs.
	startsAt, err := time.Parse(time.RFC3339, startsAtStr)
	if err != nil {
		return nil, err
	}
	endsAt, err := time.Parse(time.RFC3339, endsAtStr)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	openAt := startsAt.Add(-checkinOpenMinutesBefore * time.Minute)
	closeAt := endsAt.Add(checkinCloseMinutesAfter * time.Minute)
	if now.Before(openAt) || now.After(closeAt) {
		return nil, &ScanError{
			Code: "outside_checkin_window",
			Message: fmt.Sprintf(
				"check-in opens %d min before class and closes %d min after end",
				checkinOpenMinutesBefore, checkinCloseMinutesAfter,
			),
		}
	}

	res := &ScanResult{
		BookingID:  bookingID,
		UserID:     userID,
		UserName:   userName,
		ClassID:    classID,
		ClassTitle: classTitle,
		WasAlready: status == "attended",
	}

	if !res.WasAlready {
		// Mark attended AND consume the token in one statement so a race
		// (two devices scanning the same QR concurrently) resolves
		// deterministically: first wins, second sees invalid_token on its
		// own re-read.
		if _, err := tx.ExecContext(ctx, `
			UPDATE bookings
			   SET status = 'attended',
			       attendance_marked_by = 'scan',
			       checkin_token = NULL
			 WHERE id = ?`, bookingID,
		); err != nil {
			return nil, err
		}
		if err := s.writeAuditTx(ctx, tx, studioID, actorID,
			"attendance_scan", "booking", bookingID, map[string]any{
				"user_id":     userID,
				"user_name":   userName,
				"class_id":    classID,
				"class_title": classTitle,
			}); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return res, nil
}

// MarkAttendance flips a booking's status to attended, no_show, or back to
// booked (undo). Idempotent. Sets outcome='no_show_burned' on no_show; clears
// outcome on the other two transitions.
//
// actorID identifies the staff member who marked attendance — pass "" only for
// system-triggered transitions (none today). studioID is taken from the
// booking row so callers don't need to pre-resolve it.
func (s *Store) MarkAttendance(ctx context.Context, actorID, bookingID, status, via string) error {
	if status != "attended" && status != "no_show" && status != "booked" {
		return fmt.Errorf("invalid attendance status: %s", status)
	}
	var (
		actualVia any
		outcome   any
	)
	if status == "booked" {
		actualVia = nil
	} else {
		actualVia = via
	}
	if status == "no_show" {
		outcome = "no_show_burned"
	}
	res, err := s.db.ExecContext(ctx, `
		UPDATE bookings
		   SET status = ?, attendance_marked_by = ?, outcome = ?
		 WHERE id = ? AND status != 'cancelled'`,
		status, actualVia, outcome, bookingID,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	// Resolve studio + the human-readable context for the audit row in one
	// hop. Renders as "marked attended · <user> · <class>" in the Activity
	// log without the UI having to follow IDs.
	var (
		studioID, userID, userName, classID, classTitle string
	)
	if err := s.db.QueryRowContext(ctx, `
		SELECT b.studio_id, b.user_id, u.full_name, c.id, COALESCE(c.title,'')
		  FROM bookings b
		  JOIN users   u ON u.id = b.user_id
		  JOIN classes c ON c.id = b.class_id
		 WHERE b.id = ?`, bookingID,
	).Scan(&studioID, &userID, &userName, &classID, &classTitle); err == nil && studioID != "" {
		_ = s.WriteAudit(ctx, studioID, actorID, "attendance_mark", "booking", bookingID, map[string]any{
			"status":      status,
			"via":         via,
			"user_id":     userID,
			"user_name":   userName,
			"class_id":    classID,
			"class_title": classTitle,
		})
	}
	return nil
}

// PromoteResult is what /admin/classes/{id}/promote returns.
//
// Promote now books the seat directly — no claim window. BookingID is the
// new live booking; the student is charged immediately if they hold a
// credit pass.
type PromoteResult struct {
	BookingID      string `json:"booking_id"`
	PromotedUserID string `json:"promoted_user_id"`
	PromotedName   string `json:"promoted_name"`
	Position       int    `json:"position"`
	NotificationID string `json:"notification_id"`
	NextWaitlistN  int    `json:"next_waitlist_size"`
}

// PromoteWaitlist auto-books the first waitlister into the next open seat.
// No claim window — joining the queue is the consent step; once promoted
// the seat is theirs and credit (if any) is burned right away. If the next
// waitlister has no eligible pass we skip them and move on so a stale
// student doesn't block the queue.
//
// actorID identifies the staff user who triggered the promote. Pass "" for
// the system path (the post-cancel goroutine in CancelBooking) — a non-empty
// actorID writes an additional `waitlist_promote` audit row so the staff
// trigger is attributable.
//
// Side effects in one tx:
//  1. Verify the class still has an open seat
//  2. Walk the active queue by ascending position until we find a
//     waitlister with an eligible entitlement
//  3. Insert their booking + decrement credits for credit passes
//  4. Mark their waitlist row 'promoted' (kept for audit) + re-number
//     positions behind them
//  5. Write a "you're booked" notification (gated by their pref)
func (s *Store) PromoteWaitlist(ctx context.Context, studioID, actorID, classID string) (*PromoteResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Class info for capacity + cutoff snapshot. Also grab the class title
	// so the staff-triggered audit row can render with a human label
	// instead of an opaque class_id.
	var (
		capacity, bookedCount, cutoffHours int
		classTitle                         string
	)
	err = tx.QueryRowContext(ctx, `
		SELECT c.capacity,
		       (SELECT COUNT(*) FROM bookings b
		         WHERE b.class_id = c.id AND b.status = 'booked'),
		       s.free_cancel_cutoff_hours,
		       COALESCE(c.title,'')
		  FROM classes c
		  JOIN studios s ON s.id = c.studio_id
		 WHERE c.id = ? AND c.studio_id = ? AND c.status = 'scheduled'`,
		classID, studioID,
	).Scan(&capacity, &bookedCount, &cutoffHours, &classTitle)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if bookedCount >= capacity {
		return nil, fmt.Errorf("class is full")
	}

	// Walk the queue by ascending position. Skip anyone without an
	// eligible entitlement — leaving them as waitlisters until they top
	// up — and delete their stale entry so the queue stays contiguous if
	// we end up promoting past them.
	rows, err := tx.QueryContext(ctx, `
		SELECT w.id, w.user_id, u.full_name, w.position
		  FROM waitlist_entries w
		  JOIN users u ON u.id = w.user_id
		 WHERE w.class_id = ? AND w.status = 'waiting'
		 ORDER BY w.position ASC`,
		classID,
	)
	if err != nil {
		return nil, err
	}
	type waiter struct {
		id, userID, fullName string
		position             int
	}
	var queue []waiter
	for rows.Next() {
		var w waiter
		if err := rows.Scan(&w.id, &w.userID, &w.fullName, &w.position); err != nil {
			rows.Close()
			return nil, err
		}
		queue = append(queue, w)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(queue) == 0 {
		return nil, fmt.Errorf("waitlist is empty")
	}

	var (
		picked        *waiter
		entitlementID string
		passKind      string
	)
	for i := range queue {
		w := queue[i]
		entID, kind, err := pickEligibleEntitlementTx(ctx, tx, classID, studioID, w.userID)
		if err != nil {
			if be, ok := err.(*BookingError); ok && be.Code == "no_eligible_entitlement" {
				// Drop this waitlister — they joined when they had a pass,
				// haven't got one now. They can rejoin if they top up.
				continue
			}
			return nil, err
		}
		picked = &queue[i]
		entitlementID = entID
		passKind = kind
		break
	}
	if picked == nil {
		// Everyone in the queue lost their eligible pass — the queue is
		// effectively empty for promote purposes. Caller decides whether
		// that's worth logging.
		return nil, &BookingError{
			Code:    "no_eligible_entitlement",
			Message: "no waitlister has an eligible pass",
		}
	}

	bookingID := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
		     booked_by_role, cancel_cutoff_hours, status, checkin_token)
		    VALUES (?, ?, ?, ?, ?, 0, 'student', ?, 'booked', ?)`,
		bookingID, studioID, classID, picked.userID, entitlementID, cutoffHours, NewID(),
	); err != nil {
		return nil, fmt.Errorf("insert booking on promote: %w", err)
	}
	if passKind == "credit" {
		if _, err := tx.ExecContext(ctx,
			`UPDATE entitlements SET credits_remaining = credits_remaining - 1 WHERE id = ?`,
			entitlementID,
		); err != nil {
			return nil, err
		}
	}

	// Mark the promoted user's waitlist row as 'promoted' (kept for audit)
	// and re-pack positions of anyone still actively waiting so the queue
	// stays contiguous.
	if _, err := tx.ExecContext(ctx, `
		UPDATE waitlist_entries
		   SET status = 'promoted',
		       promoted_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ?`, picked.id,
	); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE waitlist_entries
		   SET position = position - 1
		 WHERE class_id = ? AND status = 'waiting' AND position > ?`,
		classID, picked.position,
	); err != nil {
		return nil, err
	}

	// Notify the promoted student — gated by their waitlist_promoted pref.
	const (
		title = "You're booked from the waitlist"
		body  = "A spot opened up and we booked you in. Open the app to see the details."
	)
	notificationID := NewID()
	notify, err := userOptedInTx(ctx, tx, picked.userID, "waitlist_promoted")
	if err != nil {
		return nil, err
	}
	payload := fmt.Sprintf(`{"class_id":"%s","booking_id":"%s"}`, classID, bookingID)
	if notify {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO notifications
			    (id, studio_id, user_id, type, title, body, payload)
			    VALUES (?, ?, ?, 'waitlist_promoted', ?, ?, ?)`,
			notificationID, studioID, picked.userID, title, body, payload,
		); err != nil {
			return nil, err
		}
	} else {
		notificationID = ""
	}

	// Audit the auto-promote so support can match "I got booked into a
	// class I didn't expect" to a real event.
	if err := s.writeAuditTx(ctx, tx, studioID, picked.userID,
		"waitlist_auto_book", "booking", bookingID, map[string]any{
			"class_id":      classID,
			"class_title":   classTitle,
			"from_position": picked.position,
		}); err != nil {
		return nil, err
	}
	// If a staff member triggered this promote (vs the post-cancel
	// system path) record their action separately so the activity log
	// attributes the manual nudge to a real human.
	if actorID != "" {
		if err := s.writeAuditTx(ctx, tx, studioID, actorID,
			"waitlist_promote", "class", classID, map[string]any{
				"booking_id":         bookingID,
				"promoted_user_id":   picked.userID,
				"promoted_user_name": picked.fullName,
				"class_title":        classTitle,
				"from_position":      picked.position,
			}); err != nil {
			return nil, err
		}
	}

	// Count remaining ACTIVE waitlist — the promoted user is now status=
	// 'promoted' (kept for audit) so they don't count toward the queue.
	var nextN int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM waitlist_entries
		   WHERE class_id = ? AND status = 'waiting'`,
		classID,
	).Scan(&nextN); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	if notify {
		s.dispatchPush(picked.userID, "waitlist_promoted", title, body, payload)
	}

	return &PromoteResult{
		BookingID:      bookingID,
		PromotedUserID: picked.userID,
		PromotedName:   picked.fullName,
		Position:       picked.position,
		NotificationID: notificationID,
		NextWaitlistN:  nextN,
	}, nil
}

// pickEligibleEntitlementTx returns the caller's best entitlement that
// covers this class — same rules as the student /eligible-entitlements
// listing. Returns BookingError{Code: "no_eligible_entitlement"} when
// nothing qualifies. Reused by promote (pre-check) and claim (booking).
func pickEligibleEntitlementTx(ctx context.Context, tx *sql.Tx, classID, studioID, userID string) (entitlementID, passKind string, err error) {
	var creditsR sql.NullInt64
	err = tx.QueryRowContext(ctx, `
		SELECT e.id, e.pass_kind, e.credits_remaining
		  FROM entitlements e
		  JOIN entitlement_class_types ect ON ect.entitlement_id = e.id
		  JOIN classes c                   ON c.id = ?
		 WHERE e.studio_id = ?
		   AND e.user_id   = ?
		   AND e.status    = 'active'
		   AND ect.class_type_id = c.class_type_id
		   AND (e.expires_at IS NULL OR e.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now'))
		   AND (e.pass_kind = 'unlimited' OR e.credits_remaining > 0)
		 ORDER BY (e.pass_kind = 'unlimited') DESC, e.expires_at ASC LIMIT 1`,
		classID, studioID, userID,
	).Scan(&entitlementID, &passKind, &creditsR)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", &BookingError{Code: "no_eligible_entitlement", Message: "no eligible pass"}
	}
	return entitlementID, passKind, err
}
