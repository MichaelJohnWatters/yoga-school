# Yoga School App — Pages, API Surface & Data Model (v2)

Stack: Flutter (student mobile + manager desktop/web) over a Go backend, Postgres, Stripe (deferred), Firebase Auth + FCM.
Shared Flutter core package holds models, API client, auth, and entitlement logic so both apps agree on pass rules.

---

> **Note for Claude Design:** This is the full engineering + design spec for a yoga studio app (student mobile app + manager console). Use **Parts 3–4 (API and schema) only as context** to understand what data each screen handles — don't design those. Focus your design work on **Parts 1, 2, and 5**. Before designing anything, walk me through the **ASK-ME questions in Part 5 one screen at a time**, starting with global aesthetic direction, then design **Home, Book, and Buy first** (they define the visual language the rest inherit). The manager console is a separate visual job (desktop density) — tackle it after the student app look is settled.

---

## Conventions

- `/api/v1` prefix. Auth via **Firebase ID token**; backend verifies and resolves the internal user + studio.
- **Tenancy:** every request is scoped to one `studio_id` (carried in the resolved session). Every query filters by it. Multi-studio supported but expected to be light.
- `STUDENT` / `MANAGER` / `BOTH` mark caller. **↺ REUSED** endpoints listed once in Part 3.
- IDs are UUIDs. Timestamps UTC; "day" boundaries computed in **studio timezone** (a setting). Money is integer minor units; **currency is a studio setting**.

---

# PART 1 — STUDENT APP

## 1. Splash
| Need | Endpoint | Notes |
|---|---|---|
| Validate session | `GET /me` ↺ | Firebase token → internal user + studio config |
| Studio config | `GET /studio/config` ↺ | timezone, currency, **active theme tokens**, branding, `allow_student_plus_one`, cancel cutoff |

First login: backend creates the student row and links `firebase_uid` if absent (onboarding).

## 2. Home
| Need | Endpoint | Notes |
|---|---|---|
| Upcoming bookings | `GET /bookings?scope=upcoming` ↺ | |
| Previous bookings | `GET /bookings?scope=past` ↺ | |
| Upcoming classes | `GET /classes?from=&to=` ↺ | |
| Achievements | `GET /me/achievements` | Cosmetic, derived from attendance |
| Promotions | `GET /promotions` | Active-window filtered |

## 3. Book — tabs: Classes / Enrollments
Day-strip calendar (studio-tz days); rows show time, type, instructor+photo, booking state.

| Need | Endpoint | Notes |
|---|---|---|
| Classes for a day | `GET /classes?date=&kind=class` ↺ | Per-row `booking_state` for caller |
| Enrollments (series) | `GET /enrollments` | Buyable multi-session series |
| Enrollment detail | `GET /enrollments/{id}` | Sessions, price, seats left |
| Class detail | `GET /classes/{id}` ↺ | Capacity, waitlist count |
| Eligible passes for class | `GET /classes/{id}/eligible-entitlements` | Drives book-vs-buy |
| Book a class | `POST /bookings` ↺ | class_id, entitlement_id, plus_one? |
| Join an enrollment | `POST /enrollments/{id}/join` | Consumes entitlement once; creates child session bookings |
| Cancel a booking | `DELETE /bookings/{id}` ↺ | Applies snapshotted policy; fires waitlist promote |
| Join waitlist | `POST /classes/{id}/waitlist` | |

**No-valid-pass:** empty eligible list → buy sheet via `GET /products?covers_class_type={id}`.
**+1:** `plus_one:true`; gated by `allow_student_plus_one` unless caller is manager.

## 4. Buy
| Need | Endpoint | Notes |
|---|---|---|
| List products | `GET /products` ↺ | Filter by class type/discipline |
| Product detail | `GET /products/{id}` | Terms, credits/unlimited, validity, billing |
| Start purchase (card) | `POST /purchases` ↺ | Stripe (deferred) |
| Confirm purchase | `POST /purchases/{id}/confirm` | Creates entitlement |

