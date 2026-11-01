#!/usr/bin/env bash
# Print the full Xcode developer directory used by setup, builds, and releases.
# Discovery only accepts Xcode 26 or later. --optional succeeds with no output
# when no supported Xcode is installed.
set -euo pipefail

MIN_XCODE_MAJOR=26

print_xcode_dir() {
  local candidate="$1"
  # Drop trailing slashes (shell completion adds one) so callers such as
  # `make xcode` can strip /Contents/Developer from the printed path.
  while [ "${candidate%/}" != "$candidate" ]; do
    candidate="${candidate%/}"
  done
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

# Print the version (e.g. 26.1) of the Xcode app that owns a developer
# directory, or nothing when it cannot be read.
xcode_version() {
  local version
  # PlistBuddy reports a missing file on stdout, so keep output only on success.
  if version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/../Info.plist" 2>/dev/null)"; then
    printf '%s\n' "$version"
  fi
}

is_supported_version() {
  local major="${1%%.*}"
  case "$major" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$major" -ge "$MIN_XCODE_MAJOR" ]
}

if [ -n "${DEVELOPER_DIR:-}" ]; then
  if ! developer_dir="$(print_xcode_dir "$DEVELOPER_DIR")"; then
    printf 'error: full Xcode not found at DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR" >&2
    exit 1
  fi
  # Trust an explicit override unless its version is known to be too old.
  version="$(xcode_version "$developer_dir")"
  if [ -n "$version" ] && ! is_supported_version "$version"; then
    printf 'error: DEVELOPER_DIR=%s is Xcode %s; Xcode %s or later is required.\n' \
      "$DEVELOPER_DIR" "$version" "$MIN_XCODE_MAJOR" >&2
    exit 1
  fi
  printf '%s\n' "$developer_dir"
  exit 0
fi

# Prefer the user's selected toolchain over any versioned app installation.
# Fall back to installed Xcode apps when Command Line Tools or an older Xcode is
# selected.
for candidate in \
  "$(xcode-select --print-path 2>/dev/null || true)" \
  /Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode*.app/Contents/Developer; do
  if developer_dir="$(print_xcode_dir "$candidate")" &&
    is_supported_version "$(xcode_version "$developer_dir")"; then
    printf '%s\n' "$developer_dir"
    exit 0
  fi
done

if [ "${1:-}" = "--optional" ]; then
  exit 0
fi

printf 'error: Xcode %s or later was not found. Install it, or set DEVELOPER_DIR to its Contents/Developer directory.\n' \
  "$MIN_XCODE_MAJOR" >&2
exit 1
