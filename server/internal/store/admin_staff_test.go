package store

import (
	"context"
	"errors"
	"strings"
	"testing"
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
