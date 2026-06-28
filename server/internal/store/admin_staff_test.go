package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestListAdminStaff_IncludesInstructorAndExcludesStudents(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	rows, err := s.ListAdminStaff(ctx, f.studioID)
	if err != nil {
		t.Fatalf("ListAdminStaff: %v", err)
	}
	var foundInstructor, foundStudent bool
	for _, m := range rows {
		if m.ID == f.instructorID {
			foundInstructor = true
		}
		if m.ID == f.studentID {
			foundStudent = true
		}
	}
	if !foundInstructor {
		t.Error("fixture instructor missing from staff list")
	}
	if foundStudent {
		t.Error("student leaked into staff list")
	}
}

func TestCreateStaff_PersistsValidRoles(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	for _, role := range []string{"instructor", "manager", "owner"} {
		id, err := s.CreateStaff(ctx, f.studioID, f.instructorID, StaffInput{
			Role: role, Email: role + "@studio.com", FullName: "Staff " + role,
		})
		if err != nil {
			t.Errorf("create %s: %v", role, err)
			continue
		}
		if id == "" {
			t.Errorf("create %s: empty id", role)
		}
	}
}

func TestCreateStaff_RejectsInvalidRole(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	for _, role := range []string{"student", "", "admin", "owner "} {
		if _, err := s.CreateStaff(ctx, f.studioID, f.instructorID, StaffInput{
			Role: role, Email: "x@y.com", FullName: "X",
		}); err == nil {
			t.Errorf("role=%q: expected error, got nil", role)
		}
	}
}

func TestCreateStaff_RejectsMissingFields(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	cases := []StaffInput{
		{Role: "instructor", Email: "", FullName: "X"},
		{Role: "instructor", Email: "x@y.com", FullName: ""},
		{Role: "instructor", Email: "   ", FullName: "X"},
	}
	for i, in := range cases {
		if _, err := s.CreateStaff(ctx, f.studioID, f.instructorID, in); err == nil {
			t.Errorf("case %d: expected error for %+v", i, in)
		}
	}
}

func TestCreateStaff_RejectsDuplicateEmail(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	in := StaffInput{Role: "instructor", Email: "dup@studio.com", FullName: "Dup"}
	if _, err := s.CreateStaff(ctx, f.studioID, f.instructorID, in); err != nil {
		t.Fatalf("first: %v", err)
	}
	_, err := s.CreateStaff(ctx, f.studioID, f.instructorID, in)
	if err == nil {
		t.Fatal("expected duplicate email error, got nil")
	}
	if !strings.Contains(err.Error(), "email") {
		t.Errorf("error should mention email: %v", err)
	}
}

func TestUpdateStaff_ChangesRoleAndName(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, _ := s.CreateStaff(ctx, f.studioID, f.instructorID, StaffInput{
		Role: "instructor", Email: "u@studio.com", FullName: "Una",
	})
	if err := s.UpdateStaff(ctx, f.studioID, f.instructorID, id, StaffInput{
		Role: "manager", Email: "u@studio.com", FullName: "Una Manager",
	}); err != nil {
		t.Fatalf("UpdateStaff: %v", err)
	}
	rows, _ := s.ListAdminStaff(ctx, f.studioID)
	for _, m := range rows {
		if m.ID == id {
			if m.Role != "manager" || m.FullName != "Una Manager" {
				t.Errorf("after update: %+v", m)
			}
			return
		}
	}
	t.Fatal("staff member vanished after update")
}

func TestUpdateStaff_NotFoundForStudent(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Trying to update the student via the staff endpoint should not match
	// (the WHERE clause excludes role='student').
	err := s.UpdateStaff(ctx, f.studioID, f.instructorID, f.studentID, StaffInput{
		Role: "manager", Email: "student@test.com", FullName: "Student",
	})
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("update student via staff endpoint: got %v want ErrNotFound", err)
	}
}

