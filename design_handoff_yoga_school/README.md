# Handoff: Yoga School App — Studio 52 (Student App + Manager Console)

## Overview

A white-label yoga studio app with two frontends sharing one design language:

1. **Student mobile app** — Splash + sign-in, Home, Book (day-strip schedule), Enrollments (course series), Buy (passes & memberships), Stripe checkout, booking sheet, check-in QR, Profile/Wallet, Notifications.
2. **Student web (desktop)** — the same student app reflowed for laptop: top-nav shell, two-column Home, Book with a docked detail panel, wide Buy. Breakpoint rule: below ~900 px logical width use the mobile layouts + tab bar; above it, the top-nav shell.
3. **Manager console** (desktop/web) — Dashboard, Schedule (week + day×room views), Roster/check-in, series roster, Product Builder, Students, Reports, money dialogs, Studio Settings with a **theme editor**.
4. **Front desk POS** — Stripe Terminal sale flow in the console + a **customer-facing display** (desk tablet) as a third themed frontend.

The entire UI is built on a **token-based theming system**: a studio configures six semantic color tokens (plus logo/name/welcome message) and the app derives everything else. Four starter presets ship (Warm Clay, Cool Slate, Earthy Sage, Bright Citrus), each with light + dark variants. **This theming system is the core architectural requirement — implement it first.**

The full product/engineering spec (endpoints, schema, business rules) is included as `yoga-school-spec.md`. Design decisions in this README override nothing in that spec; they fill in the "Part 5" design brief.

## About the Design Files

The files in this bundle are **design references created in HTML/JSX** — prototypes showing intended look and behavior, **not production code**. The target stack is **Flutter (student mobile + manager desktop/web) over a Go backend** (see spec). Recreate these designs in Flutter using its established patterns (ThemeData/ThemeExtension for the token system, `google_fonts` for type). The HTML exists only so you can open `Student App — Home Book Buy.html` in a browser and inspect every screen side-by-side on a pan/zoom canvas (a Tweaks panel in the hosting tool switches theme presets; the preset data itself is in `yoga-theme.jsx`).

## Fidelity

**High-fidelity.** Colors, type sizes/weights, spacing, radii, and copy are intentional — recreate pixel-faithfully at the given scales (390–402 px logical width mobile; 1240 px desktop reference). Exact text content is final-quality placeholder copy; real data replaces it.

## Design Tokens

### Semantic tokens (studio-configurable — the ONLY colors a studio sets)

| Preset | Mode | primary | accent | background | surface | text | text_muted |
|---|---|---|---|---|---|---|---|
| Warm Clay | light | `#B05C3B` | `#C8973F` | `#FAF5EF` | `#FFFFFF` | `#2D2218` | `#8F8174` |
| Warm Clay | dark | `#D08054` | `#D9AD5F` | `#201A15` | `#2B231C` | `#F3EDE6` | `#A79784` |
| Cool Slate | light | `#3A5E7E` | `#64998F` | `#F4F6F8` | `#FFFFFF` | `#1E2730` | `#75828E` |
| Cool Slate | dark | `#7BA6C9` | `#84BCB2` | `#14191F` | `#1E262E` | `#E9EEF2` | `#93A1AD` |
| Earthy Sage | light | `#5E7153` | `#A9744A` | `#F6F5EE` | `#FFFFFF` | `#272B20` | `#82876F` |
| Earthy Sage | dark | `#93AB7F` | `#C99A6B` | `#191C14` | `#232719` | `#EEF0E6` | `#9CA28E` |
| Bright Citrus | light | `#D94F24` | `#17A398` | `#FFFBF5` | `#FFFFFF` | `#25211E` | `#8B8480` |
| Bright Citrus | dark | `#FF7A4D` | `#2FC4B2` | `#1C1715` | `#281F1B` | `#F7F1EC` | `#A99F99` |

Warm Clay light is the default theme.

### Derived tokens (computed — never set by the studio)

Implement exactly these rules (reference implementation: `yoga-theme.jsx`, function `yogaVars`):

