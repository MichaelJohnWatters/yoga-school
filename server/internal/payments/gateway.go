// Package payments is the payment-processor boundary. It wraps the Stripe SDK
// behind a small interface so the store can talk to "a gateway" without
// importing stripe-go, unit tests can swap in a fake, and the dev_stub path
// can bypass the network entirely.
//
// Multi-tenant rule: every call takes the studio's secret key as an argument.
// This app stores one Stripe key set per studio (see studio_stripe_credentials)
// — there is deliberately NO process-global stripe.Key, because that would let
// one studio's request be charged against another's account.
package payments

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	stripe "github.com/stripe/stripe-go/v83"
	"github.com/stripe/stripe-go/v83/client"
	"github.com/stripe/stripe-go/v83/webhook"
)

// checkoutPaymentStatusPaid mirrors stripe's "paid" Checkout payment_status.
const checkoutPaymentStatusPaid = "paid"

// StatusSucceeded is the PaymentIntent status that authorises fulfilment.
// Mirrors stripe.PaymentIntentStatusSucceeded without leaking the SDK type
// past this package.
const StatusSucceeded = "succeeded"

// IntentParams is a studio-agnostic request to create a PaymentIntent. Amount
// is always server-computed (never trusted from the client).
type IntentParams struct {
	AmountMinor int64
	Currency    string // ISO 4217; any case — the gateway lowercases it.
	Metadata    map[string]string
	// IdempotencyKey makes CreateIntent safe to retry: Stripe returns the
	// same PaymentIntent for a repeated key instead of double-charging. We
	// pass the purchase_id so a double-tap / network retry is a no-op.
	IdempotencyKey string
	// Email, when set, is the buyer's address (from the authenticated user).
	// Set as the PaymentIntent's receipt_email so Stripe's receipt reaches
	// them without the PaymentSheet having to collect it. Empty → unset.
	Email string
	// Customer, when set (cus_…), attaches the intent to the buyer's Stripe
	// Customer so saved cards work in the PaymentSheet. Empty → one-off charge.
	Customer string
}

// Intent is the subset of a Stripe PaymentIntent the store needs.
type Intent struct {
	ID           string
	ClientSecret string
	Status       string
}

// CheckoutParams is a studio-agnostic request to create a hosted Checkout
// Session — the web payment surface. Amount is server-computed.
type CheckoutParams struct {
	AmountMinor    int64
	Currency       string
	ProductName    string // shown as the line item on Stripe's page
	SuccessURL     string
	CancelURL      string
	Metadata       map[string]string
	IdempotencyKey string
	// Email, when set, prefills the buyer's address on the hosted Checkout
	// page (Stripe's customer_email) so the student doesn't retype it. Empty
	// → Stripe collects it on the page as usual.
	Email string
}

// CheckoutSession is the subset of a Stripe Checkout Session the store needs.
type CheckoutSession struct {
	ID  string // cs_… — stored on the pending purchase until completion.
	URL string // hosted page the browser redirects to.
}

// PaymentMethod is the display subset of a saved card the wallet shows.
type PaymentMethod struct {
	ID       string `json:"id"` // pm_…
	Brand    string `json:"brand"`
	Last4    string `json:"last4"`
	ExpMonth int64  `json:"exp_month"`
	ExpYear  int64  `json:"exp_year"`
}

// CardPresentParams is a server-computed in-person (Stripe Terminal) charge.
// Amount is server-computed. Customer optionally links the sale to the buyer.
type CardPresentParams struct {
	AmountMinor    int64
	Currency       string
	Customer       string
	Metadata       map[string]string
	IdempotencyKey string
}

// CheckoutSessionStatus is what the web optimistic-confirm path reads back when
// retrieving a session: whether it's paid, and the PaymentIntent to link.
type CheckoutSessionStatus struct {
	PaymentStatus string // "paid" once settled.
	IntentID      string // pi_… ("" if not created yet).
}

// CustomerParams identifies the buyer when creating a Stripe Customer. We keep
// one Customer per (studio, student) so re-subscribing reuses saved cards.
type CustomerParams struct {
	Email    string
	Metadata map[string]string
	// IdempotencyKey makes concurrent first-checkout attempts safe: Stripe
	// returns the same Customer for a repeated key instead of creating a
	// duplicate. We pass studio+user so two racing checkouts converge.
	IdempotencyKey string
}

