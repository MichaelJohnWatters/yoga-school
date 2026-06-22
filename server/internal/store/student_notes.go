package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

// StudentNote is one free-text note attached to a student, visible to
// any staff member who opens the student's detail page. AuthorName is
// joined in for display so the UI doesn't need a second lookup.
type StudentNote struct {
	ID         string  `json:"id"`
	UserID     string  `json:"user_id"`
	AuthorID   string  `json:"author_id"`
	AuthorName string  `json:"author_name"`
	Body       string  `json:"body"`
	CreatedAt  string  `json:"created_at"`
	UpdatedAt  *string `json:"updated_at,omitempty"`
}

// ListStudentNotes returns the notes for [userID] newest-first.
// Returns an empty slice (not nil) when there are no notes, so the
// JSON response is a stable `[]` rather than `null`.
func (s *Store) ListStudentNotes(ctx context.Context, studioID, userID string) ([]StudentNote, error) {
	const q = `
		SELECT n.id, n.user_id, n.author_id,
		       COALESCE(a.full_name, '[unknown]') AS author_name,
		       n.body, n.created_at, n.updated_at
		  FROM user_notes n
		  LEFT JOIN users a ON a.id = n.author_id
		 WHERE n.studio_id = ?
		   AND n.user_id   = ?
		 ORDER BY n.created_at DESC`
	rows, err := s.db.QueryContext(ctx, q, studioID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]StudentNote, 0)
	for rows.Next() {
		var (
			n         StudentNote
			updatedAt sql.NullString
		)
		if err := rows.Scan(&n.ID, &n.UserID, &n.AuthorID, &n.AuthorName,
			&n.Body, &n.CreatedAt, &updatedAt); err != nil {
			return nil, err
		}
		if updatedAt.Valid {
			v := updatedAt.String
			n.UpdatedAt = &v
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// CreateStudentNote inserts a note authored by [authorID] about
// [userID]. Body is trimmed; empty bodies are refused so the UI can
// safely auto-submit on blur without creating phantom rows.
func (s *Store) CreateStudentNote(ctx context.Context, studioID, authorID, userID, body string) (string, error) {
	body = strings.TrimSpace(body)
	if body == "" {
		return "", errors.New("note body is required")
	}
	// Confirm the subject + author both belong to this studio so a
	// compromised auth context can't write notes across tenants.
	if err := s.assertUserInStudio(ctx, studioID, userID); err != nil {
		return "", err
	}
	id := NewID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO user_notes (id, studio_id, user_id, author_id, body)
		      VALUES (?, ?, ?, ?, ?)`,
		id, studioID, userID, authorID, body,
	); err != nil {
		return "", err
	}
	_ = s.WriteAudit(ctx, studioID, authorID, "student_note_create", "user_note", id, map[string]any{
		"user_id": userID,
		"body":    body,
	})
	return id, nil
}

// UpdateStudentNote replaces a note's body and stamps updated_at. Only
// the original author can edit — gating this in the store rather than
// the handler so the rule survives if the route ever moves.
func (s *Store) UpdateStudentNote(ctx context.Context, studioID, authorID, noteID, body string) error {
	body = strings.TrimSpace(body)
	if body == "" {
		return errors.New("note body is required")
	}
	var (
		ownerID string
		prev    string
	)
	err := s.db.QueryRowContext(ctx,
		`SELECT author_id, body FROM user_notes WHERE id = ? AND studio_id = ?`,
		noteID, studioID,
	).Scan(&ownerID, &prev)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if ownerID != authorID {
		return ErrNotSender
	}
	if prev == body {
		// No-op edit. Don't bump updated_at or write an audit row.
		return nil
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE user_notes
		    SET body = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		  WHERE id = ? AND studio_id = ?`,
		body, noteID, studioID,
	); err != nil {
		return err
	}
	_ = s.WriteAudit(ctx, studioID, authorID, "student_note_update", "user_note", noteID, map[string]any{
		"from": prev,
		"to":   body,
	})
	return nil
}

// DeleteStudentNote removes a note. Only the original author (or a
// manager — caller decides) can delete. We keep the rule
// author-only at the store layer; the API layer can layer a manager
// override on top if it wants.
func (s *Store) DeleteStudentNote(ctx context.Context, studioID, authorID, noteID string) error {
	var (
		ownerID string
		userID  string
		body    string
	)
	err := s.db.QueryRowContext(ctx,
		`SELECT author_id, user_id, body FROM user_notes
		  WHERE id = ? AND studio_id = ?`,
		noteID, studioID,
	).Scan(&ownerID, &userID, &body)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if ownerID != authorID {
		return ErrNotSender
	}
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM user_notes WHERE id = ? AND studio_id = ?`,
		noteID, studioID,
	); err != nil {
		return err
	}
	// Audit detail keeps the body so "what did the deleted note say"
	// can be answered without restoring it.
	_ = s.WriteAudit(ctx, studioID, authorID, "student_note_delete", "user_note", noteID, map[string]any{
		"user_id": userID,
		"body":    body,
	})
	return nil
}

// assertUserInStudio is a small tenant-scoping helper — fails when the
// target user isn't a member of the calling studio. Used as a sanity
// check before notes-style writes; reads from list endpoints already
// scope by studio_id and don't need this.
func (s *Store) assertUserInStudio(ctx context.Context, studioID, userID string) error {
	var n int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM users WHERE id = ? AND studio_id = ?`,
		userID, studioID,
	).Scan(&n); err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
