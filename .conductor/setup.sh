#!/usr/bin/env bash
# Conductor workspace setup. Runs each time a workspace is created.
#
# Widen is a macOS-only Xcode app, so the cloud workspace cannot run xcodebuild
# or the test bundle. On cloud we just bring up the snapshot's native Postgres
# so any Linux-buildable Swift package tests (or psql work) can use it.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ "${CONDUCTOR_IS_LOCAL:-1}" = "1" ]; then
  # Local (macOS): resolve Swift package dependencies via xcodebuild.
  make setup
else
  # Cloud (Amazon Linux 2023): bring up the native Postgres baked into the snapshot.
  # xcodebuild is unavailable here, so we cannot run `make setup`.
  # shellcheck source=.conductor/pg.sh
  . "$SCRIPT_DIR/pg.sh"
  ensure_pg_running
  echo "Cloud workspace ready. Postgres listening on 127.0.0.1:5432 as test_user."
  echo "Note: Widen is macOS-only — xcodebuild, the app, and the test bundle"
  echo "cannot run here. Use this workspace for code review, docs, and configuration."
fi
