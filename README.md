# Widen

**Ask Postgres with the LLM already on your Mac.**

Widen is a free, open-source, native macOS Postgres GUI for macOS 26+.
It introspects your schema, drafts SQL with Apple's on-device Foundation Model
through the macOS Foundation Models framework, shows every query for review,
and only runs what you approve.

No backend. No account. No analytics. Local by default.

[Download for Mac](https://github.com/betocmn/widen/releases/latest/download/Widen.dmg)
· [Build from source](#build-and-run)
· [Release notes](https://github.com/betocmn/widen/releases/latest)

`macOS 26+` · `Apple Silicon` · `Apple Intelligence for local AI` ·
`No backend` · `No account` · `MIT` · `Postgres-only MVP`

## What makes this new?

Starting with macOS 26, supported Apple Silicon Macs can run Apple's Foundation
Model on-device. Widen uses that local model for a practical developer
workflow: turning schema-aware questions into SQL you can inspect before
running.

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
| macOS 26 or later | Required for the Foundation Models framework. |
| Apple Silicon | Required for Apple's on-device Foundation Model. |
| Apple Intelligence enabled | Required for local AI generation. Manual SQL still works without it. |
| PostgreSQL | Widen is Postgres-only today. [Postgres.app](https://postgresapp.com) works well for local testing. |
| Xcode 26 | Only needed when building from source. |

## What leaves your Mac?

Out of the box, the only network connection is the PostgreSQL connection you
configure.

| Mode | Schema/question | Query results | Notes |
| --- | ---: | ---: | --- |
| Local mode | Stays on your Mac | Stays on your Mac | Default. Prompts go to Apple's local Foundation Model through macOS. |
| Cloud mode | Sent to the provider you choose | Stays on your Mac | Optional. Use Apple Private Cloud Compute on macOS 27+, or OpenRouter with your own API key. |

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

Widen is a lightweight, native, local-first Postgres workbench for browsing
schemas, keeping query sessions, and turning questions into SQL:

- Configure any number of PostgreSQL connections in Settings.
- Browse the selected database's schemas, tables, columns, types, and foreign
  keys in the inspector.
- Keep persistent chat + SQL + results sessions that survive restarts.
- Switch between the local model and optional cloud models from the toolbar.
- Use the modern macOS 26 Liquid Glass interface with light/dark appearance.

## Known limitations

- PostgreSQL only.
- Early MVP, not full DataGrip/TablePlus/Postico feature parity.
- The local Foundation Model has a small context window; very large schemas are
  truncated whole-table-at-a-time before prompting. If you need a stronger
  model, Widen already supports cloud generation with your own OpenRouter API
  key, and includes support for Apple's Private Cloud Compute models in the
  upcoming September OS releases.
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
Xcode (older SDKs have no FoundationModels and a lower deployment target).

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
2. For questions, Widen prompts the local model with the open schema's
   tables, columns, types, and foreign keys (system schemas excluded) plus
   the safety rules, and gets structured output back: SQL, explanation,
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

## Development notes and caveats

- **Ad-hoc code signing.** Debug builds are signed "to run locally". After a
  rebuild, the first Keychain access shows a confirmation prompt - choose
  "Always Allow" (it re-appears after rebuilds because the binary's signature
  changed). For a stable signature, create a self-signed code-signing
  certificate and set `CODE_SIGN_IDENTITY` in `project.yml`.
- **Postgres.app client permissions.** Postgres.app asks per client app
  before allowing a connection. If a connection seems to hang, check
  Postgres.app's Settings > Client Applications and allow Widen.
- **App Sandbox is disabled** for this development build so the app can reach
  local PostgreSQL without provisioning. Before any distribution, enable the
  sandbox with the outgoing-network-client entitlement.
- **SSL modes:** "Prefer"/"Require" encrypt the connection but skip
  certificate verification - local-development semantics for self-signed
  certs. "Disabled" is the default for local Postgres.
- **Model availability** is checked before each generation. If Apple
  Intelligence is off or the model is not downloaded, Widen says so and you
  can keep writing SQL manually, configure a cloud model (Settings › LLM), or
  enable mock mode.
- The on-device Foundation Models context window is small (~4k tokens). Very
  large schemas are truncated whole-table-at-a-time in the prompt; Widen
  retries once with a tighter budget if the window is exceeded. Cloud models
  get a much larger schema budget.
- **Apple Private Cloud Compute** needs macOS 27, a
  build made with Xcode 27, and Apple's `com.apple.developer.private-cloud-compute`
  entitlement on a properly signed build — see
  [docs/implementation-guide.md](docs/implementation-guide.md). On macOS 26,
  use OpenRouter for cloud generation instead.

## License

MIT - see [LICENSE](LICENSE).
