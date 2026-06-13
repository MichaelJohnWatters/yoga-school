package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// AdminClassInput is the body for POST/PATCH /admin/classes.
type AdminClassInput struct {
	ClassTypeID  *string `json:"class_type_id,omitempty"`
	InstructorID *string `json:"instructor_id,omitempty"`
	RoomID       *string `json:"room_id,omitempty"`
	Title        *string `json:"title,omitempty"`
	StartsAt     *string `json:"starts_at,omitempty"`  // ISO 8601 UTC
	DurationMins *int    `json:"duration_minutes,omitempty"`
	Capacity     *int    `json:"capacity,omitempty"`
}

// CreateAdminClass with audit. Pass actorID so the audit row records who created.
func (s *Store) CreateAdminClassWithAudit(ctx context.Context, studioID, actorID string, in AdminClassInput) (string, error) {
	id, err := s.CreateAdminClass(ctx, studioID, in)
	if err != nil {
		return "", err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "class_create", "class", id, map[string]any{
		"title":            valOr(in.Title, ""),
		"starts_at":        valOr(in.StartsAt, ""),
		"duration_minutes": valOr(in.DurationMins, 0),
		"capacity":         valOr(in.Capacity, 0),
	})
	return id, nil
}

// CancelAdminClassWithAudit wraps CancelAdminClass with an audit row.
func (s *Store) CancelAdminClassWithAudit(ctx context.Context, studioID, actorID, classID string) (*CancelClassResult, error) {
	out, err := s.CancelAdminClass(ctx, studioID, classID)
	if err != nil {
		return nil, err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "class_cancel", "class", classID, map[string]any{
		"bookings_cancelled":  out.BookingsCancelled,
		"credits_returned":    out.CreditsReturned,
		"notifications_sent":  out.NotificationsSent,
		"waitlist_cleared":    out.WaitlistCleared,
	})
	return out, nil
}

// valOr is a generic null-default helper used only to keep audit detail tidy.
func valOr[T any](p *T, fallback T) T {
	if p == nil {
		return fallback
	}
	return *p
}

func (s *Store) CreateAdminClass(ctx context.Context, studioID string, in AdminClassInput) (string, error) {
	missing := []string{}
	if in.ClassTypeID == nil || *in.ClassTypeID == "" {
		missing = append(missing, "class_type_id")
	}
	if in.InstructorID == nil || *in.InstructorID == "" {
		missing = append(missing, "instructor_id")
	}
	if in.RoomID == nil || *in.RoomID == "" {
		missing = append(missing, "room_id")
	}
	if in.StartsAt == nil || *in.StartsAt == "" {
		missing = append(missing, "starts_at")
	}
	if in.DurationMins == nil || *in.DurationMins <= 0 {
		missing = append(missing, "duration_minutes")
	}
	if in.Capacity == nil || *in.Capacity <= 0 {
		missing = append(missing, "capacity")
	}
	if len(missing) > 0 {
		return "", fmt.Errorf("missing required fields: %v", missing)
	}
	start, err := time.Parse(time.RFC3339, *in.StartsAt)
	if err != nil {
		return "", fmt.Errorf("starts_at must be RFC3339: %w", err)
	}
	end := start.Add(time.Duration(*in.DurationMins) * time.Minute)
	title := ""
	if in.Title != nil {
		title = *in.Title
	}
	id := uuid.NewString()
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO classes
		    (id, studio_id, class_type_id, instructor_id, room_id, title,
		     starts_at, ends_at, capacity)
		    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, studioID, *in.ClassTypeID, *in.InstructorID, *in.RoomID, title,
		start.Format(time.RFC3339), end.Format(time.RFC3339), *in.Capacity,
	)
	if err != nil {
		return "", err
	}
	return id, nil
}

// CancelClassResult summarizes what the cancel did for the manager.
type CancelClassResult struct {
	BookingsCancelled   int  `json:"bookings_cancelled"`
	CreditsReturned     int  `json:"credits_returned"`
	NotificationsSent   int  `json:"notifications_sent"`
	WaitlistCleared     int  `json:"waitlist_cleared"`
}

