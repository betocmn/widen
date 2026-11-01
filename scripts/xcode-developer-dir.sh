#!/usr/bin/env bash
# Print the full Xcode developer directory used by setup, builds, and releases.
# --optional succeeds with no output when Xcode is not installed.
set -euo pipefail

print_xcode_dir() {
  local candidate="$1"
  # xcrun also accepts an Xcode app bundle as DEVELOPER_DIR.
  if [ -d "$candidate/Contents/Developer" ]; then
    candidate="$candidate/Contents/Developer"
  fi
  if [ -n "$candidate" ] && [ -x "$candidate/usr/bin/xcodebuild" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

if [ -n "${DEVELOPER_DIR:-}" ]; then
  if ! print_xcode_dir "$DEVELOPER_DIR"; then
    printf 'error: full Xcode not found at DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR" >&2
    exit 1
  fi
  exit 0
fi

# Prefer the user's selected toolchain over any versioned app installation.
# Fall back to installed Xcode apps when only Command Line Tools are selected.
for developer_dir in \
  "$(xcode-select --print-path 2>/dev/null || true)" \
  /Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode*.app/Contents/Developer; do
  if print_xcode_dir "$developer_dir"; then
    exit 0
  fi
done

if [ "${1:-}" = "--optional" ]; then
  exit 0
fi

echo "error: full Xcode was not found. Install Xcode 26 or later, or set DEVELOPER_DIR to its Contents/Developer directory." >&2
exit 1
