#!/usr/bin/env bash
# Runs in the root phase of the stock postgres entrypoint: fix ownership of
# the shared archive volume (fresh named volumes are root-owned), then hand
# off to the real docker-entrypoint.sh unchanged.
set -euo pipefail
mkdir -p /wal_archive
chown -R postgres:postgres /wal_archive
chmod 700 /wal_archive
exec docker-entrypoint.sh "$@"
