package api

import (
	"net/http"
	"testing"
)

func TestExportStudent_ManagerSucceedsAndIsAudited(t *testing.T) {
	r := newRig(t)
	studentID := seedStudent(t, r)

	res := r.do(http.MethodGet, "/admin/students/"+studentID+"/export", nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("export status = %d, want 200", res.StatusCode)
	}
	body := decode[map[string]any](t, res)
	prof, ok := body["profile"].(map[string]any)
	if !ok || prof["id"] != studentID {
		t.Fatalf("export profile missing or wrong: %v", body["profile"])
	}

	// The access itself must be logged (reading a full subject record).
	var n int
	if err := storeDB(r.server.store).QueryRow(
		`SELECT COUNT(*) FROM audit_log WHERE action = 'user_data_exported' AND target_id = ?`,
		studentID,
	).Scan(&n); err != nil {
		t.Fatalf("count export audit: %v", err)
	}
	if n != 1 {
		t.Errorf("user_data_exported audit rows = %d, want 1", n)
	}
}

func TestExportStudent_InstructorForbidden(t *testing.T) {
	r := newRig(t)
	studentID := seedStudent(t, r)

	res := r.as("inst@test.com").do(
		http.MethodGet, "/admin/students/"+studentID+"/export", nil)
	if res.StatusCode != http.StatusForbidden {
		t.Errorf("instructor export status = %d, want 403", res.StatusCode)
	}
}
