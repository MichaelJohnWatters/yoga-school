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
	// Set when a manager retired the series. Always null on the student feed
	// (archived series are filtered out there); surfaced only to the manager
	// console so it can show an "Archived" section.
	ArchivedAt *string `json:"archived_at,omitempty"`
}

// ListEnrollments returns the studio's series. The student feed passes
// includeArchived=false so retired series disappear from the Enrollments tab;
// the manager console passes true so it can show an "Archived" section.
//
// SQLite has no "NULLS LAST", so undated series (no scheduled classes yet) are
// pushed to the end with a CASE in the ORDER BY.
func (s *Store) ListEnrollments(ctx context.Context, studioID, userID string, includeArchived bool) ([]EnrollmentSummary, error) {
	where := `WHERE e.studio_id = ?`
	if !includeArchived {
		where += ` AND e.archived_at IS NULL`
	}
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
		       ) AS i_am_enrolled,
		       e.archived_at
		  FROM enrollments e
		  JOIN products p ON p.id = e.product_id
		  JOIN studios  st ON st.id = e.studio_id
		 `+where+`
		 ORDER BY CASE WHEN (SELECT MIN(c.starts_at) FROM classes c WHERE c.enrollment_id = e.id) IS NULL THEN 1 ELSE 0 END,
		          (SELECT MIN(c.starts_at) FROM classes c WHERE c.enrollment_id = e.id) ASC`,
		userID, studioID,
	)
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
			archivedAt       sql.NullString
			iEnrolled        int
		)
		if err := rows.Scan(
			&r.ID, &r.Title, &r.Description, &r.SessionCount, &r.Capacity,
			&r.PriceMinor, &r.Currency, &r.EnrolledCount,
			&startsAt, &endsAt, &instructor, &iEnrolled, &archivedAt,
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
		if archivedAt.Valid {
			v := archivedAt.String
			r.ArchivedAt = &v
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
	rows, err := s.ListEnrollments(ctx, studioID, userID, false)
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

// JoinEnrollment is the student-initiated sync enrol (dev_stub / comp paths);
// real student purchases go through Stripe. See enrollStudentSync.
func (s *Store) JoinEnrollment(ctx context.Context, studioID, userID, enrollmentID, paymentMethod, discountCode string) (string, error) {
	return s.enrollStudentSync(ctx, studioID, userID, enrollmentID,
		paymentMethod, discountCode, userID, "student", "series_join")
}

// ManagerEnrollStudent signs a student into a series from the manager console
// (desk sign-ups: comp / cash / card / transfer). Same side-effects as a paid
// join — mints the series entitlement, books every session, records a completed
// purchase — but the purchase + audit attribute to the acting manager. Audited
// as series_manager_enroll.
func (s *Store) ManagerEnrollStudent(ctx context.Context, studioID, actorID, enrollmentID, studentID, paymentMethod, discountCode string) (string, error) {
	return s.enrollStudentSync(ctx, studioID, studentID, enrollmentID,
		paymentMethod, discountCode, actorID, "manager", "series_manager_enroll")
}

// enrollStudentSync atomically: creates an entitlement + a purchase, an
// enrollment_bookings row, and a booking for each future session.
// Returns the created enrollment_bookings ID.
//
// userID is the student being enrolled; actorID/actorRole/auditAction describe
// who initiated it (the student themselves, or a manager at the desk) so the
// purchase row + audit log attribute correctly.
//
// discountCode is optional; pass "" for no discount. When set, the code is
// validated inside the tx and recorded on the purchase row alongside the
// list price. Returns *BookingError for discount-related failures so the
// API layer can surface a structured 409.
func (s *Store) enrollStudentSync(ctx context.Context, studioID, userID, enrollmentID, paymentMethod, discountCode, actorID, actorRole, auditAction string) (string, error) {
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
		return "", ErrAlreadyEnrolled
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
		return "", ErrSeriesFull
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
		    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'completed', ?)`,
		purchaseID, studioID, userID, productID, priceMinor, amountMinor, currency,
		discountMinor, discountIDPtr,
		paymentMethod, actorID, actorRole, entitlementID,
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
	if actorRole != "student" {
		auditDetail["student_id"] = userID
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		auditAction, "enrollment", enrollmentID, auditDetail); err != nil {
		return "", fmt.Errorf("audit %s: %w", auditAction, err)
	}
	return enrollBookingID, tx.Commit()
}

