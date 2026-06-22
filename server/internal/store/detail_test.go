package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestGetClass_PopulatesBookingStateAndWaitlist(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 5)

	// Add 2 waitlist entries (synthetic, since waitlist is normally added on
	// full classes via JoinWaitlist).
	for i := 1; i <= 2; i++ {
		other := insertOtherStudent(t, s, f.studioID)
		if _, err := s.db.ExecContext(ctx,
			`INSERT INTO waitlist_entries (id, class_id, user_id, position)
			 VALUES (?, ?, ?, ?)`,
			NewID(), class, other, i,
		); err != nil {
			t.Fatalf("seed waitlist: %v", err)
		}
	}

	got, err := s.GetClass(ctx, f.studioID, f.studentID, class)
	if err != nil {
		t.Fatalf("GetClass: %v", err)
	}
	if got.ID != class {
		t.Errorf("id: got %s want %s", got.ID, class)
	}
	if got.BookingState != "available" {
		t.Errorf("state: got %q want available", got.BookingState)
	}
	if got.WaitlistCount != 2 {
		t.Errorf("waitlist_count: got %d want 2", got.WaitlistCount)
	}
}

func TestGetClass_NotFoundCrossStudio(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 5)
	_, err := s.GetClass(ctx, "other-studio", f.studentID, class)
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("cross-studio: got %v want ErrNotFound", err)
	}
}

func TestGetClass_BookedStateAfterCallerBooks(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 5)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	if err != nil {
		t.Fatalf("book: %v", err)
	}

	got, err := s.GetClass(ctx, f.studioID, f.studentID, class)
	if err != nil {
		t.Fatalf("GetClass: %v", err)
	}
	if got.BookingState != "booked" {
		t.Errorf("state: got %q want booked", got.BookingState)
	}
	if got.BookingID != bookingID {
		t.Errorf("booking_id: got %s want %s", got.BookingID, bookingID)
	}
}

func TestGetProduct_ReturnsCoverageAndDisciplines(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// A second class type to test discipline deduping.
	pilatesID, err := s.CreateClassType(ctx, f.studioID, f.instructorID, ClassTypeInput{
		Name: "Pilates", Discipline: "mat",
	})
	if err != nil {
		t.Fatalf("class type: %v", err)
	}

	productID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO products
		   (id, studio_id, name, description, price_minor, billing_type, pass_kind, credits)
		   VALUES (?, ?, 'Ten Pack', 'Ten classes', 5000, 'one_time', 'credit', 10)`,
		productID, f.studioID,
	); err != nil {
		t.Fatalf("seed product: %v", err)
	}
	// Cover both class types.
	for _, ct := range []string{f.classTypeID, pilatesID} {
		if _, err := s.db.ExecContext(ctx,
			`INSERT INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`,
			productID, ct,
		); err != nil {
			t.Fatalf("coverage: %v", err)
		}
	}

	// Set a discipline on the fixture's class type too, so we test dedupe.
	if _, err := s.db.ExecContext(ctx,
		`UPDATE class_types SET discipline = 'yoga' WHERE id = ?`, f.classTypeID,
	); err != nil {
		t.Fatalf("set discipline: %v", err)
	}

	got, err := s.GetProduct(ctx, f.studioID, productID)
	if err != nil {
		t.Fatalf("GetProduct: %v", err)
	}
	if got.Name != "Ten Pack" || got.Description != "Ten classes" || got.PriceMinor != 5000 {
		t.Errorf("scalars: %+v", *got)
	}
	if got.Credits == nil || *got.Credits != 10 {
		t.Errorf("credits: %v want 10", got.Credits)
	}
	if len(got.ClassTypeIDs) != 2 {
		t.Errorf("class_type_ids: got %v want 2 entries", got.ClassTypeIDs)
	}
	if !sameSet(got.DisciplineSet, []string{"yoga", "mat"}) {
		t.Errorf("disciplines: got %v want [yoga mat]", got.DisciplineSet)
	}
}

func TestGetProduct_NotFoundWhenArchived(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	productID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO products
		   (id, studio_id, name, price_minor, billing_type, pass_kind, is_archived)
		   VALUES (?, ?, 'Gone', 1000, 'one_time', 'unlimited', 1)`,
		productID, f.studioID,
	); err != nil {
		t.Fatalf("seed: %v", err)
	}
	_, err := s.GetProduct(ctx, f.studioID, productID)
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("archived product: got %v want ErrNotFound", err)
	}
}

func sameSet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	in := map[string]bool{}
	for _, x := range a {
		in[x] = true
	}
	for _, x := range b {
		if !in[x] {
			return false
		}
	}
	return true
}
