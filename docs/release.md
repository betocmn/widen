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
- Fast-forwards local `main`, pushes `main`, creates tag `vX.Y.Z`, and pushes
  the tag.
- Creates a draft GitHub Release in `https://github.com/betocmn/widen` with the
  DMG uploaded as the exact asset name `Widen.dmg`.
- Leaves website/appcast publishing manual and prints the follow-up commands.

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

   - `WEBSITE_REPO`: local checkout of the static website repo.
   - `DOWNLOAD_URL_PREFIX`: URL prefix for Sparkle ZIP enclosures.
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

   - If `X.Y.Z` already matches the project version and no tag/release exists,
     the current build number is reused.
   - Otherwise the current build number is incremented by one.
   - `--build N` overrides the automatic build number.

3. Wait for the command to finish.

   The script validates the release environment, updates `project.yml`, runs
   `make project`, commits changed version files, runs `make test`, runs
   `make release-mac`, fast-forwards `main`, pushes `main`, creates and pushes
   tag `vX.Y.Z`, creates a draft GitHub Release, and uploads
   `build/release-artifacts/X.Y.Z/Widen.dmg` as `Widen.dmg`.

4. Publish the remaining manual surfaces.

   If `WEBSITE_REPO` is set, the script stages Sparkle files in that separate
   checkout and prints exact commands to review, commit, push, and verify the
   website deployment. Publish the GitHub draft release only after the website
   appcast and ZIP are live.

## Artifact-Only Build

Use this only when you want local artifacts without publishing `main`, a tag,
or a GitHub Release:

```sh
make release-mac
```

`make release-mac` builds Release with Xcode 26, injects local release env,
re-signs Sparkle helpers, notarizes and staples `Widen.app`, creates the
Sparkle ZIP, creates/signs/notarizes/staples the DMG, and stages website
Sparkle files when `WEBSITE_REPO` is set.

The automated `scripts/publish_release.sh` wrapper runs these same artifact
checks before it publishes any GitHub state.

## Static Website Follow-Up

The static website handles two separate release surfaces:

- Manual download CTA: configured in `src/config/site.ts`.
- Sparkle update hosting: `public/appcast.xml` and `public/releases/Widen-X.Y.Z.zip`.

After `scripts/publish_release.sh` or `make release-mac` stages website files,
inspect and commit the website changes:

```sh
cd "$WEBSITE_REPO"
npm run build
git status --short
git add public/appcast.xml public/releases/Widen-X.Y.Z.zip
git commit -m "build: publish sparkle release"
git push
```

Manual GitHub action: if the website repo requires PRs, open and merge the
website PR after pushing. If direct pushes deploy the site, confirm the
deployment completed before announcing Sparkle updates.

Update the website download metadata in `src/config/site.ts`:

1. Set `download.version` to the released version.
2. Leave `download.dmgUrl` unchanged if the GitHub Release asset is named
   exactly `Widen.dmg`; the existing latest-release URL will update
   automatically.
3. Change `download.dmgUrl` only if you move downloads away from GitHub
   Releases or stop using the `Widen.dmg` asset name.
4. Run `npm run build`, commit, and push the website repo.

The appcast enclosure URL should look like this:

```text
https://widen.dev/releases/Widen-X.Y.Z.zip
```

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
- Website build missing dependencies: the release script runs `npm ci` when the
  website checkout lacks `node_modules/.bin/astro`.
