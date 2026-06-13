package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// ClassTemplateInput is the body for POST /admin/class-templates.
type ClassTemplateInput struct {
	Title        string `json:"title"`
	ClassTypeID  string `json:"class_type_id"`
	InstructorID string `json:"instructor_id"`
	RoomID       string `json:"room_id"`
	Weekday      int    `json:"weekday"` // 0=Mon, ..., 6=Sun
	StartHour    int    `json:"start_hour"`
	StartMinute  int    `json:"start_minute"`
	DurationMins int    `json:"duration_mins"`
	Capacity     int    `json:"capacity"`
	Weeks        int    `json:"weeks"`
	StartsOn     string `json:"starts_on"` // YYYY-MM-DD; first session date
}

// ClassTemplateResult is returned from POST and from GET.
type ClassTemplateResult struct {
	ID                string   `json:"id"`
	Title             string   `json:"title"`
	GeneratedClassIDs []string `json:"generated_class_ids"`
	Sessions          []string `json:"sessions"` // ISO timestamps
	Status            string   `json:"status"`
	CreatedAt         string   `json:"created_at"`
}

// CreateClassTemplateWithAudit wraps the create with an audit entry.
func (s *Store) CreateClassTemplateWithAudit(ctx context.Context, studioID, actorID string, in ClassTemplateInput) (*ClassTemplateResult, error) {
	r, err := s.CreateClassTemplate(ctx, studioID, actorID, in)
	if err != nil {
		return nil, err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "template_create", "class_template", r.ID, map[string]any{
		"title":              in.Title,
		"weeks":              in.Weeks,
		"generated_classes":  len(r.GeneratedClassIDs),
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

func (s *Store) CreateClassTemplate(ctx context.Context, studioID, actorID string, in ClassTemplateInput) (*ClassTemplateResult, error) {
	if in.Title == "" || in.ClassTypeID == "" || in.InstructorID == "" || in.RoomID == "" {
		return nil, fmt.Errorf("title, class_type_id, instructor_id, room_id are required")
	}
	if in.Weeks <= 0 || in.Weeks > 52 {
		return nil, fmt.Errorf("weeks must be between 1 and 52")
	}
	if in.DurationMins <= 0 {
		return nil, fmt.Errorf("duration_mins must be > 0")
	}
	if in.Capacity <= 0 {
		return nil, fmt.Errorf("capacity must be > 0")
	}
	if in.Weekday < 0 || in.Weekday > 6 {
		return nil, fmt.Errorf("weekday must be 0..6 (Mon=0)")
	}
	if in.StartHour < 0 || in.StartHour > 23 || in.StartMinute < 0 || in.StartMinute > 59 {
		return nil, fmt.Errorf("invalid start time")
	}
	startsOn, err := time.Parse("2006-01-02", in.StartsOn)
	if err != nil {
		return nil, fmt.Errorf("starts_on must be YYYY-MM-DD")
	}
	// Snap to the requested weekday (forward) if starts_on falls earlier in
	// the week than the chosen weekday.
	currentWeekday := (int(startsOn.Weekday()) + 6) % 7 // Mon=0
	delta := (in.Weekday - currentWeekday + 7) % 7
	firstSession := startsOn.AddDate(0, 0, delta).
		Add(time.Duration(in.StartHour)*time.Hour + time.Duration(in.StartMinute)*time.Minute)

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	templateID := uuid.NewString()
	_, err = tx.ExecContext(ctx, `
		INSERT INTO class_templates
		    (id, studio_id, created_by, title, class_type_id, instructor_id,
		     room_id, weekday, start_hour, start_minute, duration_mins,
		     capacity, weeks, starts_on, status)
		    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')`,
		templateID, studioID, actorID, in.Title, in.ClassTypeID, in.InstructorID,
		in.RoomID, in.Weekday, in.StartHour, in.StartMinute, in.DurationMins,
		in.Capacity, in.Weeks, in.StartsOn,
	)
	if err != nil {
		return nil, err
	}

	out := &ClassTemplateResult{
		ID:                templateID,
		Title:             in.Title,
		GeneratedClassIDs: make([]string, 0, in.Weeks),
		Sessions:          make([]string, 0, in.Weeks),
		Status:            "active",
		CreatedAt:         time.Now().UTC().Format(time.RFC3339),
	}

	for w := 0; w < in.Weeks; w++ {
		start := firstSession.AddDate(0, 0, w*7).UTC()
		end := start.Add(time.Duration(in.DurationMins) * time.Minute)
		classID := uuid.NewString()
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO classes
			    (id, studio_id, class_type_id, instructor_id, room_id,
			     template_batch_id, title, starts_at, ends_at, capacity)
			    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			classID, studioID, in.ClassTypeID, in.InstructorID, in.RoomID,
			templateID, in.Title,
			start.Format(time.RFC3339), end.Format(time.RFC3339), in.Capacity,
		); err != nil {
			return nil, err
		}
		out.GeneratedClassIDs = append(out.GeneratedClassIDs, classID)
		out.Sessions = append(out.Sessions, start.Format(time.RFC3339))
	}

	return out, tx.Commit()
}

// ListClassTemplates returns all templates for a studio, most recent first.
func (s *Store) ListClassTemplates(ctx context.Context, studioID string) ([]ClassTemplateResult, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, title, status, created_at FROM class_templates
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
		if err := rows.Scan(&t.ID, &t.Title, &t.Status, &t.CreatedAt); err != nil {
			return nil, err
		}
		// Pull per-template generated class IDs.
		crows, err := s.db.QueryContext(ctx,
			`SELECT id, starts_at FROM classes WHERE template_batch_id = ? ORDER BY starts_at`,
			t.ID,
		)
		if err != nil {
			return nil, err
		}
		for crows.Next() {
			var id, startsAt string
			if err := crows.Scan(&id, &startsAt); err != nil {
				crows.Close()
				return nil, err
			}
			t.GeneratedClassIDs = append(t.GeneratedClassIDs, id)
			t.Sessions = append(t.Sessions, startsAt)
		}
		crows.Close()
		out = append(out, t)
	}
	return out, rows.Err()
}

// UndoTemplateResult sums up what the undo did, per class.
type UndoTemplateResult struct {
	Status         string              `json:"status"`
	TotalClasses   int                 `json:"total_classes"`
	CancelResults  []CancelClassResult `json:"cancel_results"`
	Summary        CancelClassResult   `json:"summary"`
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
