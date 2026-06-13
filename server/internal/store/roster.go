package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/google/uuid"
)

// Roster is the payload for GET /admin/classes/{id}/roster.
type Roster struct {
	Class      RosterClassHeader  `json:"class"`
	Counts     RosterCounts       `json:"counts"`
	Booked     []RosterBookingRow `json:"booked"`
	Waitlist   []RosterWaitlistRow `json:"waitlist"`
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
	Booked    int `json:"booked"`
	Unmarked  int `json:"unmarked"`
	Present   int `json:"present"`
	NoShow    int `json:"no_show"`
}

type RosterBookingRow struct {
	BookingID         string  `json:"booking_id"`
	UserID            string  `json:"user_id"`
	FullName          string  `json:"full_name"`
	PhotoURL          *string `json:"photo_url,omitempty"`
	PassLabel         string  `json:"pass_label"`
	Status            string  `json:"status"` // booked | attended | no_show | cancelled
	IsPlusOne         bool    `json:"is_plus_one"`
	AttendanceVia     *string `json:"attendance_via,omitempty"`
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

	// Bookings — every non-cancelled row.
	rows, err := s.db.QueryContext(ctx, `
		SELECT b.id, u.id, u.full_name, u.photo_url,
		       COALESCE(e.label, ''), b.status, b.is_plus_one, b.attendance_marked_by
		  FROM bookings b
		  JOIN users u ON u.id = b.user_id
		  JOIN entitlements e ON e.id = b.entitlement_id
		 WHERE b.class_id = ? AND b.status != 'cancelled'
		 ORDER BY b.created_at ASC`,
		classID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			r            RosterBookingRow
			photo, via   sql.NullString
			plusOneInt   int
		)
		if err := rows.Scan(&r.BookingID, &r.UserID, &r.FullName, &photo,
			&r.PassLabel, &r.Status, &plusOneInt, &via); err != nil {
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
		r.IsPlusOne = plusOneInt != 0
		out.Booked = append(out.Booked, r)
		switch r.Status {
		case "booked":
			out.Counts.Unmarked++
		case "attended":
			out.Counts.Present++
		case "no_show":
			out.Counts.NoShow++
		}
		out.Counts.Booked++
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Waitlist.
	wrows, err := s.db.QueryContext(ctx, `
		SELECT u.id, u.full_name, w.position
		  FROM waitlist_entries w
		  JOIN users u ON u.id = w.user_id
		 WHERE w.class_id = ?
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

// CheckinScan resolves a check-in token to a user, finds their booking on
// the given class, and marks it attended via=scan. Returns ScanError with a
// code for the caller to surface (invalid_token, no_booking, was_cancelled).
// On a successful (non-idempotent) mark, writes an audit row keyed by actorID
// — the manager whose console performed the scan.
func (s *Store) CheckinScan(ctx context.Context, studioID, actorID, token, classID string) (*ScanResult, error) {
	if token == "" {
		return nil, &ScanError{Code: "invalid_token", Message: "token is required"}
	}
	if classID == "" {
		return nil, &ScanError{Code: "class_required", Message: "class_id is required"}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var userID, userName string
	err = tx.QueryRowContext(ctx,
		`SELECT id, full_name FROM users WHERE studio_id = ? AND checkin_token = ?`,
		studioID, token,
	).Scan(&userID, &userName)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, &ScanError{Code: "invalid_token", Message: "no student matches that code"}
	}
	if err != nil {
		return nil, err
	}

	var classTitle string
	err = tx.QueryRowContext(ctx,
		`SELECT COALESCE(title,'') FROM classes WHERE id = ? AND studio_id = ?`,
		classID, studioID,
	).Scan(&classTitle)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, &ScanError{Code: "class_not_found", Message: "class not found"}
	}
	if err != nil {
		return nil, err
	}

	var bookingID, status string
	err = tx.QueryRowContext(ctx, `
		SELECT id, status FROM bookings
		 WHERE class_id = ? AND user_id = ? AND is_plus_one = 0
		 ORDER BY created_at DESC LIMIT 1`,
		classID, userID,
	).Scan(&bookingID, &status)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, &ScanError{Code: "no_booking", Message: "no booking for this class"}
	}
	if err != nil {
		return nil, err
	}
	if status == "cancelled" {
		return nil, &ScanError{Code: "was_cancelled", Message: "booking was cancelled"}
	}

	res := &ScanResult{
		BookingID: bookingID, UserID: userID, UserName: userName,
		ClassID: classID, ClassTitle: classTitle,
		WasAlready: status == "attended",
	}

	if !res.WasAlready {
		if _, err := tx.ExecContext(ctx, `
			UPDATE bookings
			   SET status = 'attended', attendance_marked_by = 'scan'
			 WHERE id = ?`, bookingID,
		); err != nil {
			return nil, err
		}
		if err := s.writeAuditTx(ctx, tx, studioID, actorID,
			"attendance_scan", "booking", bookingID, map[string]any{
				"user_id":  userID,
				"class_id": classID,
			}); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return res, nil
}

// MarkAttendance flips a booking's status to attended or no_show. Idempotent.
func (s *Store) MarkAttendance(ctx context.Context, bookingID, status, via string) error {
	if status != "attended" && status != "no_show" && status != "booked" {
		return fmt.Errorf("invalid attendance status: %s", status)
	}
	var actualVia any
	if status == "booked" {
		actualVia = nil
	} else {
		actualVia = via
	}
	res, err := s.db.ExecContext(ctx, `
		UPDATE bookings
		   SET status = ?, attendance_marked_by = ?
		 WHERE id = ? AND status != 'cancelled'`,
		status, actualVia, bookingID,
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

// PromoteResult is what /admin/classes/{id}/promote returns.
type PromoteResult struct {
	BookingID      string  `json:"booking_id"`
	PromotedUserID string  `json:"promoted_user_id"`
	PromotedName   string  `json:"promoted_name"`
	Position       int     `json:"position"`
	NotificationID string  `json:"notification_id"`
	NextWaitlistN  int     `json:"next_waitlist_size"`
	NoEligibleErr  *string `json:"no_eligible_error,omitempty"`
}

// PromoteWaitlist takes the first waitlist entry and books them into the class.
// Picks the user's best eligible entitlement automatically. Returns an error
// if no waitlist entries exist or the chosen user has no eligible pass.
//
// Side effects in one tx:
//   1. Remove waitlist row
//   2. Insert booking (uses entitlement; decrements credits if applicable)
//   3. Insert a waitlist_promoted notification for the student
func (s *Store) PromoteWaitlist(ctx context.Context, studioID, classID string) (*PromoteResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Class info for capacity + cutoff snapshot.
	var capacity, bookedCount, cutoffHours int
	err = tx.QueryRowContext(ctx, `
		SELECT c.capacity,
		       (SELECT COUNT(*) FROM bookings b WHERE b.class_id = c.id AND b.status = 'booked'),
		       s.free_cancel_cutoff_hours
		  FROM classes c
		  JOIN studios s ON s.id = c.studio_id
		 WHERE c.id = ? AND c.studio_id = ? AND c.status = 'scheduled'`,
		classID, studioID,
	).Scan(&capacity, &bookedCount, &cutoffHours)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if bookedCount >= capacity {
		return nil, fmt.Errorf("class is full")
	}

	// First waitlist entry.
	var (
		waitlistID, userID, fullName string
		position                     int
	)
	err = tx.QueryRowContext(ctx, `
		SELECT w.id, w.user_id, u.full_name, w.position
		  FROM waitlist_entries w
		  JOIN users u ON u.id = w.user_id
		 WHERE w.class_id = ?
		 ORDER BY w.position ASC LIMIT 1`,
		classID,
	).Scan(&waitlistID, &userID, &fullName, &position)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("waitlist is empty")
	}
	if err != nil {
		return nil, err
	}

	// Pick the user's best eligible entitlement (same query as the student
	// /classes/{id}/eligible-entitlements would return).
	var (
		entitlementID, passKind string
		creditsR                sql.NullInt64
	)
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
		msg := fmt.Sprintf("%s has no eligible pass — cannot promote", fullName)
		return nil, &BookingError{Code: "no_eligible_entitlement", Message: msg}
	}
	if err != nil {
		return nil, err
	}

	bookingID := uuid.NewString()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
		     booked_by_role, cancel_cutoff_hours, status)
		    VALUES (?, ?, ?, ?, ?, 0, 'manager', ?, 'booked')`,
		bookingID, studioID, classID, userID, entitlementID, cutoffHours,
	); err != nil {
		return nil, fmt.Errorf("insert booking from waitlist: %w", err)
	}
	if passKind == "credit" {
		if _, err := tx.ExecContext(ctx,
			`UPDATE entitlements SET credits_remaining = credits_remaining - 1 WHERE id = ?`,
			entitlementID,
		); err != nil {
			return nil, err
		}
	}
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM waitlist_entries WHERE id = ?`, waitlistID,
	); err != nil {
		return nil, err
	}

	notificationID := uuid.NewString()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO notifications
		    (id, studio_id, user_id, type, title, body, payload)
		    VALUES (?, ?, ?, 'waitlist_promoted',
		            'A spot opened — you''re booked',
		            'We promoted you off the waitlist. See you in class!',
		            ?)`,
		notificationID, studioID, userID,
		fmt.Sprintf(`{"class_id":"%s","booking_id":"%s"}`, classID, bookingID),
	); err != nil {
		return nil, err
	}

	// Count remaining waitlist for the response.
	var nextN int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM waitlist_entries WHERE class_id = ?`, classID,
	).Scan(&nextN); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}

	return &PromoteResult{
		BookingID:      bookingID,
		PromotedUserID: userID,
		PromotedName:   fullName,
		Position:       position,
		NotificationID: notificationID,
		NextWaitlistN:  nextN,
	}, nil
}
