# Widen Implementation Guide

This document is for engineers and future LLM coding agents working in this
repository. It explains how the Widen MVP is implemented, how data moves
through the app, where the safety boundaries are, and which files to change for
common feature work.

Widen is a native SwiftUI macOS app for asking questions of a local PostgreSQL
database. It introspects the schema, asks Apple's on-device Foundation Model to
draft one read-only PostgreSQL query, validates that SQL deterministically, runs
it inside a read-only transaction, and shows the result table.

The key design rule is simple: the model is helpful but never trusted. Every
query, whether generated or typed manually, passes through the same local
validator and read-only execution path before it can reach PostgreSQL.

## Top-Level Shape

The repository uses XcodeGen plus Swift Package Manager:

```text
project.yml                 XcodeGen source of truth
Widen.xcodeproj/            generated project, committed for convenience
Makefile                    pinned Xcode 26 build/test/run helpers
Widen/                      thin app target
WidenKit/                   framework with app state, models, services, views
WidenTests/                 Swift Testing test target
scripts/sample_db.sql       sample local PostgreSQL database
docs/                       engineer-facing documentation
```

`Widen` is intentionally thin. It contains the app entry point, app icon, and
generated Info.plist. Nearly all implementation lives in `WidenKit` so tests
can exercise business logic without launching the app.

The main dependency is `vapor/postgres-nio` from `1.33.0`. The app also uses
Apple's `FoundationModels` framework when building with the macOS 26 SDK.

## Build And Runtime Assumptions

The project requires Xcode 26 because Foundation Models is only available in
the macOS 26 SDK. The Makefile exports:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.app/Contents/Developer
```

Use the Make targets as the standard entry points:

```sh
make project   # regenerate Widen.xcodeproj from project.yml
make build     # build Debug app
make run       # build and open Debug app
make test      # unit tests, gated integration tests skipped
make test-db   # unit + local PostgreSQL integration tests
make test-fm   # unit + Foundation Models smoke test
```

The app is ad-hoc signed for local development and App Sandbox is disabled in
the MVP so it can connect to local PostgreSQL without provisioning. See the
README for user-facing caveats around Keychain prompts and Postgres.app client
permissions.

## Runtime Object Graph

The central object is `AppState` in `WidenKit/App/AppState.swift`.

`AppState` is `@MainActor` and `@Observable`. It owns:

- `connections: [DatabaseConnectionConfig]` plus per-connection runtime maps:
  `connectionStates` (status), `schemas` (schema cache), `loadingSchemas`,
  and a private lazy `PostgresService` per connection id.
- `sessions: [QuerySession]` (including archived ones), the
  `sidebarSelection` (`SidebarItem.database` or `.session`, with derived
  `selectedSessionID` / `selectedDatabaseID`), and a private cache of
  `SessionController` runtime containers.
- UI state: schema inspector visibility, the Settings tab + open request,
  and the error banner.
- The saved "Use mock AI" toggle.
- Services: `ConnectionStore`, `SessionStore`, `KeychainService`,
  `SchemaIntrospectionService`, and the shared `SchemaViewModel`.

It also exposes `sqlGenerator` and `titleGenerator`, which choose:

- The mock implementations when the developer toggle is enabled.
- `FoundationModelsSQLGenerator` / `FoundationModelsTitleGenerator` when
  available at compile time.
- The mocks as a compile-time fallback when Foundation Models is not
  available.

`SessionController` in `WidenKit/App/SessionController.swift` is the
per-session runtime container. It owns a `ChatViewModel` and a
`QueryResultViewModel`, hydrates them from the persisted `QuerySession`
(`hydrate(from:)`), copies live state back (`snapshot(into:)`, which bumps
`updatedAt` only when something changed), and orchestrates
`submit(appState:)` / `runQuery(appState:)` against the session's
connection. Controllers are cached by `AppState`, so switching sessions
never loses an in-flight generation or query run.

The app's SwiftUI entry point is `Widen/WidenApp.swift`. It creates one
`@State` `AppState`, injects it into the SwiftUI environment, registers the
Settings scene plus commands for New Session, Refresh Schema, Connect, and
Disconnect, and applies the saved appearance preference.

`MainView` in `WidenKit/Views/MainView.swift` builds the application shell:

```text
NavigationSplitView
  sidebar: SidebarView (selectable database rows + their sessions)
  detail:
    ErrorBannerView when needed
    DatabaseOverviewView when a database row is selected
    SessionDetailView for the selected session's controller
      VSplitView
        ChatView
        SQLPreviewView
        QueryResultsView
    .inspector: SchemaInspectorView (toolbar-toggled)
  toolbar: connection chip · light/dark toggle · inspector toggle
