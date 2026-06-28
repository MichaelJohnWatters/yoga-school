package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
	"github.com/studio52/yoga-school/server/internal/secrets"
)

// fakeGateway is an in-memory payments.Gateway for tests. It records what it
// was asked to do and returns scripted results, so the store's Stripe paths can
// be exercised without touching the network.
type fakeGateway struct {
	// createIntentFn lets a test control the returned intent / error.
	createIntentFn func(p payments.IntentParams) (payments.Intent, error)
	// paymentMethods is returned by ListPaymentMethods; lastDetached records
	// the id passed to DetachPaymentMethod.
	paymentMethods []payments.PaymentMethod
	lastDetached   string
	// intents maps intent id → status returned by GetIntent.
	intents map[string]string
	// verifyFn lets a test script webhook verification.
	verifyFn func(payload []byte, sig, secret string) (payments.Event, error)
	// checkoutFn / refundFn script the checkout + refund calls.
	checkoutFn        func(p payments.CheckoutParams) (payments.CheckoutSession, error)
	checkoutSessionFn func(sessionID string) (payments.CheckoutSessionStatus, error)
	refundFn          func(intentID string, amountMinor int64) (string, error)

	// Subscription scripting. Defaults synthesise deterministic ids so most
	// tests don't need to set these.
	ensureCustomerFn  func(p payments.CustomerParams) (string, error)
	createPriceFn     func(p payments.PriceParams) (string, string, error)
	subCheckoutFn     func(p payments.SubscriptionCheckoutParams) (payments.CheckoutSession, error)
	getSubscriptionFn func(subID string) (payments.SubscriptionState, error)
	portalFn          func(customerID, returnURL string) (string, error)

	lastCreate   payments.IntentParams
	lastCheckout payments.CheckoutParams
	lastRefund   struct {
		intentID    string
		amountMinor int64
	}
	lastSubCheckout payments.SubscriptionCheckoutParams
	lastPrice       payments.PriceParams
	archivedPrices  []string
	canceledSubs    []string // subID for each Cancel call
	cancelAtEnd     map[string]bool
	priceSeq        int
	getCalls        int
}

func (g *fakeGateway) CreateCheckoutSession(_ context.Context, _ string, p payments.CheckoutParams) (payments.CheckoutSession, error) {
	g.lastCheckout = p
	if g.checkoutFn != nil {
		return g.checkoutFn(p)
	}
	return payments.CheckoutSession{ID: "cs_" + p.IdempotencyKey, URL: "https://checkout.stripe.test/cs_" + p.IdempotencyKey}, nil
}

func (g *fakeGateway) GetCheckoutSession(_ context.Context, _ string, sessionID string) (payments.CheckoutSessionStatus, error) {
	if g.checkoutSessionFn != nil {
		return g.checkoutSessionFn(sessionID)
	}
	// Default: paid, with a derived intent id.
	return payments.CheckoutSessionStatus{PaymentStatus: "paid", IntentID: "pi_" + sessionID}, nil
}

func (g *fakeGateway) Refund(_ context.Context, _ string, intentID string, amountMinor int64, _ string) (string, error) {
	g.lastRefund.intentID = intentID
	g.lastRefund.amountMinor = amountMinor
	if g.refundFn != nil {
		return g.refundFn(intentID, amountMinor)
	}
	return "re_" + intentID, nil
}

func (g *fakeGateway) CreateIntent(_ context.Context, _ string, p payments.IntentParams) (payments.Intent, error) {
	g.lastCreate = p
	if g.createIntentFn != nil {
		return g.createIntentFn(p)
	}
	return payments.Intent{ID: "pi_" + p.IdempotencyKey, ClientSecret: "pi_" + p.IdempotencyKey + "_secret", Status: "requires_payment_method"}, nil
}

func (g *fakeGateway) GetIntent(_ context.Context, _ string, intentID string) (payments.Intent, error) {
	g.getCalls++
	status, ok := g.intents[intentID]
	if !ok {
		status = "requires_payment_method"
	}
	return payments.Intent{ID: intentID, Status: status}, nil
}

func (g *fakeGateway) VerifyWebhook(payload []byte, sig, secret string) (payments.Event, error) {
	if g.verifyFn != nil {
		return g.verifyFn(payload, sig, secret)
	}
	return payments.Event{}, errors.New("no verifyFn")
}

func (g *fakeGateway) EnsureCustomer(_ context.Context, _ string, p payments.CustomerParams) (string, error) {
	if g.ensureCustomerFn != nil {
		return g.ensureCustomerFn(p)
	}
	return "cus_" + p.Email, nil
}

