package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	_ "modernc.org/sqlite"

	"github.com/studio52/yoga-school/server/internal/auth"
	"github.com/studio52/yoga-school/server/internal/store"
)

// testRig wires an in-memory store + the API server with a stubbed verifier
// that resolves any non-empty bearer token to the same test user.
type testRig struct {
	t        *testing.T
	server   *Server
	handler  http.Handler
	studioID string
	mgrEmail string
	mgrID    string
}

func newRig(t *testing.T) *testRig {
	t.Helper()
	store := openTestStore(t)
	srv := NewServer(store, nil)

	studioID := uuid.NewString()
	themeID := uuid.NewString()
	mgrID := uuid.NewString()
	mgrEmail := "manager@test.com"

	mustExec(t, store, `INSERT INTO studios (id, name, welcome_message)
		VALUES (?, 'Test', 'Welcome')`, studioID)
	mustExec(t, store, `INSERT INTO themes (id, studio_id, name, mode, tokens)
		VALUES (?, ?, 'T', 'light', '{"primary":"#000"}')`, themeID, studioID)
	mustExec(t, store, `UPDATE studios SET active_theme_id = ? WHERE id = ?`, themeID, studioID)
	mustExec(t, store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'manager', ?, 'Manager')`, mgrID, studioID, mgrEmail)
	// Seed an instructor + room + class_type so create-class tests can run.
	mustExec(t, store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'instructor', 'inst@test.com', 'Inst')`,
		uuid.NewString(), studioID)
	mustExec(t, store, `INSERT INTO rooms (id, studio_id, name) VALUES (?, ?, 'Studio A')`,
		uuid.NewString(), studioID)
	mustExec(t, store, `INSERT INTO class_types (id, studio_id, name) VALUES (?, ?, 'Yoga')`,
		uuid.NewString(), studioID)

	// Stub verifier: any non-empty token resolves to the manager. Tests that
	// need a different identity can override via rig.asEmail(...).
	currentEmail := &mgrEmail
	srv.verify = func(ctx context.Context, token string) (*auth.Verified, error) {
		if token == "bad" {
			return nil, auth.ErrInvalidToken
		}
		return &auth.Verified{UID: "uid-" + *currentEmail, Email: *currentEmail}, nil
	}

	return &testRig{
		t:        t,
		server:   srv,
		handler:  srv.Routes(),
		studioID: studioID,
		mgrEmail: mgrEmail,
		mgrID:    mgrID,
	}
}

func (r *testRig) do(method, path string, body any) *http.Response {
	r.t.Helper()
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			r.t.Fatalf("marshal body: %v", err)
		}
		reader = bytes.NewReader(b)
	}
	req := httptest.NewRequest(method, "/api/v1"+path, reader)
	req.Header.Set("Authorization", "Bearer test-token")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	w := httptest.NewRecorder()
	r.handler.ServeHTTP(w, req)
	return w.Result()
}

func decode[T any](t *testing.T, res *http.Response) T {
	t.Helper()
	var out T
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		t.Fatalf("decode %T: %v", out, err)
	}
	return out
}

func mustExec(t *testing.T, s *store.Store, q string, args ...any) {
	t.Helper()
	db := storeDB(s)
	if _, err := db.ExecContext(context.Background(), q, args...); err != nil {
		t.Fatalf("exec %q: %v", q, err)
	}
}

// storeDB exposes the unexported *sql.DB on the store for raw setup in tests.
// We can't reach into the struct from outside the package, so we route through
// an exported helper added to the store package... actually no — we work
// around it by using ApplySQLFile-style top-level execution. Simpler: have
// the store package add a TestDB accessor. For now reach via reflection-free
// channel: use the helpers exposed below.
func storeDB(s *store.Store) *sql.DB { return store.TestDB(s) }

func openTestStore(t *testing.T) *store.Store {
	t.Helper()
	db, err := sql.Open("sqlite",
		"file::memory:?_pragma=foreign_keys(1)&cache=shared")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	dir, _ := os.Getwd()
	for d := dir; d != "/"; d = filepath.Dir(d) {
		p := filepath.Join(d, "db", "schema.sql")
		if _, err := os.Stat(p); err == nil {
			b, _ := os.ReadFile(p)
			if _, err := db.ExecContext(context.Background(), string(b)); err != nil {
				t.Fatalf("apply schema: %v", err)
			}
			return store.NewFromDB(db)
		}
	}
	t.Fatalf("db/schema.sql not found from %s", dir)
	return nil
}

// ---- happy-path coverage for the endpoints landed this session ----