// ErrSeriesFull is returned by enrollIntoSeriesTx when the series filled between
// checkout starting and the payment landing. The caller refunds the charge.
var ErrSeriesFull = errors.New("series is full")

// refundFullEnrollment refunds a paid series purchase that couldn't be fulfilled
// because the series filled before the payment landed (ErrSeriesFull), marks the
// purchase refunded, and notifies the student. Idempotent (a 'refunded' purchase
// is a no-op). lookupStripeID finds the purchase row (the cs_ session for the web
// path, whose swap rolled back, or the pi_ for the PaymentSheet path);
// refundIntentID is the PaymentIntent the refund targets.
func (s *Store) refundFullEnrollment(ctx context.Context, studioID, lookupStripeID, refundIntentID string) error {
	var purchaseID, userID, status string
	var amountMinor int
	err := s.db.QueryRowContext(ctx, `
		SELECT id, user_id, status, amount_minor FROM purchases
		 WHERE studio_id = ? AND stripe_payment_id = ?`,
		studioID, lookupStripeID,
	).Scan(&purchaseID, &userID, &status, &amountMinor)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if status == "refunded" {
		return nil
	}
	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		return fmt.Errorf("load stripe keys: %w", err)
	}
	if _, err := s.gateway.Refund(ctx, keys.SecretKey, refundIntentID, 0, "seriesfull:"+purchaseID); err != nil {
		return fmt.Errorf("refund full series: %w", err)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `
		UPDATE purchases
		   SET status = 'refunded', refund_amount_minor = ?,
		       refunded_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ? AND status != 'refunded'`,
		amountMinor, purchaseID,
	)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return tx.Commit() // someone else already refunded
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO notifications (id, studio_id, user_id, type, title, body, payload)
		   VALUES (?, ?, ?, 'system', ?, ?, '{}')`,
		NewID(), studioID, userID,
		"Course was full — you've been refunded",
		"The course filled up before your payment completed, so we've refunded you in full.",
	); err != nil {
		return err
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"series_full_refund", "purchase", purchaseID,
		map[string]any{"amount_minor": amountMinor}); err != nil {
		return err
	}
	return tx.Commit()
}

// ErrAlreadyEnrolled signals the student already holds an active spot.
var ErrAlreadyEnrolled = errors.New("already enrolled in this series")

// EnrollmentProductForCheckout validates that a student can start paying for a
// series and returns the series' product id (what to charge). Best-effort
// gate before checkout: ErrNotFound (no such series), ErrAlreadyEnrolled, or
// ErrSeriesFull (capacity is re-checked authoritatively at fulfilment).
func (s *Store) EnrollmentProductForCheckout(ctx context.Context, studioID, userID, enrollmentID string) (string, error) {
	var productID string
	var capacity, enrolled int
	err := s.db.QueryRowContext(ctx, `
		SELECT e.product_id, e.capacity,
		       (SELECT COUNT(*) FROM enrollment_bookings eb
		         WHERE eb.enrollment_id = e.id AND eb.status = 'active')
		  FROM enrollments e
		 WHERE e.id = ? AND e.studio_id = ?`,
		enrollmentID, studioID,
	).Scan(&productID, &capacity, &enrolled)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	var already int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM enrollment_bookings
		 WHERE enrollment_id = ? AND user_id = ? AND status = 'active'`,
		enrollmentID, userID,
	).Scan(&already); err != nil {
		return "", err
	}
	if already > 0 {
		return "", ErrAlreadyEnrolled
	}
	if enrolled >= capacity {
		return "", ErrSeriesFull
	}
	return productID, nil
}

