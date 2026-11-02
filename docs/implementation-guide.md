# Widen Implementation Guide

This document is for engineers and future LLM coding agents working in this
repository. It explains how the Widen MVP is implemented, how data moves
through the app, where the safety boundaries are, and which files to change for
common feature work.

Widen is a native SwiftUI macOS app for asking questions of a PostgreSQL
database. It introspects the schema and drafts SQL with Particle-1, a cloud
model from Particle, using the user's own API key. Particle-1 is the only
text-to-SQL model; there is no on-device or offline generator. Widen validates
generated SQL deterministically and shows it for review before anything runs.

The key design rule is simple: the model is helpful but never trusted. Every
query, whether generated or typed manually, passes through the same local
validator and read-only execution path before it can reach PostgreSQL.

## Top-Level Shape

The repository uses XcodeGen plus Swift Package Manager:

```text
project.yml                 XcodeGen source of truth
Widen.xcodeproj/            generated project, committed for convenience
Makefile                    build/test/run helpers with shared Xcode discovery
Widen/                      thin app target
WidenKit/                   framework with app state, models, services, views
WidenTests/                 Swift Testing test target
scripts/sample_db.sql       sample local PostgreSQL database
docs/                       engineer-facing documentation
```

`Widen` is intentionally thin. It contains the app entry point, app icon, and
generated Info.plist. Nearly all implementation lives in `WidenKit` so tests
can exercise business logic without launching the app.

The main dependency is `vapor/postgres-nio` from `1.33.0`; the app target also
embeds Sparkle for updates. Text-to-SQL calls Particle's OpenAI-compatible
chat-completions API through `URLSession`, with no model SDK.

## Build And Runtime Assumptions

The app deployment target is macOS 14.0. The project requires Xcode 26 or later
for source builds because Liquid Glass code is compiled behind availability
checks against the macOS 26 SDK. Setup, Make targets, and release scripts use
`scripts/xcode-developer-dir.sh` to honor `DEVELOPER_DIR`, then prefer the
selected full Xcode, the standard Xcode app, and other installed Xcode apps,
skipping any older than Xcode 26. For an explicit override:

```sh
make build DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer
```

Use the Make targets as the standard entry points:

```sh
make project   # regenerate Widen.xcodeproj from project.yml
make build     # build Debug app
make run       # build and open Debug app
make test      # unit tests, gated integration tests skipped
make test-db   # unit + local PostgreSQL integration tests
make eval-release  # text-to-SQL release gate (pinned Particle-1; paid)
```

The app is ad-hoc signed for local development and App Sandbox is disabled in
the MVP so it can connect to local PostgreSQL without provisioning. See
Development Notes And Caveats below for the Keychain-prompt and Postgres.app
client-permission consequences.

## Development Notes And Caveats

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
- **Text-to-SQL readiness.** Without a Particle API key, generation fails with
  a message that points at Settings › LLM, and the toolbar chip and chat show
  a warning; schema browsing and manual SQL keep working. A rejected key,
  exhausted credits, or a key without inference scope on a real request also
  turns the chip into a warning. That state is kept in memory only, so after
  a relaunch the chip reads ready again until the next such failure. A
  connection that turns off schema metadata sharing can't use text-to-SQL.
- **Particle-1 has no dated snapshots.** Widen checks that every response
  reports `particle-ai/particle-1`, which verifies the model name only. Particle
  can change the model behind that name without a Widen release.
