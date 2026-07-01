package api

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"

	"github.com/studio52/yoga-school/server/internal/auth"
	"github.com/studio52/yoga-school/server/internal/store"
)

// Endpoints that intentionally bypass auth or role gates. Format
// "METHOD /path/pattern" exactly as chi.Walk emits it.
//
// The /dev/* endpoints are intentionally unauthenticated — they're gated at
// the handler level by FIREBASE_AUTH_EMULATOR_HOST presence (refuse with
// 404 in any production-shaped config). The matrix test runs without that
// env set, so they correctly return 404 instead of 401.
var (
	authBypassRoutes = map[string]bool{
		"POST /dev/reset-test-state": true,
		"POST /dev/fill-class":       true,
		"POST /dev/configure-stripe": true,
		"POST /dev/seed-membership":  true,
		// Load-balancer probe — must be reachable without a token.
		// See handleHealthz for the rationale (and the prod checklist
		// item about firewalling the port off the public internet).
		"GET /healthz": true,
		// Stripe webhook — Stripe calls this server-to-server with no bearer
		// token. It authenticates by verifying the Stripe-Signature header
		// against the studio's webhook secret (see handleStripeWebhook), so a
		// missing bearer is expected, not a hole.
		"POST /stripe/webhook/{studioID}": true,
	}
	roleBypassRoutes = map[string]bool{}
)

// staffAllowedRoutes is the *policy declaration* for the instructor role:
// admin routes an instructor may hit. Anything under /api/v1/admin/* NOT in
// this set must reject instructors with 403 (manager+ only). Keeping the
// list explicit makes route-tier changes deliberate — a refactor that
// accidentally opens a money endpoint to instructors fails the matrix loudly.
var staffAllowedRoutes = map[string]bool{
	"GET /api/v1/admin/classes":                   true,
	"GET /api/v1/admin/classes/{id}/roster":       true,
	"POST /api/v1/admin/bookings/{id}/attendance": true,
	"POST /api/v1/admin/classes/{id}/promote":     true,
	"POST /api/v1/admin/checkin/scan":             true,
	"GET /api/v1/admin/class-types":               true,
	"GET /api/v1/admin/instructors":               true,
	"GET /api/v1/admin/rooms":                     true,
	"GET /api/v1/admin/class-templates":           true,
	"GET /api/v1/admin/enrollments":               true,
	"GET /api/v1/admin/enrollments/{id}/roster":   true,
	"GET /api/v1/admin/students":                  true,
	"GET /api/v1/admin/students/{id}":             true,
	// Student notes — staff-tier by design (the whole point is letting
	// instructors share context). Author-only edit/delete is enforced
	// inside the store, not at the route gate.
	"GET /api/v1/admin/students/{id}/notes":  true,
	"POST /api/v1/admin/students/{id}/notes": true,
	"PATCH /api/v1/admin/notes/{id}":         true,
	"DELETE /api/v1/admin/notes/{id}":        true,
}

// staffOnlyRoutes declares non-admin routes that still require staff
// (instructor+). The chat-creation endpoints live outside /api/v1/admin/*
// — so the admin matrices above skip them — but are gated by
// s.requireStaff: a student must get 403. Declaring them keeps that gate
// under test the same way staffAllowedRoutes pins the admin tier. The
// read/post/edit chat routes are intentionally open to any member (the
// conversation_members ACL is the real gate) and so are NOT listed here.
var staffOnlyRoutes = map[string]bool{
	"POST /api/v1/conversations":              true,
	"POST /api/v1/conversations/{id}/members": true,
}

// routeKey formats the method + pattern the way our bypass sets expect it.
func routeKey(method, pattern string) string {
	return method + " " + pattern
}

