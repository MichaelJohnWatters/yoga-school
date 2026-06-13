package store

import (
	"context"
	"errors"
	"testing"
)

func TestCreateClassType_PersistsAndReturnsID(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, err := s.CreateClassType(ctx, f.studioID, f.instructorID, ClassTypeInput{
		Name: "Pilates", Discipline: "mat",
	})
	if err != nil {
		t.Fatalf("CreateClassType: %v", err)
	}
	if id == "" {
		t.Fatal("returned empty id")
	}

	rows, err := s.ListClassTypes(ctx, f.studioID)
	if err != nil {
		t.Fatalf("ListClassTypes: %v", err)
	}
	var found *ClassType
	for i := range rows {
		if rows[i].ID == id {
			found = &rows[i]
		}
	}
	if found == nil {
		t.Fatalf("created class type missing from list: %v", rows)
	}
	if found.Name != "Pilates" || found.Discipline != "mat" {
		t.Errorf("stored row: %+v want name=Pilates discipline=mat", *found)
	}
}

func TestCreateClassType_RejectsEmptyName(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateClassType(ctx, f.studioID, f.instructorID, ClassTypeInput{Name: "  "}); err == nil {
		t.Error("expected error for blank name, got nil")
	}
}

func TestCreateClassType_AllowsEmptyDiscipline(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, err := s.CreateClassType(ctx, f.studioID, f.instructorID, ClassTypeInput{Name: "Barre"})
	if err != nil {
		t.Fatalf("CreateClassType: %v", err)
	}

	// Verify the discipline column is NULL (not an empty string).
	var disc *string
	if err := s.db.QueryRowContext(ctx,
		`SELECT discipline FROM class_types WHERE id = ?`, id,
	).Scan(&disc); err != nil {
		t.Fatalf("read: %v", err)
	}
	if disc != nil {
		t.Errorf("discipline: got %q want NULL", *disc)
	}
}

func TestUpdateClassType_ChangesFields(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, _ := s.CreateClassType(ctx, f.studioID, f.instructorID, ClassTypeInput{
		Name: "Pilates", Discipline: "mat",
	})
	if err := s.UpdateClassType(ctx, f.studioID, f.instructorID, id, ClassTypeInput{
		Name: "Reformer Pilates", Discipline: "reformer",
	}); err != nil {
		t.Fatalf("UpdateClassType: %v", err)
	}

	rows, _ := s.ListClassTypes(ctx, f.studioID)
	for _, c := range rows {
		if c.ID == id {
			if c.Name != "Reformer Pilates" || c.Discipline != "reformer" {
				t.Errorf("after update: %+v", c)
			}
			return
		}
	}
	t.Fatal("class type vanished after update")
}

func TestUpdateClassType_NotFoundWhenWrongStudio(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, _ := s.CreateClassType(ctx, f.studioID, f.instructorID, ClassTypeInput{Name: "Pilates"})
	err := s.UpdateClassType(ctx, "other-studio", f.instructorID, id, ClassTypeInput{Name: "x"})
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("cross-studio update: got %v want ErrNotFound", err)
	}
}

func TestUpdateClassType_RejectsEmptyName(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, _ := s.CreateClassType(ctx, f.studioID, f.instructorID, ClassTypeInput{Name: "Pilates"})
	if err := s.UpdateClassType(ctx, f.studioID, f.instructorID, id, ClassTypeInput{Name: ""}); err == nil {
		t.Error("expected error for blank name, got nil")
	}
}
