#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-Widen}"
REPO="${REPO:-betocmn/widen}"
RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-.env.release.local}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.app/Contents/Developer}"
DRY_RUN=0
OPEN_RELEASE=1
BUILD_OVERRIDE=""
TARGET_VERSION=""
TEMP_MAIN_WORKTREE=""

usage() {
  cat <<'USAGE'
Usage: scripts/publish_release.sh VERSION [--build N] [--dry-run] [--no-open]

Builds, signs, notarizes, fast-forwards main, pushes a tag, and creates a draft
GitHub Release for Widen.

Examples:
  scripts/publish_release.sh 0.1.0
  scripts/publish_release.sh 0.2.0 --build 3
  scripts/publish_release.sh 0.2.0 --dry-run
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

quote_command() {
  printf '%q ' "$@"
  printf '\n'
}

run() {
  printf '+ '
  quote_command "$@"
  if [ "$DRY_RUN" -eq 0 ]; then
    "$@"
  fi
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need_env() {
  local name="$1"
  [ -n "${!name:-}" ] || die "missing required environment variable: $name"
}

project_value() {
  local key="$1"
  sed -nE "s/^[[:space:]]*$key:[[:space:]]*\"?([^\" #]+)\"?.*$/\\1/p" project.yml |
    head -n 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2"
}

validate_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "version must use X.Y.Z semver format"
}

validate_build_number() {
  [[ "$1" =~ ^[0-9]+$ ]] ||
    die "build number must be a non-negative integer"
}

git_clean() {
  [ -z "$(git -C "$1" status --porcelain)" ]
}

find_main_worktree() {
  git worktree list --porcelain |
    awk '
      /^worktree / { worktree = substr($0, 10) }
      /^branch refs\/heads\/main$/ { print worktree; exit }
    '
}

cleanup() {
  if [ -n "$TEMP_MAIN_WORKTREE" ] && [ -d "$TEMP_MAIN_WORKTREE" ]; then
    git worktree remove "$TEMP_MAIN_WORKTREE" --force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build)
      shift
      [ "$#" -gt 0 ] || die "--build requires a value"
      BUILD_OVERRIDE="$1"
      ;;
    --build=*)
      BUILD_OVERRIDE="${1#--build=}"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --no-open)
      OPEN_RELEASE=0
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [ -z "$TARGET_VERSION" ] || die "only one version argument is allowed"
      TARGET_VERSION="$1"
      ;;
  esac
  shift
done

[ -n "$TARGET_VERSION" ] || {
  usage >&2
  exit 1
}
validate_semver "$TARGET_VERSION"

if [ -n "$BUILD_OVERRIDE" ]; then
  validate_build_number "$BUILD_OVERRIDE"
fi

if [ -f "$RELEASE_ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$RELEASE_ENV_FILE"
  set +a
fi

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.app/Contents/Developer}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-}"
WEBSITE_REPO="${WEBSITE_REPO:-}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://widen.dev/releases/}"

export DEVELOPER_DIR

need gh
need git
need make
need perl
need xcodegen
need xcodebuild

need_env TEAM_ID
need_env NOTARY_PROFILE
need_env SPARKLE_PUBLIC_ED_KEY
need_env BUNDLE_ID_PREFIX

[ -d "$DEVELOPER_DIR" ] || die "Xcode not found at DEVELOPER_DIR=$DEVELOPER_DIR"
git_clean "$ROOT_DIR" || die "current worktree has uncommitted changes; commit or stash them first"

CURRENT_BRANCH="$(git branch --show-current)"
[ -n "$CURRENT_BRANCH" ] || die "release must run from a branch, not detached HEAD"