## 5. Profile — Overview / Wallet
| Need | Endpoint | Notes |
|---|---|---|
| Profile | `GET /me` ↺ | |
| Bookings | `GET /bookings` ↺ | |
| Attendance metrics | `GET /me/attendance` | Counts, streaks, no-shows |
| Entitlement states | `GET /me/entitlements` ↺ | active/expired/depleted, kind, remaining |
| Purchase history | `GET /purchases?scope=mine` ↺ | |
| Payment methods | `GET/POST/DELETE /wallet/payment-methods` | |

## 6. More
| Need | Endpoint | Notes |
|---|---|---|
| Notification prefs | `GET/PATCH /me/notifications` | |
| Notifications feed | `GET /me/notifications/feed` | Simple select now; FCM later |
| Register device token | `POST /me/devices` | FCM token store |
| Check-in barcode | `GET /me/checkin-code` | Rotating token |
| Feedback / review | `POST /feedback` · `POST /reviews` | |
| Content pages | `GET /content/{slug}` | |
| Sign out | `POST /auth/logout` ↺ | |

---

# PART 2 — MANAGER CONSOLE

## 7. Dashboard
| Need | Endpoint | Notes |
|---|---|---|
| Today overview | `GET /admin/dashboard` | Occupancy, revenue, unmarked-attendance alerts |
| Today's classes | `GET /classes?date=today` ↺ | |

## 8. Schedule / Class Management
| Need | Endpoint | Notes |
|---|---|---|
| Calendar | `GET /classes?from=&to=` ↺ | |
| Create class/rule | `POST /admin/classes` | Single or with recurrence rule |
| Edit class | `PATCH /admin/classes/{id}?scope=this\|future\|all` | See recurrence semantics |
| Cancel class | `DELETE /admin/classes/{id}` | Batch credit-return + notify + clear waitlist |
| Instructors | `GET /admin/instructors` ↺ | |
| Rooms | `GET /admin/rooms` | |

## 9. Product Builder
| Need | Endpoint | Notes |
|---|---|---|
| Products | `GET /products` ↺ · `POST/PATCH /admin/products` | Edits affect future purchases only |
| Archive product | `DELETE /admin/products/{id}` | Soft; existing entitlements untouched |
| Class types | `GET /admin/class-types` ↺ · `POST/PATCH` | |

## 10. Enrollment Builder
| Need | Endpoint | Notes |
|---|---|---|
| Series CRUD | `GET/POST/PATCH /admin/enrollments` | Define sessions, count, price, recurrence |
| Roster for series | `GET /admin/enrollments/{id}/roster` | Enrolled students |

## 11. Student Management
| Need | Endpoint | Notes |
|---|---|---|
| Search students | `GET /admin/students?q=` | |
| Student detail | `GET /admin/students/{id}` | |
| Their entitlements | `GET /admin/students/{id}/entitlements` ↺ | |
| Grant pass + cash | `POST /admin/students/{id}/grant` | product_id + payment_method=cash; actor=manager |
| Credit adjust | `POST /admin/students/{id}/entitlements/{eid}/adjust` | +/- + reason → audit log |
| Void entitlement | `POST /admin/entitlements/{id}/void` | Cash refund offline; audited |

## 12. Roster / Check-in
| Need | Endpoint | Notes |
|---|---|---|
| Roster | `GET /admin/classes/{id}/roster` | Booked + waitlist |
| Mark attendance | `POST /admin/bookings/{id}/attendance` | present / no_show (manager records no-shows) |
| Scan check-in | `POST /admin/checkin/scan` | Barcode token → mark present |
| Manual book | `POST /bookings` ↺ | actor=manager; overrides +1 gate |
| Promote waitlist | `POST /admin/classes/{id}/promote` | Also auto-fired on cancel |

## 13. Payments & Reporting
| Need | Endpoint | Notes |
|---|---|---|
| Revenue | `GET /admin/reports/revenue` | Split cash vs card |
| Attendance/retention | `GET /admin/reports/attendance` | |
| Instructor pay | `GET /admin/reports/instructor-pay` | |
| Purchases ledger | `GET /purchases?scope=all` ↺ | |

