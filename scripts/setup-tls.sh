#!/usr/bin/env bash
# Idempotent local TLS setup. Called from yoga-bootstrap so a fresh
# checkout (or a `tilt trigger yoga-bootstrap` after a wipe) lands in
# a runnable state without manual steps.
#
# Behaviour:
#   - mkcert installed + cert exists  → skip, print "already present".
#   - mkcert installed + cert missing → generate dev-certs/localhost+2.pem.
#   - mkcert missing                  → warn, exit 0 (don't fail bootstrap;
#                                       the HTTPS proxy just won't work
#                                       until the contributor installs it).
#   - caddy missing                   → warn (same logic — informational).
#
# Always exits 0. The yoga-caddy Tilt resource has its own runtime skip
# path for missing tools, so this script is purely about preparing
# the artifacts. Failing the bootstrap on a missing optional binary
# would block DB-only work, which isn't the trade-off we want.

set -euo pipefail

if ! command -v mkcert >/dev/null 2>&1; then
    echo "warning: mkcert missing — \`brew install mkcert && mkcert -install\` (HTTPS proxy will be skipped)"
elif [ ! -f dev-certs/localhost+2.pem ]; then
    echo "generating local TLS cert via mkcert..."
    mkdir -p dev-certs
    (cd dev-certs && mkcert localhost 127.0.0.1 ::1)
else
    echo "TLS cert already present in dev-certs/ — skipping"
fi

if ! command -v caddy >/dev/null 2>&1; then
    echo "warning: caddy missing — \`brew install caddy\` (yoga-caddy resource will idle until installed)"
fi