- `onPrimary` — `#FFFFFF` if primary's relative luminance ≤ 0.45, else `#1A1611`. Same rule for `onAccent`. **This is the contrast guardrail** — additionally the theme editor must warn/block when text-on-surface or onPrimary-on-primary falls below WCAG 4.5:1.
- `primarySoft` — light mode: mix(primary, background, 88% toward background); dark mode: primary at 16% alpha. Same recipe for `accentSoft` (86% / 16%).
- `primaryStrong` (text-safe primary for tinted chips) — light: mix(primary, text, 18% toward text); dark: mix(primary, white, 12%).
- `surface2` (subtle fill, segmented-control tracks) — light: mix(surface, text, 3.5%); dark: mix(surface, white, 5%).
- `border` — text at 10% alpha (light) / 14% (dark). `borderStrong` — 18% / 24%.
- `shadow` — light: `0 2px 10px` text@6%; dark: `0 4px 16px rgba(0,0,0,0.4)`.

### Typography (fixed — NOT studio-configurable)

Family: **Hanken Grotesk** (Google Fonts; `google_fonts` package in Flutter). Weights 400/500/600/700/800. Negative letter-spacing on large headings (≈ −0.02em), `tabular-nums` for all times/prices.

Mobile scale: greeting/screen title 26–28 / w800 · sheet title 19 / w800 · section head 17 / w700 · card title 15–16.5 / w700–800 · body/meta 12.5–14 / w500–600 muted · chip 11–12 / w600–700 · stat number 21–22 / w800.

Desktop (console) scale: page title 23 / w800 · card title 14.5 / w800 · table body 13.5 / w600 · table header 11.5 / w700 uppercase ls+0.6 · stat number 28 / w800.

### Spacing, radius, shape

- 4-pt spacing grid. Mobile screen gutter 20 px; desktop content padding 26–30 px; card padding 14–22 px; list-item gap 8 px.
- Radius: cards 16 px (a user-tweakable design var, range 10–24, keep as a constant) · chips/buttons fully rounded (999) · small tiles 10–12 px · bottom sheets 24 px top corners.
- Buttons: primary = primary fill + onPrimary text, 13 px/20 px padding (full) or 7 px/14 px (small), w700. "Soft" = primarySoft fill + primaryStrong text. "Outline" = transparent + borderStrong. Min touch target 44 px.
- State chips: Booked = primarySoft bg + primaryStrong text + check icon; Full = transparent + borderStrong border + muted text; accent chip = accentSoft + accent.
- Icons: 1.8 px stroke, round caps/joins, 24 viewBox (see SVG paths in `yoga-ui.jsx` `Y_ICONS`).

## Screens / Views — Student App (390–402 logical px)

All screens sit on `background`; cards on `surface` with 1 px `border`; bottom tab bar on `surface` with top border: **Home · Book · Buy · Profile · More** (assumption flagged to the client: spec said 4 tabs, Home added as leading 5th — confirmed by design review). Active tab = primary, inactive = muted, 10.5 px labels.

### Home
Top → bottom: (1) header — 34 px monogram logo tile (primary bg, "52"), studio name 13 px uppercase muted ls+1.6; right: 38 px bell button (1 px borderStrong circle, accent unread dot) + 38 px avatar. (2) Greeting 26/w800 + date 14 muted. (3) **Slim promo banner** — accentSoft fill, r16, 10/14 padding: tag icon (accent), 13.5/w600 single-line offer, chevron. (4) "Upcoming" section: hero booking card (shadow): 52×56 date tile (primarySoft, dow 10.5/w800 + day 21/w800 in primaryStrong), class 16.5/w700, time·room 13 muted, 20 px instructor avatar + name, "Booked" chip right. Second booking = compact row card, no shadow. (5) "This week at the studio": one card, rows separated by border — 34 px avatar, class 14.5/w700, meta 12.5 muted, small soft "Book" button. (6) Milestones strip — **deliberately quiet** (cosmetic per spec): dashed borderStrong border, star icon accent, "24 classes · 3-week streak" 12.5 muted.