// PriceParams is a studio-agnostic request to mirror a recurring product into
// the studio's Stripe account as a Product + recurring Price. Interval is
// "month" or "year".
type PriceParams struct {
	ProductName string
	AmountMinor int64
	Currency    string
	Interval    string
}

// SubscriptionState is the live subscription snapshot the reconciler reads back
// from Stripe to self-heal when a webhook was missed.
type SubscriptionState struct {
	Status            string // active | past_due | canceled | …
	CurrentPeriodEnd  int64  // unix seconds; 0 if unknown.
	CancelAtPeriodEnd bool
}

// SubscriptionCheckoutParams is a request to create a hosted Checkout Session in
// subscription mode. PriceID is the recurring Price the product mirrors to;
// Customer is the studio's cus_… for the buyer.
type SubscriptionCheckoutParams struct {
	PriceID        string
	CustomerID     string
	SuccessURL     string
	CancelURL      string
	Metadata       map[string]string
	IdempotencyKey string
}

// Event is a signature-verified webhook event reduced to what fulfilment
// needs. Fields are populated per event family:
//   - payment_intent.*       → IntentID, Status
//   - checkout.session.*     → SessionID, IntentID (the session's PI), Status
//   - charge.refunded        → IntentID, AmountRefundedMinor, FullyRefunded
type Event struct {
	ID                  string // evt_… — used for the processed-events dedup table.
	Type                string // e.g. "checkout.session.completed".
	IntentID            string // pi_… ("" when the event carries none).
	SessionID           string // cs_… (checkout.session.* only).
	Status              string // PI status, or Checkout payment_status ("paid").
	AmountRefundedMinor int64  // charge.refunded: cumulative amount refunded.
	FullyRefunded       bool   // charge.refunded: the whole charge is refunded.

	// Subscription fields, populated per family:
	//   checkout.session.*       → SessionMode, SubscriptionID, CustomerID
	//   invoice.*                → SubscriptionID, CustomerID, InvoiceBillingReason,
	//                              CurrentPeriodEnd (from the line item period)
	//   customer.subscription.*  → SubscriptionID, CustomerID, SubscriptionStatus,
	//                              CancelAtPeriodEnd, CurrentPeriodEnd
	SessionMode          string // "payment" | "subscription" (checkout.session.*).
	SubscriptionID       string // sub_…
	CustomerID           string // cus_…
	SubscriptionStatus   string // active | past_due | canceled | …
	InvoiceBillingReason string // subscription_create | subscription_cycle | …
	CurrentPeriodEnd     int64  // unix seconds; 0 when absent.
	CancelAtPeriodEnd    bool

	// charge.dispute.* — a chargeback against a charge. IntentID links it to
	// our purchase (the disputed charge's PaymentIntent).
	DisputeStatus      string // needs_response | under_review | won | lost | …
	DisputeReason      string // fraudulent | product_not_received | …
	DisputeAmountMinor int64
	DisputeDueAt       int64 // evidence submission deadline (unix seconds; 0 if none).
}

