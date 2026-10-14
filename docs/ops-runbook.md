# Ops runbook

Operational procedures for a production studio deploy. Model: **one studio per
deploy** — Go API on Fly.io (single machine + volume), static web on Firebase
Hosting. See `fly.toml`, `server/Dockerfile`, `scripts/deploy-*.sh`.

## Stand up a new studio

1. **Firebase project** — create one; enable Auth (email/password), Storage, FCM.
   Drop its real `firebase_options.dart` into `app/lib/src/` for the web build.
2. **Fly app + volume + secrets** (see `fly.toml` header for the exact commands):
   app, a `yoga_data` volume, and secrets: `STRIPE_KEY_ENC_MASTER`
   (`openssl rand -hex 32`), `FIREBASE_PROJECT_ID`, `FIREBASE_STORAGE_BUCKET`,
   `CORS_ALLOWED_ORIGINS=https://<web-domain>`, `GOOGLE_APPLICATION_CREDENTIALS`
   (path to the uploaded service-account JSON), and the `LITESTREAM_*` backup
   creds (below).
3. **Deploy the API:** `make deploy-api`.
4. **Provision the studio + owner** (once): on the machine, run
   `/app/server -migrate -bootstrap-studio -db /data/prod.db
   -studio-name "<Name>" -studio-tz "<IANA tz>" -studio-currency "<ISO>"
   -owner-email "<owner@…>"` (e.g. via `fly ssh console`). No demo data.
5. **Deploy the web app:** `API_BASE_URL=https://<app>.fly.dev/api/v1
   FIREBASE_PROJECT=<proj> make deploy-web`, then point the domain at Firebase
   Hosting.
6. The owner signs in with the email from step 4 (first sign-in backfills their
   `firebase_uid`); they create class types, rooms, products, and enter live
   Stripe keys from the manager UI (see `go-live-stripe.md`).

## Backups (Litestream)

Continuous replication of `/data/prod.db` to object storage; 30-day retention
(`server/litestream.yml`). Enabled whenever `LITESTREAM_BUCKET` is set.

Required secrets (S3 or any S3-compatible store — Tigris/R2/B2):
`LITESTREAM_ACCESS_KEY_ID`, `LITESTREAM_SECRET_ACCESS_KEY`, `LITESTREAM_BUCKET`,
`LITESTREAM_ENDPOINT`, `LITESTREAM_REGION`.

- **Verify replication:** `fly ssh console -C "litestream snapshots -config
  /etc/litestream.yml /data/prod.db"` — expect recent snapshots.
- **Restore is automatic** on a fresh/empty volume: the entrypoint runs
  `litestream restore -if-db-not-exists -if-replica-exists` before migrating.
- **Manual restore** (e.g. to a point in time): stop the app, then
  `litestream restore -config /etc/litestream.yml -o /data/prod.db
  [-timestamp <RFC3339>] /data/prod.db` and restart.
- **DR drill (do once before launch):** deploy to a scratch app, write some
  data, destroy the volume, redeploy, confirm the data came back.

## Routine

- **Logs / health:** `fly logs`; `/healthz` returns 200 when the DB is reachable
  (Fly health check pings it every 15s).
- **Deploy a code change:** `make deploy-api` (API) / `make deploy-web` (web).
  Single machine → brief downtime on API deploy; acceptable at this scale.
- **GDPR requests:** export/erase from the manager student-detail screen
  (`docs/data-retention.md`); erased data leaves backups by 30-day rotation.
- **Rotating `STRIPE_KEY_ENC_MASTER`:** not supported in place (it unseals the
  stored per-studio keys). To rotate, re-enter the studio's Stripe keys in the
  UI under a new master. Treat the master as long-lived; store it in Fly secrets.

## Known limitations

- Single machine (SQLite single-writer) — no HA; a machine restart is a few
  seconds of downtime. Fine for one studio; revisit (Postgres) only if you move
  to multi-tenant.
- Online paid **series** enrolments have no card path yet (the dev-payment gate
  blocks non-card in prod) — see `go-live-stripe.md`.
