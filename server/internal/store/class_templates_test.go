package store

import (
	"context"
	"testing"
	"time"
)

// nextMonday returns the YYYY-MM-DD of the next Monday (a stable anchor so the
// weekday-snap math is deterministic regardless of when the test runs).
func nextMonday() string {
	d := time.Now().UTC()
	for d.Weekday() != time.Monday {
		d = d.AddDate(0, 0, 1)
	}
	return d.Format("2006-01-02")
}

func TestCreateClassTemplate_MultiSlotFansOut(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// A second instructor so the two slots carry distinct shapes.
	inst2 := NewID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO users (id, studio_id, role, email, full_name)
		 VALUES (?, ?, 'instructor', 'inst2@test.com', 'Inst2')`, inst2, f.studioID); err != nil {
		t.Fatalf("seed instructor: %v", err)
	}

	res, err := s.CreateClassTemplate(ctx, f.studioID, f.instructorID, ClassTemplateInput{
		Title: "Weekend Flow", Weeks: 6, StartsOn: nextMonday(),
		Slots: []TemplateSlotInput{
			{Title: "Thu Vinyasa", ClassTypeID: f.classTypeID, InstructorID: f.instructorID,
				RoomID: f.roomID, Weekday: 3, StartHour: 18, StartMinute: 30,
				DurationMins: 60, Capacity: 14},
			{Title: "Sat Slow", ClassTypeID: f.classTypeID, InstructorID: inst2,
				RoomID: f.roomID, Weekday: 5, StartHour: 9, StartMinute: 30,
				DurationMins: 75, Capacity: 12},
		},
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	// 6 weeks × 2 slots = 12 classes.
	if got := len(res.GeneratedClassIDs); got != 12 {
		t.Fatalf("generated classes = %d, want 12", got)
	}
	if got := len(res.Slots); got != 2 {
		t.Fatalf("slots = %d, want 2", got)
	}

	// Verify per-slot shape landed: every Saturday class is the 75-min,
	// inst2, capacity-12 slot; every Thursday is the 60-min, capacity-14 one.
	rows, err := s.db.QueryContext(ctx, `
		SELECT starts_at, ends_at, instructor_id, capacity
		  FROM classes WHERE template_batch_id = ? ORDER BY starts_at`, res.ID)
	if err != nil {
		t.Fatalf("query classes: %v", err)
	}
	defer rows.Close()
	thu, sat := 0, 0
	for rows.Next() {
		var startsAt, endsAt, instructor string
		var capacity int
		if err := rows.Scan(&startsAt, &endsAt, &instructor, &capacity); err != nil {
			t.Fatalf("scan: %v", err)
		}
		start, _ := time.Parse(time.RFC3339, startsAt)
		end, _ := time.Parse(time.RFC3339, endsAt)
		dur := int(end.Sub(start).Minutes())
		switch start.Weekday() {
		case time.Thursday:
			thu++
			if dur != 60 || instructor != f.instructorID || capacity != 14 {
				t.Errorf("Thu class: dur=%d inst=%s cap=%d, want 60/%s/14", dur, instructor, capacity, f.instructorID)
			}
		case time.Saturday:
			sat++
			if dur != 75 || instructor != inst2 || capacity != 12 {
				t.Errorf("Sat class: dur=%d inst=%s cap=%d, want 75/%s/12", dur, instructor, capacity, inst2)
			}
		default:
			t.Errorf("unexpected weekday %s for %s", start.Weekday(), startsAt)
		}
	}
	if thu != 6 || sat != 6 {
		t.Errorf("weekday counts: thu=%d sat=%d, want 6/6", thu, sat)
	}
}

// The legacy flat shape (no slots[]) must still produce a single-slot batch so
// the original API and audit-matrix tests keep working.
func TestCreateClassTemplate_LegacyFlatInput(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	res, err := s.CreateClassTemplate(ctx, f.studioID, f.instructorID, ClassTemplateInput{
		Title: "Saturday Slow Flow", Weeks: 4, StartsOn: nextMonday(),
		ClassTypeID: f.classTypeID, InstructorID: f.instructorID, RoomID: f.roomID,
		Weekday: 5, StartHour: 9, StartMinute: 30, DurationMins: 60, Capacity: 12,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if len(res.Slots) != 1 {
		t.Fatalf("slots = %d, want 1", len(res.Slots))
	}
	if len(res.GeneratedClassIDs) != 4 {
		t.Fatalf("classes = %d, want 4", len(res.GeneratedClassIDs))
	}
}

func TestCreateClassTemplate_RejectsOverCap(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// 52 weeks × 8 slots = 416 > 366 cap.
	slots := make([]TemplateSlotInput, 8)
	for i := range slots {
		slots[i] = TemplateSlotInput{
			ClassTypeID: f.classTypeID, InstructorID: f.instructorID, RoomID: f.roomID,
			Weekday: i % 7, StartHour: 9, StartMinute: 0, DurationMins: 60, Capacity: 10,
		}
	}
	_, err := s.CreateClassTemplate(ctx, f.studioID, f.instructorID, ClassTemplateInput{
		Title: "Too much", Weeks: 52, StartsOn: nextMonday(), Slots: slots,
	})
	if err == nil {
		t.Fatal("expected cap rejection, got nil")
	}
}

func TestUndoClassTemplate_CancelsWholeBatch(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	res, err := s.CreateClassTemplate(ctx, f.studioID, f.instructorID, ClassTemplateInput{
		Title: "Weekend Flow", Weeks: 3, StartsOn: nextMonday(),
		Slots: []TemplateSlotInput{
			{ClassTypeID: f.classTypeID, InstructorID: f.instructorID, RoomID: f.roomID,
				Weekday: 3, StartHour: 18, StartMinute: 0, DurationMins: 60, Capacity: 10},
			{ClassTypeID: f.classTypeID, InstructorID: f.instructorID, RoomID: f.roomID,
				Weekday: 5, StartHour: 9, StartMinute: 0, DurationMins: 60, Capacity: 10},
		},
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	undo, err := s.UndoClassTemplate(ctx, f.studioID, res.ID)
	if err != nil {
		t.Fatalf("undo: %v", err)
	}
	if undo.TotalClasses != 6 {
		t.Fatalf("undo total = %d, want 6", undo.TotalClasses)
	}

	var scheduled int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM classes WHERE template_batch_id = ? AND status = 'scheduled'`,
		res.ID).Scan(&scheduled); err != nil {
		t.Fatalf("count: %v", err)
	}
	if scheduled != 0 {
		t.Errorf("scheduled classes after undo = %d, want 0", scheduled)
	}

	// Second undo must be rejected.
	if _, err := s.UndoClassTemplate(ctx, f.studioID, res.ID); err == nil {
		t.Error("expected error reverting an already-reverted template")
	}
}
