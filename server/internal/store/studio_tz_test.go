package store

import (
	"context"
	"testing"
	"time"
)

// setStudioTZ flips a fixture studio's timezone to the given IANA name and
// invalidates the location cache so subsequent reads see the change.
// Returns the *time.Location for callers that want to construct test times.
func setStudioTZ(t *testing.T, s *Store, studioID, tz string) *time.Location {
	t.Helper()
	if _, err := s.db.ExecContext(context.Background(),
		`UPDATE studios SET timezone = ? WHERE id = ?`, tz, studioID,
	); err != nil {
		t.Fatal(err)
	}
	InvalidateStudioLocation(studioID)
	loc, err := time.LoadLocation(tz)
	if err != nil {
		t.Skipf("tzdata missing for %s: %v", tz, err)
	}
	return loc
}

// TestClassesForDay_HonoursStudioTZ — parametric test (ClassesForDay takes a
// day argument explicitly). Insert a class at Sydney 2026-06-15 01:00 (which
// is UTC 2026-06-14 15:00). The Sydney studio's "2026-06-15" must include
// it; "2026-06-14" must NOT. A UTC implementation would place the class on
// the 14th and fail both assertions.
func TestClassesForDay_HonoursStudioTZ(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	syd := setStudioTZ(t, s, f.studioID, "Australia/Sydney")

	sydMorning := time.Date(2026, 6, 15, 1, 0, 0, 0, syd)
	classID := f.insertClass(t, s, sydMorning, 10)

	// Sydney's 2026-06-15 — must contain the class.
	queryDay := time.Date(2026, 6, 15, 12, 0, 0, 0, syd)
	rows, err := s.ClassesForDay(ctx, f.studioID, f.studentID, queryDay)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].ID != classID {
		t.Errorf("Sydney's 2026-06-15 should contain the class; got %d rows", len(rows))
	}

	// Sydney's 2026-06-14 — must NOT contain it (UTC's would).
	priorDay := time.Date(2026, 6, 14, 12, 0, 0, 0, syd)
	rows, err = s.ClassesForDay(ctx, f.studioID, f.studentID, priorDay)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Errorf("Sydney's 2026-06-14 should be empty; got %d rows", len(rows))
	}
}

// TestAdminDashboardFor_HonoursStudioTZ — AdminDashboardFor anchors on
// time.Now() in studio TZ. Insert a class at Sydney 09:00 today (which is
// UTC ~23:00 yesterday in winter). A Sydney studio's dashboard must
// include this class in OccupancyToday.TotalCapacity; a UTC implementation
// would exclude it because the UTC date doesn't match.
func TestAdminDashboardFor_HonoursStudioTZ(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	syd := setStudioTZ(t, s, f.studioID, "Australia/Sydney")

	sydNow := time.Now().In(syd)
	sydMorning := time.Date(sydNow.Year(), sydNow.Month(), sydNow.Day(), 9, 0, 0, 0, syd)
	f.insertClass(t, s, sydMorning, 10)

	dash, err := s.AdminDashboardFor(ctx, f.studioID, f.studentID)
	if err != nil {
		t.Fatal(err)
	}
	if dash.OccupancyToday.TotalCapacity < 10 {
		t.Errorf("Sydney 'today' should include the 09:00 class; cap=%d",
			dash.OccupancyToday.TotalCapacity)
	}
}

// TestMyAttendance_HonoursStudioTZ — MyAttendance's "this month" anchor is
// the 1st of the month in studio TZ. Smoke test: with a Sydney studio + a
// past attended class today, ThisMonth must include it. Reverting the
// implementation to UTC would still pass this test on most days, but the
// helper unit tests already lock down the boundary semantics — this one
// just guards against a revert that breaks plain operation.
func TestMyAttendance_HonoursStudioTZ(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	syd := setStudioTZ(t, s, f.studioID, "Australia/Sydney")

	// Insert a past class today (Sydney) at 06:00 — far enough back to be
	// past regardless of when the test runs, but still on Sydney's today.
	// Actually safer: pick 4 hours ago in Sydney, so the class is reliably
	// in the past and reliably in today.
	sydPast := time.Now().In(syd).Add(-4 * time.Hour)
	classID := f.insertClass(t, s, sydPast, 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID := f.insertBookedSeat(t, s, classID, ent)
	if err := s.MarkAttendance(ctx, "actor-test", bookingID, "attended", "manual"); err != nil {
		t.Fatal(err)
	}

	summary, err := s.MyAttendance(ctx, f.studentID)
	if err != nil {
		t.Fatal(err)
	}
	if summary.ThisMonth < 1 {
		t.Errorf("Sydney 'this month' should include today's attended class; got %d",
			summary.ThisMonth)
	}
	if summary.AllTime < 1 {
		t.Errorf("AllTime should include today's attended class; got %d", summary.AllTime)
	}
}

// TestAdminReportsFor_HonoursStudioTZ — AdminReportsFor uses the same
// studio-TZ monthStart as MyAttendance. Smoke test: a Sydney studio with a
// completed purchase today reports the purchase under this month's revenue.
func TestAdminReportsFor_HonoursStudioTZ(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	setStudioTZ(t, s, f.studioID, "Australia/Sydney")

	// Insert a completed purchase. amount_minor 5000 = £50.
	productID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO products (id, studio_id, name, price_minor, billing_type, pass_kind)
		VALUES (?, ?, 'P', 5000, 'one_time', 'unlimited')`,
		productID, f.studioID,
	); err != nil {
		t.Fatal(err)
	}
	purchaseID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO purchases
		    (id, studio_id, user_id, product_id, list_price_minor, amount_minor, currency,
		     payment_method, initiated_by, actor_role, status)
		VALUES (?, ?, ?, ?, 5000, 5000, 'GBP', 'card', ?, 'student', 'completed')`,
		purchaseID, f.studioID, f.studentID, productID, f.studentID,
	); err != nil {
		t.Fatal(err)
	}

	rep, err := s.AdminReportsFor(ctx, f.studioID)
	if err != nil {
		t.Fatal(err)
	}
	if rep.RevenueMonth.TotalMinor < 5000 {
		t.Errorf("Sydney 'this month' revenue should include today's £50 card purchase; got %d",
			rep.RevenueMonth.TotalMinor)
	}
}