## 14. Studio Settings
| Need | Endpoint | Notes |
|---|---|---|
| Config | `GET/PATCH /admin/studio/config` | timezone, currency, cancel cutoff, +1 permission |
| List/create themes | `GET/POST /admin/themes` | Seasonal presets + custom palettes |
| Edit theme | `PATCH /admin/themes/{id}` | Token edits; contrast-validated |
| Activate theme | `POST /admin/themes/{id}/activate` | Sets `studios.active_theme_id` |
| Promotions | `GET/POST/PATCH /admin/promotions` | |
| Staff | `GET/POST /admin/staff` | Flat roles for now |
| Audit log | `GET /admin/audit` | Cash grants, adjusts, voids, cancels |

---

# PART 3 — REUSED ENDPOINTS

`GET /me` · `GET /studio/config` · `GET /classes` (filters: date range, kind, eligibility) ·
`GET /classes/{id}` · `POST /bookings` + `DELETE /bookings/{id}` (student + manager) ·
`GET /bookings` (scope) · `GET /products` · `POST /purchases` (card-buy + cash-grant share the model) ·
`GET /me/entitlements` ↔ `GET /admin/students/{id}/entitlements` (two scopes, one view) ·
`GET /purchases` (mine / all) · `GET /admin/instructors` · `GET /admin/class-types` · `POST /auth/logout`

---

# PART 4 — POSTGRES SCHEMA

