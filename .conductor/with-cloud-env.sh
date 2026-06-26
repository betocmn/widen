#!/usr/bin/env bash
# Load Conductor Cloud environment variables for command runners that do not
# receive repo settings directly. Currently exports WIDEN_TEST_DB* and
# WIDEN_EVAL_DB* defaults defined under [environment_variables.cloud] in
# .conductor/settings.toml so a manual shell can connect to the snapshot's
# native Postgres without re-typing them.
set -euo pipefail

if [ "${CONDUCTOR_IS_LOCAL:-1}" = "0" ] && [ -f ".conductor/settings.toml" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name="${line%%=*}"
    value="${line#*=}"
    if [ -z "${!name:-}" ]; then
      export "$name=$value"
    fi
  done < <(
    awk '
      /^\[environment_variables\.cloud\]/ { in_section = 1; next }
      /^\[/ { in_section = 0 }
      in_section && /=/ {
        sub(/^[[:space:]]+/, "", $0)
        sub(/[[:space:]]*=[[:space:]]*/, "=", $0)
        gsub(/"/, "", $0)
        print
      }
    ' .conductor/settings.toml
  )
fi

exec "$@"