```

On first render, `MainView` runs `await appState.onLaunch()`. It also
watches `appState.openSettingsRequest` and opens the Settings window via
`@Environment(\.openSettings)`, and flushes sessions on
`NSApplication.willTerminateNotification`.

## Launch And Connection Flow

Launch flow:

```text
MainView.task
  AppState.onLaunch()
    ConnectionStore.load()    -> connections
    SessionStore.load()       -> sessions (incl. archived)
    restore selection from UserDefaults ("WidenSelectedSessionID"),
      falling back to the most recently updated visible session,
      then to the first database (schema browsing, no session)
    selectSession(...) / selectDatabase(...)
                              -> lazily connects only that database
    no connections            -> open Settings on the Databases tab
```

Databases connect lazily: `connectIfNeeded(_:)` is a no-op when the
connection is already connected or connecting, reads the password from the
Keychain, and loads the schema only when it is not cached yet.
`disconnect(_:)` cancels in-flight runs on that connection's controllers and
keeps the schema cache.

Connection setup lives in:

- `WidenKit/Views/Settings/` (`SettingsView`, `GeneralSettingsView`,
  `DatabasesSettingsView`, `ConnectionEditorForm`,
  `ArchivedSessionsSettingsView`)
- `WidenKit/ViewModels/ConnectionSettingsViewModel.swift`
- `WidenKit/Models/DatabaseConnectionConfig.swift`
- `WidenKit/Services/ConnectionStore.swift`
- `WidenKit/Services/KeychainService.swift`

The password is deliberately not part of `DatabaseConnectionConfig`. The
non-secret config is stored as JSON in:

```text
~/Library/Application Support/Widen/connections.json
```

The password is stored in the macOS Keychain under service `Widen` and account
`connection-<uuid>`.

`ConnectionSettingsViewModel` validates user input before constructing a
config:

- Required fields: name, host, database, username.
- Port: 1 through 65535.
- Row limit: 1 through 10000.
- Statement timeout: 1 through 120 seconds.
- Empty password is allowed for local trust auth.

`Test Connection` calls `PostgresService.testConnection`, which uses a direct
one-shot `PostgresConnection` probe and a 15-second app-level timeout. This is
separate from the long-lived pooled client so authentication errors and missing
database errors surface immediately.

`Save` calls `AppState.addOrUpdateConnection(_:password:)`, which writes the
password to the Keychain and the configs to disk. There is no eager connect —
the database connects when one of its sessions is selected. If an existing
connection's endpoint changed (host/port/database/username/SSL), the live
client and cached schema are invalidated.

`AppState.deleteConnection(_:)` disconnects, deletes the Keychain password,
and cascade-deletes every session belonging to that connection.
`DatabasesSettingsView` shows a confirmation dialog warning about the cascade
before calling it.

## Sessions And Persistence

`QuerySession` (`WidenKit/Models/QuerySession.swift`) is the persisted value:
id, connection id, title (+ `titleWasManuallySet`), `messages`
(`[ChatMessage]`, Codable), `sqlText`, `lastGeneration`, `isArchived`, and
timestamps. Runtime-only state — query results, validation, in-flight flags,
the input draft — is never persisted.

`SessionStore` mirrors `ConnectionStore`: a single
`~/Library/Application Support/Widen/sessions.json` with ISO8601 dates and
atomic pretty-printed writes, plus an `init(directory:)` override for tests.

Persistence flow: views report edits through
`AppState.sessionDidChange(_:)`, which snapshots the controller into the
session value and schedules a debounced (~1s) save. `flushSessions()` writes
immediately and is called on create/rename/archive/delete, on session
switches, and at app termination.

Lifecycle: `createSession(connectionID:)` appends a placeholder-titled
session and selects it. `selectSession(_:)` snapshots the outgoing
controller, gets-or-creates the incoming one, persists the selection to
UserDefaults, and lazily connects the session's database. Archiving hides a
session from the sidebar (recoverable from Settings › Archived Sessions);
Delete Forever removes it permanently.

## Session Auto-Naming

`SessionTitleGenerating` (`WidenKit/Services/SessionTitleGenerator.swift`)
generates a short title from the first question. Implementations:
`FoundationModelsTitleGenerator` (structured `@Generable` output, greedy
sampling, 64 tokens max) and `MockTitleGenerator` (deterministic truncation).

`SessionController.submit(appState:)` detects the first user message of a
session and fire-and-forgets `AppState.autoTitleSession(_:question:)`, which
sanitizes the model's title (`SessionTitleFallback.sanitize`) or falls back
to a word-boundary truncation of the question
(`SessionTitleFallback.title(from:)`). `applyGeneratedTitle` re-checks at
apply time that the user has not renamed the session and that the title is
still the placeholder, so a manual rename always wins.

## PostgreSQL Client Lifecycle

The PostgreSQL client is managed by the actor
`WidenKit/Services/PostgresService.swift`.

Important details:

- `connect` first runs a direct probe to catch bad credentials, missing
  databases, and refused connections early.
- After the probe succeeds, it creates a pooled `PostgresClient`.
- `client.run()` is started once in a long-lived task.
- `disconnect` cancels that run task and drops the client.
- Reconnect always builds a fresh client; cancelled clients are not reused.
- Pool settings are conservative: minimum 0, maximum 4 connections.

`PostgresService.query` is used for schema introspection and simple typed
queries. It decodes rows inside the actor and only returns `Sendable` values
across actor boundaries.

`PostgresService.executeReadOnly` is the only path that executes user or
model-written SQL. It pins all statements to one pooled connection via
`client.withConnection`.

## Schema Introspection

Schema loading is implemented in
`WidenKit/Services/SchemaIntrospectionService.swift`.

It runs three `information_schema` queries:

- Tables and views from `information_schema.tables`.
- Columns from `information_schema.columns`.
- Foreign keys from `information_schema.table_constraints`,
  `key_column_usage`, and `referential_constraints`.

System schemas are excluded:

```sql
table_schema NOT IN ('pg_catalog', 'information_schema')
```

The service returns a `DatabaseSchema` containing:

- `schemas: [SchemaInfo]`
- `tables: [TableInfo]`
- `foreignKeys: [ForeignKeyInfo]`
- `loadedAt: Date`

`TableInfo.id` is the schema-qualified identifier, e.g. `public.users`.
`TableInfo.qualifiedName` is used in prompts and UI display.

`SchemaInspectorView`, `SchemaBrowserView`, and `SchemaViewModel` render the
active connection's schema with search, table selection, and column details
in a toolbar-toggled right inspector. Schemas are cached per connection in
`AppState.schemas`; `refreshSchema(for:)` reloads only the given connection
and preserves the table selection when it still exists.

## Chat-To-SQL Flow

The chat loop is centered in `WidenKit/ViewModels/ChatViewModel.swift`,
orchestrated per session by `SessionController`.

Flow:

```text
ChatView submit
  SessionController.submit(appState:)
    ChatViewModel.submit(schema:generator:config:queryVM:)
      trim input
      require loaded schema
      append user ChatMessage
      call generator.generateSQL(...)
      append assistant or clarification ChatMessage
      queryVM.setGeneration(result)
    sessionDidChange -> debounced save
    first user message -> autoTitleSession (fire-and-forget)
