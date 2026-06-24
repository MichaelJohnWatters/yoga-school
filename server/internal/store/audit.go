package store

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"strings"
)

type AuditEntry struct {
	ID         string         `json:"id"`
	ActorID    string         `json:"actor_id"`
	ActorName  string         `json:"actor_name"`
	Action     string         `json:"action"`
	TargetType string         `json:"target_type"`
	TargetID   string         `json:"target_id,omitempty"`
	Detail     map[string]any `json:"detail"`
	CreatedAt  string         `json:"created_at"`
}

// AuditQuery parameterises a page of the activity log. All fields optional:
// Action filters to one action ("" / "all" = every action); Search is a
// case-insensitive substring matched against actor name, action, and the
// raw detail blob; Cursor is the opaque token from a previous page's
// NextCursor ("" = first page); Limit defaults to 50 (max 100).
type AuditQuery struct {
	Action string
	Search string
	Cursor string
	Limit  int
}

// AuditPage is one keyset page of audit rows. NextCursor is non-empty when
// more rows exist; pass it back as AuditQuery.Cursor to fetch the next page.
type AuditPage struct {
	Entries    []AuditEntry `json:"entries"`
	NextCursor string       `json:"next_cursor,omitempty"`
}

// ListAudit returns one keyset-paginated page of the activity log, newest
// first. Pagination seeks on (created_at, id) DESC — created_at alone isn't
// unique (bulk inserts share a millisecond), so id is the tiebreaker. The
// seek is stable under the constant append of new rows: older pages never
// shift because new rows land above the cursor. Filters run in SQL (so they
// search the WHOLE table, not just a loaded page) and lean on
// idx_audit_studio_action_time for the action-filtered case.
func (s *Store) ListAudit(ctx context.Context, studioID string, q AuditQuery) (*AuditPage, error) {
	limit := q.Limit
	if limit <= 0 || limit > 100 {
		limit = 50
	}

	where := []string{"a.studio_id = ?"}
	args := []any{studioID}
	if q.Action != "" && q.Action != "all" {
		where = append(where, "a.action = ?")
		args = append(args, q.Action)
	}
	if cur := decodeAuditCursor(q.Cursor); cur != nil {
		// (created_at, id) < (cursor.createdAt, cursor.id), DESC.
		where = append(where, "(a.created_at < ? OR (a.created_at = ? AND a.id < ?))")
		args = append(args, cur.createdAt, cur.createdAt, cur.id)
	}
	if term := strings.TrimSpace(q.Search); term != "" {
		like := "%" + term + "%"
		where = append(where, "(u.full_name LIKE ? OR a.detail LIKE ? OR a.action LIKE ?)")
		args = append(args, like, like, like)
	}

	// Fetch one extra row to detect whether a further page exists.
	query := `
		SELECT a.id, a.actor_id, u.full_name, a.action, a.target_type,
		       COALESCE(a.target_id, ''), a.detail, a.created_at
		  FROM audit_log a
		  JOIN users u ON u.id = a.actor_id
		 WHERE ` + strings.Join(where, " AND ") + `
		 ORDER BY a.created_at DESC, a.id DESC
		 LIMIT ?`
	args = append(args, limit+1)

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]AuditEntry, 0, limit+1)
	for rows.Next() {
		var (
			e          AuditEntry
			detailJSON string
		)
		if err := rows.Scan(&e.ID, &e.ActorID, &e.ActorName, &e.Action,
			&e.TargetType, &e.TargetID, &detailJSON, &e.CreatedAt); err != nil {
			return nil, err
		}
		_ = json.Unmarshal([]byte(detailJSON), &e.Detail)
		if e.Detail == nil {
			e.Detail = map[string]any{}
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	page := &AuditPage{}
	if len(out) > limit {
		last := out[limit-1] // last row we'll actually return
		page.NextCursor = encodeAuditCursor(last.CreatedAt, last.ID)
		out = out[:limit]
	}
	page.Entries = out
	return page, nil
}

type auditCursor struct{ createdAt, id string }

// Cursor token: base64url("<created_at>\x1f<id>"). Opaque to the client; the
// \x1f unit-separator can't appear in an ISO timestamp or a NanoID.
func encodeAuditCursor(createdAt, id string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(createdAt + "\x1f" + id))
}

func decodeAuditCursor(c string) *auditCursor {
	if c == "" {
		return nil
	}
	b, err := base64.RawURLEncoding.DecodeString(c)
	if err != nil {
		return nil
	}
	parts := strings.SplitN(string(b), "\x1f", 2)
	if len(parts) != 2 {
		return nil
	}
	return &auditCursor{createdAt: parts[0], id: parts[1]}
}

// Just to silence the unused warning on sql.Null types in builds without them.
var _ = sql.ErrNoRows

// WriteAudit is the standalone (non-tx) helper for callers outside tx-bound
// flows. Mirrors writeAuditTx.
func (s *Store) WriteAudit(ctx context.Context, studioID, actorID, action, targetType, targetID string, detail map[string]any) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := s.writeAuditTx(ctx, tx, studioID, actorID, action, targetType, targetID, detail); err != nil {
		return err
	}
	return tx.Commit()
}
