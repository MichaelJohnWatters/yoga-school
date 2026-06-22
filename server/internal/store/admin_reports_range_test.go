package store

import (
	"context"
	"testing"
	"time"
)

// insertPurchaseAt seeds a completed purchase for the fixture's student at a
// specific instant — used to land revenue inside or outside a report window.
func (f fixture) insertPurchaseAt(t *testing.T, s *Store, at time.Time, method string, amountMinor int) {
	t.Helper()
	id := NewID()
	productID := NewID()
	if _, err := s.db.ExecContext(context.Background(),
		`INSERT INTO products (id, studio_id, name, price_minor, billing_type, pass_kind, credits)
		 VALUES (?, ?, 'P', ?, 'one_time', 'credit', 1)`,
		productID, f.studioID, amountMinor); err != nil {
		t.Fatalf("insert product: %v", err)
	}
	if _, err := s.db.ExecContext(context.Background(),
		`INSERT INTO purchases
		   (id, studio_id, user_id, product_id, list_price_minor, amount_minor,
		    currency, payment_method, initiated_by, actor_role, status, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, 'GBP', ?, ?, 'manager', 'completed', ?)`,
		id, f.studioID, f.studentID, productID, amountMinor, amountMinor,
		method, f.studentID, at.UTC().Format(time.RFC3339)); err != nil {
		t.Fatalf("insert purchase: %v", err)
	}
}

func TestRevenueReportRange_SummaryAndBuckets(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	loc := s.StudioLocation(ctx, f.studioID)

	// Window: 2026-06-01 .. 2026-06-15 (exclusive), weekly buckets.
	from := time.Date(2026, 6, 1, 0, 0, 0, 0, loc)
	to := time.Date(2026, 6, 15, 0, 0, 0, 0, loc)

	f.insertPurchaseAt(t, s, time.Date(2026, 6, 2, 12, 0, 0, 0, loc), "card", 2000)
	f.insertPurchaseAt(t, s, time.Date(2026, 6, 9, 12, 0, 0, 0, loc), "cash", 500)
	// Outside the window — must be excluded.
	f.insertPurchaseAt(t, s, time.Date(2026, 5, 31, 23, 0, 0, 0, loc), "card", 9999)

	rep, err := s.RevenueReportRange(ctx, f.studioID, from, to, "week")
	if err != nil {
		t.Fatalf("RevenueReportRange: %v", err)
	}
	if rep.Month.CardMinor != 2000 || rep.Month.CashMinor != 500 {
		t.Fatalf("summary = card %d cash %d, want 2000/500", rep.Month.CardMinor, rep.Month.CashMinor)
	}
	if rep.Month.TotalMinor != 2500 {
		t.Fatalf("summary total = %d, want 2500", rep.Month.TotalMinor)
	}
	// 14-day window in weekly buckets → 2 buckets.
	if len(rep.ByWeek) != 2 {
		t.Fatalf("buckets = %d, want 2", len(rep.ByWeek))
	}
	if rep.ByWeek[0].CardMinor != 2000 || rep.ByWeek[0].CashMinor != 0 {
		t.Fatalf("bucket 0 = card %d cash %d, want 2000/0", rep.ByWeek[0].CardMinor, rep.ByWeek[0].CashMinor)
	}
	if rep.ByWeek[1].CashMinor != 500 {
		t.Fatalf("bucket 1 cash = %d, want 500", rep.ByWeek[1].CashMinor)
	}
	if rep.ByWeek[0].WeekStart != "2026-06-01" || rep.ByWeek[1].WeekStart != "2026-06-08" {
		t.Fatalf("bucket starts = %q,%q", rep.ByWeek[0].WeekStart, rep.ByWeek[1].WeekStart)
	}
}

func TestRevenueReportRange_DailyGranularity(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	loc := s.StudioLocation(ctx, f.studioID)
	from := time.Date(2026, 6, 1, 0, 0, 0, 0, loc)
	to := time.Date(2026, 6, 4, 0, 0, 0, 0, loc) // 3 days

	rep, err := s.RevenueReportRange(ctx, f.studioID, from, to, "day")
	if err != nil {
		t.Fatalf("RevenueReportRange: %v", err)
	}
	if len(rep.ByWeek) != 3 {
		t.Fatalf("daily buckets = %d, want 3", len(rep.ByWeek))
	}
}

func TestInstructorPayReportRange_CountsWindowedPastClasses(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	loc := s.StudioLocation(ctx, f.studioID)

	// Two past classes inside the window, one before it.
	from := time.Date(2026, 1, 1, 0, 0, 0, 0, loc)
	to := time.Date(2026, 2, 1, 0, 0, 0, 0, loc)
	f.insertClass(t, s, time.Date(2026, 1, 5, 9, 0, 0, 0, loc), 10)
	f.insertClass(t, s, time.Date(2026, 1, 20, 9, 0, 0, 0, loc), 10)
	f.insertClass(t, s, time.Date(2025, 12, 20, 9, 0, 0, 0, loc), 10) // outside

	rep, err := s.InstructorPayReportRange(ctx, f.studioID, from, to)
	if err != nil {
		t.Fatalf("InstructorPayReportRange: %v", err)
	}
	if len(rep.Rows) != 1 {
		t.Fatalf("instructor rows = %d, want 1", len(rep.Rows))
	}
	if rep.Rows[0].ClassesTaught != 2 {
		t.Fatalf("classes taught = %d, want 2", rep.Rows[0].ClassesTaught)
	}
	if rep.Rows[0].PayMinor != 2*defaultRatePerClassMinor {
		t.Fatalf("pay = %d, want %d", rep.Rows[0].PayMinor, 2*defaultRatePerClassMinor)
	}
}

func TestAttendanceReportRange_NoShowWindowed(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	loc := s.StudioLocation(ctx, f.studioID)

	from := time.Date(2026, 1, 1, 0, 0, 0, 0, loc)
	to := time.Date(2026, 2, 1, 0, 0, 0, 0, loc)
	classID := f.insertClass(t, s, time.Date(2026, 1, 10, 9, 0, 0, 0, loc), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	// One attended, one no-show on the same class.
	f.insertBookedSeat(t, s, classID, ent)
	noShowID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO bookings (id, studio_id, class_id, user_id, entitlement_id,
		   is_plus_one, booked_by_role, cancel_cutoff_hours, status, checkin_token)
		   VALUES (?, ?, ?, ?, ?, 0, 'student', 12, 'no_show', ?)`,
		noShowID, f.studioID, classID, f.studentID, ent, NewID()); err != nil {
		t.Fatalf("insert no-show: %v", err)
	}

	rep, err := s.AttendanceReportRange(ctx, f.studioID, from, to)
	if err != nil {
		t.Fatalf("AttendanceReportRange: %v", err)
	}
	// 2 of 2 past bookings, 1 no-show → 50%.
	if rep.NoShowRatePct != 50 {
		t.Fatalf("no-show rate = %d, want 50", rep.NoShowRatePct)
	}
}
