# Payments (Stripe)

How single-class tickets, N-class packs, and **recurring memberships** are sold,
fulfilled, and refunded. Memberships (rolling subscriptions) are documented in
[Memberships (subscriptions)](#memberships-subscriptions).

## Architecture at a glance

- **Multi-tenant, direct keys.** Each studio brings its own Stripe account.
  Keys are stored AES-GCM encrypted per studio in `studio_stripe_credentials`
  and resolved per call via `Store.LoadStripeKeysForUse`. There is **no**
  process-global `stripe.Key`. This is **not** Stripe Connect.
- **Two payment surfaces, one fulfilment backend:**
  - **Web (primary): hosted Checkout Session.** Browser redirects to
    `checkout.stripe.com`, returns to `?checkout=success`.
  - **Mobile (later): PaymentSheet** backed by a PaymentIntent (`flutter_stripe`).
  - Both produce a `pending` purchase and are fulfilled by the **same webhook**.
- **The webhook is authoritative.** A pass is minted by the
  `checkout.session.completed` / `payment_intent.succeeded` webhook, not by the
  client. The client's `/confirm` (mobile) and the web success page are just
  optimistic UX — if the app/browser never returns, the webhook still delivers.
- **Janitor safety net.** An in-process goroutine (`internal/jobs/janitor.go`,
  every 5 min) reconciles `pending` purchases older than 15 min against Stripe
  (confirm-or-void) and sweeps expired/depleted entitlements.
- **dev_stub fallback.** With no Stripe configured (no `STRIPE_KEY_ENC_MASTER`
  or no studio keys), purchases complete instantly via `dev_stub`. This is how
  local dev and the integration-test suite run without Stripe.

## Production safety: the dev-payment gate

`dev_stub` (and `cash` / `comp` / `card_present` / `transfer`) settle a purchase
synchronously with no real money. On the **self-serve** endpoints
(`POST /purchases`, `POST /enrollments/{id}/join`) that would let a prod client
mint a free pass — so `paymentMethodAllowed` (`internal/api/api.go`) **rejects
any non-`card` method in prod with 403**. The allow signal is the auth emulator
being active (`FIREBASE_AUTH_EMULATOR_HOST` set) — the same gate the `/dev/*`
routes use, so prod (real Firebase, no emulator) is locked by default. Locked in
by `TestPaymentMethodAllowed`.

Implications:
- In prod, students pay by `card` only. Legitimate cash/comp sales go through
  the **manager grant flow** (`admin_students.go`), not the self-serve endpoint.
- Paid **series enrollments** have no card path yet, so they're effectively
  blocked in prod until one is built — by design, rather than silently allowing
  `dev_stub`.
- All `/dev/*` routes (`reset-test-state`, `fill-class`, `configure-stripe`)
  already 404 in prod via the same emulator gate.

```
Buy ─▶ POST /checkout/session (web) ─▶ Stripe hosted page ─┐
   └─▶ POST /purchases card (mobile) ─▶ PaymentSheet ───────┤
                                                            ▼
                          Stripe ── webhook ──▶ mint pass (authoritative)
                          client return ──▶ refresh wallet / optimistic confirm
                          janitor ──▶ reconcile anything missed
```

## Webhook events (register exactly these)

Endpoint: `POST /stripe/webhook/{studioID}` — **public**, no auth; authenticated
by the `Stripe-Signature` header against the studio's webhook secret. Per-studio
path so we know which secret to verify against before parsing.

| Event | Effect |
| --- | --- |
| `checkout.session.completed` | Web success → mint pass, swap `cs_…`→`pi_…` |
| `checkout.session.async_payment_succeeded` | Delayed-settlement web payment finally paid → mint pass |
| `checkout.session.async_payment_failed` | Delayed payment failed → void pending purchase |
| `checkout.session.expired` | Web abandoned → void pending purchase |
| `payment_intent.succeeded` | Mobile success → mint pass |
| `payment_intent.payment_failed` | Void pending purchase |
| `payment_intent.canceled` | Void pending purchase |
| `charge.refunded` | Reflect a Dashboard-initiated refund (money only) |
| `charge.dispute.created` / `.updated` / `.closed` | Record a chargeback on the purchase + alert managers (never auto-revokes the pass) |
| `invoice.paid` | Membership initial/renewal payment → grant/extend the rolling pass + record a `purchases` row (revenue/refund/dispute matching) + capture the PI on `subscriptions.last_payment_intent_id` |
| `invoice.payment_failed` | Membership dunning → mark subscription `past_due` |
| `customer.subscription.updated` | Reflect status / cancel-at-period-end / period end |
| `customer.subscription.deleted` | Membership ended → mark `canceled`, end access |

Redeliveries are deduped via `processed_stripe_events`; fulfilment is idempotent
regardless. Signature verification uses `IgnoreAPIVersionMismatch: true` on
purpose — each studio's account API version is theirs, and a strict match would
break their webhooks wholesale (we only read stable id/status fields).

## Pass allocation & refunds (money ≠ pass)

The codebase keeps **money and pass deliberately separate** so a goodwill refund
doesn't strip a pass, and revoking a comp doesn't force a refund.

| Action | Money | Pass |
| --- | --- | --- |
| Purchase | charged | allocated by **webhook** |
| `RefundPurchase` (`/admin/purchases/{id}/refund`) | refunded via Stripe (card) | **kept** |
| `VoidEntitlement` — `unused` | refunds `price × creditsRemaining/creditsTotal` | **revoked** + future bookings cancelled |
| `VoidEntitlement` — `full` | full refund | revoked |
| Dashboard refund (`charge.refunded`) | reflected on the purchase | **kept** |

Rule of thumb: **you only refund what wasn't used.** A 10-pack with 4 classes
taken refunds 6/10. The manager-facing "Void & refund" dialog drives
`VoidEntitlement`; the money-only `RefundPurchase` exists as an endpoint but has
no UI button yet (the goodwill "refund but keep the pass" case).

## Chargebacks & "Payments needing attention"

A **dispute** (chargeback) is a separate event *on top of* a successful
payment — the cardholder's bank claws funds back, often weeks later. We
**never auto-revoke the pass** on a dispute (a dispute can be unresolved or
bogus, and the studio may win it). Instead `charge.dispute.*` records the
status/reason/deadline on the purchase (`RecordDispute`) and notifies the
studio's managers.

Managers act from the **Payments needing attention** screen
(`GET /admin/payments/attention`, manager-only), which surfaces two row types:

- **Open chargebacks** — with the student, product, amount, dispute status +
  evidence deadline, and *how many classes were attended / are still booked* on
  the affected pass. Action: **Void & revoke pass** (`VoidEntitlement`, with a
  no-refund option since the bank already pulled the funds).
- **Past-due memberships** — a renewal that didn't get paid. Action: **Cancel
  membership now** (`AdminCancelSubscription` with `immediate=true` — cancels
  the Stripe subscription at once and revokes access + upcoming bookings,
  vs the student-facing cancel which is end-of-period).

A resolved dispute (won / lost / closed) drops off the list automatically.
Note: disputes are matched to a purchase by the charge's PaymentIntent, so this
covers one-time purchases; subscription-invoice disputes aren't linked to a
purchase row yet.

## Configuration

| Where | What |
| --- | --- |
| `STRIPE_KEY_ENC_MASTER` (env) | Hex string decoding to **32 bytes** (`openssl rand -hex 32`). Enables the gateway + secret encryption. Unset → dev_stub. Malformed → server refuses to boot (prod-parity guard). |
| Manager → Settings → Stripe | Per-studio publishable key, secret key, webhook secret, wallet toggles, merchant display name/country. |
| Stripe Dashboard | Enable Apple/Google Pay; register the per-studio webhook URL with the events above. |
| iOS app (later) | Apple Pay merchant id in Xcode entitlements; update `_appleMerchantId` in `checkout_sheet.dart`. App-level, not per studio. |

Recommend a **restricted key (`rk_`)** over a full `sk_` where possible.

## E2E tests

A Flutter integration test can't drive Stripe's hosted page / native sheet, so
coverage is split:

- **Go full-fulfilment** — `TestStripeRealAPI_E2E` (`server/internal/store/stripe_realapi_e2e_test.go`).
  Real money→pass round-trip against Stripe test mode (create intent → confirm
  with `pm_card_visa` via the Stripe API → our confirm mints → real refund).
  Behind the **`stripe_e2e` build tag** so it's out of the normal `go test ./...`
  (which stays fast + offline). When run it loads `.env` (`STRIPE_E2E_SECRET_KEY`
  or `STRIPE_SECRET_KEY`) — runs for real when keys are present, skips when not.
  ```bash
  go test -tags stripe_e2e -run StripeRealAPI ./internal/store/ -v   # or the Tilt button
  ```
- **Flutter session-creation** — `app/integration_test/checkout_session_test.dart`.
  Drives the real UI and asserts a real `checkout.stripe.com` URL (captures the
  redirect via the `debugCheckoutRedirectOverride` seam). Web integration tests
  need `flutter drive` + chromedriver. Runs against real Stripe when the
  `--dart-define` keys are supplied; skips otherwise.
  ```bash
  chromedriver --port=4444 &
  flutter drive --driver=test_driver/integration_test.dart \
    --target=integration_test/checkout_session_test.dart \
    -d web-server --browser-name=chrome \
    --dart-define=STRIPE_TEST_SK=sk_test_… --dart-define=STRIPE_TEST_PK=pk_test_…
  ```
- **Webhook signature** — `TestWebhookE2E_RealSignature_CheckoutCompleted`
  proves real signature verification + parsing + fulfilment (no network).

Also unit-tested with a mocked gateway: create/confirm/void/refund, idempotent
convergence of the client+webhook paths, dedup, reconcile, sweep.

### Tilt (manual buttons, `yoga-school` label)

- `yoga-e2e-stripe-go` — the Go full-fulfilment e2e (self-contained).
- `yoga-e2e-stripe-flutter` — the Flutter e2e (deps on `yoga-server`).
- `yoga-server` sources repo-root `.env`, so `STRIPE_KEY_ENC_MASTER` there
  enables the gateway for the dev stack.

Both e2e resources read keys from `.env` (`STRIPE_E2E_SECRET_KEY`,
`STRIPE_TEST_SK`/`STRIPE_TEST_PK`, with `STRIPE_SECRET_KEY`/
`STRIPE_PUBLISHABLE_KEY` fallbacks) and **self-skip** when absent. `.env` is
gitignored — never commit keys.

`POST /dev/configure-stripe` (emulator-gated, like the other `/dev/*` routes)
points studio `s52` at test keys so the Flutter e2e can run.

## Key files

| File | Role |
| --- | --- |
| `server/internal/payments/gateway.go` | Stripe SDK boundary (intents, checkout, refund, webhook verify) |
| `server/internal/store/products.go` | pending→confirm purchase lifecycle, `finalizePendingTx` |
| `server/internal/store/checkout.go` | hosted Checkout + `ConfirmPurchaseBySession` + refund reflection |
| `server/internal/store/stripe_webhook.go` | event dispatch + dedup (one-time + subscription) |
| `server/internal/store/reconcile.go` | janitor reconcile + entitlement sweep |
| `server/internal/store/subscriptions.go` | membership checkout + webhook fulfilment + manage |
| `server/internal/store/stripe_credentials.go` | encrypted per-studio keys + wallet config |
| `app/lib/src/screens/checkout_sheet.dart` | web redirect / mobile PaymentSheet / subscription branch |
| `app/lib/src/api/web_redirect.dart` | redirect shim + test seam |
| `app/lib/main.dart` | `CheckoutReturnHandler` (web `?checkout=…` return) |

## Memberships (subscriptions)

A membership is a recurring Stripe **Subscription** that rolls an `unlimited`
entitlement. It reuses the existing pieces deliberately:

- **Buy surface = hosted Checkout in `mode: subscription`.** No mandate /
  card-entry code on our side — card and (if the studio enables them) SEPA/BACS
  all flow through Checkout. On **web** it's a full-page redirect; on **mobile**
  the native PaymentSheet can't drive a subscription, so the app opens the same
  hosted Checkout in the **system browser** (`url_launcher`, not a WebView) and
  refreshes on resume (`RootShell`'s lifecycle hook). The
  `checkout.session.completed` webhook is authoritative either way.
- **The in-app product is the source of truth.** Saving a `recurring` product
  (`admin_products.go`) mirrors it into the studio's Stripe account as a Product
  + recurring **Price**, stored in `products.stripe_price_id` /
  `stripe_product_id`. Managers never touch the Stripe Dashboard. **Stripe Prices
  are immutable**, so editing a recurring product's price/interval creates a new
  Price, archives the old one, and repoints `stripe_price_id` — existing
  subscribers stay on their old Price (standard grandfathering). When Stripe
  isn't configured yet the product still saves; a re-save once keys exist
  backfills the Price.
- **One Stripe Customer per (studio, student)**, cached in `stripe_customers` and
  reused across subscriptions so re-subscribing keeps saved cards.
- **The webhook is authoritative** (same principle as one-time). The
  entitlement is granted/extended by `invoice.paid`, never by the client return:
  - `checkout.session.completed` (mode=subscription) → link the `sub_…`, mark
    `active`. No grant here, so a single path owns granting.
  - `invoice.paid` → mint the unlimited pass on the first invoice, then extend
    `entitlements.expires_at` to the new period end (+2-day grace) and reset
    `status='active'` on each renewal. Re-activation matters: `SweepEntitlements`
    flips an expired unlimited pass to `expired`, so a renewal landing after
    expiry must revive it.
  - `invoice.payment_failed` → `past_due` **and access is revoked immediately**:
    the linked entitlement is expired *and the member's upcoming bookings on it
    are cancelled* (same as the manager Void path) the moment a renewal fails.
    Stripe still runs dunning retries; a retry that succeeds fires `invoice.paid`
    and reactivates the pass — but does **not** restore the cancelled seats, so
    the member re-books (and a freed seat may already be gone). If dunning gives
    up, `customer.subscription.deleted` finalises the cancellation. (A *clean*
    end-of-period cancellation keeps bookings within the paid period — only a
    payment failure revokes seats.)
  - `customer.subscription.updated` / `.deleted` → reflect status /
    cancel-at-period-end; on delete, end access at the period end.
- **Renewal = extend the entitlement, not mint a new one.** An `unlimited`
  entitlement is gated only by `status='active'` + the `expires_at` window
  (`classes.go` eligibility), so extending the date is the whole renewal.
- **Cancel / resume / update-card.** Student-facing `POST /me/subscriptions/{id}/
  cancel` schedules an end-of-period cancellation (`cancel_at_period_end`);
  `/resume` clears it; managers can cancel on a student's behalf
  (`subscription_cancel`, audited). "Update payment method" uses Stripe's
  **Billing Portal** (`POST /me/billing-portal`) rather than a bespoke
  SetupIntent form — **enable the portal once per studio in the Stripe Dashboard**
  (Settings → Billing → Customer portal).
- **Janitor** expires abandoned pending checkouts (`ReconcileSubscriptions`);
  Stripe's own dunning drives `past_due`→`canceled` via the webhook.

### Stripe Dashboard setup for memberships

On top of the one-time setup, each studio must:
1. Register the four membership webhook events above (in addition to the
   one-time events).
2. Enable the **Customer Billing Portal** (Settings → Billing → Customer portal)
   so "Manage / Update payment" links resolve.

## In-person payments (Stripe Terminal) — planned

Take real card payments at the front desk. Today `card_present` is only a
**manual record** (staff swiped on a separate machine, then logged it) — no
Stripe charge. This replaces that with an actual card-present PaymentIntent so
desk sales settle through Stripe like everything else.

### Recommended shape: server-driven smart reader

A countertop reader (**Stripe Reader S700** or **BBPOS WisePOS E**) connects
itself to the internet over WiFi and is driven **from the existing manager
console** — no Terminal SDK in the Flutter app:

```
Manager console → our backend → Stripe Terminal API → reader → customer taps
                                       │
                          payment_intent.succeeded (webhook)
                                       ▼
                       existing fulfilment mints the entitlement
```

Why this shape over a phone/Tap-to-Pay app (path B, below):

- **No new client SDK.** Server-driven readers are commanded entirely via the
  REST API (`terminal/readers/{id}/process_payment_intent`). The console just
  calls our backend. No `mek_stripe_terminal` plugin, no connection tokens, no
  platform entitlements.
- **Reuses the whole payment spine.** In-person becomes "just another
  PaymentIntent" → the same `payment_intent.succeeded` webhook (see above)
  mints the pass. No new fulfilment path.
- **Reuses the customer.** Attach the buyer's `cus_…` (the one saved-cards +
  subscriptions already create) so a desk sale links to the same student.
- It's the **one** place `payment_method_types: ['card_present']` is correct —
  the documented exception to the "never set payment_method_types" rule.

### Flow

1. **One-time per studio (setup):** create a Terminal **Location**
   (`terminal/locations`), then register the **Reader** to it
   (`terminal/readers`, using the code shown on the device). Cache both ids.
2. **Per sale:**
   a. Backend creates a PaymentIntent: `payment_method_types:['card_present']`,
      `capture_method:'automatic'`, server-computed `amount`, `customer` (to
      link the student), metadata `{purchase_id, studio_id, user_id}` — mirrors
      `CreatePendingPurchase`, just a different method.
   b. Backend calls `process_payment_intent` on the reader → it prompts the
      customer to tap/insert.
   c. Customer pays → PI → `succeeded` → **existing webhook** fulfils.
   d. Walk-away / wrong amount → `cancel_action` on the reader.

### Data model

```
CREATE TABLE terminal_readers (
  studio_id      TEXT NOT NULL REFERENCES studios(id),
  reader_id      TEXT NOT NULL,        -- tmr_…
  location_id    TEXT NOT NULL,        -- tml_…
  label          TEXT,
  created_at     TEXT NOT NULL DEFAULT (...),
  PRIMARY KEY (studio_id, reader_id)
);
```

One row per registered reader (a studio may have several tills). Reuses the
per-studio `studio_stripe_credentials` key and the `stripe_customers` cache —
no other new tables.

### Backend (sketch)

- `payments.Gateway`: `RegisterTerminalReader`, `ProcessPaymentIntentOnReader`,
  `CancelReaderAction`, `CreateLocation` (thin wrappers over stripe-go's
  `terminal/*` packages).
- `IntentParams` gains a `PresentCardOnly bool` (sets `card_present`) — or a
  dedicated `CreateCardPresentIntent`, since it must *not* use
  `AutomaticPaymentMethods`.
- Store: `RegisterReader`, `ListReaders`, `ChargeInPerson(studio,user,product,
  readerID)` → creates the PI, records a `pending` purchase (`payment_method =
  'card_present'`), kicks `process_payment_intent`. Fulfilment is the webhook,
  unchanged.
- Routes (manager-gated): `POST /admin/terminal/readers` (register),
  `GET /admin/terminal/readers`, `POST /admin/terminal/charge`,
  `POST /admin/terminal/cancel`. Audit `terminal_reader_register`,
  `terminal_charge`.

### Manager console UX

- **Settings → Stripe → Readers:** register a reader (enter the on-device code),
  list/label/remove readers.
- **Charge in person:** on the manager's "sell to student" / checkout flow, a
  "Card at desk" button → pick reader → backend charges → console shows
  "Tap card…" → "Paid". MVP status via short polling of the reader/PI; later,
  the Terminal **JS SDK** in the console for live UI if we want richer states.

### Testing

Stripe ships a **simulated reader** (`terminal/readers` with
`registration_code:'simulated-wpe'`) and card-present test PANs, so the whole
flow is buildable/CI-able **without hardware**. Slot it next to the existing
e2e-stripe Tilt resources.

### Phasing

1. ✅ **Backend (built):** `terminal_readers` table; gateway methods
   (`CreateTerminalLocation`, `RegisterTerminalReader`, `CreateCardPresentIntent`,
   `ProcessPaymentIntentOnReader`, `CancelReaderAction`); store
   (`RegisterTerminalReader`, `ListTerminalReaders`, `RemoveTerminalReader`,
   `ChargeInPerson`, `CancelTerminalCharge`) with audit
   (`terminal_reader_register`, `terminal_reader_remove`, `terminal_charge`);
   manager-gated routes under `/admin/terminal/*`. Webhook fulfilment reused
   unchanged. Covered by `store/terminal_test.go` against the fake gateway.
   Still needs a **device test** (real or simulated reader) end-to-end.
2. ✅ **Manager console (built):** `admin_terminal_screen.dart` — register /
   label / remove readers, and a "New in-person sale" flow (pick student +
   product + reader → `ChargeInPerson` → "tap to pay" prompt with cancel).
   Wired into the manager shell as the **Terminal** section. Still needs a
   device test against a real/simulated reader.
3. ☐ **Polish (optional):** live status via Terminal JS SDK; save the desk card
   for later online reuse (`setup_future_usage`, with card-present→online
   constraints); multiple tills; offline mode.

### Open decisions

- Hardware: S700 (newer, pricier) vs WisePOS E.
- One reader per studio vs many (front desk vs satellite tills).
- Capture: automatic (simplest; yoga has no tipping/adjust) vs manual.
- Save desk cards for online reuse? (nice-to-have; extra constraints.)
- Live reader status: server polling (MVP) vs Terminal JS SDK in the console.

### Alternative — path B: Tap to Pay / Bluetooth on the manager's phone

Add the Terminal SDK to the manager app; the manager's iPhone/Android becomes
the reader (Tap to Pay, no hardware) or pairs a Bluetooth reader. Needs a
Flutter Terminal plugin (`mek_stripe_terminal` — `flutter_stripe` has no
Terminal), a `terminal/connection_tokens` endpoint, and platform entitlements.
More moving parts and device-specific; reserve for roaming/pop-up sales rather
than a fixed desk.

## Needs device testing

These flows compile and pass unit/`dart analyze` checks, but involve native
SDKs / OS handoffs that can't be verified headless (web paths are fine). Run
each on a real device or simulator before relying on them:

- **Mobile saved cards — "Add card" + "save card" at checkout.** Uses the
  PaymentSheet with a Customer + **ephemeral key**. The key is minted with the
  API version in `checkout_sheet.dart`'s `_stripeApiVersion` /
  `profile_screen.dart`'s `_walletStripeApiVersion` (`'2020-08-27'`). It must
  match flutter_stripe's pinned SDK version, or the sheet rejects it — if a
  device logs a version-mismatch error, set both constants to the version it
  names.
- **Mobile membership checkout.** Opens the subscription hosted Checkout in the
  system browser via `url_launcher` (`externalApplication`). Confirm the
  browser opens, payment completes, and the membership appears on app resume
  (`RootShell`'s lifecycle hook). `https` launch needs no iOS Info.plist query
  scheme (that's `canLaunchUrl` only); confirm anyway.
- **Stripe Terminal (Phase 1).** Backend is covered by `store/terminal_test.go`
  against the fake gateway, but the live round-trip isn't. Test with Stripe's
  simulated reader (registration code `simulated-wpe`) end-to-end:
  register → `ChargeInPerson` → `payment_intent.succeeded` webhook mints the
  pass.

A runnable, step-by-step Stripe **test-mode** checklist for all of the above
(plus web flows, refunds, async, disputes) lives in
[`payments-device-test.md`](payments-device-test.md).

## Not built yet

- **Web Apple/Google Pay** beyond what Checkout surfaces automatically.
- **Discount edit** (create + archive only; no `UpdateDiscount`).
- **Standalone manager memberships list** (per-student + attention-screen only).
- **Payouts report** (needs Stripe's live Payouts API).
