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

   - `DEVELOPER_DIR`: optional Xcode path. By default, use the selected full Xcode,
     then `/Applications/Xcode.app` or another installed Xcode app (26 or later).

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
   DEVELOPER_DIR="$(bash scripts/xcode-developer-dir.sh)" \
     xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
   ```

4. Confirm the Sparkle key exists:

   ```sh
   make setup
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
     --account "$SPARKLE_ACCOUNT" -p
   ```

## Particle Model Change and Re-Gate

Text-to-SQL requests `particle-1` and discards any completion that does not
report `particle-ai/particle-1`. Particle publishes no dated snapshots, so
that check verifies the model name only: Particle can change the model behind
the name without a Widen release, and there is no earlier version to roll
back to. Re-gating the shipped configuration is how Widen notices. Nothing
schedules a re-gate between the triggers below, so a silent change can go
unnoticed until one of them fires. Run this procedure when any of these
happens:

- Particle announces a change to `particle-1`.
- A user or an eval reports an identity mismatch: a completion that names
  another model, or none. Test Connection in Settings > LLM shows the
  returned model.
- The model-list fields that `make eval-provider-probe` records (context
  window, max output tokens, capabilities, default and supported reasoning
  efforts) differ from the last recorded probe.
- A minor release is planned. Re-gate before it ships.

1. Open a re-gate issue that names the trigger. For an identity mismatch,
   record the expected and observed returned model IDs.
2. Choose the version the evidence is filed under: the planned release, or
   otherwise the next patch version. Obtain explicit authorization for the
   paid run and record, before any completion request, one total authorized
   cap, a small smoke allocation, a one-result overrun reserve, and the
   decision criteria in step 7. `MAX_CLOUD_COST_USD` is checked before each
   result, so a command can exceed it by its last result's cost. Keep the
   probe and smoke allocation plus the reserve below the total. After the
   smoke, choose one full-gate ceiling such that actual probe and smoke spend
   plus that ceiling plus the reserve does not exceed the authorization.
   Command-level ceilings do not replace cumulative accounting across
   commands.
3. Create a worktree from current `origin/main`, then probe the API. The probe
   costs under $0.02 and reads only `WIDEN_EVAL_PARTICLE_API_KEY` from
   `.env.eval.local`:

   ```sh
   make eval-provider-probe
   ```

   It writes `probe.json` and `probe.md` under
   `.eval-results/provider-probe-<timestamp>/` and exits nonzero on a critical
   failure: `particle-1` missing from the model list, a failed plain
   completion or one from another model, no accepted second-turn shape, or an
   invalid `json_object` reply. Stop on a critical failure, or on a warning
   that the second-turn shape the Particle profile sends was not accepted;
   the app's requests would fail the same way. Compare the model-list fields
   with the last recorded probe and note every difference in the issue.
4. Run the smoke at the shipped reasoning effort, with `REASONING_EFFORT`
   unset:

   ```sh
   make eval-smoke REPEAT=3 MAX_CLOUD_COST_USD=<smoke-allocation>
   ```

   It runs the five provider-smoke cases three times through the schema-tool
   agent. Stop if any result is incomplete, times out, or reports a returned
   model other than `particle-ai/particle-1`.
5. With `MODEL` and `ALLOW_MODEL_OVERRIDE` unset, run the complete gate.
   `RELEASE_VERSION` defaults to the app's `CFBundleShortVersionString`, so
   pass it explicitly:

   ```sh
   make eval-release-triage RELEASE_VERSION=X.Y.Z MAX_CLOUD_COST_USD=<full-gate-ceiling>
   ```

   It writes `docs/evals/X.Y.Z.md` and `docs/evals/X.Y.Z-triage.md` when the
   run is eligible for committed docs; see the
   [Release Gate](../Evals/README.md#release-gate) section of the eval
   README. If an infrastructure problem interrupts the run, resume its output
   directory instead of restarting completed cases:

   ```sh
   make eval-release-resume RESUME=<run-directory> RELEASE_VERSION=X.Y.Z MAX_CLOUD_COST_USD=<full-gate-ceiling>
   ```

   Reused results seed the run's recorded spend, so the resume value is the
   same cumulative gate ceiling, not an additional allowance. If an
   interruption may have left billed in-flight work unpersisted, lower the
   ceiling or obtain new authorization before resuming. Never rerun a
   complete gate to get a better number.
6. Account for spend. Particle reports no cost, so WidenEval estimates each
   request from its token usage at Particle's peak list prices. That estimate
   is an upper bound for requests that report usage, but a request that
   returns no usage, such as one cut off by a timeout, adds nothing, so the
   total can understate what Particle bills (see
   [Cost Accounting](../Evals/README.md#cost-accounting)). If Particle's
   console shows the key's usage, compare it with the estimate and record the
   larger figure. Record probe, smoke, and gate spend against the
   authorization in the issue.
7. Apply the recorded criteria mechanically. Unless the issue recorded
   stricter ones, the run is valid only with 60/60 complete results,
   transport and structured parsing at least 57/60, zero eval timeouts, the
   tools agent on 60/60, and `particle-ai/particle-1` on every completion.
   Against the last committed Particle-1 gate in `docs/evals/`, a valid run
   passes the re-gate if semantic end-to-end is at most 2 results lower, no
   case loses 2 or more of its 3 passes, clarification decisions are not
   lower, safety and schema validity stay at 100% of evaluated SQL, and
   repeated/no-progress repairs and internal schema-agent timeouts are not
   higher. Also report cumulative spend, per-result cost, P50/P95/maximum
   latency, and every triage bucket, even where no criterion applies.
8. If the re-gate passes, commit only the sanitized gate and triage evidence
   and continue with the release steps below.
9. If it fails, there is no dated snapshot to roll back to and no other model
   in the app. Commit the sanitized evidence anyway, report the regression to
   Particle with it, and keep the issue open. The maintainer decides whether
   to keep text-to-SQL enabled. Never weaken the validators, the identity
   check, or the gate criteria to make a run pass.

Before committing evidence, confirm that nothing from `.eval-results/` or
`.env*` is staged and that the staged diff contains no API keys, `Bearer`
tokens, URLs, or `/Users/` paths.

If Particle starts reporting a new name for `particle-1`, the probe fails at
its plain completion, and every app and eval completion fails the identity
check until a release expects the new name. Treat that as a new model, not a
constant update: on a candidate branch, change only `expectedReturnedModelID`
in `CloudModelProfile.particle` and the tests that assert it, then run this
procedure on that branch before merging.

Passing a re-gate keeps the beta text-to-SQL path on the current model. It
does not satisfy the separate 90% semantic production-readiness gate or
authorize removing beta wording.

## Per-Release Steps

Before a minor release, complete the
[Particle re-gate](#particle-model-change-and-re-gate) first.

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

`make release-mac` builds Release with the detected Xcode, injects local release env,
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
