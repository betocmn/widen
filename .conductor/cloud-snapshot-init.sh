#!/usr/bin/env bash
# Conductor Cloud snapshot build script. Set the app's
#   Settings -> Cloud -> Snapshots
# init script to:  bash .conductor/cloud-snapshot-init.sh
# It runs ONCE when the snapshot is built, and its result is baked
# into every forked workspace. Keep per-workspace work in setup.sh instead.
#
# Widen is a macOS-only Xcode app, so the cloud snapshot cannot run xcodebuild
# or execute the unit-test bundle. We still bake a native Postgres into the
# snapshot so that any Linux-buildable Swift package tests, or ad-hoc psql work,
# have a database to talk to.
set -euo pipefail

# Keep this file self-contained: Conductor Cloud may run its pasted contents
# against the remote default branch before helper files from this branch exist.

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

ensure_pg_running() {
  local pg_ctl
  pg_ctl="$(pg_bin pg_ctl)"
  mkdir -p "$PGSOCKET_DIR"
  "$pg_ctl" -D "$PGDATA" status >/dev/null 2>&1 ||
    "$pg_ctl" -D "$PGDATA" -l "$PGDATA/server.log" -w start
}

if ! pg_bin initdb >/dev/null 2>&1 || ! pg_bin pg_ctl >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y postgresql16-server postgresql16 || {
      sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
      sudo dnf -qy module disable postgresql || true
      sudo dnf install -y postgresql16-server postgresql16
    }
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-common
    sudo mkdir -p /etc/postgresql-common
    {
      echo "create_main_cluster = false"
      echo "start_conf = manual"
    } | sudo tee /etc/postgresql-common/createcluster.conf >/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-client
  else
    echo "Unable to install PostgreSQL: neither dnf nor apt-get is available." >&2
    exit 1
  fi
fi

INITDB="$(pg_bin initdb)"
CREATEDB="$(pg_bin createdb)"

# Initialize a cluster we own (avoid systemd; sandbox-friendly). test_user is the
# bootstrap superuser so the test suite can CREATE/DROP per-worker databases.
# Localhost auth is trust-only, so WIDEN_TEST_DB_* does not need a password.
mkdir -p "$PGDATA"
mkdir -p "$PGSOCKET_DIR"
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  "$INITDB" -D "$PGDATA" -U test_user --auth-local=trust --auth-host=trust
fi
grep -Eq "^[[:space:]]*listen_addresses[[:space:]]*=" "$PGDATA/postgresql.conf" ||
  echo "listen_addresses = '127.0.0.1'" >>"$PGDATA/postgresql.conf"
grep -Eq "^[[:space:]]*unix_socket_directories[[:space:]]*=" "$PGDATA/postgresql.conf" ||
  echo "unix_socket_directories = '$PGSOCKET_DIR'" >>"$PGDATA/postgresql.conf"

ensure_pg_running

"$CREATEDB" -h 127.0.0.1 -U test_user test_db || true
