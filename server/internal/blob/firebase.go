// Package blob implements store.MediaStorage over Firebase Storage (a Google
// Cloud Storage bucket). Bytes are written through the Admin SDK and a public
// Firebase download URL is returned — the same kind of URL the Firebase
// client SDKs mint, so the app renders it with a plain Image.network and no
// SDK on the read path.
//
// Dev: set STORAGE_EMULATOR_HOST (e.g. localhost:9199) and the GCS client +
// the URL builder both target the Storage emulator, matching the Auth
// emulator pattern used elsewhere.
package blob

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"strings"

	gcs "cloud.google.com/go/storage"
	firebase "firebase.google.com/go/v4"
)

// Bucket is a MediaStorage backed by one Firebase Storage bucket.
type Bucket struct {
	bucket *gcs.BucketHandle
	name   string
}

// New resolves the bucket handle from the shared Firebase app. bucketName is
// the project's storage bucket (e.g. "yoga-school-dev.appspot.com").
func New(ctx context.Context, app *firebase.App, bucketName string) (*Bucket, error) {
	client, err := app.Storage(ctx)
	if err != nil {
		return nil, fmt.Errorf("firebase storage client: %w", err)
	}
	handle, err := client.Bucket(bucketName)
	if err != nil {
		return nil, fmt.Errorf("firebase storage bucket: %w", err)
	}
	return &Bucket{bucket: handle, name: bucketName}, nil
}

// Put writes the object with a Firebase download token in its metadata and
// returns the token-bearing download URL. The token gates public reads —
// fine for studio imagery, which every user is shown anyway.
func (b *Bucket) Put(ctx context.Context, path, mime string, data []byte) (string, error) {
	token, err := randomToken()
	if err != nil {
		return "", err
	}
	w := b.bucket.Object(path).NewWriter(ctx)
	w.ContentType = mime
	w.Metadata = map[string]string{"firebaseStorageDownloadTokens": token}
	if _, err := w.Write(data); err != nil {
		_ = w.Close()
		return "", err
	}
	if err := w.Close(); err != nil {
		return "", err
	}
	return b.downloadURL(path, token), nil
}

// Delete removes the object. A not-found is surfaced to the caller, which
// treats object deletion as best-effort.
func (b *Bucket) Delete(ctx context.Context, path string) error {
	return b.bucket.Object(path).Delete(ctx)
}

func (b *Bucket) downloadURL(path, token string) string {
	host := "https://firebasestorage.googleapis.com"
	if base := os.Getenv("MEDIA_PUBLIC_URL_BASE"); base != "" {
		// Dev: route public image reads through the same https origin as the
		// app (the Caddy proxy), so the browser doesn't block the emulator's
		// plain-http URL as mixed content. Prod leaves this unset and serves
		// straight from firebasestorage.googleapis.com (already https).
		host = strings.TrimRight(base, "/")
	} else if emu := os.Getenv("STORAGE_EMULATOR_HOST"); emu != "" {
		host = emu
		if !strings.HasPrefix(host, "http") {
			host = "http://" + host
		}
		host = strings.TrimRight(host, "/")
	}
	// The object path is encoded as a single path segment (slashes become
	// %2F) — the shape Firebase download URLs use.
	return fmt.Sprintf("%s/v0/b/%s/o/%s?alt=media&token=%s",
		host, b.name, url.QueryEscape(path), token)
}

func randomToken() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
