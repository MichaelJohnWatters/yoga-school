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
  branding                  TEXT NOT NULL DEFAULT '{}',
  active_theme_id           TEXT,
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
  stripe_customer_id  TEXT,
  checkin_token       TEXT,
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
  name        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS classes (
  id                TEXT PRIMARY KEY,
  studio_id         TEXT NOT NULL REFERENCES studios(id),
  class_type_id     TEXT NOT NULL REFERENCES class_types(id),
  instructor_id     TEXT REFERENCES users(id),
  room_id           TEXT REFERENCES rooms(id),
  enrollment_id     TEXT REFERENCES enrollments(id),
  template_batch_id TEXT REFERENCES class_templates(id),
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
  parent_booking_id   TEXT REFERENCES bookings(id),
  booked_by_role      TEXT NOT NULL CHECK (booked_by_role IN ('student','manager')),
  cancel_cutoff_hours INTEGER NOT NULL,
  status              TEXT NOT NULL DEFAULT 'booked'
                        CHECK (status IN ('booked','cancelled','attended','no_show')),
  attendance_marked_by TEXT CHECK (attendance_marked_by IN ('manual','scan')),
  created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  cancelled_at        TEXT,
  UNIQUE (class_id, user_id, is_plus_one)
);
CREATE INDEX IF NOT EXISTS idx_bookings_class ON bookings(class_id, status);
CREATE INDEX IF NOT EXISTS idx_bookings_user ON bookings(user_id, status);

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
  amount_minor      INTEGER NOT NULL,
  currency          TEXT NOT NULL,
  payment_method    TEXT NOT NULL CHECK (payment_method IN
                      ('card','card_present','cash','transfer','comp','dev_stub')),
  initiated_by      TEXT NOT NULL REFERENCES users(id),
  actor_role        TEXT NOT NULL CHECK (actor_role IN ('student','manager')),
  status            TEXT NOT NULL DEFAULT 'completed'
                      CHECK (status IN ('pending','completed','refunded','voided')),
  resulting_entitlement_id TEXT REFERENCES entitlements(id),
  created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_purchases_user ON purchases(user_id, created_at);

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
  position    INTEGER NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  UNIQUE (class_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_waitlist_class ON waitlist_entries(class_id, position);

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
