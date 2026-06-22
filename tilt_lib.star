# Yoga School dev stack — Firebase Auth emulator, Go API, Flutter app.
#
# Uses default Firebase ports (9099/4000). Server lives under server/, so
# Go commands chain an extra `cd server` after the root cd.

def yoga_resources(root='.'):
    cd = 'cd ' + root + ' && '
    server_cd = cd + 'cd server && '

    node_bin = os.getenv('HOME', '') + '/.nvm/versions/node/v20.20.1/bin'

    local_resource(
        'yoga-firebase',
        serve_cmd=cd + 'PATH=' + node_bin + ':$PATH firebase emulators:start --only auth --project yoga-school-dev',
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

    local_resource(
        'yoga-server',
        serve_cmd=server_cd + 'FIREBASE_AUTH_EMULATOR_HOST=localhost:9099 FIREBASE_PROJECT_ID=yoga-school-dev go run ./cmd/server -addr :8080',
        resource_deps=['yoga-firebase'],
        labels=['yoga-school'],
        links=[link('http://localhost:8080', 'API')],
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

    # Full reset: ensure local TLS cert exists, disable server (releases
    # its DB locks), wipe DB, run migrate + DB seed, seed Firebase users,
    # then re-enable server + app. The TLS step is idempotent — the cert
    # only regenerates when it's missing — so a fresh checkout becomes
    # one click in the Tilt UI to land in a runnable state.
    local_resource(
        'yoga-bootstrap',
        cmd=' && '.join([
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
            '(cd server && go run ./cmd/server -migrate -seed)',
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
        ]),
        resource_deps=['yoga-firebase'],
        labels=['yoga-school'],
        trigger_mode=TRIGGER_MODE_MANUAL,
        auto_init=False,
    )
