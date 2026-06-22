package store

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// newTestStore returns an in-memory SQLite store with the production schema
// applied. Each test gets a fresh DB.
func newTestStore(t *testing.T) *Store {
	t.Helper()
	db, err := sql.Open("sqlite",
		"file::memory:?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&cache=shared")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	schemaPath := findSchema(t)
	b, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Fatalf("read schema: %v", err)
	}
	if _, err := db.ExecContext(context.Background(), string(b)); err != nil {
		t.Fatalf("apply schema: %v", err)
	}
	return &Store{db: db}
}

func findSchema(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for d := dir; d != "/"; d = filepath.Dir(d) {
		p := filepath.Join(d, "db", "schema.sql")
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	t.Fatalf("db/schema.sql not found from %s", dir)
	return ""
}

// fixture holds the minimum entities every test needs: a studio, a student,
// an instructor, a room, and a yoga class type. Specific tests layer on
// classes/bookings/entitlements via the helpers below.
type fixture struct {
	studioID     string
	studentID    string
	instructorID string
	roomID       string
	classTypeID  string
}

func newFixture(t *testing.T, s *Store) fixture {
	t.Helper()
	f := fixture{
		studioID:     NewID(),
		studentID:    NewID(),
		instructorID: NewID(),
		roomID:       NewID(),
		classTypeID:  NewID(),
	}
	ctx := context.Background()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := s.db.ExecContext(ctx, q, args...); err != nil {
			t.Fatalf("fixture exec %q: %v", q, err)
		}
	}
	themeID := NewID()
	exec(`INSERT INTO studios (id, name, allow_student_plus_one, welcome_message)
	      VALUES (?, 'Test Studio', 0, 'Welcome')`, f.studioID)
	exec(`INSERT INTO themes (id, studio_id, name, mode, tokens)
	      VALUES (?, ?, 'T', 'light', '{"primary":"#000"}')`, themeID, f.studioID)
	exec(`UPDATE studios SET active_theme_id = ? WHERE id = ?`, themeID, f.studioID)
	exec(`INSERT INTO users (id, studio_id, role, email, full_name)
	      VALUES (?, ?, 'student', 'student@test.com', 'Student')`, f.studentID, f.studioID)
	exec(`INSERT INTO users (id, studio_id, role, email, full_name)
	      VALUES (?, ?, 'instructor', 'inst@test.com', 'Inst')`, f.instructorID, f.studioID)
	exec(`INSERT INTO rooms (id, studio_id, name) VALUES (?, ?, 'Room A')`,
		f.roomID, f.studioID)
	exec(`INSERT INTO class_types (id, studio_id, name) VALUES (?, ?, 'Yoga')`,
		f.classTypeID, f.studioID)
	return f
}

// setPlusOneAllowed flips the studio's +1 setting.
func (f fixture) setPlusOneAllowed(t *testing.T, s *Store, allowed bool) {
	t.Helper()
	v := 0
	if allowed {
		v = 1
	}
	if _, err := s.db.ExecContext(context.Background(),
		`UPDATE studios SET allow_student_plus_one = ? WHERE id = ?`, v, f.studioID); err != nil {
		t.Fatalf("flip +1: %v", err)
	}
}

// insertClass inserts a scheduled class.
func (f fixture) insertClass(t *testing.T, s *Store, startsAt time.Time, capacity int) string {
	t.Helper()
	id := NewID()
	end := startsAt.Add(60 * time.Minute)
	_, err := s.db.ExecContext(context.Background(), `
		INSERT INTO classes
		   (id, studio_id, class_type_id, instructor_id, room_id,
		    title, starts_at, ends_at, capacity, status)
		   VALUES (?, ?, ?, ?, ?, 'Test Class', ?, ?, ?, 'scheduled')`,
		id, f.studioID, f.classTypeID, f.instructorID, f.roomID,
		startsAt.UTC().Format(time.RFC3339), end.UTC().Format(time.RFC3339), capacity,
	)
	if err != nil {
		t.Fatalf("insert class: %v", err)
	}
	return id
}

// insertEntitlement inserts an active entitlement for the fixture's student.
// kind is "credit" or "unlimited"; credits is the starting balance for credit
// (ignored for unlimited).
func (f fixture) insertEntitlement(t *testing.T, s *Store, kind string, credits int) string {
	return f.insertEntitlementFor(t, s, f.studentID, kind, credits)
}

