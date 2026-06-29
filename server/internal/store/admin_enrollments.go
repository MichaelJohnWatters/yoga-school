package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// AdminEnrollmentSummary adds revenue + attendance stats on top of the
// student-facing summary.
type AdminEnrollmentSummary struct {
	EnrollmentSummary
	RevenueMinor     int `json:"revenue_minor"`
	AttendancePct    int `json:"attendance_pct"` // marked-present ÷ all marked
	UpcomingSessions int `json:"upcoming_sessions"`
}

func (s *Store) ListAdminEnrollments(ctx context.Context, studioID string) ([]AdminEnrollmentSummary, error) {
	rows, err := s.ListEnrollments(ctx, studioID, "", true)
	if err != nil {
		return nil, err
	}
	out := make([]AdminEnrollmentSummary, 0, len(rows))
	for _, r := range rows {
		ae := AdminEnrollmentSummary{EnrollmentSummary: r}
		// Revenue: sum of completed purchases that landed an active or
		// voided entitlement linked to this series.
		if err := s.db.QueryRowContext(ctx, `
			SELECT COALESCE(SUM(p.amount_minor), 0)
			  FROM purchases p
			  JOIN enrollment_bookings eb ON eb.entitlement_id = p.resulting_entitlement_id
			 WHERE eb.enrollment_id = ?
			   AND p.status = 'completed'`,
			r.ID,
		).Scan(&ae.RevenueMinor); err != nil && err != sql.ErrNoRows {
			return nil, err
		}
		// Attendance %.
		var present, marked int
		if err := s.db.QueryRowContext(ctx, `
			SELECT
			  (SELECT COUNT(*) FROM bookings b
			     JOIN classes c ON c.id = b.class_id
			    WHERE c.enrollment_id = ? AND b.status = 'attended'),
			  (SELECT COUNT(*) FROM bookings b
			     JOIN classes c ON c.id = b.class_id
			    WHERE c.enrollment_id = ? AND b.status IN ('attended','no_show'))`,
			r.ID, r.ID,
		).Scan(&present, &marked); err != nil {
			return nil, err
		}
		if marked > 0 {
			ae.AttendancePct = present * 100 / marked
		}
		// Upcoming sessions.
		if err := s.db.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM classes
			 WHERE enrollment_id = ? AND status = 'scheduled'
			   AND starts_at >= strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
			r.ID,
		).Scan(&ae.UpcomingSessions); err != nil {
			return nil, err
		}
		out = append(out, ae)
	}
	return out, nil
}

// SeriesRoster is the attendance-grid payload.
type SeriesRoster struct {
	Series      EnrollmentSummary     `json:"series"`
	Sessions    []EnrollmentSession   `json:"sessions"`
	CurrentWeek int                   `json:"current_week_idx"`
	Students    []SeriesRosterStudent `json:"students"`
}

type SeriesRosterStudent struct {
	UserID   string   `json:"user_id"`
	FullName string   `json:"full_name"`
	Cells    []string `json:"cells"` // one per session: present | no_show | upcoming | absent
}

func (s *Store) SeriesRosterFor(ctx context.Context, studioID, enrollmentID string) (*SeriesRoster, error) {
	det, err := s.GetEnrollmentDetail(ctx, studioID, "", enrollmentID)
	if err != nil {
		return nil, err
	}
	out := &SeriesRoster{
		Series:   det.EnrollmentSummary,
		Sessions: det.Sessions,
		Students: []SeriesRosterStudent{},
	}

	// Determine the current week index — the next future session counts as
	// "now"; before that, the last past session.
	now := time.Now().UTC()
	out.CurrentWeek = 0
	for i, sess := range det.Sessions {
		t, _ := time.Parse(time.RFC3339, sess.StartsAt)
		if t.After(now) {
			out.CurrentWeek = i + 1 // 1-based week index
			break
		}
		out.CurrentWeek = i + 1
	}

	// Pull students enrolled in this series.
	srows, err := s.db.QueryContext(ctx, `
		SELECT u.id, u.full_name
		  FROM enrollment_bookings eb
		  JOIN users u ON u.id = eb.user_id
		 WHERE eb.enrollment_id = ? AND eb.status = 'active'
		 ORDER BY u.full_name ASC`,
		enrollmentID,
	)
	if err != nil {
		return nil, err
	}
	defer srows.Close()
	type stuKey struct {
		id, name string
	}
	students := []stuKey{}
	for srows.Next() {
		var k stuKey
		if err := srows.Scan(&k.id, &k.name); err != nil {
			return nil, err
		}
		students = append(students, k)
	}
	if err := srows.Err(); err != nil {
		return nil, err
	}

	// Per student × session attendance lookup.
	for _, stu := range students {
		row := SeriesRosterStudent{
			UserID:   stu.id,
			FullName: stu.name,
			Cells:    make([]string, len(det.Sessions)),
		}
		for i, sess := range det.Sessions {
			var status string
			err := s.db.QueryRowContext(ctx, `
				SELECT status FROM bookings
				 WHERE class_id = ? AND user_id = ?`,
				sess.ID, stu.id,
			).Scan(&status)
			if err == sql.ErrNoRows {
				row.Cells[i] = "absent"
				continue
			}
			if err != nil {
				return nil, err
			}
			startT, _ := time.Parse(time.RFC3339, sess.StartsAt)
			switch {
			case status == "attended":
				row.Cells[i] = "present"
			case status == "no_show":
				row.Cells[i] = "no_show"
			case status == "booked" && startT.After(now):
				row.Cells[i] = "upcoming"
			case status == "booked":
				row.Cells[i] = "unmarked"
			case status == "cancelled":
				row.Cells[i] = "absent"
			default:
				row.Cells[i] = "absent"
			}
		}
		out.Students = append(out.Students, row)
	}
	return out, nil
}

