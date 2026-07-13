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
- Xcode 26 to build from source, or override `DEVELOPER_DIR` if your Xcode
  lives somewhere else.
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
make eval-release MODEL=openai/gpt-5.5  # PR 12 text-to-SQL release gate
```

The committed `Widen.xcodeproj` is generated. Edit `project.yml`, run
`make project`, and commit both files when project settings change.

## Testing Expectations

Run the narrowest test set that covers your change:

- Documentation-only changes do not need the full Xcode test suite.
- Model prompt, SQL validation, persistence, connection, or session changes
  should include focused unit tests.
- Database behavior changes should run `make test-db` when you have local
  PostgreSQL available.
- Foundation Models behavior should run `make test-fm` only on an eligible Mac
  with macOS 26+, Apple Intelligence enabled, and local model support.
- Text-to-SQL release changes should run `make eval-release` (it defaults to
  the pinned production model) when the OpenRouter and local PostgreSQL eval
  environment is available. The gate rejects other models; engineering
  comparisons need `MODEL=<model> ALLOW_MODEL_OVERRIDE=1` and do not update
  the committed release docs' meaning.

If you cannot run an expected test locally, say that in the pull request.

## Safety And Privacy Rules

- Do not persist database passwords, API keys, query results, inspected data
  values, or model prompts outside their current storage boundaries.
- Keep passwords and API keys in the macOS Keychain.
- Keep generated SQL reviewable before execution.
- Keep SQL validation deterministic and covered by tests.
- Do not add analytics, telemetry, crash reporting, or network calls without a
  visible user-facing reason and README/privacy documentation.
- Cloud text-to-SQL may send the question and allowed schema metadata to the
  selected provider. Inspected data values require explicit per-connection
  cloud data inspection opt-in.
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
