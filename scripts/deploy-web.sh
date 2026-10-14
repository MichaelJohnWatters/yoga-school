#!/usr/bin/env bash
# Build the Flutter web app pointed at this studio's API, then deploy it to
# Firebase Hosting.
#
# Required env:
#   API_BASE_URL      this studio's API origin + /api/v1
#                     e.g. https://yoga-bloom.fly.dev/api/v1
#   FIREBASE_PROJECT  the studio's Firebase project id
#
# The real firebase_options.dart for the project must already be in place
# (app/lib/src/firebase_options.dart) — the committed one is an emulator
# placeholder.
set -euo pipefail

: "${API_BASE_URL:?set API_BASE_URL=https://<fly-app>/api/v1}"
: "${FIREBASE_PROJECT:?set FIREBASE_PROJECT=<firebase project id>}"

cd "$(dirname "$0")/.."

( cd app && flutter build web --release --dart-define=API_BASE_URL="$API_BASE_URL" )
exec firebase deploy --only hosting --project "$FIREBASE_PROJECT"
