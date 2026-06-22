package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// RecurrenceInput is the body block on POST /admin/classes when a manager
// asks for a recurring class instead of a one-off. The non-recurrence fields
// (title, instructor, room, etc.) come from the surrounding AdminClassInput.
type RecurrenceInput struct {
	Frequency   string `json:"frequency"`   // daily | weekly | monthly
	Interval    int    `json:"interval"`    // every N units; default 1
	Weekdays    []int  `json:"weekdays"`    // 0=Mon..6=Sun; required for weekly
	StartsOn    string `json:"starts_on"`   // YYYY-MM-DD
	EndsOn      string `json:"ends_on"`     // YYYY-MM-DD, optional
	Occurrences int    `json:"occurrences"` // optional, alternative to EndsOn
}

// RecurrenceClassInput bundles the class shape with the recurrence shape so
// CreateRecurringClasses has everything it needs in one call.
type RecurrenceClassInput struct {
	Title        string
	ClassTypeID  string
	InstructorID string
	RoomID       string
	StartHour    int
	StartMinute  int
	DurationMins int
	Capacity     int
	Recurrence   RecurrenceInput
}

// RecurrenceCreateResult is what POST returns: the rule + every concrete
// class that was materialized.
type RecurrenceCreateResult struct {
	RuleID            string   `json:"rule_id"`
	GeneratedClassIDs []string `json:"generated_class_ids"`
	Sessions          []string `json:"sessions"` // ISO8601 starts
}

// CreateRecurringClasses persists the rule and materializes a class row per
// occurrence date. Single transaction so a malformed schedule rolls back as
// a whole.
func (s *Store) CreateRecurringClasses(
	ctx context.Context, studioID, actorID string, in RecurrenceClassInput,
) (*RecurrenceCreateResult, error) {
	if err := validateClassShape(in); err != nil {
		return nil, err
	}
	dates, err := expandRecurrence(in.Recurrence)
	if err != nil {
		return nil, err
	}
	if len(dates) == 0 {
		return nil, fmt.Errorf("recurrence produced zero sessions")
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	weekdaysJSON, _ := json.Marshal(in.Recurrence.Weekdays)
	endsOn := anyOrNil(in.Recurrence.EndsOn)
	occurrences := intOrNil(in.Recurrence.Occurrences)

	ruleID := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO recurrence_rules
		    (id, studio_id, class_type_id, instructor_id, room_id, title,
		     start_hour, start_minute, duration_mins, capacity,
		     frequency, interval, weekdays, starts_on, ends_on, occurrences,
		     created_by)
		    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		ruleID, studioID, in.ClassTypeID, in.InstructorID, in.RoomID, in.Title,
		in.StartHour, in.StartMinute, in.DurationMins, in.Capacity,
		in.Recurrence.Frequency, defaultInt(in.Recurrence.Interval, 1),
		string(weekdaysJSON), in.Recurrence.StartsOn, endsOn, occurrences,
		actorID,
	); err != nil {
		return nil, err
	}

	out := &RecurrenceCreateResult{
		RuleID:            ruleID,
		GeneratedClassIDs: make([]string, 0, len(dates)),
		Sessions:          make([]string, 0, len(dates)),
	}
	for _, d := range dates {
		start := d.Add(time.Duration(in.StartHour)*time.Hour +
			time.Duration(in.StartMinute)*time.Minute).UTC()
		end := start.Add(time.Duration(in.DurationMins) * time.Minute)
		classID := NewID()
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO classes
			    (id, studio_id, class_type_id, instructor_id, room_id,
			     recurrence_rule_id, title, starts_at, ends_at, capacity)
			    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			classID, studioID, in.ClassTypeID, in.InstructorID, in.RoomID,
			ruleID, in.Title,
			start.Format(time.RFC3339), end.Format(time.RFC3339), in.Capacity,
		); err != nil {
			return nil, err
		}
		out.GeneratedClassIDs = append(out.GeneratedClassIDs, classID)
		out.Sessions = append(out.Sessions, start.Format(time.RFC3339))
	}
	return out, tx.Commit()
}