func (g *fakeGateway) CreateEphemeralKey(_ context.Context, _, customerID, _ string) (string, error) {
	return "ek_secret_" + customerID, nil
}

func (g *fakeGateway) CreateTerminalLocation(_ context.Context, _, _, _ string) (string, error) {
	return "tml_fake", nil
}

func (g *fakeGateway) RegisterTerminalReader(_ context.Context, _, _, registrationCode, _ string) (string, error) {
	return "tmr_" + registrationCode, nil
}

func (g *fakeGateway) CreateCardPresentIntent(_ context.Context, _ string, p payments.CardPresentParams) (payments.Intent, error) {
	if g.createIntentFn != nil {
		return g.createIntentFn(payments.IntentParams{
			AmountMinor: p.AmountMinor, Currency: p.Currency,
			IdempotencyKey: p.IdempotencyKey, Metadata: p.Metadata,
		})
	}
	id := "pi_cp_" + p.IdempotencyKey
	return payments.Intent{ID: id, ClientSecret: id + "_secret", Status: "requires_payment_method"}, nil
}

func (g *fakeGateway) ProcessPaymentIntentOnReader(_ context.Context, _, _, _ string) error {
	return nil
}

func (g *fakeGateway) CancelReaderAction(_ context.Context, _, _ string) error { return nil }

func (g *fakeGateway) ListPaymentMethods(_ context.Context, _, customerID string) ([]payments.PaymentMethod, error) {
	if g.paymentMethods != nil {
		return g.paymentMethods, nil
	}
	return []payments.PaymentMethod{}, nil
}

func (g *fakeGateway) CreateSetupIntent(_ context.Context, _, customerID string) (string, error) {
	return "seti_" + customerID + "_secret", nil
}

func (g *fakeGateway) CreateSetupCheckoutSession(_ context.Context, _, customerID, _, _ string) (string, error) {
	return "https://checkout.test/setup/" + customerID, nil
}

func (g *fakeGateway) DetachPaymentMethod(_ context.Context, _, _, pmID string) error {
	g.lastDetached = pmID
	return nil
}

func (g *fakeGateway) CreateRecurringPrice(_ context.Context, _ string, p payments.PriceParams) (string, string, error) {
	g.lastPrice = p
	if g.createPriceFn != nil {
		return g.createPriceFn(p)
	}
	// Unique per call so a repoint produces a distinct Price id (Stripe Prices
	// are immutable — a price edit mints a new one).
	g.priceSeq++
	return fmt.Sprintf("prod_%d", g.priceSeq), fmt.Sprintf("price_%d", g.priceSeq), nil
}

func (g *fakeGateway) ArchivePrice(_ context.Context, _ string, priceID string) error {
	g.archivedPrices = append(g.archivedPrices, priceID)
	return nil
}

func (g *fakeGateway) CreateCheckoutSubscription(_ context.Context, _ string, p payments.SubscriptionCheckoutParams) (payments.CheckoutSession, error) {
	g.lastSubCheckout = p
	if g.subCheckoutFn != nil {
		return g.subCheckoutFn(p)
	}
	return payments.CheckoutSession{ID: "cs_" + p.IdempotencyKey, URL: "https://checkout.stripe.test/sub/cs_" + p.IdempotencyKey}, nil
}

func (g *fakeGateway) GetSubscription(_ context.Context, _ string, subID string) (payments.SubscriptionState, error) {
	if g.getSubscriptionFn != nil {
		return g.getSubscriptionFn(subID)
	}
	return payments.SubscriptionState{Status: "active"}, nil
}

func (g *fakeGateway) CancelSubscription(_ context.Context, _ string, subID string, atPeriodEnd bool) error {
	g.canceledSubs = append(g.canceledSubs, subID)
	if g.cancelAtEnd == nil {
		g.cancelAtEnd = map[string]bool{}
	}
	g.cancelAtEnd[subID] = atPeriodEnd
	return nil
}

func (g *fakeGateway) ResumeSubscription(_ context.Context, _ string, subID string) error {
	if g.cancelAtEnd == nil {
		g.cancelAtEnd = map[string]bool{}
	}
	g.cancelAtEnd[subID] = false
	return nil
}

func (g *fakeGateway) CreateBillingPortalSession(_ context.Context, _ string, customerID, returnURL string) (string, error) {
	if g.portalFn != nil {
		return g.portalFn(customerID, returnURL)
	}
	return "https://billing.stripe.test/portal/" + customerID, nil
}

