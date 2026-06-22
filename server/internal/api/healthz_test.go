package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestHealthz_OK asserts the happy-path 200 with a "ok" body. A
// regression here would silently break Fly's load-balancer probe and
// the platform would start cycling the machine.
func TestHealthz_OK(t *testing.T) {
	rig := newRig(t)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	rig.handler.ServeHTTP(w, req)

	res := w.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.StatusCode)
	}
	got := w.Body.String()
	if !strings.Contains(got, "ok") {
		t.Fatalf("expected body to contain 'ok', got %q", got)
	}
}

// TestHealthz_NoAuth confirms the endpoint isn't behind /api/v1 (which
// requires a Bearer token) — load-balancer probers don't log in.
func TestHealthz_NoAuth(t *testing.T) {
	rig := newRig(t)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	// Deliberately no Authorization header.
	w := httptest.NewRecorder()
	rig.handler.ServeHTTP(w, req)

	if w.Result().StatusCode != http.StatusOK {
		t.Fatalf("healthz must be unauthenticated; got %d",
			w.Result().StatusCode)
	}
}
