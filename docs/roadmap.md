# Roadmap

Ideas for what to build next, organised by who benefits. Not a backlog
in any tool sense — just a written list so we can pick one, scope it,
and ship it without rediscovering the menu each time.

Status legend:

- ☐ idea — not started, scope is still rough
- ⏳ in progress — someone's working on it
- ✅ done — moved out of this file, lives in the codebase + audit log

When something graduates to "done", strike it through here OR delete the
entry. Either is fine; the file is meant to stay short.

---

## Recently shipped

Newest first. Move items here from below as they land so a session
returning cold can see what's recent without trawling `git log`. Trim
the list when it gets longer than ~15 items — old wins live in commit
history.

- ✅ **Student notes per student** — hero card on the manager
  student-detail page. `user_notes` table, staff-tier CRUD with
  author-only edit/delete, audit-logged (`student_note_create` /
  `_update` / `_delete`). Surfaced in the audit-log filter list.
- ✅ **Instructor Firebase accounts seeded** — `asha@` / `jonas@` /
  `mara@studio52.dev` now sign in with `dev123456`. The instructor
  staff-tier flow is finally testable.
- ✅ **Manager Schedule visual polish** —
  - `_hourHeight` / `_hourPx` bumped 56 → 64 so 60-min class blocks
    have room for title + meta + occupancy bar.
  - Tightened the LayoutBuilder thresholds (`showMeta` 42 → 36,
    `showOccupancy` 62 → 47) + padding 6 → 3 so 50-min Reformer blocks
    also carry the bar.
  - Class-block background now takes a low-alpha wash of the room
    colour (18% on Schedule, 12% on the student Book card) instead of
    the theme's primarySoft / accentSoft.
  - Missing room-colour join fixed on `AdminClassesFor` (was the only
    `ClassRow` query that didn't include `r.color` — bug hid the
    feature on the manager Schedule even when set).
- ✅ **Room colour picker UX simplified** — tap-to-commit (preset or
  custom-hex Enter both close + save), dropped the confusing "Use" vs
  "Save" pair, "Clear" renamed to "Remove colour". Palette expanded
  from 8 → 18 presets, organised by hue family.
- ✅ **Rooms-card swatch affordance** — primary-tinted border + icon
  on the empty state so it reads as "tap me", Material+InkWell hover
  overlay on web/desktop.
- ✅ **Local HTTPS dev proxy** — Caddy on `:5443` terminating TLS with
  an mkcert cert, proxying to Go API + Flutter dev. Same-origin in
  dev kills the CORS preflight noise and unlocks prod-shape behaviour
  for service workers / secure cookies / HTTP/2. Wired into Tilt
  (`yoga-caddy` resource) + Makefile (`make caddy`). Idempotent setup
  via `scripts/setup-tls.sh` and a `setup-tls` step at the top of
  `yoga-bootstrap` so a fresh checkout becomes one-button.
- ✅ **TLS smoke tests** — `scripts/check-tls.sh` (cert trust + HTTP/2
  + API proxy reachability) and `TestTLSRoundTripWithMkcert` in Go
  (httptest TLS server + mkcert-root-only trust pool). Both skip
  cleanly when their preconditions aren't present.
- ✅ **`/healthz` endpoint** — unauthenticated DB-ping probe for the
  eventual prod load balancer. `authBypassRoutes` allowlists it. Two
  tests covering OK + no-auth.