// ScopedPatchInput is the patch body for PATCH /admin/classes/{id}?scope=.
// Only the fields the manager wants to change are populated; the rest stay
// untouched. StartsAt is allowed for scope=this only — moving a single class
// detaches it from its rule's cadence.
type ScopedPatchInput struct {
	Title        *string `json:"title,omitempty"`
	ClassTypeID  *string `json:"class_type_id,omitempty"`
	InstructorID *string `json:"instructor_id,omitempty"`
	RoomID       *string `json:"room_id,omitempty"`
	StartsAt     *string `json:"starts_at,omitempty"`
	DurationMins *int    `json:"duration_minutes,omitempty"`
	Capacity     *int    `json:"capacity,omitempty"`
}

// ScopedPatchResult tells the caller how many rows were touched.
type ScopedPatchResult struct {
	Scope          string `json:"scope"`
	ClassesUpdated int    `json:"classes_updated"`
	RuleUpdated    bool   `json:"rule_updated"`
	NewRuleID      string `json:"new_rule_id,omitempty"`
	// AnchorTitle is the title of the class the patch was anchored on
	// (the one identified by the URL path). Useful for the audit row,
	// which would otherwise carry only counts — readers can render
	// "CLASS EDIT · Vinyasa Flow · scope: future" without a follow-up
	// SELECT for the class title.
	AnchorTitle string `json:"-"`
}