```

Generated SQL is not executed automatically. It fills the editable SQL preview
and is validated immediately. The user still reviews and clicks Run.

Chat transcripts are persisted as part of the session (see "Sessions And
Persistence"); query results are not.

## Prompt Construction

Prompt construction is pure and testable in
`WidenKit/Services/SQLPromptBuilder.swift`.

It exposes:

- `instructions(defaultRowLimit:)`
- `prompt(question:schema:maxSchemaCharacters:)`
- `schemaSummary(_:maxCharacters:)`
- `isSchemaTruncated(_:maxCharacters:)`

The system instructions tell the model to produce one PostgreSQL `SELECT` or
`WITH ... SELECT` query, avoid mutating/DDL/transaction keywords, include a
LIMIT unless appropriate, use only the provided schema, and ask for
clarification when the schema cannot answer the question.

`schemaSummary` renders tables as:

```text
Database schema:

Table public.users
- id integer not null
- email text not null
- name text

Foreign keys:
- public.orders.user_id -> public.users.id
```

The schema summary has a character budget. It drops whole tables once the
budget is exceeded and adds:

```text
(Schema truncated: N more tables omitted.)
```

This avoids cutting a table halfway through and makes the prompt easier to
reason about in tests.

## SQL Generation Backends

The generator protocol is `WidenKit/Services/SQLGenerator.swift`:

```swift
public protocol SQLGenerator: Sendable {
    func generateSQL(
        question: String,
        schema: DatabaseSchema,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult
}
```

There are two implementations:

- `MockSQLGenerator`: deterministic development fallback returning a safe
  `SELECT 1 AS test_value` query.
- `FoundationModelsSQLGenerator`: real local generation using Apple's
  Foundation Models framework.

`FoundationModelsSQLGenerator` is conditionally compiled with:

```swift
#if canImport(FoundationModels)
```

It checks `SystemLanguageModel.default.availability` before each generation.
If unavailable, it throws `AppError.modelUnavailable` with user-readable
guidance.

The real generator uses structured output:

```swift
@Generable
struct GeneratedSQLResponse {
    var sql: String
    var explanation: String
    var assumptions: [String]
    var referencedTables: [String]
    var confidence: Double
    var riskLevel: String
    var needsClarification: Bool
    var clarificationQuestion: String?
}
```

Guides constrain array lengths, risk values, and confidence range. Generation
uses greedy sampling and a maximum response size of 1024 tokens.

The generator creates a fresh `LanguageModelSession` per request. This keeps
generation stateless and avoids accumulating stale chat history in the local
model context.

If generation fails with `exceededContextWindowSize`, it retries once with the
schema budget reduced from 8000 characters to 4000 characters.

## Generated Result Model

`WidenKit/Models/SQLGenerationResult.swift` carries:

- `sql`
- `explanation`
- `assumptions`
- `referencedTables`
- `confidence`
- `riskLevel`
- `needsClarification`
- `clarificationQuestion`

The UI displays the explanation, assumptions, referenced tables, confidence,
and risk level in the chat/SQL preview flow. The SQL text itself is placed into
the editor for validation and manual review.

## SQL Safety Validator

The safety gate is `WidenKit/Services/SQLSafetyValidator.swift`.

It is deliberately conservative. False positives are acceptable; false
negatives are not.

High-level rules:

- Empty SQL is rejected.
- Exactly one trailing semicolon is allowed and stripped.
- Any remaining semicolon is rejected as multiple statements.
- The first token must be `SELECT` or `WITH`.
- Mutating, DDL, transaction, and server-control keywords are forbidden.
- Dangerous functions are forbidden, including `pg_sleep`, `dblink`,
  large-object import/export, file-reading helpers, backend termination,
  advisory locks, notification helpers, and stats reset functions.
- `SELECT ... FOR UPDATE` lock clauses are rejected by tests.

Before token matching, the validator strips or blanks content that should not
affect safety decisions:

- Line comments.
- Nested block comments.
- Standard string literals.
- PostgreSQL escape strings like `E'...'`.
- Quoted identifiers.
- Dollar-quoted strings.

That strip pass prevents keywords hidden in strings or comments from producing
false positives, and prevents quoted identifiers from bypassing dangerous
function checks.

The validator returns `SQLValidationResult`:

- `isValid`
- `normalizedSQL`
- `errors`
- `warnings`
- `hasLimit`

Warnings do not block execution. Current warnings cover:

- Missing LIMIT.
- `SELECT *`.
- `FROM` without `WHERE`.

Every query path uses this validator, including generated SQL and manual SQL.

## Query Execution

The UI calls `SessionController.runQuery(appState:)`, which resolves the
session's connection config, `PostgresService`, and connection state, then
calls `QueryResultViewModel.startRun(connection:postgres:isConnected:)`.

Execution flow:

```text
QueryResultViewModel.run
  validate SQL
  require isConnected and a connection config
  QueryExecutionService.run
    SQLSafetyValidator.validate
    PostgresService.executeReadOnly
```

`QueryResultViewModel.restore(sqlText:generation:)` rehydrates the editor
when a session controller is recreated; unlike `setGeneration`, it never
treats the persisted SQL as a fresh generation.

`QueryExecutionService` re-validates the SQL even if the UI already validated
it. This keeps the service boundary safe.

`PostgresService.executeReadOnly` runs:

```sql
BEGIN READ ONLY
SET LOCAL statement_timeout = <seconds * 1000>
<query>
COMMIT
```

If the validator did not find a top-level LIMIT, execution wraps the query:

```sql
SELECT * FROM (
<user sql>
) AS widen_subquery LIMIT <defaultRowLimit + 1>
```

The extra row is only used to detect truncation. If present, it is dropped from
the returned result and `QueryResult.truncated` is set to `true`.

On any error after `BEGIN`, execution attempts `ROLLBACK` so the pooled
connection is returned in a clean state.

Statement timeout is the server-side enforcement. Cancelling the Swift task
only stops the app from waiting; it does not cancel the PostgreSQL backend
query. This is called out in `QueryResultViewModel.cancelRun`.

## Result Decoding And CSV

`WidenKit/Services/PostgresCellFormatter.swift` converts PostgreSQL binary
cells into display strings. It handles common scalar types explicitly and falls
back to UTF-8 strings when possible. Unknown binary values are rendered as a
type/byte-count placeholder.

`QueryResult` contains:

- `columns: [String]`
- `rows: [[String?]]`
- `rowCount`
- `truncated`
- `executionTimeMs`

It also exposes CSV rendering with standard quoting for commas, quotes, and
newlines. `QueryResultsView` uses that for Copy CSV.

## UI Responsibilities

The UI is intentionally thin and uses view models for behavior.

Key views:

- `SidebarView` + `Sidebar/DatabaseGroupRow` + `Sidebar/SessionRow`: one
  section per database — the database itself is a selectable row (status
  badge on the icon, endpoint caption, hover "+", context menu) that opens
  its schema in the inspector, with its sessions indented beneath it
  (inline rename, archive, placeholder styling) and an "Add Database"
  footer.
- `DatabaseOverviewView`: detail pane for a selected database row — the
  connection at a glance plus a New Session call to action.
- `SessionDetailView`: hosts ChatView / SQLPreviewView / QueryResultsView for
  one session's controller and reports edits via `sessionDidChange`.
- `SchemaInspectorView` + `SchemaBrowserView`: toolbar-toggled inspector with
  table search, table list, and selected table columns.
- `Settings/SettingsView` (+ General / Databases / Archived Sessions tabs,
  `ConnectionEditorForm`): appearance, AI toggle, connection CRUD with
  cascade-delete warning, archive restore / delete forever.
- `ChatView`: natural language input and generated response history (glass
  input bar; the user bubble is glass, assistant/error bubbles use a plain
  material to keep scrolling cheap).
- `SQLPreviewView`: editable SQL text, validation messages, generation
  metadata, Validate, Run, Copy SQL, Clear.
- `QueryResultsView`: result metadata, horizontal/vertical grid, Copy CSV,
  empty/loading/error states.
- `ErrorBannerView`: dismissible app-level error banner (red-tinted glass).
- `LoadingView`: small reusable loading indicator.

Appearance: the `"WidenAppearance"` AppStorage key (`AppearancePreference`)
drives `.preferredColorScheme` on the window and Settings roots. The toolbar
sun/moon button flips to the opposite of the effective scheme; the "System"
reset lives in Settings › General. Liquid Glass styling (`.glassEffect`,
`.buttonStyle(.glass)/.glassProminent`, `GlassEffectContainer`) is used for
chat input, primary buttons, the connection chip, and the error banner; the
sidebar, inspector, and results grid intentionally keep system materials.

Keyboard behavior:

- Enter in chat submits for generation.
- Cmd+Enter in the SQL editor runs the current SQL.
- Cmd+N creates a session on the active (or first) database.
- Cmd+R refreshes the active connection's schema through the Database menu.

## Error Mapping

Errors are represented in `WidenKit/Models/AppError.swift`.

PostgreSQL-specific mapping lives in
`WidenKit/Services/PostgresErrorMapper.swift`. It maps common `PSQLError`
server information into user-readable app errors. SQL state `57014` is treated
as a statement timeout.

The view models generally store user-facing error strings instead of raw
errors:

- `AppState.errorBanner` for global errors.
- `QueryResultViewModel.runError` for query execution errors.
- `ChatViewModel` appends error chat messages for generation failures.

## Tests

Tests use Swift Testing in `WidenTests/`.

Main suites:

- `SQLSafetyValidatorTests`: allow/reject lists, strings, comments,
  dollar-quotes, dangerous functions, warnings.
- `SQLPromptBuilderTests`: schema rendering, prompt content, truncation, system
  schema exclusion.
- `ConnectionStoreTests`: multi-connection persistence round trips and
  password exclusion (plus `ConnectionSettingsViewModel` validation).
- `SessionStoreTests`: session round trips (generation metadata, archived
  flag), missing file, corrupted JSON, and `ChatMessage` Codable stability.
- `AppStateSessionTests`: session lifecycle against temp-dir stores —
  create/select, controller-cache identity, snapshot-on-switch,
  archive/restore/delete, title guards, auto-title (stub generators), and
  connection cascade-delete.
- `SessionTitleTests`: fallback truncation, sanitizer rules, mock generator
  determinism.
- `PostgresIntegrationTests`: gated local PostgreSQL tests for connection,
  introspection, execution, truncation, mutation blocking, and timeout.
- `FoundationModelsSmokeTests`: gated local model availability, structured
  SQL generation, and session-title generation tests.
- `ChatViewModelTests`: chat flow and preview population (the internal
  `submit(schema:generator:config:queryVM:)` seam).
- `WidenKitTests`: smoke tests plus `QueryResultViewModel` run/restore
  behavior.

Default `make test` skips the gated suites unless the relevant environment
variables are set by Make:

```text
make test-db -> TEST_RUNNER_WIDEN_TEST_DB=<db name>
make test-fm -> TEST_RUNNER_WIDEN_FM_TEST=1
```

Run `make test-db` after changes to connection, introspection, execution,
cell formatting, or safety behavior. Run `make test-fm` after changes to
Foundation Models generation, prompt shape, or structured output.

## Common Change Guide

Add a new connection setting:

1. Add the field to `DatabaseConnectionConfig`.
2. Update default form state in `ConnectionSettingsViewModel` (including
   `startNew()`).
3. Add validation in `ConnectionSettingsViewModel.validationErrors`.
4. Add UI in `Settings/ConnectionEditorForm`.
5. Update `ConnectionStoreTests`.
6. If it affects Postgres connection behavior, update `PostgresService` and
   consider `AppState.addOrUpdateConnection`'s endpoint-change invalidation.

Change SQL safety policy:

1. Update `SQLSafetyValidator`.
2. Add allow/reject tests first.
3. Run `make test` and `make test-db`.
4. Consider whether prompt instructions need to match the policy.

Change the prompt:

1. Update `SQLPromptBuilder`.
2. Update `SQLPromptBuilderTests`.
3. Run `make test-fm` to ensure structured generation still works.
4. Keep the prompt concise; the local model context window is limited.

Add a result display feature:

1. Extend `QueryResult` only if the data model really needs new state.
2. Prefer formatting in `PostgresCellFormatter` or `QueryResult` rather than
   directly in SwiftUI views.
3. Update `QueryResultsView`.
4. Add unit tests if formatting or export behavior changes.

Add another SQL generator:

1. Implement `SQLGenerator`.
2. Decide where `AppState.sqlGenerator` chooses it.
3. Keep `SQLGenerationResult` as the common output.
4. Do not bypass `SQLSafetyValidator` or `QueryExecutionService`.

Add per-session state:

1. Decide whether it is persistent (add to `QuerySession`, hydrate/snapshot
   in `SessionController`) or runtime-only (keep it on the controller or its
   view models).
2. Wire change reporting through `sessionDidChange` if it should be saved.
3. Update `SessionStoreTests` / `AppStateSessionTests`.
4. Never persist query results, passwords, or model prompts.

## Invariants Future Work Should Preserve

- The app remains local-only: no backend and no external LLM API calls.
- Passwords are never stored in `DatabaseConnectionConfig` or JSON files.
- Query results are never persisted; `sessions.json` holds transcripts, SQL
  text, and generation metadata only.
- A manual session rename is never overwritten by the auto-namer.
- Generated SQL is never auto-executed.
- Manual and generated SQL share the exact same validation and execution path.
- Only `SELECT` or `WITH ... SELECT` statements can reach PostgreSQL.
- Execution always uses `BEGIN READ ONLY`.
- Execution always applies a statement timeout.
- Queries without LIMIT are capped with the configured default row limit.
- System schemas are excluded from prompt context.
- Foundation Models availability failures are user-readable and do not block
  manual SQL usage.
- Tests should cover safety-policy changes before behavior is broadened.

## Files To Read First

For most onboarding or agent work, read these files in order:

1. `README.md` for setup, limitations, and user-facing behavior.
2. `WidenKit/App/AppState.swift` for ownership and runtime flow.
3. `WidenKit/App/SessionController.swift` for the per-session runtime
   container and persistence glue.
4. `WidenKit/Views/MainView.swift` for UI composition.
5. `WidenKit/Services/PostgresService.swift` for connection and execution.
6. `WidenKit/Services/SQLSafetyValidator.swift` for the safety boundary.
7. `WidenKit/Services/FoundationModelsSQLGenerator.swift` for local AI
   generation.
8. `WidenKit/Services/SQLPromptBuilder.swift` for prompt shape.
9. `WidenKit/ViewModels/QueryResultViewModel.swift` for SQL preview and run
   behavior.
10. `WidenTests/SQLSafetyValidatorTests.swift` and
    `WidenTests/PostgresIntegrationTests.swift` for expected behavior.

When in doubt, preserve the existing service boundaries and add tests around
the behavior you are changing.
