package api

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

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
				"email":     "audit-" + store.NewID()[:8] + "@studio.com",
				"full_name": "Audit Staff",
			}
		},
	},
	{
		name:           "staff_update",
		expectedAction: "staff_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			email := "audit-upd-" + store.NewID()[:8] + "@studio.com"
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
	{
		name:           "class_update",
		expectedAction: "class_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			classID := seedClass(t, r, time.Now().UTC().Add(48*time.Hour))
			return http.MethodPatch, "/admin/classes/" + classID, map[string]any{
				"title": "Renamed",
			}
		},
	},
	{
		name:           "rule_create",
		expectedAction: "rule_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			ct, inst, room := lookupSchedulingPrereqs(t, r)
			anchor := time.Now().UTC().AddDate(0, 0, 7)
			// weekdays uses 0=Mon..6=Sun (Go's Weekday is 0=Sun..6=Sat).
			weekday := (int(anchor.Weekday()) + 6) % 7
			return http.MethodPost, "/admin/classes", map[string]any{
				"class_type_id":    ct,
				"instructor_id":    inst,
				"room_id":          room,
				"title":            "Audit Recurring",
				"starts_at":        anchor.Format(time.RFC3339),
				"duration_minutes": 60,
				"capacity":         8,
				"recurrence": map[string]any{
					"frequency":   "weekly",
					"weekdays":    []int{weekday},
					"starts_on":   anchor.Format("2006-01-02"),
					"occurrences": 3,
				},
			}
		},
	},
	{
		name:           "stripe_credentials_update",
		expectedAction: "stripe_credentials_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			// Touch only non-secret fields so the sealer (not configured in
			// the test rig) isn't exercised — the audit row fires either way.
			return http.MethodPatch, "/admin/studio/stripe-credentials", map[string]any{
				"mode":            "test",
				"publishable_key": "pk_test_audit",
			}
		},
	},
	{
		name:           "purchase_refund",
		expectedAction: "purchase_refund",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			purchaseID := seedCompletedPurchase(t, r, 5000)
			return http.MethodPost, "/admin/purchases/" + purchaseID + "/refund", map[string]any{
				"refund_amount_minor": 1000,
				"note":                "audit matrix",
			}
		},
	},
	{
		name:           "subscription_cancel",
		expectedAction: "subscription_cancel",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			subID := seedActiveSubscription(t, r)
			return http.MethodPost, "/admin/subscriptions/" + subID + "/cancel", nil
		},
	},
	{
		name:           "theme_create",
		expectedAction: "theme_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			return http.MethodPost, "/admin/themes", map[string]any{
				"name": "Audit Theme",
				"mode": "light",
				"tokens": map[string]any{
					"primary":    "#B05C3B",
					"accent":     "#C8973F",
					"background": "#FAF5EF",
					"surface":    "#FFFFFF",
					"text":       "#2D2218",
					"textMuted":  "#8F8174",
				},
			}
		},
	},
	{
		name:           "theme_update",
		expectedAction: "theme_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			id := seedTheme(t, r, "Pre-Audit Theme")
			name := "Renamed Theme"
			return http.MethodPatch, "/admin/themes/" + id, map[string]any{
				"name": name,
			}
		},
	},
	{
		name:           "theme_activate",
		expectedAction: "theme_activate",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			id := seedTheme(t, r, "Activate Me")
			return http.MethodPost, "/admin/themes/" + id + "/activate", nil
		},
	},
	{
		name:           "studio_config_update",
		expectedAction: "studio_config_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			return http.MethodPatch, "/admin/studio/config", map[string]any{
				"welcome_message": "Audit Welcome",
			}
		},
	},
	{
		name:           "product_create",
		expectedAction: "product_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			return http.MethodPost, "/admin/products", map[string]any{
				"name":         "Audit Product",
				"price_minor":  5000,
				"billing_type": "one_time",
				"pass_kind":    "credit",
				"credits":      5,
			}
		},
	},
	{
		name:           "product_update",
		expectedAction: "product_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			id := seedProduct(t, r, "credit", 5)
			return http.MethodPatch, "/admin/products/" + id, map[string]any{
				"price_minor": 6000,
			}
		},
	},
	{
		name:           "product_archive",
		expectedAction: "product_archive",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			id := seedProduct(t, r, "credit", 5)
			return http.MethodDelete, "/admin/products/" + id, nil
		},
	},
	{
		name:           "series_update",
		expectedAction: "series_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			id := seedEnrollment(t, r, "Pre-Audit Series")
			return http.MethodPatch, "/admin/enrollments/" + id, map[string]any{
				"title": "Renamed Series",
			}
		},
	},
	{
		name:           "discount_create",
		expectedAction: "discount_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			code := "AUDIT" + store.NewID()[:6]
			return http.MethodPost, "/admin/discounts", map[string]any{
				"code":  code,
				"kind":  "percent",
				"value": 10,
			}
		},
	},
	{
		name:           "discount_archive",
		expectedAction: "discount_archive",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			id := seedDiscount(t, r)
			return http.MethodDelete, "/admin/discounts/" + id, nil
		},
	},
	{
		name:           "attendance_mark",
		expectedAction: "attendance_mark",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			bookingID := seedBookingForAttendance(t, r)
			return http.MethodPost, "/admin/bookings/" + bookingID + "/attendance", map[string]any{
				"status": "attended",
				"via":    "manual",
			}
		},
	},
	{
		name:           "waitlist_promote",
		expectedAction: "waitlist_promote",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			classID := seedClassWithWaitlister(t, r)
			return http.MethodPost, "/admin/classes/" + classID + "/promote", nil
		},
	},
	{
		name:           "booking_create_admin",
		expectedAction: "booking_create_admin",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			classID := seedClass(t, r, time.Now().UTC().Add(24*time.Hour))
			studentID := seedStudent(t, r)
			entID := seedEntitlement(t, r, studentID, "unlimited", 0)
			return http.MethodPost, "/admin/classes/" + classID + "/bookings", map[string]any{
				"user_id":        studentID,
				"entitlement_id": entID,
			}
		},
	},
	{
		name:           "booking_cancel_admin",
		expectedAction: "booking_cancel_admin",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			bookingID := seedBookingForAttendance(t, r)
			return http.MethodPost, "/admin/bookings/" + bookingID + "/cancel", map[string]any{
				"refund_credit": true,
				"reason":        "audit matrix",
			}
		},
	},
	{
		name:           "conversation_create",
		expectedAction: "conversation_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			student := seedStudent(t, r)
			return http.MethodPost, "/conversations", map[string]any{
				"kind":       "group",
				"title":      "Audit Group",
				"member_ids": []string{student},
			}
		},
	},
	{
		name:           "dm_open",
		expectedAction: "dm_open",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			student := seedStudent(t, r)
			return http.MethodPost, "/conversations", map[string]any{
				"kind":    "dm",
				"user_id": student,
			}
		},
	},
	{
		name:           "message_send",
		expectedAction: "message_send",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			convID := seedConversation(t, r)
			return http.MethodPost, "/conversations/" + convID + "/messages",
				map[string]any{"body": "audit matrix"}
		},
	},
	{
		name:           "message_edit",
		expectedAction: "message_edit",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			convID := seedConversation(t, r)
			msgID := seedMessage(t, r, convID)
			return http.MethodPatch, "/conversations/" + convID + "/messages/" + msgID,
				map[string]any{"body": "edited by audit matrix"}
		},
	},
	{
		name:           "message_delete",
		expectedAction: "message_delete",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			convID := seedConversation(t, r)
			msgID := seedMessage(t, r, convID)
			return http.MethodDelete, "/conversations/" + convID + "/messages/" + msgID, nil
		},
	},
	{
		name:           "conversation_member_add",
		expectedAction: "conversation_member_add",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			convID := seedConversation(t, r)
			student := seedStudent(t, r)
			return http.MethodPost, "/conversations/" + convID + "/members",
				map[string]any{"member_ids": []string{student}}
		},
	},
	{
		name:           "user_erased",
		expectedAction: "user_erased",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			studentID := seedStudent(t, r)
			return http.MethodDelete, "/admin/students/" + studentID, nil
		},
	},
	{
		name:           "student_note_create",
		expectedAction: "student_note_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			studentID := seedStudent(t, r)
			return http.MethodPost, "/admin/students/" + studentID + "/notes",
				map[string]any{"body": "Prefers props · audit matrix"}
		},
	},
	{
		name:           "student_note_update",
		expectedAction: "student_note_update",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			noteID := seedStudentNote(t, r)
			return http.MethodPatch, "/admin/notes/" + noteID,
				map[string]any{"body": "Edited note body"}
		},
	},
	{
		name:           "student_note_delete",
		expectedAction: "student_note_delete",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			noteID := seedStudentNote(t, r)
			return http.MethodDelete, "/admin/notes/" + noteID, nil
		},
	},
	{
		// Lazy-create the class group chat. The rig's actor is a manager
		// and managers are staff in their studio, so eligibility is met
		// automatically. Re-opening returns the same conversation without
		// a new audit row — this case only fires the create branch.
		name:           "class_chat_create",
		expectedAction: "class_chat_create",
		build: func(t *testing.T, r *testRig) (string, string, any) {
			classID := seedClass(t, r, time.Now().UTC().Add(24*time.Hour))
			return http.MethodPost, "/classes/" + classID + "/chat", nil
		},
	},
}

