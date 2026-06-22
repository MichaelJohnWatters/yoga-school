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

    # Full reset: disable server (releases its DB locks), wipe DB, run
    # migrate + DB seed, seed Firebase users, then re-enable server + app.
    local_resource(
        'yoga-bootstrap',
        cmd=' && '.join([
            'tilt disable yoga-server yoga-app',
            cd + 'rm -f server/dev.db server/dev.db-wal server/dev.db-shm',
            '(cd server && go run ./cmd/server -migrate -seed)',
            './scripts/seed-firebase-users.sh',
            'tilt enable yoga-server',
            'tilt enable yoga-app',
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
