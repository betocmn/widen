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

## OpenRouter Canonical-Version Watch

The `OpenRouter Canonical Watch` workflow runs every day at 08:23 UTC and can
also be started manually. It reads the requested alias and expected canonical
ID directly from `OpenRouterCatalog.productionProfile`, performs one public
single-model catalog lookup, and compares OpenRouter's `canonical_slug` with
the pin. The lookup bypasses Widen's catalog cache, stale fallback, and the
local URL cache while requesting upstream revalidation. It uses no API key or
completion request, so it has no OpenRouter completion spend. OpenRouter or
its CDN can still briefly serve edge-cached catalog metadata; confirm a
reported rollover again before changing the pin.

Run the same check locally with:

```sh
make eval-build
build/Build/Products/Debug/WidenEval --check-openrouter-canonical
```

Exit status `0` means the pin is current, `2` means a valid canonical mismatch
was confirmed, and `1` means the lookup failed without proving drift. On
confirmed drift, the workflow opens one deduplicated rollover issue and then
fails visibly. HTTP, transport, malformed-response, missing-model, and invalid
identity failures also fail the workflow, but do not open a drift issue.

## OpenRouter Canonical Rollover

Treat a canonical rollover as a new model version, not a routine constant
update. The requested production alias must remain `openai/gpt-5.6-sol`; the gate
must exercise that alias so Widen verifies the route OpenRouter will actually
use.

1. Manually rerun `OpenRouter Canonical Watch` and the local command above to
   confirm the same network mismatch. Record the old expected and newly
   observed canonical IDs in the rollover issue.
2. Choose the target patch version, obtain explicit authorization for the
   paid gate, and record one total authorized cap, a small smoke allocation,
   a one-case overrun reserve, and the conjunctive non-regression criteria
   below before making completion requests. `MAX_CLOUD_COST_USD` is checked
   before each case, so a command can exceed it by the final case's cost. Keep
   the smoke allocation plus reserve below the total authorization. After the
   smoke, choose one full-gate cumulative ceiling such that actual smoke spend
   plus that ceiling plus the reserve does not exceed the branch-wide
   authorization. Command-level ceilings do not replace cumulative branch
   accounting.
3. Create a candidate branch from current `origin/main` in a fresh worktree.
4. Update only `OpenRouterCatalog.productionProfile.expectedCanonicalModelID`
   and deterministic fixtures that assert that production pin. Do not change
   the requested alias, private routing, canonical verification, safety or
   schema validation, PostgreSQL verification, or release-gate enforcement.
   This pin update must precede the paid gate because eval preflight otherwise
   rejects the newly routed canonical version before any completion.
5. Regenerate the project, run the focused canonical/parser/routing suites,
   then run the full tests and eval build:

   ```sh
   make project
   DEVELOPER_DIR=/Applications/Xcode-26.app/Contents/Developer \
     xcodebuild -project Widen.xcodeproj -scheme Widen -configuration Debug \
       -derivedDataPath build test \
       -only-testing:WidenTests/OpenRouterCatalogTests \
       -only-testing:WidenTests/OpenRouterSQLGeneratorTests \
       -only-testing:WidenTests/OpenRouterSchemaToolSQLAgentTests \
       -only-testing:WidenTests/AIBackendSelectionTests \
       -only-testing:WidenTests/TextToSQLEvalRunPlanningTests
   make test
   make eval-build
   ```

6. With `ALLOW_MODEL_OVERRIDE` unset, run the requested alias through the
   smoke and complete release gates:

   ```sh
   make eval-openrouter-smoke MODEL=openai/gpt-5.6-sol REPEAT=3 MAX_CLOUD_COST_USD=<smoke-allocation>
   make eval-release-triage MODEL=openai/gpt-5.6-sol RELEASE_VERSION=X.Y.Z MAX_CLOUD_COST_USD=<full-gate-cumulative-ceiling>
   ```

   If the complete run is interrupted, resume its existing output directory
   instead of restarting completed cases:

   ```sh
   make eval-release-resume RESUME=<run-directory> MODEL=openai/gpt-5.6-sol RELEASE_VERSION=X.Y.Z MAX_CLOUD_COST_USD=<full-gate-cumulative-ceiling>
   ```

   Reuse the same full-gate ceiling when persisted results account for every
   prior request. Reused results seed the run's recorded spend, so the resume
   value is a cumulative gate ceiling, not an additional allowance. If an
   interruption may have left billed in-flight work unpersisted, reconcile
   actual provider spend and reduce the ceiling—or obtain new authorization—
   before resuming. Track smoke plus gate spend against the branch-wide
   authorization separately.

   Never gate the concrete canonical ID and never set `ALLOW_MODEL_OVERRIDE`;
   either would bypass the production routing contract under evaluation.
7. Apply every pre-registered rollover criterion mechanically. The retained
   comparator requires all of the following:

   - 60/60 complete results.
   - Semantic end-to-end at least 19/60.
   - Clarification decisions at least 11/12.
   - Exclusive expected-SQL clarification at most 28.
   - Tool-budget triage at most 6 and static schema failures at most 1.
   - Safety, schema, and PostgreSQL verification at 100% for evaluated SQL.
   - Transport and structured parsing at least 95%.
   - Zero forbidden bindings, repeated/no-progress repairs, eval timeouts,
     and internal schema-agent timeouts.
   - Private routing plus requested/routed/canonical model verification on
     every completion request.

   Also report cumulative branch spend, total and per-result gate cost,
   P50/P95/maximum latency, semantic mismatches, and every triage bucket even
   where no threshold applies.
8. If any criterion fails, revert the candidate pin, do not merge or ship it,
   and keep the rollover issue open. Evaluate alternatives separately without
   weakening fail-closed behavior.
9. If every criterion passes, commit only sanitized gate and triage evidence,
   merge the pin, then create a fresh `release/X.Y.Z` worktree and run
   `scripts/publish_release.sh X.Y.Z`.
10. Inspect the draft and verify that it contains exactly the three expected
    assets, then publish it. After publishing, verify the latest appcast/DMG
    URLs, perform the Sparkle end-to-end update test from an older build,
    rerun the canonical watch green on `main`, and close the rollover issue
    with links to the sanitized gate and release.

Passing these rollover non-regression criteria restores the existing beta
cloud path for the new canonical version. It does not satisfy the separate
90% semantic production-readiness gate or authorize removing beta wording.

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
