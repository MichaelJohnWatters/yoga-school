package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// scanFixture sets up a typical scan scenario: a class in N minutes, with
// the fixture's student booked on it. Returns (classID, bookingID, token).
func scanFixture(t *testing.T, s *Store, f fixture, startsInMinutes int) (string, string, string) {
	t.Helper()
	ctx := context.Background()
	class := f.insertClass(t, s,
		time.Now().UTC().Add(time.Duration(startsInMinutes)*time.Minute), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	// Seed the booking directly so the helper can also stage tests that
	// scan after the class has started (CreateBooking refuses past classes
	// — the doors-closed gate). The token still gets minted by insertBookedSeat.
	bookingID := f.insertBookedSeat(t, s, class, ent)
	var token string
	if err := s.db.QueryRowContext(ctx,
		`SELECT checkin_token FROM bookings WHERE id = ?`, bookingID,
	).Scan(&token); err != nil {
		t.Fatalf("read token: %v", err)
	}
	if token == "" {
		t.Fatal("CreateBooking did not mint a checkin_token")
	}
	return class, bookingID, token
}

func TestCheckinScan_MarksBookingAttendedAndConsumesToken(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	classID, bookingID, token := scanFixture(t, s, f, 10) // class in 10 minutes — inside window

	out, err := s.CheckinScan(ctx, f.studioID, f.instructorID, token)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if out.BookingID != bookingID || out.ClassID != classID || out.UserID != f.studentID {
		t.Errorf("scan result mismatch: %+v", out)
	}
	if out.WasAlready {
		t.Error("first scan reported as already attended")
	}

	// Booking flipped + token consumed.
	var status, via, tokenAfter string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status, COALESCE(attendance_marked_by,''), COALESCE(checkin_token,'')
		   FROM bookings WHERE id = ?`,
		bookingID,
	).Scan(&status, &via, &tokenAfter); err != nil {
		t.Fatal(err)
	}
	if status != "attended" {
		t.Errorf("status: got %q want attended", status)
	}
	if via != "scan" {
		t.Errorf("attendance_marked_by: got %q want scan", via)
	}
	if tokenAfter != "" {
		t.Errorf("checkin_token not consumed: got %q want empty", tokenAfter)
	}
}

// TestCheckinScan_RescanWithSameTokenIsInvalid — once consumed, the token
// resolves to nothing. Replaying a screenshot is identical to a made-up
// token, by design.
func TestCheckinScan_RescanWithSameTokenIsInvalid(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	_, _, token := scanFixture(t, s, f, 5)

	if _, err := s.CheckinScan(ctx, f.studioID, f.instructorID, token); err != nil {
		t.Fatalf("first scan: %v", err)
	}
	_, err := s.CheckinScan(ctx, f.studioID, f.instructorID, token)
	assertScanErr(t, err, "invalid_token")
}

func TestCheckinScan_InvalidTokenIsTypedError(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	_, err := s.CheckinScan(ctx, f.studioID, f.instructorID, "bogus-token")
	assertScanErr(t, err, "invalid_token")
}

func TestCheckinScan_RefusesCancelledBooking(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	_, bookingID, token := scanFixture(t, s, f, 10)
	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatalf("cancel: %v", err)
	}
	_, err := s.CheckinScan(ctx, f.studioID, f.instructorID, token)
	assertScanErr(t, err, "was_cancelled")
}

func TestCheckinScan_OutsideWindowBeforeOpen(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	// Class starts in 90 minutes — window opens 30 min before, so we're 60
	// min too early.
	_, _, token := scanFixture(t, s, f, 90)
	_, err := s.CheckinScan(ctx, f.studioID, f.instructorID, token)
	assertScanErr(t, err, "outside_checkin_window")
}

func TestCheckinScan_OutsideWindowAfterEnd(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	// Class started 90 min ago (60 min long → ended 30 min ago). Window
	// closes 10 min after end, so we're 20 min late.
	_, _, token := scanFixture(t, s, f, -90)
	_, err := s.CheckinScan(ctx, f.studioID, f.instructorID, token)
	assertScanErr(t, err, "outside_checkin_window")
}

func TestCheckinScan_ScopedByStudio(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	_, _, token := scanFixture(t, s, f, 10)
	// A manager from another studio can't redeem a token issued elsewhere.
	_, err := s.CheckinScan(ctx, "other-studio", f.instructorID, token)
	assertScanErr(t, err, "invalid_token")
}

func TestCreateBooking_MintsUniqueCheckinTokenPerBooking(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Two solo bookings on different classes — tokens must not collide.
	class1 := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 10)
	class2 := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	b1, _ := s.CreateBooking(ctx, f.studioID, f.studentID, class1, ent, false, "")
	b2, _ := s.CreateBooking(ctx, f.studioID, f.studentID, class2, ent, false, "")

	var t1, t2 string
	if err := s.db.QueryRowContext(ctx,
		`SELECT checkin_token FROM bookings WHERE id = ?`, b1,
	).Scan(&t1); err != nil {
		t.Fatal(err)
	}
	if err := s.db.QueryRowContext(ctx,
		`SELECT checkin_token FROM bookings WHERE id = ?`, b2,
	).Scan(&t2); err != nil {
		t.Fatal(err)
	}
	if t1 == "" || t2 == "" {
		t.Fatalf("tokens: t1=%q t2=%q", t1, t2)
	}
	if t1 == t2 {
		t.Errorf("tokens collided: %q", t1)
	}
}

func TestCreateBooking_PlusOneGetsItsOwnToken(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true, "Test Friend"); err != nil {
		t.Fatalf("book: %v", err)
	}

	rows, err := s.db.QueryContext(ctx, `
		SELECT is_plus_one, COALESCE(checkin_token,'')
		  FROM bookings WHERE class_id = ? ORDER BY is_plus_one`, class,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	tokens := map[int]string{}
	for rows.Next() {
		var p1 int
		var tok string
		if err := rows.Scan(&p1, &tok); err != nil {
			t.Fatal(err)
		}
		tokens[p1] = tok
	}
	if tokens[0] == "" || tokens[1] == "" {
		t.Errorf("missing token: %+v", tokens)
	}
	if tokens[0] == tokens[1] {
		t.Errorf("primary + +1 share a token: %q", tokens[0])
	}
}

// Ensure ScanError fan-out is still a typed error users can detect.
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
