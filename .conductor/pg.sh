#!/usr/bin/env bash
# Shared Postgres helpers for Conductor Cloud workspaces (Amazon Linux 2023).
# Sourced by setup.sh and cloud-snapshot-init.sh. Local macOS workspaces never
# use this — they connect to whatever Postgres the developer is already running
# (typically Postgres.app on localhost:5432).

# Resolve a Postgres binary across common dnf and apt package layouts.
pg_bin() {
  local binary="$1"
  command -v "$binary" 2>/dev/null && return 0
  for d in /usr/bin /usr/pgsql-*/bin /usr/lib/postgresql/*/bin; do
    [ -x "$d/$binary" ] && {
      echo "$d/$binary"
      return 0
    }
  done
  echo "$binary"
  return 1
}

PGDATA="${PGDATA:-$HOME/.local/share/conductor-postgres/data}"
export PGDATA
PGSOCKET_DIR="${PGSOCKET_DIR:-$HOME/.local/share/conductor-postgres/run}"
export PGSOCKET_DIR

# Start the server if it is not already running (snapshots bake the data dir, but the
# process must be (re)launched in each forked workspace).
ensure_pg_running() {
  local pg_ctl
  pg_ctl="$(pg_bin pg_ctl)"
  mkdir -p "$PGSOCKET_DIR"
  "$pg_ctl" -D "$PGDATA" status >/dev/null 2>&1 ||
    "$pg_ctl" -D "$PGDATA" -l "$PGDATA/server.log" -w start
}
