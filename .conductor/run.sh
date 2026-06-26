#!/usr/bin/env bash
# Conductor Run button behavior. Local builds and opens the app via the
# existing Makefile target; cloud has no Xcode/macOS SDK so it just reports
# its limited capabilities and exits.
set -euo pipefail

if [ "${CONDUCTOR_IS_LOCAL:-1}" = "1" ]; then
  exec make run-conductor
else
  echo "Widen is a macOS-only Xcode app — there is no app to launch in the cloud."
  echo "The cloud snapshot ships a native Postgres on 127.0.0.1:5432 (user test_user)"
  echo "so config and Postgres-touching work can be reviewed here. Build/test runs"
  echo "on macOS via 'make build' and 'make test-db'."
fi
