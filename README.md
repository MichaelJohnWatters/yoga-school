# yoga-school

## Before shipping to prod

A running list of dev-only shortcuts + things that need to be reconfigured
before this stack runs against real users / real money. Tick them off as
they're addressed; add new entries as they accumulate.

### Web caching

- [ ] `app/web/flutter_bootstrap.js` is a hand-written replacement for
  Flutter's default bootstrap. It tears down any leftover service worker
  + CacheStorage on every page load and loads Flutter WITHOUT registering
  a new SW. That keeps dev rebuilds visible without "Empty cache and hard
  reload". For prod, restore the default bootstrap (delete this file and
  let `flutter build web` regenerate it) so the PWA offline / atomic
  bundle swap behaviour comes back, paired with proper versioned-filename
  cache headers on the CDN.

### Server

- [ ] `POST /dev/reset-test-state` and `POST /dev/fill-class` (in
  `server/internal/api/api.go`) are unauthenticated, gated only by the
  presence of `FIREBASE_AUTH_EMULATOR_HOST`. They 404 in prod-shaped
  configs but the routes still register. Either drop the registrations
  behind a build tag or assert the env var is unset on boot in prod.
- [ ] `cmd/server -seed` runs `Store.SeedDev` which inserts the demo
  studio + Maya + community students. Never run with `-seed` against a
  real DB. Confirm prod startup scripts pass `-migrate` only (or neither).
- [ ] `STRIPE_KEY_ENC_MASTER` env var must be set so studios can save
  Stripe secret keys. The server refuses to boot if any studio already
  has encrypted keys and the master is unset, but it'll start fine with
  a fresh empty DB — wire the env var into prod config now.

### Firebase

- [ ] `app/lib/main.dart` calls `useAuthEmulator('localhost', 9099)`
  inside `if (kDebugMode)`. Release builds skip that block — verify in
  the first prod build that auth resolves against the real Firebase
  project, not silently against an emulator on the prod host.
- [ ] `scripts/seed-firebase-users.sh` is a dev convenience that creates
  the demo accounts in the local Auth emulator. Never run against prod.

### Stripe (deferred — currently dev_stub)

- [ ] `server/internal/store/products.go` has a long `STRIPE TODO` block
  at the top — full checklist for swapping `dev_stub` payment for real
  Stripe PaymentIntents. Includes the per-studio key resolution pattern
  (don't stash a process-global `stripe.Key` — multi-tenant), the
  `payment_intent.succeeded` webhook route shape, and the products UI
  field for `stripe_price_id`. Grep for `STRIPE TODO` to find every
  inline marker.
- [ ] FCM dispatch falls back to log-only when the auth emulator is
  active (`cmd/server/main.go:65-78`). In prod the messaging client
  needs real Firebase credentials.

### Schema / data

- [ ] Schema is SQLite (`server/db/schema.sql`). The spec was written
  against Postgres — translation notes are at the top of schema.sql.
  Re-evaluate whether SQLite is fine for prod load (probably yes for a
  single-studio deploy, no for multi-tenant scale).
- [ ] The two-week seed schedule (`server/internal/store/seed.go`
  `seedSchedule`) generates `cls_wk0_*` and `cls_wk1_*` IDs for the
  current and next week. Pure dev convenience; not relevant to prod.

### Tests

- [ ] Integration tests in `app/integration_test/` rely on `/dev/*`
  endpoints + the seed personas. They're a useful CI smoke suite
  against a freshly-seeded dev stack — point them at a per-PR ephemeral
  environment, not prod.
