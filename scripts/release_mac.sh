#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-.env.release.local}"
if [ -f "$RELEASE_ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$RELEASE_ENV_FILE"
  set +a
fi

APP_NAME="${APP_NAME:-Widen}"
TEAM_ID="${TEAM_ID:-}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.app/Contents/Developer}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-ed25519}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-}"
WEBSITE_REPO="${WEBSITE_REPO:-}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://widen.dev/releases/}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/release}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-build/release-artifacts}"

export DEVELOPER_DIR

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need_env() {
  local name="$1"
  [ -n "${!name:-}" ] || die "missing required environment variable: $name"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2"
}

require_resolved_value() {
  local name="$1"
  local value="$2"

  [ -n "$value" ] || die "built app has empty $name"
  case "$value" in
    *'$('*)
      die "built app has unresolved $name"
      ;;
  esac
}

find_sparkle_bin() {
  for candidate in \
    "$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin" \
    "build/SourcePackages/artifacts/sparkle/Sparkle/bin"
  do
    if [ -x "$candidate/generate_keys" ] &&
      [ -x "$candidate/generate_appcast" ] &&
      [ -x "$candidate/sign_update" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

identity_hash() {
  security find-identity -v -p codesigning |
    sed -nE "s/^[[:space:]]*[0-9]+\\) ([A-F0-9]+) \"Developer ID Application: .+ \\(${TEAM_ID}\\)\"$/\\1/p" |
    head -n 1
}

sign_preserving_sparkle_bundle() {
  local path="$1"

  [ -e "$path" ] || die "missing Sparkle signing path: $path"
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$IDENTITY_HASH" \
    --preserve-metadata=identifier,entitlements,flags \
    "$path"
}

resign_sparkle_helpers() {
  local sparkle_root="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"

  sign_preserving_sparkle_bundle "$sparkle_root/Autoupdate"
  sign_preserving_sparkle_bundle "$sparkle_root/Updater.app"
  sign_preserving_sparkle_bundle "$sparkle_root/XPCServices/Downloader.xpc"
  sign_preserving_sparkle_bundle "$sparkle_root/XPCServices/Installer.xpc"
  sign_preserving_sparkle_bundle "$sparkle_root"
}

need codesign
need ditto
need hdiutil
need security
need spctl
need xcodebuild
need xcodegen
need xcrun

need_env TEAM_ID
need_env NOTARY_PROFILE
need_env SPARKLE_PUBLIC_ED_KEY
need_env BUNDLE_ID_PREFIX

[ -d "$DEVELOPER_DIR" ] || die "Xcode not found at DEVELOPER_DIR=$DEVELOPER_DIR"

SPARKLE_BIN="$(find_sparkle_bin || true)"
if [ -z "$SPARKLE_BIN" ]; then
  xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resolvePackageDependencies
  SPARKLE_BIN="$(find_sparkle_bin || true)"
fi

[ -n "$SPARKLE_BIN" ] || die "Sparkle CLI tools not found after resolving packages"

GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"

IDENTITY_HASH="$(identity_hash)"
[ -n "$IDENTITY_HASH" ] || die "Developer ID Application certificate for team $TEAM_ID is not installed"

KEYCHAIN_SPARKLE_PUBLIC_ED_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)" ||
  die "Sparkle EdDSA key for account '$SPARKLE_ACCOUNT' is not in the login Keychain"
[ "$KEYCHAIN_SPARKLE_PUBLIC_ED_KEY" = "$SPARKLE_PUBLIC_ED_KEY" ] ||
  die "SPARKLE_PUBLIC_ED_KEY does not match Sparkle keychain account '$SPARKLE_ACCOUNT'"

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"

printf 'Building %s with Xcode at %s\n' "$APP_NAME" "$DEVELOPER_DIR"
xcodegen generate
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "generic/platform=macOS" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  BUNDLE_ID_PREFIX="$BUNDLE_ID_PREFIX" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  ENABLE_HARDENED_RUNTIME=YES \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  clean build

SPARKLE_BIN="$(find_sparkle_bin || true)"
[ -n "$SPARKLE_BIN" ] || die "Sparkle CLI tools disappeared after build"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"

[ -d "$APP_PATH" ] || die "expected app was not produced at $APP_PATH"

plist_value SUFeedURL "$APP_PATH/Contents/Info.plist" >/dev/null ||
  die "built app is missing SUFeedURL"
plist_value SUPublicEDKey "$APP_PATH/Contents/Info.plist" >/dev/null ||
  die "built app is missing SUPublicEDKey"
BUILT_SPARKLE_PUBLIC_ED_KEY="$(plist_value SUPublicEDKey "$APP_PATH/Contents/Info.plist")"
require_resolved_value SUPublicEDKey "$BUILT_SPARKLE_PUBLIC_ED_KEY"
[ "$BUILT_SPARKLE_PUBLIC_ED_KEY" = "$SPARKLE_PUBLIC_ED_KEY" ] ||
  die "built app SUPublicEDKey does not match SPARKLE_PUBLIC_ED_KEY"
plist_value CFBundleShortVersionString "$APP_PATH/Contents/Info.plist" >/dev/null ||
  die "built app is missing CFBundleShortVersionString"
plist_value CFBundleVersion "$APP_PATH/Contents/Info.plist" >/dev/null ||
  die "built app is missing CFBundleVersion"
VERSION="$(plist_value CFBundleShortVersionString "$APP_PATH/Contents/Info.plist")"
BUILD_NUMBER="$(plist_value CFBundleVersion "$APP_PATH/Contents/Info.plist")"
require_resolved_value CFBundleShortVersionString "$VERSION"
require_resolved_value CFBundleVersion "$BUILD_NUMBER"

RELEASE_DIR="$ARTIFACT_ROOT/$VERSION"
TMP_DIR="$RELEASE_DIR/tmp"
NOTARY_APP_ZIP="$TMP_DIR/$APP_NAME-notary.zip"
SPARKLE_ZIP="$RELEASE_DIR/$APP_NAME-$VERSION.zip"
DMG_PATH="$RELEASE_DIR/$APP_NAME.dmg"

rm -rf "$RELEASE_DIR"
mkdir -p "$TMP_DIR"

printf 'Packaging %s %s (%s)\n' "$APP_NAME" "$VERSION" "$BUILD_NUMBER"
resign_sparkle_helpers
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

printf 'Notarizing and stapling %s.app\n' "$APP_NAME"
ditto -c -k --keepParent "$APP_PATH" "$NOTARY_APP_ZIP"
xcrun notarytool submit "$NOTARY_APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl -a -vvv -t exec "$APP_PATH"

printf 'Creating Sparkle archive %s\n' "$SPARKLE_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$SPARKLE_ZIP"

printf 'Creating signed DMG %s\n' "$DMG_PATH"
DMG_ROOT="$TMP_DIR/dmg-root"
mkdir -p "$DMG_ROOT"
cp -R "$APP_PATH" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -format UDZO -ov "$DMG_PATH"
codesign --force --timestamp --sign "$IDENTITY_HASH" "$DMG_PATH"
codesign --verify --verbose=4 "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"

if [ -n "$WEBSITE_REPO" ]; then
  need npm
  need xmllint

  [ -d "$WEBSITE_REPO" ] || die "WEBSITE_REPO does not exist: $WEBSITE_REPO"
  [ -d "$WEBSITE_REPO/public/releases" ] ||
    die "WEBSITE_REPO is missing public/releases: $WEBSITE_REPO"
  [ -f "$WEBSITE_REPO/public/appcast.xml" ] ||
    die "WEBSITE_REPO is missing public/appcast.xml: $WEBSITE_REPO"

  WEBSITE_ZIP="$WEBSITE_REPO/public/releases/$APP_NAME-$VERSION.zip"
  cp "$SPARKLE_ZIP" "$WEBSITE_ZIP"

  printf 'Generating Sparkle appcast in %s\n' "$WEBSITE_REPO/public/appcast.xml"
  "$GENERATE_APPCAST" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    -o "$WEBSITE_REPO/public/appcast.xml" \
    "$WEBSITE_REPO/public/releases"

  SIGNATURE="$(
    xmllint --xpath "string(//*[local-name()='enclosure'][contains(@url, '$APP_NAME-$VERSION.zip')]/@*[local-name()='edSignature'])" \
      "$WEBSITE_REPO/public/appcast.xml" 2>/dev/null || true
  )"
  [ -n "$SIGNATURE" ] || die "generated appcast is missing a Sparkle EdDSA signature for $APP_NAME-$VERSION.zip"
  "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$WEBSITE_ZIP" "$SIGNATURE"

  (
    cd "$WEBSITE_REPO"
    if [ ! -x node_modules/.bin/astro ]; then
      if [ -f package-lock.json ]; then
        npm ci
      else
        npm install
      fi
    fi
    npm run build
  )
else
  printf 'Skipping website handoff; set WEBSITE_REPO to a checkout containing public/appcast.xml and public/releases/.\n'
fi

rm -rf "$TMP_DIR"

printf '\nRelease artifacts are ready:\n'
printf '  Sparkle ZIP: %s\n' "$SPARKLE_ZIP"
printf '  Manual DMG:  %s\n' "$DMG_PATH"
if [ "${RELEASE_MAC_SKIP_GITHUB_HINT:-0}" != "1" ]; then
  printf 'Upload the DMG to the GitHub Release as exactly Widen.dmg.\n'
fi
