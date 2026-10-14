#!/bin/sh
# Container entrypoint.
#
# When Litestream is configured (LITESTREAM_BUCKET set): restore the DB from
# object storage if the volume is empty (fresh machine / lost volume), apply the
# schema, then serve *under* litestream so every write is streamed to the
# backup. When it isn't configured, just migrate-then-serve (dev / pre-backup).
#
# -migrate runs here (not as a Fly release_command) so the /data volume is
# guaranteed mounted when the migration writes.
set -e

DB="${DB_PATH:-/data/prod.db}"
LS_CONFIG="/etc/litestream.yml"

if [ -n "${LITESTREAM_BUCKET:-}" ]; then
  # Restore only if there's no local DB yet AND a replica exists — a brand-new
  # studio with no backup yet is a clean no-op.
  litestream restore -if-db-not-exists -if-replica-exists -config "$LS_CONFIG" "$DB"
  /app/server -migrate -db "$DB"
  exec litestream replicate -config "$LS_CONFIG" -exec "/app/server -db $DB -addr :8080"
else
  /app/server -migrate -db "$DB"
  exec /app/server -db "$DB" -addr :8080
fi