// Gateway is the payment-processor boundary. The secret key is passed per
// call (multi-tenant — see package doc).
type Gateway interface {
	CreateIntent(ctx context.Context, secretKey string, p IntentParams) (Intent, error)
	GetIntent(ctx context.Context, secretKey, intentID string) (Intent, error)
	// CreateCheckoutSession creates a hosted Checkout Session (web surface).
	CreateCheckoutSession(ctx context.Context, secretKey string, p CheckoutParams) (CheckoutSession, error)
	// GetCheckoutSession retrieves a session so the web success page can
	// confirm payment client-side (optimistic; the webhook is authoritative).
	GetCheckoutSession(ctx context.Context, secretKey, sessionID string) (CheckoutSessionStatus, error)
	// Refund refunds amountMinor against a PaymentIntent. amountMinor <= 0
	// means a full refund. idempotencyKey makes a retried refund safe (Stripe
	// returns the same refund instead of issuing a second). Returns the refund id.
	Refund(ctx context.Context, secretKey, intentID string, amountMinor int64, idempotencyKey string) (string, error)
	// VerifyWebhook checks the Stripe-Signature header against the studio's
	// webhook signing secret and returns the parsed event. A bad signature
	// is an error — the caller must reject the request.
	VerifyWebhook(payload []byte, sigHeader, webhookSecret string) (Event, error)

	// --- Subscriptions / memberships -----------------------------------

	// CreateEphemeralKey mints a short-lived key scoped to a Customer for the
	// mobile PaymentSheet (saved cards). stripeVersion must match the mobile
	// SDK's API version.
	CreateEphemeralKey(ctx context.Context, secretKey, customerID, stripeVersion string) (string, error)

	// --- Saved card management (the wallet's Payment methods) ---
	// ListPaymentMethods returns the customer's saved cards (display fields).
	ListPaymentMethods(ctx context.Context, secretKey, customerID string) ([]PaymentMethod, error)
	// CreateSetupIntent makes a SetupIntent for saving a card with no charge —
	// the native PaymentSheet's "Add card" surface. Returns the client secret.
	CreateSetupIntent(ctx context.Context, secretKey, customerID string) (string, error)
	// CreateSetupCheckoutSession is the web "Add card" surface: a hosted
	// Checkout in setup mode that saves a card to the customer. Returns the URL.
	CreateSetupCheckoutSession(ctx context.Context, secretKey, customerID, successURL, cancelURL string) (string, error)
	// DetachPaymentMethod removes a saved card. It verifies the card belongs to
	// customerID first so one user can't detach another's card by id.
	DetachPaymentMethod(ctx context.Context, secretKey, customerID, paymentMethodID string) error

	// --- Stripe Terminal (in-person, server-driven smart readers) ---
	// CreateTerminalLocation makes a Location the studio's readers belong to.
	CreateTerminalLocation(ctx context.Context, secretKey, displayName, country string) (string, error)
	// RegisterTerminalReader registers a physical/simulated reader (by its
	// on-device code) to a Location. Returns the reader id (tmr_…).
	RegisterTerminalReader(ctx context.Context, secretKey, locationID, registrationCode, label string) (string, error)
	// CreateCardPresentIntent makes a PaymentIntent for an in-person charge.
	// This is the ONE place payment_method_types is set ('card_present') — the
	// documented exception to dynamic payment methods.
	CreateCardPresentIntent(ctx context.Context, secretKey string, p CardPresentParams) (Intent, error)
	// ProcessPaymentIntentOnReader hands a PaymentIntent to a reader so it
	// prompts the customer to tap/insert. Fulfilment lands via the webhook.
	ProcessPaymentIntentOnReader(ctx context.Context, secretKey, readerID, paymentIntentID string) error
	// CancelReaderAction aborts the reader's in-progress collection (customer
	// walked away / wrong amount).
	CancelReaderAction(ctx context.Context, secretKey, readerID string) error
	// EnsureCustomer creates a Stripe Customer in the studio's account and
	// returns its cus_… id. We persist it per (studio, student) and reuse it.
	EnsureCustomer(ctx context.Context, secretKey string, p CustomerParams) (string, error)
	// CreateRecurringPrice mirrors a recurring product into the studio's
	// account as a Product + recurring Price. Returns (productID, priceID).
	// Stripe Prices are immutable, so a price/interval edit calls this again.
	CreateRecurringPrice(ctx context.Context, secretKey string, p PriceParams) (productID, priceID string, err error)
	// ArchivePrice deactivates a Price (sets active=false). Used when a
	// recurring product's price/interval changes and we repoint to a new one.
	ArchivePrice(ctx context.Context, secretKey, priceID string) error
	// CreateCheckoutSubscription creates a hosted Checkout Session in
	// subscription mode against an existing recurring Price + Customer.
	CreateCheckoutSubscription(ctx context.Context, secretKey string, p SubscriptionCheckoutParams) (CheckoutSession, error)
	// GetSubscription reads the live subscription state (status, period end,
	// cancel-at-period-end) so the janitor can reconcile a missed webhook.
	GetSubscription(ctx context.Context, secretKey, subID string) (SubscriptionState, error)
	// CancelSubscription cancels a subscription. atPeriodEnd=true schedules
	// the cancellation for the end of the paid period (access continues);
	// false cancels immediately.
	CancelSubscription(ctx context.Context, secretKey, subID string, atPeriodEnd bool) error
	// ResumeSubscription clears a pending end-of-period cancellation.
	ResumeSubscription(ctx context.Context, secretKey, subID string) error
	// CreateBillingPortalSession returns a URL to Stripe's hosted billing
	// portal where the customer can update their card / manage the membership.
	CreateBillingPortalSession(ctx context.Context, secretKey, customerID, returnURL string) (string, error)
}