- ✅ **README "Local dev — TLS proxy"** + **"Before shipping" updates**
  documenting the convention-vs-force trust model (Caddy is the polite
  path; Go's :8080 stays open in dev, gets firewalled in prod).

## Roles cheat sheet

Four DB roles, three functional tiers. Keep this aligned with
`tierForRole` in `server/internal/api/api.go`.

| Role | Tier | Reach |
|---|---|---|
| **student** | student | Book / cancel, buy passes, view their wallet + bookings + profile, get notifications. |
| **instructor** | staff | Read-only schedule, open class rosters, mark attendance, scan check-ins, see class type / instructor / room lists. |
| **manager** | manager | Everything above + money (grants, refunds, adjusts), config, reports, audit log, staff CRUD, themes, rooms, students, promotions, GDPR actions. |
| **owner** | manager | Alias for manager — same access. Reserved for "the one account that can never be locked out". |

---

## Student — engagement / retention

- ☐ **Recurring booking** — "book this class every Tuesday for 4 weeks".
  Server already has `recurrence_rules` for classes; needs a parallel
  concept for bookings (rolling window + auto-create on schedule
  publish).
- ☐ **Class favourites** — star instructors or class types; surface on
  Home as quick rebook chips.
- ☐ **iCal feed** — `GET /me/calendar.ics` so students subscribe to
  their bookings in Apple / Google Calendar. ~half-day, no app changes.
- ☐ **Visible streaks** — "3-week streak" on Profile. Hooks into the
  existing achievements system.
- ☐ **Buddy / +1 history** — quick rebook with the same friend. Builds
  on the plus-one work already in `bookings`.

## Student — money

- ☐ **Apple Pay / Google Pay in checkout** — Stripe Payment Element
  already supports both; a few lines of wiring.
- ☐ **Gift cards** — buy + redeem. Lives as entitlements; same shape
  as a credit pack with a different `pass_kind`.
- ☐ **Family / minor accounts** — one parent account books for their
  kids. Bookings get a `for_user_id` distinct from the payer.
- ☐ **Subscription pause** — vacation hold on unlimiteds. Add
  `paused_at` / `pause_until` to `entitlements`, freeze the consumption
  clock while paused.

## Instructor — making their job easier

- ☐ **Personal dashboard** — "your week" view: your classes, your
  earnings YTD, your average attendance.
- ☐ **Class notes** — private free-text on each class instance ("ran
  flow B, played Tycho mix, Mara had shoulder").
- ✅ **Student notes** — private notes per student visible to all
  staff ("Sarah: prefers props, recovering from knee surgery"). Hero
  card on the manager student-detail page. `user_notes` table, staff-
  tier CRUD with author-only edit/delete, audit-logged.
- ☐ **Substitute request** — flag a class as "need cover"; other
  instructors see open slots and claim them.

## Manager — operations

- ☐ **Marketing broadcast** — manager composes a message, fans out to
  all students (in-app notification + optional email). Chat module
  already exists; this is a one-to-many variant.
- ☐ **Win-back automation** — "students who haven't booked in 30 days"
  cohort + one-click broadcast. Hooks into the reports + chat
  infrastructure.
- ☐ **Daily roster print** — physical paper for the front desk. PDF or
  print-friendly HTML route.
- ☐ **Door kiosk / customer display** — `customer_display.dart`
  exists in `app/lib/src/screens/`; partially built. Worth fleshing
  out: live class checkin queue on a tablet at the door.
- ☐ **Instructor payroll export** — reports already calculate
  instructor pay; add a "export CSV per pay period" action.
- ☐ **Capacity overrides** — bump a single class's capacity for a
  popular session.
- ☐ **Tax reports** — VAT / sales tax breakdown per period for HMRC.

## Operational / cross-role

- ☐ **Web push notifications** — `server/internal/push/` is wired for
  FCM; web push needs the service-worker manifest path enabling.
- ☐ **PWA install prompt** — students install the studio's app to
  their home screen. One line of HTML + a manifest tweak.
- ☐ **Audit log export** — same CSV pattern as reports.
- ☐ **2FA for managers** — Firebase Auth supports it; expose the
  enrolment screen in manager Settings.

## Tech / dev experience (not user-facing)

- ✅ **Seed Firebase users for the three instructors** — `asha@`,
  `jonas@`, `mara@studio52.dev` now have accounts in the emulator
  seeder. Password `dev123456` like everyone else.
- ☐ **Hover sweep for GestureDetector pills** — `YButton` got the
  hover treatment but sidebar nav, layout-mode pills, action chips are
  still flat. Convert to InkWell+Material as we did for YButton.

## Big rewrites — flagged so they don't sneak in

These are not features, they're projects. Listed here so the next time
someone says "wouldn't it be nice if…" we recognise the scope.

- **Multi-location studios** — currently one studio per deploy. Going
  multi-tenant inside one deploy means schema changes + tenant scoping
  everywhere.
- **Public studio website** — separate domain, separate SEO surface.
  Probably better as a small static site that links to the booking app.
- **Native mobile apps** — the Flutter codebase already runs on iOS /
  Android, but App Store guidelines, in-app payment rules (Apple takes
  30%), push notification setup, etc. turn this into a project, not a
  port.

---

## Picking the next one

When picking, optimise for:

1. **High value, low scope.** "Student notes" + "iCal feed" + "Apple
   Pay" are all in this corner.
2. **Builds on what we have.** "Win-back broadcast" reuses reports +
   chat; "achievements visible to student" reuses the achievements
   table.
3. **Closes a real gap.** "Seed instructor accounts" unblocks testing
   the instructor flow at all.

A rough recommended order — pick from the top of this list when in
doubt:

1. ~~Seed Firebase users for the three instructors~~ ✅ done
2. ~~Student notes per student~~ ✅ done
3. **iCal feed** (½ day) — student delight, easy.
4. **Apple Pay / Google Pay in checkout** (½ day) — modern UX, Stripe
   does the heavy lift. (Currently UI-only stubs; needs real wiring.)
5. **Win-back broadcast** (1 day) — manager love, reuses existing infra.
