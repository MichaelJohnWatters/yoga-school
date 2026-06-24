package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// maxTemplateClasses caps weeks × slots so a runaway template can't fill the
// DB. Mirrors the recurrence expansion cap.
const maxTemplateClasses = 366

// TemplateSlotInput is one recurring slot within a template — a full class
// shape pinned to a weekday/time.
type TemplateSlotInput struct {
	ClassTypeID  string `json:"class_type_id"`
	InstructorID string `json:"instructor_id"`
	RoomID       string `json:"room_id"`
	Weekday      int    `json:"weekday"` // 0=Mon, ..., 6=Sun
	StartHour    int    `json:"start_hour"`
	StartMinute  int    `json:"start_minute"`
	DurationMins int    `json:"duration_mins"`
	Capacity     int    `json:"capacity"`
	Title        string `json:"title,omitempty"` // optional per-slot override
}

// ClassTemplateInput is the body for POST /admin/class-templates.
//
// The modern shape is { title, weeks, starts_on, slots:[…] }. The legacy
// single-slot fields (class_type_id, weekday, …) are still accepted when
// slots is empty: they're folded into one slot. This keeps the original flat
// API — and the audit-matrix tests that exercise it — working unchanged.
type ClassTemplateInput struct {
	Title    string              `json:"title"`
	Weeks    int                 `json:"weeks"`
	StartsOn string              `json:"starts_on"` // YYYY-MM-DD anchor for week 0
	Slots    []TemplateSlotInput `json:"slots"`

	// Deprecated flat fields — used only when Slots is empty.
	ClassTypeID  string `json:"class_type_id,omitempty"`
	InstructorID string `json:"instructor_id,omitempty"`
	RoomID       string `json:"room_id,omitempty"`
	Weekday      int    `json:"weekday,omitempty"`
	StartHour    int    `json:"start_hour,omitempty"`
	StartMinute  int    `json:"start_minute,omitempty"`
	DurationMins int    `json:"duration_mins,omitempty"`
	Capacity     int    `json:"capacity,omitempty"`
}

// slots returns the normalized slot list, folding the legacy flat fields into
// a single slot when no slots were supplied.
func (in ClassTemplateInput) slots() []TemplateSlotInput {
	if len(in.Slots) > 0 {
		return in.Slots
	}
	return []TemplateSlotInput{{
		ClassTypeID:  in.ClassTypeID,
		InstructorID: in.InstructorID,
		RoomID:       in.RoomID,
		Weekday:      in.Weekday,
		StartHour:    in.StartHour,
		StartMinute:  in.StartMinute,
		DurationMins: in.DurationMins,
		Capacity:     in.Capacity,
	}}
}

// TemplateSlotResult echoes a stored slot back to the caller.
type TemplateSlotResult struct {
	Seq          int    `json:"seq"`
	ClassTypeID  string `json:"class_type_id"`
	InstructorID string `json:"instructor_id"`
	RoomID       string `json:"room_id"`
	Weekday      int    `json:"weekday"`
	StartHour    int    `json:"start_hour"`
	StartMinute  int    `json:"start_minute"`
	DurationMins int    `json:"duration_mins"`
	Capacity     int    `json:"capacity"`
	Title        string `json:"title,omitempty"`
}

// ClassTemplateResult is returned from POST and from GET.
type ClassTemplateResult struct {
	ID                string               `json:"id"`
	Title             string               `json:"title"`
	Weeks             int                  `json:"weeks"`
	StartsOn          string               `json:"starts_on"`
	Slots             []TemplateSlotResult `json:"slots"`
	GeneratedClassIDs []string             `json:"generated_class_ids"`
	Sessions          []string             `json:"sessions"` // ISO timestamps
	Status            string               `json:"status"`
	CreatedAt         string               `json:"created_at"`
}

// CreateClassTemplateWithAudit wraps the create with an audit entry.
func (s *Store) CreateClassTemplateWithAudit(ctx context.Context, studioID, actorID string, in ClassTemplateInput) (*ClassTemplateResult, error) {
	r, err := s.CreateClassTemplate(ctx, studioID, actorID, in)
	if err != nil {
		return nil, err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "template_create", "class_template", r.ID, map[string]any{
		"title":             in.Title,
		"weeks":             in.Weeks,
		"slots":             len(r.Slots),
		"generated_classes": len(r.GeneratedClassIDs),
	})
	return r, nil
}

// UndoClassTemplateWithAudit wraps with audit.
func (s *Store) UndoClassTemplateWithAudit(ctx context.Context, studioID, actorID, templateID string) (*UndoTemplateResult, error) {
	r, err := s.UndoClassTemplate(ctx, studioID, templateID)
	if err != nil {
		return nil, err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "template_revert", "class_template", templateID, map[string]any{
		"total_classes":      r.TotalClasses,
		"bookings_cancelled": r.Summary.BookingsCancelled,
		"credits_returned":   r.Summary.CreditsReturned,
		"notifications_sent": r.Summary.NotificationsSent,
	})
	return r, nil
}

