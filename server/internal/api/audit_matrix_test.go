package api

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/studio52/yoga-school/server/internal/store"
)

// auditCase declares a sensitive admin endpoint that must leave a row in
// audit_log when it succeeds. Each case knows how to build a request that
// succeeds against a fresh rig + the audit action it should produce.
type auditCase struct {
	name           string
	expectedAction string
	build          func(t *testing.T, r *testRig) (method, url string, body any)
}

// auditMatrix lists every endpoint that should write to audit_log on success.
// Adding a new sensitive admin endpoint without updating this list is the
// expected failure mode the matrix catches.
var auditMatrix = []auditCase{
	{
		name:           "class_create",
		expectedAction: "class_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			ct, inst, room := lookupSchedulingPrereqs(t, r)
			start := time.Now().UTC().Add(24 * time.Hour).Format(time.RFC3339)
			return http.MethodPost, "/admin/classes", map[string]any{
				"class_type_id":    ct,
				"instructor_id":    inst,
				"room_id":          room,
				"title":            "Audit Class",
				"starts_at":        start,
				"duration_minutes": 60,
				"capacity":         8,
			}
		},
	},
	{
		name:           "class_cancel",
		expectedAction: "class_cancel",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			classID := seedClass(t, r, time.Now().UTC().Add(24*time.Hour))
			return http.MethodDelete, "/admin/classes/" + classID, nil
		},
	},
	{
		name:           "cash_grant",
		expectedAction: "cash_grant",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			studentID := seedStudent(t, r)
			productID := seedProduct(t, r, "credit", 5)
			return http.MethodPost, "/admin/students/" + studentID + "/grant", map[string]any{
				"product_id":     productID,
				"payment_method": "cash",
			}
		},
	},
	{
		name:           "credit_adjust",
		expectedAction: "credit_adjust",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			studentID := seedStudent(t, r)
			entID := seedEntitlement(t, r, studentID, "credit", 5)
			return http.MethodPost,
				"/admin/students/" + studentID + "/entitlements/" + entID + "/adjust",
				map[string]any{"delta": 2, "reason": "audit matrix"}
		},
	},
	{
		name:           "void",
		expectedAction: "void",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			studentID := seedStudent(t, r)
			entID := seedEntitlement(t, r, studentID, "credit", 5)
			return http.MethodPost,
				"/admin/entitlements/" + entID + "/void",
				map[string]any{"refund": "none", "reason": "audit matrix"}
		},
	},
	{
		name:           "series_create",
		expectedAction: "series_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			_, inst, room := lookupSchedulingPrereqs(t, r)
			startsOn := time.Now().UTC().AddDate(0, 0, 7).Format("2006-01-02")
			return http.MethodPost, "/admin/enrollments", map[string]any{
				"title":         "Audit Series",
				"description":   "matrix",
				"price_minor":   5000,
				"instructor_id": inst,
				"room_id":       room,
				"weekday":       1,
				"start_hour":    18,
				"start_minute":  0,
				"duration_mins": 60,
				"capacity":      10,
				"session_count": 4,
				"starts_on":     startsOn,
			}
		},
	},
	{
		name:           "template_create",
		expectedAction: "template_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			ct, inst, room := lookupSchedulingPrereqs(t, r)
			startsOn := time.Now().UTC().AddDate(0, 0, 7).Format("2006-01-02")
			return http.MethodPost, "/admin/class-templates", map[string]any{
				"title":         "Audit Template",
				"class_type_id": ct,
				"instructor_id": inst,
				"room_id":       room,
				"weekday":       2,
				"start_hour":    9,
				"start_minute":  0,
				"duration_mins": 60,
				"capacity":      10,
				"weeks":         4,
				"starts_on":     startsOn,
			}
		},
	},
	{
		name:           "template_revert",
		expectedAction: "template_revert",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			tplID := seedTemplate(t, r)
			return http.MethodPost, "/admin/class-templates/" + tplID + "/undo", nil
		},
	},
	{
		name:           "class_type_create",
		expectedAction: "class_type_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			return http.MethodPost, "/admin/class-types", map[string]any{
				"name": "Audit Pilates",
			}
		},
	},
	{
		name:           "class_type_update",
		expectedAction: "class_type_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			id := seedClassType(t, r, "Audit Edit Me")
			return http.MethodPatch, "/admin/class-types/" + id, map[string]any{
				"name": "Edited",
			}
		},
	},
	{
		name:           "promotion_create",
		expectedAction: "promotion_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			return http.MethodPost, "/admin/promotions", map[string]any{
				"title": "Audit Promo",
			}
		},
	},
	{
		name:           "promotion_update",
		expectedAction: "promotion_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			id := seedPromotion(t, r, "Edit Me")
			return http.MethodPatch, "/admin/promotions/" + id, map[string]any{
				"title": "Edited",
			}
		},
	},
	{
		name:           "promotion_archive",
		expectedAction: "promotion_archive",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			id := seedPromotion(t, r, "Archive Me")
			return http.MethodDelete, "/admin/promotions/" + id, nil
		},
	},
	{
		name:           "staff_create",
		expectedAction: "staff_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			return http.MethodPost, "/admin/staff", map[string]any{
				"role":      "instructor",
				"email":     "audit-" + uuid.NewString()[:8] + "@studio.com",
				"full_name": "Audit Staff",
			}
		},
	},
	{
		name:           "staff_update",
		expectedAction: "staff_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			email := "audit-upd-" + uuid.NewString()[:8] + "@studio.com"
			id := seedStaff(t, r, "instructor", email, "Upd Me")
			return http.MethodPatch, "/admin/staff/" + id, map[string]any{
				"role":      "manager",
				"email":     email,
				"full_name": "Upd Me",
			}
		},
	},
	{
		name:           "attendance_scan",
		expectedAction: "attendance_scan",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			classID, token := seedBookedStudentWithToken(t, r)
			return http.MethodPost, "/admin/checkin/scan", map[string]any{
				"token": token, "class_id": classID,
			}
		},
	},
}

