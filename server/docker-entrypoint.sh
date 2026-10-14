#!/bin/sh
# Container entrypoint: apply the schema (idempotent — CREATE TABLE IF NOT
# EXISTS) against the SQLite file on the mounted volume, then serve. Running
# -migrate here (not as a Fly release_command) guarantees the volume at /data is
# mounted when migration writes. M4 wraps this with Litestream for backups.
set -e

DB="${DB_PATH:-/data/prod.db}"

/app/server -migrate -db "$DB"
exec /app/server -db "$DB" -addr :8080