```sql
-- ============ STUDIO & IDENTITY ============
CREATE TABLE studios (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL,
  timezone      TEXT NOT NULL DEFAULT 'Europe/London',  -- defines "day" boundaries
  currency      TEXT NOT NULL DEFAULT 'GBP',
  free_cancel_cutoff_hours INT NOT NULL DEFAULT 12,
  allow_student_plus_one   BOOLEAN NOT NULL DEFAULT FALSE,
  branding      JSONB DEFAULT '{}',
  active_theme_id UUID,                         -- currently applied theme (FK below)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Saveable, switchable colour themes (seasonal presets + custom)
CREATE TABLE themes (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id   UUID NOT NULL REFERENCES studios(id),
  name        TEXT NOT NULL,                    -- 'Winter 2026', 'Summer Bright'
  is_preset   BOOLEAN NOT NULL DEFAULT FALSE,   -- shipped starter vs studio-made
  tokens      JSONB NOT NULL,                   -- {primary, accent, background, surface, text, text_muted}
  splash_image_url TEXT,                        -- theme can override splash too
  activate_on DATE,                             -- optional scheduled auto-activation
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (studio_id, name)
);
-- studios.active_theme_id REFERENCES themes(id) (add FK after both tables exist)

CREATE TABLE users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id     UUID NOT NULL REFERENCES studios(id),
  firebase_uid  TEXT UNIQUE,                  -- external identity (Firebase Auth)
  role          TEXT NOT NULL CHECK (role IN ('student','instructor','manager','owner')),
  email         TEXT NOT NULL,
  full_name     TEXT NOT NULL,
  photo_url     TEXT,
  stripe_customer_id TEXT,
  checkin_token TEXT,                          -- rotating barcode/QR
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (studio_id, email)
);

CREATE TABLE rooms (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id UUID NOT NULL REFERENCES studios(id),
  name TEXT NOT NULL
);

CREATE TABLE class_types (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id UUID NOT NULL REFERENCES studios(id),
  name TEXT NOT NULL,
  discipline TEXT
);

-- ============ RECURRENCE ============
CREATE TABLE recurrence_rules (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id   UUID NOT NULL REFERENCES studios(id),
  frequency   TEXT NOT NULL CHECK (frequency IN ('daily','weekly','monthly')),
  interval    INT NOT NULL DEFAULT 1,
  weekdays    INT[],                            -- 0–6 for weekly
  starts_on   DATE NOT NULL,
  ends_on     DATE,                             -- null = open; or use count
  occurrences INT,                              -- alternative end-condition
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============ ENROLLMENTS (buyable series) ============
CREATE TABLE enrollments (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id     UUID NOT NULL REFERENCES studios(id),
  title         TEXT NOT NULL,
  product_id    UUID,                           -- how it's paid for (REFERENCES products)
  session_count INT NOT NULL,
  recurrence_rule_id UUID REFERENCES recurrence_rules(id),
  capacity      INT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============ CLASSES (single sessions & enrollment sessions) ============
CREATE TABLE classes (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id     UUID NOT NULL REFERENCES studios(id),
  class_type_id UUID NOT NULL REFERENCES class_types(id),
  instructor_id UUID REFERENCES users(id),
  room_id       UUID REFERENCES rooms(id),
  enrollment_id UUID REFERENCES enrollments(id),    -- non-null = a series session
  recurrence_rule_id UUID REFERENCES recurrence_rules(id),
  is_detached   BOOLEAN NOT NULL DEFAULT FALSE,      -- edited-this: skip on regenerate
  title         TEXT,
  starts_at     TIMESTAMPTZ NOT NULL,
  ends_at       TIMESTAMPTZ NOT NULL,
  capacity      INT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'scheduled'
                  CHECK (status IN ('scheduled','cancelled')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_classes_studio_time ON classes(studio_id, starts_at);

-- ============ PRODUCTS ============
CREATE TABLE products (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id     UUID NOT NULL REFERENCES studios(id),
  name          TEXT NOT NULL,
  price_minor   INT NOT NULL,
  billing_type  TEXT NOT NULL CHECK (billing_type IN ('one_time','recurring')),
  pass_kind     TEXT NOT NULL CHECK (pass_kind IN ('credit','unlimited')),
  credits       INT,                            -- credit kind only; NULL for unlimited
  validity_days INT,                            -- NULL = no expiry
  stripe_price_id TEXT,
  is_archived   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE product_class_types (
  product_id    UUID NOT NULL REFERENCES products(id),
  class_type_id UUID NOT NULL REFERENCES class_types(id),
  PRIMARY KEY (product_id, class_type_id)
);

-- ============ PURCHASES ============
CREATE TABLE purchases (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id      UUID NOT NULL REFERENCES studios(id),
  user_id        UUID NOT NULL REFERENCES users(id),
  product_id     UUID NOT NULL REFERENCES products(id),
  amount_minor   INT NOT NULL,
  currency       TEXT NOT NULL,                 -- snapshotted from studio at purchase
  payment_method TEXT NOT NULL CHECK (payment_method IN ('card','cash')),
  initiated_by   UUID NOT NULL REFERENCES users(id),
  actor_role     TEXT NOT NULL CHECK (actor_role IN ('student','manager')),
  stripe_payment_id TEXT,
  status         TEXT NOT NULL DEFAULT 'completed'
                   CHECK (status IN ('pending','completed','refunded','voided')),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============ ENTITLEMENTS (snapshotted at purchase) ============
CREATE TABLE entitlements (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id       UUID NOT NULL REFERENCES studios(id),
  user_id         UUID NOT NULL REFERENCES users(id),
  purchase_id     UUID NOT NULL REFERENCES purchases(id),
  source_product_id UUID REFERENCES products(id),
  pass_kind       TEXT NOT NULL CHECK (pass_kind IN ('credit','unlimited')),
  credits_total     INT,                         -- credit kind only
  credits_remaining INT,                         -- ignored when pass_kind='unlimited'
  expires_at      TIMESTAMPTZ,                    -- NULL = no expiry
  status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','expired','depleted','voided')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_entitlements_user ON entitlements(user_id, status);

CREATE TABLE entitlement_class_types (
  entitlement_id UUID NOT NULL REFERENCES entitlements(id),
  class_type_id  UUID NOT NULL REFERENCES class_types(id),
  PRIMARY KEY (entitlement_id, class_type_id)
);

-- ============ BOOKINGS ============
CREATE TABLE bookings (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id       UUID NOT NULL REFERENCES studios(id),
  class_id        UUID NOT NULL REFERENCES classes(id),
  user_id         UUID NOT NULL REFERENCES users(id),
  entitlement_id  UUID NOT NULL REFERENCES entitlements(id),
  is_plus_one     BOOLEAN NOT NULL DEFAULT FALSE,
  parent_booking_id UUID REFERENCES bookings(id),
  booked_by_role  TEXT NOT NULL CHECK (booked_by_role IN ('student','manager')),
  cancel_cutoff_hours INT NOT NULL,              -- POLICY SNAPSHOT
  status          TEXT NOT NULL DEFAULT 'booked'
                    CHECK (status IN ('booked','cancelled','attended','no_show')),
  attendance_marked_by TEXT CHECK (attendance_marked_by IN ('scan','manual')),
  outcome         TEXT CHECK (outcome IN
                    ('cancelled_free','cancelled_late_burned',
                     'no_show_burned','class_cancelled_returned')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  cancelled_at    TIMESTAMPTZ,
  -- guard: one active booking per student per class
  UNIQUE (class_id, user_id, is_plus_one)
);
CREATE INDEX idx_bookings_class ON bookings(class_id, status);
CREATE INDEX idx_bookings_user ON bookings(user_id, status);

-- series-level membership (one row per student per series)
CREATE TABLE enrollment_bookings (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id  UUID NOT NULL REFERENCES enrollments(id),
  user_id        UUID NOT NULL REFERENCES users(id),
  entitlement_id UUID NOT NULL REFERENCES entitlements(id),
  status         TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','cancelled')),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (enrollment_id, user_id)
);

-- ============ WAITLIST ============
CREATE TABLE waitlist_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  class_id UUID NOT NULL REFERENCES classes(id),
  user_id  UUID NOT NULL REFERENCES users(id),
  position INT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (class_id, user_id)
);

-- ============ NOTIFICATIONS (channel-agnostic; FCM later) ============
CREATE TABLE notifications (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id  UUID NOT NULL REFERENCES studios(id),
  user_id    UUID NOT NULL REFERENCES users(id),
  type       TEXT NOT NULL,        -- booking_confirmed, waitlist_promoted, class_cancelled...
  title      TEXT NOT NULL,
  body       TEXT,
  payload    JSONB DEFAULT '{}',
  read_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_notifications_user ON notifications(user_id, read_at);

CREATE TABLE device_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id),
  fcm_token TEXT NOT NULL,
  platform TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (fcm_token)
);

-- ============ AUDIT LOG (sensitive manager actions) ============
CREATE TABLE audit_log (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id   UUID NOT NULL REFERENCES studios(id),
  actor_id    UUID NOT NULL REFERENCES users(id),
  action      TEXT NOT NULL,       -- cash_grant, credit_adjust, void, class_cancel...
  target_type TEXT NOT NULL,
  target_id   UUID,
  detail      JSONB DEFAULT '{}',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_studio_time ON audit_log(studio_id, created_at);

-- ============ ANCILLARY ============
CREATE TABLE promotions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id UUID NOT NULL REFERENCES studios(id),
  title TEXT NOT NULL, body TEXT, image_url TEXT,
  starts_at TIMESTAMPTZ, ends_at TIMESTAMPTZ
);

CREATE TABLE achievements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id),
  badge_key TEXT NOT NULL,
  earned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, badge_key)
);

CREATE TABLE payment_methods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id),
  stripe_pm_id TEXT NOT NULL,
  brand TEXT, last4 TEXT,
  is_default BOOLEAN NOT NULL DEFAULT FALSE
);
```

