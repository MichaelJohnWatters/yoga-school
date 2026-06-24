package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"
)

// ClassRow is one class as returned by /classes — joins instructor/room/type
// and includes per-caller booking state.
type ClassRow struct {
	ID                 string  `json:"id"`
	Title              string  `json:"title"`
	ClassTypeID        string  `json:"class_type_id"`
	ClassTypeName      string  `json:"class_type_name"`
	Discipline         string  `json:"discipline"`
	InstructorID       string  `json:"instructor_id"`
	InstructorName     string  `json:"instructor_name"`
	InstructorPhotoURL *string `json:"instructor_photo_url,omitempty"`
	RoomID             string  `json:"room_id"`
	RoomName           string  `json:"room_name"`
	// Optional `#rrggbb` accent set on the room. Lets cards tint per
	// room without a second fetch / cross-reference. Omitted when the
	// room has no colour configured.
	RoomColor       *string `json:"room_color,omitempty"`
	StartsAt        string  `json:"starts_at"`
	EndsAt          string  `json:"ends_at"`
	DurationMinutes int     `json:"duration_minutes"`
	Capacity        int     `json:"capacity"`
	BookedCount     int     `json:"booked_count"`
	// Number of users currently on the waitlist for this class. Used by
	// the "Full · N waiting" chip on the student book screen and the
	// manager dashboard's full-class indicator.
	WaitlistCount int    `json:"waitlist_count"`
	BookingState  string `json:"booking_state"` // booked|available|full
	BookingID     string `json:"booking_id,omitempty"`
	// Set when the caller's booking on this class includes a +1 guest.
	// Lets the UI show a "+1 friend" chip on the card and "Booked with
	// <name>" inside the booking sheet without a follow-up request.
	MyPlusOneName *string `json:"my_plus_one_name,omitempty"`
	// 1-based position in the class's waitlist queue, set only when the
	// caller has joined the waitlist for this class. Lets the UI render a
	// "On waitlist · #N" affordance instead of the generic "Join waitlist"
	// button so users have visible proof they're in the queue.
	WaitlistPosition *int `json:"waitlist_position,omitempty"`
	// Set on classes that are sessions of a multi-week enrollment series.
	// The calendar UI uses this to mark a card as "SERIES" so it visually
	// reads differently from a one-off drop-in class.
	EnrollmentID *string `json:"enrollment_id,omitempty"`
	// Set on classes backed by a recurrence rule — the manager UI uses it
	// to decide whether to show the this/future/all scope picker on edit.
	RecurrenceRuleID *string `json:"recurrence_rule_id,omitempty"`
	// Number of (non-deleted) messages in this class's group chat — the
	// staff schedule renders a small chat badge so busy class chats draw
	// attention. Only populated by the admin schedule query; 0 elsewhere.
	ChatMessageCount int `json:"chat_message_count,omitempty"`
}

// ClassesForDay returns every class on the given day, with the caller's
// booking state. The day boundary is computed in the studio's timezone so
// "today" for a Sydney studio means Sydney midnight to Sydney midnight,
// not UTC midnight (which would be early afternoon Sydney time).
func (s *Store) ClassesForDay(ctx context.Context, studioID, userID string, day time.Time) ([]ClassRow, error) {
	loc := s.StudioLocation(ctx, studioID)
	dayStart := startOfDayIn(day, loc)
	dayEnd := dayStart.Add(24 * time.Hour)
	return s.ClassesInRange(ctx, studioID, userID, dayStart, dayEnd)
}

