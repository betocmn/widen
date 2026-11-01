#!/usr/bin/env bash
# Conductor workspace setup. Runs each time a workspace is created.
#
# Widen is a macOS-only Xcode app, so the cloud workspace cannot run xcodebuild
# or the test bundle. On cloud we just bring up the snapshot's native Postgres
# so any Linux-buildable Swift package tests (or psql work) can use it.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ "${CONDUCTOR_IS_LOCAL:-1}" = "1" ]; then
  # Honor an explicit toolchain; otherwise prefer the Makefile's Xcode 26
  # installation, then the active Xcode, then the standard app location.
  # Command Line Tools alone do not include xcodebuild.
  if [ -z "${DEVELOPER_DIR:-}" ]; then
    for developer_dir in \
      /Applications/Xcode-26.app/Contents/Developer \
      "$(xcode-select --print-path 2>/dev/null || true)" \
      /Applications/Xcode.app/Contents/Developer; do
      if [ -n "$developer_dir" ] && [ -x "$developer_dir/usr/bin/xcodebuild" ]; then
        export DEVELOPER_DIR="$developer_dir"
        break
      fi
    done
  fi

  if [ -n "${DEVELOPER_DIR:-}" ]; then
    # An explicitly configured but unusable Xcode, or a package resolution
    # failure, must still fail setup so the underlying error stays visible.
    make setup
  else
    echo "Skipping Swift package dependency resolution: full Xcode was not found."
    echo "The workspace is available for editing, but building and testing require Xcode 26 or later."
    echo "Command Line Tools alone are not sufficient. Install Xcode, then rerun:"
    echo "  DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer bash .conductor/setup.sh"
  fi
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
