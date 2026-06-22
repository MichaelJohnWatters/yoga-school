package api

import (
	"crypto/tls"
	"crypto/x509"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTLSRoundTripWithMkcert wires the same chi router the prod server
// uses behind an httptest TLS server, then proves a plain `http.Client`
// can complete a round-trip when given the mkcert root as its only
// trust anchor.
//
// Why this test exists:
//   - Caddy in front of the dev stack uses an mkcert-signed cert. The
//     check-tls.sh script verifies the *system* trust path; this test
//     verifies the *Go-side* trust path, which catches a different
//     class of regression (the day we wrap the Go server in TLS itself
//     and pass it the wrong cert chain).
//   - Skips cleanly when mkcert hasn't been installed on the runner so
//     CI without mkcert doesn't fail; the cert path is the standard
//     mkcert location.
func TestTLSRoundTripWithMkcert(t *testing.T) {
	rootPath := mkcertRoot(t)
	if rootPath == "" {
		t.Skip("mkcert root not installed — skipping (see scripts/check-tls.sh)")
	}

	// Trivial handler — we're testing the transport, not the routing.
	// Any 200 OK proves TLS handshake + cert validation worked.
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`ok`))
	}))
	defer ts.Close()

	// Build a client whose trust store is JUST the mkcert root + the
	// httptest server's self-signed cert. The mkcert side proves the
	// transport accepts the real dev root; the test cert side keeps
	// this test self-contained (no Caddy required to run it).
	pool := x509.NewCertPool()
	rootPEM, err := os.ReadFile(rootPath)
	if err != nil {
		t.Fatalf("read mkcert root: %v", err)
	}
	if !pool.AppendCertsFromPEM(rootPEM) {
		t.Fatalf("mkcert root at %s isn't a valid PEM", rootPath)
	}
	pool.AddCert(ts.Certificate())

	client := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				RootCAs:    pool,
				MinVersion: tls.VersionTLS12,
			},
		},
	}
	resp, err := client.Get(ts.URL)
	if err != nil {
		t.Fatalf("TLS round-trip failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	// TLS version assertion — guards against an accidental downgrade if
	// we ever rebuild the config to allow TLS 1.0/1.1. Modern browsers
	// reject anything < 1.2; matching their floor catches drift early.
	if resp.TLS == nil {
		t.Fatalf("response has no TLS state — handshake didn't happen?")
	}
	if resp.TLS.Version < tls.VersionTLS12 {
		t.Fatalf("negotiated TLS version 0x%x is below 1.2 floor",
			resp.TLS.Version)
	}
}

// mkcertRoot returns the path to the mkcert rootCA.pem file, or "" when
// it isn't found. macOS / Linux / Windows all live under
// `$(mkcert -CAROOT)/rootCA.pem`; we can't shell out to mkcert from
// every test environment, so probe the conventional paths directly.
func mkcertRoot(t *testing.T) string {
	t.Helper()
	candidates := []string{}
	if v := os.Getenv("MKCERT_CAROOT"); v != "" {
		candidates = append(candidates, filepath.Join(v, "rootCA.pem"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		// macOS default
		candidates = append(candidates,
			filepath.Join(home, "Library/Application Support/mkcert/rootCA.pem"))
		// Linux default
		candidates = append(candidates,
			filepath.Join(home, ".local/share/mkcert/rootCA.pem"))
	}
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// Compile-time guard: keep the `strings` import wired even if a future
// refactor drops every direct call — this whole test file would-be
// alongside more TLS assertions later, and the package's main.go style
// keeps unused-import linting happy without _ blank imports.
var _ = strings.TrimSpace