func (s *Store) CancelAdminClass(ctx context.Context, studioID, classID string) (*CancelClassResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Verify the class exists.
	var status string
	var title sql.NullString
	err = tx.QueryRowContext(ctx,
		`SELECT status, title FROM classes WHERE id = ? AND studio_id = ?`,
		classID, studioID,
	).Scan(&status, &title)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if status == "cancelled" {
		return nil, fmt.Errorf("class already cancelled")
	}

	// Pull live bookings + their credit entitlements.
	type bookingRow struct {
		ID, UserID, EntitlementID, PassKind string
	}
	var bookings []bookingRow
	brows, err := tx.QueryContext(ctx, `
		SELECT b.id, b.user_id, b.entitlement_id, e.pass_kind
		  FROM bookings b
		  JOIN entitlements e ON e.id = b.entitlement_id
		 WHERE b.class_id = ? AND b.status = 'booked'`,
		classID,
	)
	if err != nil {
		return nil, err
	}
	for brows.Next() {
		var b bookingRow
		if err := brows.Scan(&b.ID, &b.UserID, &b.EntitlementID, &b.PassKind); err != nil {
			brows.Close()
			return nil, err
		}
		bookings = append(bookings, b)
	}
	brows.Close()

	out := &CancelClassResult{}

	// Cancel bookings + return credits + notify each.
	for _, b := range bookings {
		if _, err := tx.ExecContext(ctx, `
			UPDATE bookings
			   SET status       = 'cancelled',
			       cancelled_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
			 WHERE id = ?`,
			b.ID,
		); err != nil {
			return nil, err
		}
		if b.PassKind == "credit" {
			if _, err := tx.ExecContext(ctx,
				`UPDATE entitlements SET credits_remaining = credits_remaining + 1 WHERE id = ?`,
				b.EntitlementID,
			); err != nil {
				return nil, err
			}
			out.CreditsReturned++
		}
		// Notify the student.
		body := "Class cancelled by the studio · your credit has been returned."
		if b.PassKind != "credit" {
			body = "Class cancelled by the studio. We'll see you next time."
		}
		nTitle := "Class cancelled"
		if title.Valid && title.String != "" {
			nTitle = title.String + " — class cancelled"
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO notifications (id, studio_id, user_id, type, title, body, payload)
			   VALUES (?, ?, ?, 'class_cancelled', ?, ?, ?)`,
			uuid.NewString(), studioID, b.UserID, nTitle, body,
			fmt.Sprintf(`{"class_id":"%s","booking_id":"%s"}`, classID, b.ID),
		); err != nil {
			return nil, err
		}
		out.NotificationsSent++
	}
	out.BookingsCancelled = len(bookings)

	// Clear waitlist.
	res, err := tx.ExecContext(ctx,
		`DELETE FROM waitlist_entries WHERE class_id = ?`, classID,
	)
	if err != nil {
		return nil, err
	}
	n, _ := res.RowsAffected()
	out.WaitlistCleared = int(n)

	// Flip the class.
	if _, err := tx.ExecContext(ctx, `
		UPDATE classes SET status = 'cancelled' WHERE id = ?`, classID,
	); err != nil {
		return nil, err
	}

	return out, tx.Commit()
}

// UpdateAdminClass partially updates a class. Only re-derives ends_at when
// either starts_at or duration_minutes changes.
func (s *Store) UpdateAdminClass(ctx context.Context, studioID, classID string, in AdminClassInput) error {
	var (
		startStr string
		endStr   string
	)
	if err := s.db.QueryRowContext(ctx,
		`SELECT starts_at, ends_at FROM classes WHERE id = ? AND studio_id = ?`,
		classID, studioID,
	).Scan(&startStr, &endStr); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	start, _ := time.Parse(time.RFC3339, startStr)
	end, _ := time.Parse(time.RFC3339, endStr)
	if in.StartsAt != nil {
		t, err := time.Parse(time.RFC3339, *in.StartsAt)
		if err != nil {
			return fmt.Errorf("starts_at must be RFC3339")
		}
		start = t
	}
	if in.DurationMins != nil {
		end = start.Add(time.Duration(*in.DurationMins) * time.Minute)
	} else if in.StartsAt != nil {
		// preserve duration when only start changes
		prevStart, _ := time.Parse(time.RFC3339, startStr)
		prevEnd, _ := time.Parse(time.RFC3339, endStr)
		dur := prevEnd.Sub(prevStart)
		end = start.Add(dur)
	}

	set := []string{"starts_at = ?", "ends_at = ?"}
	args := []any{start.Format(time.RFC3339), end.Format(time.RFC3339)}
	if in.Title != nil {
		set = append(set, "title = ?")
		args = append(args, *in.Title)
	}
	if in.ClassTypeID != nil {
		set = append(set, "class_type_id = ?")
		args = append(args, *in.ClassTypeID)
	}
	if in.InstructorID != nil {
		set = append(set, "instructor_id = ?")
		args = append(args, *in.InstructorID)
	}
	if in.RoomID != nil {
		set = append(set, "room_id = ?")
		args = append(args, *in.RoomID)
	}
	if in.Capacity != nil {
		set = append(set, "capacity = ?")
		args = append(args, *in.Capacity)
	}
	args = append(args, classID, studioID)
	q := "UPDATE classes SET "
	for i, s := range set {
		if i > 0 {
			q += ", "
		}
		q += s
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
	return nil
}

// ListAdminInstructors + ListAdminRooms power the create-class form.
type AdminInstructor struct {
	ID       string `json:"id"`
	FullName string `json:"full_name"`
}

func (s *Store) ListAdminInstructors(ctx context.Context, studioID string) ([]AdminInstructor, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, full_name FROM users
		 WHERE studio_id = ? AND role = 'instructor'
		 ORDER BY full_name ASC`, studioID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AdminInstructor{}
	for rows.Next() {
		var i AdminInstructor
		if err := rows.Scan(&i.ID, &i.FullName); err != nil {
			return nil, err
		}
		out = append(out, i)
	}
	return out, rows.Err()
}

type AdminRoom struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (s *Store) ListAdminRooms(ctx context.Context, studioID string) ([]AdminRoom, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, name FROM rooms WHERE studio_id = ? ORDER BY name ASC`,
		studioID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AdminRoom{}
	for rows.Next() {
		var r AdminRoom
		if err := rows.Scan(&r.ID, &r.Name); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
