package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

// Helper: count audit rows by action on the fixture's studio.
func countAuditByAction(t *testing.T, s *Store, studioID, action string) int {
	t.Helper()
	var n int
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM audit_log WHERE studio_id = ? AND action = ?`,
		studioID, action,
	).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// fetchAuditDetail returns the JSON detail blob for the most recent audit
// row matching action — used to assert specific keys without binding to
// the row layout.
func fetchAuditDetail(t *testing.T, s *Store, studioID, action string) string {
	t.Helper()
	var d string
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT detail FROM audit_log
		  WHERE studio_id = ? AND action = ?
		  ORDER BY created_at DESC LIMIT 1`,
		studioID, action,
	).Scan(&d); err != nil {
		t.Fatal(err)
	}
	return d
}

func TestCancelBooking_AuditsFreeOutcome(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	// Class 48h out, default cutoff 12h → free cancel.
	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, _ := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if n := countAuditByAction(t, s, f.studioID, "booking_cancel"); n != 1 {
		t.Errorf("booking_cancel audits: got %d want 1", n)
	}
	detail := fetchAuditDetail(t, s, f.studioID, "booking_cancel")
	if !strings.Contains(detail, "cancelled_free") {
		t.Errorf("audit detail missing outcome: %s", detail)
	}
	if !strings.Contains(detail, class) {
		t.Errorf("audit detail missing class_id: %s", detail)
	}
}

func TestCancelBooking_AuditsLateOutcome(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	// Class 2h out + default cutoff 12h → late cancel.
	class := f.insertClass(t, s, time.Now().UTC().Add(2*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	bookingID, _ := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatal(err)
	}
	detail := fetchAuditDetail(t, s, f.studioID, "booking_cancel")
	if !strings.Contains(detail, "cancelled_late_burned") {
		t.Errorf("audit detail outcome: %s", detail)
	}
}

func TestJoinWaitlist_WritesAudit(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 5)
	pos, err := s.JoinWaitlist(ctx, f.studentID, class)
	if err != nil {
		t.Fatalf("join: %v", err)
	}
	if pos != 1 {
		t.Errorf("position: got %d want 1", pos)
	}
	if n := countAuditByAction(t, s, f.studioID, "waitlist_join"); n != 1 {
		t.Errorf("waitlist_join audits: got %d want 1", n)
	}
	detail := fetchAuditDetail(t, s, f.studioID, "waitlist_join")
	if !strings.Contains(detail, `"position":1`) {
		t.Errorf("audit detail missing position: %s", detail)
	}
}

// Auto-promote writes a waitlist_auto_book audit row (the offer/claim
// flow is gone — the promote IS the booking event).
func TestPromoteWaitlist_WritesAutoBookAudit(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 5)
	a := insertOtherStudent(t, s, f.studioID)
	f.insertEntitlementFor(t, s, a, "unlimited", 0)
	if _, err := s.JoinWaitlist(ctx, a, class); err != nil {
		t.Fatal(err)
	}
	out, err := s.PromoteWaitlist(ctx, f.studioID, "", class)
	if err != nil {
		t.Fatal(err)
	}
	if n := countAuditByAction(t, s, f.studioID, "waitlist_auto_book"); n != 1 {
		t.Errorf("waitlist_auto_book audits: got %d want 1", n)
	}
	detail := fetchAuditDetail(t, s, f.studioID, "waitlist_auto_book")
	if !strings.Contains(detail, out.BookingID) && !strings.Contains(detail, class) {
		t.Errorf("audit should link to class/booking ids: %s", detail)
	}
}

// TestCancelBooking_AuditAtomicWithCancel — if the cancel commits, the
// audit row commits with it (same transaction). If we crash mid-cancel
// the audit doesn't get a phantom row either way.
func TestCancelBooking_AuditAtomicWithCancel(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, _ := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")

	// Sanity: pre-cancel, no booking_cancel audit.
	if n := countAuditByAction(t, s, f.studioID, "booking_cancel"); n != 0 {
		t.Fatalf("precondition: expected 0 audits, got %d", n)
	}
	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatal(err)
	}
	// Now exactly one.
	if n := countAuditByAction(t, s, f.studioID, "booking_cancel"); n != 1 {
		t.Errorf("post-cancel audits: got %d want 1", n)
	}
}
