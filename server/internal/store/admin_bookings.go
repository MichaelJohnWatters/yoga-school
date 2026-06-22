// Manager-initiated booking + cancel. The student-self flow lives in
// classes.go (CreateBooking / CancelBooking) — these are the parallel
// admin paths that thread an actor through the audit log and let the
// manager override gates the student-facing flow enforces (the
// allow_student_plus_one studio toggle, the cancel-cutoff window).
//
// Capacity and entitlement-eligibility are NOT overridden: a manager
// shouldn't be able to seat someone with no eligible pass (they should
// grant one first) or push the class past capacity (they should bump
// the class capacity first). Both are easier to undo than the audit
// trail of an over-booked, comp'd-by-accident class.

package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// CreateAdminBookingResult mirrors what the student-self CreateBooking
// returns (a single id) but is named so the API layer can grow more
// fields without another rename.
type CreateAdminBookingResult struct {
	BookingID string `json:"booking_id"`
}

// CreateAdminBooking books `userID` into `classID` on behalf of the
// manager `actorID`. Behaviour vs CreateBooking:
//
//   - booked_by_role on the inserted row is 'manager'
//   - allow_student_plus_one is bypassed (managers can always +1)
//   - if the student is currently on this class's waitlist, the entry
//     is auto-marked 'left' so the queue stays contiguous and they
//     don't sit in the queue and the seat at the same time
//   - audit row 'booking_create_admin' is keyed to actorID, with detail
//     describing the student + class so the activity log reads cleanly
//
// Capacity, class-already-started, entitlement-eligibility, and the
// +1-unlimited-pass restrictions all behave exactly like CreateBooking.
func (s *Store) CreateAdminBooking(
	ctx context.Context,
	studioID, actorID, classID, userID, entitlementID string,
	plusOne bool, plusOneName string,
) (*CreateAdminBookingResult, error) {
	plusOneName = strings.TrimSpace(plusOneName)
	if plusOne && plusOneName == "" {
		return nil, &BookingError{
			Code:    "plus_one_name_required",
			Message: "Add the friend's name for the +1 seat",
		}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Class shape — capacity, current bookings, cutoff snapshot, plus
	// title + user name so the audit row can render with human labels.
	var (
		capacity, bookedCount, cutoffHours int
		classStartStr, classTitle, userName string
	)
	err = tx.QueryRowContext(ctx, `
		SELECT c.starts_at,
		       c.capacity,
		       (SELECT COUNT(*) FROM bookings b
		         WHERE b.class_id = c.id AND b.status = 'booked'),
		       s.free_cancel_cutoff_hours,
		       COALESCE(c.title,''),
		       (SELECT u.full_name FROM users u WHERE u.id = ?)
		  FROM classes c
		  JOIN studios s ON s.id = c.studio_id
		 WHERE c.id = ? AND c.studio_id = ? AND c.status = 'scheduled'`,
		userID, classID, studioID,
	).Scan(&classStartStr, &capacity, &bookedCount, &cutoffHours, &classTitle, &userName)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, &BookingError{Code: "class_not_found", Message: "class not found"}
	}
	if err != nil {
		return nil, err
	}
	classStart, err := time.Parse(time.RFC3339, classStartStr)
	if err != nil {
		return nil, err
	}
	if !time.Now().UTC().Before(classStart) {
		return nil, &BookingError{
			Code:    "class_already_started",
			Message: "Class has already started",
		}
	}

	seatsWanted := 1
	if plusOne {
		seatsWanted = 2
	}
	if bookedCount+seatsWanted > capacity {
		return nil, &BookingError{Code: "class_full", Message: "class is full"}
	}

	// If the student is on the waitlist for this class, drop their
	// active entry so they don't end up both seated and queued. Marked
	// 'left' rather than deleted to preserve the audit trail of "they
	// joined, then a manager seated them".
	if _, err := tx.ExecContext(ctx, `
		UPDATE waitlist_entries
		   SET status   = 'left',
		       left_at  = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE class_id = ? AND user_id = ? AND status = 'waiting'`,
		classID, userID,
	); err != nil {
		return nil, err
	}

	// Verify the entitlement covers this class + has the seats.
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
		return nil, &BookingError{Code: "entitlement_ineligible", Message: "entitlement does not cover this class"}
	}
	if err != nil {
		return nil, err
	}
	if passKind == "credit" {
		needed := int64(seatsWanted)
		if !creditsR.Valid || creditsR.Int64 < needed {
			return nil, &BookingError{Code: "no_credits", Message: "not enough credits on that pass"}
		}
	}
	if plusOne && passKind == "unlimited" {
		return nil, &BookingError{
			Code:    "plus_one_unlimited_not_allowed",
			Message: "+1 needs a credit pass — pick a credit pass for this booking",
		}
	}

	bookingID := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
		     booked_by_role, cancel_cutoff_hours, status, checkin_token)
		    VALUES (?, ?, ?, ?, ?, 0, 'manager', ?, 'booked', ?)`,
		bookingID, studioID, classID, userID, entitlementID, cutoffHours, NewID(),
	); err != nil {
		return nil, &BookingError{
			Code:    "already_booked",
			Message: "This student already has a booking for this class.",
		}
	}
	if plusOne {
		plusOneID := NewID()
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO bookings
			    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one, plus_one_name, parent_booking_id,
			     booked_by_role, cancel_cutoff_hours, status, checkin_token)
			    VALUES (?, ?, ?, ?, ?, 1, ?, ?, 'manager', ?, 'booked', ?)`,
			plusOneID, studioID, classID, userID, entitlementID, plusOneName, bookingID, cutoffHours,
			NewID(),
		); err != nil {
			return nil, &BookingError{
				Code:    "plus_one_failed",
				Message: "Couldn't add the +1 seat — already booked?",
			}
		}
	}

	if passKind == "credit" {
		if _, err := tx.ExecContext(ctx,
			`UPDATE entitlements SET credits_remaining = credits_remaining - ? WHERE id = ?`,
			seatsWanted, entitlementID,
		); err != nil {
			return nil, err
		}
	}

	// Notify the student so they know a seat was reserved for them.
	// Reuses the same "you're booked" payload as the self-book path —
	// the student doesn't need to know who pressed the button.
	push, err := writeBookingConfirmedTx(ctx, tx, studioID, userID, classID, bookingID)
	if err != nil {
		return nil, fmt.Errorf("booking_confirmed notif: %w", err)
	}

	// Audit, keyed to the manager. Carries the human labels so the
	// activity log reads "<actor> booked <student> into <class>" with
	// no follow-up lookups.
	detail := map[string]any{
		"user_id":        userID,
		"user_name":      userName,
		"class_id":       classID,
		"class_title":    classTitle,
		"entitlement_id": entitlementID,
		"pass_kind":      passKind,
		"seats":          seatsWanted,
	}
	if plusOne {
		detail["plus_one_name"] = plusOneName
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		"booking_create_admin", "booking", bookingID, detail); err != nil {
		return nil, fmt.Errorf("audit booking_create_admin: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	if push != nil {
		s.dispatchPush(push.userID, push.notifType, push.title, push.body, push.payloadJSON)
	}
	return &CreateAdminBookingResult{BookingID: bookingID}, nil
}

