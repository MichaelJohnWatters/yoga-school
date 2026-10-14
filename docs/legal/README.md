# Legal pages

The user-facing Privacy Policy and Terms of Service live as static HTML so they
can be served directly to users:

- `app/web/privacy.html` → served at `/privacy.html`
- `app/web/terms.html` → served at `/terms.html`

They're copied into `app/build/web` by `flutter build web` and served by Firebase
Hosting (real files resolve before the SPA rewrite). The sign-in screen links to
them (acceptance-at-signup). Single source — edit the HTML, not a duplicate.

> **DRAFT.** Both documents are drafts, not legal advice. Before taking real
> customers: have a solicitor review them, replace every `[bracketed]` field
> (studio name, address, DP contact, date), and confirm the retention summary
> matches `../data-retention.md`.
