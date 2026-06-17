# Release Runbook

This is the app release procedure for signed Developer ID builds, notarized
DMGs, and Sparkle updates.

## Automated Release Overview

Normal releases use one command with the target version as an argument:

```sh
scripts/publish_release.sh 0.1.0
```

The script:

- Updates release version files and commits the bump when needed.
- Runs tests, builds, signs, notarizes, staples, and packages the app.
- Fast-forwards local `main`, pushes `main`, creates or reuses tag `vX.Y.Z`,
  and pushes the tag when needed.
- Creates or updates a draft GitHub Release in `https://github.com/betocmn/widen`
  with the DMG, Sparkle ZIP, and appcast uploaded as release assets.

## One-Time Local Setup

1. Copy the release env template and fill it from your password manager:

   ```sh
   cp .env.release.example .env.release.local
   ```

   Required values:

   - `TEAM_ID`: Apple Developer team identifier.
   - `NOTARY_PROFILE`: local `notarytool` keychain profile.
   - `BUNDLE_ID_PREFIX`: bundle identifier prefix for release builds.
   - `SPARKLE_ACCOUNT`: Sparkle Keychain account used for signing updates.
   - `SPARKLE_PUBLIC_ED_KEY`: public half of the Sparkle EdDSA key.

   Optional values:

   - `DEVELOPER_DIR`: Xcode path. The default is `/Applications/Xcode-26.app/Contents/Developer`.

   `.env.release.local` is ignored by git. Do not commit it.

   Before running manual checks in the current shell, load it with:

   ```sh
   set -a
   . ./.env.release.local
   set +a
   ```

   Run this in every new terminal before the checks below. If
   `NOTARY_PROFILE` is not loaded, `notarytool` exits with
   `Profile name must be at least 3 characters`.

2. Confirm Conductor copies the env file into new workspaces.

   The root checkout's `.conductor/settings.toml` should include
   `.env.release.local` in `file_include_globs`. Keep the official
   `.env.release.local` only in your local root checkout and password manager.

3. Confirm Apple signing and notarization are available:

   ```sh
   : "${NOTARY_PROFILE:?Set NOTARY_PROFILE in .env.release.local and load it first}"
   security find-identity -v -p codesigning | rg "Developer ID Application"
   DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.app/Contents/Developer}" \
     xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
   ```

4. Confirm the Sparkle key exists:

   ```sh
   make setup
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
     --account "$SPARKLE_ACCOUNT" -p
   ```

## Per-Release Steps

1. Start a fresh release worktree from `origin/main`:

   ```sh
   git fetch origin
   git worktree add ../release-X.Y.Z -b release/X.Y.Z origin/main
   cd ../release-X.Y.Z
   ```

2. Run the release command with the target version:

   ```sh
   scripts/publish_release.sh X.Y.Z
   ```

   Equivalent Makefile form:

   ```sh
   make release VERSION=X.Y.Z
   ```

   Optional flags:

   ```sh
   scripts/publish_release.sh X.Y.Z --build N
   scripts/publish_release.sh X.Y.Z --dry-run
   scripts/publish_release.sh X.Y.Z --no-open
   ```

   Build number behavior:

   - If `X.Y.Z` already matches the project version, the current build number is
     reused.
   - Otherwise the current build number is incremented by one.
   - `--build N` overrides the automatic build number.

3. Wait for the command to finish.

   The script validates the release environment, updates `project.yml`, runs
   `make project`, commits changed version files, runs `make test`, runs
   `make release-mac`, fast-forwards `main`, pushes `main`, creates or reuses
   tag `vX.Y.Z`, creates or updates a draft GitHub Release, and uploads:

   - `build/release-artifacts/X.Y.Z/Widen.dmg`
   - `build/release-artifacts/X.Y.Z/Widen-X.Y.Z.zip`
   - `build/release-artifacts/X.Y.Z/appcast.xml`

4. Inspect and publish the GitHub draft release.

   Before publishing, confirm the draft contains exactly these asset names:

   - `Widen.dmg`
   - `Widen-X.Y.Z.zip`
   - `appcast.xml`

   After publishing, verify:

   ```text
   https://github.com/betocmn/widen/releases/latest/download/appcast.xml
   https://github.com/betocmn/widen/releases/latest/download/Widen.dmg
   ```

## Artifact-Only Build

Use this only when you want local artifacts without publishing `main`, a tag,
or a GitHub Release:

```sh
make release-mac
```

`make release-mac` builds Release with Xcode 26, injects local release env,
re-signs Sparkle helpers, notarizes and staples `Widen.app`, creates the
Sparkle ZIP, generates `appcast.xml`, and creates/signs/notarizes/staples the
DMG. The appcast enclosure URL points at the versioned GitHub Release ZIP:

```text
https://github.com/betocmn/widen/releases/download/vX.Y.Z/Widen-X.Y.Z.zip
```

The automated `scripts/publish_release.sh` wrapper runs these same artifact
checks before it publishes any GitHub state.

## Static Website Follow-Up

The static website should point its download CTA at GitHub's latest DMG asset:

```text
https://github.com/betocmn/widen/releases/latest/download/Widen.dmg
```

After that one-time website update, routine app releases do not require static
website changes unless the site displays hardcoded release version text.

## Sparkle End-To-End Test

1. Install an older signed build locally.
2. Publish a test appcast advertising a higher `CFBundleVersion`.
3. Launch Widen and choose **Widen > Check for Updates...**.
4. Confirm Sparkle downloads, verifies, installs, prompts to relaunch, and
   relaunches into the newer build.

## Troubleshooting

- Missing release env: `make release-mac` exits before building and names the
  missing variable.
- Keychain prompt: choose **Always Allow** for the Developer ID private key.
- Slow notarization: query status with `xcrun notarytool info <submission-id>
  --keychain-profile "$NOTARY_PROFILE"`.
- Retry after a partial publish: rerun the same command. If tag `vX.Y.Z`
  already points at the same release commit, the script reuses it. If a draft
  GitHub Release already exists, the script replaces its assets. Published
  releases and tags pointing at a different commit still stop the release.
