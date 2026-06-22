package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// AdminClassInput is the body for POST/PATCH /admin/classes.
type AdminClassInput struct {
	ClassTypeID  *string `json:"class_type_id,omitempty"`
	InstructorID *string `json:"instructor_id,omitempty"`
	RoomID       *string `json:"room_id,omitempty"`
	Title        *string `json:"title,omitempty"`
	StartsAt     *string `json:"starts_at,omitempty"` // ISO 8601 UTC
	DurationMins *int    `json:"duration_minutes,omitempty"`
	Capacity     *int    `json:"capacity,omitempty"`
}

// CreateAdminClass with audit. Pass actorID so the audit row records who created.
func (s *Store) CreateAdminClassWithAudit(ctx context.Context, studioID, actorID string, in AdminClassInput) (string, error) {
	id, err := s.CreateAdminClass(ctx, studioID, in)
	if err != nil {
		return "", err
	}
	// Hydrate the human labels for the audit row so the activity log
	// can render "NEW CLASS · Vinyasa Flow · Priya · Studio A" without
	// the reader having to follow opaque IDs back to their tables.
	var instructorName, roomName string
	if in.InstructorID != nil && *in.InstructorID != "" {
		_ = s.db.QueryRowContext(ctx,
			`SELECT full_name FROM users WHERE id = ?`, *in.InstructorID,
		).Scan(&instructorName)
	}
	if in.RoomID != nil && *in.RoomID != "" {
		_ = s.db.QueryRowContext(ctx,
			`SELECT name FROM rooms WHERE id = ?`, *in.RoomID,
		).Scan(&roomName)
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "class_create", "class", id, map[string]any{
		"title":            valOr(in.Title, ""),
		"starts_at":        valOr(in.StartsAt, ""),
		"duration_minutes": valOr(in.DurationMins, 0),
		"capacity":         valOr(in.Capacity, 0),
		"instructor_id":    valOr(in.InstructorID, ""),
		"instructor_name":  instructorName,
		"room_id":          valOr(in.RoomID, ""),
		"room_name":        roomName,
	})
	return id, nil
}