// PatchClassScoped applies the edit at one of three scopes.
//
//	this   — detach this single class (is_detached=1) and apply the patch
//	         to just it. The rule and other instances are untouched.
//	future — patch every non-detached class with starts_at >= this one's,
//	         and copy the patch into the rule so newly-materialized classes
//	         use the new shape.
//	all    — patch every non-detached class in the rule and update the rule.
//
// If the class isn't attached to a rule, scope is implicitly "this".
func (s *Store) PatchClassScoped(
	ctx context.Context, studioID, classID, scope string, in ScopedPatchInput,
) (*ScopedPatchResult, error) {
	if scope == "" {
		scope = "this"
	}
	if scope != "this" && scope != "future" && scope != "all" {
		return nil, fmt.Errorf("scope must be this | future | all")
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var (
		ruleID      sql.NullString
		isDetach    int
		startsAt    string
		anchorTitle string
	)
	err = tx.QueryRowContext(ctx, `
		SELECT recurrence_rule_id, is_detached, starts_at,
		       COALESCE(title,'')
		  FROM classes WHERE id = ? AND studio_id = ?`,
		classID, studioID,
	).Scan(&ruleID, &isDetach, &startsAt, &anchorTitle)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	// No rule (or detached row), or caller asked for "this" anyway → single
	// in-place update. Falls through to the existing UpdateAdminClass path,
	// plus a detach flag for rule-backed rows.
	if scope == "this" || !ruleID.Valid || isDetach == 1 {
		if err := applySingleClassPatch(ctx, tx, studioID, classID, in); err != nil {
			return nil, err
		}
		if ruleID.Valid && isDetach == 0 {
			if _, err := tx.ExecContext(ctx,
				`UPDATE classes SET is_detached = 1 WHERE id = ?`, classID,
			); err != nil {
				return nil, err
			}
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return &ScopedPatchResult{Scope: "this", ClassesUpdated: 1, AnchorTitle: anchorTitle}, nil
	}

	// scope=future and scope=all both update the rule + a set of classes.
	// future: only the classes from this one onwards (non-detached).
	// all:    every non-detached class on the rule.
	whereTime := ""
	args := []any{ruleID.String}
	if scope == "future" {
		whereTime = " AND starts_at >= ?"
		args = append(args, startsAt)
	}

	// Build the column updates once.
	sets, setArgs, err := buildClassPatchSets(in, true)
	if err != nil {
		return nil, err
	}
	out := &ScopedPatchResult{Scope: scope, AnchorTitle: anchorTitle}
	if len(sets) > 0 {
		q := `UPDATE classes SET ` + strings.Join(sets, ", ") +
			` WHERE recurrence_rule_id = ? AND is_detached = 0 AND status = 'scheduled'` +
			whereTime
		// setArgs come first, then the WHERE args.
		execArgs := append(append([]any{}, setArgs...), args...)
		res, err := tx.ExecContext(ctx, q, execArgs...)
		if err != nil {
			return nil, err
		}
		n, _ := res.RowsAffected()
		out.ClassesUpdated = int(n)
	}

	// Mirror the patch into the rule's snapshot. For scope=future we instead
	// fork: the old rule ends at the day before this class, a new rule with
	// the patched shape takes over.
	if scope == "all" {
		if err := patchRuleSnapshot(ctx, tx, ruleID.String, in); err != nil {
			return nil, err
		}
		out.RuleUpdated = true
	} else {
		newRuleID, err := forkRule(ctx, tx, ruleID.String, startsAt, in, studioID)
		if err != nil {
			return nil, err
		}
		// Re-link affected classes to the new rule.
		if _, err := tx.ExecContext(ctx, `
			UPDATE classes
			   SET recurrence_rule_id = ?
			 WHERE recurrence_rule_id = ? AND is_detached = 0
			   AND starts_at >= ?`,
			newRuleID, ruleID.String, startsAt,
		); err != nil {
			return nil, err
		}
		out.RuleUpdated = true
		out.NewRuleID = newRuleID
	}

	return out, tx.Commit()
}

// CancelClassScoped cancels at one of three scopes. "this" is the existing
// CancelAdminClass behavior (single class, returns credits, clears waitlist).
// "future" cancels every non-detached scheduled class from this one onwards
// and marks the rule superseded. "all" cancels every non-detached scheduled
// class on the rule (past attended ones are immutable).
func (s *Store) CancelClassScoped(
	ctx context.Context, studioID, classID, scope string,
) ([]CancelClassResult, error) {
	if scope == "" {
		scope = "this"
	}
	if scope != "this" && scope != "future" && scope != "all" {
		return nil, fmt.Errorf("scope must be this | future | all")
	}
	if scope == "this" {
		r, err := s.CancelAdminClass(ctx, studioID, classID)
		if err != nil {
			return nil, err
		}
		return []CancelClassResult{*r}, nil
	}

	// Resolve the rule + the anchor time.
	var (
		ruleID   sql.NullString
		startsAt string
	)
	if err := s.db.QueryRowContext(ctx, `
		SELECT recurrence_rule_id, starts_at
		  FROM classes WHERE id = ? AND studio_id = ?`,
		classID, studioID,
	).Scan(&ruleID, &startsAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if !ruleID.Valid {
		// Falls back to single — caller picked future/all on a one-off class.
		r, err := s.CancelAdminClass(ctx, studioID, classID)
		if err != nil {
			return nil, err
		}
		return []CancelClassResult{*r}, nil
	}

	whereTime := ""
	args := []any{ruleID.String}
	if scope == "future" {
		whereTime = " AND starts_at >= ?"
		args = append(args, startsAt)
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT id FROM classes
		  WHERE recurrence_rule_id = ?
		    AND is_detached = 0 AND status = 'scheduled'`+whereTime,
		args...,
	)
	if err != nil {
		return nil, err
	}
	classIDs := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		classIDs = append(classIDs, id)
	}
	rows.Close()

	results := make([]CancelClassResult, 0, len(classIDs))
	for _, id := range classIDs {
		r, err := s.CancelAdminClass(ctx, studioID, id)
		if err != nil {
			return nil, fmt.Errorf("cancel %s: %w", id, err)
		}
		results = append(results, *r)
	}
	// Mark the rule superseded so it won't be picked up by future
	// materialization helpers.
	if _, err := s.db.ExecContext(ctx,
		`UPDATE recurrence_rules SET status = 'superseded' WHERE id = ?`,
		ruleID.String,
	); err != nil {
		return nil, err
	}
	return results, nil
}

// ---- helpers ---------------------------------------------------------

func validateClassShape(in RecurrenceClassInput) error {
	missing := []string{}
	if in.ClassTypeID == "" {
		missing = append(missing, "class_type_id")
	}
	if in.InstructorID == "" {
		missing = append(missing, "instructor_id")
	}
	if in.RoomID == "" {
		missing = append(missing, "room_id")
	}
	if in.DurationMins <= 0 {
		missing = append(missing, "duration_minutes")
	}
	if in.Capacity <= 0 {
		missing = append(missing, "capacity")
	}
	if in.StartHour < 0 || in.StartHour > 23 {
		missing = append(missing, "start_hour")
	}
	if in.StartMinute < 0 || in.StartMinute > 59 {
		missing = append(missing, "start_minute")
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing or invalid fields: %v", missing)
	}
	return nil
}

// expandRecurrence walks the recurrence rule and returns the date (midnight
// UTC) of every session — the per-class start time gets layered on top by
// the caller. Capped at 366 occurrences to keep a runaway rule from filling
// the DB.
func expandRecurrence(r RecurrenceInput) ([]time.Time, error) {
	if r.Frequency != "daily" && r.Frequency != "weekly" && r.Frequency != "monthly" {
		return nil, fmt.Errorf("frequency must be daily | weekly | monthly")
	}
	if r.StartsOn == "" {
		return nil, fmt.Errorf("starts_on is required")
	}
	start, err := time.Parse("2006-01-02", r.StartsOn)
	if err != nil {
		return nil, fmt.Errorf("starts_on must be YYYY-MM-DD")
	}
	var end time.Time
	if r.EndsOn != "" {
		end, err = time.Parse("2006-01-02", r.EndsOn)
		if err != nil {
			return nil, fmt.Errorf("ends_on must be YYYY-MM-DD")
		}
	}
	interval := defaultInt(r.Interval, 1)
	if interval < 1 {
		return nil, fmt.Errorf("interval must be >= 1")
	}

	maxCount := r.Occurrences
	if maxCount <= 0 {
		maxCount = 366
	}
	if maxCount > 366 {
		maxCount = 366
	}

	dates := []time.Time{}
	switch r.Frequency {
	case "daily":
		cursor := start
		for len(dates) < maxCount {
			if !end.IsZero() && cursor.After(end) {
				break
			}
			dates = append(dates, cursor)
			cursor = cursor.AddDate(0, 0, interval)
		}
	case "weekly":
		if len(r.Weekdays) == 0 {
			return nil, fmt.Errorf("weekly recurrence requires at least one weekday")
		}
		// Normalise weekdays + dedupe.
		seen := map[int]struct{}{}
		ws := make([]int, 0, len(r.Weekdays))
		for _, w := range r.Weekdays {
			if w < 0 || w > 6 {
				return nil, fmt.Errorf("weekday must be 0..6 (Mon=0): %d", w)
			}
			if _, ok := seen[w]; !ok {
				seen[w] = struct{}{}
				ws = append(ws, w)
			}
		}
		sort.Ints(ws)
		// Anchor on the Monday of the week containing starts_on.
		monOffset := (int(start.Weekday()) + 6) % 7 // Mon=0..Sun=6
		monday := start.AddDate(0, 0, -monOffset)
		week := 0
		for len(dates) < maxCount {
			weekStart := monday.AddDate(0, 0, 7*interval*week)
			advanced := false
			for _, w := range ws {
				d := weekStart.AddDate(0, 0, w)
				if d.Before(start) {
					continue
				}
				if !end.IsZero() && d.After(end) {
					// Past the window; flush remaining and stop the outer loop.
					return dates, nil
				}
				dates = append(dates, d)
				advanced = true
				if len(dates) >= maxCount {
					break
				}
			}
			if !advanced && !end.IsZero() && weekStart.After(end) {
				break
			}
			week++
			if week > 520 { // sanity bound: 10 years of weeks
				break
			}
		}
	case "monthly":
		cursor := start
		for len(dates) < maxCount {
			if !end.IsZero() && cursor.After(end) {
				break
			}
			dates = append(dates, cursor)
			cursor = cursor.AddDate(0, interval, 0)
		}
	}
	return dates, nil
}

// applySingleClassPatch updates one class row using the existing patch
// semantics (re-derive ends_at when start/duration change).
func applySingleClassPatch(ctx context.Context, tx *sql.Tx, studioID, classID string, in ScopedPatchInput) error {
	var startStr, endStr string
	if err := tx.QueryRowContext(ctx,
		`SELECT starts_at, ends_at FROM classes WHERE id = ? AND studio_id = ?`,
		classID, studioID,
	).Scan(&startStr, &endStr); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	start, _ := time.Parse(time.RFC3339, startStr)
	end, _ := time.Parse(time.RFC3339, endStr)
	if in.StartsAt != nil {
		t, err := time.Parse(time.RFC3339, *in.StartsAt)
		if err != nil {
			return fmt.Errorf("starts_at must be RFC3339")
		}
		start = t
	}
	if in.DurationMins != nil {
		end = start.Add(time.Duration(*in.DurationMins) * time.Minute)
	} else if in.StartsAt != nil {
		dur := end.Sub(parseRFC(startStr))
		end = start.Add(dur)
	}

	set := []string{"starts_at = ?", "ends_at = ?"}
	args := []any{start.Format(time.RFC3339), end.Format(time.RFC3339)}
	if in.Title != nil {
		set = append(set, "title = ?")
		args = append(args, *in.Title)
	}
	if in.ClassTypeID != nil {
		set = append(set, "class_type_id = ?")
		args = append(args, *in.ClassTypeID)
	}
	if in.InstructorID != nil {
		set = append(set, "instructor_id = ?")
		args = append(args, *in.InstructorID)
	}
	if in.RoomID != nil {
		set = append(set, "room_id = ?")
		args = append(args, *in.RoomID)
	}
	if in.Capacity != nil {
		set = append(set, "capacity = ?")
		args = append(args, *in.Capacity)
	}
	args = append(args, classID, studioID)
	_, err := tx.ExecContext(ctx,
		`UPDATE classes SET `+strings.Join(set, ", ")+
			` WHERE id = ? AND studio_id = ?`, args...,
	)
	return err
}

// buildClassPatchSets returns the SET clauses + args common to scope=future
// and scope=all bulk updates. Skips starts_at — moving an instance off the
// rule's cadence is a scope=this operation by definition.
func buildClassPatchSets(in ScopedPatchInput, bulk bool) ([]string, []any, error) {
	_ = bulk
	if in.StartsAt != nil {
		return nil, nil, fmt.Errorf("starts_at can only be patched with scope=this")
	}
	sets := []string{}
	args := []any{}
	if in.Title != nil {
		sets = append(sets, "title = ?")
		args = append(args, *in.Title)
	}
	if in.ClassTypeID != nil {
		sets = append(sets, "class_type_id = ?")
		args = append(args, *in.ClassTypeID)
	}
	if in.InstructorID != nil {
		sets = append(sets, "instructor_id = ?")
		args = append(args, *in.InstructorID)
	}
	if in.RoomID != nil {
		sets = append(sets, "room_id = ?")
		args = append(args, *in.RoomID)
	}
	if in.Capacity != nil {
		sets = append(sets, "capacity = ?")
		args = append(args, *in.Capacity)
	}
	if in.DurationMins != nil {
		d := *in.DurationMins
		sets = append(sets,
			`ends_at = strftime('%Y-%m-%dT%H:%M:%fZ',
				datetime(starts_at, '+`+fmt.Sprintf("%d", d)+` minutes'))`)
	}
	return sets, args, nil
}

func patchRuleSnapshot(ctx context.Context, tx *sql.Tx, ruleID string, in ScopedPatchInput) error {
	sets := []string{}
	args := []any{}
	if in.Title != nil {
		sets = append(sets, "title = ?")
		args = append(args, *in.Title)
	}
	if in.ClassTypeID != nil {
		sets = append(sets, "class_type_id = ?")
		args = append(args, *in.ClassTypeID)
	}
	if in.InstructorID != nil {
		sets = append(sets, "instructor_id = ?")
		args = append(args, *in.InstructorID)
	}
	if in.RoomID != nil {
		sets = append(sets, "room_id = ?")
		args = append(args, *in.RoomID)
	}
	if in.Capacity != nil {
		sets = append(sets, "capacity = ?")
		args = append(args, *in.Capacity)
	}
	if in.DurationMins != nil {
		sets = append(sets, "duration_mins = ?")
		args = append(args, *in.DurationMins)
	}
	if len(sets) == 0 {
		return nil
	}
	args = append(args, ruleID)
	_, err := tx.ExecContext(ctx,
		`UPDATE recurrence_rules SET `+strings.Join(sets, ", ")+
			` WHERE id = ?`, args...,
	)
	return err
}

// forkRule supersedes the old rule (sets ends_on to the day before the
// pivot) and copies its shape into a new rule with the patch applied.
// Returns the new rule ID.
func forkRule(ctx context.Context, tx *sql.Tx, oldRuleID, pivotStartsAt string, in ScopedPatchInput, studioID string) (string, error) {
	// Load old rule.
	var old struct {
		ClassTypeID, InstructorID, RoomID, Title              string
		StartHour, StartMinute, DurationMins, Capacity, Itval int
		Frequency, Weekdays, StartsOn                         string
		EndsOn                                                sql.NullString
		Occurrences                                           sql.NullInt64
		CreatedBy                                             string
	}
	if err := tx.QueryRowContext(ctx, `
		SELECT class_type_id, instructor_id, room_id, COALESCE(title,''),
		       start_hour, start_minute, duration_mins, capacity, interval,
		       frequency, weekdays, starts_on, ends_on, occurrences, created_by
		  FROM recurrence_rules WHERE id = ?`,
		oldRuleID,
	).Scan(
		&old.ClassTypeID, &old.InstructorID, &old.RoomID, &old.Title,
		&old.StartHour, &old.StartMinute, &old.DurationMins, &old.Capacity, &old.Itval,
		&old.Frequency, &old.Weekdays, &old.StartsOn, &old.EndsOn, &old.Occurrences,
		&old.CreatedBy,
	); err != nil {
		return "", err
	}

	// End the old rule the day before the pivot (date math via the class's
	// starts_at, which is RFC3339 UTC).
	pivotDate, err := time.Parse(time.RFC3339, pivotStartsAt)
	if err != nil {
		return "", err
	}
	oldEnd := pivotDate.AddDate(0, 0, -1).Format("2006-01-02")
	if _, err := tx.ExecContext(ctx,
		`UPDATE recurrence_rules SET ends_on = ?, status = 'superseded' WHERE id = ?`,
		oldEnd, oldRuleID,
	); err != nil {
		return "", err
	}

	// Apply the patch on top of the snapshot.
	if in.Title != nil {
		old.Title = *in.Title
	}
	if in.ClassTypeID != nil {
		old.ClassTypeID = *in.ClassTypeID
	}
	if in.InstructorID != nil {
		old.InstructorID = *in.InstructorID
	}
	if in.RoomID != nil {
		old.RoomID = *in.RoomID
	}
	if in.Capacity != nil {
		old.Capacity = *in.Capacity
	}
	if in.DurationMins != nil {
		old.DurationMins = *in.DurationMins
	}

	newID := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO recurrence_rules
		    (id, studio_id, class_type_id, instructor_id, room_id, title,
		     start_hour, start_minute, duration_mins, capacity,
		     frequency, interval, weekdays, starts_on, ends_on, occurrences,
		     parent_rule_id, created_by)
		    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		newID, studioID, old.ClassTypeID, old.InstructorID, old.RoomID, old.Title,
		old.StartHour, old.StartMinute, old.DurationMins, old.Capacity,
		old.Frequency, old.Itval, old.Weekdays,
		pivotDate.Format("2006-01-02"), old.EndsOn, old.Occurrences,
		oldRuleID, old.CreatedBy,
	); err != nil {
		return "", err
	}
	return newID, nil
}

// ---- tiny helpers ----------------------------------------------------

func anyOrNil(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func intOrNil(n int) any {
	if n == 0 {
		return nil
	}
	return n
}

func defaultInt(n, def int) int {
	if n == 0 {
		return def
	}
	return n
}

func parseRFC(s string) time.Time {
	t, _ := time.Parse(time.RFC3339, s)
	return t
}
