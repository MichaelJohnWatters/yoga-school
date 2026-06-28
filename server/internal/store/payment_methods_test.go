package store

import (
	"context"
	"errors"
	"testing"

	"github.com/studio52/yoga-school/server/internal/payments"
)

func TestPaymentMethods_ListSetupDetach(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{}
	s.SetPaymentGateway(g)

	// No customer yet → empty, not an error.
	methods, err := s.ListMyPaymentMethods(ctx, f.studioID, f.studentID)
	if err != nil || len(methods) != 0 {
		t.Fatalf("empty list: err=%v n=%d", err, len(methods))
	}

	// Adding a card ensures the customer + returns a secret and its id.
	secret, custID, err := s.SetupIntentForCard(ctx, f.studioID, f.studentID, "s@test.com")
	if err != nil || secret == "" || custID == "" {
		t.Fatalf("SetupIntentForCard: err=%v secret=%q cust=%q", err, secret, custID)
	}

	// Now the gateway reports a saved card.
	g.paymentMethods = []payments.PaymentMethod{
		{ID: "pm_1", Brand: "visa", Last4: "4242", ExpMonth: 12, ExpYear: 2030},
	}
	methods, err = s.ListMyPaymentMethods(ctx, f.studioID, f.studentID)
	if err != nil || len(methods) != 1 || methods[0].Last4 != "4242" {
		t.Fatalf("list: err=%v methods=%+v", err, methods)
	}

	// Detach hits the gateway with the right id.
	if err := s.DetachMyPaymentMethod(ctx, f.studioID, f.studentID, "pm_1"); err != nil {
		t.Fatalf("detach: %v", err)
	}
	if g.lastDetached != "pm_1" {
		t.Errorf("detached %q, want pm_1", g.lastDetached)
	}
}

func TestPaymentMethods_DetachWithoutCustomer(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	s.SetPaymentGateway(&fakeGateway{})

	if err := s.DetachMyPaymentMethod(ctx, f.studioID, f.studentID, "pm_x"); !errors.Is(err, ErrNotFound) {
		t.Errorf("detach without customer err = %v, want ErrNotFound", err)
	}
}