// StripeGateway is the real, network-backed implementation.
type StripeGateway struct{}

// NewStripeGateway returns a gateway that talks to the live Stripe API.
func NewStripeGateway() *StripeGateway { return &StripeGateway{} }

// api builds a per-call client bound to one studio's secret key. Cheap — it's
// just struct init; no connection is opened until a request is made.
func (g *StripeGateway) api(secretKey string) *client.API {
	sc := &client.API{}
	sc.Init(secretKey, nil)
	return sc
}

func (g *StripeGateway) CreateIntent(ctx context.Context, secretKey string, p IntentParams) (Intent, error) {
	params := &stripe.PaymentIntentParams{
		Amount:   stripe.Int64(p.AmountMinor),
		Currency: stripe.String(strings.ToLower(p.Currency)),
		// Dynamic payment methods: never set PaymentMethodTypes. This is what
		// surfaces Apple Pay / Google Pay and lets the studio manage methods
		// from their Stripe Dashboard.
		AutomaticPaymentMethods: &stripe.PaymentIntentAutomaticPaymentMethodsParams{
			Enabled: stripe.Bool(true),
		},
	}
	if p.Email != "" {
		params.ReceiptEmail = stripe.String(p.Email)
	}
	// Attaching the buyer's Customer lets the PaymentSheet list their saved
	// cards and offer to save a new one (paired with an ephemeral key on the
	// client). Empty = a one-off charge with no customer.
	if p.Customer != "" {
		params.Customer = stripe.String(p.Customer)
	}
	params.Context = ctx
	if p.IdempotencyKey != "" {
		params.SetIdempotencyKey(p.IdempotencyKey)
	}
	for k, v := range p.Metadata {
		params.AddMetadata(k, v)
	}
	pi, err := g.api(secretKey).PaymentIntents.New(params)
	if err != nil {
		return Intent{}, err
	}
	return Intent{ID: pi.ID, ClientSecret: pi.ClientSecret, Status: string(pi.Status)}, nil
}

// CreateEphemeralKey mints a short-lived key scoped to one Customer, used by
// the mobile PaymentSheet to read/save that customer's payment methods. The
// stripeVersion MUST match the mobile SDK's pinned API version or the SDK
// rejects the key — the client sends its version (see the app's
// stripeApiVersion constant).
func (g *StripeGateway) CreateEphemeralKey(ctx context.Context, secretKey, customerID, stripeVersion string) (string, error) {
	params := &stripe.EphemeralKeyParams{
		Customer:      stripe.String(customerID),
		StripeVersion: stripe.String(stripeVersion),
	}
	params.Context = ctx
	key, err := g.api(secretKey).EphemeralKeys.New(params)
	if err != nil {
		return "", err
	}
	return key.Secret, nil
}

func (g *StripeGateway) CreateTerminalLocation(ctx context.Context, secretKey, displayName, country string) (string, error) {
	if country == "" {
		country = "GB"
	}
	params := &stripe.TerminalLocationParams{
		DisplayName: stripe.String(displayName),
		// Stripe requires an address on a Location; country is the only field
		// that matters for our purposes (registration is keyed to the reader).
		Address: &stripe.AddressParams{Country: stripe.String(country)},
	}
	params.Context = ctx
	loc, err := g.api(secretKey).TerminalLocations.New(params)
	if err != nil {
		return "", err
	}
	return loc.ID, nil
}

func (g *StripeGateway) RegisterTerminalReader(ctx context.Context, secretKey, locationID, registrationCode, label string) (string, error) {
	params := &stripe.TerminalReaderParams{
		Location:         stripe.String(locationID),
		RegistrationCode: stripe.String(registrationCode),
	}
	if label != "" {
		params.Label = stripe.String(label)
	}
	params.Context = ctx
	r, err := g.api(secretKey).TerminalReaders.New(params)
	if err != nil {
		return "", err
	}
	return r.ID, nil
}