// withStripeCreds wires a sealer + a stored secret/webhook key so the gateway
// paths (which call LoadStripeKeysForUse) can resolve a studio's keys. actorID
// must be a real user (updated_by is FK-constrained).
func withStripeCreds(t *testing.T, s *Store, studioID, actorID string) {
	t.Helper()
	s.SetSealer(secrets.NewTestSealer())
	if _, err := s.UpdateStripeCredentials(context.Background(), studioID, actorID,
		StripeCredentialsPatch{
			SecretKey:     strptr("sk_test_123"),
			WebhookSecret: strptr("whsec_test_123"),
		}); err != nil {
		t.Fatalf("seed stripe creds: %v", err)
	}
}

func strptr(s string) *string { return &s }

func TestCreatePendingPurchase_UsesGatewayIntent(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	out, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	if err != nil {
		t.Fatalf("CreatePendingPurchase: %v", err)
	}
	// The real intent id (not a pi_stub_) must be persisted + returned.
	if out.StripePaymentID == "" || out.StripePaymentID[:3] != "pi_" || out.StripePaymentID[:8] == "pi_stub_" {
		t.Fatalf("expected real intent id, got %q", out.StripePaymentID)
	}
	// Idempotency key must be the purchase id (kills double-charge on retry).
	if g.lastCreate.IdempotencyKey != out.PurchaseID {
		t.Errorf("idempotency key = %q, want purchase id %q", g.lastCreate.IdempotencyKey, out.PurchaseID)
	}
	// Amount charged is the server-side price (5000), not anything client-sent.
	if g.lastCreate.AmountMinor != 5000 {
		t.Errorf("amount = %d, want 5000", g.lastCreate.AmountMinor)
	}
	if g.lastCreate.Metadata["purchase_id"] != out.PurchaseID {
		t.Errorf("metadata purchase_id missing/wrong: %v", g.lastCreate.Metadata)
	}
	// No entitlement yet — that's confirm's job.
	assertPurchaseStatus(t, s, out.PurchaseID, "pending")
}

func TestConfirmPurchase_VerifiesSucceededBeforeMint(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	pending, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	if err != nil {
		t.Fatalf("pending: %v", err)
	}

	// Intent NOT succeeded → confirm must refuse and mint nothing.
	g.intents[pending.StripePaymentID] = "requires_payment_method"
	if _, err := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID); err == nil {
		t.Fatal("expected confirm to refuse an unsucceeded intent")
	}
	assertPurchaseStatus(t, s, pending.PurchaseID, "pending")

	// Now the intent succeeds → confirm mints + completes.
	g.intents[pending.StripePaymentID] = payments.StatusSucceeded
	entID, err := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID)
	if err != nil {
		t.Fatalf("confirm after success: %v", err)
	}
	if entID == "" {
		t.Fatal("expected an entitlement id")
	}
	assertPurchaseStatus(t, s, pending.PurchaseID, "completed")
}

