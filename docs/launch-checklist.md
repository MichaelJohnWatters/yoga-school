# Launch checklist — stand up a paying studio

The repeatable procedure to take a new customer live. Model: **web-first, one
studio per deploy** (Go API on Fly.io + SQLite volume, web on Firebase Hosting).
Ordered so nothing takes money or stores customer data before it's safe.

Legend: **[code]** already in the repo · **[ops]** you run once per studio.

## 0. Prerequisites (once)
- [ ] **[ops]** Merge the security PR (#7) into `main`.
- [ ] **[code]** CI runs `go vet`/`go test`/`govulncheck` + `dart analyze`/
      `flutter test` on every push (`.github/workflows/ci.yml`).

## 1. External accounts (per studio)
- [ ] **[ops]** Firebase project: enable Auth (email/password), Storage, FCM.
      Put its real `firebase_options.dart` into `app/lib/src/`.
- [ ] **[ops]** Stripe account + business verification (the studio's own).
- [ ] **[ops]** Object storage bucket for backups (S3-compatible).
- [ ] **[ops]** A domain for the web app.

## 2. Deploy the API (Fly.io)
- [ ] **[ops]** `fly apps create`, `fly volumes create yoga_data`, and
      `fly secrets set` per the `fly.toml` header: `STRIPE_KEY_ENC_MASTER`,
      `FIREBASE_PROJECT_ID`, `FIREBASE_STORAGE_BUCKET`, `CORS_ALLOWED_ORIGINS`,
      `GOOGLE_APPLICATION_CREDENTIALS`, `APP_ENV=production`, and `LITESTREAM_*`.
- [ ] **[code]** Build the image locally first to confirm it compiles:
      `docker build -f server/Dockerfile .` (not verifiable in the dev sandbox —
      do it here).
- [ ] **[ops]** `make deploy-api`. Confirm `/healthz` is 200. Boot will **refuse**
      if `APP_ENV=production` and a dev gate is set or CORS is empty (by design).

## 3. Provision the studio (once, clean — no demo data)
- [ ] **[ops]** `fly ssh console` → `/app/server -migrate -bootstrap-studio
      -db /data/prod.db -studio-name "<Name>" -studio-tz "<IANA>"
      -studio-currency "<ISO>" -owner-email "<owner@…>"`. Note the printed
      `studioID`.

## 4. Deploy the web app (Firebase Hosting)
- [ ] **[ops]** `API_BASE_URL=https://<app>.fly.dev/api/v1 FIREBASE_PROJECT=<proj>
      make deploy-web`. Point the domain at Hosting; set `CORS_ALLOWED_ORIGINS`
      to it.

## 5. Backups (before any real data)
- [ ] **[ops]** Confirm Litestream is replicating (`ops-runbook.md`), then run the
      **DR drill**: destroy the scratch volume and confirm restore works.

## 6. Stripe go-live (`docs/go-live-stripe.md`)
- [ ] **[ops]** Validate the web flows in **test mode** first (one-time pass,
      membership subscribe, refund, dispute reflection — `payments-device-test.md`).
- [ ] **[ops]** Enter live restricted key + publishable key; register the live
      webhook at `/stripe/webhook/<studioID>` with the documented events; enable
      the Billing Portal.

## 7. Legal (`docs/legal/README.md`)
- [ ] **[ops]** Solicitor-review `privacy.html` + `terms.html`; fill every
      `[bracketed]` field; name a data-protection contact in `data-retention.md`.

## 8. Pre-launch smoke (real Firebase, deployed instance)
- [ ] **[ops]** Sign-up → `email_verified` gate → verify link → resume →
      signed-in (the gate was never exercised against real Firebase — see the
      verification-screen note in the security PR).
- [ ] **[ops]** Owner signs in (the `-bootstrap-studio` email), configures class
      types/rooms/products, and a student completes: book a class, buy a pass
      (live-mode test card), subscribe to a membership, request a refund, and
      the owner runs a GDPR export + erase.

## Deliberately out of scope
Multi-tenant-in-one-deploy, self-serve studio signup, native mobile apps,
Postgres, Stripe Terminal / saved-card device testing — deferred until after the
first web customers (`docs/roadmap.md` "big rewrites").
