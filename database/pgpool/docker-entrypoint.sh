#!/usr/bin/env bash
set -euo pipefail

# ── Clean up stale PID files from previous runs ───────────────────────────
rm -f /tmp/pgpool.pid /var/run/pgpool/pgpool.pid

exec "$@"