TAG_NAME="v$TARGET_VERSION"
CURRENT_VERSION="$(project_value MARKETING_VERSION)"
CURRENT_BUILD="$(project_value CURRENT_PROJECT_VERSION)"
[ -n "$CURRENT_VERSION" ] || die "could not read MARKETING_VERSION from project.yml"
[ -n "$CURRENT_BUILD" ] || die "could not read CURRENT_PROJECT_VERSION from project.yml"
validate_semver "$CURRENT_VERSION"
validate_build_number "$CURRENT_BUILD"

if [ -n "$BUILD_OVERRIDE" ]; then
  TARGET_BUILD="$BUILD_OVERRIDE"
elif [ "$TARGET_VERSION" = "$CURRENT_VERSION" ]; then
  TARGET_BUILD="$CURRENT_BUILD"
else
  TARGET_BUILD="$((CURRENT_BUILD + 1))"
fi

log "Preparing $APP_NAME $TARGET_VERSION ($TARGET_BUILD) from branch $CURRENT_BRANCH"

run git fetch --prune origin
git merge-base --is-ancestor origin/main HEAD ||
  die "current branch must contain origin/main before releasing"

if git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null; then
  die "local tag already exists: $TAG_NAME"
fi

if [ -n "$(git ls-remote --tags origin "refs/tags/$TAG_NAME")" ]; then
  die "remote tag already exists: $TAG_NAME"
fi

if gh release view "$TAG_NAME" --repo "$REPO" >/dev/null 2>&1; then
  die "GitHub Release already exists: $TAG_NAME"
fi

gh auth status --hostname github.com >/dev/null
gh repo view "$REPO" >/dev/null

MAIN_WORKTREE="$(find_main_worktree)"
if [ -n "$MAIN_WORKTREE" ]; then
  git_clean "$MAIN_WORKTREE" ||
    die "main worktree has uncommitted changes: $MAIN_WORKTREE"
elif [ "$DRY_RUN" -eq 1 ]; then
  MAIN_WORKTREE="<temporary main worktree>"
else
  TEMP_MAIN_WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/widen-release-main.XXXXXX")"
  rmdir "$TEMP_MAIN_WORKTREE"
  if git show-ref --verify --quiet refs/heads/main; then
    run git worktree add "$TEMP_MAIN_WORKTREE" main
  else
    run git worktree add -b main "$TEMP_MAIN_WORKTREE" origin/main
  fi
  MAIN_WORKTREE="$TEMP_MAIN_WORKTREE"
fi

log "Using main worktree: $MAIN_WORKTREE"

if [ -n "$WEBSITE_REPO" ]; then
  [ -d "$WEBSITE_REPO" ] || die "WEBSITE_REPO does not exist: $WEBSITE_REPO"
  if git -C "$WEBSITE_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_clean "$WEBSITE_REPO" ||
      die "WEBSITE_REPO has uncommitted changes: $WEBSITE_REPO"
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "Dry run only. Planned release actions:"
  log "  update project.yml to $TARGET_VERSION ($TARGET_BUILD)"
  log "  run make project and make test"
  log "  run make release-mac"
  log "  fast-forward main to this release commit and push origin main"
  log "  create and push tag $TAG_NAME"
  log "  create a draft GitHub Release with Widen.dmg"
  exit 0
fi

TARGET_VERSION="$TARGET_VERSION" TARGET_BUILD="$TARGET_BUILD" perl -0pi -e '
  s/(CFBundleShortVersionString:\s*)"[0-9]+\.[0-9]+\.[0-9]+"/$1"$ENV{TARGET_VERSION}"/g;
  s/(MARKETING_VERSION:\s*)"[0-9]+\.[0-9]+\.[0-9]+"/$1"$ENV{TARGET_VERSION}"/g;
  s/(CFBundleVersion:\s*)"[0-9]+"/$1"$ENV{TARGET_BUILD}"/g;
  s/(CURRENT_PROJECT_VERSION:\s*)"[0-9]+"/$1"$ENV{TARGET_BUILD}"/g;
' project.yml

run make project

[ "$(project_value CFBundleShortVersionString)" = "$TARGET_VERSION" ] ||
  die "project.yml CFBundleShortVersionString did not update"
