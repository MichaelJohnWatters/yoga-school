# Yoga School dev stack — Firebase Auth + Storage emulators, Go API, Flutter app.
#
# Uses default Firebase ports (auth 9099, storage 9199, UI 4000). Server lives
# under server/, so Go commands chain an extra `cd server` after the root cd.

def yoga_resources(root='.'):
    cd = 'cd ' + root + ' && '
    server_cd = cd + 'cd server && '

    node_bin = os.getenv('HOME', '') + '/.nvm/versions/node/v20.20.1/bin'

    # Source repo-root .env (Stripe keys + STRIPE_KEY_ENC_MASTER) into a
    # resource's shell when present. Tilt doesn't auto-load .env; `set -a`
    # exports every var so `go run` / `flutter test` inherit them. A missing
    # .env is a no-op (current behaviour — Stripe stays disabled).
    dotenv = 'set -a; [ -f .env ] && . ./.env; set +a; '

    local_resource(
        'yoga-firebase',
        serve_cmd=cd + 'PATH=' + node_bin + ':$PATH firebase emulators:start --only auth,storage --project yoga-school-dev',
        labels=['yoga-school'],
        links=[link('http://localhost:4000', 'Emulator UI')],
        readiness_probe=probe(
            period_secs=2,
            tcp_socket=tcp_socket_action(port=9099),
        ),
    )

    local_resource(
        'yoga-clean-db',
        cmd=cd + 'rm -f server/dev.db',
        labels=['yoga-school'],
        trigger_mode=TRIGGER_MODE_MANUAL,
        auto_init=False,
    )

    local_resource(
        'yoga-firebase-seed',
        cmd=cd + './scripts/seed-firebase-users.sh',
        resource_deps=['yoga-firebase'],
        labels=['yoga-school'],
        trigger_mode=TRIGGER_MODE_MANUAL,
        auto_init=False,
    )

    # .env is sourced first so STRIPE_KEY_ENC_MASTER (when set) enables the
    # Stripe payment gateway — without it the server runs in dev_stub mode, the
    # same as before. A malformed master key makes the server refuse to boot by
    # design (the prod-parity guard in SealerFromEnv).
    local_resource(
        'yoga-server',
        serve_cmd=cd + dotenv + 'cd server && FIREBASE_AUTH_EMULATOR_HOST=localhost:9099 FIREBASE_PROJECT_ID=yoga-school-dev FIREBASE_STORAGE_BUCKET=yoga-school-dev.appspot.com STORAGE_EMULATOR_HOST=localhost:9199 MEDIA_PUBLIC_URL_BASE=https://localhost:5443 go run ./cmd/server -addr :8080',
        resource_deps=['yoga-firebase'],
        labels=['yoga-school'],
        links=[link('http://localhost:8080', 'API')],
        # Tilt serializes local_resource updates by default. The bootstrap-*-with-stripe chain
        # ends with configure-stripe-dev.sh, which blocks waiting for this server's /healthz — but
        # a serialized server can't start until that chain finishes, so it deadlocks (server never
        # comes up, configure-stripe times out). allow_parallel lets the server boot *during* the
        # bootstrap so the /healthz wait succeeds.
        allow_parallel=True,
    )

    # --pid-file lets the hotreload watcher (below) signal this process on
    # dart file changes. SIGUSR1 = hot reload, SIGUSR2 = hot restart. We
    # use SIGUSR2 — Flutter web's hot-reload pipeline (DDC) is flaky from
    # signals; restart reliably refreshes the Chrome tab. Widget state
    # loss is fine for an admin tool with no transient client state.
    #
    # --web-header forces no-store on every dev-server response. Without
    # it, Chrome aggressively caches the Flutter JS chunks and the user
    # has to DevTools → Application → Clear storage → hard reload after
    # every yoga-bootstrap, because the tab still has the old chunks while
    # the seed wiped Firebase/DB underneath.
    #
    # --web-browser-flag=--disable-web-security turns CORS off in the dev
    # Chrome instance. Seed avatars come from i.pravatar.cc, which doesn't
    # send Access-Control-Allow-Origin, so Flutter's NetworkImage (XHR-
    # based on web) is blocked. Flutter launches Chrome with its own
    # temporary --user-data-dir, so this stays sandboxed to the dev tab
    # and never touches the user's real Chrome profile.
    #
    # --no-track-widget-creation kills a known Flutter-web/DDC bug where
    # debugTransformDebugCreator throws a "LegacyJavaScriptObject is not
    # a subtype of DiagnosticsNode" cast failure inside the error
    # reporter, which then triggers another error in the reporter,
    # spamming the console with thousands of identical stack traces and
    # burying any real error. The tradeoff is losing "tap to inspect
    # widget" in DevTools, which is already flaky on web.
    local_resource(
        'yoga-app',
        serve_cmd=cd + 'cd app && flutter run -d chrome --web-port 5173 ' +
                  '--web-header=Cache-Control=no-store ' +
                  '--web-browser-flag=--disable-web-security ' +
                  '--no-track-widget-creation ' +
                  '--pid-file=/tmp/yoga-flutter.pid',
        resource_deps=['yoga-server'],
        labels=['yoga-school'],
        links=[link('http://localhost:5173', 'App')],
        trigger_mode=TRIGGER_MODE_MANUAL,
        auto_init=False,
    )

    # Local HTTPS reverse proxy. Same-origin for API + Flutter on a real
    # TLS cert (mkcert-signed), which closes the dev/prod gap on cookies,
    # service workers, HTTP/2, etc. AND removes the per-request OPTIONS
    # preflight chatter you see in the Go logs today.
    #
    # No resource_deps so caddy comes up immediately — it'll 502 the
    # individual proxied paths until yoga-server / yoga-app are ready,
    # which is the expected behaviour while the stack boots.
    #
    # Auto-skip when caddy isn't installed: the serve_cmd checks and
    # exits 0 with a helpful message so a fresh checkout doesn't fail
    # the whole `tilt up` over a missing optional binary.
    local_resource(
        'yoga-caddy',
        serve_cmd=cd + '''
if ! command -v caddy >/dev/null 2>&1; then
  echo "caddy not installed — skip (brew install caddy mkcert && mkcert -install)"
  echo "App still works on http://localhost:5173 + http://localhost:8080"
  sleep 86400  # keep the resource alive so Tilt doesn't loop-restart
  exit 0
fi
if [ ! -f dev-certs/localhost+2.pem ]; then
  echo "missing dev-certs/localhost+2.pem — run:"
  echo "  mkdir -p dev-certs && (cd dev-certs && mkcert localhost 127.0.0.1 ::1)"
  sleep 86400
  exit 0
fi
exec caddy run --config Caddyfile.dev --adapter caddyfile
''',
        labels=['yoga-school'],
        links=[link('https://localhost:5443', 'App (HTTPS)')],
    )

    # Always exits 0 so Tilt doesn't flag "Build Failed" when the app
    # isn't running or the PID file is mid-write. The script:
    #   - skips if the PID file is missing or empty (flutter starting),
    #   - skips if the PID is stale (process gone — yoga-app was
    #     stopped without cleaning up /tmp/),
    #   - sends SIGUSR2 otherwise and reports success.
    local_resource(
        'yoga-hotreload',
        cmd='''
PID_FILE=/tmp/yoga-flutter.pid
if [ ! -s "$PID_FILE" ]; then
  echo "yoga-app not running — nothing to reload"
  exit 0
fi
PID=$(cat "$PID_FILE")
if ! kill -0 "$PID" 2>/dev/null; then
  echo "stale PID $PID in $PID_FILE — re-trigger yoga-app"
  exit 0
fi
# macOS /bin/sh rejects the GNU "-SIGUSR2" alias; -USR2 is the POSIX
# form and works in bash, zsh and sh.
if kill -USR2 "$PID" 2>/dev/null; then
  echo "hot restart sent to PID $PID"
else
  echo "could not signal PID $PID"
fi
exit 0
''',
        deps=[root + '/app/lib'],
        labels=['yoga-school'],
    )

    # Full reset, one click in the Tilt UI: ensure local TLS cert exists,
    # disable server (releases its DB locks), wipe DB, run migrate + seed,
    # seed Firebase users, then re-enable server + app. The TLS step is
    # idempotent — the cert only regenerates when missing — so a fresh
    # checkout becomes one button to land in a runnable state.
    #
    # The chain is parameterised by the seed step. Two flavours share it,
    # differing only in how the DB is populated:
    #   yoga-bootstrap      → `-seed`          (fast all-SQL fixture seed)
    #   yoga-bootstrap-api  → `-bootstrap-api` (audited, method-driven seed —
    #                         real audit_log rows, richer/realistic data, and a
    #                         skipped-steps summary printed at the end)
    def _bootstrap_cmd(seed_flags):
        return ' && '.join([
            # cd once at the top of the chain — every following step
            # then uses relative paths (`rm`, `scripts/...`, `server/`).
            # The previous shape re-`cd`'d before `rm`, which became a
            # bug as soon as another `cd + cmd` joined the chain and the
            # second cd resolved relative to the first cd's destination.
            #
            # Idempotent local TLS prep (cert generation + tool checks).
            # Lives in a script rather than inline so the multi-line
            # if/elif/else doesn't collide with the surrounding `&&`
            # chain — the inline form trips a shell parse error.
            cd + './scripts/setup-tls.sh',
            # Disable caddy alongside the server + app so when we
            # re-enable below, the proxy process restarts too. That's
            # the one path that picks up Caddyfile.dev changes (Caddy
            # doesn't hot-reload from disk), so "one-button bootstrap"
            # is also "one-button proxy refresh".
            'tilt disable yoga-server yoga-app yoga-caddy',
            'rm -f server/dev.db server/dev.db-wal server/dev.db-shm',
            # Storage env lets the bootstrap-api seed populate the media
            # library through the real upload path (skips cleanly otherwise).
            '(cd server && FIREBASE_PROJECT_ID=yoga-school-dev FIREBASE_STORAGE_BUCKET=yoga-school-dev.appspot.com STORAGE_EMULATOR_HOST=localhost:9199 MEDIA_PUBLIC_URL_BASE=https://localhost:5443 go run ./cmd/server -migrate ' + seed_flags + ')',
            './scripts/seed-firebase-users.sh',
            'tilt enable yoga-server',
            'tilt enable yoga-app',
            'tilt enable yoga-caddy',
            # Manual-trigger resources need an explicit kick after enable.
            # `tilt enable` is async — the state change is queued but not
            # yet visible to `tilt trigger`, which 1-shots into a disabled
            # resource. Retry the trigger for a few seconds so the bootstrap
            # doesn't fail on the race.
            'for i in 1 2 3 4 5 6 7 8 9 10; do tilt trigger yoga-app 2>/dev/null && break; sleep 0.5; done',
        ])

    local_resource(
        'yoga-bootstrap',
        cmd=_bootstrap_cmd('-seed'),
        resource_deps=['yoga-firebase'],
        labels=['yoga-school'],
        trigger_mode=TRIGGER_MODE_MANUAL,
        auto_init=False,
    )

    local_resource(
        'yoga-bootstrap-api',
        cmd=_bootstrap_cmd('-bootstrap-api'),
        resource_deps=['yoga-firebase'],
        labels=['yoga-school'],
        trigger_mode=TRIGGER_MODE_MANUAL,
        auto_init=False,
    )

    # Same as yoga-bootstrap-api, then points studio s52 at the Stripe test keys
    # from .env (via /dev/configure-stripe) so you can manually test the real
    # Checkout flow without pasting keys in the manager UI. The Stripe step
    # self-skips when .env has no keys. You still run `stripe listen` yourself
    # for webhook delivery (set STRIPE_WEBHOOK_SECRET in .env to wire that too).
    local_resource(
        'yoga-bootstrap-api-with-stripe',
        cmd=_bootstrap_cmd('-bootstrap-api') + ' && ./scripts/configure-stripe-dev.sh',
        resource_deps=['yoga-firebase'],
        labels=['yoga-school'],
        trigger_mode=TRIGGER_MODE_MANUAL,
        auto_init=False,
    )

    # Stripe webhook delivery — always on (Stripe is mandatory; the web hosted
    # Checkout flow mints the pass via the checkout.session.completed webhook).
    # Forwards straight to the Go server (:8080) — NOT through Caddy, which
    # routes /stripe/* to the Flutter app. The studio path is s52 (the dev
    # studio). One-time setup: `stripe login`, then put the signing secret from
    # `stripe listen --print-secret` into .env as STRIPE_WEBHOOK_SECRET so
    # configure-stripe-dev.sh wires it onto the studio.
    local_resource(
        'yoga-stripe-webhook',
        serve_cmd=cd + 'stripe listen --forward-to localhost:8080/stripe/webhook/s52',
        resource_deps=['yoga-server'],
        labels=['yoga-school'],
    )

    # --- Stripe e2e tests (manual one-shots) ------------------------------
    #
    # Both read keys from repo-root .env and self-skip when the relevant key
    # is absent, so a click never hard-fails on a fresh checkout.

    # Go full-fulfilment e2e: real money→pass round-trip against Stripe test
    # mode (creates a PaymentIntent, confirms it with pm_card_visa via the
    # Stripe API, our ConfirmPurchase mints the pass, then a real refund).
    # Self-contained — needs no running stack. Behind the `stripe_e2e` build
    # tag so it's out of the normal suite; the test loads keys from .env (runs
    # for real when present, skips when absent). -count=1 defeats Go's test
    # cache so a click always re-runs.
    local_resource(
        'yoga-e2e-stripe-go',
        cmd=cd + 'cd server && go test -tags stripe_e2e -run StripeRealAPI ./internal/store/ -v -count=1',
        labels=['yoga-school'],
        trigger_mode=TRIGGER_MODE_MANUAL,
        auto_init=False,
    )

    # Flutter web hosted-Checkout e2e: drives the real UI (sign in → Buy →
    # Pay) and asserts a real checkout.stripe.com URL is produced. Needs the
    # stack up (server with STRIPE_KEY_ENC_MASTER, so it can store the studio's
    # keys via /dev/configure-stripe) + the test publishable/secret keys.
    # Web integration tests can't run via `flutter test -d chrome` ("web
    # devices are not supported"); they need `flutter drive` + chromedriver
    # against the headless web-server device. Start chromedriver, run the
    # drive, then clean it up — exiting with the test's own status.
    local_resource(
        'yoga-e2e-stripe-flutter',
        cmd=cd + dotenv + 'cd app || exit 1; ' +
            'chromedriver --port=4444 >/dev/null 2>&1 & CDPID=$!; sleep 1; ' +
            'flutter drive ' +
            '--driver=test_driver/integration_test.dart ' +
            '--target=integration_test/checkout_session_test.dart ' +
            '-d web-server --browser-name=chrome ' +
            '--dart-define=STRIPE_TEST_SK="${STRIPE_TEST_SK:-${STRIPE_SECRET_KEY:-}}" ' +
            '--dart-define=STRIPE_TEST_PK="${STRIPE_TEST_PK:-${STRIPE_PUBLISHABLE_KEY:-}}"; ' +
            'RC=$?; kill $CDPID 2>/dev/null; exit $RC',
        resource_deps=['yoga-server'],
        labels=['yoga-school'],
        trigger_mode=TRIGGER_MODE_MANUAL,
        auto_init=False,
    )
