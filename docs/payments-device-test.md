# Payments — Stripe test-mode device checklist

A runnable, end-to-end pass over every payment flow against **Stripe test mode**.
Most of this is verified by unit tests against the fake gateway; this checklist
is what those *can't* prove — the real Stripe round-trip, the webhook payloads,
and the native SDK / OS handoffs. Work top to bottom; later sections assume the
setup from §0.

Conventions: ✅ = expected result. DB checks use the dev SQLite at
`server/dev.db` — run them with `sqlite3 server/dev.db "…"`.

> **Already automated** (no manual run needed): the membership money path —
> §6.4 PaymentIntent capture, §6.5 invoice→purchase recording, and §8's refund
> round-trip — is covered by `TestStripeRealAPI_MembershipE2E`. It hits live
> Stripe test mode server-side (no browser/reader) and replays Stripe's real
> `invoice.paid` event through our handler. Run it with test keys in `.env`:
> `cd server && go test -tags stripe_e2e -run MembershipE2E ./internal/store/`.
> The manual §6–§8 steps below remain useful as a UI sanity check, but if that
> test passes, the capture/recording/refund are proven.

---

## 0. Setup (once)

1. **Fresh DB with the latest schema** (this batch added `products.duplicate_policy`
   and `subscriptions.last_payment_intent_id`):
   ```
   make reset        # or: rm -f server/dev.db* && re-run bootstrap
   ```
   Then start the stack (Tilt). Confirm the columns exist:
   ```
   sqlite3 server/dev.db "PRAGMA table_info(subscriptions);" | grep last_payment_intent_id
   sqlite3 server/dev.db "PRAGMA table_info(products);"      | grep duplicate_policy
   ```
2. **Stripe test keys + webhook forwarding.** Tilt already runs this as the
   `yoga-stripe-webhook` resource — it forwards **straight to the Go server on
   `:8080`** (not through Caddy, which routes `/stripe/*` to the Flutter app). If
   running it by hand:
   ```
   stripe listen --forward-to localhost:8080/stripe/webhook/s52
   ```
   One-time: `stripe login`, then put `stripe listen --print-secret` (`whsec_…`)
   into `.env` as `STRIPE_WEBHOOK_SECRET` so `configure-stripe-dev.sh` wires it
   onto the studio (or set it in manager Settings → Stripe). `s52` is the dev studio.
3. **Sign in** as a manager (`asha@studio52.dev` etc.) and as a student in a second
   browser/profile for the buy flows.
4. **Test cards:** `4242 4242 4242 4242` (succeeds), `4000 0000 0000 9995`
   (declined), `4000 0000 0000 3220` (3DS/SCA challenge), any future expiry + any CVC.
   Card-present (Terminal): the simulated reader auto-approves.
5. Keep the `stripe listen` terminal visible — every fulfilment below should print
   the matching event there.

A "purchase" check that recurs below:
```
sqlite3 server/dev.db "SELECT status, payment_method, amount_minor, stripe_payment_id, resulting_entitlement_id FROM purchases ORDER BY created_at DESC LIMIT 5;"
```

---

## 1. One-time pass — WEB checkout

1. Student → Buy → pick a credit pack → hosted Checkout opens → pay with `4242`.
2. Returns to the app's full-screen success page.

✅ `stripe listen` shows `checkout.session.completed`.
✅ purchase row `status=completed`, `stripe_payment_id` is a `pi_…` (swapped from `cs_…`).
✅ an `entitlements` row minted; Wallet shows the pass.
✅ audit row `purchase` (`sqlite3 server/dev.db "SELECT action FROM audit_log ORDER BY id DESC LIMIT 5;"`).

**Abandon variant:** start checkout, close the tab. After Stripe expires it (or
`stripe trigger checkout.session.expired`), ✅ the pending row flips to `voided`.

## 2. One-time pass — NATIVE PaymentSheet (device/simulator)

1. Student app on device → Buy → pack → PaymentSheet appears → pay `4242`.
2. ✅ `payment_intent.succeeded`; purchase `completed`; pass in Wallet.
3. Repeat with `4000…3220` → ✅ 3DS challenge sheet shows, then completes.
4. Repeat with `4000…9995` → ✅ declined, no pass, purchase stays pending/void.

## 3. Duplicate-pass policy (per product)

In the product editor set **Repeat purchases** and re-test as the student:
- **prevent:** buy once, then the Buy card shows "Already owned" + dims; tapping
  shows the snackbar; the API returns 409 `duplicate_pass`. ✅
- **topup:** buy a 5-pack twice → ✅ **one** entitlement with credits merged
  (`SELECT credits_total, credits_remaining FROM entitlements …` shows 10/10).
- **allow:** buy twice → ✅ two separate entitlement rows.

## 4. Series / enrollment purchase

1. Manager creates a series (Series → New). Student → Enrollments → enroll → pay
   (web Checkout or native sheet).
   ✅ enrolled into **every** future session: `enrollment_bookings` row + one
   `bookings` row per session; purchase `completed`; audit `series_join`.
2. **Capacity race:** set a series capacity to 1, fill it, then have a second
   student pay. ✅ at fulfilment they're **auto-refunded** (`stripe listen` shows a
   refund), purchase `refunded`, a "course full" notification, audit
   `series_full_refund`.

## 5. Manager enroll-a-student (no Stripe)

Series roster → "Enroll a student" → pick student → PAID VIA comp/cash → Enroll.
✅ entitlement + session bookings; purchase `completed` with `actor_role=manager`,
chosen `payment_method`; audit `series_manager_enroll`.

## 6. Membership — subscribe (WEB)