func TestAPI_AuthMissingBearer_Returns401(t *testing.T) {
	r := newRig(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/me", nil)
	w := httptest.NewRecorder()
	r.handler.ServeHTTP(w, req)
	res := w.Result()
	if res.StatusCode != http.StatusUnauthorized {
		t.Errorf("no auth header: got %d want 401", res.StatusCode)
	}
}

func TestAPI_AuthBadToken_Returns401(t *testing.T) {
	r := newRig(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/me", nil)
	req.Header.Set("Authorization", "Bearer bad")
	w := httptest.NewRecorder()
	r.handler.ServeHTTP(w, req)
	if got := w.Result().StatusCode; got != http.StatusUnauthorized {
		t.Errorf("bad token: got %d want 401", got)
	}
}

func TestAPI_StudentRouteForbiddenForNonManager_ButThisRigIsManager(t *testing.T) {
	// Sanity: our rig is wired with manager role, so admin routes succeed.
	r := newRig(t)
	res := r.do(http.MethodGet, "/admin/staff", nil)
	if res.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(res.Body)
		t.Fatalf("admin/staff as manager: %d body=%s", res.StatusCode, body)
	}
}

func TestAPI_ClassTypeCRUD_RoundTrips(t *testing.T) {
	r := newRig(t)

	create := r.do(http.MethodPost, "/admin/class-types", map[string]any{
		"name": "Pilates", "discipline": "mat",
	})
	if create.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(create.Body)
		t.Fatalf("create class type: %d %s", create.StatusCode, body)
	}
	idResp := decode[map[string]string](t, create)
	id := idResp["id"]
	if id == "" {
		t.Fatal("create returned empty id")
	}

	upd := r.do(http.MethodPatch, "/admin/class-types/"+id, map[string]any{
		"name": "Reformer Pilates", "discipline": "reformer",
	})
	if upd.StatusCode != http.StatusNoContent {
		body, _ := io.ReadAll(upd.Body)
		t.Fatalf("patch class type: %d %s", upd.StatusCode, body)
	}

	list := r.do(http.MethodGet, "/admin/class-types", nil)
	rows := decode[[]map[string]any](t, list)
	var found bool
	for _, row := range rows {
		if row["id"] == id && row["name"] == "Reformer Pilates" {
			found = true
		}
	}
	if !found {
		t.Errorf("updated class type missing from list: %v", rows)
	}
}

func TestAPI_ClassTypeCreate_RejectsEmptyName(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodPost, "/admin/class-types", map[string]any{"name": ""})
	if res.StatusCode != http.StatusBadRequest {
		t.Errorf("blank name: got %d want 400", res.StatusCode)
	}
}

func TestAPI_PromotionsListEndpoint_FiltersByWindow(t *testing.T) {
	r := newRig(t)

	now := time.Now().UTC()
	starts := now.Add(-1 * time.Hour).Format(time.RFC3339)
	ends := now.Add(48 * time.Hour).Format(time.RFC3339)
	create := r.do(http.MethodPost, "/admin/promotions", map[string]any{
		"title": "Now On", "starts_at": starts, "ends_at": ends,
	})
	if create.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(create.Body)
		t.Fatalf("create promo: %d %s", create.StatusCode, body)
	}

	// Future promo — should not show on student feed.
	startsLater := now.Add(48 * time.Hour).Format(time.RFC3339)
	endsMuchLater := now.Add(72 * time.Hour).Format(time.RFC3339)
	r.do(http.MethodPost, "/admin/promotions", map[string]any{
		"title": "Future", "starts_at": startsLater, "ends_at": endsMuchLater,
	})

	student := r.do(http.MethodGet, "/promotions", nil)
	if student.StatusCode != http.StatusOK {
		t.Fatalf("student promotions: %d", student.StatusCode)
	}
	rows := decode[[]map[string]any](t, student)
	titles := map[string]bool{}
	for _, row := range rows {
		titles[row["title"].(string)] = true
	}
	if !titles["Now On"] {
		t.Errorf("active promo missing from feed: %v", titles)
	}
	if titles["Future"] {
		t.Errorf("future promo leaked into feed: %v", titles)
	}
}

func TestAPI_PromotionsCreate_RejectsBlankTitle(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodPost, "/admin/promotions", map[string]any{"title": ""})
	if res.StatusCode != http.StatusBadRequest {
		t.Errorf("blank title: got %d want 400", res.StatusCode)
	}
}

func TestAPI_PromotionArchive_HidesFromStudent(t *testing.T) {
	r := newRig(t)

	create := r.do(http.MethodPost, "/admin/promotions", map[string]any{"title": "Spring"})
	id := decode[map[string]string](t, create)["id"]

	del := r.do(http.MethodDelete, "/admin/promotions/"+id, nil)
	if del.StatusCode != http.StatusNoContent {
		body, _ := io.ReadAll(del.Body)
		t.Fatalf("archive: %d %s", del.StatusCode, body)
	}
	student := r.do(http.MethodGet, "/promotions", nil)
	rows := decode[[]map[string]any](t, student)
	for _, row := range rows {
		if row["id"] == id {
			t.Errorf("archived promo still visible to student: %v", row)
		}
	}
}