// substitutePathParams swaps any {param} placeholders in the chi route
// pattern with a stable UUID so the URL is valid for an HTTP request. Auth
// and role middleware fires before handlers touch path params, so the value
// doesn't need to resolve to a real row.
func substitutePathParams(pattern string) string {
	out := pattern
	for {
		start := strings.IndexByte(out, '{')
		if start < 0 {
			break
		}
		end := strings.IndexByte(out[start:], '}')
		if end < 0 {
			break
		}
		out = out[:start] + store.NewID() + out[start+end+1:]
	}
	return out
}

// enumerateRoutes returns every (method, pattern) chi has registered on the
// server. Skips OPTIONS — those short-circuit through the CORS middleware
// and never reach the auth layer.
func enumerateRoutes(t *testing.T, srv *Server) [][2]string {
	t.Helper()
	router, ok := srv.Routes().(chi.Router)
	if !ok {
		t.Fatal("Routes() did not return a chi.Router; matrix tests need the chi handle")
	}
	var out [][2]string
	err := chi.Walk(router, func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		if method == http.MethodOptions {
			return nil
		}
		out = append(out, [2]string{method, route})
		return nil
	})
	if err != nil {
		t.Fatalf("chi.Walk: %v", err)
	}
	if len(out) == 0 {
		t.Fatal("walk yielded zero routes — refusing to pass an empty matrix")
	}
	return out
}

// TestAuthMatrix_EveryEndpointRequiresBearer asserts that every registered
// route returns 401 when called with no Authorization header. A failure
// means a new endpoint was added without going through the s.auth middleware.
func TestAuthMatrix_EveryEndpointRequiresBearer(t *testing.T) {
	r := newRig(t)
	routes := enumerateRoutes(t, r.server)

	for _, rt := range routes {
		method, pattern := rt[0], rt[1]
		key := routeKey(method, pattern)
		if authBypassRoutes[key] {
			continue
		}
		t.Run(key, func(t *testing.T) {
			url := substitutePathParams(pattern)
			req := httptest.NewRequest(method, url, bytes.NewReader([]byte("{}")))
			// No Authorization header.
			w := httptest.NewRecorder()
			r.handler.ServeHTTP(w, req)
			got := w.Result().StatusCode
			if got != http.StatusUnauthorized {
				body, _ := io.ReadAll(w.Result().Body)
				t.Errorf("%s %s without auth: got %d want 401 body=%s",
					method, pattern, got, body)
			}
		})
	}
}

