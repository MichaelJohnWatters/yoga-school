# Dev convenience targets.
#
# To boot the full stack you need two shells:
#   make firebase   — Firebase Auth emulator (:9099, UI on :4000)
#   make go         — wipes the DB, seeds the DB + Firebase, runs the API on :8080
#   make flutter    — Flutter web app on :5173 (a third shell)
#
# `make go` requires the emulator to be running already (it seeds users into it).
#
# Test accounts (created by `make go`):
#   maya@studio52.dev  / dev123456   (student)
#   priya@studio52.dev / dev123456   (manager)
# The sign-in screen has a dev dropdown that populates these for you.

.PHONY: go flutter firebase seed-firebase reset analyze check-leaks check-tls caddy macos

# Firebase CLI requires Node ≥ 20.
NODE_BIN := $(HOME)/.nvm/versions/node/v20.20.1/bin

go:
	rm -f server/dev.db
	cd server && go run ./cmd/server -migrate -seed
	./scripts/seed-firebase-users.sh
	cd server && FIREBASE_AUTH_EMULATOR_HOST=localhost:9099 \
		FIREBASE_PROJECT_ID=yoga-school-dev \
		go run ./cmd/server -addr :8080

flutter:
	cd app && flutter run -d chrome --web-port 5173

firebase:
	PATH=$(NODE_BIN):$$PATH firebase emulators:start --only auth --project yoga-school-dev

seed-firebase:
	./scripts/seed-firebase-users.sh

reset:
	rm -f server/dev.db
	cd server && go run ./cmd/server -migrate -seed

analyze:
	cd app && flutter analyze

# Guard against patterns that leak raw DB / framework errors into API
# responses or onto user-facing UI. See scripts/check-error-leaks.sh for
# the rule set. Add to CI alongside `make analyze` so a regression fails
# the pipeline rather than landing silently.
check-leaks:
	./scripts/check-error-leaks.sh

# Local HTTPS reverse proxy. Requires `brew install mkcert caddy &&
# mkcert -install` once per machine, then `(cd dev-certs && mkcert
# localhost 127.0.0.1 ::1)` once per checkout. App URL becomes
# https://localhost:5443 — same origin for API + Flutter, no CORS.
caddy:
	@test -f dev-certs/localhost+2.pem || { \
		echo "Missing dev-certs/localhost+2.pem — generate with:"; \
		echo "  mkdir -p dev-certs && (cd dev-certs && mkcert localhost 127.0.0.1 ::1)"; \
		exit 1; \
	}
	caddy run --config Caddyfile.dev --adapter caddyfile

# End-to-end TLS smoke test: cert trusted by the system + HTTPS endpoint
# reachable through the proxy + HTTP/2 negotiated. Skips with a clear
# message if the proxy isn't running so CI can call it unconditionally.
check-tls:
	./scripts/check-tls.sh

macos:
	cd app && flutter run -d macos
