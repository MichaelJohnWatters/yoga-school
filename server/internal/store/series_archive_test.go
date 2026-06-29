package store

import (
	"context"
	"testing"
)

// Archiving a series hides it from the student feed but keeps it on the manager
// list (flagged archived), is audited, and is idempotent.
func TestArchiveEnrollment(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	series := seedTestSeries(t, s, f, 5)

	// Visible to students before archiving.
	before, err := s.ListEnrollments(ctx, f.studioID, f.studentID, false)
	if err != nil {
		t.Fatalf("ListEnrollments: %v", err)
	}
	if !containsEnrollment(before, series.EnrollmentID) {
		t.Fatal("series should be on the student feed before archiving")
	}

	if err := s.ArchiveEnrollment(ctx, f.studioID, f.instructorID, series.EnrollmentID); err != nil {
		t.Fatalf("ArchiveEnrollment: %v", err)
	}

	// Gone from the student feed.
	after, err := s.ListEnrollments(ctx, f.studioID, f.studentID, false)
	if err != nil {
		t.Fatalf("ListEnrollments: %v", err)
	}
	if containsEnrollment(after, series.EnrollmentID) {
		t.Error("archived series must not appear on the student feed")
	}

	// Still visible to the manager, flagged archived.
	admin, err := s.ListEnrollments(ctx, f.studioID, "", true)
	if err != nil {
		t.Fatalf("ListEnrollments(includeArchived): %v", err)
	}
	var found *EnrollmentSummary
	for i := range admin {
		if admin[i].ID == series.EnrollmentID {
			found = &admin[i]
		}
	}
	if found == nil {
		t.Fatal("archived series must still appear on the manager list")
	}
	if found.ArchivedAt == nil || *found.ArchivedAt == "" {
		t.Error("manager list should carry archived_at for an archived series")
	}

	if n := auditCount(t, s, f.studioID, "series_archive"); n != 1 {
		t.Errorf("series_archive audit = %d, want 1", n)
	}

	// Idempotent: archiving again succeeds without a second audit row.
	if err := s.ArchiveEnrollment(ctx, f.studioID, f.instructorID, series.EnrollmentID); err != nil {
		t.Fatalf("second ArchiveEnrollment: %v", err)
	}
	if n := auditCount(t, s, f.studioID, "series_archive"); n != 1 {
		t.Errorf("series_archive audit after re-archive = %d, want 1", n)
	}

	// Unknown id → ErrNotFound.
	if err := s.ArchiveEnrollment(ctx, f.studioID, f.instructorID, "enr_does_not_exist"); err != ErrNotFound {
		t.Errorf("archiving unknown series = %v, want ErrNotFound", err)
	}
}

func containsEnrollment(rows []EnrollmentSummary, id string) bool {
	for _, r := range rows {
		if r.ID == id {
			return true
		}
	}
	return false
}
