package api

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime/debug"
	"strings"
	"sync/atomic"
	"time"

	"github.com/go-chi/chi/v5/middleware"
)

// Observability surface, per the portfolio deploy standard
// (toolkit/docs/deploy-standard.md):
//   - GET /healthz — liveness (process up; no deps). See handleHealthz.
//   - GET /readyz  — readiness (DB reachable). See handleReadyz.
//   - GET /metrics — Prometheus-text request counters (this file).
//   - newRecoverer — panic recovery + counter + optional ERROR_WEBHOOK alert,
//     replacing chi's middleware.Recoverer.

var metrics struct {
	total  atomic.Int64
	r2xx   atomic.Int64
	r3xx   atomic.Int64
	r4xx   atomic.Int64
	r5xx   atomic.Int64
	panics atomic.Int64
}

// metricsMiddleware counts responses by status class for /metrics.
func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		metrics.total.Add(1)
		switch sc := ww.Status(); {
		case sc >= 500:
			metrics.r5xx.Add(1)
		case sc >= 400:
			metrics.r4xx.Add(1)
		case sc >= 300:
			metrics.r3xx.Add(1)
		default: // 0 (implicit 200) or 2xx
			metrics.r2xx.Add(1)
		}
	})
}

// handleReadyz reports whether the server can serve traffic — i.e. the DB
// answers. Liveness (/healthz) says only "the process is up"; a load balancer
// or uptime check should gate on /readyz. (Split out of the old /healthz,
// which conflated the two — a DB blip must not restart-loop the machine.)
func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if err := s.store.DB().PingContext(ctx); err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("db ping failed: " + err.Error() + "\n"))
		return
	}
	_, _ = w.Write([]byte("ready\n"))
}

// handleMetrics emits Prometheus text — no client library. Aggregate counts
// only (no PII); firewall it off if request volume shouldn't be public.
func handleMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprintf(w, "# HELP yoga_http_requests_total Total HTTP requests handled.\n")
	fmt.Fprintf(w, "# TYPE yoga_http_requests_total counter\n")
	fmt.Fprintf(w, "yoga_http_requests_total %d\n", metrics.total.Load())
	fmt.Fprintf(w, "# HELP yoga_http_responses_total HTTP responses by status class.\n")
	fmt.Fprintf(w, "# TYPE yoga_http_responses_total counter\n")
	fmt.Fprintf(w, "yoga_http_responses_total{class=\"2xx\"} %d\n", metrics.r2xx.Load())
	fmt.Fprintf(w, "yoga_http_responses_total{class=\"3xx\"} %d\n", metrics.r3xx.Load())
	fmt.Fprintf(w, "yoga_http_responses_total{class=\"4xx\"} %d\n", metrics.r4xx.Load())
	fmt.Fprintf(w, "yoga_http_responses_total{class=\"5xx\"} %d\n", metrics.r5xx.Load())
	fmt.Fprintf(w, "# HELP yoga_handler_panics_total Handler panics recovered.\n")
	fmt.Fprintf(w, "# TYPE yoga_handler_panics_total counter\n")
	fmt.Fprintf(w, "yoga_handler_panics_total %d\n", metrics.panics.Load())
}

// newRecoverer replaces chi's middleware.Recoverer: it turns a panic into a
// 500, logs the stack, counts it, and (when ERROR_WEBHOOK is set) fires a
// best-effort crash alert. http.ErrAbortHandler is re-panicked, as chi does.
func newRecoverer() func(http.Handler) http.Handler {
	webhook := os.Getenv("ERROR_WEBHOOK")
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				rvr := recover()
				if rvr == nil {
					return
				}
				if rvr == http.ErrAbortHandler {
					panic(rvr) // not a real error; let the server handle it
				}
				metrics.panics.Add(1)
				log.Printf("panic %s %s: %v\n%s", r.Method, r.URL.Path, rvr, debug.Stack())
				if webhook != "" {
					go postErrorWebhook(webhook, fmt.Sprintf("yoga-school panic %s %s: %v", r.Method, r.URL.Path, rvr))
				}
				w.WriteHeader(http.StatusInternalServerError)
			}()
			next.ServeHTTP(w, r)
		})
	}
}

func postErrorWebhook(url, text string) {
	defer func() { _ = recover() }()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(fmt.Sprintf(`{"text":%q}`, text)))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	_ = resp.Body.Close()
}
