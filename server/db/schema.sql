-- SQLite schema for Studio 52 yoga-school backend.
-- Translation from the Postgres spec in yoga-school-spec.md:
--   gen_random_uuid() → app-generated UUIDs (Go side)
--   JSONB            → TEXT (validated/parsed in Go)
--   TIMESTAMPTZ      → TEXT, ISO 8601 UTC
--   INT[]            → TEXT, JSON array
--   BOOLEAN          → INTEGER (0/1)
--   DEFAULT now()    → DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
--
-- Only the tables needed for the current vertical slice are defined.
-- Add the rest as endpoints come online.

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS studios (
  id                        TEXT PRIMARY KEY,
  name                      TEXT NOT NULL,
  timezone                  TEXT NOT NULL DEFAULT 'Europe/London',
  currency                  TEXT NOT NULL DEFAULT 'GBP',
  free_cancel_cutoff_hours  INTEGER NOT NULL DEFAULT 12,
  allow_student_plus_one    INTEGER NOT NULL DEFAULT 0,
  -- Light slot: the theme served when the user's pref is "light" or
  -- "system" + the device is in light mode. Required (joined, not LEFT
  -- JOIN'd) — every studio must have a light theme so the app always
  -- has something to render.
  active_theme_id           TEXT,
  -- Dark slot: served when the user picks "dark" or system says dark.
  -- Optional; if null, students who pick dark fall back to the light
  -- slot so the studio is never "broken in dark mode".
  active_dark_theme_id      TEXT,
  welcome_message           TEXT,
  buy_layout                TEXT NOT NULL DEFAULT 'grouped'
                              CHECK (buy_layout IN ('grid','list','grouped')),
  created_at                TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS themes (
  id                TEXT PRIMARY KEY,
  studio_id         TEXT NOT NULL REFERENCES studios(id),
  name              TEXT NOT NULL,
  is_preset         INTEGER NOT NULL DEFAULT 0,
  mode              TEXT NOT NULL DEFAULT 'light' CHECK (mode IN ('light','dark')),
  tokens            TEXT NOT NULL,
  splash_image_url  TEXT,
  activate_on       TEXT,
  created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  UNIQUE (studio_id, name)
);

CREATE TABLE IF NOT EXISTS users (
  id                  TEXT PRIMARY KEY,
  studio_id           TEXT NOT NULL REFERENCES studios(id),
  firebase_uid        TEXT UNIQUE,
  role                TEXT NOT NULL CHECK (role IN ('student','instructor','manager','owner')),
  email               TEXT NOT NULL,
  full_name           TEXT NOT NULL,
  photo_url           TEXT,
  -- Per-class pay rate in minor currency units (e.g. pence). NULL falls
  -- back to the studio-wide default in admin_reports.go.
  instructor_pay_rate_minor INTEGER,
  -- Theme mode preference. "system" follows the OS / browser brightness;
  -- "light" / "dark" pin the studio's matching active slot regardless.
  -- Defaults to "light" rather than "system" so a new account doesn't
  -- suddenly render in a half-finished dark slot before the studio has
  -- one configured — the manager opts in to system/dark from Settings or
  -- Profile when ready.
  theme_mode_pref     TEXT NOT NULL DEFAULT 'light'
                        CHECK (theme_mode_pref IN ('light','dark','system')),
  -- Set when the account has been erased under UK GDPR Art. 17 (right to
  -- erasure). The row is NOT deleted — financial (HMRC 6yr) and audit
  -- records reference user_id and must survive. Instead the PII columns are
  -- tombstoned (email → erased+<id>@deleted.invalid, full_name → '[erased]',
  -- photo_url/firebase_uid → NULL) and erased_at is stamped. Every read that
  -- surfaces a person filters `erased_at IS NULL`; with firebase_uid cleared
  -- the account can also no longer authenticate. See EraseUser / EXPORT and
  -- docs/data-retention.md.
  erased_at           TEXT,
  created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  UNIQUE (studio_id, email)
);

-- ===== Classes + bookings ================================================

CREATE TABLE IF NOT EXISTS class_types (
  id          TEXT PRIMARY KEY,
  studio_id   TEXT NOT NULL REFERENCES studios(id),
  name        TEXT NOT NULL,
  discipline  TEXT
);

CREATE TABLE IF NOT EXISTS rooms (
  id          TEXT PRIMARY KEY,
  studio_id   TEXT NOT NULL REFERENCES studios(id),
  name        TEXT NOT NULL,
  -- Optional accent colour the UI tints class cards with. NULL means
  -- "use the theme default" (no tint, plain surface). Stored as a
  -- lowercase #rrggbb string; the API layer validates the format on
  -- create / update.
  color       TEXT
);

-- ===== Recurrence rules ==================================================
-- A rule captures the shape of a recurring class. Concrete sessions are
-- materialized into `classes` and back-link via recurrence_rule_id. Edits
-- come in three scopes: `this` detaches one class, `future` splits the rule
-- (old one ends, new one starts), `all` updates every non-detached instance
-- in place.

CREATE TABLE IF NOT EXISTS recurrence_rules (
  id             TEXT PRIMARY KEY,
  studio_id      TEXT NOT NULL REFERENCES studios(id),
  -- Snapshotted class shape — used to materialize / regenerate instances.
  class_type_id  TEXT NOT NULL REFERENCES class_types(id),
  instructor_id  TEXT NOT NULL REFERENCES users(id),
  room_id        TEXT NOT NULL REFERENCES rooms(id),
  title          TEXT,
  start_hour     INTEGER NOT NULL,
  start_minute   INTEGER NOT NULL,
  duration_mins  INTEGER NOT NULL,
  capacity       INTEGER NOT NULL,
  -- Recurrence shape.
  frequency      TEXT NOT NULL CHECK (frequency IN ('daily','weekly','monthly')),
  interval       INTEGER NOT NULL DEFAULT 1,
  weekdays       TEXT NOT NULL DEFAULT '[]',     -- JSON array of int 0..6 (Mon=0)
  starts_on      TEXT NOT NULL,                  -- YYYY-MM-DD inclusive
  ends_on        TEXT,                            -- YYYY-MM-DD inclusive, NULL = open
  occurrences    INTEGER,                         -- alternative end-condition
  -- Lifecycle.
  parent_rule_id TEXT REFERENCES recurrence_rules(id),  -- set when a future-scope edit split off this rule
  status         TEXT NOT NULL DEFAULT 'active'
                   CHECK (status IN ('active','superseded')),
  created_by     TEXT NOT NULL REFERENCES users(id),
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_recurrence_studio ON recurrence_rules(studio_id, status);

CREATE TABLE IF NOT EXISTS classes (
  id                TEXT PRIMARY KEY,
  studio_id         TEXT NOT NULL REFERENCES studios(id),
  class_type_id     TEXT NOT NULL REFERENCES class_types(id),
  instructor_id     TEXT REFERENCES users(id),
  room_id           TEXT REFERENCES rooms(id),
  enrollment_id     TEXT REFERENCES enrollments(id),
  template_batch_id TEXT REFERENCES class_templates(id),
  recurrence_rule_id TEXT REFERENCES recurrence_rules(id),
  -- Set when this instance has been edited away from its rule's shape
  -- (scope=this). Future "edit future / all" passes skip detached rows.
  is_detached       INTEGER NOT NULL DEFAULT 0,
  title             TEXT,
  starts_at         TEXT NOT NULL,
  ends_at           TEXT NOT NULL,
  capacity          INTEGER NOT NULL,
  status            TEXT NOT NULL DEFAULT 'scheduled'
                      CHECK (status IN ('scheduled','cancelled')),
  created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- ===== Class templates ==================================================
-- A template captures the "recipe" for a recurring class. Generating from a
-- template creates N concrete `classes` rows linked back via
-- template_batch_id; the whole batch can be undone in one call.

CREATE TABLE IF NOT EXISTS class_templates (
  id            TEXT PRIMARY KEY,
  studio_id     TEXT NOT NULL REFERENCES studios(id),
  created_by    TEXT NOT NULL REFERENCES users(id),
  title         TEXT NOT NULL,
  class_type_id TEXT NOT NULL REFERENCES class_types(id),
  instructor_id TEXT NOT NULL REFERENCES users(id),
  room_id       TEXT NOT NULL REFERENCES rooms(id),
  weekday       INTEGER NOT NULL,             -- 0=Mon, ..., 6=Sun
  start_hour    INTEGER NOT NULL,
  start_minute  INTEGER NOT NULL,
  duration_mins INTEGER NOT NULL,
  capacity      INTEGER NOT NULL,
  weeks         INTEGER NOT NULL,
  starts_on     TEXT NOT NULL,                -- first session date (YYYY-MM-DD)
  status        TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','reverted')),
  created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_class_templates_studio ON class_templates(studio_id, created_at);
CREATE INDEX IF NOT EXISTS idx_classes_studio_time ON classes(studio_id, starts_at);
CREATE INDEX IF NOT EXISTS idx_classes_enrollment ON classes(enrollment_id);

-- ===== Enrollments (buyable multi-session series) =======================

CREATE TABLE IF NOT EXISTS enrollments (
  id            TEXT PRIMARY KEY,
  studio_id     TEXT NOT NULL REFERENCES studios(id),
  title         TEXT NOT NULL,
  description   TEXT,
  product_id    TEXT REFERENCES products(id),
  session_count INTEGER NOT NULL,
  capacity      INTEGER NOT NULL,
  created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS enrollment_bookings (
  id             TEXT PRIMARY KEY,
  enrollment_id  TEXT NOT NULL REFERENCES enrollments(id),
  user_id        TEXT NOT NULL REFERENCES users(id),
  entitlement_id TEXT NOT NULL REFERENCES entitlements(id),
  status         TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','cancelled')),
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  UNIQUE (enrollment_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_enroll_book_user ON enrollment_bookings(user_id, status);

CREATE TABLE IF NOT EXISTS entitlements (
  id                  TEXT PRIMARY KEY,
  studio_id           TEXT NOT NULL REFERENCES studios(id),
  user_id             TEXT NOT NULL REFERENCES users(id),
  source_product_id   TEXT,
  pass_kind           TEXT NOT NULL CHECK (pass_kind IN ('credit','unlimited')),
  label               TEXT NOT NULL,
  credits_total       INTEGER,
  credits_remaining   INTEGER,
  expires_at          TEXT,
  status              TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','expired','depleted','voided')),
  created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_entitlements_user ON entitlements(user_id, status);

-- Empty junction = "all class types" (interpreted in the eligibility query).
CREATE TABLE IF NOT EXISTS entitlement_class_types (
  entitlement_id TEXT NOT NULL REFERENCES entitlements(id),
  class_type_id  TEXT NOT NULL REFERENCES class_types(id),
  PRIMARY KEY (entitlement_id, class_type_id)
);

CREATE TABLE IF NOT EXISTS bookings (
  id                  TEXT PRIMARY KEY,
  studio_id           TEXT NOT NULL REFERENCES studios(id),
  class_id            TEXT NOT NULL REFERENCES classes(id),
  user_id             TEXT NOT NULL REFERENCES users(id),
  entitlement_id      TEXT NOT NULL REFERENCES entitlements(id),
  is_plus_one         INTEGER NOT NULL DEFAULT 0,
  -- Friend's name when is_plus_one=1, NULL otherwise. The API enforces
  -- presence on create; the column is nullable so primary booking rows
  -- (and any pre-migration +1 rows) don't need a value.
  plus_one_name       TEXT,
  parent_booking_id   TEXT REFERENCES bookings(id),
  booked_by_role      TEXT NOT NULL CHECK (booked_by_role IN ('student','manager')),
  cancel_cutoff_hours INTEGER NOT NULL,
  status              TEXT NOT NULL DEFAULT 'booked'
                        CHECK (status IN ('booked','cancelled','attended','no_show')),
  attendance_marked_by TEXT CHECK (attendance_marked_by IN ('manual','scan')),
  -- Single-use admission token. Minted on booking creation, consumed (set
  -- NULL) on successful scan. UNIQUE so the scan endpoint can resolve a
  -- token → exactly one booking without needing the class_id from the
  -- caller.
  checkin_token       TEXT UNIQUE,
  -- Settled business outcome once the booking leaves the 'booked' state.
  -- NULL while still active or attended. Drives reports + the roster's
  -- late-cancel grouping (no julianday math at read time).
  outcome             TEXT CHECK (outcome IN
                        ('cancelled_free','cancelled_late_burned',
                         'no_show_burned','class_cancelled_returned')),
  created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  cancelled_at        TEXT
);
CREATE INDEX IF NOT EXISTS idx_bookings_class ON bookings(class_id, status);
CREATE INDEX IF NOT EXISTS idx_bookings_user ON bookings(user_id, status);
-- "At most one active seat per (class, user, is_plus_one)" — partial so
-- the constraint only counts live bookings. Without the WHERE, a user
-- who cancels then tries to re-book the same class would collide with
-- their own cancelled row. Mirrors uq_waitlist_active_per_user.
CREATE UNIQUE INDEX IF NOT EXISTS uq_bookings_active_seat
  ON bookings (class_id, user_id, is_plus_one)
  WHERE status = 'booked';

-- ===== Products + purchases =============================================

CREATE TABLE IF NOT EXISTS products (
  id            TEXT PRIMARY KEY,
  studio_id     TEXT NOT NULL REFERENCES studios(id),
  name          TEXT NOT NULL,
  description   TEXT,
  price_minor   INTEGER NOT NULL,
  billing_type  TEXT NOT NULL CHECK (billing_type IN ('one_time','recurring')),
  pass_kind     TEXT NOT NULL CHECK (pass_kind IN ('credit','unlimited')),
  credits       INTEGER,
  validity_days INTEGER,
  is_hero       INTEGER NOT NULL DEFAULT 0,
  display_order INTEGER NOT NULL DEFAULT 0,
  is_archived   INTEGER NOT NULL DEFAULT 0,
  -- Optional Stripe Price id (price_…). Set once the studio mirrors the
  -- product into Stripe so the intent flow can charge against it.
  stripe_price_id TEXT,
  created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS product_class_types (
  product_id    TEXT NOT NULL REFERENCES products(id),
  class_type_id TEXT NOT NULL REFERENCES class_types(id),
  PRIMARY KEY (product_id, class_type_id)
);

CREATE TABLE IF NOT EXISTS purchases (
  id                TEXT PRIMARY KEY,
  studio_id         TEXT NOT NULL REFERENCES studios(id),
  user_id           TEXT NOT NULL REFERENCES users(id),
  product_id        TEXT NOT NULL REFERENCES products(id),
  -- amount_minor is what the customer actually paid (list - discount).
  -- list_price_minor is what the product cost before any discount; we
  -- store it explicitly so reports can compute gross-vs-net without
  -- having to look up the product's current price (which may have
  -- changed since the purchase).
  list_price_minor  INTEGER NOT NULL,
  amount_minor      INTEGER NOT NULL,
  discount_minor    INTEGER NOT NULL DEFAULT 0,
  discount_id       TEXT REFERENCES discounts(id),
  currency          TEXT NOT NULL,
  payment_method    TEXT NOT NULL CHECK (payment_method IN
                      ('card','card_present','cash','transfer','comp','dev_stub')),
  initiated_by      TEXT NOT NULL REFERENCES users(id),
  actor_role        TEXT NOT NULL CHECK (actor_role IN ('student','manager')),
  status            TEXT NOT NULL DEFAULT 'completed'
                      CHECK (status IN ('pending','completed','refunded','voided')),
  -- Refund tracking: refunded_at/refund_amount/refunded_by are set when
  -- a manager refunds the purchase. refund_amount_minor supports partial
  -- refunds; full refunds set it to amount_minor and status to 'refunded'.
  refunded_at        TEXT,
  refund_amount_minor INTEGER NOT NULL DEFAULT 0,
  refunded_by        TEXT REFERENCES users(id),
  refund_note        TEXT,
  -- Stripe PaymentIntent id (pi_…) once the intent flow is in use. NULL
  -- for cash/comp/dev_stub paths.
  stripe_payment_id TEXT,
  resulting_entitlement_id TEXT REFERENCES entitlements(id),
  created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_purchases_user ON purchases(user_id, created_at);

-- ===== Discounts =========================================================
--
-- A discount is a price modifier applied at purchase time. Attaches to
-- the purchase row, never to the entitlement — a 10-pack is always 10
-- credits regardless of what was paid for it. Series enrollments
-- discount through the same `purchases` row (the enrollment_booking
-- row owns the seat; the purchase owns the money).
--
-- Kinds:
--   percent      value = 1..100 (10 means 10%)
--   fixed_minor  value = currency minor units (500 = £5.00 off)
--   comp         value ignored — 100% off; used for staff / make-goods
--
-- code:                 NULL for ad-hoc manager grants; otherwise the
--                       string customers type at checkout. Looked up
--                       case-insensitively per studio.
-- applies_to_product_id NULL = applies to any product. Set to restrict.
-- valid_from/to:        NULL = no bound on that side.
-- max_uses:             NULL = unlimited; otherwise rejects on Nth use.
-- max_uses_per_user:    NULL = unlimited; otherwise rejects when a
--                       user's prior usage count reaches the cap.
-- archived_at:          set when the discount is retired. Past usages
--                       remain on the purchases for the audit trail.
CREATE TABLE IF NOT EXISTS discounts (
  id                     TEXT PRIMARY KEY,
  studio_id              TEXT NOT NULL REFERENCES studios(id),
  code                   TEXT,
  kind                   TEXT NOT NULL CHECK (kind IN ('percent','fixed_minor','comp')),
  value                  INTEGER NOT NULL DEFAULT 0,
  applies_to_product_id  TEXT REFERENCES products(id),
  valid_from             TEXT,
  valid_to               TEXT,
  max_uses               INTEGER,
  max_uses_per_user      INTEGER,
  notes                  TEXT,
  created_by             TEXT NOT NULL REFERENCES users(id),
  created_at             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  archived_at            TEXT
);
-- Code lookup at checkout. Partial index keeps the no-code (manager
-- grant) rows out of the lookup index entirely.
CREATE INDEX IF NOT EXISTS idx_discounts_code
  ON discounts(studio_id, code) WHERE code IS NOT NULL;

-- One Stripe credential set per studio. Secrets are stored AES-GCM
-- encrypted with the master key in STRIPE_KEY_ENC_MASTER (env). The DB
-- alone yields ciphertext; loss of the DB without the master key keeps
-- the secrets safe.
--
-- Conventions:
--   publishable_key       — pk_test_ / pk_live_, plaintext (it's meant
--                           for client-side use anyway).
--   secret_key_*          — sk_test_ / sk_live_, encrypted blobs.
--   webhook_signing_*     — whsec_…, encrypted blobs.
--   secret_key_last4      — last 4 chars of the (decrypted) secret key so
--                           the manager UI can show "•••• abcd" without
--                           decrypting on every read.
CREATE TABLE IF NOT EXISTS studio_stripe_credentials (
  studio_id                  TEXT PRIMARY KEY REFERENCES studios(id),
  mode                       TEXT NOT NULL DEFAULT 'test'
                                 CHECK (mode IN ('test','live')),
  account_id                 TEXT,
  publishable_key            TEXT,
  secret_key_cipher          BLOB,
  secret_key_nonce           BLOB,
  secret_key_last4           TEXT,
  webhook_secret_cipher      BLOB,
  webhook_secret_nonce       BLOB,
  webhook_secret_last4       TEXT,
  updated_by                 TEXT REFERENCES users(id),
  updated_at                 TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- ===== Notifications + waitlist =========================================

CREATE TABLE IF NOT EXISTS notifications (
  id          TEXT PRIMARY KEY,
  studio_id   TEXT NOT NULL REFERENCES studios(id),
  user_id     TEXT NOT NULL REFERENCES users(id),
  type        TEXT NOT NULL, -- booking_confirmed | waitlist_promoted | class_cancelled | system | ...
  title       TEXT NOT NULL,
  body        TEXT,
  payload     TEXT NOT NULL DEFAULT '{}',
  read_at     TEXT,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, read_at);

-- Per-user notification category opt-outs. One row per user; absence means
-- "send me everything" (no row = defaults).
CREATE TABLE IF NOT EXISTS notification_prefs (
  user_id            TEXT PRIMARY KEY REFERENCES users(id),
  booking_confirmed  INTEGER NOT NULL DEFAULT 1,
  class_cancelled    INTEGER NOT NULL DEFAULT 1,
  waitlist_promoted  INTEGER NOT NULL DEFAULT 1,
  promotions         INTEGER NOT NULL DEFAULT 1,
  system_msgs        INTEGER NOT NULL DEFAULT 1,
  updated_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS device_tokens (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id),
  fcm_token   TEXT NOT NULL UNIQUE,
  platform    TEXT,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS waitlist_entries (
  id          TEXT PRIMARY KEY,
  class_id    TEXT NOT NULL REFERENCES classes(id),
  user_id     TEXT NOT NULL REFERENCES users(id),
  -- 1-based queue position. Only meaningful while status='waiting' — we
  -- leave the value as-is on promote/leave so audit reads can see "they
  -- were #3 when promoted".
  position    INTEGER NOT NULL,
  -- Row lifecycle. We don't delete entries on promote or leave so the
  -- studio can answer "who waited for this class, what happened to
  -- them". The UI's "queue" view filters for status='waiting'.
  status      TEXT NOT NULL DEFAULT 'waiting'
                  CHECK (status IN ('waiting','promoted','left')),
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  promoted_at TEXT,
  left_at     TEXT
);
-- Partial unique index — at most one ACTIVE queue slot per (class, user).
-- Historical 'promoted' / 'left' rows are unconstrained so the same user
-- can join, leave, rejoin, get promoted, all in one history.
CREATE UNIQUE INDEX IF NOT EXISTS uq_waitlist_active_per_user
  ON waitlist_entries(class_id, user_id)
  WHERE status = 'waiting';
CREATE INDEX IF NOT EXISTS idx_waitlist_class
  ON waitlist_entries(class_id, position)
  WHERE status = 'waiting';

-- ===== Achievements =====================================================
-- Cosmetic per the spec — secondary on Home, not a hero. Stored as
-- (user_id, badge_key) so a future schema change to the catalogue of
-- badges doesn't require backfilling earned_at on every row.
CREATE TABLE IF NOT EXISTS achievements (
  user_id    TEXT NOT NULL REFERENCES users(id),
  badge_key  TEXT NOT NULL,
  earned_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (user_id, badge_key)
);
CREATE INDEX IF NOT EXISTS idx_achievements_user ON achievements(user_id, earned_at);

-- ===== Promotions =======================================================

CREATE TABLE IF NOT EXISTS promotions (
  id          TEXT PRIMARY KEY,
  studio_id   TEXT NOT NULL REFERENCES studios(id),
  title       TEXT NOT NULL,
  body        TEXT,
  image_url   TEXT,
  starts_at   TEXT,                    -- NULL = open-start
  ends_at     TEXT,                    -- NULL = open-end
  is_archived INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_promotions_studio ON promotions(studio_id, created_at);

-- ===== Audit log (sensitive manager actions) ============================

CREATE TABLE IF NOT EXISTS audit_log (
  id          TEXT PRIMARY KEY,
  studio_id   TEXT NOT NULL REFERENCES studios(id),
  actor_id    TEXT NOT NULL REFERENCES users(id),
  action      TEXT NOT NULL,           -- cash_grant | credit_adjust | void | ...
  target_type TEXT NOT NULL,           -- entitlement | booking | purchase | ...
  target_id   TEXT,
  detail      TEXT NOT NULL DEFAULT '{}',
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_audit_studio_time ON audit_log(studio_id, created_at);

-- ===== Group chat + direct messages =====================================
-- A `conversation` is either a staff-created `group` (named, many members)
-- or a `dm` (no title, exactly two members, staff-initiated to a student).
-- Membership in `conversation_members` is the access-control list: only
-- members read or post. There is no studio-wide "everyone" room — every
-- participant has an explicit row.
--
-- Messages carry a per-conversation monotonic `seq` ASSIGNED IN GO (not a
-- DB sequence) so the schema ports unchanged to Postgres. The pattern
-- mirrors waitlist_entries.position: SELECT MAX(seq)+1 inside the insert
-- tx, guarded by uq_messages_conv_seq. Under Postgres' looser write
-- concurrency two senders can read the same MAX; the unique index makes
-- the loser fail and the store retries (see SendMessage). seq drives both
-- keyset pagination (seq < cursor / seq > cursor) and unread maths
-- (messages.seq > members.last_read_seq).

CREATE TABLE IF NOT EXISTS conversations (
  id          TEXT PRIMARY KEY,
  studio_id   TEXT NOT NULL REFERENCES studios(id),
  kind        TEXT NOT NULL CHECK (kind IN ('group','dm')),
  title       TEXT,                    -- NULL for dm; client derives from members
  created_by  TEXT NOT NULL REFERENCES users(id),
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_conversations_studio ON conversations(studio_id, created_at);

CREATE TABLE IF NOT EXISTS conversation_members (
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  user_id         TEXT NOT NULL REFERENCES users(id),
  -- High-water mark of the highest message seq this member has read.
  -- 0 = never read. Drives unread counts and "read by" receipts.
  last_read_seq   INTEGER NOT NULL DEFAULT 0,
  joined_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_conv_members_user ON conversation_members(user_id);

CREATE TABLE IF NOT EXISTS messages (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  -- 1-based, dense, per-conversation. App-assigned (see header note).
  seq             INTEGER NOT NULL,
  sender_id       TEXT NOT NULL REFERENCES users(id),
  body            TEXT NOT NULL,
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  -- Set on edit; client renders an "edited" marker. NULL = never edited.
  edited_at       TEXT,
  -- Soft delete: row stays so seq numbering + receipts don't shift; body
  -- is blanked and the client shows "message removed". NULL = live.
  deleted_at      TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_messages_conv_seq ON messages(conversation_id, seq);
CREATE INDEX IF NOT EXISTS idx_messages_conv_seq ON messages(conversation_id, seq);

-- ===== Student notes ====================================================
-- Free-text notes attached to a user, visible to all staff (instructor +
-- manager). Use cases: injuries to be aware of, preferences ("always
-- sits at the back"), what an instructor covered with the student last
-- time. Distinct from `audit_log` (which records what happened in the
-- system) and `messages` (which is a conversation WITH the student).
--
-- Soft-delete intentionally NOT modelled — notes get small + frequent
-- edits, hard-delete on remove keeps the list focused. The audit_log
-- captures the create/update/delete actions for compliance, including
-- the body at the time of the action, so historical reads are still
-- possible via audit even after the row is gone.
CREATE TABLE IF NOT EXISTS user_notes (
  id          TEXT PRIMARY KEY,
  studio_id   TEXT NOT NULL REFERENCES studios(id),
  -- Subject of the note (the student being noted about).
  user_id     TEXT NOT NULL REFERENCES users(id),
  -- Staff member who wrote the note. Could differ from the studio's
  -- current staff list if they've since left; we keep the FK so the
  -- attribution survives but accept that the join might surface an
  -- ex-staff name.
  author_id   TEXT NOT NULL REFERENCES users(id),
  body        TEXT NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  -- NULL until edited.
  updated_at  TEXT
);
-- Primary read path: list a user's notes newest-first when opening their
-- detail page. Index covers that exact lookup.
CREATE INDEX IF NOT EXISTS idx_user_notes_user
  ON user_notes (user_id, created_at DESC);
