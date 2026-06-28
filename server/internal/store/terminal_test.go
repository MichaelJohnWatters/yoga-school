package store

import (
	"context"
	"errors"
	"testing"

	"github.com/studio52/yoga-school/server/internal/secrets"
)

func TestTerminal_RegisterChargeListRemove(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	s.SetPaymentGateway(&fakeGateway{})
	adminID := seedAdminUser(t, s, f.studioID)
	productID := seedTenPack(t, s, f)

	// Register a reader (simulated pairing code).
	reader, err := s.RegisterTerminalReader(ctx, f.studioID, adminID, "simulated-wpe", "Front desk")
	if err != nil {
		t.Fatalf("RegisterTerminalReader: %v", err)
	}
	if reader.ReaderID == "" || reader.LocationID == "" {
		t.Fatalf("reader ids empty: %+v", reader)
	}
	if got := auditCount(t, s, f.studioID, "terminal_reader_register"); got != 1 {
		t.Errorf("terminal_reader_register audit = %d, want 1", got)
	}

	// A second reader reuses the first's Location.
	reader2, err := s.RegisterTerminalReader(ctx, f.studioID, adminID, "simulated-2", "Back desk")
	if err != nil {
		t.Fatalf("second register: %v", err)
	}
	if reader2.LocationID != reader.LocationID {
		t.Errorf("second reader location = %q, want reuse of %q", reader2.LocationID, reader.LocationID)
	}

	readers, err := s.ListTerminalReaders(ctx, f.studioID)
	if err != nil || len(readers) != 2 {
		t.Fatalf("ListTerminalReaders: err=%v n=%d", err, len(readers))
	}

	// Charge a student in person on the reader.
	out, err := s.ChargeInPerson(ctx, f.studioID, adminID, f.studentID, productID, "", reader.ReaderID)
	if err != nil {
		t.Fatalf("ChargeInPerson: %v", err)
	}
	if out.AmountMinor != 5000 {
		t.Errorf("amount = %d, want 5000", out.AmountMinor)
	}
	// A pending card_present purchase, attributed to the manager.
	var pm, status, actorRole, initiatedBy string
	if err := s.db.QueryRowContext(ctx,
		`SELECT payment_method, status, actor_role, initiated_by FROM purchases WHERE id = ?`,
		out.PurchaseID).Scan(&pm, &status, &actorRole, &initiatedBy); err != nil {
		t.Fatalf("read purchase: %v", err)
	}
	if pm != "card_present" || status != "pending" || actorRole != "manager" || initiatedBy != adminID {
		t.Fatalf("purchase pm=%q status=%q actor=%q by=%q", pm, status, actorRole, initiatedBy)
	}
	if got := auditCount(t, s, f.studioID, "terminal_charge"); got != 1 {
		t.Errorf("terminal_charge audit = %d, want 1", got)
	}

	// Unknown reader → ErrNotFound (never touches Stripe).
	if _, err := s.ChargeInPerson(ctx, f.studioID, adminID, f.studentID, productID, "", "tmr_unknown"); !errors.Is(err, ErrNotFound) {
		t.Errorf("charge with unknown reader err = %v, want ErrNotFound", err)
	}

	// Remove drops the cached row + audits.
	if err := s.RemoveTerminalReader(ctx, f.studioID, adminID, reader2.ReaderID); err != nil {
		t.Fatalf("RemoveTerminalReader: %v", err)
	}
	if got, _ := s.ListTerminalReaders(ctx, f.studioID); len(got) != 1 {
		t.Errorf("after remove: %d readers, want 1", len(got))
	}
	if errors.Is(s.RemoveTerminalReader(ctx, f.studioID, adminID, "tmr_nope"), ErrNotFound) {
		// expected
	} else {
		t.Errorf("removing unknown reader should be ErrNotFound")
	}
}

func TestTerminal_RequiresStripeConfigured(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	s.SetSealer(secrets.NewTestSealer()) // sealer present, but no creds saved
	s.SetPaymentGateway(&fakeGateway{})
	adminID := seedAdminUser(t, s, f.studioID)

	_, err := s.RegisterTerminalReader(ctx, f.studioID, adminID, "simulated-wpe", "")
	if !errors.Is(err, ErrStripeNotConfigured) {
		t.Errorf("register without keys err = %v, want ErrStripeNotConfigured", err)
	}
}
