package store

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// fakeMediaStorage records Puts/Deletes in memory so the media store can be
// exercised without a real Firebase bucket.
type fakeMediaStorage struct {
	objects map[string][]byte
	deleted []string
}

func newFakeMediaStorage() *fakeMediaStorage {
	return &fakeMediaStorage{objects: map[string][]byte{}}
}

func (f *fakeMediaStorage) Put(_ context.Context, path, _ string, data []byte) (string, error) {
	cp := make([]byte, len(data))
	copy(cp, data)
	f.objects[path] = cp
	return "https://media.test/" + path, nil
}

func (f *fakeMediaStorage) Delete(_ context.Context, path string) error {
	f.deleted = append(f.deleted, path)
	delete(f.objects, path)
	return nil
}

func TestUploadMedia_StoresRowObjectAndAudits(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	fake := newFakeMediaStorage()
	s.SetMediaStorage(fake)
	mgr := mkUser(t, s, f.studioID, "manager", "mgr-media@test.com")

	row, err := s.UploadMedia(ctx, f.studioID, mgr, "yoga.png", "image/png", []byte("\x89PNG fake bytes"))
	if err != nil {
		t.Fatalf("upload: %v", err)
	}
	if !strings.HasPrefix(row.URL, "https://media.test/") {
		t.Fatalf("unexpected url %q", row.URL)
	}
	if len(fake.objects) != 1 {
		t.Fatalf("expected 1 stored object, got %d", len(fake.objects))
	}
	if n := countAuditByAction(t, s, f.studioID, "media_upload"); n != 1 {
		t.Errorf("media_upload audits: got %d want 1", n)
	}

	list, err := s.ListMedia(ctx, f.studioID)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(list) != 1 || list[0].ID != row.ID {
		t.Fatalf("list mismatch: %+v", list)
	}
}

func TestUploadMedia_RejectsNonImage(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	s.SetMediaStorage(newFakeMediaStorage())
	mgr := mkUser(t, s, f.studioID, "manager", "mgr-media@test.com")

	_, err := s.UploadMedia(context.Background(), f.studioID, mgr, "notes.txt", "text/plain", []byte("hello"))
	var mr MediaRejected
	if !errors.As(err, &mr) {
		t.Fatalf("expected MediaRejected for non-image, got %v", err)
	}
}

func TestUploadMedia_RejectsOversize(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	s.SetMediaStorage(newFakeMediaStorage())
	mgr := mkUser(t, s, f.studioID, "manager", "mgr-media@test.com")

	big := make([]byte, MaxMediaBytes+1)
	_, err := s.UploadMedia(context.Background(), f.studioID, mgr, "huge.png", "image/png", big)
	var mr MediaRejected
	if !errors.As(err, &mr) {
		t.Fatalf("expected MediaRejected for oversize, got %v", err)
	}
}

func TestUploadMedia_WithoutStorageIsUnavailable(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	// Deliberately no SetMediaStorage.
	mgr := mkUser(t, s, f.studioID, "manager", "mgr-media@test.com")

	_, err := s.UploadMedia(context.Background(), f.studioID, mgr, "x.png", "image/png", []byte("x"))
	if !errors.Is(err, ErrMediaStorageUnavailable) {
		t.Fatalf("expected ErrMediaStorageUnavailable, got %v", err)
	}
}

func TestDeleteMedia_RemovesRowObjectAndAudits(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	fake := newFakeMediaStorage()
	s.SetMediaStorage(fake)
	mgr := mkUser(t, s, f.studioID, "manager", "mgr-media@test.com")

	row, err := s.UploadMedia(ctx, f.studioID, mgr, "yoga.png", "image/png", []byte("bytes"))
	if err != nil {
		t.Fatalf("upload: %v", err)
	}

	if err := s.DeleteMedia(ctx, f.studioID, mgr, row.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if len(fake.deleted) != 1 {
		t.Fatalf("expected 1 deleted object, got %d", len(fake.deleted))
	}
	if list, _ := s.ListMedia(ctx, f.studioID); len(list) != 0 {
		t.Fatalf("expected empty library after delete, got %d", len(list))
	}
	if n := countAuditByAction(t, s, f.studioID, "media_delete"); n != 1 {
		t.Errorf("media_delete audits: got %d want 1", n)
	}

	// Deleting again is a clean not-found.
	if err := s.DeleteMedia(ctx, f.studioID, mgr, row.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("re-delete: want ErrNotFound, got %v", err)
	}
}
