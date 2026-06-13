package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// ClassRow is one class as returned by /classes — joins instructor/room/type
// and includes per-caller booking state.
type ClassRow struct {
	ID                  string  `json:"id"`
	Title               string  `json:"title"`
	ClassTypeID         string  `json:"class_type_id"`
	ClassTypeName       string  `json:"class_type_name"`
	Discipline          string  `json:"discipline"`
	InstructorID        string  `json:"instructor_id"`
	InstructorName      string  `json:"instructor_name"`
	InstructorPhotoURL  *string `json:"instructor_photo_url,omitempty"`
	RoomID              string  `json:"room_id"`
	RoomName            string  `json:"room_name"`
	StartsAt            string  `json:"starts_at"`
	EndsAt              string  `json:"ends_at"`
	DurationMinutes     int     `json:"duration_minutes"`
	Capacity            int     `json:"capacity"`
	BookedCount         int     `json:"booked_count"`
	WaitlistCount       int     `json:"waitlist_count"`
	BookingState        string  `json:"booking_state"` // booked|available|full
	BookingID           string  `json:"booking_id,omitempty"`
}

// ClassesForDay returns every class on the given day (studio TZ approx UTC for
// dev), with the caller's booking state.
func (s *Store) ClassesForDay(ctx context.Context, studioID, userID string, day time.Time) ([]ClassRow, error) {
	dayStart := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, time.UTC)
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
			r.id, r.name,
			c.starts_at, c.ends_at, c.capacity,
			(SELECT COUNT(*) FROM bookings b
			    WHERE b.class_id = c.id AND b.status = 'booked') AS booked_count,
			(SELECT COUNT(*) FROM waitlist_entries w
			    WHERE w.class_id = c.id) AS waitlist_count,
			(SELECT b.id FROM bookings b
			    WHERE b.class_id = c.id AND b.user_id = ? AND b.status = 'booked'
			    LIMIT 1) AS my_booking_id
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
		userID, studioID,
		from.Format(time.RFC3339), to.Format(time.RFC3339),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []ClassRow
	for rows.Next() {
		var (
			r            ClassRow
			myBookingID  sql.NullString
			photoURL     sql.NullString
		)
		if err := rows.Scan(
			&r.ID, &r.Title,
			&r.ClassTypeID, &r.ClassTypeName, &r.Discipline,
			&r.InstructorID, &r.InstructorName, &photoURL,
			&r.RoomID, &r.RoomName,
			&r.StartsAt, &r.EndsAt, &r.Capacity,
			&r.BookedCount, &r.WaitlistCount, &myBookingID,
		); err != nil {
			return nil, err
		}
		if photoURL.Valid {
			s := photoURL.String
			r.InstructorPhotoURL = &s
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
			r.id, r.name,
			c.starts_at, c.ends_at, c.capacity,
			(SELECT COUNT(*) FROM bookings b
			    WHERE b.class_id = c.id AND b.status = 'booked') AS booked_count,
			(SELECT b.id FROM bookings b
			    WHERE b.class_id = c.id AND b.user_id = ? AND b.status = 'booked'
			    LIMIT 1) AS my_booking_id,
			(SELECT COUNT(*) FROM waitlist_entries w
			    WHERE w.class_id = c.id) AS waitlist_count
		  FROM classes c
		  JOIN class_types ct ON ct.id = c.class_type_id
		  JOIN users i        ON i.id = c.instructor_id
		  JOIN rooms r        ON r.id = c.room_id
		 WHERE c.id = ? AND c.studio_id = ?`
	var (
		out         ClassDetail
		myBookingID sql.NullString
		photoURL    sql.NullString
	)
	err := s.db.QueryRowContext(ctx, q, userID, classID, studioID).Scan(
		&out.ID, &out.Title,
		&out.ClassTypeID, &out.ClassTypeName, &out.Discipline,
		&out.InstructorID, &out.InstructorName, &photoURL,
		&out.RoomID, &out.RoomName,
		&out.StartsAt, &out.EndsAt, &out.Capacity,
		&out.BookedCount, &myBookingID, &out.WaitlistCount,
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

// BookingError carries a specific reason for a refused booking.
type BookingError struct{ Code, Message string }

func (e *BookingError) Error() string { return e.Message }

// CreateBooking inserts a booking after verifying capacity + entitlement.
// If plusOne is true, an additional is_plus_one=1 row is inserted in the same
// transaction and credit consumption doubles. Gated by studio's
// allow_student_plus_one setting (manager callers bypass — not modeled yet).
// Returns the (primary) new booking ID on success.
func (s *Store) CreateBooking(ctx context.Context, studioID, userID, classID, entitlementID string, plusOne bool) (string, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	// Verify the class exists + has room (count both seats if +1).
	var capacity, bookedCount, cutoffHours, plusOneAllowed int
	err = tx.QueryRowContext(ctx, `
		SELECT c.capacity,
		       (SELECT COUNT(*) FROM bookings b WHERE b.class_id = c.id AND b.status = 'booked'),
		       s.free_cancel_cutoff_hours,
		       s.allow_student_plus_one
		  FROM classes c
		  JOIN studios s ON s.id = c.studio_id
		 WHERE c.id = ? AND c.studio_id = ? AND c.status = 'scheduled'`,
		classID, studioID,
	).Scan(&capacity, &bookedCount, &cutoffHours, &plusOneAllowed)
	if errors.Is(err, sql.ErrNoRows) {
		return "", &BookingError{Code: "class_not_found", Message: "class not found"}
	}
	if err != nil {
		return "", err
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

	bookingID := uuid.NewString()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one, booked_by_role, cancel_cutoff_hours, status)
		    VALUES (?, ?, ?, ?, ?, 0, 'student', ?, 'booked')`,
		bookingID, studioID, classID, userID, entitlementID, cutoffHours,
	); err != nil {
		return "", &BookingError{Code: "already_booked", Message: fmt.Sprintf("already booked: %v", err)}
	}
	if plusOne {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO bookings
			    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one, parent_booking_id,
			     booked_by_role, cancel_cutoff_hours, status)
			    VALUES (?, ?, ?, ?, ?, 1, ?, 'student', ?, 'booked')`,
			uuid.NewString(), studioID, classID, userID, entitlementID, bookingID, cutoffHours,
		); err != nil {
			return "", &BookingError{Code: "plus_one_failed", Message: fmt.Sprintf("plus one: %v", err)}
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

	return bookingID, tx.Commit()
}

// CancelBooking marks a booking cancelled. Caller-side rules (free vs late)
// will follow once the cancel-cutoff snapshot is wired into reporting.
func (s *Store) CancelBooking(ctx context.Context, userID, bookingID string) error {
	res, err := s.db.ExecContext(ctx, `
		UPDATE bookings
		   SET status = 'cancelled',
		       cancelled_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ? AND user_id = ? AND status = 'booked'`,
		bookingID, userID,
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
