package store

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeDispatcher captures push calls so tests can assert who got pushed and
// with what payload. Thread-safe — the real dispatcher fires in a goroutine
// and tests should sleep-poll, but since the store calls Dispatch
// synchronously after commit, the mutex covers the post-commit case.
type fakeDispatcher struct {
	mu    sync.Mutex
	calls []dispatchedPush
}

type dispatchedPush struct {
	userID, notifType, title, body, payloadJSON string
}

func (f *fakeDispatcher) Dispatch(userID, notifType, title, body, payloadJSON string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, dispatchedPush{
		userID:      userID,
		notifType:   notifType,
		title:       title,
		body:        body,
		payloadJSON: payloadJSON,
	})
}

func (f *fakeDispatcher) Calls() []dispatchedPush {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]dispatchedPush, len(f.calls))
	copy(out, f.calls)
	return out
}

func TestCreateBooking_DispatchesPush(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	d := &fakeDispatcher{}
	s.SetPushDispatcher(d)
	ctx := context.Background()
	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, ""); err != nil {
		t.Fatal(err)
	}
	calls := d.Calls()
	if len(calls) != 1 {
		t.Fatalf("dispatch calls: got %d want 1", len(calls))
	}
	c := calls[0]
	if c.userID != f.studentID {
		t.Errorf("userID: got %s want %s", c.userID, f.studentID)
	}
	if c.notifType != "booking_confirmed" {
		t.Errorf("notifType: got %s", c.notifType)
	}
	if !strings.Contains(c.payloadJSON, class) {
		t.Errorf("payload missing class_id: %s", c.payloadJSON)
	}
}

func TestCreateBooking_OptedOutSkipsPush(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	d := &fakeDispatcher{}
	s.SetPushDispatcher(d)
	ctx := context.Background()

	// Pre-write a notification_prefs row with booking_confirmed = 0.
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO notification_prefs (user_id, booking_confirmed)
		VALUES (?, 0)`, f.studentID,
	); err != nil {
		t.Fatal(err)
	}

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, ""); err != nil {
		t.Fatal(err)
	}
	if got := len(d.Calls()); got != 0 {
		t.Errorf("opted-out: expected 0 push, got %d", got)
	}
}

func TestPromoteWaitlist_DispatchesPush(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	d := &fakeDispatcher{}
	s.SetPushDispatcher(d)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 5)
	a := insertOtherStudent(t, s, f.studioID)
	f.insertEntitlementFor(t, s, a, "unlimited", 0)
	if _, err := s.JoinWaitlist(ctx, a, class); err != nil {
		t.Fatal(err)
	}
	if _, err := s.PromoteWaitlist(ctx, f.studioID, "", class); err != nil {
		t.Fatal(err)
	}
	calls := d.Calls()
	if len(calls) != 1 {
		t.Fatalf("dispatch calls: got %d want 1", len(calls))
	}
	if calls[0].notifType != "waitlist_promoted" {
		t.Errorf("notifType: got %s", calls[0].notifType)
	}
	if calls[0].userID != a {
		t.Errorf("userID: got %s want %s", calls[0].userID, a)
	}
}

// TestPromoteWaitlist_AutoBookPayload locks down the contents of the push
// fired on auto-promote — it now signals the booking directly, not an
// offer to claim.
func TestPromoteWaitlist_AutoBookPayload(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	d := &fakeDispatcher{}
	s.SetPushDispatcher(d)
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
	calls := d.Calls()
	if len(calls) != 1 {
		t.Fatalf("dispatch calls: got %d want 1", len(calls))
	}
	if calls[0].notifType != "waitlist_promoted" {
		t.Errorf("push type: got %s want waitlist_promoted", calls[0].notifType)
	}
	if calls[0].title != "You're booked from the waitlist" {
		t.Errorf("push title drift: %q", calls[0].title)
	}
	if !strings.Contains(calls[0].payloadJSON, out.BookingID) {
		t.Errorf("payload should carry booking id %s, got %s",
			out.BookingID, calls[0].payloadJSON)
	}
}

// TestCancelAdminClass_DispatchesPushPerBooker — closing the fourth notif
// site. A class with two bookers gets two pushes; a booker opted out of
// class_cancelled drops out of the push list (matching the in-app row
// suppression behaviour).
func TestCancelAdminClass_DispatchesPushPerBooker(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	d := &fakeDispatcher{}
	s.SetPushDispatcher(d)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(36*time.Hour), 5)

	// Booker A: opted in (default).
	entA := f.insertEntitlement(t, s, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, entA, false, ""); err != nil {
		t.Fatal(err)
	}
	// Booker B: opted in.
	b := insertOtherStudent(t, s, f.studioID)
	entB := f.insertEntitlementFor(t, s, b, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, b, class, entB, false, ""); err != nil {
		t.Fatal(err)
	}
	// Booker C: opt out of class_cancelled.
	c := insertOtherStudent(t, s, f.studioID)
	entC := f.insertEntitlementFor(t, s, c, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, c, class, entC, false, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO notification_prefs (user_id, class_cancelled)
		VALUES (?, 0)`, c,
	); err != nil {
		t.Fatal(err)
	}

	// Reset dispatcher so we only see the cancel pushes.
	d.calls = nil

	if _, err := s.CancelAdminClass(ctx, f.studioID, class); err != nil {
		t.Fatal(err)
	}

	calls := d.Calls()
	if len(calls) != 2 {
		t.Fatalf("expected 2 cancel pushes (C opted out); got %d", len(calls))
	}
	pushed := map[string]bool{}
	for _, c := range calls {
		if c.notifType != "class_cancelled" {
			t.Errorf("notifType: got %s", c.notifType)
		}
		pushed[c.userID] = true
	}
	if !pushed[f.studentID] || !pushed[b] {
		t.Errorf("expected pushes to A and B; got %v", pushed)
	}
	if pushed[c] {
		t.Error("opted-out booker C should not have been pushed")
	}
}

func TestNilDispatcher_NoCrash(t *testing.T) {
	// Default state — no dispatcher wired. Should still complete bookings
	// without panicking or erroring.
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, ""); err != nil {
		t.Errorf("createBooking with nil dispatcher: %v", err)
	}
}
