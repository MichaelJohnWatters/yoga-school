#!/usr/bin/env bash
# Seed the running Firebase Auth emulator with the dev users our DB knows
# about. Idempotent: if a user already exists, we move on.
#
# Requires the emulator to be running:  make firebase

set -euo pipefail

EMU_HOST="${FIREBASE_AUTH_EMULATOR_HOST:-localhost:9099}"
PROJECT_ID="${PROJECT_ID:-yoga-school-dev}"
# Any non-empty string works for the emulator — it never validates the key.
API_KEY="${FIREBASE_API_KEY:-fake-api-key}"

create_user() {
  local email="$1"
  local password="$2"
  local name="$3"

  # signUp creates an account + immediately signs in. We don't care about the
  # token here — we just want the user to exist so the Flutter app can sign in
  # next time with the same email/password.
  local resp
  resp=$(curl -s -X POST \
    "http://${EMU_HOST}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${email}\",\"password\":\"${password}\",\"returnSecureToken\":true}")

  if echo "$resp" | grep -q '"localId"'; then
    local uid
    uid=$(echo "$resp" | sed -E 's/.*"localId":"([^"]+)".*/\1/')
    echo "  + ${name} (${email}) — created uid=${uid}"
  elif echo "$resp" | grep -q 'EMAIL_EXISTS'; then
    echo "  · ${name} (${email}) — already exists"
  else
    echo "  ! ${name} (${email}) — unexpected response:"
    echo "$resp"
    return 1
  fi
}

# Wait until the emulator is up (give it ~20s).
echo "waiting for emulator at ${EMU_HOST}..."
for i in {1..20}; do
  if curl -sf "http://${EMU_HOST}/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "seeding Firebase users in project ${PROJECT_ID}:"
create_user "maya@studio52.dev"  "dev123456" "Maya (student · unlimited)"
create_user "priya@studio52.dev" "dev123456" "Priya (manager)"
# Instructors — DB seed in seed.go already inserts these as users with
# role=instructor; Firebase Auth accounts here let them actually log in
# and exercise the staff-tier routes (schedule read, roster, attendance,
# scan check-in). Without these the instructor flow is untestable.
create_user "asha@studio52.dev"  "dev123456" "Asha (instructor)"
create_user "jonas@studio52.dev" "dev123456" "Jonas (instructor)"
create_user "mara@studio52.dev"  "dev123456" "Mara (instructor)"
# Community students — covers the main pass-shape permutations so dev
# testing can hit each booking/wallet code path. Same password as Maya.
# (See seed.go for the per-student pass configuration that backs these.)
create_user "aria.lin@studio52.dev"     "dev123456" "Aria (multi-pass: 10-pack + new unlimited)"
create_user "ben.carter@studio52.dev"   "dev123456" "Ben (unlimited + reformer pack)"
create_user "chen.wei@studio52.dev"     "dev123456" "Chen (reformer-only, 2/5)"
create_user "diego.rivera@studio52.dev" "dev123456" "Diego (drop-in, no credits left)"
create_user "grace.okoye@studio52.dev"  "dev123456" "Grace (yoga 5-pack, 4/5 credits)"
create_user "ivy.nakamura@studio52.dev" "dev123456" "Ivy (10-pack + reformer pack)"
create_user "kira.walker@studio52.dev"  "dev123456" "Kira (current 10-pack + depleted past)"
echo "done."