func (g *StripeGateway) CreateCardPresentIntent(ctx context.Context, secretKey string, p CardPresentParams) (Intent, error) {
	params := &stripe.PaymentIntentParams{
		Amount:   stripe.Int64(p.AmountMinor),
		Currency: stripe.String(strings.ToLower(p.Currency)),
		// The one valid use of PaymentMethodTypes: Terminal requires
		// 'card_present'. Automatic capture so the sale settles on tap.
		PaymentMethodTypes: stripe.StringSlice([]string{"card_present"}),
		CaptureMethod:      stripe.String(string(stripe.PaymentIntentCaptureMethodAutomatic)),
	}
	if p.Customer != "" {
		params.Customer = stripe.String(p.Customer)
	}
	params.Context = ctx
	if p.IdempotencyKey != "" {
		params.SetIdempotencyKey(p.IdempotencyKey)
	}
	for k, v := range p.Metadata {
		params.AddMetadata(k, v)
	}
	pi, err := g.api(secretKey).PaymentIntents.New(params)
	if err != nil {
		return Intent{}, err
	}
	return Intent{ID: pi.ID, ClientSecret: pi.ClientSecret, Status: string(pi.Status)}, nil
}

func (g *StripeGateway) ProcessPaymentIntentOnReader(ctx context.Context, secretKey, readerID, paymentIntentID string) error {
	params := &stripe.TerminalReaderProcessPaymentIntentParams{
		PaymentIntent: stripe.String(paymentIntentID),
	}
	params.Context = ctx
	_, err := g.api(secretKey).TerminalReaders.ProcessPaymentIntent(readerID, params)
	return err
}

func (g *StripeGateway) CancelReaderAction(ctx context.Context, secretKey, readerID string) error {
	params := &stripe.TerminalReaderCancelActionParams{}
	params.Context = ctx
	_, err := g.api(secretKey).TerminalReaders.CancelAction(readerID, params)
	return err
}

func (g *StripeGateway) ListPaymentMethods(ctx context.Context, secretKey, customerID string) ([]PaymentMethod, error) {
	params := &stripe.PaymentMethodListParams{
		Customer: stripe.String(customerID),
		Type:     stripe.String("card"),
	}
	params.Context = ctx
	iter := g.api(secretKey).PaymentMethods.List(params)
	out := make([]PaymentMethod, 0)
	for iter.Next() {
		pm := iter.PaymentMethod()
		m := PaymentMethod{ID: pm.ID}
		if pm.Card != nil {
			m.Brand = string(pm.Card.Brand)
			m.Last4 = pm.Card.Last4
			m.ExpMonth = pm.Card.ExpMonth
			m.ExpYear = pm.Card.ExpYear
		}
		out = append(out, m)
	}
	return out, iter.Err()
}

func (g *StripeGateway) CreateSetupIntent(ctx context.Context, secretKey, customerID string) (string, error) {
	params := &stripe.SetupIntentParams{
		Customer: stripe.String(customerID),
	}
	params.Context = ctx
	si, err := g.api(secretKey).SetupIntents.New(params)
	if err != nil {
		return "", err
	}
	return si.ClientSecret, nil
}

func (g *StripeGateway) CreateSetupCheckoutSession(ctx context.Context, secretKey, customerID, successURL, cancelURL string) (string, error) {
	params := &stripe.CheckoutSessionParams{
		Mode:       stripe.String(string(stripe.CheckoutSessionModeSetup)),
		Customer:   stripe.String(customerID),
		SuccessURL: stripe.String(successURL),
		CancelURL:  stripe.String(cancelURL),
	}
	params.Context = ctx
	sess, err := g.api(secretKey).CheckoutSessions.New(params)
	if err != nil {
		return "", err
	}
	return sess.URL, nil
}

func (g *StripeGateway) DetachPaymentMethod(ctx context.Context, secretKey, customerID, paymentMethodID string) error {
	api := g.api(secretKey)
	get := &stripe.PaymentMethodParams{}
	get.Context = ctx
	pm, err := api.PaymentMethods.Get(paymentMethodID, get)
	if err != nil {
		return err
	}
	if pm.Customer == nil || pm.Customer.ID != customerID {
		return errors.New("payment method does not belong to this customer")
	}
	det := &stripe.PaymentMethodDetachParams{}
	det.Context = ctx
	_, err = api.PaymentMethods.Detach(paymentMethodID, det)
	return err
}