---

## Load-bearing decisions (unchanged + new)

1. **Snapshotting** in four places: entitlement copies product allowed-set/credits/expiry/kind; purchase copies currency; booking copies cancel cutoff. Manager edits never act retroactively.
2. **`pass_kind` branch** is the fix for unlimited-vs-credit: `credit` enforces `credits_remaining`; `unlimited` ignores it and checks only validity window + allowed set. Booking logic branches once.
3. **Enrollments** are a series (`enrollments`) bought once (`enrollment_bookings`, one entitlement consumed), whose dated sessions are `classes` rows linked by `enrollment_id`. Per-session `bookings` still track attendance → partial attendance falls out naturally.
4. **Recurrence** stores a real rule; instances are materialized `classes`. Edit-this detaches one instance; edit-future splits the rule; edit-all regenerates non-detached instances.
5. **Tenancy:** Firebase token → internal user → `studio_id`; every query filters by it.
6. **No-shows** are manager-recorded on the roster (no sweep job). **Waitlist promotion** fires on cancel. **Studio class-cancel** batch-returns credits via the `class_cancelled_returned` outcome.
7. **Stripe** fields present; webhook→entitlement reconciliation and card refunds deferred to the Stripe phase.

## Still open (smaller, non-blocking)
- Waitlist promotion **credit timing**: auto-book+burn vs notify-with-claim-window (recommend claim-window). Pick before building the promote flow.
- Rotating `checkin_token` rotation/expiry mechanism (security).
- Achievement earning logic + optional leaderboard table.

