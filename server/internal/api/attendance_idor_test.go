package api

import (
	"context"
	"io"
	"net/http"
	"testing"

	"github.com/studio52/yoga-school/server/internal/store"
)

// TestAPI_MarkAttendance_CrossTenantRejected is the end-to-end guard for the
// cross-tenant IDOR fix on POST /admin/bookings/{id}/attendance. A manager
// authenticated against studio A must not be able to flip a booking that lives
// in studio B: the store scopes the update to the caller's studio, so the
// handler returns 404 and the foreign booking is left untouched.
func TestAPI_MarkAttendance_CrossTenantRejected(t *testing.T) {
	r := newRig(t) // default identity is the studio-A manager
	s := r.server.store
	ctx := context.Background()

	// Seed an independent studio B with a single booked seat.
	studioB := store.NewID()
	mustExec(t, s, `INSERT INTO studios (id, name, welcome_message)
		VALUES (?, 'Studio B', 'Welcome')`, studioB)
	userB := store.NewID()
	mustExec(t, s, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'student', 'b-student@test.com', 'B Student')`, userB, studioB)
	classTypeB := store.NewID()
	mustExec(t, s, `INSERT INTO class_types (id, studio_id, name)
		VALUES (?, ?, 'Yoga B')`, classTypeB, studioB)
	classB := store.NewID()
	mustExec(t, s, `INSERT INTO classes
		(id, studio_id, class_type_id, starts_at, ends_at, capacity)
		VALUES (?, ?, ?, '2026-01-01T10:00:00.000Z', '2026-01-01T11:00:00.000Z', 10)`,
		classB, studioB, classTypeB)
	entB := store.NewID()
	mustExec(t, s, `INSERT INTO entitlements (id, studio_id, user_id, pass_kind, label)
		VALUES (?, ?, ?, 'credit', '5-pack')`, entB, studioB, userB)
	bookingB := store.NewID()
	mustExec(t, s, `INSERT INTO bookings
		(id, studio_id, class_id, user_id, entitlement_id, booked_by_role,
		 cancel_cutoff_hours, status)
		VALUES (?, ?, ?, ?, ?, 'student', 12, 'booked')`,
		bookingB, studioB, classB, userB, entB)

	res := r.do(http.MethodPost, "/admin/bookings/"+bookingB+"/attendance",
		map[string]any{"status": "no_show"})
	if res.StatusCode != http.StatusNotFound {
		body, _ := io.ReadAll(res.Body)
		t.Fatalf("cross-tenant attendance mark: got %d want 404 body=%s", res.StatusCode, body)
	}

	var status string
	if err := s.DB().QueryRowContext(ctx,
		`SELECT status FROM bookings WHERE id = ?`, bookingB).Scan(&status); err != nil {
		t.Fatalf("read back booking: %v", err)
	}
	if status != "booked" {
		t.Fatalf("cross-tenant mark mutated studio B's booking: status=%q, want booked", status)
	}
}
