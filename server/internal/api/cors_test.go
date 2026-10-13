package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestCORS_AllowlistReflectsOnlyListedOrigins verifies the CORS middleware:
// with CORS_ALLOWED_ORIGINS set, a listed Origin is reflected and an unlisted
// one is not; unset falls back to the permissive "*".
func TestCORS_AllowlistReflectsOnlyListedOrigins(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	t.Run("unset → wildcard", func(t *testing.T) {
		t.Setenv("CORS_ALLOWED_ORIGINS", "")
		h := newCORS()(ok)
		req := httptest.NewRequest(http.MethodGet, "/x", nil)
		req.Header.Set("Origin", "https://evil.example")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != "*" {
			t.Fatalf("unset: ACAO = %q, want *", got)
		}
	})

	t.Run("listed origin reflected", func(t *testing.T) {
		t.Setenv("CORS_ALLOWED_ORIGINS", "https://app.studio52.com, https://admin.studio52.com")
		h := newCORS()(ok)
		req := httptest.NewRequest(http.MethodGet, "/x", nil)
		req.Header.Set("Origin", "https://admin.studio52.com")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != "https://admin.studio52.com" {
			t.Fatalf("listed: ACAO = %q, want the origin", got)
		}
		if got := w.Header().Get("Vary"); got != "Origin" {
			t.Fatalf("listed: Vary = %q, want Origin", got)
		}
	})

	t.Run("normalization: trailing slash + case in env still matches", func(t *testing.T) {
		t.Setenv("CORS_ALLOWED_ORIGINS", "https://App.Studio52.com/")
		h := newCORS()(ok)
		req := httptest.NewRequest(http.MethodGet, "/x", nil)
		req.Header.Set("Origin", "https://app.studio52.com")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != "https://app.studio52.com" {
			t.Fatalf("normalized match: ACAO = %q, want the browser's origin reflected", got)
		}
	})

	t.Run("unlisted origin not reflected", func(t *testing.T) {
		t.Setenv("CORS_ALLOWED_ORIGINS", "https://app.studio52.com")
		h := newCORS()(ok)
		req := httptest.NewRequest(http.MethodGet, "/x", nil)
		req.Header.Set("Origin", "https://evil.example")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != "" {
			t.Fatalf("unlisted: ACAO = %q, want empty (not reflected)", got)
		}
	})
}
