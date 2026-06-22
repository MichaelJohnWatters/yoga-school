package store

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"testing"
	"time"
)

// seedErasableSubject builds one student carrying a distinctive value in every
// PII-bearing category, so the erasure test can assert each is gone. Returns
// the userID and the set of identifying tokens that must not survive erasure.
func seedErasableSubject(t *testing.T, s *Store, f fixture) (string, []string) {
	t.Helper()
	ctx := context.Background()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := s.db.ExecContext(ctx, q, args...); err != nil {
			t.Fatalf("seed exec %q: %v", q, err)
		}
	}

	const (
		name     = "Zelda Fitzcarraldo"
		email    = "zelda@realmail.example"
		fbUID    = "firebase-uid-zelda-9000"
		plusOne  = "Quentin Guest"
		msgBody  = "my secret message text"
		devToken = "fcm-device-secret-token"
	)
	userID := NewID()
	exec(`INSERT INTO users (id, studio_id, firebase_uid, role, email, full_name, photo_url)
	      VALUES (?, ?, ?, 'student', ?, ?, 'https://pics.example/zelda.jpg')`,
		userID, f.studioID, fbUID, email, name)

	// Booking with a +1 guest name (third-party PII).
	classID := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	entID := f.insertEntitlementFor(t, s, userID, "credit", 5)
	exec(`INSERT INTO bookings
	        (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
	         plus_one_name, booked_by_role, cancel_cutoff_hours, status, checkin_token)
	        VALUES (?, ?, ?, ?, ?, 1, ?, 'student', 12, 'booked', ?)`,
		NewID(), f.studioID, classID, userID, entID, plusOne, NewID())

	// Chat message authored by the subject.
	convID := NewID()
	exec(`INSERT INTO conversations (id, studio_id, kind, created_by)
	      VALUES (?, ?, 'group', ?)`, convID, f.studioID, f.instructorID)
	exec(`INSERT INTO conversation_members (conversation_id, user_id) VALUES (?, ?)`,
		convID, userID)
	exec(`INSERT INTO messages (id, conversation_id, seq, sender_id, body)
	      VALUES (?, ?, 1, ?, ?)`, NewID(), convID, userID, msgBody)

	// Transient categories: notification, device token, prefs, achievement.
	exec(`INSERT INTO notifications (id, studio_id, user_id, type, title, body)
	      VALUES (?, ?, ?, 'system', 'Hi Zelda Fitzcarraldo', 'body')`,
		NewID(), f.studioID, userID)
	exec(`INSERT INTO device_tokens (id, user_id, fcm_token) VALUES (?, ?, ?)`,
		NewID(), userID, devToken)
	exec(`INSERT INTO notification_prefs (user_id) VALUES (?)`, userID)
	exec(`INSERT INTO achievements (user_id, badge_key) VALUES (?, 'first_class')`, userID)

	// Audit row naming the subject in its detail JSON (target is the
	// entitlement, but the student is referenced inside detail).
	if err := s.WriteAudit(ctx, f.studioID, f.instructorID, "cash_grant", "entitlement", entID, map[string]any{
		"student_id":   userID,
		"student_name": name,
		"email":        email,
		"amount_minor": 1000,
	}); err != nil {
		t.Fatalf("seed audit: %v", err)
	}

	return userID, []string{name, email, fbUID, plusOne, msgBody, devToken}
}

func TestExportUserData_GathersEveryCategory(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	userID, _ := seedErasableSubject(t, s, f)

	out, err := s.ExportUserData(context.Background(), f.studioID, userID)
	if err != nil {
		t.Fatalf("export: %v", err)
	}
	if out.Profile.Email != "zelda@realmail.example" {
		t.Errorf("profile email = %q", out.Profile.Email)
	}
	checks := map[string]int{
		"entitlements":  len(out.Entitlements),
		"purchases":     len(out.Purchases),
		"bookings":      len(out.Bookings),
		"achievements":  len(out.Achievements),
		"notifications": len(out.Notifications),
		"messages":      len(out.Messages),
		"conversations": len(out.Conversations),
	}
	for cat, n := range checks {
		if n == 0 {
			t.Errorf("export %s: expected at least one row, got 0", cat)
		}
	}
	if len(out.Bookings) > 0 && (out.Bookings[0].PlusOneName == nil || *out.Bookings[0].PlusOneName != "Quentin Guest") {
		t.Errorf("export bookings: +1 name not carried")
	}

	// Cross-tenant isolation: another studio's manager can't export.
	if _, err := s.ExportUserData(context.Background(), NewID(), userID); err != ErrNotFound {
		t.Errorf("cross-tenant export err = %v, want ErrNotFound", err)
	}
}