func TestAPI_StaffList_IncludesManagerAndInstructor(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodGet, "/admin/staff", nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("staff list: %d", res.StatusCode)
	}
	rows := decode[[]map[string]any](t, res)
	roles := map[string]int{}
	for _, row := range rows {
		roles[row["role"].(string)]++
	}
	if roles["manager"] < 1 || roles["instructor"] < 1 {
		t.Errorf("expected at least 1 manager + 1 instructor in fixture: %v", roles)
	}
}

func TestAPI_StaffCreateAndUpdate(t *testing.T) {
	r := newRig(t)

	create := r.do(http.MethodPost, "/admin/staff", map[string]any{
		"role":      "instructor",
		"email":     "new-inst@test.com",
		"full_name": "New Instructor",
	})
	if create.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(create.Body)
		t.Fatalf("create staff: %d %s", create.StatusCode, body)
	}
	id := decode[map[string]string](t, create)["id"]

	upd := r.do(http.MethodPatch, "/admin/staff/"+id, map[string]any{
		"role":      "manager",
		"email":     "new-inst@test.com",
		"full_name": "New Instructor",
	})
	if upd.StatusCode != http.StatusNoContent {
		body, _ := io.ReadAll(upd.Body)
		t.Fatalf("update staff: %d %s", upd.StatusCode, body)
	}

	list := r.do(http.MethodGet, "/admin/staff", nil)
	rows := decode[[]map[string]any](t, list)
	var found bool
	for _, row := range rows {
		if row["id"] == id && row["role"] == "manager" {
			found = true
		}
	}
	if !found {
		t.Errorf("updated staff missing from list")
	}
}

func TestAPI_StaffCreate_RejectsInvalidRole(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodPost, "/admin/staff", map[string]any{
		"role": "student", "email": "x@y.com", "full_name": "X",
	})
	if res.StatusCode != http.StatusBadRequest {
		t.Errorf("invalid role: got %d want 400", res.StatusCode)
	}
}

func TestAPI_BookingsScope_PastReturns200_NotError(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodGet, "/bookings?scope=past", nil)
	if res.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(res.Body)
		t.Errorf("scope=past: got %d body=%s", res.StatusCode, body)
	}
}

func TestAPI_BookingsScope_BogusReturns400(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodGet, "/bookings?scope=weird", nil)
	if res.StatusCode != http.StatusBadRequest {
		t.Errorf("scope=weird: got %d want 400", res.StatusCode)
	}
}

func TestAPI_ClassesRange_AcceptsFromTo(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodGet, "/classes?from=2026-06-01&to=2026-06-14", nil)
	if res.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(res.Body)
		t.Errorf("range: got %d body=%s", res.StatusCode, body)
	}
}

func TestAPI_ClassesRange_RejectsNoArgs(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodGet, "/classes", nil)
	if res.StatusCode != http.StatusBadRequest {
		t.Errorf("no args: got %d want 400", res.StatusCode)
	}
}

func TestAPI_ClassDetail_NotFound(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodGet, "/classes/"+uuid.NewString(), nil)
	if res.StatusCode != http.StatusNotFound {
		t.Errorf("missing class: got %d want 404", res.StatusCode)
	}
}

func TestAPI_ProductDetail_NotFound(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodGet, "/products/"+uuid.NewString(), nil)
	if res.StatusCode != http.StatusNotFound {
		t.Errorf("missing product: got %d want 404", res.StatusCode)
	}
}

func TestAPI_CheckinScan_InvalidToken_Returns404(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodPost, "/admin/checkin/scan", map[string]any{
		"token": "no-such-code", "class_id": uuid.NewString(),
	})
	if res.StatusCode != http.StatusNotFound {
		body, _ := io.ReadAll(res.Body)
		t.Errorf("bad token: got %d body=%s want 404", res.StatusCode, body)
	}
}

func TestAPI_CheckinScan_MissingFields_Returns404(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodPost, "/admin/checkin/scan", map[string]any{})
	// Empty token surfaces as invalid_token (404 per handler mapping).
	if res.StatusCode != http.StatusNotFound {
		t.Errorf("missing fields: got %d want 404", res.StatusCode)
	}
}

func TestAPI_MeEndpoint_ReturnsCallerIdentity(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodGet, "/me", nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("/me: %d", res.StatusCode)
	}
	body := decode[map[string]any](t, res)
	if email, _ := body["email"].(string); !strings.Contains(email, "@test.com") {
		t.Errorf("/me email: got %v", body["email"])
	}
}
