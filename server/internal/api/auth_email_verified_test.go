package api

import (
	"context"
	"io"
	"net/http"
	"testing"

	"github.com/studio52/yoga-school/server/internal/auth"
)

// TestAuth_EmailNotVerified_Returns403 guards the auth fix: when token
// verification reports the email is unverified (auth.ErrEmailNotVerified), the
// middleware must reject the request with 403 and not fall through to
// resolving/provisioning a user. Verifying real tokens requires Firebase, so
// we drive the behaviour through the verify stub — the same seam the rest of
// the api tests use.
func TestAuth_EmailNotVerified_Returns403(t *testing.T) {
	r := newRig(t)
	r.server.verify = func(ctx context.Context, token string) (*auth.Verified, error) {
		return nil, auth.ErrEmailNotVerified
	}

	res := r.do(http.MethodGet, "/me", nil)
	if res.StatusCode != http.StatusForbidden {
		body, _ := io.ReadAll(res.Body)
		t.Fatalf("unverified email: status=%d body=%s, want 403", res.StatusCode, body)
	}
}
