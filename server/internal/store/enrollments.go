package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// EnrollmentSummary is one row in GET /enrollments.
type EnrollmentSummary struct {
	ID             string `json:"id"`
	Title          string `json:"title"`
	Description    string `json:"description"`
	SessionCount   int    `json:"session_count"`
	Capacity       int    `json:"capacity"`
	EnrolledCount  int    `json:"enrolled_count"`
	PriceMinor     int    `json:"price_minor"`
	Currency       string `json:"currency"`
	StartsAt       string `json:"starts_at"`
	EndsAt         string `json:"ends_at"`
	InstructorName string `json:"instructor_name"`
	SeriesState    string `json:"series_state"` // open | full | enrolled
}

// MyEnrollmentState reports per-caller enrollment.
func (s *Store) ListEnrollments(ctx context.Context, studioID, userID string) ([]EnrollmentSummary, error) {
	const q = `
		SELECT e.id, e.title, COALESCE(e.description,''), e.session_count, e.capacity,
		       p.price_minor, st.currency,
		       (SELECT COUNT(*) FROM enrollment_bookings eb
		           WHERE eb.enrollment_id = e.id AND eb.status = 'active') AS enrolled,
		       (SELECT MIN(c.starts_at) FROM classes c WHERE c.enrollment_id = e.id) AS starts_at,
		       (SELECT MAX(c.ends_at)   FROM classes c WHERE c.enrollment_id = e.id) AS ends_at,
		       (SELECT i.full_name FROM classes c JOIN users i ON i.id = c.instructor_id
		          WHERE c.enrollment_id = e.id ORDER BY c.starts_at LIMIT 1) AS instructor_name,
		       EXISTS (
		         SELECT 1 FROM enrollment_bookings eb
		          WHERE eb.enrollment_id = e.id
		            AND eb.user_id = ? AND eb.status = 'active'
		       ) AS i_am_enrolled
		  FROM enrollments e
		  JOIN products p ON p.id = e.product_id
		  JOIN studios  st ON st.id = e.studio_id
		 WHERE e.studio_id = ?
		 ORDER BY starts_at ASC NULLS LAST`
	// SQLite doesn't support "NULLS LAST" — workaround.
	rows, err := s.db.QueryContext(ctx, `
		SELECT e.id, e.title, COALESCE(e.description,''), e.session_count, e.capacity,
		       p.price_minor, st.currency,
		       (SELECT COUNT(*) FROM enrollment_bookings eb
		           WHERE eb.enrollment_id = e.id AND eb.status = 'active') AS enrolled,
		       (SELECT MIN(c.starts_at) FROM classes c WHERE c.enrollment_id = e.id) AS starts_at,
		       (SELECT MAX(c.ends_at)   FROM classes c WHERE c.enrollment_id = e.id) AS ends_at,
		       (SELECT i.full_name FROM classes c JOIN users i ON i.id = c.instructor_id
		          WHERE c.enrollment_id = e.id ORDER BY c.starts_at LIMIT 1) AS instructor_name,
		       EXISTS (
		         SELECT 1 FROM enrollment_bookings eb
		          WHERE eb.enrollment_id = e.id
		            AND eb.user_id = ? AND eb.status = 'active'
		       ) AS i_am_enrolled
		  FROM enrollments e
		  JOIN products p ON p.id = e.product_id
		  JOIN studios  st ON st.id = e.studio_id
		 WHERE e.studio_id = ?
		 ORDER BY CASE WHEN (SELECT MIN(c.starts_at) FROM classes c WHERE c.enrollment_id = e.id) IS NULL THEN 1 ELSE 0 END,
		          (SELECT MIN(c.starts_at) FROM classes c WHERE c.enrollment_id = e.id) ASC`,
		userID, studioID,
	)
	_ = q
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []EnrollmentSummary{}
	for rows.Next() {
		var (
			r                EnrollmentSummary
			instructor       sql.NullString
			startsAt, endsAt sql.NullString
			iEnrolled        int
		)
		if err := rows.Scan(
			&r.ID, &r.Title, &r.Description, &r.SessionCount, &r.Capacity,
			&r.PriceMinor, &r.Currency, &r.EnrolledCount,
			&startsAt, &endsAt, &instructor, &iEnrolled,
		); err != nil {
			return nil, err
		}
		if startsAt.Valid {
			r.StartsAt = startsAt.String
		}
		if endsAt.Valid {
			r.EndsAt = endsAt.String
		}
		if instructor.Valid {
			r.InstructorName = instructor.String
		}
		if iEnrolled != 0 {
			r.SeriesState = "enrolled"
		} else if r.EnrolledCount >= r.Capacity {
			r.SeriesState = "full"
		} else {
			r.SeriesState = "open"
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// EnrollmentDetail is GET /enrollments/{id} (summary + sessions).
type EnrollmentDetail struct {
	EnrollmentSummary
	Sessions []EnrollmentSession `json:"sessions"`
}

type EnrollmentSession struct {
	ID       string `json:"id"`
	WeekIdx  int    `json:"week_idx"`
	StartsAt string `json:"starts_at"`
	EndsAt   string `json:"ends_at"`
	RoomName string `json:"room_name"`
}

func (s *Store) GetEnrollmentDetail(ctx context.Context, studioID, userID, enrollmentID string) (*EnrollmentDetail, error) {
	rows, err := s.ListEnrollments(ctx, studioID, userID)
	if err != nil {
		return nil, err
	}
	var summary *EnrollmentSummary
	for i := range rows {
		if rows[i].ID == enrollmentID {
			summary = &rows[i]
			break
		}
	}
	if summary == nil {
		return nil, ErrNotFound
	}
	det := &EnrollmentDetail{EnrollmentSummary: *summary, Sessions: []EnrollmentSession{}}
	sRows, err := s.db.QueryContext(ctx, `
		SELECT c.id, c.starts_at, c.ends_at, r.name
		  FROM classes c
		  JOIN rooms r ON r.id = c.room_id
		 WHERE c.enrollment_id = ?
		 ORDER BY c.starts_at ASC`,
		enrollmentID,
	)
	if err != nil {
		return nil, err
	}
	defer sRows.Close()
	idx := 1
	for sRows.Next() {
		var sess EnrollmentSession
		sess.WeekIdx = idx
		idx++
		if err := sRows.Scan(&sess.ID, &sess.StartsAt, &sess.EndsAt, &sess.RoomName); err != nil {
			return nil, err
		}
		det.Sessions = append(det.Sessions, sess)
	}
	return det, sRows.Err()
}

// JoinEnrollment atomically: creates an entitlement + a purchase, an
// enrollment_bookings row, and a booking for each future session.
// Returns the created enrollment_bookings ID.
//
// discountCode is optional; pass "" for no discount. When set, the code is
// validated inside the tx and recorded on the purchase row alongside the
// list price. Returns *BookingError for discount-related failures so the
// API layer can surface a structured 409.
func (s *Store) JoinEnrollment(ctx context.Context, studioID, userID, enrollmentID, paymentMethod, discountCode string) (string, error) {
	switch paymentMethod {
	case "cash", "card", "card_present", "transfer", "comp", "dev_stub":
	default:
		paymentMethod = "dev_stub"
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	// Idempotency: refuse if already enrolled.
	var already int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM enrollment_bookings
		 WHERE enrollment_id = ? AND user_id = ? AND status = 'active'`,
		enrollmentID, userID,
	).Scan(&already); err != nil {
		return "", err
	}
	if already > 0 {
		return "", fmt.Errorf("already enrolled in this series")
	}

	// Capacity check.
	var capacity, currentlyEnrolled int
	err = tx.QueryRowContext(ctx, `
		SELECT e.capacity,
		       (SELECT COUNT(*) FROM enrollment_bookings eb
		         WHERE eb.enrollment_id = e.id AND eb.status = 'active')
		  FROM enrollments e
		 WHERE e.id = ? AND e.studio_id = ?`,
		enrollmentID, studioID,
	).Scan(&capacity, &currentlyEnrolled)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if currentlyEnrolled >= capacity {
		return "", fmt.Errorf("enrollment is full")
	}

	// Product + currency for the purchase row. Also grab the enrollment
	// title for the audit row — without it the activity log would just
	// show an opaque enrollment_id.
	var productID, enrollmentTitle string
	var priceMinor int
	var currency string
	err = tx.QueryRowContext(ctx, `
		SELECT p.id, p.price_minor, st.currency, e.title
		  FROM enrollments e
		  JOIN products p ON p.id = e.product_id
		  JOIN studios st ON st.id = e.studio_id
		 WHERE e.id = ?`,
		enrollmentID,
	).Scan(&productID, &priceMinor, &currency, &enrollmentTitle)
	if err != nil {
		return "", err
	}

	// Sessions to book (future only).
	sRows, err := tx.QueryContext(ctx, `
		SELECT c.id, c.starts_at
		  FROM classes c
		 WHERE c.enrollment_id = ? AND c.status = 'scheduled'
		   AND c.starts_at >= strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY c.starts_at ASC`,
		enrollmentID,
	)
	if err != nil {
		return "", err
	}
	type sessRow struct{ id, startsAt string }
	var sessions []sessRow
	for sRows.Next() {
		var s sessRow
		if err := sRows.Scan(&s.id, &s.startsAt); err != nil {
			sRows.Close()
			return "", err
		}
		sessions = append(sessions, s)
	}
	sRows.Close()
	if len(sessions) == 0 {
		return "", fmt.Errorf("no future sessions in this series")
	}

	// Expiry: end of the last session.
	lastStart, _ := time.Parse(time.RFC3339, sessions[len(sessions)-1].startsAt)
	expiresAt := lastStart.Add(24 * time.Hour).Format(time.RFC3339)

	// Snapshot eligible class types for the entitlement = the series' own
	// dedicated class type. We pick it from one of the sessions.
	var classTypeID string
	if err := tx.QueryRowContext(ctx,
		`SELECT class_type_id FROM classes WHERE id = ?`, sessions[0].id,
	).Scan(&classTypeID); err != nil {
		return "", err
	}

	purchaseID := NewID()
	entitlementID := NewID()
	enrollBookingID := NewID()

	// Entitlement — unlimited within the series' validity window.
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO entitlements
		    (id, studio_id, user_id, source_product_id, pass_kind, label,
		     credits_total, credits_remaining, expires_at, status)
		    VALUES (?, ?, ?, ?, 'unlimited', ?, NULL, NULL, ?, 'active')`,
		entitlementID, studioID, userID, productID,
		"Beginners' Course (6 weeks)", expiresAt,
	); err != nil {
		return "", err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO entitlement_class_types (entitlement_id, class_type_id)
		    VALUES (?, ?)`,
		entitlementID, classTypeID,
	); err != nil {
		return "", err
	}

	// Discount (optional). Validates inside the tx so the usage counts
	// stay consistent with the purchase insert.
	discountID, discountMinor, err := validateAndApplyDiscountTx(
		ctx, tx, studioID, userID, productID, discountCode, priceMinor,
	)
	if err != nil {
		return "", err
	}
	amountMinor := priceMinor - discountMinor
	var discountIDPtr any
	if discountID != "" {
		discountIDPtr = discountID
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO purchases
		    (id, studio_id, user_id, product_id, list_price_minor, amount_minor, currency,
		     discount_minor, discount_id,
		     payment_method, initiated_by, actor_role, status,
		     resulting_entitlement_id)
		    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'student', 'completed', ?)`,
		purchaseID, studioID, userID, productID, priceMinor, amountMinor, currency,
		discountMinor, discountIDPtr,
		paymentMethod, userID, entitlementID,
	); err != nil {
		return "", err
	}

	// Enrollment booking + per-session bookings.
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO enrollment_bookings
		    (id, enrollment_id, user_id, entitlement_id, status)
		    VALUES (?, ?, ?, ?, 'active')`,
		enrollBookingID, enrollmentID, userID, entitlementID,
	); err != nil {
		return "", err
	}
	for _, sess := range sessions {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO bookings
			    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
			     booked_by_role, cancel_cutoff_hours, status)
			    VALUES (?, ?, ?, ?, ?, 0, 'student', 0, 'booked')`,
			NewID(), studioID, sess.id, userID, entitlementID,
		); err != nil {
			return "", err
		}
	}
	// Audit the student joining a series so the activity log captures
	// it alongside one-off booking_create rows. Records what they paid
	// and which series so support can match "did I sign up for the
	// 6-week course?" to a real event.
	auditDetail := map[string]any{
		"enrollment_id":    enrollmentID,
		"enrollment_title": enrollmentTitle,
		"sessions":         len(sessions),
		"amount_minor":     amountMinor,
		"currency":         currency,
		"payment_method":   paymentMethod,
	}
	if discountMinor > 0 {
		auditDetail["discount_minor"] = discountMinor
	}
	if discountCode != "" {
		auditDetail["discount_code"] = discountCode
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"series_join", "enrollment", enrollmentID, auditDetail); err != nil {
		return "", fmt.Errorf("audit series_join: %w", err)
	}
	return enrollBookingID, tx.Commit()
}