- **The first launch of a build deletes retired AI state** on that Mac,
  including the old OpenRouter Keychain item (see "Preferences, secrets, and
  launch cleanup"). Running a development build does this to your own
  Keychain once.

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

It also exposes the text-to-SQL entry points:

- `sqlGenerator(connectionID:schema:)`, which live sessions call. It returns
  the mock generator when the developer toggle is on, `UnavailableSQLGenerator`
  when no Particle key is saved or the connection turns off schema metadata
  sharing, and otherwise `SchemaToolSQLAgent` on the Particle-1 profile.
- `titleGenerator(for:connectionID:)`, which returns `ParticleTitleGenerator`
  only under the rule in "Session Auto-Naming" and the deterministic
  `MockTitleGenerator` otherwise.
- `textToSQLStatus` (`ready`, `mock`, `notConfigured`, `unavailable`), which
  the toolbar chip, the chat, and Settings › LLM read. `particleRuntimeIssue`
  holds a rejected key, missing credits, or missing inference scope reported
  by a real request or Test Connection, until a later one succeeds or the key
  changes.

`SessionController` in `WidenKit/App/SessionController.swift` is the
per-session runtime container. It owns a `ChatViewModel` and a
`QueryResultViewModel`, hydrates them from the persisted `QuerySession`
(`hydrate(from:)`), copies live state back (`snapshot(into:)`, which bumps
`updatedAt` only when something changed), and orchestrates
`submit(appState:)` / `runQuery(appState:)` against the session's
connection. Controllers are cached by `AppState`, so switching sessions
never loses an in-flight generation or query run.

`runQuery`, via the `startRun` completion hook, appends the outcome to the
transcript: a `.result` `ChatMessage` (with a `RunSummary` of row count,
duration, truncation, and the executed SQL) on success, or an `.error`
message on failure or "stopped waiting" cancellation. The materialized
result is cached in `SessionController.results` keyed by the record's
message id, so every run of the live session keeps its full table card in
the thread; the cache is never persisted — after a relaunch records render
as compact summary rows. `clearConversation()` wipes transcript, preview,
and cache together.

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
      ChatModeView — one chronological chat thread:
        messages, where SQL-bearing messages carry their card inline
        (newest = runnable SQLCardView, earlier = StaticSQLCardView) and
        run records render their ResultsCardView while cached
        + ComposerView pinned at the bottom
    SchemaInspectorView: fixed-width trailing content column, scoped to the schema
  toolbar: system sidebar toggle · Widen title · breadcrumb
           (status dot · database › schema menu) · Particle-1 status
           (ParticleStatusChip; opens Settings › LLM) · inspector toggle.
           macOS manages the control backgrounds and spacing.
           The System/Light/Dark appearance switch
           lives in the sidebar footer next to "Add Database".
```

The sidebar uses the built-in toggle, with no custom toolbar spacers or
background overrides. The schema inspector is a regular trailing content column
with a system material background, avoiding a second native split controller
around `NavigationSplitView`. The window minimum is 1000 points with the schema
panel open and 700 with it closed; the initial size is set on the window scene.
There is no automatic panel toggle based on content geometry. Table and column
lists hide their scroll backgrounds so the panel keeps one continuous material.

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
A file that fails to decode is copied to `sessions.unreadable-<ISO 8601
basic timestamp>.json` beside it before `load()` throws
`SessionStore.UnreadableFileError`, and the launch banner names the copy: the
app then starts with no sessions, and its next save rewrites `sessions.json`.

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
`ParticleTitleGenerator` (`WidenKit/Services/ParticleTitleGenerator.swift`)
and `MockTitleGenerator` (deterministic truncation).

`ParticleTitleGenerator` sends one request at the profile's `sessionTitle`
call site: reasoning off, at most 64 completion tokens, no tools, no
`response_format`, a 10-second timeout, and no retries. The only user message
is the trimmed question, cut to 500 characters; no schema, database context,
or results are sent. The reply goes through the shared parser, so a provider
error or a model other than `particle-ai/particle-1` throws.

`SessionController.submit(appState:)` records whether the input was direct SQL
or a plain-English question before submitting clears it. After the first user
message of a session it starts `AppState.autoTitleSession` with the question,
that source, and the session's connection, without awaiting it.
`AppState.titleGenerator(for:connectionID:)` picks Particle-1 only when the
message was a plain-English question, mock AI is off, Particle has reported
no runtime issue, the connection allows schema metadata sharing, and a key is
saved; anything else gets `MockTitleGenerator`, so the title is made on the
Mac. `autoTitleSession` sanitizes the model's title
(`SessionTitleFallback.sanitize`) or, if the request fails or the title is
unusable, falls back to a word-boundary truncation of the question
(`SessionTitleFallback.title(from:)`).
`applyGeneratedTitle` re-checks at apply time that the user has not renamed
the session and that the title is still the placeholder, so a manual rename
always wins.

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
active connection's schema in a toolbar-toggled right inspector: a schema
picker, a flat searchable table list scoped to the open schema, and the
selected table's columns. Schemas are cached per connection in
`AppState.schemas`; `refreshSchema(for:)` reloads only the given connection
and preserves the table selection when it still exists.

The "open schema" is per-connection UI state: `AppState.selectedSchemaNames`
(persisted in UserDefaults under `"WidenSelectedSchemaNames"`), read through
`currentSchemaName(for:)`, which falls back to `public`, then to the first
schema, whenever the stored choice no longer exists in the loaded schema.
It is switchable from the toolbar breadcrumb and the inspector picker (both
bind through `selectSchema(_:for:)`). It scopes both the inspector table
list and the generation prompt: `promptSchema(for:)` returns the cached
schema narrowed by `DatabaseSchema.filtered(toSchema:)` — that schema's
tables plus only the foreign keys whose both ends live in it.

## Chat-To-SQL Flow

The chat loop is centered in `WidenKit/ViewModels/ChatViewModel.swift`,
orchestrated per session by `SessionController`.

Flow:

```text
ComposerView submit
  SessionController.submit(appState:)
    ChatViewModel.isDirectSQL(input)?      // leading SELECT/WITH word
      yes: ChatViewModel.submitDirectSQL(queryVM:)
        append user ChatMessage (the SQL itself)
        queryVM.setDirectSQL(sql)          // no model call
      no: SessionController.submitGeneratedSQL(appState:)
        trim input
        require loaded schema              // promptSchema(for:) — open schema only
        append user ChatMessage
        TextToSQLPipeline.run(...)         // generate, ground, validate, repair
        append assistant or clarification ChatMessage
        queryVM.setGeneration(result)
    sessionDidChange -> debounced save
    first user message -> autoTitleSession (fire-and-forget)
```

Generated SQL is not executed automatically. It renders as the read-only
`SQLCardView` right below the message that introduced it (dashed accent
border, validation status icon with a popover for the messages, compact
generation caption, Run button). Earlier SQL stays in the thread as
`StaticSQLCardView` records — visible, copyable, but only the newest SQL can
run. The user refines by chatting or by pasting new SQL into the composer.
Run keeps the thread flowing: a "Running query…" indicator appears, and the
outcome lands chronologically after the SQL — each run record renders its
inline `ResultsCardView` (bordered table, "View more" past 10 rows,
Copy/Export CSV) while its result is cached on the controller.

Chat transcripts — including `.result` run records — are persisted as part
of the session (see "Sessions And Persistence"); materialized query results
are not, so full results cards only render during the live session — after
a relaunch the records show as compact summary rows.

## Prompt Construction

Prompt construction is pure and testable in
`WidenKit/Services/SQLPromptBuilder.swift`, which builds the one-shot
`CloudSQLGenerator` prompt. The schema-tool agent writes its own system
instructions and first user message in `SchemaToolSQLAgent` and fetches
schema through tools instead of a schema summary; both read the same
`SQLGenerationContext`.

It exposes:

- `instructions(defaultRowLimit:)`
- `prompt(question:schema:context:maxSchemaCharacters:)`
- `contextSection(_:)`
- `schemaSummary(_:maxCharacters:)`
- `isSchemaTruncated(_:maxCharacters:)`

The system instructions tell the model to produce one PostgreSQL `SELECT` or
`WITH ... SELECT` query, use PostgreSQL date/interval syntax (never MySQL
idioms like `CURDATE()`), avoid mutating/DDL/transaction keywords, include a
LIMIT unless appropriate, use only the provided schema, treat the question
as a follow-up to any conversation context in the prompt, and ask for
clarification when the schema cannot answer the question.

Every generation starts fresh, with no chat history kept at the provider, so
follow-ups work through `SQLGenerationContext` (defined with the
`SQLGenerator` protocol): up to three earlier user questions, the recent
conversation, the SQL currently on screen, and the last run error, each with
a tight character budget, plus the connection's confirmed definitions.
`SessionController.submitGeneratedSQL` assembles it from the transcript and
`QueryResultViewModel` before appending the new question —
this is what lets "the query is failing" produce a corrected version of the
failing SQL instead of an unrelated query.

`GenerationLog` appends each one-shot `CloudSQLGenerator` generation (full
prompt plus structured outcome or error) to
`~/Library/Application Support/Widen/generation.log`. The schema-tool agent
that live sessions use does not write it. Plain text, local only,
best-effort. WidenEval turns it off unless `--record-prompts` is passed.

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
        context: SQLGenerationContext,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult
}
```

There are four implementations:

- `MockSQLGenerator`: deterministic development fallback returning a safe
  `SELECT 1 AS test_value` query. The "Use mock AI (developer)" toggle in
  Settings › LLM selects it.
- `SchemaToolSQLAgent` (`WidenKit/Services/SchemaToolSQLAgent.swift`): the
  production path, built on the Particle-1 profile for every live session.
  Instead of a full schema prompt, it gives Particle-1 bounded,
  host-controlled schema tools (plus privacy-gated database inspection tools
  when the connection allows them) and finishes when the model calls the
  terminal tool `submit_text_to_sql_result`. It runs with
  `SchemaToolSQLAgentConfiguration.default` (see "Schema-Tool Agent,
  Grounding, And Repairs"). Users cannot turn the agent off or choose another
  model.
- `CloudSQLGenerator` (`WidenKit/Services/CloudSQLGenerator.swift`): the
  legacy one-shot generator. It sends the packaged schema prompt in one
  request and parses one JSON object. WidenEval runs it with
  `--cloud-agent legacy`. In the app it is reachable only through the
  context-free `AppState.sqlGenerator` property, which no live session calls,
  and as the agent's fallback for a model without tool support, which
  Particle-1's fixed capabilities never trigger.
- `UnavailableSQLGenerator`: throws a user-readable message when no Particle
  key is saved or the connection turns off schema metadata sharing, so
  production never silently swaps to another backend.

### Particle-1 profile and request signing

`CloudModelProfile` (`WidenKit/Models/CloudModelProfile.swift`) describes one
model at one provider: base URL and paths, the requested and expected returned
model IDs, the identity policy, capabilities, prices, a policy per call site,
timeouts, error-code maps, and the API-key prefixes that belong to other
providers. `CloudModelCatalog.productionProfile` is `.particle`, the only
profile the app builds:

| Setting | Particle-1 |
|---|---|
| Endpoint | `https://api.particle.ai/v1/chat/completions` |
| Requested model | `particle-1` |
| Required returned model | `particle-ai/particle-1`, exact match |
| Capabilities | Fixed in the profile; no catalog request |
| Prices (USD per 1M tokens) | $0.25 input, $0.03 cached input, $1.00 output |
| Timeouts | 180 s per request, 300 s per resource |

| Call site | Reasoning effort | Max completion tokens | Response format |
|---|---|---|---|
| `agentTurn` | `high` | 16,000 | None; tools with `tool_choice: required` |
| `oneShotSQL` | `high` | 16,000 | `json_object` |
| `connectivityProbe` | `none` | 256 | `json_object` |
| `sessionTitle` | `none` | 64 | None |
| `groundingJudge` | `low` | 8,000 | `json_object`; no tools |
| `critic` | `high` | 16,000 | `json_object`; no tools |

Agent turns and one-shot requests send one `prompt_cache_key` per generation
run; the grounding judge and the critic send it with a `-grounding` or
`-critic` suffix. Particle requests never send a `provider` routing object,
`temperature`, `max_tokens`, `n`, `seed`, OpenRouter's `X-` headers, or a
tool-message `name`. Particle reports no `usage.cost`, so `costUSD` is
estimated from the usage tokens at the peak list prices above and recorded
with `costSource` `estimatedPeakList`; it is an upper bound. Every completion
must report `particle-ai/particle-1` before its content is used. Particle
publishes no dated snapshots, so this verifies the model name only.

Failures become `CloudRequestFailure`
(`WidenKit/Services/ChatCompletionsCore.swift`) with a category from
Particle's typed `error.code` first, then `error.type`, then the HTTP status.
A rejected key (401), missing credits (402), missing inference scope (403),
unknown model (404), or too-large request (413) is not retried. Rate limits
(429, with a `Retry-After` of up to 15 seconds) and 5xx responses are retried
within the HTTP-attempt budget. `invalid_model_output` is resent once (the
one-shot generator adds a corrective message, the grounding judge and the
critic append one to their prompt, and agent turns resend unchanged) and is
then reported as a parsing failure, not a transport failure.

`CloudModelProfile.authorizedRequest(_:apiKey:)` is the only code that sets
`Authorization`. Before anything is sent, it refuses a URL that is not https
on the profile's host and port, and a key with another provider's prefix
(`sk-or-` for Particle). `URLSessionTransport` refuses redirects, so a signed
request cannot be forwarded to another host. `AppState.setParticleAPIKey(_:)`
also refuses `sk-or-` keys.

### OpenRouter: eval-only comparison profile

`CloudModelProfile.openRouterGPT55` (the previous production model,
`openai/gpt-5.5`) and the `CloudModelProfile.openRouter(...)` factory stay in
WidenKit only so WidenEval can compare against them. `CloudModelCatalog.profile(forRequestedModelID:)` maps
`particle-1` to Particle-1 and any `vendor/model` ID to OpenRouter. OpenRouter
profiles send the same requests the app sent before 0.2.0: the
zero-data-retention `provider` block, the `X-Title` and `X-OpenRouter-Metadata`
headers, and capabilities from the authenticated OpenRouter catalog, cached
under `~/Library/Caches/WidenEval/`. Only the pinned GPT-5.5 comparison model
verifies a dated canonical version. OpenRouter-only code lives in
`WidenKit/Services/OpenRouterEvalSupport.swift`. The app and view layers never
reference these profiles: `AppLayerProviderIsolationTests` scans
`WidenKit/App` and `WidenKit/Views` for OpenRouter symbols and hosts.

### Backend selection and Settings › LLM

`AppState.sqlGenerator(connectionID:schema:)` checks, in order, the test
override, mock mode, a saved Particle key, and the connection's
`allowCloudSchemaMetadata`, then builds `SchemaToolSQLAgent` on
`CloudModelCatalog.productionProfile` with the connection's database
inspection policy for the cloud audience. There is no backend mode, provider,
or model preference. `make eval-release` builds the same agent on the same
profile and configuration (critic off, grounding judge on), but with no
inspection policy, inspection database or schema fingerprint, so the gate
never offers data-inspection tools or runs the stale-schema check. Execution
repair (`SessionController`) and session titles (`AppState`) run outside the
pipeline the gate exercises.

The UI surface is the Settings › LLM tab (`LLMSettingsView`) plus the
`ParticleStatusChip` toolbar button, which shows `textToSQLStatus` and opens
Settings › LLM. Settings has a "Particle-1 — Beta" section (the `pai-…` key
field, which warns about an `sk-or-` key and won't save one; Save and Remove; a
link to platform.particle.ai; fixed model rows; Test Connection; a status
line; privacy copy) and a Developer section with the mock toggle. There is no
model or agent-path selection.

Test Connection runs `CloudConnectivityCheck`
(`WidenKit/Services/CloudConnectivityCheck.swift`). It calls `GET /v1/models`
to check the key, that `particle-1` is listed, and that tool calling is on,
then sends one `connectivityProbe` completion with the instruction
`Reply with {"ok":true}` and the prompt `ping`, whose returned model must be
`particle-ai/particle-1`. It sends no question, schema, or database context,
uses a 30-second timeout, and sends each request at most twice.
`ParticleConnectionTestPresentation` turns the result into the Settings grid,
and the outcome updates `particleRuntimeIssue`.

### Preferences, secrets, and launch cleanup

| What | Where | Key / account |
|---|---|---|
| Particle API key | Keychain, service `Widen` | `particle-api-key` |
| Mock AI developer toggle | UserDefaults | `WidenUseMockAI` |

`RetiredAIStateCleanup` (`WidenKit/App/RetiredAIStateCleanup.swift`) runs from
`AppState.onLaunch()`. Every launch it removes the retired preferences
`WidenAIBackendMode`, `WidenCloudAIProvider`, `WidenOpenRouterModelID`,
`WidenOpenRouterSchemaToolAgentEnabled`,
`WidenExperimentalCloudSchemaAgentEnabled`, and every
`WidenDidShowInstallLLMCompatibilityAlert.*` key, and deletes
`~/Library/Application Support/Widen/openrouter-model-catalog-cache.json`.
Once, guarded by `WidenDidRemoveRetiredOpenRouterState.v1`, it deletes the
Keychain item `Widen`/`openrouter-api-key`. The flag is set before the
attempt, so a failed or cancelled delete is never retried. The old key is
only deleted, never read, so it can never reach the Particle slot. The test
initializer injects a no-op Keychain deleter.

## Schema-Tool Agent, Grounding, And Repairs

`SessionController.submitGeneratedSQL` runs each question through
`TextToSQLPipeline` (`WidenKit/Services/TextToSQLPipeline.swift`): one
generator call, the grounding postprocessor, canonicalization, safety and
schema validation, PostgreSQL verification (`PREPARE`) when the database is
connected, and validation or verification repairs. WidenEval runs the same
pipeline.

### Agent configuration

`SchemaToolSQLAgentConfiguration.default` is the shipped configuration. The
app builds the agent with it unchanged. WidenEval changes only the modes its
`--schema-agent-*` flags set, records that as the run manifest's
`agentConfiguration`, and clamps HTTP attempts per case under
`--max-http-attempts`. `TextToSQLCallBudgetTests` pins these values:

| Setting | Default |
|---|---|
| Model turns | 12 |
| Schema-tool calls | 12; 4 in repair and reconstruction runs |
| HTTP attempts, every request in the run | 30 |
| Malformed-terminal, repeated-tool and invalid-terminal-SQL corrections | 2 each |
| Over-clarification, intent-coverage, plan-consistency and terminal-required corrections | 1 each |
| Wall clock | 180 s; 120 s for repair and reconstruction runs |
| Forced final answer | `terminalToolOnly`; at most 2 requests; 45 s reserve |
| Grounding judge | on; 2 HTTP attempts; skipped with under 15 s left |
| Critic | off; when on, 2 revisions and 2 HTTP attempts per review |

Schema-tool results are capped at 16,000 bytes per call and 64,000 per run
(`SchemaToolPolicy.cloudAgent`). Database inspection keeps its own budget of
4 calls, 8,000 bytes per call and 20,000 per run. The clarification
correction, intent-coverage and plan-consistency policies stay
`diagnosticsOnly`.

**Forced final answer.** When a run spends its schema-tool budget, ends its
last model turn without a terminal answer, keeps calling tools after the
terminal-required correction, or has searched the schema and has under 45 s
left, the agent sends a forced final request: only the terminal tool, named
in `tool_choice`, with `parallel_tool_calls: false` and an instruction to
answer now. A run sends at most two. They don't count as model turns but
spend HTTP attempts and the wall clock, and their SQL goes through the same
evidence checks. A forced request that fails, or answers without the
terminal tool, rethrows the failure that triggered it, so the
inspected-evidence clarification fallback still applies.

### Grounding and the grounding judge

`GeneratedSQLPostprocessor.enriched`, in
`WidenKit/Services/SQLSchemaValidator.swift`, runs on every generation before
validation. Its lexical grounding pass matches the question's words against
the schema the SQL references, the database context and confirmed
definitions. When a word matches nothing, or the SQL uses the current time
where the question or context names an explicit window anchor (the
anchored-window rule), it replaces the SQL with a clarification.

The grounding judge (`WidenKit/Services/SchemaToolAgentGroundingJudge.swift`,
on by default) is one more Particle-1 request from the agent, at the
`groundingJudge` call site: low reasoning effort (at high effort its call
pushed the 0.2.0 gate's P95 latency over its ceiling), 8,000 completion
tokens, `json_object`, no tools, and at most 2 HTTP attempts within the run's
deadline and HTTP budget. The agent sends it after accepting SQL in any mode,
forced final answers included, when the lexical pass would replace that SQL.
It sends the question, the database context, the last 12 confirmed
definitions, the tables, columns, types and foreign keys the schema tools
returned, the allowed values and comments of those columns on tables the SQL
reads (at most 8,000 bytes), and the first 8 flagged words. The request would
add up to 3 recent questions in `followUp` mode, but no app or eval caller
sets that mode yet, so a follow-up reaches the judge as an initial question
with no earlier questions. It never sends the SQL under review, the SQL a
follow-up edits, a query plan, or data values. It is skipped, with the reason
recorded, when a flagged word matches a SQL literal the grounder rejected,
the SQL writes, a table it reads was never described, more than 8 words are
flagged, under 15 s are left, or the HTTP budget is spent. Any skip or failure
keeps the lexical decision.

The judge labels each word `request_wording`, `query_operation`,
`schema_match`, `context_defined`, `question_defined`, `needs_definition` or
`unsupported`. The reply is parsed leniently and verified deterministically:
`schema_match` must cite an existing table, column or allowed value on a
table the SQL reads, and a cited column must be one the SQL uses;
`context_defined` must quote at least 12 characters of the context or a
definition; `question_defined` must quote at least 8 characters of the
question that name the word and say more than it. `request_wording` and
`query_operation` need no citation, and the other labels never verify.

`enriched` uses a judgment only when its digest matches the exact SQL,
question, context, definitions and flagged words. It then keeps the SQL only
if every flagged word has a verified label, the agent ended on a SQL
terminal, the schema tools described every table the SQL reads, the SQL only
reads, no flagged word matches a rejected literal, intent coverage does not
say `mustClarify`, the critic did not ask to clarify, and no intent or plan
rejection stands. The anchored-window rule always wins. Otherwise the
judgment can only re-aim the
clarification at the first word it labelled `needs_definition` or
`unsupported`. It never adds a clarification the lexical pass would not ask,
and kept SQL still goes through canonicalization, safety and schema
validation, and `PREPARE`. `groundingJudgeReleaseViolations` re-checks the
release rules for evals. Callers that run the SQL they get back pass
`allowGroundingJudgeRelease: false`: the app's execution repair loop may
re-aim a clarification but never keeps SQL only the judge let stand, so that
SQL always waits for the user's Run.

### The dormant critic

`SchemaToolAgentCritic` (`WidenKit/Services/SchemaToolAgentCritic.swift`) is a
second-opinion review the agent can request before answering: one `critic`
request (high effort, 16,000 tokens, `json_object`, no tools, at most 2 HTTP
attempts) carrying the question and its context, the tool-exposed schema, the
SQL and its query plan, and inspected values only when the connection lets
them reach the cloud. It answers `accept`, `revise` with issues, or
`clarify`. The agent revises at most twice, records a `clarify` verdict
without trusting it, and keeps the reviewed SQL on any critic failure. The
critic skips repair and reconstruction runs, forced final answers, and runs
with under 30 s left, and a run with under 60 s left keeps its SQL instead of
revising it. It is off by default: in the 0.2.0 Stage 3 gate its revisions
trimmed columns the expected results keep, so only WidenEval's
`--schema-agent-critic on` turns it on. PRIVACY.md does not describe its
request.

### Repair accounting

`TextToSQLRepairPolicy` (`WidenKit/Services/GeneratedSQLRepairSupport.swift`)
bounds the repairs one request may ask for. It counts logical generator
invocations (`SQLGenerationResult.generatorInvocationCount`), not HTTP
attempts, so a schema-agent run that sent many requests counts once; a
generation saved by an older build counts as one.

| Budget | Default |
|---|---|
| Generator invocations per request, first generation included | 5 |
| Validation repairs (a focused repair and one reconstruction) | 2 |
| PostgreSQL verification repairs | 1 |
| Execution repairs | 2 |
| No repair starts after | 300 s |

Each stage's cap is bounded by what is left of the request's five
invocations. `TextToSQLPipeline` runs validation and verification repairs.
Execution repair is `SessionController.repairGeneratedSQL`: when a generated
read the user ran fails, it asks for up to two repairs and runs each repaired
read itself, never a write; its 300 s cutoff counts from the start of the
repair loop. A failed write instead offers a one-shot Try Again that only
refills the editor. Agent repair and reconstruction runs get 4 schema-tool
calls and the 120 s wall clock.

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
newlines. `ResultsCardView` uses that for Copy as CSV and Export CSV.

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
- `SessionDetailView`: hosts `ChatModeView` for one session's controller and
  reports edits via `sessionDidChange`.
- `Chat/ChatModeView`: the single chronological thread — messages with their
  SQL cards inline (the newest runnable, earlier ones static), results cards
  on cached run records, generating/running indicators, and the bottom-pinned
  composer (empty sessions show only a centered hint). "Clear Conversation"
  context menu, auto-scroll to bottom.
- `Chat/ComposerView`: the large rounded input. Accepts plain English or raw
  SQL; Return submits, Option+Return inserts a newline (no
  `.keyboardShortcut(.defaultAction)` on the send button — it would
  double-fire with `onSubmit`).
- `Chat/MessageBubbleView`: user bubbles use an accent tint; assistant/error bubbles use
  a plain material to keep scrolling cheap; `.result` records render as a
  compact row when their result is no longer cached.
- `Chat/SQLCardView`: the read-only active SQL card (dashed accent border,
  validation status icon + popover, copy, Run, one-line generation caption,
  explanation/assumptions behind an info popover). `StaticSQLCardView` is the
  permanent record for superseded SQL: plain border, copy only, no Run.
- `Results/ResultsCardView`: one run's result inline in the thread — same
  tint family as the SQL card one shade lighter with a solid border, summary
  caption, bordered table, "View more"/"View less" past 10 rows, Copy as
  CSV, and Export CSV via `NSSavePanel`.
- `Results/ResultsGridView`: content-sized bordered table (header row, cell
  separators, measured column widths, horizontal scrolling, optional
  `maxRows` cap).
- `SchemaInspectorView` + `SchemaBrowserView`: toolbar-toggled inspector with
  schema picker, table search, table list, and selected table columns.
- `Settings/SettingsView` (+ General / LLM / Databases / Archived Sessions
  tabs, `ConnectionEditorForm`): appearance, updates, and privacy copy; the
  Particle API key, Test Connection, and the mock AI toggle; connection CRUD
  with cascade-delete warning; archive restore / delete forever.
- `ParticleStatusChip`: the toolbar's text-to-SQL status — Particle-1 ready,
  mock AI, or a warning — as a plain button that opens Settings › LLM.
- `ErrorBannerView`: dismissible app-level error banner with a red tint.
- `LoadingView`: small reusable loading indicator.

Appearance: the `"WidenAppearance"` AppStorage key (`AppearancePreference`)
drives `NSApplication.appearance`, keeping window chrome and content in sync.
Light, Dark, and System are available in the sidebar footer and Settings.
Controls use standard bordered button styles, and content uses system
backgrounds, regular materials, or simple color tints. There are no custom
Liquid Glass effects or macOS-version-specific toolbar layout branches.

Keyboard behavior:

- Enter in the composer submits (generation, or direct SQL when the input
  starts with SELECT/WITH); Option+Enter inserts a newline.
- Cmd+Enter runs the active SQL card.
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
  `SQLGenerationErrorCopy` turns typed Particle failures (rejected key, no
  credits, missing inference scope, outage, unusable output, model identity
  mismatch, request too large, model not found) into plain-language copy,
  keeps the technical message as a detail line, and decides whether the
  bubble offers Try Again.

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
  archive/restore/delete, title guards, auto-title (stub generators), the
  Particle-1 title gating matrix, and connection cascade-delete.
- `AppStateSchemaTests`: open-schema fallback chain (`public` → first),
  vanished-selection fallback, prompt-schema scoping, cross-schema foreign
  key filtering, cascade prune on delete, and `SchemaViewModel` table
  filtering. These touch the real `WidenSelectedSchemaNames` UserDefaults
  key and clean it up in `defer`.
- `SessionControllerTests`: run records appended on success/failure with the
  snapshotted SQL, the direct-SQL submit path (via the executor-injectable
  internal initializer), and execution repair that grounds repaired SQL and
  never runs SQL only a grounding judgment kept.
- `SessionTitleTests`: fallback truncation, sanitizer rules, mock generator
  determinism.
- `PostgresIntegrationTests`: gated local PostgreSQL tests for connection,
  introspection, execution, truncation, mutation blocking, and timeout.
- `ChatViewModelTests`: chat flow and preview population (the internal
  `submit(schema:generator:config:queryVM:)` seam), direct-SQL detection
  and submission, and run-record/error appending.
- `ParticleBackendSelectionTests`: generator selection (mock, missing key,
  connected-session agent, schema-metadata opt-out), `sk-or-` key refusal,
  the runtime-issue lifecycle, deterministic paste-autofill, and a leak test
  in which every recorded request goes to `api.particle.ai`.
- `CredentialHostGuardTests`: the single-signer rule. Foreign hosts,
  redirects, foreign-prefix keys, and catalog lookups for Particle are all
  refused before a request is sent.
- `AppLayerProviderIsolationTests`: a source scan of `WidenKit/App` and
  `WidenKit/Views` for OpenRouter symbols and hosts.
- `CloudModelCatalogTests`: the Particle-1 profile contract, eval profile
  inference from the model ID, and OpenRouter eval requests that match the
  pre-0.2.0 requests.
- `SchemaToolSQLAgentTests` and `CloudSQLGeneratorTests`: request shape,
  parsing, retries, error mapping, identity checks, and cost, on the
  Particle and OpenRouter test profiles from `ChatCompletionsTestSupport.swift`;
  the agent tests also cover forced final answers and the grounding judge and
  critic requests.
- `TextToSQLCallBudgetTests`: the agent, schema-tool, inspection, retry, and
  repair budgets, so any change to them is deliberate.
- `TextToSQLPipelineTests`: pipeline stages, repairs and their invocation
  counts, withheld SQL, judge divergences, and judge-kept SQL still passing
  safety and schema validation and `PREPARE`.
- `SQLSchemaValidatorTests`: schema validation and the grounding
  postprocessor, including every judge release rule, re-aims, and
  `allowGroundingJudgeRelease: false`.
- `SchemaToolAgentGroundingJudgeTests` and `SchemaToolAgentCriticTests`: the
  judge request's contents and caps, its prompt, lenient parsing and
  deterministic verification; the critic's review contract.
- `TextToSQLEvalExtraCallsMetricsTests`, `TextToSQLEvalGroundingJudgeTests`,
  `TextToSQLEvalGroundingProbeTests`, and `TextToSQLEvalWithheldSQLTests`: the
  eval's critic and judge flags, forced-answer, critic and judge counts, the
  paired judge-off arm, the probe suite, and withheld-SQL scoring.
- `CloudConnectivityCheckTests`, `ParticleConnectionTestPresentationTests`,
  `ParticleTitleGeneratorTests`, `RetiredAIStateCleanupTests`, and
  `SQLGenerationErrorCopyTests`: Test Connection and its Settings grid,
  session-title requests, launch cleanup, and failure copy.
- `WidenKitTests`: smoke tests plus `QueryResultViewModel` run/restore
  behavior, the `onFinish` completion hook, and `setDirectSQL`.

Default `make test` skips the gated suites unless the relevant environment
variables are set by Make:

```text
make test-db -> TEST_RUNNER_WIDEN_TEST_DB=<db name>
```

Run `make test-db` after changes to connection, introspection, execution,
cell formatting, or safety behavior. No unit test sends a request to Particle
or OpenRouter: model tests use stub transports. Paid checks against the real
API are the eval targets in `Evals/README.md`.

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

1. Update the agent's instructions or user prompt in `SchemaToolSQLAgent`
   (the production path), or `SQLPromptBuilder` for the one-shot generator.
2. Update `SchemaToolSQLAgentTests` or `SQLPromptBuilderTests`.
3. Run `make eval-schema-tools` (no model calls). Measuring the effect on
   Particle-1 needs the paid eval targets in `Evals/README.md`.
4. Keep the prompt concise; Particle-1 bills every input token.
5. The grounding judge's prompt lives in `SchemaToolAgentGroundingJudge`;
   `SchemaToolAgentGroundingJudgeTests` keeps every word the grounder flags
   in the gate suite and the grounding probe out of its system prompt.

Change an agent budget, the grounding judge, or the critic:

1. Change `SchemaToolSQLAgentConfiguration`'s defaults,
   `TextToSQLRepairPolicy`, or the profile's `groundingJudge` / `critic`
   call-site policy.
2. Update `TextToSQLCallBudgetTests` (and `CloudModelCatalogTests` for a
   call-site policy).
3. Measure it with a preregistered paid gate run, as
   `docs/next-dev-steps.md` records for 0.2.0; the run manifest's
   `agentConfiguration` shows what ran.
4. Turning the critic on in the app also needs a PRIVACY.md note: it sends
   the drafted SQL, its query plan and, when allowed, inspected values.

Add a result display feature:

1. Extend `QueryResult` only if the data model really needs new state.
2. Prefer formatting in `PostgresCellFormatter` or `QueryResult` rather than
   directly in SwiftUI views.
3. Update `Results/ResultsGridView` (table cells) or `Results/ResultsCardView`
   (summary, expansion, export around the table).
4. Add unit tests if formatting or export behavior changes.

Add another SQL generator:

1. Implement `SQLGenerator`.
2. Decide where `AppState.sqlGenerator(connectionID:schema:)` chooses it.
3. Keep `SQLGenerationResult` as the common output.
4. Do not bypass `SQLSafetyValidator` or `QueryExecutionService`.
5. A new model or provider also needs its own `CloudModelProfile`, a passing
   release-gate run, and an app release; never send one provider's key to
   another provider's host.

Add per-session state:

1. Decide whether it is persistent (add to `QuerySession`, hydrate/snapshot
   in `SessionController`) or runtime-only (keep it on the controller or its
   view models).
2. Wire change reporting through `sessionDidChange` if it should be saved.
3. Update `SessionStoreTests` / `AppStateSessionTests`.
4. Never persist query results, passwords, or model prompts.

## Invariants Future Work Should Preserve

- Text-to-SQL uses only Particle-1 with the user's own key. There is no
  Widen-hosted backend and no on-device or offline generator.
- The Particle-1 production profile (requests `particle-1`, requires
  `particle-ai/particle-1`) and the connected-session schema-tool path are
  fixed. Changing either model ID requires a new release and release-gate
  evaluation. OpenRouter stays an eval-only comparison provider that the app
  and view layers never reference.
- The app and the release gate run the agent with
  `SchemaToolSQLAgentConfiguration.default`. Its budgets, the repair policy,
  and the judge and critic defaults change only with
  `TextToSQLCallBudgetTests` and a gate run that measures the change.
- The grounding judge never receives SQL, a query plan, or data values, and
  never adds a clarification. Its labels count only after local
  verification and a digest match, and the postprocessor keeps SQL on them
  only when every release rule holds; kept SQL still passes safety and
  schema validation and `PREPARE`. A caller that runs SQL without the
  user's review passes `allowGroundingJudgeRelease: false`.
- The critic stays off by default and is reachable only through WidenEval's
  `--schema-agent-critic on`.
- Particle requests carry no routing or retention object. Zero data retention
  is Particle's stated policy, not something Widen enforces; don't describe
  it otherwise.
- `CloudModelProfile.authorizedRequest(_:apiKey:)` is the only code that signs
  a request. A key is sent only over https to its own profile's host, never
  with another provider's prefix, and signed requests never follow redirects.
- Paste-autofill stays deterministic and local (`MockConnectionDetailsParser`).
  Pasted connection details can contain credentials and never reach a model.
- Passwords are never stored in `DatabaseConnectionConfig` or JSON files.
- Query results are never persisted; `sessions.json` holds transcripts, SQL
  text, and generation metadata only.
- A manual session rename is never overwritten by the auto-namer.
- Generated SQL is never auto-executed. The one exception is execution
  repair, which runs a repaired read after a generated read the user ran
  failed, and never a write.
- No generated SQL bypasses safety validation, schema validation, PostgreSQL
  verification when available, or manual Run.
- Manual and generated SQL share the exact same validation and execution path.
- Only `SELECT` or `WITH ... SELECT` statements can reach PostgreSQL.
- Execution always uses `BEGIN READ ONLY`.
- Execution always applies a statement timeout.
- Queries without LIMIT are capped with the configured default row limit.
- System schemas are excluded from prompt context.
- A missing or rejected Particle key is reported in plain language and never
  blocks schema browsing or manual SQL.
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
7. `WidenKit/Services/SchemaToolSQLAgent.swift` and
   `WidenKit/Models/CloudModelProfile.swift` for text-to-SQL with Particle-1
   and request signing.
8. `WidenKit/Services/TextToSQLPipeline.swift`,
   `WidenKit/Services/GeneratedSQLRepairSupport.swift`,
   `GeneratedSQLPostprocessor` in `WidenKit/Services/SQLSchemaValidator.swift`,
   and `WidenKit/Services/SchemaToolAgentGroundingJudge.swift` for validation,
   repairs, and grounding.
9. `WidenKit/Services/SQLPromptBuilder.swift` for prompt shape.
10. `WidenKit/ViewModels/QueryResultViewModel.swift` for SQL preview and run
    behavior.
11. `WidenTests/SQLSafetyValidatorTests.swift` and
    `WidenTests/PostgresIntegrationTests.swift` for expected behavior.

When in doubt, preserve the existing service boundaries and add tests around
the behavior you are changing.