// TestAuditMatrix_EachSensitiveAdminRouteWritesAuditRow runs every declared
// case on a fresh rig and asserts: (a) the request succeeds (2xx) and (b) at
// least one audit_log row with the expected action exists afterward.
func TestAuditMatrix_EachSensitiveAdminRouteWritesAuditRow(t *testing.T) {
	for _, c := range auditMatrix {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t)
			before := countAuditRows(t, r, c.expectedAction)

			method, url, body := c.build(t, r)
			res := r.do(method, url, body)
			if res.StatusCode >= 300 {
				rawBody, _ := io.ReadAll(res.Body)
				t.Fatalf("%s %s: got %d body=%s", method, url, res.StatusCode, rawBody)
			}

			after := countAuditRows(t, r, c.expectedAction)
			if after <= before {
				t.Errorf("%s %s: no new %q audit row (before=%d after=%d)",
					method, url, c.expectedAction, before, after)
			}
		})
	}
}

// ---- helpers ----

func countAuditRows(t *testing.T, r *testRig, action string) int {
	t.Helper()
	var n int
	if err := store.TestDB(r.server.store).QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM audit_log WHERE studio_id = ? AND action = ?`,
		r.studioID, action,
	).Scan(&n); err != nil {
		t.Fatalf("count audit: %v", err)
	}
	return n
}

func seedClassType(t *testing.T, r *testRig, name string) string {
	t.Helper()
	id := uuid.NewString()
	mustExec(t, r.server.store,
		`INSERT INTO class_types (id, studio_id, name) VALUES (?, ?, ?)`,
		id, r.studioID, name)
	return id
}

func seedPromotion(t *testing.T, r *testRig, title string) string {
	t.Helper()
	id := uuid.NewString()
	mustExec(t, r.server.store,
		`INSERT INTO promotions (id, studio_id, title) VALUES (?, ?, ?)`,
		id, r.studioID, title)
	return id
}

func seedStaff(t *testing.T, r *testRig, role, email, name string) string {
	t.Helper()
	id := uuid.NewString()
	mustExec(t, r.server.store,
		`INSERT INTO users (id, studio_id, role, email, full_name)
		 VALUES (?, ?, ?, ?, ?)`,
		id, r.studioID, role, email, name)
	return id
}

// lookupSchedulingPrereqs returns the IDs of one class_type, one instructor,
// and one room in the rig's studio. The rig fixture seeds one of each.
func lookupSchedulingPrereqs(t *testing.T, r *testRig) (classTypeID, instructorID, roomID string) {
	t.Helper()
	ctx := context.Background()
	db := store.TestDB(r.server.store)
	if err := db.QueryRowContext(ctx,
		`SELECT id FROM class_types WHERE studio_id = ? LIMIT 1`, r.studioID,
	).Scan(&classTypeID); err != nil {
		t.Fatalf("class_type lookup: %v", err)
	}
	if err := db.QueryRowContext(ctx,
		`SELECT id FROM users WHERE studio_id = ? AND role = 'instructor' LIMIT 1`, r.studioID,
	).Scan(&instructorID); err != nil {
		t.Fatalf("instructor lookup: %v", err)
	}
	if err := db.QueryRowContext(ctx,
		`SELECT id FROM rooms WHERE studio_id = ? LIMIT 1`, r.studioID,
	).Scan(&roomID); err != nil {
		t.Fatalf("room lookup: %v", err)
	}
	return
}

// seedStudent creates a student row in the rig's studio.
func seedStudent(t *testing.T, r *testRig) string {
	t.Helper()
	id := uuid.NewString()
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'student', ?, 'Audit Student')`,
		id, r.studioID, "stu-"+id[:8]+"@test.com")
	return id
}