// CancelAdminClassWithAudit wraps CancelAdminClass with an audit row.
// The audit detail includes a compact list of affected_users so the
// manager's Activity-log view can render "released N bookings — Maya,
// Aria, Ben + 3 more" without having to re-query the roster.
func (s *Store) CancelAdminClassWithAudit(ctx context.Context, studioID, actorID, classID string) (*CancelClassResult, error) {
	out, err := s.CancelAdminClass(ctx, studioID, classID)
	if err != nil {
		return nil, err
	}
	users := make([]map[string]any, 0, len(out.AffectedUsers))
	for _, u := range out.AffectedUsers {
		row := map[string]any{
			"id":        u.ID,
			"name":      u.Name,
			"seats":     u.Seats,
			"pass_kind": u.PassKind,
		}
		if u.PlusOneName != "" {
			row["plus_one_name"] = u.PlusOneName
		}
		users = append(users, row)
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "class_cancel", "class", classID, map[string]any{
		"class_title":        out.Title,
		"bookings_cancelled": out.BookingsCancelled,
		"credits_returned":   out.CreditsReturned,
		"notifications_sent": out.NotificationsSent,
		"waitlist_cleared":   out.WaitlistCleared,
		"affected_users":     users,
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
	if in.Title == nil || strings.TrimSpace(*in.Title) == "" {
		missing = append(missing, "title")
	}
	if len(missing) > 0 {
		return "", fmt.Errorf("missing required fields: %v", missing)
	}
	start, err := time.Parse(time.RFC3339, *in.StartsAt)
	if err != nil {
		return "", fmt.Errorf("starts_at must be RFC3339: %w", err)
	}
	end := start.Add(time.Duration(*in.DurationMins) * time.Minute)
	title := strings.TrimSpace(*in.Title)
	id := NewID()
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
	BookingsCancelled int                  `json:"bookings_cancelled"`
	CreditsReturned   int                  `json:"credits_returned"`
	NotificationsSent int                  `json:"notifications_sent"`
	WaitlistCleared   int                  `json:"waitlist_cleared"`
	AffectedUsers     []AffectedUserBrief  `json:"affected_users,omitempty"`
	// Title is the cancelled class's title, snapshotted at cancel time
	// so the audit/activity log can render "CANCELLED · Vinyasa Flow"
	// without re-querying after the row's status flipped.
	Title string `json:"title,omitempty"`
}

// AffectedUserBrief describes one person who lost a seat in a class-cancel,
// aggregated across parent + plus-one rows so the Activity log can render
// "Ben · 2 credits returned (with friend)" instead of two separate "Ben"
// chips. Seats is 1 for a solo booking and 2 when a +1 was attached;
// PassKind is "credit" or "unlimited" so the UI can decide whether to
// say "credit returned" vs "unlimited pass". PlusOneName is filled when
// the booking included a friend.
type AffectedUserBrief struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Seats       int    `json:"seats"`
	PassKind    string `json:"pass_kind"`
	PlusOneName string `json:"plus_one_name,omitempty"`
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

	// Pull live bookings + their credit entitlements. is_plus_one /
	// plus_one_name come along so we can aggregate parent+friend into a
	// single affected-user entry below (seats=2, with friend's name).
	type bookingRow struct {
		ID, UserID, UserName, EntitlementID, PassKind string
		IsPlusOne                                     bool
		PlusOneName                                   sql.NullString
	}
	var bookings []bookingRow
	brows, err := tx.QueryContext(ctx, `
		SELECT b.id, b.user_id, u.full_name, b.entitlement_id, e.pass_kind,
		       b.is_plus_one, b.plus_one_name
		  FROM bookings b
		  JOIN entitlements e ON e.id = b.entitlement_id
		  JOIN users u        ON u.id = b.user_id
		 WHERE b.class_id = ? AND b.status = 'booked'`,
		classID,
	)
	if err != nil {
		return nil, err
	}
	for brows.Next() {
		var (
			b      bookingRow
			plusOn int
		)
		if err := brows.Scan(&b.ID, &b.UserID, &b.UserName, &b.EntitlementID, &b.PassKind,
			&plusOn, &b.PlusOneName); err != nil {
			brows.Close()
			return nil, err
		}
		b.IsPlusOne = plusOn != 0
		bookings = append(bookings, b)
	}
	brows.Close()

	out := &CancelClassResult{}
	if title.Valid {
		out.Title = title.String
	}

	// Collected post-commit pushes — populated as we walk bookings, fired
	// after tx.Commit so a rolled-back cancel doesn't produce phantom pings.
	var pushes []pendingPush

	// Cancel bookings + return credits + notify each. Outcome is always
	// class_cancelled_returned: it was the studio's call, never the student's
	// fault, so credits go back regardless of when the cancel happened.
	for _, b := range bookings {
		if _, err := tx.ExecContext(ctx, `
			UPDATE bookings
			   SET status       = 'cancelled',
			       outcome      = 'class_cancelled_returned',
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
		// Notify the student — unless they've opted out of class_cancelled.
		// (A no-op opt-out for credit-pass holders still leaves the
		// refunded credit in place; this only suppresses the feed entry.)
		ok, err := userOptedInTx(ctx, tx, b.UserID, "class_cancelled")
		if err != nil {
			return nil, err
		}
		if ok {
			body := "Class cancelled by the studio · your credit has been returned."
			if b.PassKind != "credit" {
				body = "Class cancelled by the studio. We'll see you next time."
			}
			nTitle := "Class cancelled"
			if title.Valid && title.String != "" {
				nTitle = title.String + " — class cancelled"
			}
			payloadJSON := fmt.Sprintf(`{"class_id":"%s","booking_id":"%s"}`, classID, b.ID)
			if _, err := tx.ExecContext(ctx, `
				INSERT INTO notifications (id, studio_id, user_id, type, title, body, payload)
				   VALUES (?, ?, ?, 'class_cancelled', ?, ?, ?)`,
				NewID(), studioID, b.UserID, nTitle, body, payloadJSON,
			); err != nil {
				return nil, err
			}
			out.NotificationsSent++
			pushes = append(pushes, pendingPush{
				userID:      b.UserID,
				notifType:   "class_cancelled",
				title:       nTitle,
				body:        body,
				payloadJSON: payloadJSON,
			})
		}
	}
	out.BookingsCancelled = len(bookings)
	// Aggregate by user so parent + +1 collapse into one entry with
	// seats=2. Preserve the queue order — walk bookings in turn and
	// append a fresh brief the first time we meet each user. The +1
	// row's plus_one_name is empty (the name lives on the parent), so
	// we copy it onto the parent's brief.
	briefByUser := map[string]int{} // userID → index in out.AffectedUsers
	for _, b := range bookings {
		if idx, ok := briefByUser[b.UserID]; ok {
			out.AffectedUsers[idx].Seats++
			if !b.IsPlusOne && b.PlusOneName.Valid {
				out.AffectedUsers[idx].PlusOneName = b.PlusOneName.String
			}
			continue
		}
		brief := AffectedUserBrief{
			ID:       b.UserID,
			Name:     b.UserName,
			Seats:    1,
			PassKind: b.PassKind,
		}
		if !b.IsPlusOne && b.PlusOneName.Valid {
			brief.PlusOneName = b.PlusOneName.String
		}
		briefByUser[b.UserID] = len(out.AffectedUsers)
		out.AffectedUsers = append(out.AffectedUsers, brief)
	}

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

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	for _, p := range pushes {
		s.dispatchPush(p.userID, p.notifType, p.title, p.body, p.payloadJSON)
	}
	return out, nil
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
	// Optional `#rrggbb` accent the UI tints class cards with. Omitted
	// from the response when unset so the client can default to the
	// theme's neutral border without a special-case "no color" string.
	Color *string `json:"color,omitempty"`
}

func (s *Store) ListAdminRooms(ctx context.Context, studioID string) ([]AdminRoom, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, name, color FROM rooms WHERE studio_id = ? ORDER BY name ASC`,
		studioID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AdminRoom{}
	for rows.Next() {
		var (
			r     AdminRoom
			color sql.NullString
		)
		if err := rows.Scan(&r.ID, &r.Name, &color); err != nil {
			return nil, err
		}
		if color.Valid && color.String != "" {
			c := color.String
			r.Color = &c
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
