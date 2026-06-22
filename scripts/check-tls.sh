#!/usr/bin/env bash
# End-to-end TLS smoke test for the local dev proxy.
#
# Asserts three things in order:
#   1. The reverse proxy is reachable on https://localhost:5443.
#   2. The certificate validates against the system trust store (no -k
#      needed). Catches the "I forgot to run mkcert -install" case.
#   3. The connection negotiates HTTP/2 (proves Caddy + TLS are doing
#      their job rather than falling back to HTTP/1.1).
#
# Skips with a clear message — exit 0 — when the proxy isn't running so
# CI / pre-push hooks can call it unconditionally without failing the
# developer who hasn't started the stack.

set -euo pipefail

URL="${TLS_CHECK_URL:-https://localhost:5443}"

# Probe step 1: is anything answering on the port? Use curl --connect-
# timeout to fail fast — the proxy is a local process; if it's not up
# in 2s it isn't up at all.
if ! curl --silent --output /dev/null --connect-timeout 2 \
     --max-time 5 "$URL" 2>/dev/null; then
  # Differentiate "not running" from "running but TLS broken" by retrying
  # WITHOUT cert validation. If --insecure works but the strict probe
  # didn't, that's a trust problem; if both fail, the proxy is down.
  if curl --silent --insecure --output /dev/null --connect-timeout 2 \
       --max-time 5 "$URL" 2>/dev/null; then
    echo "FAIL: proxy is up on $URL but the cert isn't trusted by the system."
    echo "      Run \`mkcert -install\` (once per machine) and restart the proxy."
    exit 1
  fi
  echo "SKIP: proxy not reachable at $URL — start it with \`make caddy\` or \`tilt up\`."
  exit 0
fi

# Probe step 2: HTTP/2 negotiation. curl reports the chosen protocol via
# `-w '%{http_version}'`. We accept 2 or 3 (HTTP/3 would also be a pass);
# fail on 1.x because that means Caddy didn't negotiate the upgrade.
proto=$(curl --silent --output /dev/null --connect-timeout 2 --max-time 5 \
        -w '%{http_version}' "$URL")
case "$proto" in
  2|3)
    : # ok
    ;;
  *)
    echo "FAIL: expected HTTP/2 or HTTP/3 from $URL, got $proto."
    echo "      Caddy should negotiate h2 by default on TLS endpoints."
    exit 1
    ;;
esac

# Probe step 3: the API path proxies through. Hit a public-ish route
# (`/api/v1/studio/config` requires auth; use the OPTIONS preflight as a
# proxy-reachability check since it returns 204 from the CORS middleware
# without needing a token).
api_status=$(curl --silent --output /dev/null --connect-timeout 2 --max-time 5 \
             -w '%{http_code}' \
             -X OPTIONS "$URL/api/v1/studio/config")
if [ "$api_status" != "204" ] && [ "$api_status" != "200" ]; then
  echo "FAIL: API proxy returned $api_status on OPTIONS /api/v1/studio/config."
  echo "      Expected 204 (CORS preflight) or 200. Is yoga-server up?"
  exit 1
fi

echo "OK: $URL is up, cert trusted, HTTP/$proto, API proxy reachable."