**Empty (first run):** same header/promo; centered card — 58 px primarySoft circle w/ calendar icon, "Your week is wide open" 18/w800, 1-line sub, primary "Browse classes" + outline "See passes"; below, surface2 strip suggesting beginner classes. Tone: warm but brief.

### Book
(1) Title "Book" 28/w800 + 38 px barcode check-in button. (2) Segmented control Classes | Enrollments — surface2 track r999 p3, active segment surface + border + shadow. (3) "JUNE 2026" 13/w700 muted + prev/next chevrons. (4) **Day strip — 7 equal chips**: dow letter 10.5, date 16/w800, 4 px dot underneath when the day has classes (dot = primary on unselected, onPrimary on selected); selected chip = primary fill r14, others surface + border. (5) Class rows (8 px gap): 48 px time column (16/w800 + duration 11.5 muted), 1 px vertical divider, class name 15/w700 + 20 px avatar + instructor 12.5 muted, right-aligned state column. States: **Booked** chip · primary small **Book** button (+optional "2 spots left" 11.5 muted hint below) · **"Full · 3 waiting"** outline chip with "Join waitlist" primary text-link below (row otherwise normal — decided).

**Empty day:** strip dot absent for that day; centered 58 px surface2 circle clock icon, "A rest day at the studio" 17/w800, sub line, soft button "Next classes · Fri 12 →".

### Buy — three layouts, studio-selectable
The studio chooses Grid / List / Grouped in console Settings → Policies → "Buy screen layout". All three share: title 28/w800 + "Passes & memberships" sub; filter chips All/Yoga/Reformer (active = text-color fill with bg-color text). **Membership vs pack distinction is color treatment (decided):** hero membership = primary fill + onPrimary; other memberships = primarySoft; packs = plain surface + border. Memberships carry a "Membership" tag with renew icon (12 px); packs carry a discipline gate chip ("All yoga" surface2/muted; "Reformer only" accentSoft/accent). Price 18–21/w800; meta 11–12 at 60–85% opacity.
- **A Grid:** 2-col, 8 px gap, cards min-height 118, chip top / name / price+meta bottom.
- **B List:** full-width rows, name+tag line, meta below, gate chip + price right.
- **C Grouped:** "Memberships" head → 2-up membership cards; "Class packs" head → list rows.

