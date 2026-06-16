# Release Runbook

This is the app release procedure for signed Developer ID builds, notarized
DMGs, and Sparkle updates.

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
   build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
     --account "$SPARKLE_ACCOUNT" -p
   ```

## Per-Release Steps

1. Choose the app version and build number.

   For version `X.Y.Z` and build `N`, update `project.yml` in both places:

   - `CFBundleShortVersionString: "X.Y.Z"`
   - `CFBundleVersion: "N"`
   - `MARKETING_VERSION: "X.Y.Z"`
   - `CURRENT_PROJECT_VERSION: "N"`

2. Regenerate the Xcode project and run tests:

   ```sh
   make project
   make test
   ```

3. Commit the version bump:

   ```sh
   git add project.yml Widen.xcodeproj Widen/Info.plist
   git commit -m "build: bump release version"
   ```

4. Build, sign, notarize, package, and stage website files:

   ```sh
   make release-mac
   ```

   The script:

   - Builds Release with Xcode 26.
   - Injects `TEAM_ID`, `BUNDLE_ID_PREFIX`, and `SPARKLE_PUBLIC_ED_KEY` from local env.
   - Re-signs Sparkle helper bundles for Developer ID distribution.
   - Notarizes and staples `Widen.app`.
   - Creates `build/release-artifacts/X.Y.Z/Widen-X.Y.Z.zip` for Sparkle.
   - Creates, signs, notarizes, and staples `build/release-artifacts/X.Y.Z/Widen.dmg`.
   - If `WEBSITE_REPO` is set, copies the ZIP to the website repo, regenerates
     `public/appcast.xml`, verifies the Sparkle signature, and runs the website build.

5. Verify the app artifact:

   ```sh
   codesign --verify --deep --strict --verbose=4 build/release/Build/Products/Release/Widen.app
   xcrun stapler validate build/release/Build/Products/Release/Widen.app
   spctl -a -vvv -t exec build/release/Build/Products/Release/Widen.app
   ```

6. Verify the DMG:

   ```sh
   codesign --verify --verbose=4 build/release-artifacts/X.Y.Z/Widen.dmg
   xcrun stapler validate build/release-artifacts/X.Y.Z/Widen.dmg
   spctl -a -vvv -t open --context context:primary-signature build/release-artifacts/X.Y.Z/Widen.dmg
   ```

7. Create or update the GitHub Release.

   Upload the DMG asset with the exact filename `Widen.dmg`. The static website
   CTA expects this conventional latest-release URL:

   ```text
   https://github.com/<owner>/<repo>/releases/latest/download/Widen.dmg
   ```

## Static Website Repo

The static website handles two separate release surfaces:

- Manual download CTA: configured in `src/config/site.ts`.
- Sparkle update hosting: `public/appcast.xml` and `public/releases/Widen-X.Y.Z.zip`.

After `make release-mac`, inspect and commit the website changes:

```sh
cd "$WEBSITE_REPO"
npm run build
git status --short
git add public/appcast.xml public/releases/Widen-X.Y.Z.zip
git commit -m "build: publish sparkle release"
git push
```

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