// TestRoleMatrix_AdminRoutesRequireManager asserts that every /admin/* route
// returns 403 when the caller is authenticated as a student. A failure means
// a new admin route was added without going through s.requireManager.
func TestRoleMatrix_AdminRoutesRequireManager(t *testing.T) {
	r := newRig(t)

	// Seed a student user so the auth middleware can resolve the email to
	// a real row before requireManager fires.
	studentEmail := "matrix-student@test.com"
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'student', ?, 'Matrix Student')`,
		store.NewID(), r.studioID, studentEmail)

	// Swap the verifier so any token resolves to the student.
	r.server.verify = func(ctx context.Context, token string) (*auth.Verified, error) {
		return &auth.Verified{UID: "uid-student", Email: studentEmail}, nil
	}

	routes := enumerateRoutes(t, r.server)

	var sawAdmin bool
	for _, rt := range routes {
		method, pattern := rt[0], rt[1]
		if !strings.HasPrefix(pattern, "/api/v1/admin/") {
			continue
		}
		sawAdmin = true
		key := routeKey(method, pattern)
		if roleBypassRoutes[key] {
			continue
		}
		t.Run(key, func(t *testing.T) {
			url := substitutePathParams(pattern)
			req := httptest.NewRequest(method, url, bytes.NewReader([]byte("{}")))
			req.Header.Set("Authorization", "Bearer test-token")
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			r.handler.ServeHTTP(w, req)
			got := w.Result().StatusCode
			if got != http.StatusForbidden {
				body, _ := io.ReadAll(w.Result().Body)
				t.Errorf("%s %s as student: got %d want 403 body=%s",
					method, pattern, got, body)
			}
		})
	}
	if !sawAdmin {
		t.Fatal("no /admin/* routes found — fixture or route prefix changed?")
	}
}

// TestRoleMatrix_StaffOnlyRoutesRejectStudents asserts that every declared
// staff-only non-admin route (the chat-creation endpoints) returns 403 for a
// student, and that staffOnlyRoutes has no stale entries. A failure means a
// chat-creation route lost its s.requireStaff gate, or the declaration drifted
// from the registered routes.
func TestRoleMatrix_StaffOnlyRoutesRejectStudents(t *testing.T) {
	r := newRig(t)

	studentEmail := "matrix-staffonly-student@test.com"
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'student', ?, 'Matrix StaffOnly Student')`,
		store.NewID(), r.studioID, studentEmail)
	r.server.verify = func(ctx context.Context, token string) (*auth.Verified, error) {
		return &auth.Verified{UID: "uid-staffonly-student", Email: studentEmail}, nil
	}

	routes := enumerateRoutes(t, r.server)

	// Flag stale declarations — a route removed/renamed without updating the set.
	registered := map[string]bool{}
	for _, rt := range routes {
		registered[routeKey(rt[0], rt[1])] = true
	}
	for declared := range staffOnlyRoutes {
		if !registered[declared] {
			t.Errorf("staffOnlyRoutes contains stale entry %q — route no longer exists", declared)
		}
	}

	var checked int
	for _, rt := range routes {
		method, pattern := rt[0], rt[1]
		key := routeKey(method, pattern)
		if !staffOnlyRoutes[key] {
			continue
		}
		checked++
		t.Run(key, func(t *testing.T) {
			url := substitutePathParams(pattern)
			req := httptest.NewRequest(method, url, bytes.NewReader([]byte("{}")))
			req.Header.Set("Authorization", "Bearer test-token")
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			r.handler.ServeHTTP(w, req)
			got := w.Result().StatusCode
			if got != http.StatusForbidden {
				body, _ := io.ReadAll(w.Result().Body)
				t.Errorf("%s %s as student: got %d want 403 body=%s",
					method, pattern, got, body)
			}
		})
	}
	if checked == 0 {
		t.Fatal("no staff-only routes were checked — declaration is empty?")
	}
}