// CancelAdminBookingResult tells the caller what happened: how many
// rows were cancelled (a parent+friend cascade is 2) and whether the
// credit was returned. Returned even on success so the manager UI can
// render a precise confirmation toast.
type CancelAdminBookingResult struct {
	CascadeCount   int  `json:"cascade_count"`
	CreditReturned bool `json:"credit_returned"`
	Seats          int  `json:"seats"`
}

// CancelAdminBooking cancels any booking on behalf of the manager.
// Refund behaviour is the manager's explicit choice, not the
// cancel-cutoff window — pass refundCredit=true to put the credit(s)
// back, false to leave the pass consumed (e.g. for a no-show after
// the fact, or a courtesy cancel that the studio doesn't want to eat).
//
//   - cutoff is bypassed entirely (a manager can cancel any time before
//     the class starts)
//   - +1 child row cascades alongside the parent — refund decision
//     applies to both seats
//   - notifies the student with the "cancelled by studio" copy so they
//     don't think they did it themselves
//   - audit row 'booking_cancel_admin' is keyed to the manager, with
//     the refund flag in the detail so a later audit reader can match
//     "where's my credit?" disputes to a real decision
//   - if the cancel freed seats, offer them to the waitlist async
func (s *Store) CancelAdminBooking(
	ctx context.Context,
	studioID, actorID, bookingID string,
	refundCredit bool,
	reason string,
) (*CancelAdminBookingResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var (
		classStartStr, entitlementID, passKind  string
		classID, userID, userName, classTitle   string
		bookingStudio                           string
	)
	err = tx.QueryRowContext(ctx, `
		SELECT c.starts_at, b.entitlement_id, e.pass_kind,
		       b.studio_id, b.class_id, b.user_id, u.full_name,
		       COALESCE(c.title,'')
		  FROM bookings b
		  JOIN classes      c ON c.id = b.class_id
		  JOIN entitlements e ON e.id = b.entitlement_id
		  JOIN users        u ON u.id = b.user_id
		 WHERE b.id = ? AND b.status = 'booked'`,
		bookingID,
	).Scan(&classStartStr, &entitlementID, &passKind,
		&bookingStudio, &classID, &userID, &userName, &classTitle)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if bookingStudio != studioID {
		// Don't leak the existence of a booking in another studio.
		return nil, ErrNotFound
	}
	classStart, err := time.Parse(time.RFC3339, classStartStr)
	if err != nil {
		return nil, err
	}
	if !time.Now().UTC().Before(classStart) {
		// The class has begun — same rule as student CancelBooking:
		// attendance / no-show is the proper way to record what
		// happened, not a retroactive cancel.
		return nil, ErrClassStarted
	}

	// Outcome literal mirrors the existing column vocabulary so reports
	// keep working: 'cancelled_free' when we're refunding, otherwise
	// 'cancelled_late_burned' (the pass was consumed).
	outcome := "cancelled_late_burned"
	if refundCredit {
		outcome = "cancelled_free"
	}

	res, err := tx.ExecContext(ctx, `
		UPDATE bookings
		   SET status       = 'cancelled',
		       outcome      = ?,
		       cancelled_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE (id = ? OR parent_booking_id = ?)
		   AND status = 'booked'`,
		outcome, bookingID, bookingID,
	)
	if err != nil {
		return nil, err
	}
	rowsAffected, err := res.RowsAffected()
	if err != nil {
		return nil, err
	}

	creditReturned := false
	if refundCredit && passKind == "credit" {
		if _, err := tx.ExecContext(ctx,
			`UPDATE entitlements SET credits_remaining = credits_remaining + ? WHERE id = ?`,
			rowsAffected, entitlementID,
		); err != nil {
			return nil, err
		}
		creditReturned = true
	}

	// Notify the student with the "studio cancelled this for you" copy.
	// Gated by the same notification pref as a class-cancel notification
	// since the user experience is identical (a seat they had is gone
	// without their action).
	notify, err := userOptedInTx(ctx, tx, userID, "class_cancelled")
	if err != nil {
		return nil, err
	}
	if notify {
		nTitle := "Booking cancelled by the studio"
		body := "Your booking was cancelled by the studio."
		if classTitle != "" {
			nTitle = classTitle + " — booking cancelled"
		}
		if refundCredit && passKind == "credit" {
			body = "Your booking was cancelled by the studio · your credit has been returned."
		}
		payload := fmt.Sprintf(`{"class_id":"%s","booking_id":"%s"}`, classID, bookingID)
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO notifications (id, studio_id, user_id, type, title, body, payload)
			   VALUES (?, ?, ?, 'class_cancelled', ?, ?, ?)`,
			NewID(), studioID, userID, nTitle, body, payload,
		); err != nil {
			return nil, err
		}
	}

	detail := map[string]any{
		"user_id":         userID,
		"user_name":       userName,
		"class_id":        classID,
		"class_title":     classTitle,
		"credit_returned": creditReturned,
		"pass_kind":       passKind,
		"cascade_count":   rowsAffected,
	}
	if strings.TrimSpace(reason) != "" {
		detail["reason"] = strings.TrimSpace(reason)
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		"booking_cancel_admin", "booking", bookingID, detail); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	// Offer the freed seats to the waitlist — same async pattern as the
	// student self-cancel path. A seat is freed whether or not we
	// refunded the credit, so always run.
	seats := int(rowsAffected)
	go func() {
		ctx := context.Background()
		for i := 0; i < seats; i++ {
			_, err := s.PromoteWaitlist(ctx, studioID, "", classID)
			if err == nil {
				continue
			}
			var be *BookingError
			if errors.As(err, &be) {
				// "no waiters" / "class full" are expected — break the
				// loop quietly rather than logging noise.
				return
			}
			return
		}
	}()

	return &CancelAdminBookingResult{
		CascadeCount:   int(rowsAffected),
		CreditReturned: creditReturned,
		Seats:          seats,
	}, nil
}