func TestConfirmByIntent_And_Confirm_ConvergeIdempotently(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	pending, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	g.intents[pending.StripePaymentID] = payments.StatusSucceeded

	// Webhook path mints first (authoritative).
	entWebhook, err := s.ConfirmPurchaseByIntent(ctx, f.studioID, pending.StripePaymentID)
	if err != nil {
		t.Fatalf("confirm by intent: %v", err)
	}
	// Optimistic client confirm then races in — must return the SAME entitlement.
	entClient, err := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID)
	if err != nil {
		t.Fatalf("confirm: %v", err)
	}
	if entWebhook != entClient {
		t.Fatalf("paths diverged: webhook=%s client=%s", entWebhook, entClient)
	}
	// Exactly one entitlement exists for this purchase.
	var n int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM entitlements WHERE user_id = ? AND source_product_id = ?`,
		f.studentID, productID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("expected 1 entitlement, got %d", n)
	}
}

func TestVoidPurchaseByIntent_OnlyTouchesPending(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	pending, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	if err := s.VoidPurchaseByIntent(ctx, f.studioID, pending.StripePaymentID, "payment_intent.payment_failed"); err != nil {
		t.Fatalf("void: %v", err)
	}
	assertPurchaseStatus(t, s, pending.PurchaseID, "voided")

	// A void on an already-completed purchase is a no-op (doesn't error,
	// doesn't downgrade). Confirm one then try to void.
	pending2, _ := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	g.intents[pending2.StripePaymentID] = payments.StatusSucceeded
	if _, err := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending2.PurchaseID); err != nil {
		t.Fatalf("confirm2: %v", err)
	}
	if err := s.VoidPurchaseByIntent(ctx, f.studioID, pending2.StripePaymentID, "late_fail"); err != nil {
		t.Fatalf("void completed: %v", err)
	}
	assertPurchaseStatus(t, s, pending2.PurchaseID, "completed")
}

func TestHandleStripeEvent_SignatureDedupAndDispatch(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)
	pending, _ := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")

	// Bad signature → ErrWebhookSignature (caller 400s, no fulfilment).
	g.verifyFn = func(_ []byte, _, _ string) (payments.Event, error) {
		return payments.Event{}, errors.New("bad sig")
	}
	if err := s.HandleStripeEvent(ctx, f.studioID, []byte("{}"), "t=1,v1=bad"); !errors.Is(err, ErrWebhookSignature) {
		t.Fatalf("expected ErrWebhookSignature, got %v", err)
	}
	assertPurchaseStatus(t, s, pending.PurchaseID, "pending")

	// Valid succeeded event → fulfils.
	g.verifyFn = func(_ []byte, _, _ string) (payments.Event, error) {
		return payments.Event{ID: "evt_1", Type: "payment_intent.succeeded", IntentID: pending.StripePaymentID, Status: "succeeded"}, nil
	}
	if err := s.HandleStripeEvent(ctx, f.studioID, []byte("{}"), "sig"); err != nil {
		t.Fatalf("handle succeeded: %v", err)
	}
	assertPurchaseStatus(t, s, pending.PurchaseID, "completed")

	// Redelivery of the same event id is a deduped no-op.
	var before int
	s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM processed_stripe_events`).Scan(&before)
	if err := s.HandleStripeEvent(ctx, f.studioID, []byte("{}"), "sig"); err != nil {
		t.Fatalf("redelivery: %v", err)
	}
	var after int
	s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM processed_stripe_events`).Scan(&after)
	if before != after {
		t.Fatalf("redelivery double-recorded: %d → %d", before, after)
	}
}

func TestReconcilePendingPurchases(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedTenPack(t, s, f)

	// Two stale pending purchases: one secretly succeeded, one abandoned.
	good, _ := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	bad, _ := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	g.intents[good.StripePaymentID] = payments.StatusSucceeded
	g.intents[bad.StripePaymentID] = "requires_payment_method"
	// Age both rows past the threshold.
	s.db.ExecContext(ctx, `UPDATE purchases SET created_at = ?`,
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339))

	confirmed, voided, err := s.ReconcilePendingPurchases(ctx, 15*time.Minute)
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if confirmed != 1 || voided != 1 {
		t.Fatalf("confirmed=%d voided=%d, want 1/1", confirmed, voided)
	}
	assertPurchaseStatus(t, s, good.PurchaseID, "completed")
	assertPurchaseStatus(t, s, bad.PurchaseID, "voided")
}

func TestSweepEntitlements(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	// An expired-but-still-active pass and a depleted credit pack.
	expired := f.insertEntitlement(t, s, "unlimited", 0)
	s.db.ExecContext(ctx, `UPDATE entitlements SET expires_at = ? WHERE id = ?`,
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339), expired)
	depleted := f.insertEntitlement(t, s, "credit", 0)

	exp, dep, err := s.SweepEntitlements(ctx)
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if exp != 1 || dep != 1 {
		t.Fatalf("expired=%d depleted=%d, want 1/1", exp, dep)
	}
	assertEntitlementStatus(t, s, expired, "expired")
	assertEntitlementStatus(t, s, depleted, "depleted")
}

func assertPurchaseStatus(t *testing.T, s *Store, purchaseID, want string) {
	t.Helper()
	var got string
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT status FROM purchases WHERE id = ?`, purchaseID).Scan(&got); err != nil {
		t.Fatalf("read purchase status: %v", err)
	}
	if got != want {
		t.Fatalf("purchase %s status = %q, want %q", purchaseID, got, want)
	}
}

func assertEntitlementStatus(t *testing.T, s *Store, entID, want string) {
	t.Helper()
	var got string
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT status FROM entitlements WHERE id = ?`, entID).Scan(&got); err != nil {
		t.Fatalf("read entitlement status: %v", err)
	}
	if got != want {
		t.Fatalf("entitlement %s status = %q, want %q", entID, got, want)
	}
}