// insertEntitlementFor inserts an active entitlement owned by an arbitrary
// user — useful when a test needs two students competing for a seat.
func (f fixture) insertEntitlementFor(t *testing.T, s *Store, userID, kind string, credits int) string {
	t.Helper()
	id := NewID()
	purchaseID := NewID()
	productID := NewID()
	ctx := context.Background()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := s.db.ExecContext(ctx, q, args...); err != nil {
			t.Fatalf("fixture exec %q: %v", q, err)
		}
	}
	exec(`INSERT INTO products
	      (id, studio_id, name, price_minor, billing_type, pass_kind, credits)
	      VALUES (?, ?, 'P', 1000, 'one_time', ?, ?)`,
		productID, f.studioID, kind, sqlInt(kind == "credit", credits))
	exec(`INSERT INTO entitlements
	      (id, studio_id, user_id, source_product_id,
	       label, pass_kind, credits_total, credits_remaining, status)
	      VALUES (?, ?, ?, ?, 'Pass', ?, ?, ?, 'active')`,
		id, f.studioID, userID, productID, kind,
		sqlInt(kind == "credit", credits), sqlInt(kind == "credit", credits))
	exec(`INSERT INTO purchases
	      (id, studio_id, user_id, product_id, list_price_minor, amount_minor, currency,
	       payment_method, initiated_by, actor_role, status, resulting_entitlement_id)
	      VALUES (?, ?, ?, ?, 1000, 1000, 'GBP', 'dev_stub', ?, 'student', 'completed', ?)`,
		purchaseID, f.studioID, userID, productID, userID, id)
	exec(`INSERT INTO entitlement_class_types (entitlement_id, class_type_id)
	      VALUES (?, ?)`, id, f.classTypeID)
	return id
}

// insertBookedSeat directly inserts a 'booked' row for the fixture's student
// — bypasses CreateBooking so tests can set up bookings against classes that
// are already in the past (CreateBooking refuses those).
func (f fixture) insertBookedSeat(t *testing.T, s *Store, classID, entitlementID string) string {
	t.Helper()
	id := NewID()
	if _, err := s.db.ExecContext(context.Background(), `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
		     booked_by_role, cancel_cutoff_hours, status, checkin_token)
		    VALUES (?, ?, ?, ?, ?, 0, 'student', 12, 'booked', ?)`,
		id, f.studioID, classID, f.studentID, entitlementID, NewID()); err != nil {
		t.Fatalf("insert booked seat: %v", err)
	}
	return id
}

// insertCancelledLateSeat seeds a booking that's already been cancelled past
// the cutoff — used by tests that need the terminal 'cancelled_late_burned'
// state without driving it through the (now-refused-on-past-class) cancel
// path.
func (f fixture) insertCancelledLateSeat(t *testing.T, s *Store, classID, entitlementID string) string {
	t.Helper()
	id := NewID()
	if _, err := s.db.ExecContext(context.Background(), `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
		     booked_by_role, cancel_cutoff_hours, status, outcome,
		     cancelled_at, checkin_token)
		    VALUES (?, ?, ?, ?, ?, 0, 'student', 12, 'cancelled',
		            'cancelled_late_burned',
		            strftime('%Y-%m-%dT%H:%M:%fZ','now'), ?)`,
		id, f.studioID, classID, f.studentID, entitlementID, NewID()); err != nil {
		t.Fatalf("insert cancelled-late seat: %v", err)
	}
	return id
}

// insertOtherStudent creates a second student in the same studio.
func insertOtherStudent(t *testing.T, s *Store, studioID string) string {
	t.Helper()
	id := NewID()
	if _, err := s.db.ExecContext(context.Background(),
		`INSERT INTO users (id, studio_id, role, email, full_name)
		 VALUES (?, ?, 'student', ?, 'Other')`,
		id, studioID, "other-"+id[:8]+"@test.com"); err != nil {
		t.Fatalf("insert other student: %v", err)
	}
	return id
}

// sqlInt returns the int when on, otherwise nil (so it inserts NULL).
func sqlInt(on bool, v int) any {
	if !on {
		return nil
	}
	return v
}
