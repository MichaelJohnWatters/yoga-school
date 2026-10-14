package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// /readyz is readiness: with the test store's DB up, it returns 200.
func TestReadyz_OK(t *testing.T) {
	rig := newRig(t)
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()
	rig.handler.ServeHTTP(w, req)
	if w.Result().StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Result().StatusCode)
	}
	if !strings.Contains(w.Body.String(), "ready") {
		t.Fatalf("expected body to contain 'ready', got %q", w.Body.String())
	}
}

// /metrics renders Prometheus text with the expected series.
func TestMetrics_Renders(t *testing.T) {
	rig := newRig(t)
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()
	rig.handler.ServeHTTP(w, req)
	if w.Result().StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Result().StatusCode)
	}
	body := w.Body.String()
	for _, want := range []string{
		"yoga_http_requests_total",
		`yoga_http_responses_total{class="2xx"}`,
		"yoga_handler_panics_total",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("/metrics missing %q", want)
		}
	}
}