// enrollIntoSeriesTx books an already-paid student into a series, completing the
// (pending) purchase identified by purchaseID. It re-checks capacity (async
// payment may have filled the series since checkout — returns ErrSeriesFull),
// mints the series entitlement (unlimited, scoped to the series class type,
// expiring after the last session), creates the enrollment_bookings row + a
// booking per future session, flips the purchase to 'completed', and audits
// series_join. Returns the new entitlement id.
//
// This is the Stripe-fulfilment counterpart to JoinEnrollment's inline sync
// path (which still serves the emulator-gated dev_stub/comp case).
func enrollIntoSeriesTx(ctx context.Context, s *Store, tx *sql.Tx, studioID, userID, enrollmentID, purchaseID string) (string, error) {
	var capacity, enrolled int
	var title string
	err := tx.QueryRowContext(ctx, `
		SELECT e.capacity, e.title,
		       (SELECT COUNT(*) FROM enrollment_bookings eb
		         WHERE eb.enrollment_id = e.id AND eb.status = 'active')
		  FROM enrollments e
		 WHERE e.id = ? AND e.studio_id = ?`,
		enrollmentID, studioID,
	).Scan(&capacity, &title, &enrolled)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if enrolled >= capacity {
		return "", ErrSeriesFull
	}

	rows, err := tx.QueryContext(ctx, `
		SELECT id, class_type_id, starts_at FROM classes
		 WHERE enrollment_id = ? AND status = 'scheduled'
		   AND starts_at >= strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY starts_at ASC`, enrollmentID)
	if err != nil {
		return "", err
	}
	type sess struct{ id, classType, startsAt string }
	var sessions []sess
	for rows.Next() {
		var x sess
		if err := rows.Scan(&x.id, &x.classType, &x.startsAt); err != nil {
			rows.Close()
			return "", err
		}
		sessions = append(sessions, x)
	}
	rows.Close()
	if len(sessions) == 0 {
		return "", fmt.Errorf("no future sessions in this series")
	}

	lastStart, _ := time.Parse(time.RFC3339, sessions[len(sessions)-1].startsAt)
	expiresAt := lastStart.Add(24 * time.Hour).Format(time.RFC3339)
	classTypeID := sessions[0].classType

	var productID string
	if err := tx.QueryRowContext(ctx,
		`SELECT product_id FROM purchases WHERE id = ?`, purchaseID,
	).Scan(&productID); err != nil {
		return "", err
	}

	entitlementID := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO entitlements
		    (id, studio_id, user_id, source_product_id, pass_kind, label,
		     credits_total, credits_remaining, expires_at, status)
		    VALUES (?, ?, ?, ?, 'unlimited', ?, NULL, NULL, ?, 'active')`,
		entitlementID, studioID, userID, productID, title, expiresAt,
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
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO enrollment_bookings
		    (id, enrollment_id, user_id, entitlement_id, status)
		    VALUES (?, ?, ?, ?, 'active')`,
		NewID(), enrollmentID, userID, entitlementID,
	); err != nil {
		return "", err
	}
	for _, x := range sessions {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO bookings
			    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
			     booked_by_role, cancel_cutoff_hours, status)
			    VALUES (?, ?, ?, ?, ?, 0, 'student', 0, 'booked')`,
			NewID(), studioID, x.id, userID, entitlementID,
		); err != nil {
			return "", err
		}
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE purchases SET status = 'completed', resulting_entitlement_id = ?
		 WHERE id = ?`,
		entitlementID, purchaseID,
	); err != nil {
		return "", err
	}

	var amountMinor int
	var currency, paymentMethod string
	_ = tx.QueryRowContext(ctx,
		`SELECT amount_minor, currency, payment_method FROM purchases WHERE id = ?`,
		purchaseID,
	).Scan(&amountMinor, &currency, &paymentMethod)
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"series_join", "enrollment", enrollmentID, map[string]any{
			"enrollment_id":    enrollmentID,
			"enrollment_title": title,
			"sessions":         len(sessions),
			"amount_minor":     amountMinor,
			"currency":         currency,
			"payment_method":   paymentMethod,
		}); err != nil {
		return "", fmt.Errorf("audit series_join: %w", err)
	}
	return entitlementID, nil
}
