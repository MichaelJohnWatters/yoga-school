package api

import (
	"net/http"
	"testing"

	"github.com/studio52/yoga-school/server/internal/store"
)

// TestDeleteNotificationRoute pins the DELETE /me/notifications/{id} route:
// a 204 on the first delete, a 404 once it's gone. Guards against the route
// silently not being registered (which surfaces client-side as a 404 on
// swipe-to-dismiss).
func TestDeleteNotificationRoute(t *testing.T) {
	r := newRig(t)
	id := store.NewID()
	mustExec(t, r.server.store, `
		INSERT INTO notifications (id, studio_id, user_id, type, title, body)
		VALUES (?, ?, ?, 'system', 'T', 'B')`, id, r.studioID, r.mgrID)

	if res := r.do(http.MethodDelete, "/me/notifications/"+id, nil); res.StatusCode != http.StatusNoContent {
		t.Fatalf("delete: want 204, got %d", res.StatusCode)
	}
	// Already gone → 404.
	if res := r.do(http.MethodDelete, "/me/notifications/"+id, nil); res.StatusCode != http.StatusNotFound {
		t.Fatalf("re-delete: want 404, got %d", res.StatusCode)
	}
}

// TestClearReadNotificationsRoute pins POST /me/notifications/clear-read:
// read rows are removed, unread rows survive, and the count is reported.
func TestClearReadNotificationsRoute(t *testing.T) {
	r := newRig(t)
	readID := store.NewID()
	unreadID := store.NewID()
	mustExec(t, r.server.store, `
		INSERT INTO notifications (id, studio_id, user_id, type, title, body, read_at)
		VALUES (?, ?, ?, 'system', 'T', 'B', strftime('%Y-%m-%dT%H:%M:%fZ','now'))`,
		readID, r.studioID, r.mgrID)
	mustExec(t, r.server.store, `
		INSERT INTO notifications (id, studio_id, user_id, type, title, body)
		VALUES (?, ?, ?, 'system', 'T', 'B')`, unreadID, r.studioID, r.mgrID)

	res := r.do(http.MethodPost, "/me/notifications/clear-read", nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("clear-read: want 200, got %d", res.StatusCode)
	}
	out := decode[map[string]int](t, res)
	if out["cleared"] != 1 {
		t.Fatalf("want cleared=1, got %v", out)
	}
}
