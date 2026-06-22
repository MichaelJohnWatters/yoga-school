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

.PHONY: go flutter firebase seed-firebase reset analyze check-leaks macos

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

macos:
	cd app && flutter run -d macos