func validateTemplate(in ClassTemplateInput, slots []TemplateSlotInput) error {
	if in.Title == "" {
		return fmt.Errorf("title is required")
	}
	if in.Weeks <= 0 || in.Weeks > 52 {
		return fmt.Errorf("weeks must be between 1 and 52")
	}
	if len(slots) == 0 {
		return fmt.Errorf("at least one slot is required")
	}
	if in.Weeks*len(slots) > maxTemplateClasses {
		return fmt.Errorf("template would generate %d classes (max %d)", in.Weeks*len(slots), maxTemplateClasses)
	}
	for i, sl := range slots {
		if sl.ClassTypeID == "" || sl.InstructorID == "" || sl.RoomID == "" {
			return fmt.Errorf("slot %d: class_type_id, instructor_id, room_id are required", i+1)
		}
		if sl.Weekday < 0 || sl.Weekday > 6 {
			return fmt.Errorf("slot %d: weekday must be 0..6 (Mon=0)", i+1)
		}
		if sl.StartHour < 0 || sl.StartHour > 23 || sl.StartMinute < 0 || sl.StartMinute > 59 {
			return fmt.Errorf("slot %d: invalid start time", i+1)
		}
		if sl.DurationMins <= 0 {
			return fmt.Errorf("slot %d: duration_mins must be > 0", i+1)
		}
		if sl.Capacity <= 0 {
			return fmt.Errorf("slot %d: capacity must be > 0", i+1)
		}
	}
	return nil
}

func (s *Store) CreateClassTemplate(ctx context.Context, studioID, actorID string, in ClassTemplateInput) (*ClassTemplateResult, error) {
	slots := in.slots()
	if err := validateTemplate(in, slots); err != nil {
		return nil, err
	}
	startsOn, err := time.Parse("2006-01-02", in.StartsOn)
	if err != nil {
		return nil, fmt.Errorf("starts_on must be YYYY-MM-DD")
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	templateID := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO class_templates
		    (id, studio_id, created_by, title, weeks, starts_on, status)
		    VALUES (?, ?, ?, ?, ?, ?, 'active')`,
		templateID, studioID, actorID, in.Title, in.Weeks, in.StartsOn,
	); err != nil {
		return nil, err
	}

	out := &ClassTemplateResult{
		ID:                templateID,
		Title:             in.Title,
		Weeks:             in.Weeks,
		StartsOn:          in.StartsOn,
		Slots:             make([]TemplateSlotResult, 0, len(slots)),
		GeneratedClassIDs: make([]string, 0, in.Weeks*len(slots)),
		Sessions:          make([]string, 0, in.Weeks*len(slots)),
		Status:            "active",
		CreatedAt:         time.Now().UTC().Format(time.RFC3339),
	}

	for i, sl := range slots {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO class_template_slots
			    (id, template_id, seq, class_type_id, instructor_id, room_id,
			     weekday, start_hour, start_minute, duration_mins, capacity, title)
			    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			NewID(), templateID, i, sl.ClassTypeID, sl.InstructorID, sl.RoomID,
			sl.Weekday, sl.StartHour, sl.StartMinute, sl.DurationMins, sl.Capacity,
			nullableTitle(sl.Title),
		); err != nil {
			return nil, err
		}
		out.Slots = append(out.Slots, TemplateSlotResult{
			Seq: i, ClassTypeID: sl.ClassTypeID, InstructorID: sl.InstructorID,
			RoomID: sl.RoomID, Weekday: sl.Weekday, StartHour: sl.StartHour,
			StartMinute: sl.StartMinute, DurationMins: sl.DurationMins,
			Capacity: sl.Capacity, Title: sl.Title,
		})

		// Snap starts_on forward to this slot's weekday, then walk one class
		// per week.
		currentWeekday := (int(startsOn.Weekday()) + 6) % 7 // Mon=0
		delta := (sl.Weekday - currentWeekday + 7) % 7
		first := startsOn.AddDate(0, 0, delta).
			Add(time.Duration(sl.StartHour)*time.Hour + time.Duration(sl.StartMinute)*time.Minute)
		title := sl.Title
		if title == "" {
			title = in.Title
		}
		for w := 0; w < in.Weeks; w++ {
			start := first.AddDate(0, 0, w*7).UTC()
			end := start.Add(time.Duration(sl.DurationMins) * time.Minute)
			classID := NewID()
			if _, err := tx.ExecContext(ctx, `
				INSERT INTO classes
				    (id, studio_id, class_type_id, instructor_id, room_id,
				     template_batch_id, title, starts_at, ends_at, capacity)
				    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				classID, studioID, sl.ClassTypeID, sl.InstructorID, sl.RoomID,
				templateID, title,
				start.Format(time.RFC3339), end.Format(time.RFC3339), sl.Capacity,
			); err != nil {
				return nil, err
			}
			out.GeneratedClassIDs = append(out.GeneratedClassIDs, classID)
			out.Sessions = append(out.Sessions, start.Format(time.RFC3339))
		}
	}

	return out, tx.Commit()
}