func (g *StripeGateway) CreateCheckoutSession(ctx context.Context, secretKey string, p CheckoutParams) (CheckoutSession, error) {
	params := &stripe.CheckoutSessionParams{
		Mode:       stripe.String(string(stripe.CheckoutSessionModePayment)),
		SuccessURL: stripe.String(p.SuccessURL),
		CancelURL:  stripe.String(p.CancelURL),
		LineItems: []*stripe.CheckoutSessionLineItemParams{{
			Quantity: stripe.Int64(1),
			PriceData: &stripe.CheckoutSessionLineItemPriceDataParams{
				Currency:   stripe.String(strings.ToLower(p.Currency)),
				UnitAmount: stripe.Int64(p.AmountMinor),
				ProductData: &stripe.CheckoutSessionLineItemPriceDataProductDataParams{
					Name: stripe.String(p.ProductName),
				},
			},
		}},
	}
	if p.Email != "" {
		params.CustomerEmail = stripe.String(p.Email)
	}
	params.Context = ctx
	if p.IdempotencyKey != "" {
		params.SetIdempotencyKey(p.IdempotencyKey)
	}
	for k, v := range p.Metadata {
		params.AddMetadata(k, v)
	}
	sess, err := g.api(secretKey).CheckoutSessions.New(params)
	if err != nil {
		return CheckoutSession{}, err
	}
	return CheckoutSession{ID: sess.ID, URL: sess.URL}, nil
}

func (g *StripeGateway) GetCheckoutSession(ctx context.Context, secretKey, sessionID string) (CheckoutSessionStatus, error) {
	params := &stripe.CheckoutSessionParams{}
	params.Context = ctx
	sess, err := g.api(secretKey).CheckoutSessions.Get(sessionID, params)
	if err != nil {
		return CheckoutSessionStatus{}, err
	}
	out := CheckoutSessionStatus{PaymentStatus: string(sess.PaymentStatus)}
	if sess.PaymentIntent != nil {
		out.IntentID = sess.PaymentIntent.ID
	}
	return out, nil
}

func (g *StripeGateway) Refund(ctx context.Context, secretKey, intentID string, amountMinor int64, idempotencyKey string) (string, error) {
	params := &stripe.RefundParams{PaymentIntent: stripe.String(intentID)}
	params.Context = ctx
	if amountMinor > 0 {
		params.Amount = stripe.Int64(amountMinor)
	}
	if idempotencyKey != "" {
		params.SetIdempotencyKey(idempotencyKey)
	}
	r, err := g.api(secretKey).Refunds.New(params)
	if err != nil {
		return "", err
	}
	return r.ID, nil
}

func (g *StripeGateway) EnsureCustomer(ctx context.Context, secretKey string, p CustomerParams) (string, error) {
	params := &stripe.CustomerParams{}
	params.Context = ctx
	if p.Email != "" {
		params.Email = stripe.String(p.Email)
	}
	if p.IdempotencyKey != "" {
		params.SetIdempotencyKey(p.IdempotencyKey)
	}
	for k, v := range p.Metadata {
		params.AddMetadata(k, v)
	}
	c, err := g.api(secretKey).Customers.New(params)
	if err != nil {
		return "", err
	}
	return c.ID, nil
}

func (g *StripeGateway) CreateRecurringPrice(ctx context.Context, secretKey string, p PriceParams) (string, string, error) {
	sc := g.api(secretKey)
	prodParams := &stripe.ProductParams{Name: stripe.String(p.ProductName)}
	prodParams.Context = ctx
	prod, err := sc.Products.New(prodParams)
	if err != nil {
		return "", "", err
	}
	priceParams := &stripe.PriceParams{
		Product:    stripe.String(prod.ID),
		Currency:   stripe.String(strings.ToLower(p.Currency)),
		UnitAmount: stripe.Int64(p.AmountMinor),
		Recurring:  &stripe.PriceRecurringParams{Interval: stripe.String(p.Interval)},
	}
	priceParams.Context = ctx
	price, err := sc.Prices.New(priceParams)
	if err != nil {
		return "", "", err
	}
	return prod.ID, price.ID, nil
}

func (g *StripeGateway) ArchivePrice(ctx context.Context, secretKey, priceID string) error {
	params := &stripe.PriceParams{Active: stripe.Bool(false)}
	params.Context = ctx
	_, err := g.api(secretKey).Prices.Update(priceID, params)
	return err
}