---

# PART 5 — DESIGN BRIEF & THEMING (handoff to Claude Design)

> **For Claude Design:** the screens in Parts 1–2 are the source of truth for *content and data*. This part covers *look and feel*. Where a decision is already made it's marked **DECIDED** — don't re-ask. Where it's open it's marked **ASK ME** — please put these questions back to me before committing to a direction, one screen at a time.

## 5.1 Theming & configuration (studio-controllable from Settings)

Build the UI as a **token-based themeable system**, not fixed styling. A studio configures a small set of *semantic tokens* and the app derives everything else (hover/disabled/border states) from them, with **contrast enforced automatically** so a studio can't ship unreadable text.

**Semantic tokens (the only colours a studio sets directly):**
- `primary`, `accent`, `background`, `surface`, `text` (+ `text_muted`)
- Everything else is computed from these.

**Other configurable branding:**
- **Splash image**, **Logo**, **App display name**, **Welcome message**

**Seasonal theming — saveable named presets.** A studio saves a palette as a named **theme** ("Winter 2026", "Summer Bright") and switches in one click; we ship a few starter presets (warm / cool / earthy / bright) they can tweak. Optional later: schedule a theme to auto-activate on a date.

**Contrast guardrail:** whatever tokens a studio picks, text-on-surface and text-on-primary must meet a minimum contrast ratio; the editor warns/blocks below it.

Fixed (not studio-controllable): tab-bar structure, screen layouts, iconography, typography scale.

**RESOLVED (was ASK ME):** presets *and* token-level editing, layered — presets are the friendly default, token editing for studios that want control, contrast guardrails under both.

## 5.2 Decided constraints (don't re-ask)

- **DECIDED** — Tab bar: Book / Buy / Profile / More. Fixed.
- **DECIDED** — Achievements/badges are a *low-priority cosmetic gimmick*. Do **not** make them a hero element on Home; keep them secondary. Leaderboard is optional/opt-in.
- **DECIDED** — Book uses a horizontal dotted day-strip calendar; class rows show time, class type, instructor name + photo, and booking state ("Booked" when reserved).
- **DECIDED** — Two frontends share a design language: student app (mobile-first) and manager console (desktop/web-first, also mobile). Same visual system, different density.
- **DECIDED** — Platform: Flutter. Design within Flutter-friendly patterns.

## 5.3 Open design questions — ASK ME, grouped by screen

**Global**
- Overall aesthetic direction — calm/minimal/wellness, or bold/energetic? Reference apps I like?
- Light only, or light + dark?

**Splash**
- Logo-forward, or full-bleed image with logo overlaid?

**Home**
- Card order / priority: bookings, upcoming classes, promotions, achievements — what leads?
- How prominent should promotions be (banner vs card vs carousel)?

**Book**
- Day-strip: how many days visible at once? Week view fallback?
- Class row density — compact list vs roomy cards with large instructor photos?
- How is a full / waitlist-only class shown?

**Buy**
- Products as a grid or a list? How do I visually distinguish one-off passes from rolling memberships?
- How are discipline-gated passes (yoga-only / reformer-only) labelled?

**Profile**
- How are active vs expired/depleted passes shown — together with state, or separated?
- Attendance metrics: numbers, charts, or both?

**Manager console**
- Density preference — data-dense dashboard, or calmer/spacious?
- Product Builder is the most complex screen — wizard/step flow, or single dense form?

## 5.4 Empty states — please design these too

Every primary screen needs a first-run / empty version:
- **Home** — new student, no bookings, no passes (this is the first thing a new user sees — make it inviting, point to Book/Buy).
- **Book** — a day with no classes scheduled.
- **Buy** — (rare) no products configured yet.
- **Profile** — no passes, no history.
- **Notifications feed** — nothing yet.
- **Manager** — brand-new studio with no classes/products/students.

**ASK ME:** tone for empty states — playful, or plain/functional?
