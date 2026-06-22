package store

import (
	"context"
	"database/sql"
	"errors"
	"regexp"
	"strings"
)

// hexColorRE bounds the colour values clients can set on a room. We
// keep the shape narrow — lowercase `#rrggbb`, no alpha, no shorthand —
// because the column flows straight to CSS-style usage in the Flutter
// layer and any deviation invites parsing branches. NULL / empty is
// still a valid stored value meaning "no tint".
var hexColorRE = regexp.MustCompile(`^#[0-9a-f]{6}$`)

// normaliseColor returns the canonical lowercase form of [c] when it
// matches [hexColorRE], the empty string when [c] is blank (the "clear
// the colour" signal), or an error otherwise. Callers pass the result
// straight to a nullable column write — empty string → SQL NULL.
func normaliseColor(c string) (string, error) {
	c = strings.TrimSpace(strings.ToLower(c))
	if c == "" {
		return "", nil
	}
	if !hexColorRE.MatchString(c) {
		return "", errors.New("colour must be a hex value like #a3b7c1")
	}
	return c, nil
}

// ErrRoomInUse is returned by DeleteRoom when one or more classes still
// reference the room. classes.room_id is NOT NULL in the schema so a
// silent cascade would either fail the FK or strand orphan rows — both
// worse than asking the manager to move / cancel the classes first. The
// API layer maps this to a 409 with code room_in_use so the UI can show
// the count of blocking classes.
var ErrRoomInUse = errors.New("room is still used by one or more classes")

// CreateRoom inserts a new room scoped to studioID. Names are trimmed +
// must be unique within the studio (matches the implicit shape of every
// other studio-scoped name in this DB — class types, themes, products).
// [color] is the optional accent the UI tints class cards with — pass
// empty string to leave it unset. Returns the new room's ID.
func (s *Store) CreateRoom(ctx context.Context, studioID, actorID, name, color string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", errors.New("room name is required")
	}
	normColor, err := normaliseColor(color)
	if err != nil {
		return "", err
	}
	// Pre-check uniqueness so the API layer can return a clear error
	// rather than an opaque SQL constraint failure.
	if dup, err := s.roomNameTaken(ctx, studioID, name, ""); err != nil {
		return "", err
	} else if dup {
		return "", errors.New("a room with that name already exists")
	}
	id := NewID()
	var colorArg any
	if normColor != "" {
		colorArg = normColor
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO rooms (id, studio_id, name, color) VALUES (?, ?, ?, ?)`,
		id, studioID, name, colorArg,
	); err != nil {
		return "", err
	}
	detail := map[string]any{"name": name}
	if normColor != "" {
		detail["color"] = normColor
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "room_create", "room", id, detail)
	return id, nil
}

// RoomPatch is the editable subset of a room — pointer fields so absent
// keys mean "leave this column alone" rather than "set it to empty".
// Color is special: a non-nil empty-string pointer means "clear it"
// (column → NULL); a non-nil "#rrggbb" pointer means "set it".
type RoomPatch struct {
	Name  *string `json:"name,omitempty"`
	Color *string `json:"color,omitempty"`
}

// UpdateRoom applies the patch to the room. Both name and colour are
// optional — a patch that touches neither is a no-op (and writes no
// audit row, to keep the activity feed from filling up with empty
// saves). Same uniqueness + format rules as CreateRoom apply.
func (s *Store) UpdateRoom(ctx context.Context, studioID, actorID, roomID string, p RoomPatch) error {
	// Read current state so the audit detail can record what actually
	// changed AND to confirm the room belongs to this studio before
	// mutating anything.
	var (
		prevName  string
		prevColor sql.NullString
	)
	err := s.db.QueryRowContext(ctx,
		`SELECT name, color FROM rooms WHERE id = ? AND studio_id = ?`,
		roomID, studioID,
	).Scan(&prevName, &prevColor)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}

	nextName := prevName
	if p.Name != nil {
		nextName = strings.TrimSpace(*p.Name)
		if nextName == "" {
			return errors.New("room name is required")
		}
	}
	// Colour: nil = unchanged; non-nil empty = clear; non-nil value = set.
	prevColorStr := ""
	if prevColor.Valid {
		prevColorStr = prevColor.String
	}
	nextColor := prevColorStr
	if p.Color != nil {
		n, err := normaliseColor(*p.Color)
		if err != nil {
			return err
		}
		nextColor = n
	}

	// Short-circuit no-op patches BEFORE touching the DB so we don't
	// run a redundant UPDATE + audit row when the user opens then closes
	// the form without changing anything.
	if nextName == prevName && nextColor == prevColorStr {
		return nil
	}

	if nextName != prevName {
		if dup, err := s.roomNameTaken(ctx, studioID, nextName, roomID); err != nil {
			return err
		} else if dup {
			return errors.New("a room with that name already exists")
		}
	}

	var colorArg any
	if nextColor != "" {
		colorArg = nextColor
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE rooms SET name = ?, color = ? WHERE id = ? AND studio_id = ?`,
		nextName, colorArg, roomID, studioID,
	); err != nil {
		return err
	}
	detail := map[string]any{"name": nextName}
	if nextName != prevName {
		detail["previous_name"] = prevName
	}
	if nextColor != prevColorStr {
		// Use empty string in the audit detail to mean "cleared" — it
		// reads naturally next to the previous_color field.
		detail["color"] = nextColor
		detail["previous_color"] = prevColorStr
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "room_update", "room", roomID, detail)
	return nil
}

