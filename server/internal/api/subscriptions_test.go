package api

import (
	"context"
	"net/http"
	"testing"

	"github.com/studio52/yoga-school/server/internal/payments"
	"github.com/studio52/yoga-school/server/internal/secrets"
	"github.com/studio52/yoga-school/server/internal/store"
)

// apiFakeGateway is a no-op payments.Gateway for the API layer tests: it lets
// the subscription endpoints resolve a configured gateway without touching the
// network. Fulfilment correctness lives in the store-package tests; here we
// only assert routing, validation, and auth.
type apiFakeGateway struct{}

func (apiFakeGateway) CreateIntent(context.Context, string, payments.IntentParams) (payments.Intent, error) {
	return payments.Intent{ID: "pi_x"}, nil
}
func (apiFakeGateway) GetIntent(context.Context, string, string) (payments.Intent, error) {
	return payments.Intent{ID: "pi_x", Status: payments.StatusSucceeded}, nil
}
func (apiFakeGateway) CreateCheckoutSession(context.Context, string, payments.CheckoutParams) (payments.CheckoutSession, error) {
	return payments.CheckoutSession{ID: "cs_x", URL: "https://checkout.stripe.test/cs_x"}, nil
}
func (apiFakeGateway) GetCheckoutSession(context.Context, string, string) (payments.CheckoutSessionStatus, error) {
	return payments.CheckoutSessionStatus{PaymentStatus: "paid", IntentID: "pi_x"}, nil
}
func (apiFakeGateway) Refund(context.Context, string, string, int64, string) (string, error) {
	return "re_x", nil
}
func (apiFakeGateway) VerifyWebhook([]byte, string, string) (payments.Event, error) {
	return payments.Event{}, nil
}
func (apiFakeGateway) EnsureCustomer(context.Context, string, payments.CustomerParams) (string, error) {
	return "cus_x", nil
}
func (apiFakeGateway) CreateEphemeralKey(context.Context, string, string, string) (string, error) {
	return "ek_secret_x", nil
}
func (apiFakeGateway) CreateTerminalLocation(context.Context, string, string, string) (string, error) {
	return "tml_x", nil
}
func (apiFakeGateway) RegisterTerminalReader(context.Context, string, string, string, string) (string, error) {
	return "tmr_x", nil
}
func (apiFakeGateway) CreateCardPresentIntent(context.Context, string, payments.CardPresentParams) (payments.Intent, error) {
	return payments.Intent{ID: "pi_cp_x", ClientSecret: "pi_cp_x_secret", Status: "requires_payment_method"}, nil
}
func (apiFakeGateway) ProcessPaymentIntentOnReader(context.Context, string, string, string) error {
	return nil
}
func (apiFakeGateway) CancelReaderAction(context.Context, string, string) error { return nil }
func (apiFakeGateway) ListPaymentMethods(context.Context, string, string) ([]payments.PaymentMethod, error) {
	return []payments.PaymentMethod{}, nil
}
func (apiFakeGateway) CreateSetupIntent(context.Context, string, string) (string, error) {
	return "seti_x_secret", nil
}
func (apiFakeGateway) CreateSetupCheckoutSession(context.Context, string, string, string, string) (string, error) {
	return "https://checkout.test/setup", nil
}
func (apiFakeGateway) DetachPaymentMethod(context.Context, string, string, string) error {
	return nil
}
func (apiFakeGateway) CreateRecurringPrice(context.Context, string, payments.PriceParams) (string, string, error) {
	return "prod_x", "price_x", nil
}
func (apiFakeGateway) ArchivePrice(context.Context, string, string) error { return nil }
func (apiFakeGateway) CreateCheckoutSubscription(context.Context, string, payments.SubscriptionCheckoutParams) (payments.CheckoutSession, error) {
	return payments.CheckoutSession{ID: "cs_sub_x", URL: "https://checkout.stripe.test/sub/cs_sub_x"}, nil
}
func (apiFakeGateway) GetSubscription(context.Context, string, string) (payments.SubscriptionState, error) {
	return payments.SubscriptionState{Status: "active"}, nil
}
func (apiFakeGateway) CancelSubscription(context.Context, string, string, bool) error { return nil }
func (apiFakeGateway) ResumeSubscription(context.Context, string, string) error       { return nil }
func (apiFakeGateway) CreateBillingPortalSession(_ context.Context, _, customerID, _ string) (string, error) {
	return "https://billing.stripe.test/" + customerID, nil
}

// configureStripeForTest wires the fake gateway + a sealer + stored keys so the
// subscription store paths resolve a studio's credentials.
func configureStripeForTest(t *testing.T, r *testRig) {
	t.Helper()
	r.server.store.SetPaymentGateway(apiFakeGateway{})
	r.server.store.SetSealer(secrets.NewTestSealer())
	sk, wh := "sk_test_x", "whsec_x"
	if _, err := r.server.store.UpdateStripeCredentials(context.Background(),
		r.studioID, r.mgrID, store.StripeCredentialsPatch{
			SecretKey:     &sk,
			WebhookSecret: &wh,
		}); err != nil {
		t.Fatalf("configure stripe: %v", err)
	}
}

