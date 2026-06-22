package store

import (
	"context"
	"testing"
	"time"
)

func TestMyNotificationPrefs_AbsentRowReturnsAllTrue(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	p, err := s.MyNotificationPrefs(ctx, f.studentID)
	if err != nil {
		t.Fatal(err)
	}
	// All-true is the spec's "absence of row → opt in to everything"
	// rule. If any toggle defaults to false, a brand-new user would miss
	// notifications they never opted out of.
	if !p.BookingConfirmed || !p.ClassCancelled || !p.WaitlistPromoted ||
		!p.Promotions || !p.System {
		t.Errorf("default prefs should be all true: %+v", *p)
	}
}

func TestUpdateNotificationPrefs_PartialPatchPreservesOthers(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	off := false
	out, err := s.UpdateNotificationPrefs(ctx, f.studentID, NotificationPrefsPatch{
		Promotions: &off,
	})
	if err != nil {
		t.Fatal(err)
	}
	if out.Promotions {
		t.Error("promotions: opt-out not applied")
	}
	// The four categories not in the patch should stay at their default
	// (true) — partial PATCH must not nuke other toggles.
	if !out.BookingConfirmed || !out.ClassCancelled || !out.WaitlistPromoted || !out.System {
		t.Errorf("other prefs were reset by partial patch: %+v", *out)
	}
}

func TestUpdateNotificationPrefs_RoundTrip(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	off := false
	if _, err := s.UpdateNotificationPrefs(ctx, f.studentID, NotificationPrefsPatch{
		BookingConfirmed: &off,
		Promotions:       &off,
	}); err != nil {
		t.Fatal(err)
	}
	got, err := s.MyNotificationPrefs(ctx, f.studentID)
	if err != nil {
		t.Fatal(err)
	}
	if got.BookingConfirmed || got.Promotions {
		t.Errorf("opt-outs not persisted: %+v", *got)
	}
	if !got.ClassCancelled || !got.WaitlistPromoted || !got.System {
		t.Errorf("other prefs flipped: %+v", *got)
	}
}

func TestCreateBooking_RespectsBookingConfirmedOptOut(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Opt out of booking_confirmed.
	off := false
	if _, err := s.UpdateNotificationPrefs(ctx, f.studentID, NotificationPrefsPatch{
		BookingConfirmed: &off,
	}); err != nil {
		t.Fatal(err)
	}

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, ""); err != nil {
		t.Fatalf("book: %v", err)
	}

	var n int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM notifications WHERE user_id = ? AND type = 'booking_confirmed'`,
		f.studentID,
	).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("opted-out user got %d booking_confirmed notifs; want 0", n)
	}
}

func TestCancelAdminClass_RespectsClassCancelledOptOut(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, ""); err != nil {
		t.Fatal(err)
	}

	off := false
	if _, err := s.UpdateNotificationPrefs(ctx, f.studentID, NotificationPrefsPatch{
		ClassCancelled: &off,
	}); err != nil {
		t.Fatal(err)
	}

	if _, err := s.CancelAdminClass(ctx, f.studioID, class); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM notifications WHERE user_id = ? AND type = 'class_cancelled'`,
		f.studentID,
	).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("opted-out user got %d class_cancelled notifs; want 0", n)
	}
}