func (g *StripeGateway) CreateCheckoutSubscription(ctx context.Context, secretKey string, p SubscriptionCheckoutParams) (CheckoutSession, error) {
	params := &stripe.CheckoutSessionParams{
		Mode:       stripe.String(string(stripe.CheckoutSessionModeSubscription)),
		Customer:   stripe.String(p.CustomerID),
		SuccessURL: stripe.String(p.SuccessURL),
		CancelURL:  stripe.String(p.CancelURL),
		LineItems: []*stripe.CheckoutSessionLineItemParams{{
			Price:    stripe.String(p.PriceID),
			Quantity: stripe.Int64(1),
		}},
		// Copy our metadata onto the Subscription too (not just the session),
		// so customer.subscription.* and invoice.* events carry our ids — the
		// webhook can resolve the row without leaning on the customer fallback.
		SubscriptionData: &stripe.CheckoutSessionSubscriptionDataParams{},
	}
	params.Context = ctx
	if p.IdempotencyKey != "" {
		params.SetIdempotencyKey(p.IdempotencyKey)
	}
	for k, v := range p.Metadata {
		params.AddMetadata(k, v)
		params.SubscriptionData.AddMetadata(k, v)
	}
	sess, err := g.api(secretKey).CheckoutSessions.New(params)
	if err != nil {
		return CheckoutSession{}, err
	}
	return CheckoutSession{ID: sess.ID, URL: sess.URL}, nil
}

func (g *StripeGateway) GetSubscription(ctx context.Context, secretKey, subID string) (SubscriptionState, error) {
	params := &stripe.SubscriptionParams{}
	params.Context = ctx
	sub, err := g.api(secretKey).Subscriptions.Get(subID, params)
	if err != nil {
		return SubscriptionState{}, err
	}
	out := SubscriptionState{
		Status:            string(sub.Status),
		CancelAtPeriodEnd: sub.CancelAtPeriodEnd,
	}
	// v83 carries the period end on each item; take the latest.
	if sub.Items != nil {
		for _, it := range sub.Items.Data {
			if it.CurrentPeriodEnd > out.CurrentPeriodEnd {
				out.CurrentPeriodEnd = it.CurrentPeriodEnd
			}
		}
	}
	return out, nil
}

func (g *StripeGateway) CancelSubscription(ctx context.Context, secretKey, subID string, atPeriodEnd bool) error {
	sc := g.api(secretKey)
	if atPeriodEnd {
		params := &stripe.SubscriptionParams{CancelAtPeriodEnd: stripe.Bool(true)}
		params.Context = ctx
		_, err := sc.Subscriptions.Update(subID, params)
		return err
	}
	params := &stripe.SubscriptionCancelParams{}
	params.Context = ctx
	_, err := sc.Subscriptions.Cancel(subID, params)
	return err
}

func (g *StripeGateway) ResumeSubscription(ctx context.Context, secretKey, subID string) error {
	params := &stripe.SubscriptionParams{CancelAtPeriodEnd: stripe.Bool(false)}
	params.Context = ctx
	_, err := g.api(secretKey).Subscriptions.Update(subID, params)
	return err
}

func (g *StripeGateway) CreateBillingPortalSession(ctx context.Context, secretKey, customerID, returnURL string) (string, error) {
	params := &stripe.BillingPortalSessionParams{
		Customer:  stripe.String(customerID),
		ReturnURL: stripe.String(returnURL),
	}
	params.Context = ctx
	sess, err := g.api(secretKey).BillingPortalSessions.New(params)
	if err != nil {
		return "", err
	}
	return sess.URL, nil
}

func (g *StripeGateway) GetIntent(ctx context.Context, secretKey, intentID string) (Intent, error) {
	params := &stripe.PaymentIntentParams{}
	params.Context = ctx
	pi, err := g.api(secretKey).PaymentIntents.Get(intentID, params)
	if err != nil {
		return Intent{}, err
	}
	return Intent{ID: pi.ID, ClientSecret: pi.ClientSecret, Status: string(pi.Status)}, nil
}

