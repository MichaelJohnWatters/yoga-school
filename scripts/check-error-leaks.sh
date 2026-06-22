#!/usr/bin/env bash
# Refuse to ship code that bypasses the error-sanitization layer.
#
# Three patterns are forbidden:
#   1. writeError(w, status, err.Error())  —  server-side raw leak. Use
#      respondErr or respondValidation instead.
#   2. fmt.Sprintf("...: %v", err) inside a BookingError / ScanError /
#      similar — server-side message wrapping leak. Return a typed
#      sentinel and let mapStoreError convert it.
#   3. '...: $e' interpolation in Dart catch blocks — client-side leak.
#      Use ApiError.fromAny(e).message instead.
#
# Run via `make check-leaks` or wire into CI. Exits non-zero on any
# match, prints the offending lines so the failure is actionable.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
status=0

# ---------- Server: writeError(..., err.Error()) ----------
# Allow-list: errors.go itself (defines the helpers and may reference err.Error
# in its own diagnostics) and *_test.go (tests assert on error texts).
go_leaks=$(grep -rn 'writeError(.*err\.Error()' "$ROOT/server/internal" \
  --include='*.go' \
  --exclude='errors.go' \
  --exclude='*_test.go' || true)
if [ -n "$go_leaks" ]; then
  echo "FAIL: server still has writeError(..., err.Error()) — use respondErr / respondValidation."
  echo "$go_leaks"
  status=1
fi

# ---------- Server: BookingError{Message: fmt.Sprintf("...", err)} ----------
sprintf_leaks=$(grep -rn 'Message:[[:space:]]*fmt\.Sprintf' "$ROOT/server/internal" \
  --include='*.go' \
  --exclude='*_test.go' \
  | grep -E '%[vws]' \
  | grep -E ', err\b|, e\.|, [a-z]+Err\b' || true)
if [ -n "$sprintf_leaks" ]; then
  echo "FAIL: server wraps raw error into a user-facing Message field — return a typed sentinel instead."
  echo "$sprintf_leaks"
  status=1
fi

# ---------- App: ': $e' interpolation ----------
# Allow-list: api_error.dart (defines fromAny), error_display.dart (renders
# debug), and *_test.dart.
dart_leaks=$(grep -rn ': \$e[^a-zA-Z_]' "$ROOT/app/lib" \
  --include='*.dart' \
  --exclude='api_error.dart' \
  --exclude='error_display.dart' || true)
if [ -n "$dart_leaks" ]; then
  echo "FAIL: client interpolates raw \$e — use ApiError.fromAny(e).message."
  echo "$dart_leaks"
  status=1
fi

# Bare \$e at the start of an interpolation (e.g. _error = '$e'; or Text('$e'))
bare_dollar=$(grep -rn "'\\\$e'" "$ROOT/app/lib" \
  --include='*.dart' \
  --exclude='api_error.dart' \
  --exclude='error_display.dart' || true)
if [ -n "$bare_dollar" ]; then
  echo "FAIL: client renders raw '\$e' — use ApiError.fromAny(e).message."
  echo "$bare_dollar"
  status=1
fi

if [ $status -eq 0 ]; then
  echo "OK: no error-leak patterns found."
fi
exit $status