// ListClassTemplates returns all templates for a studio, most recent first,
// each with its slots and generated sessions.
func (s *Store) ListClassTemplates(ctx context.Context, studioID string) ([]ClassTemplateResult, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, title, weeks, starts_on, status, created_at FROM class_templates
		 WHERE studio_id = ?
		 ORDER BY created_at DESC LIMIT 50`,
		studioID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ClassTemplateResult{}
	for rows.Next() {
		var t ClassTemplateResult
		if err := rows.Scan(&t.ID, &t.Title, &t.Weeks, &t.StartsOn, &t.Status, &t.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Hydrate slots + generated classes per template. Small N (<=50), so a
	// per-template query is fine and keeps the scan simple.
	for i := range out {
		if err := s.loadTemplateSlots(ctx, &out[i]); err != nil {
			return nil, err
		}
		if err := s.loadTemplateClasses(ctx, &out[i]); err != nil {
			return nil, err
		}
	}
	return out, nil
}

func (s *Store) loadTemplateSlots(ctx context.Context, t *ClassTemplateResult) error {
	rows, err := s.db.QueryContext(ctx, `
		SELECT seq, class_type_id, instructor_id, room_id, weekday,
		       start_hour, start_minute, duration_mins, capacity, COALESCE(title,'')
		  FROM class_template_slots WHERE template_id = ? ORDER BY seq`,
		t.ID,
	)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var sl TemplateSlotResult
		if err := rows.Scan(&sl.Seq, &sl.ClassTypeID, &sl.InstructorID, &sl.RoomID,
			&sl.Weekday, &sl.StartHour, &sl.StartMinute, &sl.DurationMins,
			&sl.Capacity, &sl.Title); err != nil {
			return err
		}
		t.Slots = append(t.Slots, sl)
	}
	return rows.Err()
}

func (s *Store) loadTemplateClasses(ctx context.Context, t *ClassTemplateResult) error {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, starts_at FROM classes WHERE template_batch_id = ? ORDER BY starts_at`,
		t.ID,
	)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id, startsAt string
		if err := rows.Scan(&id, &startsAt); err != nil {
			return err
		}
		t.GeneratedClassIDs = append(t.GeneratedClassIDs, id)
		t.Sessions = append(t.Sessions, startsAt)
	}
	return rows.Err()
}

// UndoTemplateResult sums up what the undo did, per class.
type UndoTemplateResult struct {
	Status        string              `json:"status"`
	TotalClasses  int                 `json:"total_classes"`
	CancelResults []CancelClassResult `json:"cancel_results"`
	Summary       CancelClassResult   `json:"summary"`
}

// UndoClassTemplate iterates every class in the batch and calls
// CancelAdminClass on each — which handles refunds, credit returns, and
// notifications via the same path as a one-off cancel.
func (s *Store) UndoClassTemplate(ctx context.Context, studioID, templateID string) (*UndoTemplateResult, error) {
	// Verify the template + still active.
	var status string
	err := s.db.QueryRowContext(ctx,
		`SELECT status FROM class_templates WHERE id = ? AND studio_id = ?`,
		templateID, studioID,
	).Scan(&status)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if status == "reverted" {
		return nil, fmt.Errorf("template already reverted")
	}

	rows, err := s.db.QueryContext(ctx,
		`SELECT id FROM classes WHERE template_batch_id = ? AND status = 'scheduled'`,
		templateID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	classIDs := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		classIDs = append(classIDs, id)
	}

	out := &UndoTemplateResult{
		Status:        "reverted",
		TotalClasses:  len(classIDs),
		CancelResults: make([]CancelClassResult, 0, len(classIDs)),
	}
	for _, id := range classIDs {
		r, err := s.CancelAdminClass(ctx, studioID, id)
		if err != nil {
			return nil, fmt.Errorf("cancel class %s: %w", id, err)
		}
		out.CancelResults = append(out.CancelResults, *r)
		out.Summary.BookingsCancelled += r.BookingsCancelled
		out.Summary.CreditsReturned += r.CreditsReturned
		out.Summary.NotificationsSent += r.NotificationsSent
		out.Summary.WaitlistCleared += r.WaitlistCleared
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE class_templates SET status = 'reverted' WHERE id = ?`, templateID,
	); err != nil {
		return nil, err
	}
	return out, nil
}

func nullableTitle(s string) any {
	if s == "" {
		return nil
	}
	return s
}