func (g *StripeGateway) VerifyWebhook(payload []byte, sigHeader, webhookSecret string) (Event, error) {
	// IgnoreAPIVersionMismatch: this is multi-tenant — each studio's Stripe
	// account has its own default API version, which won't necessarily match
	// the version stripe-go is pinned to. A strict match would make a studio's
	// webhooks fail wholesale. We only read a few stable, long-lived fields
	// (ids, status, payment_intent), so a version skew is safe here. The
	// signature + timestamp are still fully verified.
	evt, err := webhook.ConstructEventWithOptions(payload, sigHeader, webhookSecret,
		webhook.ConstructEventOptions{IgnoreAPIVersionMismatch: true})
	if err != nil {
		return Event{}, err
	}
	out := Event{ID: evt.ID, Type: string(evt.Type)}
	switch {
	case strings.HasPrefix(out.Type, "payment_intent."):
		var pi stripe.PaymentIntent
		if err := json.Unmarshal(evt.Data.Raw, &pi); err != nil {
			return Event{}, err
		}
		out.IntentID = pi.ID
		out.Status = string(pi.Status)
	case strings.HasPrefix(out.Type, "checkout.session."):
		var sess stripe.CheckoutSession
		if err := json.Unmarshal(evt.Data.Raw, &sess); err != nil {
			return Event{}, err
		}
		out.SessionID = sess.ID
		out.Status = string(sess.PaymentStatus)
		out.SessionMode = string(sess.Mode)
		if sess.PaymentIntent != nil {
			out.IntentID = sess.PaymentIntent.ID
		}
		if sess.Subscription != nil {
			out.SubscriptionID = sess.Subscription.ID
		}
		if sess.Customer != nil {
			out.CustomerID = sess.Customer.ID
		}
	case strings.HasPrefix(out.Type, "invoice."):
		var inv stripe.Invoice
		if err := json.Unmarshal(evt.Data.Raw, &inv); err != nil {
			return Event{}, err
		}
		out.InvoiceBillingReason = string(inv.BillingReason)
		if inv.Customer != nil {
			out.CustomerID = inv.Customer.ID
		}
		// v83 links the invoice to its subscription via parent.subscription_details.
		if inv.Parent != nil && inv.Parent.SubscriptionDetails != nil &&
			inv.Parent.SubscriptionDetails.Subscription != nil {
			out.SubscriptionID = inv.Parent.SubscriptionDetails.Subscription.ID
		}
		// The new period end is the subscription line item's period end.
		if inv.Lines != nil {
			for _, ln := range inv.Lines.Data {
				if ln.Period != nil && ln.Period.End > out.CurrentPeriodEnd {
					out.CurrentPeriodEnd = ln.Period.End
				}
			}
		}
	case strings.HasPrefix(out.Type, "customer.subscription."):
		var sub stripe.Subscription
		if err := json.Unmarshal(evt.Data.Raw, &sub); err != nil {
			return Event{}, err
		}
		out.SubscriptionID = sub.ID
		out.SubscriptionStatus = string(sub.Status)
		out.CancelAtPeriodEnd = sub.CancelAtPeriodEnd
		if sub.Customer != nil {
			out.CustomerID = sub.Customer.ID
		}
		// v83 moved current_period_end onto each subscription item.
		if sub.Items != nil {
			for _, it := range sub.Items.Data {
				if it.CurrentPeriodEnd > out.CurrentPeriodEnd {
					out.CurrentPeriodEnd = it.CurrentPeriodEnd
				}
			}
		}
	case out.Type == "charge.refunded":
		var ch stripe.Charge
		if err := json.Unmarshal(evt.Data.Raw, &ch); err != nil {
			return Event{}, err
		}
		if ch.PaymentIntent != nil {
			out.IntentID = ch.PaymentIntent.ID
		}
		out.AmountRefundedMinor = ch.AmountRefunded
		out.FullyRefunded = ch.Refunded
	case strings.HasPrefix(out.Type, "charge.dispute."):
		var d stripe.Dispute
		if err := json.Unmarshal(evt.Data.Raw, &d); err != nil {
			return Event{}, err
		}
		if d.PaymentIntent != nil {
			out.IntentID = d.PaymentIntent.ID
		}
		out.DisputeStatus = string(d.Status)
		out.DisputeReason = string(d.Reason)
		out.DisputeAmountMinor = d.Amount
		if d.EvidenceDetails != nil {
			out.DisputeDueAt = d.EvidenceDetails.DueBy
		}
	}
	return out, nil
}
