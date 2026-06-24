package store

import (
	"context"
	"errors"
	"testing"
)

// helper: insert a notification for the fixture's student, optionally already
// read. Returns the new id.
func (f fixture) insertNotification(t *testing.T, s *Store, read bool) string {
	t.Helper()
	id := NewID()
	readExpr := "NULL"
	if read {
		readExpr = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"
	}
	if _, err := s.db.ExecContext(context.Background(), `
		INSERT INTO notifications (id, studio_id, user_id, type, title, body, read_at)
		VALUES (?, ?, ?, 'system', 'T', 'B', `+readExpr+`)`,
		id, f.studioID, f.studentID); err != nil {
		t.Fatalf("insert notification: %v", err)
	}
	return id
}

// TestDeleteNotification: a user can delete their own notification; deleting
// a stranger's (or a missing) row is ErrNotFound and leaves it in place.
func TestDeleteNotification(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	id := f.insertNotification(t, s, false)
	if err := s.DeleteNotification(ctx, f.studentID, id); err != nil {
		t.Fatalf("delete own: %v", err)
	}
	feed, _ := s.NotificationsFeed(ctx, f.studentID)
	if len(feed) != 0 {
		t.Fatalf("want feed empty after delete, got %d", len(feed))
	}

	// Re-insert and try to delete as the instructor (not the owner).
	id2 := f.insertNotification(t, s, false)
	if err := s.DeleteNotification(ctx, f.instructorID, id2); !errors.Is(err, ErrNotFound) {
		t.Fatalf("delete another user's row: want ErrNotFound, got %v", err)
	}
	feed, _ = s.NotificationsFeed(ctx, f.studentID)
	if len(feed) != 1 {
		t.Fatalf("foreign delete should not remove the row, feed=%d", len(feed))
	}

	// Unknown id → ErrNotFound.
	if err := s.DeleteNotification(ctx, f.studentID, NewID()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("delete missing: want ErrNotFound, got %v", err)
	}
}

// TestClearReadNotifications: clearing removes only read rows, returns the
// count removed, and leaves unread rows untouched so nothing unseen is lost.
func TestClearReadNotifications(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	f.insertNotification(t, s, true)  // read
	f.insertNotification(t, s, true)  // read
	unread := f.insertNotification(t, s, false)

	n, err := s.ClearReadNotifications(ctx, f.studentID)
	if err != nil {
		t.Fatalf("clear read: %v", err)
	}
	if n != 2 {
		t.Fatalf("want 2 cleared, got %d", n)
	}
	feed, _ := s.NotificationsFeed(ctx, f.studentID)
	if len(feed) != 1 || feed[0].ID != unread {
		t.Fatalf("clear should keep the single unread row, got %+v", feed)
	}
}