// TestInstructorPayRate_OverridesDefaultInReport verifies the per-instructor
// rate from the users table flows all the way into the report payload, and
// that the fallback default applies when the column is NULL.
func TestInstructorPayRate_OverridesDefaultInReport(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Custom rate of £42/class on the fixture instructor.
	custom := 4200
	if err := s.UpdateStaff(ctx, f.studioID, f.instructorID, f.instructorID, StaffInput{
		Role: "instructor", Email: "inst@test.com", FullName: "Inst",
		PayRateMinor: &custom,
	}); err != nil {
		t.Fatalf("UpdateStaff: %v", err)
	}

	// Plant one past class taught by this instructor in the current month.
	classID := NewID()
	start := time.Now().UTC().Add(-2 * time.Hour)
	end := start.Add(1 * time.Hour)
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO classes
		    (id, studio_id, class_type_id, instructor_id, room_id, title,
		     starts_at, ends_at, capacity, status)
		    VALUES (?, ?, ?, ?, ?, 'Past', ?, ?, 10, 'scheduled')`,
		classID, f.studioID, f.classTypeID, f.instructorID, f.roomID,
		start.Format(time.RFC3339), end.Format(time.RFC3339),
	); err != nil {
		t.Fatal(err)
	}

	rep, err := s.AdminReportsFor(ctx, f.studioID)
	if err != nil {
		t.Fatalf("reports: %v", err)
	}
	var got *ReportInstructorPay
	for i := range rep.InstructorPay {
		if rep.InstructorPay[i].InstructorID == f.instructorID {
			got = &rep.InstructorPay[i]
			break
		}
	}
	if got == nil {
		t.Fatalf("instructor missing from report: %+v", rep.InstructorPay)
	}
	if got.RateMinor != custom {
		t.Errorf("rate_minor: got %d want %d (per-instructor override)", got.RateMinor, custom)
	}
	if got.ClassesTaught == 0 || got.PayMinor != got.ClassesTaught*custom {
		t.Errorf("pay calc: %+v (custom rate %d)", *got, custom)
	}
}

func TestSetStaffActive_DeactivateReactivate(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, _ := s.CreateStaff(ctx, f.studioID, f.instructorID, StaffInput{
		Role: "instructor", Email: "leaver@studio.com", FullName: "Leaver",
	})

	if err := s.SetStaffActive(ctx, f.studioID, f.instructorID, id, false); err != nil {
		t.Fatalf("deactivate: %v", err)
	}
	if got := auditCount(t, s, f.studioID, "staff_deactivate"); got != 1 {
		t.Errorf("staff_deactivate audit = %d, want 1", got)
	}
	if active := staffActive(t, s, f.studioID, id); active {
		t.Error("member still active after deactivate")
	}
	// Deactivated instructor is hidden from the class-creation picker.
	insts, _ := s.ListAdminInstructors(ctx, f.studioID)
	for _, in := range insts {
		if in.ID == id {
			t.Error("deactivated instructor still in the picker")
		}
	}

	if err := s.SetStaffActive(ctx, f.studioID, f.instructorID, id, true); err != nil {
		t.Fatalf("reactivate: %v", err)
	}
	if got := auditCount(t, s, f.studioID, "staff_reactivate"); got != 1 {
		t.Errorf("staff_reactivate audit = %d, want 1", got)
	}
	if active := staffActive(t, s, f.studioID, id); !active {
		t.Error("member not active after reactivate")
	}
}

func TestSetStaffActive_RejectsSelfDeactivate(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, _ := s.CreateStaff(ctx, f.studioID, f.instructorID, StaffInput{
		Role: "manager", Email: "self@studio.com", FullName: "Self",
	})
	if err := s.SetStaffActive(ctx, f.studioID, id, id, false); err == nil {
		t.Error("expected error deactivating self, got nil")
	}
}

func TestSetStaffActive_RejectsLastOwner(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	ownerID, _ := s.CreateStaff(ctx, f.studioID, f.instructorID, StaffInput{
		Role: "owner", Email: "owner@studio.com", FullName: "Owner",
	})
	// Only owner in the studio → can't deactivate.
	if err := s.SetStaffActive(ctx, f.studioID, f.instructorID, ownerID, false); err == nil {
		t.Error("expected last-owner guard error, got nil")
	}
	// Add a second owner → now the first can be deactivated.
	owner2, _ := s.CreateStaff(ctx, f.studioID, f.instructorID, StaffInput{
		Role: "owner", Email: "owner2@studio.com", FullName: "Owner Two",
	})
	if err := s.SetStaffActive(ctx, f.studioID, owner2, ownerID, false); err != nil {
		t.Errorf("deactivate owner with a spare owner present: %v", err)
	}
}

func staffActive(t *testing.T, s *Store, studioID, id string) bool {
	t.Helper()
	rows, err := s.ListAdminStaff(context.Background(), studioID)
	if err != nil {
		t.Fatalf("ListAdminStaff: %v", err)
	}
	for _, m := range rows {
		if m.ID == id {
			return m.Active
		}
	}
	t.Fatalf("staff %s not found", id)
	return false
}

func TestUpdateStaff_NotFoundCrossStudio(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, _ := s.CreateStaff(ctx, f.studioID, f.instructorID, StaffInput{
		Role: "instructor", Email: "v@studio.com", FullName: "V",
	})
	err := s.UpdateStaff(ctx, "other-studio", f.instructorID, id, StaffInput{
		Role: "manager", Email: "v@studio.com", FullName: "V",
	})
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("cross-studio update: got %v want ErrNotFound", err)
	}
}