// seedStudentNote drops a single note onto a freshly-seeded student
// owned by the rig's manager, so the update/delete audit cases above
// have a real row to operate on. Returns the note id.
func seedStudentNote(t *testing.T, r *testRig) string {
	t.Helper()
	studentID := seedStudent(t, r)
	id, err := r.server.store.CreateStudentNote(
		context.Background(), r.studioID, r.mgrID, studentID,
		"Seeded for audit matrix",
	)
	if err != nil {
		t.Fatalf("seed note: %v", err)
	}
	return id
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
	id := store.NewID()
	mustExec(t, r.server.store,
		`INSERT INTO class_types (id, studio_id, name) VALUES (?, ?, ?)`,
		id, r.studioID, name)
	return id
}

func seedPromotion(t *testing.T, r *testRig, title string) string {
	t.Helper()
	id := store.NewID()
	mustExec(t, r.server.store,
		`INSERT INTO promotions (id, studio_id, title) VALUES (?, ?, ?)`,
		id, r.studioID, title)
	return id
}

func seedStaff(t *testing.T, r *testRig, role, email, name string) string {
	t.Helper()
	id := store.NewID()
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
	id := store.NewID()
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
	id := store.NewID()
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
	id := store.NewID()
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
	id := store.NewID()
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

// seedBookedStudentWithToken creates a student, an entitlement, a class
// (starting in ~15 min so it's inside the scan window), and a booking with
// a per-booking checkin_token. Returns (classID, token) for a /scan call
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

	studentID := store.NewID()
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'student', ?, 'Audit Student')`,
		studentID, r.studioID, studentID+"@test.com")

	classID = store.NewID()
	// Start in 15 minutes — comfortably inside the 30-min-before window.
	start := time.Now().UTC().Add(15 * time.Minute)
	end := start.Add(60 * time.Minute)
	mustExec(t, r.server.store, `INSERT INTO classes
		(id, studio_id, class_type_id, instructor_id, room_id, title, starts_at, ends_at, capacity, status)
		VALUES (?, ?, ?, ?, ?, 'Audit Class', ?, ?, 10, 'scheduled')`,
		classID, r.studioID, classTypeID, instructorID, roomID,
		start.Format(time.RFC3339), end.Format(time.RFC3339))

	entID := store.NewID()
	mustExec(t, r.server.store, `INSERT INTO entitlements
		(id, studio_id, user_id, label, pass_kind, status)
		VALUES (?, ?, ?, 'Audit Pass', 'unlimited', 'active')`,
		entID, r.studioID, studentID)
	mustExec(t, r.server.store,
		`INSERT INTO entitlement_class_types (entitlement_id, class_type_id) VALUES (?, ?)`,
		entID, classTypeID)

	bookingID := store.NewID()
	token = "AUDIT-" + store.NewID()
	mustExec(t, r.server.store, `INSERT INTO bookings
		(id, studio_id, class_id, user_id, entitlement_id, booked_by_role,
		 cancel_cutoff_hours, status, checkin_token)
		VALUES (?, ?, ?, ?, ?, 'student', 12, 'booked', ?)`,
		bookingID, r.studioID, classID, studentID, entID, token)

	return classID, token
}

// seedTheme inserts a non-preset theme directly with a legible token blob.
func seedTheme(t *testing.T, r *testRig, name string) string {
	t.Helper()
	id := store.NewID()
	tokens := `{"primary":"#B05C3B","accent":"#C8973F","background":"#FAF5EF",` +
		`"surface":"#FFFFFF","text":"#2D2218","text_muted":"#8F8174"}`
	mustExec(t, r.server.store,
		`INSERT INTO themes (id, studio_id, name, is_preset, mode, tokens)
		 VALUES (?, ?, ?, 0, 'light', ?)`,
		id, r.studioID, name, tokens)
	return id
}

// seedEnrollment inserts a minimal series row. session_count and capacity
// satisfy the NOT NULL constraints; nothing in the update path looks at
// them.
func seedEnrollment(t *testing.T, r *testRig, title string) string {
	t.Helper()
	id := store.NewID()
	mustExec(t, r.server.store,
		`INSERT INTO enrollments (id, studio_id, title, session_count, capacity)
		 VALUES (?, ?, ?, 4, 10)`,
		id, r.studioID, title)
	return id
}

// seedDiscount inserts a fixed-amount discount with no code so the archive
// route has a row to retire.
func seedDiscount(t *testing.T, r *testRig) string {
	t.Helper()
	id := store.NewID()
	mustExec(t, r.server.store,
		`INSERT INTO discounts (id, studio_id, kind, value, created_by)
		 VALUES (?, ?, 'fixed_minor', 500, ?)`,
		id, r.studioID, r.mgrID)
	return id
}

// seedCompletedPurchase inserts a completed purchase paid in full so the
// refund route has a target whose status passes the "only refund completed"
// gate.
func seedCompletedPurchase(t *testing.T, r *testRig, amountMinor int) string {
	t.Helper()
	productID := seedProduct(t, r, "credit", 5)
	studentID := seedStudent(t, r)
	id := store.NewID()
	mustExec(t, r.server.store,
		`INSERT INTO purchases
		     (id, studio_id, user_id, product_id, list_price_minor, amount_minor,
		      currency, payment_method, initiated_by, actor_role, status)
		 VALUES (?, ?, ?, ?, ?, ?, 'GBP', 'cash', ?, 'manager', 'completed')`,
		id, r.studioID, studentID, productID, amountMinor, amountMinor, r.mgrID)
	return id
}

// seedBookingForAttendance creates a student + entitlement + class + booking
// in a state the attendance endpoint accepts (status != 'cancelled').
func seedBookingForAttendance(t *testing.T, r *testRig) string {
	t.Helper()
	studentID := seedStudent(t, r)
	entID := seedEntitlement(t, r, studentID, "unlimited", 0)
	classID := seedClass(t, r, time.Now().UTC().Add(2*time.Hour))
	bookingID := store.NewID()
	mustExec(t, r.server.store, `INSERT INTO bookings
		(id, studio_id, class_id, user_id, entitlement_id, booked_by_role,
		 cancel_cutoff_hours, status, checkin_token)
		VALUES (?, ?, ?, ?, ?, 'student', 12, 'booked', ?)`,
		bookingID, r.studioID, classID, studentID, entID, store.NewID())
	return bookingID
}

// seedClassWithWaitlister inserts a class at-capacity-equivalent and a
// waitlister with an eligible unlimited pass, so PromoteWaitlist has a
// candidate to bump into the open seat.
func seedClassWithWaitlister(t *testing.T, r *testRig) string {
	t.Helper()
	ct, inst, room := lookupSchedulingPrereqs(t, r)
	classID := store.NewID()
	start := time.Now().UTC().Add(24 * time.Hour)
	end := start.Add(60 * time.Minute)
	// Capacity 1 with no current bookings → the seat is open and the
	// waitlister gets bumped immediately on promote.
	mustExec(t, r.server.store, `INSERT INTO classes
		(id, studio_id, class_type_id, instructor_id, room_id, title,
		 starts_at, ends_at, capacity, status)
		VALUES (?, ?, ?, ?, ?, 'Audit Promote', ?, ?, 1, 'scheduled')`,
		classID, r.studioID, ct, inst, room,
		start.Format(time.RFC3339), end.Format(time.RFC3339))

	studentID := seedStudent(t, r)
	entID := seedEntitlement(t, r, studentID, "unlimited", 0)
	_ = entID // entitlement attaches via entitlement_class_types in the seed helper
	mustExec(t, r.server.store, `INSERT INTO waitlist_entries
		(id, class_id, user_id, position, status)
		VALUES (?, ?, ?, 1, 'waiting')`,
		store.NewID(), classID, studentID)
	return classID
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
