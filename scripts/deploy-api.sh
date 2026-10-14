#!/usr/bin/env bash
# Deploy one studio's Go API to Fly.io. Run from anywhere; uses the repo-root
# fly.toml. Assumes `fly` is authenticated and the app/volume/secrets exist
# (see the fly.toml header for first-time setup).
set -euo pipefail
cd "$(dirname "$0")/.."
exec fly deploy "$@"