// seedProduct creates a product (credit or unlimited) covering the fixture's
// class type. Returns the new product's ID.
func seedProduct(t *testing.T, r *testRig, passKind string, credits int) string {
	t.Helper()
	classTypeID, _, _ := lookupSchedulingPrereqs(t, r)
	id := uuid.NewString()
	var creditsArg any
	if passKind == "credit" {
		creditsArg = credits
	}
	mustExec(t, r.server.store, `INSERT INTO products
		(id, studio_id, name, price_minor, billing_type, pass_kind, credits)
		VALUES (?, ?, 'Audit Product', 5000, 'one_time', ?, ?)`,
		id, r.studioID, passKind, creditsArg)
	mustExec(t, r.server.store,
		`INSERT INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`,
		id, classTypeID)
	return id
}

// seedEntitlement issues an active entitlement to the given student covering
// the fixture's class type. Mirrors the production schema (no purchase row —
// not needed for adjust/void tests).
func seedEntitlement(t *testing.T, r *testRig, studentID, passKind string, credits int) string {
	t.Helper()
	classTypeID, _, _ := lookupSchedulingPrereqs(t, r)
	id := uuid.NewString()
	var creditsArg any
	if passKind == "credit" {
		creditsArg = credits
	}
	mustExec(t, r.server.store, `INSERT INTO entitlements
		(id, studio_id, user_id, label, pass_kind, credits_total, credits_remaining, status)
		VALUES (?, ?, ?, 'Audit Pass', ?, ?, ?, 'active')`,
		id, r.studioID, studentID, passKind, creditsArg, creditsArg)
	mustExec(t, r.server.store,
		`INSERT INTO entitlement_class_types (entitlement_id, class_type_id) VALUES (?, ?)`,
		id, classTypeID)
	return id
}

// seedClass inserts a scheduled class on the fixture defaults. Returns its ID.
func seedClass(t *testing.T, r *testRig, startsAt time.Time) string {
	t.Helper()
	ct, inst, room := lookupSchedulingPrereqs(t, r)
	id := uuid.NewString()
	end := startsAt.Add(60 * time.Minute)
	mustExec(t, r.server.store, `INSERT INTO classes
		(id, studio_id, class_type_id, instructor_id, room_id, title, starts_at, ends_at, capacity, status)
		VALUES (?, ?, ?, ?, ?, 'Audit Class', ?, ?, 10, 'scheduled')`,
		id, r.studioID, ct, inst, room,
		startsAt.UTC().Format(time.RFC3339), end.UTC().Format(time.RFC3339))
	return id
}