// AdminEnrollmentInput is the body for PATCH /admin/enrollments/{id}.
type AdminEnrollmentInput struct {
	Title       *string `json:"title,omitempty"`
	Description *string `json:"description,omitempty"`
	Capacity    *int    `json:"capacity,omitempty"`
}

// NewSeriesInput is the body for POST /admin/enrollments. Captures the
// full atomic creation (class type + product + enrollment + N classes).
type NewSeriesInput struct {
	Title        string `json:"title"`
	Description  string `json:"description"`
	PriceMinor   int    `json:"price_minor"`
	InstructorID string `json:"instructor_id"`
	RoomID       string `json:"room_id"`
	Weekday      int    `json:"weekday"` // 0=Mon, ..., 6=Sun
	StartHour    int    `json:"start_hour"`
	StartMinute  int    `json:"start_minute"`
	DurationMins int    `json:"duration_mins"`
	Capacity     int    `json:"capacity"`
	SessionCount int    `json:"session_count"`
	StartsOn     string `json:"starts_on"` // YYYY-MM-DD
}

type NewSeriesResult struct {
	EnrollmentID string   `json:"enrollment_id"`
	ProductID    string   `json:"product_id"`
	ClassTypeID  string   `json:"class_type_id"`
	ClassIDs     []string `json:"class_ids"`
}

