# Widen

Free, local and open-source Postgres GUI for your Mac, with natural language
to SQL support — fully offline by default, with optional cloud pro models.

Widen introspects your schema, drafts a read-only SQL query with **Apple's
on-device Foundation Model**, shows you the SQL to review and edit, and runs
it safely - all locally.

- **Local by default.** No backend, no accounts, no analytics. Out of the box
  the only network connection is the PostgreSQL connection you configure.
- **Optional cloud pro models.** Flip the toolbar cloud toggle to generate
  with a bigger model: **Apple Private Cloud Compute** (macOS 27+, free with
  a daily limit) or any model via your own **OpenRouter** API key. Configure
  in Settings › LLM; everything keeps working fully local if you never turn
  it on.
- **Read-only by design.** Every statement (yours or the model's) goes through
  a deterministic safety validator: single `SELECT`/`WITH` statements only,
  executed inside a `READ ONLY` transaction with a statement timeout and a row
  limit.
- **Private.** By default prompts go to Apple's local Foundation Model through
  macOS and your schema and queries never leave your machine. With a cloud pro
  model enabled, your questions and the relevant schema go to the provider you
  chose — query results still never leave your Mac. Passwords and API keys
  live in the macOS Keychain, never on disk in plaintext.
- **Multiple databases, persistent sessions.** Configure any number of
  PostgreSQL connections in Settings; each one is a group in the sidebar.
  Select a database to browse its schema, or press "+" on it to start a
  query session — a persistent chat + SQL + results workspace that survives
  restarts and is auto-named by the local model after your first question.
- **Modern macOS 26 look.** Liquid Glass styling, a schema inspector panel,
  a local/cloud LLM toggle in the toolbar, and a light/dark toggle in the
  sidebar footer.

## Requirements

- **macOS 26 or later** on **Apple Silicon** (Foundation Models requirement).
- **Apple Intelligence enabled** (System Settings > Apple Intelligence & Siri)
  for AI generation. Without it, the app still works for manual SQL, or flip
  on "Use mock AI" in Settings for development.
- **Xcode 26** to build (the macOS 26 SDK ships FoundationModels).
- A local **PostgreSQL** server ([Postgres.app](https://postgresapp.com) works
  great).

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

Release packaging is prepared for Developer ID distribution. Debug stays ad-hoc
signed for local development. The release script reads local signing, notarizing,
bundle ID, and Sparkle values from environment variables or
`.env.release.local`:

```sh
cp .env.release.example .env.release.local
make release-mac
```

See [docs/release.md](docs/release.md) for the full signed DMG, Sparkle, and
static website release runbook.

For codebase onboarding and implementation details, see
[docs/implementation-guide.md](docs/implementation-guide.md).

## Sample test database

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

> **Safety tip:** connect with a read-only Postgres user when using
> AI-generated SQL. Widen enforces read-only execution itself, but defense in
> depth is cheap.

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
   (anything starting with `SELECT`/`WITH` skips the model entirely).
2. For questions, Widen prompts the local model with the open schema's
   tables, columns, types, and foreign keys (system schemas excluded) plus
   the safety rules, and gets structured output back: SQL, explanation,
   assumptions, referenced tables, confidence, and risk level.
3. The SQL appears in the chat as a read-only dashed card, validated
   deterministically: only a single `SELECT`/`WITH` statement, no
   semicolons, no mutation/DDL/transaction keywords, no
   `pg_sleep`/`dblink`/`lo_*`. Validation issues sit behind the card's
   status icon. Keep chatting (or paste corrected SQL) until it's right.
4. Run executes it in a `BEGIN READ ONLY` transaction with
   `SET LOCAL statement_timeout` (default 10s). Queries without a `LIMIT` are
   wrapped in a subquery with your default row limit (default 100).
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
- **Apple Private Cloud Compute** (announced WWDC 2026) needs macOS 27, a
  build made with Xcode 27, and Apple's `com.apple.developer.private-cloud-compute`
  entitlement on a properly signed build — see
  [docs/implementation-guide.md](docs/implementation-guide.md). On macOS 26,
  use OpenRouter for cloud generation instead.

## MVP limitations

- PostgreSQL only.
- Results are stringified text (no typed grid, no export-to-file).
- No SQL syntax highlighting.
- Query results are not persisted across restarts (transcripts, SQL text,
  and generation metadata are; rerun a session's query to repopulate the
  grid).

## License

MIT - see [LICENSE](LICENSE).