// seedTemplate creates a class template via the production endpoint so that
// generated classes + the audit row from create are in place. Returns the
// template's ID — caller can then revert it to exercise template_revert.
func seedTemplate(t *testing.T, r *testRig) string {
	t.Helper()
	ct, inst, room := lookupSchedulingPrereqs(t, r)
	startsOn := time.Now().UTC().AddDate(0, 0, 14).Format("2006-01-02")
	res := r.do(http.MethodPost, "/admin/class-templates", map[string]any{
		"title":         "Pre-Audit Template",
		"class_type_id": ct,
		"instructor_id": inst,
		"room_id":       room,
		"weekday":       3,
		"start_hour":    18,
		"start_minute":  0,
		"duration_mins": 60,
		"capacity":      10,
		"weeks":         2,
		"starts_on":     startsOn,
	})
	if res.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(res.Body)
		t.Fatalf("seed template: %d %s", res.StatusCode, body)
	}
	out := decode[map[string]any](t, res)
	id, _ := out["id"].(string)
	if id == "" {
		t.Fatalf("seed template: response missing id: %+v", out)
	}
	return id
}

// seedBookedStudentWithToken creates a student, an entitlement, a class, a
// booking, and a check-in token. Returns (classID, token) for a /scan call
// that should succeed.
func seedBookedStudentWithToken(t *testing.T, r *testRig) (classID, token string) {
	t.Helper()
	ctx := context.Background()
	db := store.TestDB(r.server.store)

	var classTypeID, roomID, instructorID string
	if err := db.QueryRowContext(ctx,
		`SELECT id FROM class_types WHERE studio_id = ? LIMIT 1`, r.studioID,
	).Scan(&classTypeID); err != nil {
		t.Fatalf("class_type lookup: %v", err)
	}
	if err := db.QueryRowContext(ctx,
		`SELECT id FROM rooms WHERE studio_id = ? LIMIT 1`, r.studioID,
	).Scan(&roomID); err != nil {
		t.Fatalf("room lookup: %v", err)
	}
	if err := db.QueryRowContext(ctx,
		`SELECT id FROM users WHERE studio_id = ? AND role = 'instructor' LIMIT 1`, r.studioID,
	).Scan(&instructorID); err != nil {
		t.Fatalf("instructor lookup: %v", err)
	}

	studentID := uuid.NewString()
	token = "AUDIT-" + uuid.NewString()[:8]
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name, checkin_token)
		VALUES (?, ?, 'student', ?, 'Audit Student', ?)`,
		studentID, r.studioID, studentID+"@test.com", token)

	classID = uuid.NewString()
	start := time.Now().UTC().Add(1 * time.Hour)
	end := start.Add(60 * time.Minute)
	mustExec(t, r.server.store, `INSERT INTO classes
		(id, studio_id, class_type_id, instructor_id, room_id, title, starts_at, ends_at, capacity, status)
		VALUES (?, ?, ?, ?, ?, 'Audit Class', ?, ?, 10, 'scheduled')`,
		classID, r.studioID, classTypeID, instructorID, roomID,
		start.Format(time.RFC3339), end.Format(time.RFC3339))

	entID := uuid.NewString()
	mustExec(t, r.server.store, `INSERT INTO entitlements
		(id, studio_id, user_id, label, pass_kind, status)
		VALUES (?, ?, ?, 'Audit Pass', 'unlimited', 'active')`,
		entID, r.studioID, studentID)
	mustExec(t, r.server.store,
		`INSERT INTO entitlement_class_types (entitlement_id, class_type_id) VALUES (?, ?)`,
		entID, classTypeID)

	bookingID := uuid.NewString()
	mustExec(t, r.server.store, `INSERT INTO bookings
		(id, studio_id, class_id, user_id, entitlement_id, booked_by_role, cancel_cutoff_hours, status)
		VALUES (?, ?, ?, ?, ?, 'student', 12, 'booked')`,
		bookingID, r.studioID, classID, studentID, entID)

	return classID, token
}

// Tiny sanity check: confirm the auditMatrix list is non-empty so a future
// refactor doesn't silently neuter it.
func TestAuditMatrix_NonEmpty(t *testing.T) {
	if len(auditMatrix) == 0 {
		t.Fatal("auditMatrix is empty — at least the new sensitive endpoints should be listed")
	}
	// Action names must be unique — two cases sharing the same expected_action
	// would let one regression hide behind the other.
	seen := map[string]string{}
	for _, c := range auditMatrix {
		if prev, ok := seen[c.expectedAction]; ok {
			if !strings.EqualFold(prev, c.name) {
				t.Errorf("duplicate expected_action %q in cases %q and %q",
					c.expectedAction, prev, c.name)
			}
		}
		seen[c.expectedAction] = c.name
	}
}
