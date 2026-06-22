package store

import (
	"context"
	"testing"
	"time"
)

// helper: hand-build the recurrence input for the fixture's studio.
func (f fixture) recur(weeks int, weekday int) RecurrenceClassInput {
	start := time.Now().UTC().AddDate(0, 0, 1) // tomorrow, in case today's weekday matches
	return RecurrenceClassInput{
		Title:        "Vinyasa",
		ClassTypeID:  f.classTypeID,
		InstructorID: f.instructorID,
		RoomID:       f.roomID,
		StartHour:    18,
		StartMinute:  0,
		DurationMins: 60,
		Capacity:     12,
		Recurrence: RecurrenceInput{
			Frequency: "weekly",
			Interval:  1,
			Weekdays:  []int{weekday},
			StartsOn:  start.Format("2006-01-02"),
			Occurrences: weeks,
		},
	}
}

func TestCreateRecurringClasses_MaterializesOnePerWeek(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	res, err := s.CreateRecurringClasses(ctx, f.studioID, f.studentID, f.recur(6, 2))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if len(res.GeneratedClassIDs) != 6 {
		t.Fatalf("classes: got %d want 6", len(res.GeneratedClassIDs))
	}
	// Every class points back to the rule and is non-detached.
	var ruleCount, detachedCount int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*), COALESCE(SUM(is_detached),0) FROM classes
		 WHERE recurrence_rule_id = ?`, res.RuleID).Scan(&ruleCount, &detachedCount); err != nil {
		t.Fatal(err)
	}
	if ruleCount != 6 {
		t.Errorf("rule-linked classes: got %d want 6", ruleCount)
	}
	if detachedCount != 0 {
		t.Errorf("none should be detached at create: got %d", detachedCount)
	}
}

func TestPatchClassScoped_ThisDetachesAndUpdatesOne(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	res, err := s.CreateRecurringClasses(ctx, f.studioID, f.studentID, f.recur(4, 2))
	if err != nil {
		t.Fatal(err)
	}
	target := res.GeneratedClassIDs[1]
	newCap := 20
	patch, err := s.PatchClassScoped(ctx, f.studioID, target, "this", ScopedPatchInput{
		Capacity: &newCap,
	})
	if err != nil {
		t.Fatalf("patch: %v", err)
	}
	if patch.Scope != "this" || patch.ClassesUpdated != 1 || patch.RuleUpdated {
		t.Errorf("unexpected result: %+v", patch)
	}
	var cap_ int
	var detached int
	if err := s.db.QueryRowContext(ctx,
		`SELECT capacity, is_detached FROM classes WHERE id = ?`, target,
	).Scan(&cap_, &detached); err != nil {
		t.Fatal(err)
	}
	if cap_ != 20 {
		t.Errorf("target capacity: got %d want 20", cap_)
	}
	if detached != 1 {
		t.Errorf("target should be detached: got %d", detached)
	}
	// Others on the rule unchanged.
	var other int
	if err := s.db.QueryRowContext(ctx,
		`SELECT capacity FROM classes WHERE id = ?`, res.GeneratedClassIDs[2],
	).Scan(&other); err != nil {
		t.Fatal(err)
	}
	if other != 12 {
		t.Errorf("sibling should still be capacity 12: got %d", other)
	}
}

func TestPatchClassScoped_FutureSplitsRuleAndUpdatesForward(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	res, err := s.CreateRecurringClasses(ctx, f.studioID, f.studentID, f.recur(4, 2))
	if err != nil {
		t.Fatal(err)
	}
	pivot := res.GeneratedClassIDs[1]
	newCap := 18
	patch, err := s.PatchClassScoped(ctx, f.studioID, pivot, "future", ScopedPatchInput{
		Capacity: &newCap,
	})
	if err != nil {
		t.Fatalf("patch: %v", err)
	}
	// pivot is index 1 of a 4-week series → classes 1, 2, 3 should update.
	// Exact equality so an off-by-one (e.g. dragging class 0 along) is caught.
	if patch.Scope != "future" || patch.ClassesUpdated != 3 {
		t.Errorf("expected 3 classes updated, got %+v", patch)
	}
	if !patch.RuleUpdated || patch.NewRuleID == "" {
		t.Errorf("expected fork to produce new rule: %+v", patch)
	}

	// The first class (before the pivot) should be untouched and still
	// pointing at the original (now superseded) rule.
	var firstCap int
	var firstRule string
	if err := s.db.QueryRowContext(ctx,
		`SELECT capacity, COALESCE(recurrence_rule_id,'') FROM classes WHERE id = ?`,
		res.GeneratedClassIDs[0],
	).Scan(&firstCap, &firstRule); err != nil {
		t.Fatal(err)
	}
	if firstCap != 12 {
		t.Errorf("class[0] capacity: got %d want 12", firstCap)
	}
	if firstRule != res.RuleID {
		t.Errorf("class[0] rule: got %q want original %q", firstRule, res.RuleID)
	}

	// Pivot + later classes pointed at new rule, capacity 18.
	var pivotCap int
	var pivotRule string
	if err := s.db.QueryRowContext(ctx,
		`SELECT capacity, COALESCE(recurrence_rule_id,'') FROM classes WHERE id = ?`, pivot,
	).Scan(&pivotCap, &pivotRule); err != nil {
		t.Fatal(err)
	}
	if pivotCap != 18 || pivotRule != patch.NewRuleID {
		t.Errorf("pivot got cap=%d rule=%q want cap=18 rule=%s", pivotCap, pivotRule, patch.NewRuleID)
	}

	// Old rule is superseded.
	var status string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status FROM recurrence_rules WHERE id = ?`, res.RuleID,
	).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if status != "superseded" {
		t.Errorf("old rule status: got %q want superseded", status)
	}
}