[ "$(project_value CFBundleVersion)" = "$TARGET_BUILD" ] ||
  die "project.yml CFBundleVersion did not update"
[ "$(project_value MARKETING_VERSION)" = "$TARGET_VERSION" ] ||
  die "project.yml MARKETING_VERSION did not update"
[ "$(project_value CURRENT_PROJECT_VERSION)" = "$TARGET_BUILD" ] ||
  die "project.yml CURRENT_PROJECT_VERSION did not update"
[ "$(plist_value CFBundleShortVersionString Widen/Info.plist)" = "$TARGET_VERSION" ] ||
  die "Widen/Info.plist CFBundleShortVersionString did not regenerate"
[ "$(plist_value CFBundleVersion Widen/Info.plist)" = "$TARGET_BUILD" ] ||
  die "Widen/Info.plist CFBundleVersion did not regenerate"

if ! git diff --quiet -- project.yml Widen.xcodeproj Widen/Info.plist; then
  run git add project.yml Widen.xcodeproj Widen/Info.plist
  run git commit -m "build: bump release version"
else
  log "Version files already match $TARGET_VERSION ($TARGET_BUILD); no bump commit needed."
fi

run make test

log "Building signed and notarized release artifacts"
run env RELEASE_MAC_SKIP_GITHUB_HINT=1 make release-mac

DMG_PATH="build/release-artifacts/$TARGET_VERSION/$APP_NAME.dmg"
[ -f "$DMG_PATH" ] || die "expected DMG was not produced at $DMG_PATH"

RELEASE_COMMIT="$(git rev-parse HEAD)"
run git fetch --prune origin
git merge-base --is-ancestor origin/main "$RELEASE_COMMIT" ||
  die "origin/main moved during release; rebase or merge it before publishing"

if [ "$MAIN_WORKTREE" = "$ROOT_DIR" ]; then
  run git merge --ff-only origin/main
else
  run git -C "$MAIN_WORKTREE" fetch --prune origin
  run git -C "$MAIN_WORKTREE" merge --ff-only origin/main
  run git -C "$MAIN_WORKTREE" merge --ff-only "$RELEASE_COMMIT"
fi

run git -C "$MAIN_WORKTREE" push origin main
run git -C "$MAIN_WORKTREE" tag -a "$TAG_NAME" "$RELEASE_COMMIT" -m "$APP_NAME $TARGET_VERSION"
run git -C "$MAIN_WORKTREE" push origin "$TAG_NAME"

run gh release create "$TAG_NAME" "$DMG_PATH#$APP_NAME.dmg" \
  --repo "$REPO" \
  --draft \
  --verify-tag \
  --title "$APP_NAME $TARGET_VERSION" \
  --generate-notes

RELEASE_URL="$(gh release view "$TAG_NAME" --repo "$REPO" --json url -q .url)"

cat <<EOF

Draft GitHub Release is ready:
  $RELEASE_URL

Before publishing the draft:
EOF

if [ -n "$WEBSITE_REPO" ]; then
  cat <<EOF
  1. Publish the Sparkle website files:
     cd "$WEBSITE_REPO"
     git status --short
     git add public/appcast.xml public/releases/$APP_NAME-$TARGET_VERSION.zip
     git commit -m "build: publish sparkle release"
     git push
  2. Confirm the website deployment serves:
     $DOWNLOAD_URL_PREFIX$APP_NAME-$TARGET_VERSION.zip
     https://widen.dev/appcast.xml
  3. Publish the GitHub draft release.
EOF
else
  cat <<EOF
  1. WEBSITE_REPO was not set, so Sparkle appcast files were not staged.
  2. Publish the GitHub draft release when you are ready to make the DMG public.
EOF
fi

if [ "$OPEN_RELEASE" -eq 1 ]; then
  run gh release view "$TAG_NAME" --repo "$REPO" --web
fi