1. Student → Buy → membership → hosted Checkout (subscription mode) → pay `4242`.
2. ✅ `checkout.session.completed` (links sub) **then** `invoice.paid` (grants).
3. ✅ unlimited entitlement minted; Buy card now shows "Current plan".
4. **NEW — invoice recorded as a purchase + PI captured** (this is the part with
   no headless coverage):
   ```
   sqlite3 server/dev.db "SELECT status, amount_minor, stripe_payment_id FROM purchases WHERE product_id IN (SELECT id FROM products WHERE billing_type='recurring');"
   sqlite3 server/dev.db "SELECT status, last_payment_intent_id FROM subscriptions ORDER BY created_at DESC LIMIT 1;"
   ```
   ✅ a `completed`, `card` purchase row whose `stripe_payment_id` == the
   subscription's `last_payment_intent_id` (a `pi_…`). **If `last_payment_intent_id`
   is null, the invoice-payment capture didn't parse — note the actual invoice
   payload from `stripe listen --print-json` so we can fix the field path.**
5. ✅ membership income now appears in Reports → Revenue.

## 7. Membership — renewal (Stripe test clock)

Renewals are what prove capture works across cycles. Easiest path:
```
stripe trigger invoice.payment_succeeded     # or drive a test clock forward
```
…but the cleanest is a **test clock**: create a clock, a customer on it, subscribe,
advance the clock one billing period. ✅ a second `invoice.paid`, a **second**
purchase row with a new `pi_…`, entitlement expiry extended, both
`last_payment_intent_id` and the new purchase agree.

## 8. Membership management (manager → student page)

Open the student; the membership pass row shows "Membership · renews <date>" and a
**Cancel** button. Test each option:
- **Cancel at renewal** → ✅ subscription stays `active`, `cancel_at_period_end=1`;
  row now reads "cancels <date>" (accent); audit `subscription_cancel`. The pass
  stays; future bookings kept.
- **Resume** (now that a cancel is scheduled) → ✅ `cancel_at_period_end=0`; audit
  `subscription_resume`.
- **Cancel now** → ✅ subscription `canceled`, entitlement `expired`, the student's
  **future** booked classes on this pass flip to `cancelled` (book one first to
  verify); audit `subscription_cancel` (`immediate=true`).
- **Refund & cancel** → ✅ a Stripe refund against the captured PI (`stripe listen`
  shows `charge.refunded`), subscription canceled, pass expired, future seats
  released, audit `subscription_refund`; the recorded invoice purchase reflects the
  refund (`SELECT status, refund_amount_minor FROM purchases WHERE stripe_payment_id = '<pi>'`).
  - If the sub has **no** captured PI (older sub), ✅ a 409 "refund via the Stripe
    dashboard" message instead.

## 9. Duplicate membership guard

With an active membership, try to subscribe again to the **same** product → ✅ Buy
card shows "Current plan"; the API returns 409 `already_subscribed`. A *pending*
(abandoned) sub does **not** block a retry.

## 10. Money-only purchase refund

Student page → Purchase history → **Refund** on a completed sale → full or partial
amount → confirm. ✅ Stripe refund issued; row shows "Refunded"; audit
`purchase_refund`. (This does **not** void the pass — verify the entitlement is
still active.)

## 11. Dashboard-initiated refund reflection

Refund a charge directly in the Stripe **Dashboard** (or `stripe trigger
charge.refunded`). ✅ `ReflectStripeRefund` updates the matching purchase's
`refund_amount_minor` — including **membership** invoices now that they have
purchase rows (pick a membership `pi_` and confirm it's found, not ignored).

## 12. Chargebacks / disputes

```
stripe trigger charge.dispute.created
```
✅ a row appears on Manager → Payments (needing attention); the pass is **not**
auto-revoked. Trigger `charge.dispute.closed` → ✅ it clears.

## 13. Async (delayed-settlement) payment

Only relevant if you enable a non-card method (e.g. a delayed bank debit). Simulate:
```
stripe trigger checkout.session.async_payment_succeeded
```
✅ the matching pending purchase fulfils (this path had no handler before). The
failed variant (`…async_payment_failed`) voids it.

## 14. Stale-checkout janitor sweep

Create a web-checkout pending row, then make it look old and run a tick:
```
sqlite3 server/dev.db "UPDATE purchases SET created_at='2020-01-01T00:00:00Z' WHERE status='pending' AND stripe_payment_id LIKE 'cs_%';"
```
Wait for the janitor (or restart the server). ✅ paid sessions get confirmed,
unpaid ones get `voided` — nothing lingers `pending`.

## 15. Saved cards (device)

Wallet → Add card → SetupIntent/PaymentSheet → save `4242`. ✅ card lists; delete
works; a subsequent native purchase can use it. **Watch for an API-version
mismatch** — if the sheet errors, set `_stripeApiVersion` /
`_walletStripeApiVersion` to the version named in the error (see payments.md).

## 16. Stripe Terminal (simulated reader)

Manager → Terminal → Register reader (`simulated-wpe`) → New in-person sale → pick a
pass → send to reader. ✅ the simulated reader auto-approves;
`payment_intent.succeeded` (card_present) mints the pass; purchase
`payment_method=card_present`; audit `terminal_charge`. Test Cancel mid-charge too.

---

## Sign-off

Tick each section. The ones with **no** prior headless coverage and therefore the
highest priority: **§6/§7 (membership invoice→purchase + PI capture)**, **§8
(refund & cancel against the real PI)**, **§11 (membership refund reflection)**,
§13 (async), §15 (saved cards), §16 (Terminal). If §6.4 shows a null
`last_payment_intent_id`, capture the raw `invoice.paid` JSON — that's the one
thing the SDK field path can't be confirmed for without a live event.
