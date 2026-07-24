# Widen

[![CI](https://github.com/betocmn/widen/actions/workflows/ci.yml/badge.svg)](https://github.com/betocmn/widen/actions/workflows/ci.yml)
[![CodeQL](https://github.com/betocmn/widen/actions/workflows/codeql.yml/badge.svg)](https://github.com/betocmn/widen/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

Widen is an open-source macOS Postgres GUI for macOS 14+. It reads your schema
and can draft SQL from a question using a cloud model you configure. On eligible
macOS 26+ Apple Silicon Macs, Widen can also use Apple's on-device Foundation
Model. It shows the SQL before anything runs, so you can review or edit it first.

No Widen backend. No account. No analytics. Cloud-first for text-to-SQL, with
manual SQL and optional local AI still available where supported.

[Download for Mac](https://github.com/betocmn/widen/releases/latest/download/Widen.dmg)
· [Build from source](#build-and-run)
· [Privacy](PRIVACY.md)
· [Contributing](CONTRIBUTING.md)
· [Security](SECURITY.md)
· [Release notes](https://github.com/betocmn/widen/releases/latest)

`macOS 14+` · `Cloud-first text-to-SQL` · `Optional local AI on macOS 26+` ·
`No backend` · `No account` · `MIT` · `Postgres-only MVP`

## What makes this new?

Widen turns schema-aware questions into SQL you can inspect before running.
Cloud generation is the default text-to-SQL path because it works on older
supported Macs and can handle broader schemas. Starting with macOS 26,
supported Apple Silicon Macs can also run Apple's Foundation Model on-device
for an optional local mode.

It is not an autonomous database agent. Widen drafts SQL, validates it, and
waits for you to decide whether to run it.

## Install

Download the latest signed and notarized DMG:

```text
https://github.com/betocmn/widen/releases/latest/download/Widen.dmg
```

Open `Widen.dmg`, drag Widen into Applications, and launch it. Sparkle updates
are served from GitHub Releases.

## Compatibility

| Requirement | Notes |
| --- | --- |
| macOS 14 or later | Required to install and launch Widen. |
| Apple Silicon | Required only for Apple's optional on-device Foundation Model. |
| Apple Intelligence enabled | Required only for local AI generation. Manual SQL and cloud models still work without it. |
| PostgreSQL | Widen is Postgres-only today. [Postgres.app](https://postgresapp.com) works well for local testing. |
| Xcode 26 | Needed when building from source. |

## What leaves your Mac?

Out of the box, Widen can browse schemas and run manual SQL with only the
PostgreSQL connection you configure. Cloud text-to-SQL requires a provider you
configure in Settings.

| Mode | Schema/question | Query results | Notes |
| --- | ---: | ---: | --- |
| Cloud mode | Question and allowed schema metadata are sent to the provider you choose | Stays on your Mac unless cloud data inspection is enabled for that connection | Default text-to-SQL backend. Fresh installs use the fixed OpenRouter GPT-5.6 Sol profile and schema-tool agent. OpenRouter requests require zero-data-retention endpoints and deny provider data collection. |
| Local mode | Stays on your Mac | Stays on your Mac | Optional on eligible macOS 26+ Apple Silicon Macs with Apple Intelligence enabled. Best suited to narrow requests over simple databases. |

Passwords and API keys live in the macOS Keychain, never on disk in plaintext.

## Review before run

Every statement, whether typed manually or drafted by the model, goes through
the same deterministic safety validator:

- One statement only.
- `SELECT`/`WITH` reads, or explicit `INSERT`/`UPDATE`/`DELETE` writes.
- No DDL, transaction keywords, semicolon chains, `pg_sleep`, `dblink`, or
  large-object calls.
- Statement timeouts and row caps apply at execution time.
- Writes are never auto-run, and Widen asks for confirmation before `DELETE`
  or an `UPDATE` without a `WHERE`.

If you only want reads, connect with a read-only Postgres user. The app-level
guardrails are useful, but database permissions are the real boundary.

## Built for people who live in Postgres

Widen is a lightweight, native Postgres workbench for browsing schemas, keeping
query sessions, and turning questions into SQL:

- Configure any number of PostgreSQL connections in Settings.
- Browse the selected database's schemas, tables, columns, types, and foreign
  keys in the inspector.
- Keep persistent chat + SQL + results sessions that survive restarts.
- Switch between Cloud and Local from the toolbar when local AI is available.
- Use a modern macOS interface with light/dark appearance and Liquid Glass on macOS 26+.

## Known limitations

- PostgreSQL only.
- Early MVP, not full DataGrip/TablePlus/Postico feature parity.
- Cloud text-to-SQL requires your own provider setup. Widen defaults to
  OpenRouter with the fixed `openai/gpt-5.6-sol` profile. Custom OpenRouter model
  selection is not exposed; changing the evaluated model version requires a
  new app release and release-gate evaluation. Apple Private Cloud Compute
  support is planned when Apple's required OS and SDK support is available.
- The optional local Foundation Model requires eligible macOS 26+ Apple Silicon
  hardware and has a small context window; very large schemas are truncated
  whole-table-at-a-time before prompting.
- Results are rendered as text values; typed grid behavior is still limited.
- Export is CSV-only today.
- No SQL syntax highlighting yet.
- Query results are not persisted across restarts. Transcripts, SQL text, and
  generation metadata are persisted; rerun a session's query to repopulate the
  grid.

## Build and run

The Makefile pins `DEVELOPER_DIR` to `/Applications/Xcode-26.app`. If your
Xcode 26 lives elsewhere (e.g. it is your default `/Applications/Xcode.app`),
override it: `make build DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
make project   # regenerate Widen.xcodeproj from project.yml (needs xcodegen)
make build     # build the app (Debug)
make run       # build and launch Widen.app
make test      # unit tests
make test-db   # unit + Postgres integration tests (needs the sample DB below)
make test-fm   # unit + on-device Foundation Models smoke test
make xcode     # open the project in Xcode 26
```

The committed `Widen.xcodeproj` is generated - edit `project.yml` and run
`make project` instead of editing project settings by hand. If you open the
project in Xcode directly, make sure it is **Xcode 26**, not an older default
Xcode. Widen targets macOS 14, while optional Foundation Models code is compiled
behind macOS 26 availability checks.

## Release packaging

Release packaging is automated for Developer ID distribution. Debug stays ad-hoc
signed for local development. The release script reads local signing,
notarizing, bundle ID, and Sparkle values from environment variables or
`.env.release.local`:

```sh
cp .env.release.example .env.release.local
make release-mac
```

See [docs/release.md](docs/release.md) for the full signed DMG, Sparkle, and
static website release runbook.

For codebase onboarding and implementation details, see
[docs/implementation-guide.md](docs/implementation-guide.md).

## Open source

Widen is MIT licensed and developed in the open. Start with
[CONTRIBUTING.md](CONTRIBUTING.md) for local setup, testing expectations, and
the safety/privacy rules contributors should preserve. See
[PRIVACY.md](PRIVACY.md) for the data-flow summary and [SECURITY.md](SECURITY.md)
for vulnerability reporting.

## Sample database for exploring the app

This is only for trying the app by hand — the integration tests (`make test-db`)
provision and drop their own throwaway databases and do not need it.

With Postgres.app running (its default server on `localhost:5432`):

```sh
createdb widen_test
psql -d widen_test -f scripts/sample_db.sql
```

If `psql` is not on your PATH, use the bundled one, e.g.
`/Applications/Postgres.app/Contents/Versions/17/bin/psql`.

The script creates a tiny shop dataset:

```sql
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  email TEXT NOT NULL,
  name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE orders (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  total_cents INTEGER NOT NULL,
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

plus a few rows. Good first questions to try:

- "Show me all users."
- "Show the 10 most recent orders."
- "Which users have spent the most?"
- "Count orders by status."
- "Show revenue by day."
- "Show customers with no orders."

## Connecting

On first launch Widen opens Settings › Databases. For a default Postgres.app
setup: host `localhost`, port `5432`, database `widen_test`, username = your
macOS username, empty password (Postgres.app uses trust auth locally), SSL
mode Disabled. Add as many databases as you like with the "+" button;
deleting one warns you first — its sessions are deleted with it.

> **Safety tip:** Widen runs the SQL you approve, including writes — it never
> auto-runs a write, and DELETE or UPDATE-without-WHERE asks you to confirm
> first. If you only want reads, connect with a read-only Postgres user; defense
> in depth is cheap.

Non-secret connection settings are stored in
`~/Library/Application Support/Widen/connections.json`; passwords are stored
in the macOS Keychain (service `Widen`).

## Sessions

Each database in the sidebar lists its query sessions. Selecting the
database itself opens its schema in the inspector; press the hover "+"
(or Cmd+N) to start a session — the database connects lazily, so nothing
happens until a session or schema browse needs it. A session keeps its chat
transcript (including run records), active SQL, and generation metadata in
`~/Library/Application Support/Widen/sessions.json` (query results are
deliberately not persisted). The local model names the session after your
first question; rename it manually (right-click › Rename) and the auto-name
never overwrites yours. Right-click › Archive hides a session; restore it or
delete it forever from Settings › Archived Sessions.

The schema browser lives in a right-hand inspector — toggle it from the
toolbar. The toolbar breadcrumb (`database › schema`) and the inspector's
picker both switch the open schema; the table list and the AI's context are
scoped to it. Schema snapshots are cached in
`~/Library/Application Support/Widen/schemas.json` so the last known schema is
available immediately on relaunch; Refresh Schema fetches the live structure
and updates that cache. The sun/moon button in the sidebar footer flips
light/dark mode; pick "System" in Settings › General to follow macOS again.

## How a query runs

1. You type into the composer: a plain-English question, or raw SQL
   (`SELECT`/`WITH` reads and SQL-shaped `INSERT INTO`, `UPDATE ... SET`, or
   `DELETE FROM` writes skip the model entirely).
2. For questions, Widen prompts the selected backend with the open schema's
   allowed tables, columns, types, and foreign keys (system schemas excluded)
   plus the safety rules, and gets structured output back: SQL, explanation,
   assumptions, referenced tables, confidence, and risk level.
3. The SQL appears in the chat as a dashed card, validated deterministically:
   only one read or `INSERT`/`UPDATE`/`DELETE` statement, no semicolons, no
   DDL/transaction keywords, no `pg_sleep`/`dblink`/`lo_*`. Validation issues
   sit behind the card's status icon. Keep chatting (or paste corrected SQL)
   until it's right.
4. Run executes reads in a `BEGIN READ ONLY` transaction and writes in a normal
   transaction with `SET LOCAL statement_timeout` (default 10s). Read queries
   without a `LIMIT` are wrapped in a subquery with your default row limit
   (default 100).
5. The results flow into the same chat thread: a bordered table card appears
   where the run happened (first 10 rows, "View more" for the rest), with
   Copy as CSV and Export CSV. Every run is recorded in the transcript, and
   the conversation just keeps going underneath.

Keyboard: **Enter** in the composer submits (Option+Enter for a newline);
**Cmd+Enter** runs the active SQL; **Cmd+N** starts a new session; **Cmd+R**
refreshes the active database's schema; **Cmd+,** opens Settings.

## Text-to-SQL evals

`WidenEval` provides native static-shape and seeded-Postgres semantic evals for
generated SQL under [Evals](Evals). A static-shape pass verifies the decision,
SQL safety, schema references, and configured structural expectations. Seeded
Postgres evals execute safe candidates against synthetic fixtures and compare
result sets.

The committed baselines record deterministic hashes for the suite, scorer
source, and schema fixtures so future runs can detect compatibility drift.
Each case defaults to a 120-second eval-only timeout and reports `evalTimeout`
instead of transport failure when the timeout cancels the pipeline. Baselines
from older evaluation modes are stale; regenerate cloud baselines only with a
real `WIDEN_EVAL_OPENROUTER_API_KEY`, never from an all-unavailable run.
Foundation Models cancellation is cooperative, so timed-out model work may
continue in process until the framework returns.

The release gate defaults to the same pinned GPT-5.6 Sol profile as the app:

```sh
make eval-release
```

It runs the 20-case suite three times against the same OpenRouter schema-tool
path used by the default product experience, with seeded Postgres semantic
grading. Engineering comparisons must opt in with
`MODEL=<id> ALLOW_MODEL_OVERRIDE=1`; their gate and triage reports stay in the
run directory rather than replacing committed release docs. A pinned gate
writes the normal `.eval-results/` artifacts, writes `docs/evals/<version>.md`,
and exits nonzero unless the release thresholds pass.
Cloud/OpenRouter is the default text-to-SQL path, but text-to-SQL remains beta
and should not be described as production-ready until that gate passes. Manual
SQL editing, schema browsing, and normal database work remain supported
independently of AI backend configuration.

## Development notes and caveats

- **Ad-hoc code signing.** Debug builds are signed "to run locally". After a
  rebuild, the first Keychain access shows a confirmation prompt - choose
  "Always Allow" (it re-appears after rebuilds because the binary's signature
  changed). For a stable signature, create a self-signed code-signing
  certificate and set `CODE_SIGN_IDENTITY` in `project.yml`.
- **Postgres.app client permissions.** Postgres.app asks per client app
  before allowing a connection. If a connection seems to hang, check
  Postgres.app's Settings > Client Applications and allow Widen.
- **App Sandbox is disabled today.** Developer ID apps can ship outside the
  sandbox, but database permissions remain the real safety boundary. If you
  work on sandboxing, enable the outgoing-network-client entitlement and test
  local Postgres, remote Postgres, Keychain access, and Sparkle updates.
- **SSL modes:** "Prefer"/"Require" encrypt the connection but skip
  certificate verification - local-development semantics for self-signed
  certs. "Disabled" is the default for local Postgres.
- **Model availability** is checked before each generation. If the cloud model
  is not configured, Widen says so without blocking schema browsing or manual
  SQL. If Local is selected and Apple Intelligence is off or the model is not
  downloaded, Widen says so and you can switch back to Cloud or keep writing SQL
  manually.
- The on-device Foundation Models context window is small (~4k tokens). Very
  large schemas are truncated whole-table-at-a-time in the prompt; Widen
  retries once with a tighter budget if the window is exceeded. Cloud models
  get a much larger schema budget.
- **Apple Private Cloud Compute** is not part of the default product path yet.
  Support is planned when Apple's required OS and SDK support is available. On
  current builds, use OpenRouter for cloud generation instead.

## License

MIT - see [LICENSE](LICENSE).