// ClassesInRange returns scheduled classes whose start time falls in [from, to),
// with per-caller booking state. Both bounds are UTC; callers pre-normalize.
func (s *Store) ClassesInRange(ctx context.Context, studioID, userID string, from, to time.Time) ([]ClassRow, error) {
	const q = `
		SELECT
			c.id, COALESCE(c.title,''),
			ct.id, ct.name, COALESCE(ct.discipline,''),
			i.id, i.full_name, i.photo_url,
			r.id, r.name, r.color,
			c.starts_at, c.ends_at, c.capacity,
			(SELECT COUNT(*) FROM bookings b
			    WHERE b.class_id = c.id AND b.status = 'booked') AS booked_count,
			(SELECT COUNT(*) FROM waitlist_entries w
			    WHERE w.class_id = c.id) AS waitlist_count,
			(SELECT b.id FROM bookings b
			    WHERE b.class_id = c.id AND b.user_id = ? AND b.status = 'booked'
			      AND b.is_plus_one = 0
			    LIMIT 1) AS my_booking_id,
			(SELECT w.position FROM waitlist_entries w
			    WHERE w.class_id = c.id AND w.user_id = ? AND w.status = 'waiting'
			    LIMIT 1) AS my_waitlist_pos,
			c.enrollment_id,
			-- The +1 row inherits the parent's user_id at insert time, so
			-- this is a single direct lookup rather than a self-join.
			(SELECT b.plus_one_name FROM bookings b
			    WHERE b.class_id = c.id AND b.user_id = ? AND b.status = 'booked'
			      AND b.is_plus_one = 1
			    LIMIT 1) AS my_plus_one_name
		FROM classes c
		JOIN class_types ct ON ct.id = c.class_type_id
		JOIN users i        ON i.id = c.instructor_id
		JOIN rooms r        ON r.id = c.room_id
		WHERE c.studio_id = ?
		  AND c.status = 'scheduled'
		  AND c.starts_at >= ?
		  AND c.starts_at <  ?
		ORDER BY c.starts_at`

	rows, err := s.db.QueryContext(ctx, q,
		userID, userID, userID, studioID,
		from.UTC().Format(time.RFC3339), to.UTC().Format(time.RFC3339),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []ClassRow
	for rows.Next() {
		var (
			r             ClassRow
			myBookingID   sql.NullString
			myWaitPos     sql.NullInt64
			photoURL      sql.NullString
			enrollmentID  sql.NullString
			myPlusOneName sql.NullString
			roomColor     sql.NullString
		)
		if err := rows.Scan(
			&r.ID, &r.Title,
			&r.ClassTypeID, &r.ClassTypeName, &r.Discipline,
			&r.InstructorID, &r.InstructorName, &photoURL,
			&r.RoomID, &r.RoomName, &roomColor,
			&r.StartsAt, &r.EndsAt, &r.Capacity,
			&r.BookedCount, &r.WaitlistCount,
			&myBookingID, &myWaitPos, &enrollmentID,
			&myPlusOneName,
		); err != nil {
			return nil, err
		}
		if photoURL.Valid {
			s := photoURL.String
			r.InstructorPhotoURL = &s
		}
		if myWaitPos.Valid {
			p := int(myWaitPos.Int64)
			r.WaitlistPosition = &p
		}
		if enrollmentID.Valid {
			s := enrollmentID.String
			r.EnrollmentID = &s
		}
		if myPlusOneName.Valid {
			s := myPlusOneName.String
			r.MyPlusOneName = &s
		}
		if roomColor.Valid && roomColor.String != "" {
			s := roomColor.String
			r.RoomColor = &s
		}
		start, _ := time.Parse(time.RFC3339, r.StartsAt)
		end, _ := time.Parse(time.RFC3339, r.EndsAt)
		r.DurationMinutes = int(end.Sub(start).Minutes())
		switch {
		case myBookingID.Valid:
			r.BookingState = "booked"
			r.BookingID = myBookingID.String
		case r.BookedCount >= r.Capacity:
			r.BookingState = "full"
		default:
			r.BookingState = "available"
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ClassDetail is a single-class view: the standard row + waitlist count.
type ClassDetail struct {
	ClassRow
	WaitlistCount int `json:"waitlist_count"`
}

// GetClass returns one class with the caller's booking state and waitlist
// count. Used by GET /classes/{id}.
func (s *Store) GetClass(ctx context.Context, studioID, userID, classID string) (*ClassDetail, error) {
	const q = `
		SELECT
			c.id, COALESCE(c.title,''),
			ct.id, ct.name, COALESCE(ct.discipline,''),
			i.id, i.full_name, i.photo_url,
			r.id, r.name, r.color,
			c.starts_at, c.ends_at, c.capacity,
			(SELECT COUNT(*) FROM bookings b
			    WHERE b.class_id = c.id AND b.status = 'booked') AS booked_count,
			(SELECT b.id FROM bookings b
			    WHERE b.class_id = c.id AND b.user_id = ? AND b.status = 'booked'
			      AND b.is_plus_one = 0
			    LIMIT 1) AS my_booking_id,
			(SELECT w.position FROM waitlist_entries w
			    WHERE w.class_id = c.id AND w.user_id = ? AND w.status = 'waiting'
			    LIMIT 1) AS my_waitlist_pos,
			(SELECT COUNT(*) FROM waitlist_entries w
			    WHERE w.class_id = c.id AND w.status = 'waiting') AS waitlist_count,
			c.enrollment_id,
			(SELECT b.plus_one_name FROM bookings b
			    WHERE b.class_id = c.id AND b.user_id = ? AND b.status = 'booked'
			      AND b.is_plus_one = 1
			    LIMIT 1) AS my_plus_one_name
		  FROM classes c
		  JOIN class_types ct ON ct.id = c.class_type_id
		  JOIN users i        ON i.id = c.instructor_id
		  JOIN rooms r        ON r.id = c.room_id
		 WHERE c.id = ? AND c.studio_id = ?`
	var (
		out           ClassDetail
		myBookingID   sql.NullString
		myWaitPos     sql.NullInt64
		photoURL      sql.NullString
		enrollmentID  sql.NullString
		myPlusOneName sql.NullString
		roomColor     sql.NullString
	)
	err := s.db.QueryRowContext(ctx, q, userID, userID, userID, classID, studioID).Scan(
		&out.ID, &out.Title,
		&out.ClassTypeID, &out.ClassTypeName, &out.Discipline,
		&out.InstructorID, &out.InstructorName, &photoURL,
		&out.RoomID, &out.RoomName, &roomColor,
		&out.StartsAt, &out.EndsAt, &out.Capacity,
		&out.BookedCount, &myBookingID, &myWaitPos, &out.WaitlistCount,
		&enrollmentID, &myPlusOneName,
	)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if photoURL.Valid {
		v := photoURL.String
		out.InstructorPhotoURL = &v
	}
	if myWaitPos.Valid {
		p := int(myWaitPos.Int64)
		out.WaitlistPosition = &p
	}
	if enrollmentID.Valid {
		v := enrollmentID.String
		out.EnrollmentID = &v
	}
	if myPlusOneName.Valid {
		v := myPlusOneName.String
		out.MyPlusOneName = &v
	}
	if roomColor.Valid && roomColor.String != "" {
		v := roomColor.String
		out.RoomColor = &v
	}
	start, _ := time.Parse(time.RFC3339, out.StartsAt)
	end, _ := time.Parse(time.RFC3339, out.EndsAt)
	out.DurationMinutes = int(end.Sub(start).Minutes())
	switch {
	case myBookingID.Valid:
		out.BookingState = "booked"
		out.BookingID = myBookingID.String
	case out.BookedCount >= out.Capacity:
		out.BookingState = "full"
	default:
		out.BookingState = "available"
	}
	return &out, nil
}

// EligibleEntitlement is one option in the booking sheet's PAY WITH section.
type EligibleEntitlement struct {
	ID               string `json:"id"`
	Label            string `json:"label"`
	PassKind         string `json:"pass_kind"`
	CreditsRemaining *int   `json:"credits_remaining,omitempty"`
	ExpiresAt        string `json:"expires_at,omitempty"`
}

// EligibleEntitlements returns the caller's active entitlements that cover
// the class's type. Empty list ⇒ student must buy a pass first.
func (s *Store) EligibleEntitlements(ctx context.Context, studioID, userID, classID string) ([]EligibleEntitlement, error) {
	const q = `
		SELECT e.id, e.label, e.pass_kind, e.credits_remaining,
		       COALESCE(e.expires_at,''), c.class_type_id
		  FROM entitlements e
		  JOIN entitlement_class_types ect ON ect.entitlement_id = e.id
		  JOIN classes c                   ON c.id = ?
		 WHERE e.studio_id = ?
		   AND e.user_id   = ?
		   AND e.status    = 'active'
		   AND ect.class_type_id = c.class_type_id
		   AND (e.expires_at IS NULL OR e.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now'))
		   AND (e.pass_kind = 'unlimited' OR e.credits_remaining > 0)
		 ORDER BY (e.pass_kind = 'unlimited') DESC, e.expires_at ASC`

	rows, err := s.db.QueryContext(ctx, q, classID, studioID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]EligibleEntitlement, 0)
	for rows.Next() {
		var (
			e        EligibleEntitlement
			creditsR sql.NullInt64
			classTID string
		)
		if err := rows.Scan(&e.ID, &e.Label, &e.PassKind, &creditsR, &e.ExpiresAt, &classTID); err != nil {
			return nil, err
		}
		if creditsR.Valid {
			n := int(creditsR.Int64)
			e.CreditsRemaining = &n
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// BookingError carries a specific reason for a refused booking. The
// fields-not-methods shape keeps it cheap to construct (`&BookingError{
// Code: ..., Message: ...}`) — the API layer recognises the type
// directly in mapStoreError and routes it through respondErr with a 409
// status, so handlers don't need a per-call errors.As block.
type BookingError struct{ Code, Message string }

func (e *BookingError) Error() string { return e.Message }

// CreateBooking inserts a booking after verifying capacity + entitlement.
// If plusOne is true, an additional is_plus_one=1 row is inserted in the same
// transaction and credit consumption doubles. Gated by studio's
// allow_student_plus_one setting (manager callers bypass — not modeled yet).
// Returns the (primary) new booking ID on success.
func (s *Store) CreateBooking(ctx context.Context, studioID, userID, classID, entitlementID string, plusOne bool, plusOneName string) (string, error) {
	// Friend's name is required when bringing a +1 so managers can see
	// who actually showed up on the audit log and the student detail page.
	plusOneName = strings.TrimSpace(plusOneName)
	if plusOne && plusOneName == "" {
		return "", &BookingError{
			Code:    "plus_one_name_required",
			Message: "Tell us your friend's name when bringing a +1",
		}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	// Verify the class exists + has room (count both seats if +1).
	// Also grab the class title so the audit row can render with a
	// human label instead of an opaque class_id.
	var capacity, bookedCount, cutoffHours, plusOneAllowed int
	var classStartStr, classTitle string
	err = tx.QueryRowContext(ctx, `
		SELECT c.starts_at,
		       c.capacity,
		       (SELECT COUNT(*) FROM bookings b
		         WHERE b.class_id = c.id AND b.status = 'booked'),
		       s.free_cancel_cutoff_hours,
		       s.allow_student_plus_one,
		       COALESCE(c.title,'')
		  FROM classes c
		  JOIN studios s ON s.id = c.studio_id
		 WHERE c.id = ? AND c.studio_id = ? AND c.status = 'scheduled'`,
		classID, studioID,
	).Scan(&classStartStr, &capacity, &bookedCount, &cutoffHours, &plusOneAllowed, &classTitle)
	if errors.Is(err, sql.ErrNoRows) {
		return "", &BookingError{Code: "class_not_found", Message: "class not found"}
	}
	if err != nil {
		return "", err
	}
	// You can't book a class after it has begun. The cancel-cutoff is a
	// separate (earlier) window; this is the absolute "doors closed" rule.
	classStart, err := time.Parse(time.RFC3339, classStartStr)
	if err != nil {
		return "", err
	}
	if !time.Now().UTC().Before(classStart) {
		return "", &BookingError{
			Code:    "class_already_started",
			Message: "Class has already started",
		}
	}

	// Refuse if the user is currently on the class's waitlist. The seat-
	// holding offer flow is the legitimate path from waitlist → booking;
	// a direct CreateBooking here would orphan the waitlist row and let
	// someone jump their own queue. The UI's "Leave waitlist" button
	// removes the entry first, then a normal Book is allowed.
	var existingWaitID sql.NullString
	if err := tx.QueryRowContext(ctx, `
		SELECT id FROM waitlist_entries
		 WHERE class_id = ? AND user_id = ? AND status = 'waiting'
		 LIMIT 1`,
		classID, userID,
	).Scan(&existingWaitID); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if existingWaitID.Valid {
		return "", &BookingError{
			Code:    "on_waitlist",
			Message: "Leave the waitlist before booking directly",
		}
	}

	seatsWanted := 1
	if plusOne {
		if plusOneAllowed == 0 {
			return "", &BookingError{Code: "plus_one_not_allowed", Message: "studio does not allow +1 guests"}
		}
		seatsWanted = 2
	}
	if bookedCount+seatsWanted > capacity {
		return "", &BookingError{Code: "class_full", Message: "class is full"}
	}

	// Verify entitlement is active + covers this class's type.
	var passKind string
	var creditsR sql.NullInt64
	err = tx.QueryRowContext(ctx, `
		SELECT e.pass_kind, e.credits_remaining
		  FROM entitlements e
		  JOIN entitlement_class_types ect ON ect.entitlement_id = e.id
		  JOIN classes c                   ON c.id = ?
		 WHERE e.id = ? AND e.user_id = ? AND e.studio_id = ?
		   AND e.status = 'active'
		   AND ect.class_type_id = c.class_type_id
		   AND (e.expires_at IS NULL OR e.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now'))`,
		classID, entitlementID, userID, studioID,
	).Scan(&passKind, &creditsR)
	if errors.Is(err, sql.ErrNoRows) {
		return "", &BookingError{Code: "entitlement_ineligible", Message: "entitlement does not cover this class"}
	}
	if err != nil {
		return "", err
	}
	if passKind == "credit" {
		needed := int64(seatsWanted)
		if !creditsR.Valid || creditsR.Int64 < needed {
			return "", &BookingError{Code: "no_credits", Message: "not enough credits"}
		}
	}
	// +1 guests are restricted to credit passes. Unlimited passes don't
	// decrement on booking, so allowing +1 would let a single subscription
	// bring unlimited free guests — which isn't the intent of the perk.
	if plusOne && passKind == "unlimited" {
		return "", &BookingError{
			Code:    "plus_one_unlimited_not_allowed",
			Message: "+1 guests need a credit pass — use one of your credit passes instead",
		}
	}

	bookingID := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
		     booked_by_role, cancel_cutoff_hours, status, checkin_token)
		    VALUES (?, ?, ?, ?, ?, 0, 'student', ?, 'booked', ?)`,
		bookingID, studioID, classID, userID, entitlementID, cutoffHours,
		NewID(), // single-use admission token, consumed on first successful scan
	); err != nil {
		// The only realistic constraint failure here is the partial
		// unique index uq_bookings_active_seat — i.e. an existing live
		// booking for the same (class, user, is_plus_one=0). Surface a
		// clean message rather than leaking the SQL error text.
		return "", &BookingError{
			Code:    "already_booked",
			Message: "You already have a booking for this class.",
		}
	}
	// Audit the student's self-book so it shows up in the Activity log
	// next to the existing booking_cancel / waitlist_* events. Manager
	// flow writes booking_create_admin instead so the actor attribution
	// stays clean — this row's actor is always the student themselves.
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"booking_create", "booking", bookingID, map[string]any{
			"class_id":       classID,
			"class_title":    classTitle,
			"entitlement_id": entitlementID,
			"pass_kind":      passKind,
		}); err != nil {
		return "", fmt.Errorf("audit booking_create: %w", err)
	}
	if plusOne {
		plusOneID := NewID()
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO bookings
			    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one, plus_one_name, parent_booking_id,
			     booked_by_role, cancel_cutoff_hours, status, checkin_token)
			    VALUES (?, ?, ?, ?, ?, 1, ?, ?, 'student', ?, 'booked', ?)`,
			plusOneID, studioID, classID, userID, entitlementID, plusOneName, bookingID, cutoffHours,
			NewID(),
		); err != nil {
			return "", &BookingError{
				Code:    "plus_one_failed",
				Message: "You already have a +1 booked for this class.",
			}
		}
		// Audit every +1 separately so managers can spot abuse patterns
		// without scanning the bookings table. Surfaces on the Activity
		// page and is filterable by action="booking_plus_one".
		if err := s.writeAuditTx(ctx, tx, studioID, userID,
			"booking_plus_one", "booking", plusOneID, map[string]any{
				"class_id":          classID,
				"class_title":       classTitle,
				"parent_booking_id": bookingID,
				"entitlement_id":    entitlementID,
				"friend_name":       plusOneName,
			}); err != nil {
			return "", fmt.Errorf("audit plus_one: %w", err)
		}
	}

	// Decrement credits if applicable (1 or 2).
	if passKind == "credit" {
		if _, err := tx.ExecContext(ctx,
			`UPDATE entitlements SET credits_remaining = credits_remaining - ? WHERE id = ?`,
			seatsWanted, entitlementID,
		); err != nil {
			return "", err
		}
	}

	// Send the "You're booked" notification on the primary row only. The
	// +1 row doesn't get its own notif — the guest doesn't have a user
	// account to receive one anyway.
	push, err := writeBookingConfirmedTx(ctx, tx, studioID, userID, classID, bookingID)
	if err != nil {
		return "", fmt.Errorf("booking_confirmed notif: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return "", err
	}
	if push != nil {
		s.dispatchPush(push.userID, push.notifType, push.title, push.body, push.payloadJSON)
	}
	return bookingID, nil
}

// AddPlusOneToBooking adds a +1 guest to a class the caller is ALREADY booked
// on — the "add a friend after the fact" path, for when they booked solo and
// later want to bring someone. It mirrors the +1 branch of CreateBooking but
// without creating a primary seat: it finds the caller's existing booking and
// hangs a child +1 row off it.
//
// The guest seat is charged to a CALLER-CHOSEN credit pass (entitlementID) —
// not necessarily the one that paid for the original seat. A student who
// booked solo on an unlimited pass can still bring a +1 by picking a credit
// pass here. The chosen pass must be an active credit pass that covers this
// class type and has a spare credit; CancelBooking refunds each cancelled
// seat to its OWN entitlement, so a guest paid from a different pass refunds
// correctly. Returns the new +1 booking ID.
func (s *Store) AddPlusOneToBooking(ctx context.Context, studioID, userID, classID, entitlementID, plusOneName string) (string, error) {
	plusOneName = strings.TrimSpace(plusOneName)
	if plusOneName == "" {
		return "", &BookingError{
			Code:    "plus_one_name_required",
			Message: "Tell us your friend's name when bringing a +1",
		}
	}
	if entitlementID == "" {
		return "", &BookingError{
			Code:    "entitlement_required",
			Message: "Pick a pass to pay for your +1",
		}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	// Class state + the studio's +1 toggle + a human title for the audit row.
	var capacity, bookedCount, cutoffHours, plusOneAllowed int
	var classStartStr, classTitle string
	err = tx.QueryRowContext(ctx, `
		SELECT c.starts_at,
		       c.capacity,
		       (SELECT COUNT(*) FROM bookings b
		         WHERE b.class_id = c.id AND b.status = 'booked'),
		       s.free_cancel_cutoff_hours,
		       s.allow_student_plus_one,
		       COALESCE(c.title,'')
		  FROM classes c
		  JOIN studios s ON s.id = c.studio_id
		 WHERE c.id = ? AND c.studio_id = ? AND c.status = 'scheduled'`,
		classID, studioID,
	).Scan(&classStartStr, &capacity, &bookedCount, &cutoffHours, &plusOneAllowed, &classTitle)
	if errors.Is(err, sql.ErrNoRows) {
		return "", &BookingError{Code: "class_not_found", Message: "class not found"}
	}
	if err != nil {
		return "", err
	}
	if plusOneAllowed == 0 {
		return "", &BookingError{Code: "plus_one_not_allowed", Message: "studio does not allow +1 guests"}
	}
	classStart, err := time.Parse(time.RFC3339, classStartStr)
	if err != nil {
		return "", err
	}
	if !time.Now().UTC().Before(classStart) {
		return "", &BookingError{Code: "class_already_started", Message: "Class has already started"}
	}

	// The caller's primary (non-+1) seat — the +1 hangs off it. We only need
	// its id for the parent link; the guest is paid from the chosen pass, not
	// this booking's.
	var parentBookingID string
	err = tx.QueryRowContext(ctx, `
		SELECT id FROM bookings
		 WHERE class_id = ? AND user_id = ? AND is_plus_one = 0 AND status = 'booked'
		 LIMIT 1`,
		classID, userID,
	).Scan(&parentBookingID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", &BookingError{Code: "not_booked", Message: "Book the class before adding a +1"}
	}
	if err != nil {
		return "", err
	}

	// Already brought someone?
	var existing sql.NullString
	if err := tx.QueryRowContext(ctx, `
		SELECT id FROM bookings
		 WHERE class_id = ? AND user_id = ? AND is_plus_one = 1 AND status = 'booked'
		 LIMIT 1`,
		classID, userID,
	).Scan(&existing); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if existing.Valid {
		return "", &BookingError{Code: "plus_one_exists", Message: "You already have a +1 booked for this class."}
	}

	// One more seat has to fit.
	if bookedCount+1 > capacity {
		return "", &BookingError{Code: "class_full", Message: "class is full"}
	}

	// Validate the CHOSEN pass: active, covers this class type, not expired,
	// a credit pass (unlimited can't fund a +1), with a spare credit.
	var passKind string
	var creditsR sql.NullInt64
	err = tx.QueryRowContext(ctx, `
		SELECT e.pass_kind, e.credits_remaining
		  FROM entitlements e
		  JOIN entitlement_class_types ect ON ect.entitlement_id = e.id
		  JOIN classes c                   ON c.id = ?
		 WHERE e.id = ? AND e.user_id = ? AND e.studio_id = ?
		   AND e.status = 'active'
		   AND ect.class_type_id = c.class_type_id
		   AND (e.expires_at IS NULL OR e.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now'))`,
		classID, entitlementID, userID, studioID,
	).Scan(&passKind, &creditsR)
	if errors.Is(err, sql.ErrNoRows) {
		return "", &BookingError{Code: "entitlement_ineligible", Message: "That pass can't cover this class."}
	}
	if err != nil {
		return "", err
	}
	if passKind == "unlimited" {
		return "", &BookingError{
			Code:    "plus_one_unlimited_not_allowed",
			Message: "+1 guests need a credit pass — pick one of your credit passes.",
		}
	}
	if !creditsR.Valid || creditsR.Int64 < 1 {
		return "", &BookingError{Code: "no_credits", Message: "That pass has no credits left for a +1."}
	}

	plusOneID := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one, plus_one_name, parent_booking_id,
		     booked_by_role, cancel_cutoff_hours, status, checkin_token)
		    VALUES (?, ?, ?, ?, ?, 1, ?, ?, 'student', ?, 'booked', ?)`,
		plusOneID, studioID, classID, userID, entitlementID, plusOneName, parentBookingID, cutoffHours,
		NewID(),
	); err != nil {
		// uq_bookings_active_seat (class, user, is_plus_one=1) — a concurrent
		// add raced us to the single +1 slot.
		return "", &BookingError{Code: "plus_one_failed", Message: "You already have a +1 booked for this class."}
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE entitlements SET credits_remaining = credits_remaining - 1 WHERE id = ?`,
		entitlementID,
	); err != nil {
		return "", err
	}
	// Same action name as the at-booking-time +1 so the Activity log + abuse
	// filters treat both paths identically; added_after_booking distinguishes
	// them for anyone who cares to look.
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"booking_plus_one", "booking", plusOneID, map[string]any{
			"class_id":            classID,
			"class_title":         classTitle,
			"parent_booking_id":   parentBookingID,
			"entitlement_id":      entitlementID,
			"friend_name":         plusOneName,
			"added_after_booking": true,
		}); err != nil {
		return "", fmt.Errorf("audit plus_one: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return plusOneID, nil
}

// CancelBooking marks a booking cancelled and records the business outcome.
//
//	cancelled_free         — cancelled outside the snapshotted cutoff window:
//	                         credit pass gets its credit back, unlimited just
//	                         frees the seat.
//	cancelled_late_burned  — cancelled inside the cutoff: pass stays consumed.
//
// The cutoff was snapshotted onto the booking at create-time so a later
// studio policy change can't retroactively re-classify history.
func (s *Store) CancelBooking(ctx context.Context, userID, bookingID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var (
		classStartStr string
		cutoffHours   int
		studioID      string
		classID       string
		classTitle    string
	)
	err = tx.QueryRowContext(ctx, `
		SELECT c.starts_at, b.cancel_cutoff_hours,
		       b.studio_id, b.class_id, COALESCE(c.title,'')
		  FROM bookings b
		  JOIN classes c ON c.id = b.class_id
		 WHERE b.id = ? AND b.user_id = ? AND b.status = 'booked'`,
		bookingID, userID,
	).Scan(&classStartStr, &cutoffHours, &studioID, &classID, &classTitle)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}

	classStart, err := time.Parse(time.RFC3339, classStartStr)
	if err != nil {
		return err
	}
	// Once the class has begun, cancellation is no longer a meaningful
	// action — the seat has already been used (or not) and we don't want
	// to retroactively rewrite history into a late-cancel. The earlier
	// cutoff window already handled the "late but still allowed" case.
	if !time.Now().UTC().Before(classStart) {
		return ErrClassStarted
	}
	cutoff := classStart.Add(-time.Duration(cutoffHours) * time.Hour)
	outcome := "cancelled_free"
	if time.Now().UTC().After(cutoff) {
		outcome = "cancelled_late_burned"
	}

	// Snapshot the seats about to be cancelled (the parent + any +1 child)
	// with each seat's own entitlement + pass kind. We refund per-seat to the
	// pass that actually paid for it — the parent and the +1 can be on
	// different passes now that a post-hoc +1 picks its own pass.
	type cancelledSeat struct {
		entitlementID string
		passKind      string
	}
	seatRows, err := tx.QueryContext(ctx, `
		SELECT b.entitlement_id, e.pass_kind
		  FROM bookings b
		  JOIN entitlements e ON e.id = b.entitlement_id
		 WHERE (b.id = ? OR b.parent_booking_id = ?) AND b.status = 'booked'`,
		bookingID, bookingID,
	)
	if err != nil {
		return err
	}
	var cancelledSeats []cancelledSeat
	for seatRows.Next() {
		var st cancelledSeat
		if err := seatRows.Scan(&st.entitlementID, &st.passKind); err != nil {
			seatRows.Close()
			return err
		}
		cancelledSeats = append(cancelledSeats, st)
	}
	seatRows.Close()
	if err := seatRows.Err(); err != nil {
		return err
	}

	// Cancellation cascades to the +1 child row if one exists. Letting the
	// parent walk while the child stays 'booked' leaves an orphan seat held
	// against capacity. The checkin_token deliberately stays put on cancelled
	// rows so the scan endpoint can resolve a stale QR to a specific
	// "was_cancelled" outcome instead of a generic "invalid_token".
	if _, err := tx.ExecContext(ctx, `
		UPDATE bookings
		   SET status       = 'cancelled',
		       outcome      = ?,
		       cancelled_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE (id = ? OR parent_booking_id = ?)
		   AND status = 'booked'`,
		outcome, bookingID, bookingID,
	); err != nil {
		return err
	}
	rowsAffected := len(cancelledSeats)

	// Free cancel refunds one credit per cancelled credit seat, each to its
	// own pass. Unlimited seats and late cancels keep the pass consumed.
	if outcome == "cancelled_free" {
		refundByEntitlement := map[string]int{}
		for _, st := range cancelledSeats {
			if st.passKind == "credit" {
				refundByEntitlement[st.entitlementID]++
			}
		}
		for entID, n := range refundByEntitlement {
			if _, err := tx.ExecContext(ctx,
				`UPDATE entitlements SET credits_remaining = credits_remaining + ? WHERE id = ?`,
				n, entID,
			); err != nil {
				return err
			}
		}
	}
	// Audit the student's own cancel so support can trace "but I cancelled
	// in time!" disputes back to a real event. Records the outcome (free
	// vs late) so a reader can spot a cancel that fired moments before the
	// cutoff without re-deriving from timestamps. cascade_count = 2 marks
	// rows where a +1 was cancelled alongside the parent.
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"booking_cancel", "booking", bookingID, map[string]any{
			"class_id":      classID,
			"class_title":   classTitle,
			"outcome":       outcome,
			"cascade_count": rowsAffected,
		}); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}

	// Offer the freed seats to the waitlist asynchronously — the student
	// who cancelled doesn't need to wait on N waitlist notifications + push
	// dispatches before their request returns. A detached context so the
	// goroutine isn't cancelled when the HTTP handler returns. One offer
	// per cancelled row (a parent + +1 cascade frees two). Benign races
	// ("no waiters" / "full") are expected and end the loop quietly.
	freedSeats := rowsAffected
	go func() {
		ctx := context.Background()
		for i := 0; i < freedSeats; i++ {
			_, err := s.PromoteWaitlist(ctx, studioID, "", classID)
			if err == nil {
				continue
			}
			msg := err.Error()
			if msg == "waitlist is empty" || msg == "class is full" {
				return
			}
			if errors.Is(err, sql.ErrConnDone) ||
				strings.Contains(msg, "database is closed") {
				return // process shutdown raced us; nothing to log
			}
			log.Printf("auto-promote after cancel (class=%s): %v", classID, err)
			return
		}
	}()
	return nil
}

// BookingPreview reports what the server would allow for this (class,
// entitlement) pair — without writing anything. The client renders the
// booking sheet directly from this so it doesn't have to duplicate the
// eligibility rules (capacity, pass kind, credit count, +1 gate). The
// reason strings match the BookingError codes that CreateBooking emits.
type BookingPreview struct {
	CanBook             bool   `json:"can_book"`
	BlockReason         string `json:"block_reason,omitempty"`
	BlockMessage        string `json:"block_message,omitempty"`
	CreditsRemaining    *int   `json:"credits_remaining,omitempty"` // null for unlimited
	PlusOneEligible     bool   `json:"plus_one_eligible"`
	PlusOneBlockReason  string `json:"plus_one_block_reason,omitempty"`
	PlusOneBlockMessage string `json:"plus_one_block_message,omitempty"`
}

func (s *Store) BookingPreview(ctx context.Context, studioID, userID, classID, entitlementID string) (*BookingPreview, error) {
	out := &BookingPreview{CanBook: true, PlusOneEligible: true}

	// Class + capacity + studio plus-one gate.
	var capacity, bookedCount, plusOneStudioAllowed int
	var classStartStr string
	err := s.db.QueryRowContext(ctx, `
		SELECT c.starts_at,
		       c.capacity,
		       (SELECT COUNT(*) FROM bookings b
		         WHERE b.class_id = c.id AND b.status = 'booked'),
		       s.allow_student_plus_one
		  FROM classes c
		  JOIN studios s ON s.id = c.studio_id
		 WHERE c.id = ? AND c.studio_id = ? AND c.status = 'scheduled'`,
		classID, studioID,
	).Scan(&classStartStr, &capacity, &bookedCount, &plusOneStudioAllowed)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	// Mirror the CreateBooking gate so the client knows to hide the Book
	// button (and we don't promise a booking the server would reject).
	classStart, err := time.Parse(time.RFC3339, classStartStr)
	if err != nil {
		return nil, err
	}
	if !time.Now().UTC().Before(classStart) {
		out.CanBook = false
		out.BlockReason = "class_already_started"
		out.BlockMessage = "Class has already started"
		out.PlusOneEligible = false
		out.PlusOneBlockReason = "class_already_started"
		return out, nil
	}
	if bookedCount >= capacity {
		out.CanBook = false
		out.BlockReason = "class_full"
		out.BlockMessage = "Class is full"
		out.PlusOneEligible = false
		out.PlusOneBlockReason = "class_full"
		return out, nil
	}
	if bookedCount+2 > capacity {
		out.PlusOneEligible = false
		out.PlusOneBlockReason = "no_seat_for_plus_one"
		out.PlusOneBlockMessage = "Only one seat left — not enough for a +1"
	}

	// Entitlement: must be active, cover this class, not expired.
	var passKind string
	var creditsR sql.NullInt64
	err = s.db.QueryRowContext(ctx, `
		SELECT e.pass_kind, e.credits_remaining
		  FROM entitlements e
		  JOIN entitlement_class_types ect ON ect.entitlement_id = e.id
		  JOIN classes c                   ON c.id = ?
		 WHERE e.id = ? AND e.user_id = ? AND e.studio_id = ?
		   AND e.status = 'active'
		   AND ect.class_type_id = c.class_type_id
		   AND (e.expires_at IS NULL OR e.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now'))`,
		classID, entitlementID, userID, studioID,
	).Scan(&passKind, &creditsR)
	if errors.Is(err, sql.ErrNoRows) {
		out.CanBook = false
		out.BlockReason = "entitlement_ineligible"
		out.BlockMessage = "This pass doesn't cover this class"
		out.PlusOneEligible = false
		out.PlusOneBlockReason = "entitlement_ineligible"
		return out, nil
	}
	if err != nil {
		return nil, err
	}

	if passKind == "credit" {
		credits := int(creditsR.Int64)
		out.CreditsRemaining = &credits
		if credits < 1 {
			out.CanBook = false
			out.BlockReason = "no_credits"
			out.BlockMessage = "No credits left on this pass"
		}
		if credits < 2 && out.PlusOneEligible {
			out.PlusOneEligible = false
			out.PlusOneBlockReason = "no_credit_for_plus_one"
			out.PlusOneBlockMessage = "Need 2 credits to book a +1"
		}
	}
	// Unlimited passes don't decrement on booking, so a +1 would let one
	// subscription bring unlimited free guests. Restricted to credit only.
	if passKind == "unlimited" && out.PlusOneEligible {
		out.PlusOneEligible = false
		out.PlusOneBlockReason = "plus_one_unlimited_not_allowed"
		out.PlusOneBlockMessage = "+1 needs a credit pass"
	}
	if plusOneStudioAllowed == 0 && out.PlusOneEligible {
		out.PlusOneEligible = false
		out.PlusOneBlockReason = "studio_disabled"
		out.PlusOneBlockMessage = "Studio doesn't allow +1 guests"
	}

	return out, nil
}

// CancelPreview reports what would happen if a student cancelled this
// booking *right now* — without mutating anything. The client uses it
// to show a "free vs late" warning in the cancel confirmation dialog,
// so the message it shows and the outcome the server writes can't drift
// apart (different clocks, TZ handling, etc.). Mirror of the calculation
// at the top of CancelBooking — keep them in sync.
type CancelPreview struct {
	// CanCancel is false once the class has begun — cancellation is refused
	// outright at that point (see ErrClassStarted). The UI uses this to
	// hide the cancel button instead of letting it open a doomed dialog.
	CanCancel        bool      `json:"can_cancel"`
	BlockReason      string    `json:"block_reason,omitempty"`
	BlockMessage     string    `json:"block_message,omitempty"`
	Outcome          string    `json:"outcome"`            // cancelled_free | cancelled_late_burned
	IsLate           bool      `json:"is_late"`            // convenience for the UI
	CreditWillReturn bool      `json:"credit_will_return"` // only true on credit + free cancel
	FreeUntil        time.Time `json:"free_until"`         // cutoff threshold, UTC
}

func (s *Store) CancelPreview(ctx context.Context, userID, bookingID string) (*CancelPreview, error) {
	var (
		classStartStr string
		cutoffHours   int
		passKind      string
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT c.starts_at, b.cancel_cutoff_hours, e.pass_kind
		  FROM bookings b
		  JOIN classes      c ON c.id = b.class_id
		  JOIN entitlements e ON e.id = b.entitlement_id
		 WHERE b.id = ? AND b.user_id = ? AND b.status = 'booked'`,
		bookingID, userID,
	).Scan(&classStartStr, &cutoffHours, &passKind)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	classStart, err := time.Parse(time.RFC3339, classStartStr)
	if err != nil {
		return nil, err
	}
	cutoff := classStart.Add(-time.Duration(cutoffHours) * time.Hour)
	now := time.Now().UTC()
	if !now.Before(classStart) {
		return &CancelPreview{
			CanCancel:    false,
			BlockReason:  "class_already_started",
			BlockMessage: "Class has already started",
			Outcome:      "cancelled_late_burned",
			IsLate:       true,
			FreeUntil:    cutoff,
		}, nil
	}
	isLate := now.After(cutoff)
	outcome := "cancelled_free"
	if isLate {
		outcome = "cancelled_late_burned"
	}
	return &CancelPreview{
		CanCancel:        true,
		Outcome:          outcome,
		IsLate:           isLate,
		CreditWillReturn: !isLate && passKind == "credit",
		FreeUntil:        cutoff,
	}, nil
}

// UpcomingBooking is one row in GET /bookings?scope=upcoming or ?scope=past.
// Status is always "booked" for upcoming; for past it reflects the final state
// (attended | no_show | cancelled | booked-but-class-passed).
type UpcomingBooking struct {
	ID                 string  `json:"id"`
	ClassID            string  `json:"class_id"`
	Title              string  `json:"title"`
	StartsAt           string  `json:"starts_at"`
	EndsAt             string  `json:"ends_at"`
	RoomName           string  `json:"room_name"`
	InstructorName     string  `json:"instructor_name"`
	InstructorPhotoURL *string `json:"instructor_photo_url,omitempty"`
	Status             string  `json:"status"`
}

func (s *Store) UpcomingBookings(ctx context.Context, userID string) ([]UpcomingBooking, error) {
	const q = `
		SELECT b.id, c.id, COALESCE(c.title,''), c.starts_at, c.ends_at, r.name,
		       i.full_name, i.photo_url, b.status
		  FROM bookings b
		  JOIN classes c ON c.id = b.class_id
		  JOIN rooms r   ON r.id = c.room_id
		  JOIN users i   ON i.id = c.instructor_id
		 WHERE b.user_id = ?
		   AND b.status  = 'booked'
		   AND c.starts_at >= strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY c.starts_at ASC
		 LIMIT 20`
	return scanBookings(ctx, s, q, userID)
}

// PastBookings returns the caller's history — classes whose start time has
// passed. Includes cancelled and unmarked rows so the student sees their full
// history with status badges. Latest first.
func (s *Store) PastBookings(ctx context.Context, userID string) ([]UpcomingBooking, error) {
	const q = `
		SELECT b.id, c.id, COALESCE(c.title,''), c.starts_at, c.ends_at, r.name,
		       i.full_name, i.photo_url, b.status
		  FROM bookings b
		  JOIN classes c ON c.id = b.class_id
		  JOIN rooms r   ON r.id = c.room_id
		  JOIN users i   ON i.id = c.instructor_id
		 WHERE b.user_id = ?
		   AND c.starts_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY c.starts_at DESC
		 LIMIT 50`
	return scanBookings(ctx, s, q, userID)
}

func scanBookings(ctx context.Context, s *Store, q string, userID string) ([]UpcomingBooking, error) {
	rows, err := s.db.QueryContext(ctx, q, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]UpcomingBooking, 0)
	for rows.Next() {
		var (
			u        UpcomingBooking
			photoURL sql.NullString
		)
		if err := rows.Scan(&u.ID, &u.ClassID, &u.Title, &u.StartsAt, &u.EndsAt, &u.RoomName, &u.InstructorName, &photoURL, &u.Status); err != nil {
			return nil, err
		}
		if photoURL.Valid {
			s := photoURL.String
			u.InstructorPhotoURL = &s
		}
		out = append(out, u)
	}
	return out, rows.Err()
}
