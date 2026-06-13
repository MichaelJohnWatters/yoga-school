package api

import (
	"context"
	"net/http"
	"testing"

	"github.com/google/uuid"

	"github.com/studio52/yoga-school/server/internal/auth"
)

func TestMe_ReturnsManagerTierForManager(t *testing.T) {
	r := newRig(t)
	res := r.do(http.MethodGet, "/me", nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("/me: %d", res.StatusCode)
	}
	body := decode[map[string]any](t, res)
	if body["tier"] != "manager" {
		t.Errorf("manager tier: got %v want manager", body["tier"])
	}
}

func TestMe_ReturnsStaffTierForInstructor(t *testing.T) {
	r := newRig(t)
	email := "tier-inst@test.com"
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'instructor', ?, 'Inst Tier')`,
		uuid.NewString(), r.studioID, email)
	r.server.verify = func(ctx context.Context, token string) (*auth.Verified, error) {
		return &auth.Verified{UID: "uid-inst", Email: email}, nil
	}
	res := r.do(http.MethodGet, "/me", nil)
	body := decode[map[string]any](t, res)
	if body["tier"] != "staff" {
		t.Errorf("instructor tier: got %v want staff", body["tier"])
	}
}

func TestMe_ReturnsStudentTierForStudent(t *testing.T) {
	r := newRig(t)
	email := "tier-stu@test.com"
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'student', ?, 'Stu Tier')`,
		uuid.NewString(), r.studioID, email)
	r.server.verify = func(ctx context.Context, token string) (*auth.Verified, error) {
		return &auth.Verified{UID: "uid-stu", Email: email}, nil
	}
	res := r.do(http.MethodGet, "/me", nil)
	body := decode[map[string]any](t, res)
	if body["tier"] != "student" {
		t.Errorf("student tier: got %v want student", body["tier"])
	}
}

func TestTierForRole_MapsAllCases(t *testing.T) {
	for _, c := range []struct{ role, want string }{
		{"owner", "manager"},
		{"manager", "manager"},
		{"instructor", "staff"},
		{"student", "student"},
		{"", "student"},     // unknown → student (safe default)
		{"alien", "student"}, // unknown → student
	} {
		if got := tierForRole(c.role); got != c.want {
			t.Errorf("tierForRole(%q): got %q want %q", c.role, got, c.want)
		}
	}
}
