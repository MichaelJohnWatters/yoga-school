#!/usr/bin/env bash
# Point the dev studio (s52) at the Stripe test keys in repo-root .env via the
# dev-only /dev/configure-stripe endpoint, so manual testing skips the
# manager-UI key-paste step.
#
# Self-skips (exit 0) when keys are absent, so it never fails a bootstrap.
# Requires the server running with STRIPE_KEY_ENC_MASTER set (so it can encrypt
# the secret) — the Tilt yoga-server resource sources .env for exactly that.
#
# Reads from .env (with fallbacks):
#   STRIPE_TEST_SK  | STRIPE_SECRET_KEY        sk_test_…
#   STRIPE_TEST_PK  | STRIPE_PUBLISHABLE_KEY   pk_test_…
#   STRIPE_WEBHOOK_SECRET                      whsec_… (from `stripe listen`)
#
# Usage: scripts/configure-stripe-dev.sh [base_url]   (default http://localhost:8080)

BASE="${1:-http://localhost:8080}"

# Resolve .env relative to this script (yoga-school root), not the caller's
# CWD — the bootstrap invokes us from the toolkit monorepo root, which has a
# different .env without the yoga Stripe keys. Anchoring to the script keeps
# the lookup deterministic wherever it's run from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

SK="${STRIPE_TEST_SK:-${STRIPE_SECRET_KEY:-}}"
PK="${STRIPE_TEST_PK:-${STRIPE_PUBLISHABLE_KEY:-}}"
WH="${STRIPE_WEBHOOK_SECRET:-}"

if [ -z "$SK" ] || [ -z "$PK" ]; then
  echo "configure-stripe-dev: no Stripe keys in .env — s52 stays in dev_stub mode"
  exit 0
fi

# The bootstrap re-enables the server asynchronously, and Tilt starts it with a
# cold `go run` — a full recompile that can take well over a minute on a fresh
# build cache (and grows with the codebase). Wait generously for /healthz so we
# don't POST into a not-yet-listening server (HTTP 000). 180s headroom.
for _ in $(seq 1 180); do
  if curl -sf "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done

# Retry the POST a few times: during a bootstrap the server can answer
# /healthz before it's finished wiring the Stripe gateway, so a single shot
# races the startup. Capture the status + body so a real failure is legible
# instead of a blanket "FAILED".
body_file="$(mktemp)"
code=""
for _ in $(seq 1 30); do
  code="$(curl -s -o "$body_file" -w '%{http_code}' -X POST "$BASE/dev/configure-stripe" \
    -H 'Content-Type: application/json' \
    -d "{\"studio_id\":\"s52\",\"secret_key\":\"$SK\",\"publishable_key\":\"$PK\",\"webhook_secret\":\"$WH\"}")"
  case "$code" in 2*) break ;; esac
  sleep 1
done

case "$code" in
  2*)
    if [ -n "$WH" ]; then
      echo "configure-stripe-dev: s52 configured (webhook secret set)"
    else
      echo "configure-stripe-dev: s52 configured — set the webhook secret after 'stripe listen' (manager Settings or STRIPE_WEBHOOK_SECRET in .env)"
    fi
    ;;
  ""|000)
    # 000 = curl connected to nothing / no HTTP response (server not listening yet), NOT an auth
    # or encryption problem — so don't send people chasing STRIPE_KEY_ENC_MASTER.
    echo "configure-stripe-dev: FAILED — could not reach $BASE (is yoga-server up?)"
    ;;
  *)
    echo "configure-stripe-dev: FAILED — HTTP $code from /dev/configure-stripe"
    echo "  response: $(cat "$body_file" 2>/dev/null)"
    echo "  (is STRIPE_KEY_ENC_MASTER set in .env so the server can encrypt secrets?)"
    ;;
esac
rm -f "$body_file"
exit 0
