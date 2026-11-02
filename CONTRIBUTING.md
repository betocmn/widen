# Contributing

Thanks for helping improve Widen. This project is early and privacy-sensitive,
so contributions should preserve the central promise: Widen helps draft SQL,
but the user stays in control of every query that runs.

## Good First Areas

- Documentation improvements, especially setup, troubleshooting, and release
  notes.
- UI polish that keeps the app native, readable, and efficient on macOS.
- Postgres schema browsing, result rendering, export, and session workflow
  improvements.
- SQL safety validator tests for real-world edge cases.
- Better error messages for database connectivity, model availability, and
  release packaging.

If you are unsure whether a large feature fits, open an issue first with the
problem, proposed behavior, and any tradeoffs.

## Development Setup

Requirements:

- macOS 14 or later to run the app.
- Xcode 26 or later (including Xcode 27) to build from source. The selected
  Xcode is detected automatically; set `DEVELOPER_DIR` to override it.
- XcodeGen for regenerating the committed project from `project.yml`.
- PostgreSQL only if you want to run integration tests or try the sample
  database.

Common commands:

```sh
make project   # regenerate Widen.xcodeproj from project.yml
make setup     # resolve Swift package dependencies
make build     # build the Debug app
make test      # unit tests
make test-db   # unit + local Postgres integration tests
make run       # build and launch Widen.app
make eval-release  # text-to-SQL release gate (pinned Particle-1)
```

The committed `Widen.xcodeproj` is generated. Edit `project.yml`, run
`make project`, and commit both files when project settings change.

The app icon uses the website's W mark and colors. Its vector master is
`scripts/app_icon.svg`, matching `widen-web/public/logo/mark.svg` and the icon
layout in that repository's `scripts/images.mjs`. After updating the master,
run `swift scripts/make_icon.swift` and commit all generated PNGs in
`Widen/Assets.xcassets/AppIcon.appiconset`.

## Testing Expectations

Run the narrowest test set that covers your change:

- Documentation-only changes do not need the full Xcode test suite.
- Model prompt, SQL validation, persistence, connection, or session changes
  should include focused unit tests.
- Database behavior changes should run `make test-db` when you have local
  PostgreSQL available.
- Text-to-SQL release changes should run `make eval-release` (it runs the
  pinned Particle-1 model) when `WIDEN_EVAL_PARTICLE_API_KEY` is set in
  `.env.eval.local` and local PostgreSQL is available. The gate is paid; never
  print or commit `.env.eval.local`. OpenRouter comparisons run on the non-gate
  eval targets with `MODEL=openai/gpt-5.5` and `WIDEN_EVAL_OPENROUTER_API_KEY`.
  The gate targets reject other models unless you add `ALLOW_MODEL_OVERRIDE=1`,
  and such runs never update the committed release docs.

If you cannot run an expected test locally, say that in the pull request.

## Safety And Privacy Rules

- Do not persist database passwords, API keys, query results, inspected data
  values, or model prompts outside their current storage boundaries.
- Keep passwords and API keys in the macOS Keychain.
- Keep generated SQL reviewable before execution.
- Keep SQL validation deterministic and covered by tests.
- Do not add analytics, telemetry, crash reporting, or network calls without a
  visible user-facing reason and README/privacy documentation.
- Text-to-SQL may send the question and allowed schema metadata to Particle.
  Inspected data values require explicit per-connection cloud data inspection
  opt-in.
- Keep paste-autofill deterministic and local: pasted connection details can
  contain credentials and must never reach a model.
- Prefer read-only database guidance in docs and examples.

## Pull Request Checklist

Before opening a PR:

- Run the relevant tests or document why they were not run.
- Update README or docs when behavior, requirements, or user-facing privacy
  boundaries change.
- Add or update tests for behavior changes.
- Keep changes focused; split unrelated work into separate PRs.
- Do not commit `.env.release.local`, signing keys, certificates, database
  dumps, screenshots containing real data, or local app support files.

## Release Process

Release packaging is maintainer-only because it requires Developer ID,
notarization, and Sparkle signing credentials. See [docs/release.md](docs/release.md)
for the runbook.