// TestRoleMatrix_StaffOnlyRoutesAllowInstructors is the inverse: an
// instructor must clear the role gate on staff-only routes. The handler may
// still 400/404 (empty body, no such conversation) — we only assert the gate
// itself doesn't reject with 403.
func TestRoleMatrix_StaffOnlyRoutesAllowInstructors(t *testing.T) {
	r := newRig(t)

	instructorEmail := "matrix-staffonly-instructor@test.com"
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'instructor', ?, 'Matrix StaffOnly Instructor')`,
		store.NewID(), r.studioID, instructorEmail)
	r.server.verify = func(ctx context.Context, token string) (*auth.Verified, error) {
		return &auth.Verified{UID: "uid-staffonly-instructor", Email: instructorEmail}, nil
	}

	routes := enumerateRoutes(t, r.server)
	var checked int
	for _, rt := range routes {
		method, pattern := rt[0], rt[1]
		key := routeKey(method, pattern)
		if !staffOnlyRoutes[key] {
			continue
		}
		checked++
		t.Run(key, func(t *testing.T) {
			url := substitutePathParams(pattern)
			req := httptest.NewRequest(method, url, bytes.NewReader([]byte("{}")))
			req.Header.Set("Authorization", "Bearer test-token")
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			r.handler.ServeHTTP(w, req)
			if got := w.Result().StatusCode; got == http.StatusForbidden {
				body, _ := io.ReadAll(w.Result().Body)
				t.Errorf("%s %s as instructor: got 403 (role gate rejected); should pass body=%s",
					method, pattern, body)
			}
		})
	}
	if checked == 0 {
		t.Fatal("no staff-only routes were checked — declaration is empty?")
	}
}

// TestRoleMatrix_InstructorRejectedFromManagerOnlyRoutes asserts that an
// authenticated instructor still gets 403 on the manager-only admin tier
// (money mutators, config, reports, audit, dashboard, staff CRUD,
// promotions). A failure here means a sensitive endpoint silently moved
// from requireManager to requireStaff.
func TestRoleMatrix_InstructorRejectedFromManagerOnlyRoutes(t *testing.T) {
	r := newRig(t)

	instructorEmail := "matrix-instructor@test.com"
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'instructor', ?, 'Matrix Instructor')`,
		store.NewID(), r.studioID, instructorEmail)
	r.server.verify = func(ctx context.Context, token string) (*auth.Verified, error) {
		return &auth.Verified{UID: "uid-instructor", Email: instructorEmail}, nil
	}

	routes := enumerateRoutes(t, r.server)
	var checked int
	for _, rt := range routes {
		method, pattern := rt[0], rt[1]
		if !strings.HasPrefix(pattern, "/api/v1/admin/") {
			continue
		}
		if staffAllowedRoutes[routeKey(method, pattern)] {
			continue // covered by the next matrix
		}
		checked++
		t.Run(routeKey(method, pattern), func(t *testing.T) {
			url := substitutePathParams(pattern)
			req := httptest.NewRequest(method, url, bytes.NewReader([]byte("{}")))
			req.Header.Set("Authorization", "Bearer test-token")
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			r.handler.ServeHTTP(w, req)
			got := w.Result().StatusCode
			if got != http.StatusForbidden {
				body, _ := io.ReadAll(w.Result().Body)
				t.Errorf("%s %s as instructor: got %d want 403 body=%s",
					method, pattern, got, body)
			}
		})
	}
	if checked == 0 {
		t.Fatal("staffAllowedRoutes covers every admin route — manager-only list is empty")
	}
}

// TestRoleMatrix_InstructorAllowedOnStaffRoutes is the inverse: routes
// declared in staffAllowedRoutes must NOT return 403 when an instructor
// calls them. The handler may still return 404 / 400 (no class with that
// path-param UUID, missing body), but the role gate must pass.
func TestRoleMatrix_InstructorAllowedOnStaffRoutes(t *testing.T) {
	r := newRig(t)

	instructorEmail := "matrix-instructor@test.com"
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'instructor', ?, 'Matrix Instructor')`,
		store.NewID(), r.studioID, instructorEmail)
	r.server.verify = func(ctx context.Context, token string) (*auth.Verified, error) {
		return &auth.Verified{UID: "uid-instructor", Email: instructorEmail}, nil
	}

	routes := enumerateRoutes(t, r.server)
	// Build a lookup from registered routes so we can also detect
	// stale entries in staffAllowedRoutes (declared but not registered).
	registered := map[string]bool{}
	for _, rt := range routes {
		registered[routeKey(rt[0], rt[1])] = true
	}
	for declared := range staffAllowedRoutes {
		if !registered[declared] {
			t.Errorf("staffAllowedRoutes contains stale entry %q — route no longer exists", declared)
		}
	}

	var checked int
	for _, rt := range routes {
		method, pattern := rt[0], rt[1]
		key := routeKey(method, pattern)
		if !staffAllowedRoutes[key] {
			continue
		}
		checked++
		t.Run(key, func(t *testing.T) {
			url := substitutePathParams(pattern)
			req := httptest.NewRequest(method, url, bytes.NewReader([]byte("{}")))
			req.Header.Set("Authorization", "Bearer test-token")
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			r.handler.ServeHTTP(w, req)
			got := w.Result().StatusCode
			if got == http.StatusForbidden {
				body, _ := io.ReadAll(w.Result().Body)
				t.Errorf("%s %s as instructor: got 403 (role gate rejected); should pass body=%s",
					method, pattern, body)
			}
		})
	}
	if checked == 0 {
		t.Fatal("no staff-allowed routes were checked — declaration is empty?")
	}
}