// seedActiveSubscription wires Stripe + inserts an active membership linked to a
// Stripe subscription id, returning the row id. Used by the cancel paths.
func seedActiveSubscription(t *testing.T, r *testRig) string {
	t.Helper()
	configureStripeForTest(t, r)
	studentID := seedStudent(t, r)
	productID := seedProduct(t, r, "unlimited", 0)
	subID := store.NewID()
	mustExec(t, r.server.store, `
		INSERT INTO subscriptions
		  (id, studio_id, user_id, product_id, stripe_customer_id,
		   stripe_subscription_id, status, currency, amount_minor)
		  VALUES (?, ?, ?, ?, 'cus_x', 'sub_x', 'active', 'gbp', 8800)`,
		subID, r.studioID, studentID, productID)
	mustExec(t, r.server.store, `
		INSERT INTO stripe_customers (studio_id, user_id, stripe_customer_id)
		  VALUES (?, ?, 'cus_x')`, r.studioID, studentID)
	return subID
}

func TestSubscriptionCheckout_RequiresRecurringProduct(t *testing.T) {
	r := newRig(t)
	configureStripeForTest(t, r)
	// A one-time product can't be subscribed to.
	productID := seedProduct(t, r, "credit", 5)
	res := r.do(http.MethodPost, "/checkout/subscription", map[string]any{
		"product_id":  productID,
		"success_url": "https://app.test/ok",
		"cancel_url":  "https://app.test/no",
	})
	if res.StatusCode != http.StatusInternalServerError && res.StatusCode != http.StatusBadRequest {
		// store returns a plain error (not recurring) → respondErr 500.
		t.Fatalf("expected error for one-time product, got %d", res.StatusCode)
	}
}

func TestSubscriptionCheckout_CreatesSessionForRecurring(t *testing.T) {
	r := newRig(t)
	configureStripeForTest(t, r)
	productID := seedRecurringProduct(t, r)
	res := r.do(http.MethodPost, "/checkout/subscription", map[string]any{
		"product_id":  productID,
		"success_url": "https://app.test/ok",
		"cancel_url":  "https://app.test/no",
	})
	if res.StatusCode != http.StatusOK {
		t.Fatalf("checkout subscription: %d", res.StatusCode)
	}
	out := decode[store.SubscriptionCheckoutResult](t, res)
	if out.SubscriptionID == "" || out.URL == "" {
		t.Fatalf("missing fields: %+v", out)
	}
	// The pending row exists for this student.
	subs := decode[[]store.Subscription](t, r.do(http.MethodGet, "/me/subscriptions", nil))
	if len(subs) != 1 || subs[0].Status != "pending" {
		t.Fatalf("expected 1 pending subscription, got %+v", subs)
	}
}

func TestAdminCancelSubscription_RequiresManager(t *testing.T) {
	r := newRig(t)
	subID := seedActiveSubscription(t, r)
	studentEmail := "student@test.com"
	mustExec(t, r.server.store, `INSERT INTO users (id, studio_id, role, email, full_name)
		VALUES (?, ?, 'student', ?, 'S')`, store.NewID(), r.studioID, studentEmail)
	res := r.as(studentEmail).do(http.MethodPost, "/admin/subscriptions/"+subID+"/cancel", nil)
	if res.StatusCode != http.StatusForbidden {
		t.Fatalf("student should be forbidden, got %d", res.StatusCode)
	}
}

// seedRecurringProduct creates a recurring/unlimited product already mirrored to
// Stripe (stripe_price_id set) so the subscription checkout can proceed.
func seedRecurringProduct(t *testing.T, r *testRig) string {
	t.Helper()
	id := store.NewID()
	var classTypeID string
	if err := store.TestDB(r.server.store).QueryRowContext(context.Background(),
		`SELECT id FROM class_types WHERE studio_id = ? LIMIT 1`, r.studioID).Scan(&classTypeID); err != nil {
		t.Fatalf("class type: %v", err)
	}
	mustExec(t, r.server.store, `
		INSERT INTO products
		  (id, studio_id, name, price_minor, billing_type, billing_interval, pass_kind,
		   validity_days, stripe_product_id, stripe_price_id)
		  VALUES (?, ?, 'Unlimited Monthly', 8800, 'recurring', 'month', 'unlimited',
		          30, 'prod_x', 'price_x')`, id, r.studioID)
	mustExec(t, r.server.store, `INSERT INTO product_class_types (product_id, class_type_id)
		VALUES (?, ?)`, id, classTypeID)
	return id
}
