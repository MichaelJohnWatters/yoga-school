package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

const testToken = "S52-test-token"

func TestCheckinScan_MarksBookingAttended(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(1*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false)
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	f.setCheckinToken(t, s, f.studentID, testToken)

	out, err := s.CheckinScan(ctx, f.studioID, f.instructorID, testToken, class)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if out.BookingID != bookingID {
		t.Errorf("booking id: got %s want %s", out.BookingID, bookingID)
	}
	if out.UserID != f.studentID {
		t.Errorf("user id: got %s want %s", out.UserID, f.studentID)
	}
	if out.WasAlready {
		t.Error("first scan reported as already attended")
	}

	// Verify DB state.
	var status, via string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status, COALESCE(attendance_marked_by,'') FROM bookings WHERE id = ?`,
		bookingID,
	).Scan(&status, &via); err != nil {
		t.Fatalf("read booking: %v", err)
	}
	if status != "attended" {
		t.Errorf("status: got %q want attended", status)
	}
	if via != "scan" {
		t.Errorf("attendance_marked_by: got %q want scan", via)
	}
}

func TestCheckinScan_IdempotentReturnsAlreadyFlag(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(1*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false); err != nil {
		t.Fatalf("book: %v", err)
	}
	f.setCheckinToken(t, s, f.studentID, testToken)

	if _, err := s.CheckinScan(ctx, f.studioID, f.instructorID, testToken, class); err != nil {
		t.Fatalf("scan 1: %v", err)
	}
	out, err := s.CheckinScan(ctx, f.studioID, f.instructorID, testToken, class)
	if err != nil {
		t.Fatalf("scan 2: %v", err)
	}
	if !out.WasAlready {
		t.Error("second scan should report was_already_attended=true")
	}
}

func TestCheckinScan_InvalidTokenIsTypedError(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(1*time.Hour), 10)
	_, err := s.CheckinScan(ctx, f.studioID, f.instructorID, "bogus-token", class)
	assertScanErr(t, err, "invalid_token")
}

func TestCheckinScan_NoBookingForClass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(1*time.Hour), 10)
	f.setCheckinToken(t, s, f.studentID, testToken)

	// Token valid, but student hasn't booked this class.
	_, err := s.CheckinScan(ctx, f.studioID, f.instructorID, testToken, class)
	assertScanErr(t, err, "no_booking")
}

func TestCheckinScan_RefusesCancelledBooking(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(1*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, _ := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false)
	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatalf("cancel: %v", err)
	}
	f.setCheckinToken(t, s, f.studentID, testToken)

	_, err := s.CheckinScan(ctx, f.studioID, f.instructorID, testToken, class)
	assertScanErr(t, err, "was_cancelled")
}

func TestCheckinScan_ScopedByStudio(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(1*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false); err != nil {
		t.Fatalf("book: %v", err)
	}
	f.setCheckinToken(t, s, f.studentID, testToken)

	// Scanning under a different studio's auth context shouldn't resolve.
	_, err := s.CheckinScan(ctx, "other-studio", f.instructorID, testToken, class)
	assertScanErr(t, err, "invalid_token")
}

func (f fixture) setCheckinToken(t *testing.T, s *Store, userID, token string) {
	t.Helper()
	if _, err := s.db.ExecContext(context.Background(),
		`UPDATE users SET checkin_token = ? WHERE id = ?`, token, userID,
	); err != nil {
		t.Fatalf("set token: %v", err)
	}
}

func assertScanErr(t *testing.T, err error, wantCode string) {
	t.Helper()
	var se *ScanError
	if !errors.As(err, &se) {
		t.Fatalf("expected ScanError, got %T: %v", err, err)
	}
	if se.Code != wantCode {
		t.Errorf("error code: got %q want %q (msg=%q)", se.Code, wantCode, se.Message)
	}
}