### Checkout (Stripe) — bottom sheet over Buy
Dim overlay `rgba(15,10,5,0.4)` + 2 px blur. Sheet: surface, 24 px top radius, grabber 38×4. "Confirm purchase" 19/w800 → product summary card (primarySoft: name 15/w800, terms 12.5 muted, price 19/w800) → **express wallets row**: Apple Pay (black #000 pill, white  Pay logo) + Google Pay (white pill, #dadce0 border, G logo) — these keep platform branding, NEVER theme tokens → divider "OR PAY WITH CARD" → saved card option (selected: 1.5 px primary border, radio = 5 px primary ring, VISA tile = text-color fill) + "Use a different card…" → full-width primary "Pay £60" → lock icon + "Payments secured by Stripe · receipt by email" 11.5 muted.

### Purchase success
Centered: 72 px primary circle + onPrimary check, "You're all set" 22/w800, sub, pass card (primarySoft, 5 filled credit-segment bars, "5 of 5 credits", expiry), full-width primary "Book your first class", muted "Done" text button, receipt line 11.5 muted.

### Class detail / booking sheet (over Book)
Same sheet pattern. Class 19/w800, datetime·room 13 muted, "2 spots left" accent chip; 30 px avatar + "with Jonas Meyer · 10 of 12 booked". "PAY WITH" label → eligible entitlement selected (primary border + primarySoft; credits left + expiry; "1 credit" right) → "Buy a new pass…" fallback row (this is the no-valid-pass path: when eligible list is empty it's the only option). "+1 guest" row with toggle (40×24, gated by `allow_student_plus_one`), "uses a 2nd credit" note. Cancel policy line 12 muted ("Free cancellation until Wed 21:00. After that, your credit is used." — snapshot of studio cutoff). Full-width primary "Book this class".

### Profile — Overview / Wallet (segmented)
Header: 56 px avatar, name 21/w800, "Member since…" 13 muted, edit pencil button; segmented Overview|Wallet.
- **Overview:** stats card — 3 columns (9 this month / 3 wks streak / 24 all time; 22/w800 + 11.5 muted) divided by borders, **plus 12-week bar chart** (44 px tall, 4 px r bars, primarySoft history + primary current week, axis labels 10.5 muted). "Active passes" (lead position): primarySoft card, name 15.5/w800 + gate chip, 5-segment credit progress bar (filled = primary; empty = surface + borderStrong), "3 of 5 credits left" + expiry 12.5. "History" below at 75% opacity: rows w/ Expired/Depleted outline chips. (Decision: active and history **separated**, active on top.)
- **Wallet:** "Payment methods" (+Add action): VISA tile 42×28 (text-color fill, bg-color label), "···· 4242" 14/w700, Default chip. "Purchase history": rows — product 14/w700, "date · Card/Cash, at the desk" 12 muted, price 14.5/w800 tabular. Footnote about receipts/cash 11.5 muted.

### Notifications (under More) + empty
Back chevron button + "Notifications" 22/w800. Cards: 34 px tonal icon circle (accent = waitlist, primary = confirmations, surface2 = system), title 14/w700 + time 11.5 muted + 7 px accent unread dot, body 12.5 muted lh1.45. Waitlist promotion includes small primary "Claim spot" button (claim-window model: "claim your place by 11:15"). Empty: bell in surface2 circle, "All quiet for now" 17/w800 + one line.

## Screens / Views — Student Web (desktop, 1240×800 reference)

Same tokens and components as mobile, reflowed. Shell: 64 px top bar on `surface` with bottom border — logo + studio name, nav pills Home/Book/Buy (active = primarySoft fill + primaryStrong text), bell + avatar right; content in a 1040 px max-width column, 28 px top padding.

- **Home:** greeting 28/w800 + date; slim promo banner full-width (with "See offer →" text link); two-column grid (1.5fr/1fr): left — "Upcoming" hero booking card (adds a muted "Cancel" text action under the chip) + compact second booking + quiet milestones strip; right — "This week" rail card with 3 bookable rows.
- **Book:** header row = title + 280 px Classes|Enrollments segmented control. Two-column (1.6fr/1fr): left — month label + chevrons, 7-day strip (same dot semantics), class rows; the selected row gets a 1.5 px primary border + shadow and a "Selected" accent chip. Right — **docked detail panel**: the mobile booking sheet's content (class info, PAY WITH entitlement selection, cancel policy, Book button) as a persistent surface card — no overlay. Selecting a row populates the panel.
- **Buy:** grouped layout only at desktop — "Memberships" as 2-up horizontal cards (tag + name + meta left, price 24/w800 right; hero = primary fill), "Class packs" as 2-up rows. The studio's Grid/List/Grouped setting applies to mobile; desktop always uses grouped.
- **Checkout on desktop:** centered modal instead of bottom sheet; express wallets render via Stripe's payment request API (browser-dependent).

### Splash, sign-in, check-in
- **Splash:** standard = themed bg, centered 84 px monogram tile (r26, primary fill, shadow), studio name 24/w800 + welcome message 13.5 muted. **Optional studio image variant** (uploaded in Settings → Studio → Splash image): full-bleed image backdrop; logo tile flips to white-on-image with primary monogram; name/welcome in white. Image is a placeholder in the design — awaiting real asset.
- **Sign in:** logo 52 px, "Welcome to Studio 52" 27/w800, email + password fields (label 11/w700 muted inside bordered field r14), "Forgot password?" right-aligned primary link, full-width primary "Sign in", OR divider, **Continue with Apple (black) / Google (white+border)** — platform branding, never themed — "Create an account" footer link. (Firebase Auth per spec.)
- **Check-in (behind Book's barcode button):** white card (always white for scanner contrast, regardless of theme/dark) r24 with QR (`GET /me/checkin-code`, rotating token) + human-readable code 17/w800 ls2.5; below: avatar + name, "Booked · <next class>" chip, note "Show this at the front desk scanner / Screen brightness raised automatically."

### Enrollments (Book › Enrollments tab)
Model: **one payment → booked into every session** of a series (e.g. £60 · 6 Wednesdays). No credits involved.
- **List:** course cards — name 15.5/w800, "6 sessions · Wednesdays 18:00 · 17 Jun – 22 Jul" 12.5 muted, instructor avatar+name; right: price 17/w800 + "one payment" 11 muted. States: open = primary "Enroll · £60" button + "3 of 10 left"; full = "Full · 2 waiting" chip + "Join waitlist" link; enrolled = primarySoft card, "Enrolled" chip, 6-segment week-progress bar + "Session 2 of 6 · next Mon 15". Footer note explains the model.
- **Enroll sheet:** course header + spots chip; "YOU'LL BE BOOKED INTO ALL 6" — 3-col grid of week tiles (WK n + date, primarySoft); missed-week policy line; surface2 total row ("One payment · no credits used" + £60); primary "Enroll & pay £60"; Stripe footnote (wallets + card).
- **Manager series roster:** stats (Enrolled 9/12, Revenue, Attendance %); attendance grid — students × 6 week columns, cells: present = primary tile w/ check, no-show = text-color tile w/ ✕, upcoming = dashed outline; legend below; current week column header in primary.

## Screens — Manager money dialogs (centered modals, 460 px, over dimmed screen)
All three: title 18/w800, sub 13 muted, student line (avatar/name/email in surface2 row + "Change"), Cancel + confirm bottom-right.
- **Grant/sell a pass:** Product select, "Paid via" segmented **[Cash | Card · reader | Transfer | Comp]**, amount, start date, audit note field; footer note: instant pass + receipt, recorded in Reports. (`POST /admin/students/{id}/grant`)
- **Adjust credits:** pass picker, −/+ stepper (current → new preview "3 → 4 of 5"), **reason required**; logged with actor name. (`/adjust`)
- **Void & refund:** purchase summary, refund segmented [Unused £36 | Full £60 | None], method (Stripe → original card), reason required, **danger confirm** (`#A33B2E` fill), accentSoft warning when upcoming bookings will be cancelled. (`/void`)

## Screens — Front desk POS (Stripe Terminal)
- **Sell via reader:** same sell dialog with "Card · reader" selected → reader status card (reader illustration, name, green connected dot, battery, "Change") and confirm = "Send to reader · £60". Footer note: customer display shows the order; approval grants the pass instantly, recorded as card-present revenue.
- **Customer display** (desk tablet, landscape, themed from studio tokens): shell = logo+name top-left, "Payments secured by Stripe" bottom-center. **Paying state:** two-column — YOUR ORDER card (product, terms, divider, Total 30/w800) | contactless icon in 130 px primarySoft circle + "Tap, insert or swipe" 24/w800. **Approved state:** primary circle check, "Thank you, <name>" 28/w800, amount + card + receipt line, primarySoft "See you in class 🙏" pill. (Idle state = splash-like logo screen; not drawn.)
- **Plan/schema implications:** `payment_method` CHECK gains `'card_present'` (or add a `channel` column); Stripe Terminal SDK + reader pairing row in Studio Settings; customer display is simplest as a themed web page the desk tablet keeps open, driven by the console's active sale.

## Screens / Views — Manager Console (1240×800 reference, desktop)

Density: **calm/spacious** — generous padding, airy tables, same tokens. Shell: 208 px sidebar (surface, right border): logo + "Studio 52 / MANAGER", nav items (9/10 padding r10, active = primarySoft fill + primaryStrong text; icons 17 px) — Dashboard, Schedule, Products, Students, Roster, Reports, Settings; bottom: manager avatar + name/role. Content: 26/30 padding; page title 23/w800 + sub 13.5 muted; right-aligned action buttons.

### Dashboard
Accent-soft alert banner ("2 classes from yesterday still have unmarked attendance" + "Review →"). 3 stat cards (label 12.5 muted / value 28 w800 / sub 12 muted): Occupancy today, Revenue today (card/cash split), New bookings. "Today's classes" table: Time w800 tabular · Class w700 · Instructor (22 px avatar) · Occupancy **meter** (6 px track surface2, fill primary, accent at 100%) + "13 / 14" · status chip · "Roster" link (primary 12.5/w700).

### Schedule — Week + Day views (toggle in header)
- **Week:** 7 columns w/ left borders; day label 11.5 uppercase (today = primary); class blocks: r10, primarySoft (yoga) / accentSoft (reformer/courses) with 3 px left border in the solid color; name 11.5/w800, "time · instructor · room" 10.5 muted; empty day = "No classes — rest day". 
- **Day (time × room lanes):** column per room (Room 1, Room 2 · Reformer, Garden Studio) + 52 px time gutter 7:00–20:00 (46 px/hour); hairline hour gridlines; blocks absolutely positioned by start/duration; FULL pill on full classes. **This view is the room-conflict answer** — simultaneous classes sit side-by-side in their lanes.

### Roster / Check-in
Title = class name; sub = datetime · instructor · room. Actions: outline "+ Add student", primary "Scan check-in". Left card "Booked · 16 of 16" (+"Mark all present" action): **filter chip row — All 16 / Unmarked 13 / Present 2 / No-show 1** (active = text-fill/bg-text) + "Find a name…" search pill; table: student (26 px avatar; "· scanned" accent note when checked in by scan), pass used (muted), attendance segmented per row [Present | No-show] (Present active = primary fill; No-show active = text fill). Right card "Waitlist · 3": position number, name, soft "Promote" buttons; surface2 note: "Promoting notifies the student — their spot holds for 60 minutes before passing on" (claim-window model, the spec's recommended option).

### Product Builder — single form + live preview (decided)
Header: breadcrumb sub "Products / 5-Class Pack"; actions: outline Archive, primary Save. Left card (2-col fields): Name, Price (GBP suffix), Billing [One-time|Recurring], Pass kind [Credits|Unlimited] (hint: "Credit packs count down; unlimited checks only the validity window") — **credits + validity fields hide/disable when Unlimited**, Eligible class types as check-chips. Bottom note (surface2): edits affect **future purchases only**. Right column: "Student sees" card — live render of the Buy row exactly as the student app shows it + plain-language terms sentence; "In use" card — active passes count, revenue, last sale.

### Students
Stat sub "214 students · 128 with an active pass"; primary action "Grant a pass (cash)". Search field; table: student (26 avatar) · active pass · remaining (credits or renew date) · last visit · row action ("View", or "Grant pass" for pass-less students).

### Reports
3 stat cards (Revenue month w/ card/cash, Avg occupancy, No-show rate). "Revenue by week" stacked bars: card = solid primary bar, cash = accentSoft with 2 px accent top edge, week labels 11 muted. "Instructor pay" table: instructor · classes taught · pay (w800 tabular).

### Studio Settings
Two-column. Left: "Studio" card (Display name, Welcome message, Timezone, Currency) and "Policies" card — Free cancellation cutoff (hours input), "Students can bring a +1" toggle + explainer, **"Buy screen layout" segmented [Grid|List|Grouped]** (new studio setting from design review). Right: **"Themes" card** (+ New theme): rows of palette swatch-trios + name + "Contrast ✓ AA" + Active chip / "Activate" link; optional "auto-activates 1 Dec" scheduled note (accent). Inline token editor panel (surface2): 6 token swatch-chips for the active theme + guardrail line: "Text on surface 12.6:1 · Text on primary 4.9:1 — both pass. The editor blocks saving below 4.5:1."

## Interactions & Behavior

- Bottom sheets slide up ≈300 ms ease-out with fade-in dim; respect reduced motion.
- Day strip: horizontal selection, content swaps per day; week chevrons page 7 days.
- Booking: row Book → class sheet → entitlement preselected (best eligible) → Book → confirmation → row state becomes Booked chip. No eligible pass → sheet shows only "Buy a new pass…" → Buy/checkout flow → returns to complete booking.
- Full class → Join waitlist; waitlist promotion = notify + 60-min claim window (notification carries "Claim spot").
- Checkout: wallets (Apple Pay/Google Pay via Stripe payment-request) preferred, saved card fallback; success screen routes to Book.
- Roster: attendance toggles write immediately; "Mark all present" bulk; scan check-in marks present + shows "· scanned".
- Theme switch (or activation from console) re-themes the whole app live — no restart; derived tokens recompute.
- Dark mode follows system, using the active theme's dark token set.

## State Management (per spec endpoints)

Key client state: studio config + active theme tokens (from `GET /studio/config`, cached at splash); bookings (upcoming/past); per-day class lists with per-row `booking_state`; eligible entitlements per class (drives book-vs-buy); entitlement wallet states (active/expired/depleted); purchase flow (pending → confirm → new entitlement). Console: roster attendance map, waitlist order, product form draft + derived preview, theme draft + contrast validation.

## Assets

- No raster assets. Studio logo = monogram tile placeholder ("52" on primary); instructor/user photos = initials avatars (primarySoft or accentSoft bg, w700 initials) — **replace with real photos via `photo_url` when available**.
- Icons are inline SVG paths (1.8 stroke, 24 viewBox) in `yoga-ui.jsx` (`Y_ICONS`), `yoga-admin-ui.jsx` (`K_NAV`), and inline per-screen. Map to closest Lucide/Material equivalents in Flutter.
- Apple Pay / Google Pay marks must use the official platform button assets in production.

## Files

- `Student App — Home Book Buy.html` — open in a browser to view all boards on a canvas.
- `yoga-theme.jsx` — **token presets + derivation math (authoritative for theming).**
- `yoga-ui.jsx` — shared mobile primitives (avatar, chips, buttons, tab bar, icons, screen shell).
- `yoga-home.jsx`, `yoga-book.jsx`, `yoga-buy.jsx` — Home, Book, Buy (×3 layouts) + empty states.
- `yoga-student2.jsx` — Profile/Wallet, class booking sheet, notifications.
- `yoga-checkout.jsx` — Stripe checkout sheet + purchase success.
- `yoga-student-web.jsx` — student app at desktop width (web shell, Home, Book + docked panel, Buy).
- `yoga-onboard.jsx` — splash (×2), sign-in, check-in QR screen.
- `yoga-enroll.jsx` — Enrollments list + enroll sheet + manager series roster.
- `yoga-admin-c.jsx` — money dialogs (grant/sell, adjust credits, void & refund).
- `yoga-pos.jsx` — Stripe Terminal sell dialog + customer-facing display (paying / approved).
- `yoga-admin-ui.jsx` — console shell + desktop primitives (cards, stats, tables, form controls).
- `yoga-admin-a.jsx` — Dashboard, Schedule (week + day×room), Product Builder.
- `yoga-admin-b.jsx` — Roster (+ filters), Students, Reports, Settings/theme editor.
- `yoga-app.jsx`, `design-canvas.jsx`, `ios-frame.jsx`, `tweaks-panel.jsx` — canvas/presentation chrome only; **not part of the product design**.
- `yoga-school-spec.md` — full engineering spec (API, schema, business rules).

## Not yet designed (build from established patterns, or request designs)

More screen (settings list pattern) · manager enrollment-series **builder** form (use Product Builder pattern) · audit log screen · achievements detail (keep cosmetic/quiet) · POS idle state · push-permission priming · class-cancellation comms · error/offline states.