func TestEraseUser_PseudonymisesAndLeavesNoPII(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	userID, tokens := seedErasableSubject(t, s, f)
	ctx := context.Background()

	res, err := s.EraseUser(ctx, f.studioID, f.instructorID, userID)
	if err != nil {
		t.Fatalf("erase: %v", err)
	}
	if res.FirebaseUID != "firebase-uid-zelda-9000" {
		t.Errorf("erase result FirebaseUID = %q, want the seeded uid", res.FirebaseUID)
	}

	// Anchor row is tombstoned but still present (financial/audit FKs survive).
	var email, fullName string
	var photo, fbUID, erasedAt sql.NullString
	if err := s.db.QueryRowContext(ctx,
		`SELECT email, full_name, photo_url, firebase_uid, erased_at FROM users WHERE id = ?`,
		userID,
	).Scan(&email, &fullName, &photo, &fbUID, &erasedAt); err != nil {
		t.Fatalf("reload user: %v", err)
	}
	if !strings.HasPrefix(email, "erased+") || !strings.HasSuffix(email, "@deleted.invalid") {
		t.Errorf("email not tombstoned: %q", email)
	}
	if fullName != "[erased]" || photo.Valid || fbUID.Valid || !erasedAt.Valid {
		t.Errorf("user row not fully tombstoned: name=%q photo=%v fb=%v erased=%v",
			fullName, photo, fbUID, erasedAt)
	}

	// Financial record retained (HMRC).
	var purchaseCount int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM purchases WHERE user_id = ?`, userID).Scan(&purchaseCount); err != nil {
		t.Fatalf("count purchases: %v", err)
	}
	if purchaseCount == 0 {
		t.Errorf("purchases were deleted — financial records must be retained")
	}

	// Transient categories gone.
	for _, q := range []string{
		`SELECT COUNT(*) FROM notifications WHERE user_id = ?`,
		`SELECT COUNT(*) FROM device_tokens WHERE user_id = ?`,
		`SELECT COUNT(*) FROM notification_prefs WHERE user_id = ?`,
		`SELECT COUNT(*) FROM achievements WHERE user_id = ?`,
	} {
		var n int
		if err := s.db.QueryRowContext(ctx, q, userID).Scan(&n); err != nil {
			t.Fatalf("count: %v", err)
		}
		if n != 0 {
			t.Errorf("transient rows survived: %q -> %d", q, n)
		}
	}

	// A user_erased audit row was written (accountability).
	var erasedAudit int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM audit_log WHERE action = 'user_erased' AND target_id = ?`,
		userID).Scan(&erasedAudit); err != nil {
		t.Fatalf("count erase audit: %v", err)
	}
	if erasedAudit != 1 {
		t.Errorf("user_erased audit rows = %d, want 1", erasedAudit)
	}

	// The clincher: no identifying token survives anywhere in the database.
	for _, tok := range tokens {
		if hits := scanForToken(t, s.db, tok); len(hits) > 0 {
			t.Errorf("PII token %q survived erasure in: %s", tok, strings.Join(hits, ", "))
		}
	}

	// Erasure is idempotent — the now-tombstoned row is no longer erasable
	// and no longer exportable.
	if _, err := s.EraseUser(ctx, f.studioID, f.instructorID, userID); err != ErrNotFound {
		t.Errorf("second erase err = %v, want ErrNotFound", err)
	}
	if _, err := s.ExportUserData(ctx, f.studioID, userID); err != ErrNotFound {
		t.Errorf("export after erase err = %v, want ErrNotFound", err)
	}
}

// scanForToken walks every text column of every table looking for needle.
// Returns "table.column" for each table that still contains it — a generic
// safety net so a newly-added PII column can't silently escape erasure.
func scanForToken(t *testing.T, db *sql.DB, needle string) []string {
	t.Helper()
	ctx := context.Background()
	tableRows, err := db.QueryContext(ctx,
		`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'`)
	if err != nil {
		t.Fatalf("list tables: %v", err)
	}
	var tables []string
	for tableRows.Next() {
		var name string
		if err := tableRows.Scan(&name); err != nil {
			t.Fatalf("scan table: %v", err)
		}
		tables = append(tables, name)
	}
	tableRows.Close()

	var hits []string
	for _, tbl := range tables {
		colRows, err := db.QueryContext(ctx, fmt.Sprintf(`PRAGMA table_info(%q)`, tbl))
		if err != nil {
			t.Fatalf("table_info %s: %v", tbl, err)
		}
		var cols []string
		for colRows.Next() {
			var (
				cid        int
				name, typ  string
				notNull    int
				dflt       sql.NullString
				primaryKey int
			)
			if err := colRows.Scan(&cid, &name, &typ, &notNull, &dflt, &primaryKey); err != nil {
				t.Fatalf("scan col: %v", err)
			}
			cols = append(cols, name)
		}
		colRows.Close()

		for _, col := range cols {
			q := fmt.Sprintf(`SELECT COUNT(*) FROM %q WHERE CAST(%q AS TEXT) LIKE ?`, tbl, col)
			var n int
			if err := db.QueryRowContext(ctx, q, "%"+needle+"%").Scan(&n); err != nil {
				t.Fatalf("scan %s.%s: %v", tbl, col, err)
			}
			if n > 0 {
				hits = append(hits, fmt.Sprintf("%s.%s", tbl, col))
			}
		}
	}
	return hits
}
