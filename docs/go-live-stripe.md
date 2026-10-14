# Stripe go-live (per studio)

Each studio brings its **own** Stripe account — keys are stored per-studio,
AES-GCM encrypted (not Stripe Connect). Do this once per customer, after the API
is deployed (so the webhook URL exists). See `docs/payments.md` for the full
architecture.

## 1. Stripe account
- [ ] Complete Stripe **business verification** (the studio's own account).
- [ ] Create a **restricted key** (`rk_…`) with write access to Checkout,
      PaymentIntents, Refunds, Customers, Invoices, Subscriptions — preferred
      over a full `sk_…`.

## 2. Enter keys in the app
Manager → Settings → Stripe:
- [ ] Publishable key (`pk_live_…`), secret/restricted key (`rk_live_…`),
      webhook signing secret (`whsec_…`, from step 3), merchant display name +
      country. Keys are encrypted at rest with `STRIPE_KEY_ENC_MASTER`.

## 3. Register the live webhook
In the Stripe Dashboard → Developers → Webhooks, add an endpoint:

```
https://<fly-app>.fly.dev/stripe/webhook/<studioID>
```

(`<studioID>` is printed by `-bootstrap-studio`; it's the studio row id.) Select
exactly these events — the handler is authoritative for fulfilment:

- `checkout.session.completed`
- `checkout.session.async_payment_succeeded`
- `checkout.session.async_payment_failed`
- `checkout.session.expired`
- `payment_intent.succeeded`
- `payment_intent.payment_failed`
- `payment_intent.canceled`
- `charge.refunded`
- `charge.dispute.created`, `charge.dispute.updated`, `charge.dispute.closed`
- `invoice.paid`
- `invoice.payment_failed`
- `customer.subscription.updated`
- `customer.subscription.deleted`

Copy the endpoint's signing secret into step 2.

## 4. Memberships
- [ ] Enable the **Customer Billing Portal** (Settings → Billing → Customer
      portal) so members can manage/cancel — the app links to it.

## 5. Validate before flipping real money on
Run the **web** sections of `docs/payments-device-test.md` against this deployed
instance in Stripe **test mode** first (test keys + a test webhook endpoint):
one-time pass checkout, membership subscribe (`invoice.paid` → pass + purchase
row), a refund, and a dispute reflection. Then switch to live keys.

## Known limitation — online paid series
The dev-payment gate rejects any non-`card` method in production, and **online
paid series enrolments have no card path yet** (`docs/payments.md`). Go/no-go:
- **OK at launch** if series are sold in person / by manager grant (cash/comp),
  or you only sell drop-ins, passes, and memberships online.
- **Otherwise** this is a small follow-on (wire series enrolment through hosted
  Checkout like one-time passes) before advertising online series sales.
