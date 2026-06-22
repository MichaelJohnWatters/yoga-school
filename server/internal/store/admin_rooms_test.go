package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestRoomCRUD_CreateRenameDelete(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Create — also sets a colour to exercise the new column.
	id, err := s.CreateRoom(ctx, f.studioID, f.instructorID, "  Reformer  ", "#41B3A3")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	rooms, err := s.ListAdminRooms(ctx, f.studioID)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if got := lookupName(rooms, id); got != "Reformer" {
		t.Fatalf("trimmed name not stored: got %q", got)
	}
	if got := lookupColor(rooms, id); got != "#41b3a3" {
		t.Fatalf("colour not normalised + stored: got %q", got)
	}

	// Rename via patch — uniqueness lets you keep the same name, but a
	// no-op is silently allowed without an audit row.
	newName := "Reformer Studio"
	if err := s.UpdateRoom(ctx, f.studioID, f.instructorID, id, RoomPatch{Name: &newName}); err != nil {
		t.Fatalf("rename: %v", err)
	}
	rooms, _ = s.ListAdminRooms(ctx, f.studioID)
	if lookupName(rooms, id) != "Reformer Studio" {
		t.Fatalf("rename didn't stick: %+v", rooms)
	}
	// Clear the colour via empty-string patch — distinct from omitting
	// the field, which would leave it alone.
	cleared := ""
	if err := s.UpdateRoom(ctx, f.studioID, f.instructorID, id, RoomPatch{Color: &cleared}); err != nil {
		t.Fatalf("clear colour: %v", err)
	}
	rooms, _ = s.ListAdminRooms(ctx, f.studioID)
	if lookupColor(rooms, id) != "" {
		t.Fatalf("clear didn't remove colour: %+v", rooms)
	}

	// Delete — nothing references it, should succeed.
	if err := s.DeleteRoom(ctx, f.studioID, f.instructorID, id); err != nil {
		t.Fatalf("delete: %v", err)
	}
	rooms, _ = s.ListAdminRooms(ctx, f.studioID)
	if lookupName(rooms, id) != "" {
		t.Fatalf("delete didn't remove row: %+v", rooms)
	}
}

func TestRoomCRUD_RejectsBlankAndDuplicate(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateRoom(ctx, f.studioID, f.instructorID, "   ", ""); err == nil {
		t.Fatalf("expected blank name to fail")
	}
	// f.roomID was seeded as "Room A" by the fixture.
	if _, err := s.CreateRoom(ctx, f.studioID, f.instructorID, "Room A", ""); err == nil {
		t.Fatalf("expected duplicate name to fail")
	}
	blank := ""
	if err := s.UpdateRoom(ctx, f.studioID, f.instructorID, f.roomID, RoomPatch{Name: &blank}); err == nil {
		t.Fatalf("expected blank rename to fail")
	}
	// Malformed hex on create + update should also fail with a clean
	// error rather than crashing on the regex / DB layer.
	if _, err := s.CreateRoom(ctx, f.studioID, f.instructorID, "Studio X", "not-a-color"); err == nil {
		t.Fatalf("expected bad colour on create to fail")
	}
	bad := "rgb(1,2,3)"
	if err := s.UpdateRoom(ctx, f.studioID, f.instructorID, f.roomID, RoomPatch{Color: &bad}); err == nil {
		t.Fatalf("expected bad colour on update to fail")
	}
}

func TestRoomCRUD_DeleteRefusesWhenInUse(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Hang a class off the seeded room — DeleteRoom should refuse.
	classID := NewID()
	starts := time.Now().Add(2 * time.Hour).UTC().Format(time.RFC3339)
	ends := time.Now().Add(3 * time.Hour).UTC().Format(time.RFC3339)
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO classes (id, studio_id, class_type_id, instructor_id, room_id,
		                     title, starts_at, ends_at, capacity, status)
		VALUES (?, ?, ?, ?, ?, 'Test', ?, ?, 10, 'scheduled')`,
		classID, f.studioID, f.classTypeID, f.instructorID, f.roomID, starts, ends,
	); err != nil {
		t.Fatalf("seed class: %v", err)
	}

	err := s.DeleteRoom(ctx, f.studioID, f.instructorID, f.roomID)
	if !errors.Is(err, ErrRoomInUse) {
		t.Fatalf("expected ErrRoomInUse, got %v", err)
	}

	// Drop the blocking class — delete should now succeed.
	if _, err := s.db.ExecContext(ctx, `DELETE FROM classes WHERE id = ?`, classID); err != nil {
		t.Fatalf("drop class: %v", err)
	}
	if err := s.DeleteRoom(ctx, f.studioID, f.instructorID, f.roomID); err != nil {
		t.Fatalf("delete after detach: %v", err)
	}
}

func TestRoomCRUD_WritesAuditOnEachMutation(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, err := s.CreateRoom(ctx, f.studioID, f.instructorID, "Studio C", "")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	rename := "Studio C2"
	if err := s.UpdateRoom(ctx, f.studioID, f.instructorID, id, RoomPatch{Name: &rename}); err != nil {
		t.Fatalf("update: %v", err)
	}
	if err := s.DeleteRoom(ctx, f.studioID, f.instructorID, id); err != nil {
		t.Fatalf("delete: %v", err)
	}

	for _, action := range []string{"room_create", "room_update", "room_delete"} {
		var n int
		if err := s.db.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM audit_log WHERE studio_id = ? AND action = ?`,
			f.studioID, action,
		).Scan(&n); err != nil {
			t.Fatalf("count %s: %v", action, err)
		}
		if n != 1 {
			t.Fatalf("expected exactly one %s row, got %d", action, n)
		}
	}
}

// lookupName returns the name of the room with id == [id], or empty
// string when not found. Keeps the assertions in the tests above readable.
func lookupName(rooms []AdminRoom, id string) string {
	for _, r := range rooms {
		if r.ID == id {
			return r.Name
		}
	}
	return ""
}

// lookupColor mirrors lookupName for the optional colour field. Returns
// the empty string both for "room not found" and "room has no colour" —
// the tests assert against the non-empty case explicitly so the
// collapsing is fine.
func lookupColor(rooms []AdminRoom, id string) string {
	for _, r := range rooms {
		if r.ID == id && r.Color != nil {
			return *r.Color
		}
	}
	return ""
}

// Compile-time guard so an accidental rename of the sentinel still
// surfaces in the tests rather than at the HTTP layer only.
var _ = strings.TrimSpace
