package store

import (
	"context"
	"database/sql"
	"encoding/json"
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

func (s *Store) ListAudit(ctx context.Context, studioID, actionFilter string, limit int) ([]AuditEntry, error) {
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	q := `
		SELECT a.id, a.actor_id, u.full_name, a.action, a.target_type,
		       COALESCE(a.target_id, ''), a.detail, a.created_at
		  FROM audit_log a
		  JOIN users u ON u.id = a.actor_id
		 WHERE a.studio_id = ?`
	args := []any{studioID}
	if actionFilter != "" && actionFilter != "all" {
		q += ` AND a.action = ?`
		args = append(args, actionFilter)
	}
	q += ` ORDER BY a.created_at DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]AuditEntry, 0)
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
	return out, rows.Err()
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