func TestPatchClassScoped_AllUpdatesEveryNonDetached(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	res, err := s.CreateRecurringClasses(ctx, f.studioID, f.studentID, f.recur(4, 2))
	if err != nil {
		t.Fatal(err)
	}
	// Detach #1 first so it's protected from the bulk patch.
	deCap := 5
	if _, err := s.PatchClassScoped(ctx, f.studioID, res.GeneratedClassIDs[1], "this", ScopedPatchInput{
		Capacity: &deCap,
	}); err != nil {
		t.Fatal(err)
	}

	newCap := 30
	patch, err := s.PatchClassScoped(ctx, f.studioID, res.GeneratedClassIDs[0], "all", ScopedPatchInput{
		Capacity: &newCap,
	})
	if err != nil {
		t.Fatalf("patch all: %v", err)
	}
	if patch.ClassesUpdated != 3 { // 4 - 1 detached
		t.Errorf("classes updated: got %d want 3", patch.ClassesUpdated)
	}
	// Detached one preserved at 5.
	var deCheck int
	if err := s.db.QueryRowContext(ctx,
		`SELECT capacity FROM classes WHERE id = ?`, res.GeneratedClassIDs[1],
	).Scan(&deCheck); err != nil {
		t.Fatal(err)
	}
	if deCheck != 5 {
		t.Errorf("detached preserved: got %d want 5", deCheck)
	}
	// Rule's capacity snapshot updated too.
	var ruleCap int
	if err := s.db.QueryRowContext(ctx,
		`SELECT capacity FROM recurrence_rules WHERE id = ?`, res.RuleID,
	).Scan(&ruleCap); err != nil {
		t.Fatal(err)
	}
	if ruleCap != 30 {
		t.Errorf("rule capacity snapshot: got %d want 30", ruleCap)
	}
}