// DeleteRoom refuses if any class still references the room. The caller
// (UI) gets back a typed sentinel so it can surface "X classes still use
// this room — move them first" rather than a generic 500.
func (s *Store) DeleteRoom(ctx context.Context, studioID, actorID, roomID string) error {
	// Single transaction so the in-use check and the delete can't race
	// against a concurrent class creation.
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var name string
	err = tx.QueryRowContext(ctx,
		`SELECT name FROM rooms WHERE id = ? AND studio_id = ?`,
		roomID, studioID,
	).Scan(&name)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}

	// Count blocking references. The room is pinned by:
	//   * materialised classes (classes.room_id),
	//   * active recurrence rules (recurrence_rules.room_id) — a rule
	//     with no future sessions still blocks because the next
	//     materialisation would fail,
	//   * class templates (class_templates.room_id) — templates spawn
	//     new classes and the FK would refuse mid-spawn otherwise.
	var classCount, ruleCount, tplCount int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM classes WHERE room_id = ?`, roomID,
	).Scan(&classCount); err != nil {
		return err
	}
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM recurrence_rules WHERE room_id = ?`, roomID,
	).Scan(&ruleCount); err != nil {
		return err
	}
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM class_templates WHERE room_id = ?`, roomID,
	).Scan(&tplCount); err != nil {
		return err
	}
	if classCount+ruleCount+tplCount > 0 {
		return ErrRoomInUse
	}

	if _, err := tx.ExecContext(ctx,
		`DELETE FROM rooms WHERE id = ? AND studio_id = ?`,
		roomID, studioID,
	); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "room_delete", "room", roomID, map[string]any{
		"name": name,
	})
	return nil
}

// roomNameTaken reports whether another room in the same studio already
// owns [name] (case-sensitive — the rooms in the wild tend to be short
// numeric labels like "Room 1" so collapsing case would be more
// surprising than helpful). Pass [exceptID] to ignore a specific row
// (used by UpdateRoom so a rename-to-same-letters-different-trim doesn't
// trigger a self-collision).
func (s *Store) roomNameTaken(ctx context.Context, studioID, name, exceptID string) (bool, error) {
	q := `SELECT COUNT(*) FROM rooms WHERE studio_id = ? AND name = ?`
	args := []any{studioID, name}
	if exceptID != "" {
		q += ` AND id <> ?`
		args = append(args, exceptID)
	}
	var n int
	if err := s.db.QueryRowContext(ctx, q, args...).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}