// CreateSeries does the whole atomic dance in one tx.
func (s *Store) CreateSeries(ctx context.Context, studioID, actorID string, in NewSeriesInput) (*NewSeriesResult, error) {
	if in.Title == "" {
		return nil, fmt.Errorf("title required")
	}
	if in.InstructorID == "" || in.RoomID == "" {
		return nil, fmt.Errorf("instructor + room required")
	}
	if in.SessionCount <= 0 || in.SessionCount > 52 {
		return nil, fmt.Errorf("session_count must be 1..52")
	}
	if in.PriceMinor < 0 {
		return nil, fmt.Errorf("price_minor must be non-negative")
	}
	if in.DurationMins <= 0 {
		return nil, fmt.Errorf("duration_mins must be > 0")
	}
	if in.Capacity <= 0 {
		return nil, fmt.Errorf("capacity must be > 0")
	}
	startsOn, err := time.Parse("2006-01-02", in.StartsOn)
	if err != nil {
		return nil, fmt.Errorf("starts_on must be YYYY-MM-DD")
	}
	currentWeekday := (int(startsOn.Weekday()) + 6) % 7 // Mon=0
	delta := (in.Weekday - currentWeekday + 7) % 7
	firstSession := startsOn.AddDate(0, 0, delta).
		Add(time.Duration(in.StartHour)*time.Hour + time.Duration(in.StartMinute)*time.Minute)

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	classTypeID := NewID()
	productID := NewID()
	enrollmentID := NewID()

	// Dedicated class type so the entitlement is naturally scoped.
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO class_types (id, studio_id, name, discipline)
		    VALUES (?, ?, ?, 'yoga')`,
		classTypeID, studioID, in.Title,
	); err != nil {
		return nil, fmt.Errorf("insert class_type: %w", err)
	}

	// Product for the series purchase.
	desc := in.Description
	if desc == "" {
		desc = fmt.Sprintf("%d sessions · sold as a course, not a single drop-in.", in.SessionCount)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO products
		    (id, studio_id, name, description, price_minor, billing_type, pass_kind,
		     credits, validity_days, is_hero, display_order, is_archived)
		    VALUES (?, ?, ?, ?, ?, 'one_time', 'unlimited', NULL, 90, 0, 99, 0)`,
		productID, studioID, in.Title, desc, in.PriceMinor,
	); err != nil {
		return nil, fmt.Errorf("insert product: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`,
		productID, classTypeID,
	); err != nil {
		return nil, fmt.Errorf("link product class type: %w", err)
	}

	// Enrollment.
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO enrollments
		    (id, studio_id, title, description, product_id, session_count, capacity)
		    VALUES (?, ?, ?, ?, ?, ?, ?)`,
		enrollmentID, studioID, in.Title, in.Description, productID, in.SessionCount, in.Capacity,
	); err != nil {
		return nil, fmt.Errorf("insert enrollment: %w", err)
	}

	// Sessions = classes linked back to the enrollment.
	classIDs := make([]string, 0, in.SessionCount)
	for w := 0; w < in.SessionCount; w++ {
		start := firstSession.AddDate(0, 0, w*7).UTC()
		end := start.Add(time.Duration(in.DurationMins) * time.Minute)
		classID := NewID()
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO classes
			    (id, studio_id, class_type_id, instructor_id, room_id,
			     enrollment_id, title, starts_at, ends_at, capacity)
			    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			classID, studioID, classTypeID, in.InstructorID, in.RoomID,
			enrollmentID, fmt.Sprintf("%s · wk %d/%d", in.Title, w+1, in.SessionCount),
			start.Format(time.RFC3339), end.Format(time.RFC3339), in.Capacity,
		); err != nil {
			return nil, fmt.Errorf("insert class %d: %w", w+1, err)
		}
		classIDs = append(classIDs, classID)
	}

	if err := s.writeAuditTx(ctx, tx, studioID, actorID, "series_create", "enrollment", enrollmentID, map[string]any{
		"title":         in.Title,
		"sessions":      in.SessionCount,
		"price_minor":   in.PriceMinor,
		"product_id":    productID,
		"class_type_id": classTypeID,
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &NewSeriesResult{
		EnrollmentID: enrollmentID,
		ProductID:    productID,
		ClassTypeID:  classTypeID,
		ClassIDs:     classIDs,
	}, nil
}

// UpdateAdminEnrollment partially updates a series row.
func (s *Store) UpdateAdminEnrollment(ctx context.Context, studioID, actorID, enrollmentID string, in AdminEnrollmentInput) error {
	set := []string{}
	args := []any{}
	detail := map[string]any{}
	if in.Title != nil {
		set = append(set, "title = ?")
		args = append(args, *in.Title)
		detail["title"] = *in.Title
	}
	if in.Description != nil {
		set = append(set, "description = ?")
		args = append(args, *in.Description)
		detail["description"] = *in.Description
	}
	if in.Capacity != nil {
		if *in.Capacity < 1 {
			return fmt.Errorf("capacity must be >= 1")
		}
		set = append(set, "capacity = ?")
		args = append(args, *in.Capacity)
		detail["capacity"] = *in.Capacity
	}
	if len(set) == 0 {
		return nil
	}
	args = append(args, enrollmentID, studioID)
	q := "UPDATE enrollments SET "
	for i, sq := range set {
		if i > 0 {
			q += ", "
		}
		q += sq
	}
	q += " WHERE id = ? AND studio_id = ?"
	res, err := s.db.ExecContext(ctx, q, args...)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	// Always include the current title on the audit row so the
	// activity log can identify the series even when the patch only
	// touched description/capacity. Cheap; the row is already loaded
	// into the page cache by the UPDATE above.
	var enrollmentTitle string
	_ = s.db.QueryRowContext(ctx,
		`SELECT title FROM enrollments WHERE id = ?`, enrollmentID,
	).Scan(&enrollmentTitle)
	detail["enrollment_title"] = enrollmentTitle
	_ = s.WriteAudit(ctx, studioID, actorID, "series_update", "enrollment", enrollmentID, detail)
	return nil
}

// ArchiveEnrollment retires a series — the manager's escape hatch for one
// created in error (price is otherwise locked). It's hidden from the student
// Enrollments tab so no new sign-ups land; students already enrolled keep their
// booked sessions, and the per-class schedule is untouched. One-way (mirrors the
// discounts/products archive). Idempotent: archiving an already-archived series
// is a no-op success; an unknown id is ErrNotFound.
func (s *Store) ArchiveEnrollment(ctx context.Context, studioID, actorID, enrollmentID string) error {
	res, err := s.db.ExecContext(ctx, `
		UPDATE enrollments
		   SET archived_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ? AND studio_id = ? AND archived_at IS NULL`,
		enrollmentID, studioID,
	)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		// Distinguish "already archived" (success) from "no such series".
		var exists int
		if err := s.db.QueryRowContext(ctx,
			`SELECT 1 FROM enrollments WHERE id = ? AND studio_id = ?`,
			enrollmentID, studioID,
		).Scan(&exists); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrNotFound
			}
			return err
		}
		return nil // already archived
	}
	var enrollmentTitle string
	_ = s.db.QueryRowContext(ctx,
		`SELECT title FROM enrollments WHERE id = ?`, enrollmentID,
	).Scan(&enrollmentTitle)
	_ = s.WriteAudit(ctx, studioID, actorID, "series_archive", "enrollment", enrollmentID,
		map[string]any{"enrollment_title": enrollmentTitle})
	return nil
}