func TestCancelClassScoped_FutureCancelsFromAnchorOnwards(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	res, err := s.CreateRecurringClasses(ctx, f.studioID, f.studentID, f.recur(4, 2))
	if err != nil {
		t.Fatal(err)
	}
	results, err := s.CancelClassScoped(ctx, f.studioID, res.GeneratedClassIDs[2], "future")
	if err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if len(results) != 2 {
		t.Errorf("cancelled count: got %d want 2", len(results))
	}
	// First two classes still scheduled.
	var statuses [4]string
	for i, id := range res.GeneratedClassIDs {
		if err := s.db.QueryRowContext(ctx,
			`SELECT status FROM classes WHERE id = ?`, id,
		).Scan(&statuses[i]); err != nil {
			t.Fatal(err)
		}
	}
	want := [4]string{"scheduled", "scheduled", "cancelled", "cancelled"}
	if statuses != want {
		t.Errorf("statuses: got %v want %v", statuses, want)
	}
	// Rule superseded.
	var ruleStatus string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status FROM recurrence_rules WHERE id = ?`, res.RuleID,
	).Scan(&ruleStatus); err != nil {
		t.Fatal(err)
	}
	if ruleStatus != "superseded" {
		t.Errorf("rule: got %q want superseded", ruleStatus)
	}
}

func TestExpandRecurrence_WeeklyMultipleWeekdaysCapsAtOccurrences(t *testing.T) {
	dates, err := expandRecurrence(RecurrenceInput{
		Frequency:   "weekly",
		Weekdays:    []int{0, 2, 4}, // Mon Wed Fri
		StartsOn:    "2026-06-15",   // Monday
		Occurrences: 7,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(dates) != 7 {
		t.Errorf("got %d dates want 7", len(dates))
	}
	// Mon Wed Fri Mon Wed Fri Mon ...
	want := []string{
		"2026-06-15", "2026-06-17", "2026-06-19",
		"2026-06-22", "2026-06-24", "2026-06-26",
		"2026-06-29",
	}
	for i, d := range dates {
		if got := d.Format("2006-01-02"); got != want[i] {
			t.Errorf("dates[%d]: got %s want %s", i, got, want[i])
		}
	}
}

func TestExpandRecurrence_DailyHonoursEndsOn(t *testing.T) {
	dates, err := expandRecurrence(RecurrenceInput{
		Frequency: "daily",
		Interval:  1,
		StartsOn:  "2026-06-15",
		EndsOn:    "2026-06-18",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"2026-06-15", "2026-06-16", "2026-06-17", "2026-06-18"}
	if len(dates) != len(want) {
		t.Fatalf("got %d dates want %d (15..18 inclusive)", len(dates), len(want))
	}
	for i, d := range dates {
		if got := d.Format("2006-01-02"); got != want[i] {
			t.Errorf("dates[%d]: got %s want %s", i, got, want[i])
		}
	}
}

func TestExpandRecurrence_WeeklyIntervalSkipsWeeks(t *testing.T) {
	// Every 2nd Wednesday for 4 occurrences, starting on a Wednesday.
	dates, err := expandRecurrence(RecurrenceInput{
		Frequency:   "weekly",
		Interval:    2,
		Weekdays:    []int{2},
		StartsOn:    "2026-06-17", // Wednesday
		Occurrences: 4,
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"2026-06-17", "2026-07-01", "2026-07-15", "2026-07-29"}
	if len(dates) != len(want) {
		t.Fatalf("got %d dates want %d", len(dates), len(want))
	}
	for i, d := range dates {
		if got := d.Format("2006-01-02"); got != want[i] {
			t.Errorf("dates[%d]: got %s want %s", i, got, want[i])
		}
	}
}

func TestExpandRecurrence_MonthlyAdvancesByMonth(t *testing.T) {
	dates, err := expandRecurrence(RecurrenceInput{
		Frequency:   "monthly",
		Interval:    1,
		StartsOn:    "2026-06-15",
		Occurrences: 3,
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"2026-06-15", "2026-07-15", "2026-08-15"}
	if len(dates) != len(want) {
		t.Fatalf("got %d dates want %d", len(dates), len(want))
	}
	for i, d := range dates {
		if got := d.Format("2006-01-02"); got != want[i] {
			t.Errorf("dates[%d]: got %s want %s", i, got, want[i])
		}
	}
}
