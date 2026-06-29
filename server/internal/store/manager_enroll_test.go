package store

import (
	"context"
	"testing"
)

// A manager enrolling a student into a series mints the entitlement, books
// every future session, records a completed purchase attributed to the manager,
// and audits series_manager_enroll. Capacity + duplicate enrolment are enforced.
func TestManagerEnrollStudent(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	series := seedTestSeries(t, s, f, 2) // capacity 2

	bookingID, err := s.ManagerEnrollStudent(
		ctx, f.studioID, f.instructorID, series.EnrollmentID, f.studentID, "comp", "")
	if err != nil {
		t.Fatalf("ManagerEnrollStudent: %v", err)
	}
	if bookingID == "" {
		t.Fatal("expected an enrollment_booking id")
	}

	var eb, bk int
	s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM enrollment_bookings WHERE enrollment_id=? AND user_id=? AND status='active'`,
		series.EnrollmentID, f.studentID).Scan(&eb)
	s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM bookings WHERE user_id=?`, f.studentID).Scan(&bk)
	if eb != 1 {
		t.Errorf("enrollment_bookings = %d, want 1", eb)
	}
	if bk != 3 {
		t.Errorf("session bookings = %d, want 3", bk)
	}

	// Purchase attributes to the acting manager, paid via comp.
	var actorRole, initiatedBy, pm, status string
	if err := s.db.QueryRowContext(ctx, `
		SELECT actor_role, initiated_by, payment_method, status
		  FROM purchases
		 WHERE user_id=? AND resulting_entitlement_id IS NOT NULL`,
		f.studentID).Scan(&actorRole, &initiatedBy, &pm, &status); err != nil {
		t.Fatalf("read purchase: %v", err)
	}
	if actorRole != "manager" || initiatedBy != f.instructorID || pm != "comp" || status != "completed" {
		t.Errorf("purchase: role=%s by=%s pm=%s status=%s; want manager/%s/comp/completed",
			actorRole, initiatedBy, pm, status, f.instructorID)
	}
	if n := auditCount(t, s, f.studioID, "series_manager_enroll"); n != 1 {
		t.Errorf("series_manager_enroll audit = %d, want 1", n)
	}

	// Re-enrolling the same student → ErrAlreadyEnrolled.
	if _, err := s.ManagerEnrollStudent(
		ctx, f.studioID, f.instructorID, series.EnrollmentID, f.studentID, "comp", ""); err != ErrAlreadyEnrolled {
		t.Errorf("re-enroll err = %v, want ErrAlreadyEnrolled", err)
	}

	// Fill the last seat, then a third student → ErrSeriesFull.
	other := insertOtherStudent(t, s, f.studioID)
	if _, err := s.ManagerEnrollStudent(
		ctx, f.studioID, f.instructorID, series.EnrollmentID, other, "cash", ""); err != nil {
		t.Fatalf("fill seat: %v", err)
	}
	third := insertOtherStudent(t, s, f.studioID)
	if _, err := s.ManagerEnrollStudent(
		ctx, f.studioID, f.instructorID, series.EnrollmentID, third, "cash", ""); err != ErrSeriesFull {
		t.Errorf("over-capacity err = %v, want ErrSeriesFull", err)
	}
}
