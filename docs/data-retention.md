# Data Retention & Erasure Policy

Studio 52 processes personal data under the **UK GDPR** and the **Data
Protection Act 2018**. The supervisory authority is the **ICO**. This document
records, per data category, the lawful basis for holding it and how long we
keep it — and what a Right to Erasure (Art. 17) request actually does to each
category. It is the reference the engineering implementation
(`server/internal/store/gdpr.go`) is built against.

## Principle: erasure = pseudonymisation, not deletion

The right to erasure is **not absolute**. It is overridden where we have an
independent legal obligation to retain data (UK GDPR Art. 17(3)(b)) — most
importantly **HMRC's 6-year retention requirement for financial records**, and
the need to retain records for the establishment or defence of legal claims.

So an erasure request does **not** drop the person's rows. It:

1. **Tombstones** the `users` anchor row — email, name, photo and the Firebase
   link are replaced/cleared and `erased_at` is stamped. The row's surrogate
   `id` survives so financial and audit rows remain referentially intact but no
   longer point at an identifiable person.
2. **Scrubs** free-text PII wherever it leaks (chat message bodies, +1 guest
   names, refund notes, audit detail).
3. **Deletes** purely transient, device-bound categories outright.
4. **Deletes the Firebase Auth account**, which holds the email separately.

After erasure the person cannot authenticate (Firebase link cleared) and does
not appear in any staff-facing listing (`erased_at IS NULL` filters).

## Per-category register

| Category | Table(s) | Lawful basis to retain | On erasure |
|---|---|---|---|
| Identity / profile | `users` | Contract while active | **Tombstone** (email→`erased+<id>@deleted.invalid`, name→`[erased]`, photo/firebase_uid→NULL, `erased_at` set) |
| Payments / purchases | `purchases` | **Legal obligation — HMRC, 6 years** | **Retain** amounts/dates; scrub `refund_note` free text |
| Entitlements / passes | `entitlements`, `enrollment_bookings` | Tied to financial record | **Retain** (no free-text PII; anonymised via tombstone) |
| Class bookings | `bookings` | Legitimate interest (attendance/liability) | **Retain** row; scrub `plus_one_name` (third-party PII) → `[erased]` |
| Waitlist history | `waitlist_entries` | Legitimate interest | **Retain** (user_id only; anonymised) |
| Chat / DMs | `messages`, `conversation_members` | Contract while active | **Scrub** message bodies authored by subject; membership retained for thread integrity |
| Audit log | `audit_log` | **Accountability (Art. 5(2)) / legal claims** | **Retain** row, action, actor, timestamp; **redact** PII keys in `detail` |
| Notifications | `notifications` | Transient | **Delete** |
| Push device tokens | `device_tokens` | Transient / device-bound | **Delete** |
| Notification prefs | `notification_prefs` | Transient | **Delete** |
| Achievements | `achievements` | Cosmetic | **Delete** |

## External processors

- **Stripe** (payments) — a data *processor*. Card and contact data held there
  fall under the same financial-retention exemption; Stripe applies its own
  retention. We do not attempt to erase the Stripe-side payment record.
- **Firebase Auth** (identity) — the auth account is **deleted** as part of
  erasure (best-effort, post-commit). An orphaned auth account would otherwise
  let the person sign back in.

## Backups

Erasure operates on the live database. Personal data may persist in encrypted
backups until they rotate out of the retention window. Backups are retained for
**[FILL IN: e.g. 30 days]** and are not restored selectively; an erased subject
is removed from backups by normal rotation within that window. This is an
accepted approach under ICO guidance provided the window is documented and
backups are not used to repopulate live data.

## Subject rights handling

- **Right of Access / Portability (Art. 15 & 20)** — a manager exports the full
  per-subject bundle as JSON via the student detail screen
  (`GET /admin/students/{id}/export`). The access is itself logged
  (`user_data_exported`).
- **Right to Erasure (Art. 17)** — a manager triggers erasure from the same
  screen (`DELETE /admin/students/{id}`), logged as `user_erased`.
- **Statutory response time** — **one calendar month** from request.

> **Note:** Items in **[FILL IN]** are operational decisions for the studio
> owner to confirm (backup window length, named DPO/contact). Everything else
> reflects what the code does today.
