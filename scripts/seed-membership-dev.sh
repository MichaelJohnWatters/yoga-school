#!/usr/bin/env bash
# Create a real Stripe *test-mode* membership for a seeded student (Maya) via the
# dev-only /dev/seed-membership endpoint, so dev exercises real Stripe rather
# than placeholder subscription rows. The invoice.paid webhook fulfils it, so
# this must run after configure-stripe AND with `stripe listen` forwarding.
#
# Self-skips (exit 0) when no Stripe keys are in .env — no keys, no real sub.
#
# Usage: scripts/seed-membership-dev.sh [base_url]   (default http://localhost:8080)

BASE="${1:-http://localhost:8080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

SK="${STRIPE_TEST_SK:-${STRIPE_SECRET_KEY:-}}"
if [ -z "$SK" ]; then
  echo "seed-membership-dev: no Stripe keys in .env — skipping (no real subscription)"
  exit 0
fi

# Server may still be compiling (cold `go run`); wait for /healthz.
for _ in $(seq 1 180); do
  if curl -sf "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done

body_file="$(mktemp)"
code=""
# Retry: the server can answer /healthz before the Stripe gateway + keys are
# wired (configure-stripe runs just before us).
for _ in $(seq 1 30); do
  code="$(curl -s -o "$body_file" -w '%{http_code}' -X POST "$BASE/dev/seed-membership" \
    -H 'Content-Type: application/json' \
    -d '{"studio_id":"s52","email":"maya@studio52.dev"}')"
  case "$code" in 2*) break ;; esac
  sleep 1
done

case "$code" in
  2*) echo "seed-membership-dev: real test membership created for maya@studio52.dev (webhook will fulfil it)" ;;
  ""|000) echo "seed-membership-dev: FAILED — could not reach $BASE (is yoga-server up?)" ;;
  *)
    echo "seed-membership-dev: FAILED — HTTP $code from /dev/seed-membership"
    echo "  response: $(cat "$body_file" 2>/dev/null)"
    echo "  (is Stripe configured for s52? run yoga-configure-stripe first)"
    ;;
esac
rm -f "$body_file"
exit 0
