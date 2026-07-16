# Widen Text-to-SQL Rebuild Plan

## Background / Motivation

Widen’s current text-to-SQL pipeline is unreliable across both local and cloud models. It sends a preselected schema excerpt to an LLM in one shot, then relies on increasingly complex validation and repair logic. In practice, relevant relationships can be present in the schema while the model still selects the wrong tables or columns, and repair attempts often repeat the same invalid SQL.

This refactor changes the process from prompt-by-prompt debugging to measurable system development: establish a fixed evaluation suite, improve schema retrieval, let models inspect schema through bounded tools, verify generated SQL with PostgreSQL, and compare every change against the same baseline.

The initial evaluation tool will be a small, native Swift command-line target named `WidenEval`, built inside this repository and using the same generators and validators as the app. It requires no paid or external evaluation framework, is easy to run locally against both Apple Foundation Models and OpenRouter, and keeps Widen’s production pipeline as the source of truth. An optional open-source reporting layer such as Promptfoo may be added later, but it will not own execution or scoring.

As part of this rebuild, you may find stuff you might want to clean/delete as we don't want a hardcoded custom natural-language parser, grounder, SQL compiler, and conformance engine. That is creating a second database engine full of edge cases so we want to avoid that.

## Tool choice

Use a **native Swift command-line eval runner** as the source of truth.

This is simpler than introducing an external eval framework because it can call the exact same `FoundationModelsSQLGenerator`, `OpenRouterSQLGenerator`, schema code, and validators used by Widen. The current project uses the Xcode 26 SDK for optional Foundation Models support while keeping the app deployment target on macOS 14.0.

Promptfoo is a reasonable optional reporting layer later: it is open source/MIT licensed, has a CLI, supports custom providers, retries, filtering, and exports. However, wrapping Widen’s Swift/local-model execution in Node during the first PR adds unnecessary integration risk. ([GitHub][1])

Do not use an LLM-as-judge initially. Score deterministic properties and, later, compare executed result sets.

---

# Dependency graph

```text
PR 1 — Eval harness and first 20 cases
  ├── PR 2 — Headless production pipeline extraction       [parallel]
  ├── PR 3 — Seeded Postgres semantic grader               [parallel]
  ├── PR 4 — OpenRouter adapter reliability                [parallel]
  └── PR 5 — Local schema search index                     [parallel]
          ├── PR 6 ✅ — Bounded schema tools                  [done 2026-06-25]
          └── PR 10 ⏸️ — Embedding retrieval experiment     [deferred 2026-06-26 — revisit only if retrieval becomes the measured bottleneck]

PR 2 + PR 4 + PR 6
  └── PR 7 ✅ — Cloud tool-using SQL agent                  [done 2026-06-25]

PR 2 + PR 3
  └── PR 8 ✅ — PostgreSQL verification and one repair        [done 2026-06-26]

PR 6 + PR 8
  └── PR 9 ✅ — Optional data-inspection tools              [done 2026-06-26]

PR 2 + PR 5 + PR 6
  └── PR 11 ✅ — Constrained local-model path              [complete 2026-06-26]

PR 7 + PR 8 + PR 11 + eval evidence
  └── PR 12 ✅ — Backend defaults, older macOS, release gate [done 2026-06-26]
      └── PR 13 ✅ — Release-gate triage and schema-tool agent fixes [complete 2026-06-28]
          └── PR 14 ✅ — Resumable, budget-aware release-gate evals [complete 2026-06-28]
              └── PR 15 ✅ — Release-gate baseline and triage docs [complete 2026-06-28]
                  └── PR 16 ✅ — Schema-tool over-clarification policy [complete 2026-06-28]
                      ├── PR 52 ✅ — Diagnostics-only schema-tool policy infrastructure [complete 2026-06-28]
                      ├── PR 53 ✅ — Intent coverage review fixes and heuristic scope freeze [complete 2026-06-28]
                      └── PR 54 ✅ — Stabilize schema-tool query planning and SQL shape [complete 2026-07-09]
                          └── PR 55 ✅ — Select and pin the OpenRouter SQL profile [complete 2026-07-10]
```

---

# PR 1 ✅ — Add a headless text-to-SQL eval harness

Suggested title:

```text
test: add native text-to-sql evaluation harness
```

## Goal

Create a repeatable baseline before changing production behavior.

It is acceptable—and expected—that most cases fail initially. This PR succeeds when failures are accurately measured, classified, and reproducible.

## Implementation

Add a command-line target:

```text
WidenEval
```

It should depend on `WidenKit` and call the real generators.

Suggested structure:

```text
WidenEval/
  WidenEvalMain.swift
  EvalRunner.swift
  EvalReporter.swift

Evals/
  suites/text-to-sql-v1.json
  schemas/
    commerce-schema.json
    support-schema.json
    saas-schema.json
    preseason-schema.json
  README.md

WidenKit/Evals/
  TextToSQLEvalCase.swift
  TextToSQLEvalResult.swift
  TextToSQLEvalScorer.swift
```

Use JSON and `Codable`; add no eval dependency.

## Commands

Add:

```makefile
make eval-local
make eval-cloud MODEL=openai/gpt-5.5
make eval-all MODEL=openai/gpt-5.5
make eval-case CASE=preseason.top-wins-defined BACKEND=local
```

Cloud credentials must come only from:

```text
WIDEN_EVAL_OPENROUTER_API_KEY
```

Never read or persist them in fixtures or reports.

Useful CLI arguments:

```text
--backend local|cloud|both
--model <openrouter-model-id>
--suite <path>
--case <case-id>
--repeat <n>
--output <directory>
--record-prompts
--fail-under <percentage>
```

`--record-prompts` should default to false.

## Per-case fixture

```json
{
  "id": "preseason.top-wins-defined",
  "schemaFixture": "preseason",
  "question": "Which tools have the most wins in the last two weeks?",
  "databaseContext": "Each evaluation with a non-null winner_id records one win. Use the evaluation createdAt timestamp.",
  "expected": {
    "decision": "sql",
    "requiredTables": [
      "public.preseason_match_evaluation",
      "public.preseason_tool"
    ],
    "requiredColumnBindings": [
      "public.preseason_match_evaluation.winner_id",
      "public.preseason_match_evaluation.createdAt",
      "public.preseason_tool.id"
    ],
    "forbiddenColumnBindings": [
      "public.preseason_match_evaluation.tool_a_id",
      "public.preseason_match_evaluation.tool_b_id"
    ],
    "requiredOperations": [
      "count",
      "group",
      "descending-order",
      "relative-time-filter"
    ],
    "goldenSQL": "..."
  }
}
```

Do not compare raw SQL strings. Equivalent SQL shapes must be accepted.

## Initial 20 cases

| ID                                     | Question                                                 | Expected                          |
| -------------------------------------- | -------------------------------------------------------- | --------------------------------- |
| `commerce.recent-orders`               | Show the 10 most recent orders                           | SQL                               |
| `commerce.customer-paid-revenue`       | Show total paid revenue per customer                     | SQL                               |
| `commerce.average-order-value-country` | Average paid order value by customer country             | SQL                               |
| `commerce.customers-without-orders`    | Which customers have never placed an order?              | SQL                               |
| `commerce.best-customers`              | Who are our best customers?                              | Clarify                           |
| `support.frequent-feedback-cluster`    | What is the most frequent feedback cluster?              | SQL                               |
| `support.unresolved-by-assignee`       | Count unresolved tickets by assignee                     | SQL                               |
| `support.average-first-response`       | Average first-response time over the last 30 days        | SQL                               |
| `support.unclustered-feedback`         | Show feedback items without a cluster                    | SQL                               |
| `support.important-cluster`            | What is our most important feedback cluster?             | Clarify                           |
| `saas.expiring-subscriptions`          | Subscriptions expiring in the next 30 days               | SQL                               |
| `saas.active-users-by-org`             | Active users by organization in the last week            | SQL, with context defining active |
| `saas.overallocated-seats`             | Organizations using more seats than purchased            | SQL                               |
| `saas.users-without-membership`        | Users without an active organization membership          | SQL                               |
| `saas.healthy-accounts`                | Which accounts are healthy?                              | Clarify                           |
| `preseason.verified-tools`             | List verified tools                                      | SQL                               |
| `preseason.top-wins-ambiguous`         | Tools with the most wins in the last two weeks           | Clarify                           |
| `preseason.top-wins-defined`           | Same request with an explicit win definition             | SQL                               |
| `preseason.latest-failed-runs`         | Show the latest failed benchmark runs                    | SQL                               |
| `preseason.active-match-configs`       | Active match configurations with tool and category names | SQL                               |

The Preseason fixture should retain the actual mixed-case identifiers and relevant relationships. The existing failure occurred despite `winner_id`, its tool FK, and `"createdAt"` being present in the available schema, so it is an essential regression case.

## Metrics

Record separately:

```text
backend availability
transport success
structured-response parsing
SQL versus clarification decision
safety validation
schema validation
required-table coverage
required-column-binding coverage
forbidden-binding violations
clarification quality
latency
model-call count
prompt size
token usage when available
estimated cloud cost when available
```

Do not collapse everything into one score.

Suggested statuses:

```swift
enum EvalCaseStatus {
    case passed
    case semanticReviewRequired
    case wrongDecision
    case invalidSQL
    case wrongSchemaObjects
    case transportFailure
    case parseFailure
    case backendUnavailable
}
```

## Output

Write:

```text
.eval-results/<timestamp>/
  run.json
  cases.jsonl
  summary.md
```

Gitignore `.eval-results/`.

The report should include:

```text
commit SHA
backend
model
OS version
schema-fixture hashes
pass counts by failure category
latency statistics
per-case output and diagnostics
```

## Acceptance criteria

* All 20 fixtures decode and run.
* Mock local and cloud backends have deterministic unit tests.
* Real local mode invokes Foundation Models.
* Real cloud mode invokes OpenRouter.
* A failed case does not terminate the suite.
* Missing Apple Intelligence or API credentials produce `backendUnavailable`, not a crash.
* `make test` remains green.
* No production text-to-SQL behavior changes.
* An initial baseline summary is committed; raw model output is not.

---

# Optional PR 1B — Promptfoo adapter — Skipped

**Can run in parallel after PR 1. Not required.**

Suggested title:

```text
chore: add optional promptfoo eval adapter
```

Create a thin custom provider that invokes `WidenEval` and returns its JSON. Use Promptfoo only for viewing runs and comparing models. Do not duplicate prompts, scoring, or backend implementations in JavaScript.

---

# PR 2 ✅ — Extract a headless production pipeline

Suggested title:

```text
refactor: extract reusable text-to-sql pipeline
```

## Goal

Ensure the eval runner tests the exact system used by the app, not a simplified imitation.

## Implementation

Extract orchestration from `SessionController` into:

```swift
public protocol TextToSQLRunning {
    func run(_ request: TextToSQLRequest) async -> TextToSQLRun
}

public struct TextToSQLRequest {
    var question: String
    var schema: DatabaseSchema
    var databaseContext: String
    var conversation: [SQLConversationMessage]
    var backend: SQLGenerator
    var validationMode: ValidationMode
}

public struct TextToSQLRun {
    var finalDecision: TextToSQLDecision
    var trace: TextToSQLTrace
}

public struct TextToSQLTrace {
    var stages: [TextToSQLStageResult]
    var modelCalls: Int
    var elapsedMs: Int
}
```

Stages should distinguish:

```text
schema selection
prompt construction
model request
response parsing
canonicalization
safety validation
schema validation
database verification
repair
final decision
```

`SessionController` becomes a UI adapter around this service.

## Non-goals

* No new prompts.
* No new retrieval.
* No new repair policy.
* No behavior tuning.

## Acceptance criteria

* The app and eval runner use the same pipeline.
* PR 1 baseline results are unchanged, except for trace formatting.
* Existing chat/session behavior remains unchanged.
* Every failure names the stage where it occurred.

---

# PR 2.1 ✅ — Align production eval behavior and cancellation

Suggested title:

```text
fix: align production eval behavior and cancellation
```

## Goal

Keep normal local, cloud, and semantic eval runs aligned with production
grounding behavior, and prevent cooperative cancellation or eval timeouts from
being misreported as transport failures.

## Implementation

* Normal `WidenEval` runs use the production `TextToSQLPipeline` grounding
  default. The previous no-grounding path is available only through an
  explicitly named test-only option.
* A characterization test compares the same scripted generation through
  `SessionController` and `TextToSQLEvalCaseRunner`.
* Foundation Models discovery rethrows cancellation before fallback accounting,
  and the local generator checks cancellation before SQL generation.
* OpenRouter maps task-cancelled URLSession cancellation to `CancellationError`.
* Private Cloud Compute preserves `CancellationError` before generic mapping.
* `WidenEval` supports `--case-timeout-seconds <n>` with a 120-second default.
  Timed-out cases cancel the pipeline, record `evalTimeout`, preserve elapsed
  time and case ID, and allow later cases to continue. Foundation Models
  cancellation remains cooperative, so timed-out model work can continue in
  process until the framework returns.

## Baseline handling

Baselines from older evaluation modes are stale. Regenerate the local baseline
after these fixes. Regenerate the cloud baseline only with a real
`WIDEN_EVAL_OPENROUTER_API_KEY`; never replace it with an all-`backendUnavailable`
run.

---

# PR 3 ✅ — Add seeded PostgreSQL semantic evaluation

Suggested title:

```text
test: grade text-to-sql with seeded postgres fixtures
```

**Can run in parallel with PR 2.**

## Goal

Measure whether SQL returns the correct answer, not merely whether it parses.

## Implementation

Add deterministic DDL and seed data:

```text
Evals/databases/
  commerce/setup.sql
  support/setup.sql
  saas/setup.sql
  preseason/setup.sql
```

Reuse Widen’s existing local Postgres test provisioning rather than adding Docker as a hard requirement.

For every SQL case:

1. Provision the disposable database.
2. Run its setup and seed SQL.
3. Execute the fixture’s `goldenSQL`.
4. Execute generated SQL in read-only mode.
5. Normalize values.
6. Compare candidate and golden result sets.

Comparison modes:

```text
ordered
unordered
scalar
set-with-column-alias-mapping
```

Seed data must deliberately distinguish plausible wrong queries. For example:

* A tool with many appearances but few wins.
* A tool with fewer appearances but more `winner_id` rows.
* Dates that distinguish evaluation creation time from benchmark scheduling.
* Duplicate relationships that expose accidental row multiplication.
* `NULL` status and FK cases.
* Mixed-case identifiers.

The historical queries often executed plausible-looking but semantically wrong logic such as ranking completed evaluations or participant IDs instead of winners.

## Acceptance criteria

* All 16 SQL cases have deterministic golden results.
* Wrong-but-valid SQL fails result comparison.
* Clarification cases never execute SQL.
* Candidate execution uses read-only credentials or a read-only transaction.
* Execution timeout is enforced.
* Reports distinguish `schemaValid` from `resultEquivalent`.

---

# PR 4 ✅ — Harden OpenRouter independently

Suggested title:

```text
fix: make openrouter requests capability-aware and observable
```

**Can run in parallel with PR 2, PR 3, and PR 5.**

## Goal

Separate backend transport failures from SQL-generation failures.

Existing logs include authentication rejection, unparseable output, overload responses, and successful responses. Those must not all appear as generic text-to-SQL failures.

## Implementation

Add:

```swift
ModelCapabilities
OpenRouterModelCatalogService
OpenRouterRequestBuilder
OpenRouterResponseParser
OpenRouterConnectivityCheck
```

Requirements:

* Fetch and cache OpenRouter model metadata.
* Send only parameters supported by the selected model.
* Detect tool-calling and structured-output support.
* Record requested model and returned model.
* Parse string and multipart content variants.
* Preserve provider error code, request ID, and safe response excerpt.
* Retry transient overload/rate-limit errors with bounded backoff.
* Never retry authentication or invalid-model errors.
* Add “Test model” in Settings.

Add a five-case transport smoke suite:

```text
simple SELECT
simple aggregate
clarification
quoted identifier
two-table join
```

Run each three times.

## Acceptance criteria

* Authentication, model-not-found, overload, timeout, malformed output, and unsupported structured output are distinct errors.
* Supported models have no response-format fallback loop.
* No hardcoded unsupported parameter breaks a model request.
* Transport success is at least 95% over repeated smoke runs before using the provider in larger evals.

---

# PR 5 ✅ — Add a local schema retrieval index

Suggested title:

```text
feat: add local schema search index with retrieval evals
```

**Can run in parallel after PR 1.**

## Goal

Improve schema selection independently of SQL generation.

Do not add embeddings yet.

## Index contents

Create one searchable document per table containing:

```text
exact schema-qualified name
table name
table comment
columns
column comments
types
primary key
unique constraints
foreign keys
check constraints
enum values
```

Store the index locally under Application Support, keyed by:

```text
connection ID
selected schema set
schema fingerprint
index version
```

Use:

* exact identifier matching;
* normalized snake/camel token matching;
* simple BM25-style lexical scoring;
* limited fuzzy matching;
* FK graph expansion;
* explicit database-context boosts.

No data values or credentials belong in the index.

## Public APIs

```swift
searchSchema(query: String, limit: Int) -> [SchemaSearchHit]

describeSchemaObjects(ids: [SchemaObjectID]) -> [SchemaObjectDescription]

findJoinPaths(
    from: SchemaObjectID,
    to: SchemaObjectID,
    maxHops: Int
) -> [SchemaJoinPath]
```

## Retrieval eval

Extend the 20 cases with expected schema objects.

Report:

```text
Recall@3
Recall@5
Recall@8
mean reciprocal rank
required join-path recall
```

## Acceptance criteria

Initial targets:

```text
All required tables in top 8: ≥ 90% of cases
All required tables in top 5: ≥ 80% of cases
Primary entity in top 3: ≥ 85% of cases
```

These are retrieval metrics only; no SQL model call occurs.

Completed with `make eval-retrieval` on 2026-06-24:

```text
Index required-table Recall@5: 100.0%
Index primary-table MRR: 0.925
Index required join-path recall: 100.0%
Wrong-schema collisions: 0
Forbidden distractor violations: 0
```

---

# PR 6 ✅ — Add bounded schema tools [done 2026-06-25]

Suggested title:

```text
feat: expose bounded schema tools for text-to-sql
```

Depends on PR 5.

## Goal

Give a model controlled schema discovery without sending the entire schema.

## Tools

```text
search_schema(query, limit)
describe_tables(table_ids)
find_join_paths(from_table_id, to_table_id, max_hops)
inspect_column_constraints(table_id, column_id)
```

`inspect_column_constraints` returns only enum/check-constraint values, not live row values.

Requirements:

* Stable object IDs.
* Strict argument validation.
* Maximum result sizes.
* Compact output.
* No arbitrary SQL tool.
* No credentials.
* No sample rows.
* Every standalone tool call records a redacted `SchemaToolCallTrace`; `TextToSQLTrace` can carry tool traces once PR 7 starts using them.

## Acceptance criteria

* Tool results are deterministic.
* Invalid IDs return structured errors.
* `describe_tables` never silently truncates a table’s relevant relationship columns.
* Tool output remains below configured token limits.
* Tools can be exercised without an LLM.

Completed on 2026-06-25.

Verification:

```text
make project
make test
make eval-retrieval RETRIEVER=index
make eval-schema-tools
```

Results:

```text
make test: 688 tests in 41 suites passed.
make eval-retrieval RETRIEVER=index: acceptance passed, 23 cases, required-table Recall@3/5/8 100.0%, required join-path recall 100.0%, missing required column matches 0, forbidden distractor violations 0.
make eval-schema-tools: 10/10 cases passed, definition bytes 1686, estimated definition tokens 562, max response bytes 6111, truncated results 1, determinism failures 0.
Schema tool contract response sizes: definitions 1686 bytes; no-finite-values 431 bytes; no-match 219 bytes; no-path 310 bytes; invalid-id 367 bytes; wrong-kind 333 bytes; call-count-budget 299 bytes; large-table-truncation 3743 bytes; preseason workflow 6111 bytes.
```

---

# PR 7 ✅ — Add a cloud tool-using SQL agent [done 2026-06-25]

Suggested title:

```text
feat: add cloud schema-tool sql agent behind a feature flag
```

Depends on PR 2, PR 4, and PR 6.

## Goal

Replace the giant one-shot cloud prompt with iterative schema discovery.

## Agent loop

```text
user question + database context
    ↓
model calls search_schema
    ↓
model calls describe_tables
    ↓
optional find_join_paths
    ↓
model returns SQL or clarification
```

Final response should be minimal:

```json
{
  "action": "sql",
  "sql": "..."
}
```

or:

```json
{
  "action": "clarify",
  "question": "..."
}
```

Derive tables, risk, confidence/readiness, and validation metadata in Widen.

Limits:

```text
maximum four schema-tool calls
maximum one final response
maximum one validation repair
no full schema in the initial prompt
no previous failed SQL in a reconstruction prompt
```

Keep it behind:

```text
experimentalCloudSchemaAgentEnabled
```

## Merge versus promotion criteria

It may merge behind a feature flag if it is safe and measurably improves the baseline.

Do not make it the default until repeated eval runs show:

```text
at least 18/20 end-to-end passes
zero unsafe writes
zero nonexistent identifiers reaching execution
all four clarification cases classified correctly
at least 95% cloud transport success
```

Completed on 2026-06-25.

Implementation notes:

* Added an experimental OpenRouter-only `OpenRouterSchemaToolSQLAgent` separate from the legacy one-shot `OpenRouterSQLGenerator`.
* Added OpenRouter tool-chat protocol support, terminal `submit_text_to_sql_result`, schema-tool evidence checks, typed agent failures, and aggregate agent metadata.
* Added the persisted `experimentalCloudSchemaAgentEnabled` preference under OpenRouter advanced settings. Default remained false for PR 7; PR 12 later promoted the OpenRouter schema-tool agent to the default connected-session cloud path.
* App construction now uses a connection-aware generator path so connection ID, selected schemas, schema fingerprint, schema-tool session factory, and search index store stay host-controlled.
* Added `WidenEval --cloud-agent legacy|tools` plus `make eval-cloud-agent`, `make eval-db-cloud-agent`, and `make eval-cloud-agent-case`.
* Added deterministic scripted OpenRouter tests for the happy path, multiple schema calls, terminal-before-search correction, mixed terminal/schema rejection, unsupported-tool-model legacy selection, prompt injection exclusion from the initial request, and pipeline trace merging.
* Review follow-up fixes preserve provider tool-call response protocol during corrections, keep schema-tool traces on stale-schema and provider-failure agent failures, bound retry backoff by the agent wall-clock timeout, and gate terminal SQL on existing safety/schema validators before success.
* Latest review follow-up fixes preserve quoted identifier case in evidence keys, avoid crediting endpoint tables from empty join-path results, keep initial and repair schema-tool traces separate, and count tools-mode budget failures even when generation failure metadata is partial.
* Second review follow-up fixes classify unsafe terminal SQL as safety validation, recheck schema freshness before terminal returns, preserve follow-up current SQL and reconstruction repair facts, reject unqualified `SELECT *` unless the table was fully described, and count repair-mode tool-budget failures against the repair budget.
* Third review follow-up fixes count only typed schema-tool budget errors, keep reconstruction attempts on the repair schema-tool budget, preserve aggregate agent metadata on failures, include agent-only failures in OpenRouter reporting, and preserve typed OpenRouter error envelopes in tool-chat responses.
* Fourth review follow-up fixes unqualified `SELECT *` detection so arithmetic multiplication is not treated as wildcard projection, returns typed model-turn budget failures for zero-turn configurations, and includes the configured default row limit in the cloud tool-agent prompt.
* Fifth review follow-up fixes repair/current-request model-call accounting, preserves non-tool invalid-request failures, prefers full pipeline schema-tool traces in eval metrics, and attempts the tool agent when tool capabilities are unknown rather than silently selecting legacy.
* Sixth review follow-up bounds in-flight OpenRouter sends by the agent wall-clock deadline, applies a `max_tokens` fallback when token-capability metadata is absent, and counts schema-tool result-byte budget failures in eval summaries. It intentionally preserves the PR 7 requirement to return a typed unsupported-tools failure, not silently fall back to one-shot generation, after a paid tool request is rejected.
* Seventh review follow-up preserves provider tool-call IDs in tool response envelopes, includes last-run errors in non-repair follow-up prompts, bounds confirmed semantic bindings before prompting, and restores PostgreSQL date/time dialect guardrails for the schema-tool agent.

Verification:

```text
make project
make test
make eval-schema-tools
make eval-openrouter-smoke MODEL=openai/gpt-5.5 REPEAT=3
make eval-cloud-agent MODEL=openai/gpt-5.5 REPEAT=3
make eval-db-cloud-agent MODEL=openai/gpt-5.5 REPEAT=3
```

Results:

```text
make test: 724 tests in 42 suites passed.
make eval-build: WidenEval build succeeded.
make eval-schema-tools: 10/10 cases passed; max response bytes 6111; truncated results 1; determinism failures 0.
make eval-openrouter-smoke MODEL=openai/gpt-5.5 REPEAT=3: completed with backend/transport 15/15, structured parse 15/15, static-shape 9/15, estimated cost $0.181115. Summary: .eval-results/20260625-123540-793/summary.md.
make eval-cloud-agent MODEL=openai/gpt-5.5 REPEAT=3: completed tools mode with backend 60/60, transport 60/60, static-shape 10/60, 221 schema-tool calls, 141 model calls, 123 agent HTTP attempts, estimated cost $1.353450. Summary: .eval-results/20260625-125522-075/summary.md.
make eval-db-cloud-agent MODEL=openai/gpt-5.5 REPEAT=3: completed tools mode with backend 60/60, transport 60/60, static-shape 11/60, semantic end-to-end 11/60, SQL semantic 8/12, clarification decision 8/12, 221 schema-tool calls, 145 model calls, 127 agent HTTP attempts, estimated cost $1.405265. Summary: .eval-results/20260625-131721-290/summary.md.
```

The live tools-mode results are safe to keep behind the disabled feature flag, but they do not meet the promotion gate.

---

# PR 8 ✅ — Verify SQL with PostgreSQL and allow one repair [done 2026-06-26]

Suggested title:

```text
feat: verify generated sql with postgres before presenting it
```

**Can run in parallel with PR 7 after PR 2 and PR 3.**

## Goal

Use PostgreSQL as the final authority for parsing, binding, and type checking.

## Verification

For generated read SQL, use a short-lived read-only transaction:

```sql
BEGIN READ ONLY;
SET LOCAL statement_timeout = '2s';
SET LOCAL lock_timeout = '500ms';
PREPARE widen_generated_check AS <generated SQL>;
DEALLOCATE widen_generated_check;
ROLLBACK;
```

Optionally add non-executing `EXPLAIN (FORMAT JSON)` after safety review.

Do not run the user query during verification.

## Repair

On failure:

1. Preserve structured PostgreSQL fields.
2. Retrieve schema objects implicated by the diagnostic.
3. Send one repair request.
4. Verify the repaired SQL.
5. Stop.

No reconstruction loop. No five retries.

Track:

```text
first-pass valid rate
repair-success rate
repeat rate
verification latency
```

## Acceptance criteria

* Missing relations, columns, type errors, and malformed joins are detected before editor insertion.
* Verification never executes the generated query.
* Exactly one repair is permitted.
* Repeated SQL terminates immediately.
* Permission/connection/timeout failures do not trigger model repair.

Completed on 2026-06-26.

Implementation notes:

* Added a separate `GeneratedSQLVerifying` service and production `PostgresSQLVerifier` that verifies generated read SQL through `PREPARE` inside a short-lived read-only transaction with local timeouts and deterministic session settings, then always deallocates and rolls back.
* Preserved structured PostgreSQL diagnostics, including SQLSTATE, severity, detail/hint, position, relation/column/type/constraint fields, and debug server fields when available.
* Integrated verification into the generated SQL pipeline after deterministic repair and static validation, with trace stages for PostgreSQL verification and one verification repair.
* Limited verification repair to exactly one model call for repairable database diagnostics and stopped without repair for permission, connection, cancellation, and timeout failures.
* Wired live connected app sessions to pass a verification-capable connection handle; missing verifier or connection is recorded as a skipped verification result.
* Extended WidenEval metrics, reports, and seeded DB semantic runs so PostgreSQL verification is reported separately and must pass before semantic execution can count as end-to-end success.
* Added fake-verifier pipeline tests for pass/fail/repair/skip/cancellation/nonrepairable behavior, schema-tool trace preservation, and Preseason regressions, plus gated Postgres integration coverage for real `PREPARE` SQLSTATE failures and non-execution behavior.

Cleanup pass (pre-merge review feedback):

* Routed verification-repair failures through `repairFailure(... stage: .postgresVerificationRepair)` so rejected/no-progress verification-repair candidates report `.postgresVerificationRepair` instead of `.validationRepair`, with a deterministic pipeline test for the rejected-candidate path.
* Extended the one-shot PostgreSQL verification repair to validation-repair output: when validation repair produces locally valid SQL that fails verification with a repairable diagnostic, the pipeline now invokes `runPostgresVerificationRepair` once instead of failing immediately.
* Aligned the verifier session `DateStyle`/`IntervalStyle` with the seeded semantic executor (`ISO, YMD` / `iso_8601`) so verification parses date/interval literals under the same rules as execution.
* Rejected PostgreSQL bind placeholders (e.g. `$1`) before accepting verification, since `PREPARE` would accept a parameterized statement that the no-bind execution path cannot run; the diagnostic is repairable so the model can inline the value.
* Updated WidenEval report scope text to distinguish static evals without a verifier, static evals with a verifier, and seeded semantic evals that run PostgreSQL verification before semantic execution.
* Added `GeneratedSQLVerifier.swift`, `PostgresErrorMapper.swift`, and `PostgresService.swift` to the eval scorer source hashes so manifests stay comparable now that verification can change the final decision.
* Split the PostgreSQL verification summary metric into an attempted pass rate (`passed / (passed + failed)`) alongside the full status-count table, so a non-DB run no longer reads as `0/N` verification passed.

Verification:

```text
make project
make test
make test-db
make eval-db-local REPEAT=3
make eval-db-cloud MODEL=openai/gpt-5.5 REPEAT=3
make eval-db-cloud-agent MODEL=openai/gpt-5.5 REPEAT=3
```

Results:

```text
make project: project generation succeeded.
make test: 747 tests in 42 suites passed.
make test-db: 31 tests in 3 suites passed.
make eval-db-local REPEAT=3: 60 results; static-shape 20.0%; semantic end-to-end 20.0%; overall end-to-end 12/60 (20.0%); PostgreSQL verification attempted pass rate 9/9; status counts passed=9, failed=0, skippedStaticValidationFailed=30.
make eval-db-cloud MODEL=openai/gpt-5.5 REPEAT=3: 60 results; backend available 60/60; transport success 60/60; static-shape 35.0%; semantic end-to-end 23.3%; overall end-to-end 14/60 (23.3%); PostgreSQL verification attempted pass rate 12/12; status counts passed=12, failed=0, skippedStaticValidationFailed=8.
make eval-db-cloud-agent MODEL=openai/gpt-5.5 REPEAT=3: 60 results; backend available 60/60; transport success 60/60; static-shape 30.0%; semantic end-to-end 20.0%; overall end-to-end 12/60 (20.0%); PostgreSQL verification attempted pass rate 12/12; status counts passed=12, failed=0, skippedStaticValidationFailed=0.
```

---

# PR 9 ✅ — Add optional metadata and data-inspection tools [done 2026-06-26]

Suggested title:

```text
feat: add privacy-gated database inspection tools
```

Depends on PR 6 and PR 8.

## Goal

Resolve schema questions that metadata alone cannot answer.

Start with safer aggregate tools:

```text
inspect_column_profile
  null count or estimate
  min/max for date and numeric columns
  up to 20 distinct values for low-cardinality columns

inspect_relation_size
  PostgreSQL row estimate

inspect_sample_rows
  explicit opt-in only
```

Rules:

* No arbitrary model-authored SQL.
* App builds predefined, parameterized inspection queries.
* Row sampling disabled by default.
* Cloud sharing requires per-connection opt-in.
* Show the user exactly what metadata or values will be sent.
* Redact columns the user marks sensitive.
* Tool responses have strict row and character caps.

This PR should be evaluated separately to quantify whether live metadata materially improves the suite.

Completed on 2026-06-26.

Verification:

```text
make project
make test
make test-db
make eval-schema-tools
make eval-inspection-tools
```

Results:

```text
make test: 776 tests in 43 suites passed.
make test-db: 34 tests in 3 suites passed.
make eval-schema-tools: 10/10 cases passed, definition bytes 1686, estimated definition tokens 562, max response bytes 6111, truncated results 1, determinism failures 0.
make eval-inspection-tools: 11/11 cases passed, policy-denied calls 3, redacted values 1, max result bytes 752, truncations 1.
Optional OpenRouter agent evals were skipped because WIDEN_EVAL_OPENROUTER_API_KEY was not set.
```

---

# PR 10 ⏸️ — Experiment with local schema embeddings [deferred 2026-06-26]

Suggested title:

```text
experiment: add hybrid embedding schema retrieval
```

**Deferred.** The historical failures were not primarily caused by missing semantic vector search — the schema often contained the needed tables and columns, but the model still mixed column ownership, produced invalid SQL, and repeated failed repairs. The priority is to finish the text-to-SQL refactor and validate the actual user experience first. Revisit after PR 12 and after real app/eval testing shows retrieval remains a bottleneck.

**Can run in parallel after PR 5.**

## Goal

Determine whether embeddings improve retrieval beyond lexical search.

Do not introduce a vector database initially. A PostgreSQL schema normally has hundreds or a few thousand searchable objects; brute-force cosine similarity over locally stored vectors is sufficient for the experiment.

## Implementation

Add:

```swift
protocol SchemaEmbeddingProvider {
    func embed(_ texts: [String]) async throws -> [[Float]]
}
```

Use a small local Core ML sentence-embedding model after reviewing its license and app-size impact.

Persist vectors by schema fingerprint.

Hybrid score:

```text
lexical score
+ embedding similarity
+ exact-name boost
+ database-context boost
+ FK graph connectivity boost
```

## Merge gate

Merge only if, on the same retrieval eval:

```text
Recall@5 improves by at least 10 percentage points
or
the agent’s end-to-end accuracy improves by at least 2 of 20 cases
```

without unacceptable launch time, index time, or application size.

If it does not meet that gate, close the experiment. Embeddings are a retrieval enhancement, not the architecture.

---

# PR 11 ✅ — Add a constrained experimental local path [complete 2026-06-26]

Suggested title:

```text
feat: rebuild local text-to-sql as a constrained experimental mode
```

**Can run in parallel with PR 7–10 after PR 2, PR 5, and PR 6.**

## Goal

Keep the Apple model useful without pretending it matches a frontier cloud model.

Recommended local flow:

```text
deterministic schema search
    ↓
optional tiny schema-query planning call
    ↓
fresh generation session with 2–4 detailed tables
    ↓
PostgreSQL verification
    ↓
one repair or clarification
```

Do not implement an open-ended agent loop locally.

Initial local limits:

```text
SELECT only
maximum three base tables
no writes
no deeply nested CTEs
no undefined business metric
maximum two model calls
```

UI label:

```text
On-Device — Experimental
```

Explain that complex requests may require Cloud.

## Promotion threshold

Keep local experimental until it achieves, over three repeated runs:

```text
all simple single-table cases
all quoted-identifier cases
at least 14/20 total cases
zero unsafe or schema-invalid SQL presented to the user
```

## Completion status

Complete as of the final PR 47 accounting fix on 2026-06-26.

Implemented:

* Constrained the on-device path to a maximum two cumulative model calls per request, including repair/follow-up contexts that enter with prior model calls already spent.
* Kept optional schema discovery available only when the request still has budget for both discovery and the subsequent SQL response.
* Ensured context-window retry accounting cannot exceed the same two-call cumulative budget, including failed attempts that already spent discovery.
* Preserved the verification-repair guard: an initial local generation can use one call and validation repair can use the second call, but a subsequent PostgreSQL verification failure does not trigger a third local model call.

Final verification:

```text
make project: project generation succeeded.
focused xcodebuild accounting/pipeline tests: 46 tests in 2 suites passed.
make test: 797 tests in 43 suites passed.
make eval-local REPEAT=3: 60 results; backend available 60/60; static-shape pass rate 20.0% (12/60); stable pass rate 20.0% (4/20); total model calls 84; summary .eval-results/20260626-110912-836/summary.md.
make eval-db-local REPEAT=3: 60 results; backend available 60/60; static-shape pass rate 20.0% (12/60); semantic end-to-end pass rate 20.0% (12/60); SQL semantic pass rate 6/9; PostgreSQL verification attempted pass rate 9/9; semantic environment available 9/9; total model calls 84; summary .eval-results/20260626-111513-208/summary.md.
```

The local Foundation Models backend was available for the final eval runs. The constrained local path remains experimental because the promotion threshold above is not met.

---

# PR 12 ✅ — Backend defaults, older macOS, and release gate

Suggested title:

```text
refactor: make text-to-sql cloud-first with optional on-device mode
```

Only start this after eval evidence from PR 7 and PR 11.

## Implementation

* Isolate `FoundationModels` imports behind availability and conditional compilation.
* Lower the deployment target to the oldest macOS version supported by the rest of Widen’s dependencies.
* Cloud/OpenRouter becomes the default text-to-SQL backend.
* Local appears only on eligible macOS 26 hardware.
* Preserve a fully local mode for users who prioritize privacy over capability.
* Add clear privacy descriptions before sending schema metadata or data values to cloud services.
* Keep normal database browsing and SQL editing independent of AI availability.

## Release gate

Add:

```makefile
make eval-release MODEL=<model>
```

It should run the 20-case suite three times and require:

```text
≥ 90% end-to-end accuracy
100% safety pass
100% schema validity before editor insertion
100% correct clarification decision on ambiguity cases
≥ 95% transport reliability
no repeated repair fingerprints
```

Store a versioned summary under:

```text
docs/evals/<release-version>.md
```

Do not publish the text-to-SQL feature as production-ready until the gate passes.
Until then, text-to-SQL remains beta even though Cloud/OpenRouter is the default
AI path. Manual SQL editing, schema browsing, and normal database work are
supported independently of AI backend configuration.

Completion notes:

* Lowered the app deployment target and `LSMinimumSystemVersion` to macOS 14.0 while keeping Foundation Models and Liquid Glass behind macOS 26 availability gates.
* Made OpenRouter Cloud the default backend for fresh installs (`aiBackendMode = .cloud`, `cloudProvider = .openRouter`, model `openai/gpt-5.5`), kept Local available only on eligible macOS 26+ Apple Silicon hosts, and prevented Local compatibility alerts from blocking normal browsing/manual SQL when Cloud is selected.
* Promoted the OpenRouter schema-tool agent to the default connected-session product path so `make eval-release` tests the same path users get by default.
* Added `make eval-release MODEL=<model>` as the PR 12 release gate with versioned summaries in `docs/evals/<release-version>.md`.
* Updated privacy/default-backend docs to describe cloud schema metadata, optional inspected data values, and optional local mode.
* Ran `make eval-release MODEL=openai/gpt-5.5`; the gate wrote `docs/evals/0.1.0.md` and failed the current production-ready threshold on semantic accuracy and clarification decisions.

---

# PR 13 ✅ — Release-gate triage and schema-tool agent fixes [complete 2026-06-28]

Suggested title:

```text
fix: triage and improve cloud schema-tool agent release gate failures
```

Start from latest `main` after PR 48 and use the PR 12 release gate as the source of truth.

## Goal

Add redacted release-gate triage artifacts and fix the highest-impact cloud schema-tool agent failures without changing backend defaults, eval goldens, seeded semantic data, embeddings, local Foundation Models behavior, or database-inspection privacy policy.

Current PR 12 baseline:

```text
release gate fails
semantic pass rate: 11/60
clarification decision accuracy: 5/12
transport reliability: 60/60
preseason.top-wins-ambiguous: generationFailure in all repeats
preseason.top-wins-defined: wrongDecision in all repeats
```

## Implementation

* Add `make eval-release-triage MODEL=<model>` or `WidenEval --triage-release <run.json>` to generate `.eval-results/<timestamp>/triage.md`, with an optional sanitized `docs/evals/0.1.0-triage.md`.
* Group failures by stable stage/reason categories, not localized error strings, and include per-case redacted fields for decisions, validation status, terminal action, schema-tool usage, inspected objects, safe SQL references, and repeated/no-progress repair.
* Extend schema-tool agent traces with backward-compatible diagnostics: turn counts, terminal-tool behavior, schema evidence ledger summary, app-side rejection reason, and terminal validation failure reason.
* Add deterministic regression tests for `preseason.top-wins-ambiguous` and `preseason.top-wins-defined`, plus generic database-context cases that prove explicit metric/event/time/relationship context is authoritative enough to generate SQL.
* Add one strict correction turn for missing/malformed/mixed terminal results or prose-only model responses, then return a typed failure without fallback one-shot generation.
* Add a deterministic clarification fallback when inspected evidence identifies an unresolved metric, relationship, filter, or time-field choice but no SQL is accepted.
* Improve terminal SQL rejection recovery for uninspected valid objects and invalid column ownership without adding a general repair loop.
* Tighten clarification quality scoring so expected-clarification cases must mention a concrete unresolved database decision.
* Extend release-gate reporting/tests to call out the historical Preseason regressions and generic SQL validity checks around quoted timestamps, timestamp-vs-interval comparisons, invalid bindings, and repeated repairs.

## Acceptance

Required before closing PR 13:

```text
make test passes
release-gate triage report is generated
preseason.top-wins-ambiguous clarifies correctly in 3/3 repeats
preseason.top-wins-defined passes semantic DB eval in 3/3 repeats
clarification decision accuracy improves from 5/12 to at least 9/12
end-to-end semantic pass rate improves above 11/60
transport reliability stays at or above 95%
safety and schema validity stay at 100% for evaluated SQL
repeated/no-progress repair count remains zero
no raw prompts, API keys, result rows, or full schemas are committed
```

If the target numbers are not met, commit the triage report and focused test results, and keep docs clear that text-to-SQL remains not production-ready.

---

# PR 14 ✅ — Resumable, budget-aware release-gate evals [complete 2026-06-28]

Suggested title:

```text
test: make release-gate evals resumable and budget-aware
```

Start from latest `main` after PR 49.

## Goal

Make the OpenRouter release-gate workflow practical to run repeatedly without
wasting provider credits. PR 49 improved the agent and added triage, but the
full `make eval-release` run hit the provider key's total limit after only 8
evaluated results. Before another accuracy pass, make the release gate
resumable, partial-run aware, and cost/budget visible.

## Do not change

* Production prompts.
* Schema-tool agent behavior.
* SQL validation or repair.
* Eval fixture goldens.
* Seeded DB data.
* Backend defaults.
* Local Foundation Models behavior.
* Privacy policy.
* Release-gate thresholds.

## Implementation

Add resumable eval CLI support:

```text
--resume-run <path-to-run-directory-or-run.json>
--resume-missing
--resume-failed
--resume-case-status <status[,status...]>
```

Resuming loads the previous `run.json` manifest and `cases.jsonl`, validates
compatibility, writes a new run directory, records `parentRunID`/`resumedFrom`,
preserves repeat indexes exactly, reuses compatible results, and reruns only
missing, failed, or explicitly selected statuses.

Compatibility checks must include:

* Suite name, version, and hash.
* Schema fixture hashes.
* Model ID.
* Backend.
* Cloud-agent mode.
* Semantic DB setting.
* Scorer/evaluator source hashes.
* Selected release-gate version when applicable.

Add budget controls:

```text
--max-cloud-cost-usd <decimal>
--max-http-attempts <int>
--max-completed-results <int>
--stop-before-provider-limit
```

Budget stops should stop cleanly, write all normal artifacts for partial runs,
avoid classifying budget stops as transport/model failures, and make release
gate runs fail incomplete when fewer than the expected results were evaluated.

Update eval and release-gate reporting to show:

* Complete versus partial status.
* Expected results.
* Actual completed results.
* Missing result count.
* Skipped budget count.
* `resumedFrom`, if any.

Release-gate failures should say:

```text
Release gate incomplete: only X/Y expected results were evaluated.
```

Keep incomplete-run failures separate from normal threshold failures.

Add focused commands:

```makefile
make eval-release-preseason MODEL=openai/gpt-5.5
make eval-release-resume MODEL=openai/gpt-5.5 RESUME=<path>
```

The preseason command runs only:

```text
preseason.top-wins-ambiguous
preseason.top-wins-defined
```

with cloud backend, schema-tool agent, semantic DB grading, `--repeat 3`, and
release triage output.

The resume command runs:

```text
WidenEval --resume-run "$(RESUME)" --resume-missing --release-gate-version "$(RELEASE_VERSION)" --write-release-triage
```

When OpenRouter returns structured credits, payment, or provider-limit failures,
classify them distinctly from generic generation or transport failures and make
the eval summary state that provider budget was unavailable.

For incomplete triage reports:

* Show categories for evaluated failures.
* Add a "Not Evaluated" section listing missing case IDs and repeats.
* Highlight historical Preseason cases separately even if only one ran.
* Do not imply pass/fail for cases that were not run.

## Tests

Add deterministic tests for:

* Loading a previous run and reusing compatible results.
* Rejecting resume with changed suite hash.
* Rejecting resume with changed model, backend, or cloud-agent mode.
* Rerunning only missing cases.
* Rerunning only failed cases.
* Preserving repeat indexes.
* Writing a new run directory.
* Release gate failing as incomplete when fewer than 60 expected results exist.
* Triage working on partial runs.
* Budget stops not becoming transport failures.
* Provider-limit classification being distinct.
* Makefile command behavior where testable.

Use fake eval results and fake generators. Unit tests must not require
OpenRouter.

## Manual verification

Run:

```text
make project
make test
```

Then, if OpenRouter and Postgres env is available:

```text
make eval-release-preseason MODEL=openai/gpt-5.5
```

If that succeeds, run:

```text
make eval-release MODEL=openai/gpt-5.5
```

If it stops early due provider budget, immediately test resume:

```text
make eval-release-resume MODEL=openai/gpt-5.5 RESUME=<previous-run-dir>
```

## Acceptance

* Release-gate evals can resume missing cases without rerunning completed cases.
* Partial runs are clearly labeled incomplete.
* Provider budget/credit failures are distinct from transport/model failures.
* Triage reports work for complete and partial runs.
* Focused Preseason release command exists.
* No production text-to-SQL behavior changes.
* `make test` passes.

---

# PR 15 ✅ — Release-gate baseline and triage docs [complete 2026-06-28]

Suggested title:

```text
docs: complete release gate baseline and triage
```

Start from latest `main` after PR 50.

## Goal

Use the PR 14 resumable and budget-aware release-gate eval workflow to produce
a current baseline for the default OpenRouter schema-tool path. This PR is
evaluation/reporting only unless a tiny reporting bug blocks completion.

## Scope

Run `make project`, `make test`, and `make eval-build`; then run the focused
Preseason gate before the full release gate:

```text
make eval-release-preseason MODEL=openai/gpt-5.5
make eval-release MODEL=openai/gpt-5.5
make eval-release-resume MODEL=openai/gpt-5.5 RESUME=<run-dir>
```

Resume incomplete runs without rerunning completed cases until the gate is
complete, or until provider budget is unavailable.

Commit only sanitized docs:

```text
docs/evals/0.1.0.md
docs/evals/0.1.0-triage.md
docs/refactoring-plan.md
```

Do not change production prompts, schema-tool behavior, SQL validation/repair,
schema retrieval, eval goldens, seeded fixtures, backend defaults, local
Foundation Models behavior, privacy settings, or embeddings. Do not commit raw
run directories, prompts, model output, SQL with sensitive content, database
rows, API keys, or local absolute paths.

## Required report shape

The release summary must show complete/incomplete status, expected/completed/
missing results, budget/provider stops, semantic pass rate, clarification
accuracy, safety/schema validity, transport reliability, and repeated repair
count. Triage must group failures by stable category and explicitly list
`preseason.top-wins-ambiguous` and `preseason.top-wins-defined` repeat status,
semantic status, clarification/semantic result, repeated repair, invalid
binding detection, and quoted timestamp check when SQL exists.

If the gate remains incomplete, docs must say text-to-SQL is not production-ready
and the next action is to resume when provider budget is available. If it
completes, add the next failure bucket here for PR 16.

## Acceptance

* `make test` passes.
* Focused Preseason and full release gates are complete, or clearly incomplete
  only because provider budget is unavailable.
* `docs/evals/0.1.0.md` is updated from the latest run.
* `docs/evals/0.1.0-triage.md` is present if generated.
* No raw prompts, keys, row values, local absolute paths, or production behavior
  changes are committed.

Completion notes:

* `make project`, `make test`, and `make eval-build` passed on 2026-06-28.
* Focused Preseason gate completed 6/6 results; full release gate completed
  60/60 results with provider budget available.
* Gate failed: semantic end-to-end 20/60 (33%); clarification decision accuracy
  10/12 (83%); safety, schema validity, transport reliability, and repeated
  repair checks passed.
* Sanitized artifacts: `docs/evals/0.1.0.md` and
  `docs/evals/0.1.0-triage.md`.

## Next failure bucket

Top category: wrong decision, expected SQL but got clarification (28 results).

Affected case IDs: `commerce.average-order-value-country`,
`commerce.customer-paid-revenue`, `commerce.customers-without-orders`,
`saas.expiring-subscriptions`, `saas.overallocated-seats`,
`saas.users-without-membership`, `support.average-first-response`,
`support.frequent-feedback-cluster`, `support.unclustered-feedback`, and
`support.unresolved-by-assignee`.

Failures are mostly wrong decision. Secondary buckets are tool budget exhausted
(7), semantic mismatch (4), and static schema failure (1). Text-to-SQL is not
production-ready; PR 16 should start with the wrong-decision/over-clarification
bucket.

---

# PR 16 ✅ — Reduce schema-tool over-clarification [complete 2026-06-28]

Implemented a schema-tool clarification policy that rejects generic
clarifications, treats explicit database context as authoritative, sends one
strict correction when evidence is sufficient for SQL, records redacted policy
trace fields, and preserves concrete ambiguity clarifications. Also added the
focused over-clarification release helper and policy/agent/postprocessor tests.

Before/after against the full release gate:

| Metric | PR 51 baseline | PR 16 run |
| --- | ---: | ---: |
| End-to-end semantic pass | 20/60 | 24/60 |
| Clarification decision accuracy | 10/12 | 10/12 |
| Expected SQL, got clarification | 28 | 3 |
| Tool budget exhausted | 7 | 9 |

Preseason historical status stayed green: `top-wins-ambiguous` clarified 3/3,
`top-wins-defined` semantically passed 3/3, and invalid tool A/B binding stayed
at 0.

PR 16 did not make text-to-SQL production-ready. The full gate still failed:
semantic end-to-end reached 24/60, below the 30/60 PR target and the release
threshold, and tool-budget failures increased. The next largest bucket is now
semantic result mismatch (24 results), followed by tool budget exhausted (9).

Sanitized artifacts were updated in `docs/evals/0.1.0.md` and
`docs/evals/0.1.0-triage.md`.

## PR 52 ✅ — Diagnostics-only schema-tool policy infrastructure [complete 2026-06-28]

PR 52 merged diagnostics-only. Experimental correction modes remain disabled by
default and are not production behavior. It keeps the answerability policy, SQL
intent coverage policy, redacted trace fields, semantic mismatch categories, and
triage columns, but default production behavior is conservative: both new
schema-tool enforcement modes default to diagnostics only. The default
OpenRouter schema-tool path records policy decisions without forcing
clarification into SQL and without running the SQL intent-correction loop.

The focused over-clarification helper explicitly enables the experimental
correction modes. Those modes still do one strict correction for missing
deterministic intent such as status predicates, anti-join/null semantics,
aggregates, group/order/limit shape, anchored date windows, database-context
filters, or obvious projection/unit requirements. Eval artifacts are now written
before the first model call and after each result, with per-case progress
heartbeats so a stalled run leaves partial output.

Local verification passed:

```text
make project
make test
```

Latest completed focused experimental over-clarification run:
`.eval-results/20260628-124309-188` at commit `dce4f4d`, with
`clarificationCorrectionMode=correctOverClarificationExperimental` and
`intentCoverageMode=correctAndRetryExperimental`.

| Metric | Full PR 16 gate | PR 52 focused experimental |
| --- | ---: | ---: |
| Scope | 60 | 30 |
| End-to-end semantic pass | 24/60 | 11/30 |
| Clarification decision accuracy | 10/12 | n/a |
| Expected SQL, got clarification | 3 | 3 |
| Semantic result mismatch | 24 | 5 triage / 6 semantic status |
| Tool budget exhausted | 9 | 3 triage / 2 summary |
| Model/tool protocol failure | 0 | 6 |
| Repeated/no-progress repair | 0 | 0 |
| Transport reliability | 60/60 | 30/30 |

Previous focused Preseason status remained semantically green:
`top-wins-ambiguous` clarified 3/3, `top-wins-defined` semantically passed 3/3,
and invalid tool A/B binding stayed at 0. One `top-wins-defined` repeat still
had a static schema-object failure despite semantic equivalence.

This run completed without the previous no-artifact stall, but it does not meet
the behavior-changing acceptance gate. PR 52 merged for diagnostics, traces,
tests, and artifact hardening only. The current largest focused buckets are
model/tool protocol no-progress after intent correction, semantic projection and
row-order mismatches, residual `support.average-first-response` clarification,
and tool budget exhaustion on saas status/filter cases. The next production fix
should not be more force-SQL pressure; it should target stable query-plan and
SQL-shape generation, or deterministic synthesis for common patterns.

## PR 53 ✅ — Intent coverage review fixes and heuristic scope freeze [complete 2026-06-28]

PR 53 addressed the PR 52 review feedback: it reduced intent-coverage false
positives (subject-scoped metric definitions, count-alias and status-predicate
value matching, tiered context date anchors), cleared stale clarification
rejection state after corrected SQL succeeds, and let older eval run manifests
resume when the schema-agent mode fields are absent by treating them as
diagnostics-only defaults. Both correction modes still default to
`diagnosticsOnly`; production behavior is unchanged.

PR 53 also froze the scope of `SchemaToolAgentSQLIntentCoveragePolicy`. Review
iteration showed that phrase-level heuristics do not converge: every refinement
surfaces new linguistic and SQL-shape edge cases. The policy stays a
diagnostics-only triage layer tuned for the eval suites, and it is intentionally
non-exhaustive. New phrasing or SQL-form rules should not be added to it; per
the background principle above, Widen avoids building a hardcoded
natural-language parser and SQL conformance engine. Accuracy work continues in
schema retrieval, bounded schema tools, PostgreSQL verification with repair,
and — if pursued — deterministic synthesis for common patterns as noted in the
PR 52 conclusion.

---

# PR 54 ✅ — Stabilize schema-tool query planning and SQL shape [complete 2026-07-09]

Suggested title:

```text
fix: stabilize schema tool sql shape
```

Start from latest `main` after PR 53. Keep PR 10 deferred: the latest release
gate shows the largest remaining default-path bucket is semantic mismatch and
SQL-shape drift, not missing schema retrieval.

## Goal

Improve the default OpenRouter schema-tool agent's SQL-shape reliability without
turning the diagnostics-only intent-coverage policy into a production
natural-language parser or enabling experimental correction modes by default.

The current baseline from `docs/evals/0.1.0-triage.md` is:

```text
semantic result mismatch: 24
semantic end-to-end pass: 24/60
wrong decision, expected SQL got clarification: 3
tool budget exhausted: 9
safety/schema validity: 100%
transport reliability: 60/60
repeated/no-progress repair: 0
```

## Implementation

* Extend the schema-tool terminal result contract with optional redacted
  `query_plan` text for SQL terminal results. The plan should summarize grain,
  joins/roles, filters, projection/aliases/units, grouping, ordering, limit,
  and date anchors.
* Persist the terminal query plan in `OpenRouterSchemaToolAgentDiagnostics`
  with backward-compatible decoding, and include it in redacted eval/triage
  reporting when present.
* Update default and experimental schema-tool instructions so terminal SQL must
  be preceded by that concise SQL-shape checklist. Missing or imperfect
  `query_plan` remains diagnostics-only; do not reject otherwise valid SQL for
  a plan-format issue.
* Add `make eval-release-sql-shape MODEL=openai/gpt-5.5` for the current
  semantic-mismatch bucket:
  `commerce.average-order-value-country`, `commerce.customer-paid-revenue`,
  `commerce.customers-without-orders`, `preseason.active-match-configs`,
  `preseason.verified-tools`, `saas.expiring-subscriptions`,
  `saas.overallocated-seats`, `support.frequent-feedback-cluster`,
  `support.unclustered-feedback`, and `support.unresolved-by-assignee`.
* Do not change eval goldens, seeded semantic data, schema fixtures, backend
  defaults, privacy policy, local Foundation Models behavior, or PR 52/53
  diagnostics-only defaults.

## Tests

Add deterministic tests for optional `query_plan` parsing, backward-compatible
diagnostic metadata decoding, prompt contents, release triage redaction, and
the focused Makefile command. Unit tests must not require OpenRouter.

Manual verification:

```text
make project
make test
make eval-release-sql-shape MODEL=openai/gpt-5.5
```

Run the focused eval only when OpenRouter and seeded Postgres eval environment
variables are available. If the focused run improves, run the full release gate:

```text
make eval-release MODEL=openai/gpt-5.5
```

Focused eval note, 2026-07-09: a PR 54 working-tree run of
`make eval-release-sql-shape MODEL=openai/gpt-5.5` completed all 30 focused
results with 6 static passes, 0 semantic end-to-end passes, 24 wrong-decision
results, 6 semantic mismatches, 0 tool-budget failures, 100% safety/schema
validity on evaluated SQL, 30/30 transport success, and 0 repeated repairs.
The run did not improve the semantic mismatch bucket. The redacted triage did
show populated query-plan summaries, so this step adds observability and prompt
pressure, but default diagnostics-only behavior still needs a follow-up shape
correction or synthesis step before the full release gate should be rerun.

PR 54 closed with this negative focused result. It kept the query-plan
diagnostics and did not promote a behavior-changing SQL-shape correction.

## Acceptance

* Focused SQL-shape eval improves the semantic mismatch bucket, or the docs
  record why it did not.
* Full release-gate target before closing PR 54: semantic mismatches below 24,
  semantic pass above 24/60, wrong-decision clarifications no worse than 3,
  tool-budget failures no worse than 9, safety/schema validity 100%,
  transport reliability at least 95%, and repeated repair count 0.
* No raw eval runs, prompts, API keys, row values, full schemas, or local
  absolute paths are committed.

---

# PR 55 ✅ — Select and pin the OpenRouter SQL profile [complete 2026-07-10]

Suggested title:

```text
feat: standardize openrouter sql profile
```

PR 55 compared the remaining eligible OpenRouter candidates under explicit
cost caps, required private routing, the production schema-tool path, seeded
PostgreSQL semantic grading, and deterministic promotion criteria. PR 10
embeddings remain deferred because these failures are SQL decision and shape
failures, not missing schema retrieval.

Original bake-off evidence:

| Candidate | Focused semantic | Cost | Outcome |
| --- | ---: | ---: | --- |
| Claude Sonnet 5 | 2/30 | $1.038 | Tied Terra at higher measured cost |
| GPT-5.6 Terra | 2/30 | $0.633 | Best original focused power/cost result |
| DeepSeek V4 Pro | 1/30 | $0.607 | Rejected for schema and latency failures |
| GPT-5.6 Terra full | 17/60 | $1.512 | Below the established GPT-5.5 24/60 baseline |

Corrected comparison after the query-plan work:

| Run | Semantic / transport | Cost | P95 | Decision |
| --- | ---: | ---: | ---: | --- |
| GPT-5.5 focused | 1/30 semantic; 30/30 transport/parse | $1.518680 | 24,528 ms | Eligible |
| GPT-5.6 Terra focused | 5/30 semantic; 30/30 transport/parse | $0.691767 | 26,643 ms | Focused winner |
| GPT-5.6 Terra smoke | 15/15 transport/parse | $0.079022 | 8,110 ms | Private-routing smoke passed |
| GPT-5.6 Terra full | 22/60 semantic; 59/60 transport; 57/59 parse | $1.484147 | 56,860 ms | Not promoted |

Terra won the focused comparison mechanically because its 16.7% semantic pass
rate exceeded GPT-5.5's 3.3% by more than five percentage points. The complete
full run then failed the incremental promotion gate: semantic performance did
not exceed 24/60 and four results had static schema failures. Clarification
accuracy was 10/12, safety was 40/40, transport and parsing remained above 95%,
and forbidden bindings, repeated/no-progress repairs, and eval timeouts stayed
at zero, but those passing criteria do not override either failed requirement.

The approved fallback was applied:

* Reverted only the experimental trusted-agent grounding bypass.
* Kept private OpenRouter routing: zero data retention, provider data collection
  denied, and all request parameters required.
* Fixed the product profile to requested model `openai/gpt-5.5`, expected
  canonical model `openai/gpt-5.5-20260423`, display name `GPT-5.5`.
* Made the schema-tool agent the only connected-session OpenRouter path and
  removed custom model and agent-path preferences from Settings.
* Added fail-closed canonical-version checks for product completions and the
  model connectivity test. Eval model and agent CLI overrides remain free-form.
* Kept Cloud/OpenRouter as the fresh-install default and kept Local as an
  optional experimental backend on eligible Macs for narrow requests and
  simple databases.
* Kept cloud text-to-SQL labeled beta. The complete production-ready release
  gate remains unmet.

New PR 55 evaluation spend was $3.773616, below the $6.00 implementation cap.
Historical bake-off artifacts remain in their run directories; the current
sanitized release summary and triage record the complete negative pinned
GPT-5.5 run.

## PR 55 hardening follow-up [2026-07-10]

A post-merge review pass hardened the pinned-profile work on the same branch:

* Pinned-model eval runs now enforce the same canonical-version contract as
  the app, including a pre-flight catalog check that fails before any billed
  completion when OpenRouter rolls the canonical version. The live catalog
  and completion responses both confirmed `openai/gpt-5.5-20260423`.
* `make eval-release` and `make eval-release-triage` refuse a non-pinned
  `MODEL=` override unless `ALLOW_MODEL_OVERRIDE=1` is set, so gate docs can
  no longer silently record a non-production model.
* Settings surfaces the underlying catalog error for a rejected key, missing
  response model versions produce a distinct fail-closed message, private
  routing rejections explain Widen's requirements, the zero-retention claim
  is one shared constant across views, and OpenRouter key/credit-limit
  failures are classified as provider budget rather than permission denied.

The full release gate was rerun at HEAD for the pinned GPT-5.5 profile with
private routing and canonical enforcement active (a first attempt stopped at
23/60 on an exhausted key limit; after the limit was raised, the complete
rerun cost $3.18). Complete results, recorded in `docs/evals/0.1.0.md`:

```text
gate: failed (still beta)
semantic end-to-end: 19/60
clarification decision accuracy: 11/12
safety and schema validity: 100%
transport: 60/60 with private routing and canonical checks on every request
repeated/no-progress repairs: 0
wrong decision, expected SQL got clarification: 28
semantic result mismatch: 6
tool budget exhausted: 6
```

The failure profile flipped versus the June 24/60 baseline: semantic
mismatch collapsed (24 to 6) while host-side false clarification returned to
its pre-PR 16 level (3 to 28). All 28 of those results had terminal action
`sql` — the model produced SQL and the legacy grounding clarification path
discarded it. The June baseline ran with PR 16's over-clarification
enforcement, which PR 52 later defaulted to diagnostics-only; the current
default path therefore reproduces the PR 15-era wrong-decision bucket. The
highest-leverage next step is the trusted-agent grounding-bypass experiment
on the pinned model (PR 56 in `docs/next-dev-steps.md`), which targets
exactly this bucket. The June GPT-5.5 24/60 record remains in git history at
commit `386f363` and earlier.

## PR 56 grounding-bypass experiment ✅ [completed 2026-07-14]

The first pinned GPT-5.5 attempt was inconclusive. Commit `747eef5` restored
the previously tested bypass and passed the two focused validator/pipeline
suites (182 tests) and the full unit suite (1,094 tests). The capped
`make eval-release-triage MODEL=openai/gpt-5.5 MAX_CLOUD_COST_USD=4` run
produced 35/35 typed `modelVersionMismatch` failures from HTTP-successful
Azure responses before any schema tool ran. The authenticated catalog named
canonical `openai/gpt-5.5-20260423`, while every top-level completion `model`
field contained only `openai/gpt-5.5`. The run stopped with 25 records missing,
$0.204335 spent, and P95 latency 4,748 ms; `30c5cb9` reverted the bypass.

The response contract was then resolved without trusting the alias alone.
OpenRouter router metadata echoes the requested alias and reports the selected
endpoint's concrete model. Commit `9d8eb1a` accepts an alias response only when
that requested value matches and exactly one selected endpoint reports the
pinned canonical ID. Missing, ambiguous, conflicting, or unexpected evidence
still produces `modelVersionMismatch`; both regular and tool-chat parsers use
the same validator. Its focused parser suites passed 126 tests.

Commit `cd10d86` restored the bypass for a second gate. The 182 focused
validator/pipeline tests and the full 1,097-test suite passed. The complete
60/60 gate cost $3.276305 and recorded:

```text
pre-registered PR 56 criteria
semantic end-to-end: 22/60 (required >= 20)             pass
clarification decisions: 9/12 (required >= 11)          fail
safety validity: 41/41 (required 100%)                  pass
schema validity: 41/41 (required 100%)                  pass
transport: 60/60 (required >= 95%)                      pass
structured parsing: 57/60 (required >= 95%)             pass
forbidden bindings: 0                                   pass
repeated/no-progress repairs: 0                         pass
eval-timeout status: 0                                  pass
internal schema-agent timeout surfaced as parseFailure: 1  strict fail
latency: P50 16,977 ms; P95 30,244 ms; max 91,012 ms
```

The experiment therefore fails its conjunctive promotion gate even though
semantic end-to-end improved from 19 to 22. Clarification alone is sufficient
to reject it; a strict reading that counts any internal timeout also fails.
Cumulative branch OpenRouter spend
was $3.481360: the $0.204335 inconclusive attempt, $0.000720 in two metadata
probes, and the $3.276305 complete gate. The bypass is reverted in the
following commit while the canonical router-metadata verifier remains.

Fresh failure buckets explain the tradeoff:

```text
bucket                                      PR 55 comparator   PR 56 experiment
wrong decision, expected SQL got clarify            28                 5
semantic result mismatch                              6                28
tool-budget triage                                     6                 5
static schema failure                                  1                 0
```

The five non-budget wrong-decision records are outside the bypass trust
contract: four terminal SQL results had deterministic `invalidSQL` app
rejections, and one result was an explicit model clarification. The semantic
mismatches are now the largest actionable experimental bucket, dominated by
projection shape differences (20 missing candidate-column and 7
unexpected-extra-column comparisons, plus 1 ordered-row mismatch). PR 57 is
therefore the accuracy lever if a future bypass retry first clears every
promotion criterion; the 28-result bucket is not the retained product baseline
after this revert.

The 9/12 clarification result does not justify expanding frozen phrase
heuristics. Two `saas.healthy-accounts` repeats consumed six successful schema
calls and received an error on the seventh `inspect_column_constraints` call.
One `preseason.top-wins-ambiguous` repeat instead timed out after 91 seconds
before any schema call, but its `budgetExhausted` diagnostic grouped it into
the redacted tool-budget bucket. The same six-call pattern also affected two
`saas.active-users-by-org` SQL decisions. PR 59 should separate that timeout
classification from genuine exhaustion and explain the redundant zero-result
search/join-path sequences before changing behavior. Do not raise the six-call
budget without evidence. PR 58 follows only if clarification remains
independently below 12/12 after those operational failures are addressed.

PR 59 subsequently implemented that separation and the redundancy fix in
commits `47d6ad1`, `2b28900`, and `551ce3e` without raising the six-call
budget: a
dedicated wall-clock timeout failure category with its own `timedOut`
diagnostic, eval status, `schema-agent timeout` triage bucket, and gate-report
count, plus deterministic pre-invocation interception of value-identical
repeats, repeated zero-result searches, and already-explored join-path scopes
so they no longer burn schema-tool budget. Implementation details and the
completed acceptance measurement live in `docs/next-dev-steps.md`.

### Post-PR 59 PR 56 retry [2026-07-14] — ✅ Done, negative

Commit `bcaf957` restored the exact patch last tested in `cd10d86`. Stable
patch comparison confirmed that the `cd10d86` and `747eef5` restores are
identical, while the older `7d6baff` patch predates later test-helper changes.
The retry changed only the grounding bypass and its validator/pipeline tests;
the routed-model verifier, canonical enforcement, privacy routing, safety and
schema validation, PostgreSQL verification, frozen phrase heuristics, and
six-call schema-tool limit were unchanged. The two focused suites passed 182
tests, `make test` passed 1,117 tests in 49 suites, and the complete pinned
gate recorded:

```text
pre-registered PR 56 criteria
complete results: 60/60                                  pass
semantic end-to-end: 26/60 (required >= 20)             pass
clarification decisions: 11/12 (required >= 11)         pass
safety validity: 42/42 (required 100%)                  pass
schema validity: 42/42 (required 100%)                  pass
transport: 60/60 (required >= 95%)                      pass
structured parsing: 59/60 (required >= 95%)             pass
forbidden bindings: 0                                   pass
repeated/no-progress repairs: 0                         pass
eval-timeout status: 0                                  pass
internal schema-agent timeouts: 1 (required 0)           fail
latency: P50 17,968 ms; P95 33,781 ms; max 93,681 ms
cost: $3.521450
```

The criteria are conjunctive, so the one internal schema-agent timeout rejects
the bypass despite every other PR 56 criterion passing. The timeout was
reported consistently as a `generationFailure`, the `schema-agent timeout`
triage bucket, and an `Internal schema-agent timeouts` run-table count of one;
it was not an eval timeout, parse failure, or tool-budget triage result. Commit
`842bd42` reverted only the bypass. The sanitized gate intentionally records
`bcaf957`, the commit that was evaluated, while routed-model and canonical
enforcement remain in the retained product. Recorded branch OpenRouter spend
was $3.521450, below both the $4 gate cap and $8 branch authorization.

The fresh exclusive triage categories were 26 semantic mismatches, five
expected-SQL clarifications, one expected-clarification SQL decision, one
schema-agent timeout, one earlier-zero-hit `no schema match` classification,
and zero tool-budget, safety, or schema failures. The semantic-status total is
27 mismatches because category precedence assigns the result with the earlier
zero-hit search to `no schema match` even though it later produced and verified
SQL. The sole clarification miss, `preseason.top-wins-ambiguous` repeat 3,
returned SQL independently of timeout or budget behavior. PR 58 is therefore
next; PR 57 remains conditional on a future bypass iteration passing every
promotion criterion.

### PR 58 comparator reconciliation [2026-07-14] — pre-registered

Before any PR 58 paid gate, the acceptance comparator was reconciled against
the retained production path. The historical expected-SQL clarification
ceiling of 3 came from the PR 16 configuration that PR 52 later made
diagnostics-only. The retained PR 55 product-path comparator instead recorded
28 in that exclusive triage bucket, while the later value of 5 came from a
rejected and reverted grounding-bypass experiment. The approved PR 58 gate
therefore requires 12/12 clarification decisions across three repeats without
raising the retained-path expected-SQL clarification bucket above 28. This
choice was recorded before seeing PR 58 results; it does not restore the
grounding bypass or broaden the frozen phrase heuristics.

### PR 58 funded attempt [2026-07-14] — negative, behavior reverted

The narrow attempt enforced the existing terminal `mustClarify` intent
coverage decision while preserving diagnostics-only handling for broader SQL
shape corrections. Deterministic tests reproduced the prior terminal-SQL
failure before the change and passed afterward, alongside nearby ambiguous
and defined-context controls. The focused clarification/validator/pipeline/
reporting matrix passed 427/427 tests, the full suite passed 1,112 tests, and
`make eval-build` passed before the gate.

The complete pinned `openai/gpt-5.5` gate evaluated commit `ff79bb2`, completed
60/60 cases, and spent $3.330465 under the authorized $4 cap. It failed both
pre-registered PR 58 criteria:

| Mechanical criterion | Retained PR 55 comparator | PR 58 attempt | Result |
| --- | ---: | ---: | --- |
| Clarification decisions | 11/12 | 10/12 | Fail (required 12/12) |
| Exclusive expected-SQL clarification bucket | 28 | 30 | Fail (required `<= 28`) |
| Semantic end to end | 19/60 | 19/60 | No change |

The targeted `preseason.top-wins-ambiguous` path did reach the new guard in
repeat 2: diagnostics recorded `mustClarify`, and the app returned a
clarification instead of the model's SQL. It nevertheless failed the
clarification-quality scorer because the fallback used plural “wins,” while
the expected concepts contain singular “win” or “winner” and the scorer does
not stem terms. The separate `saas.healthy-accounts` repeat 2 miss exhausted
the fixed six-call budget and had its seventh schema-tool request rejected;
there was no terminal response for the guard to inspect.

A reporting-only follow-up fixed the triage policy column so intent-policy
diagnostics remain visible when the separate clarification-policy decision is
empty. Offline re-triage now records `unresolved: metric; intent: mustClarify`
for the ambiguity miss without changing decisions or scoring.

The raw expected-SQL-to-clarification count stayed 33 in both runs. Exclusive
triage precedence assigned five of those comparator results and three attempt
results to the tool-budget category, producing the pre-registered comparison
of 28 to 30. That criterion was applied mechanically without post-result
reinterpretation.

The complete attempt also recorded 19/60 semantic end-to-end, SQL semantic
9/15, safety 15/15, schema validity 15/15, PostgreSQL verification 15/15,
transport 60/60, structured parsing 59/60, forbidden bindings 0,
repeated/no-progress repairs 0, eval timeouts 0, internal schema-agent
timeouts 0, direct schema-tool budget failures 1 (exclusive triage bucket 4),
and semantic mismatches 6. Latency was 15,717 ms P50, 27,042 ms P95, and
30,725 ms maximum. All 60 requested and returned aliases were
`openai/gpt-5.5`; private routing, canonical-model enforcement, and
routed-model verification remained active. The sanitized evidence is in
the history of commit `4618375`; those report paths now contain the later
retry described below.

Because the conjunctive criteria failed, commit `b3b69fe` reverted the
behavioral change and its tests. PR 58 remains not done. The retained tree
still has `maximumSchemaToolCalls == 6`, the PR 53 phrase-heuristic freeze,
all safety/schema/PostgreSQL and structured-response checks, PR 59 timeout/
budget/interception behavior, and no PR 56 grounding bypass. A retry should
make evidence-specific ambiguity wording quality-safe and separately address
terminal-less nonredundant six-call exploration, then earn a fresh funded
gate rather than retaining an unproven change.

### PR 58 funded retry [2026-07-15] — negative, behavior reverted

Candidate `f356ba4` addressed both mechanisms exposed by the first attempt.
It changed the existing protected-metric fallback to ask what counts as one
win, centralized evidence-vetted ambiguity selection, and added a bounded
response after a real rejected seventh schema-tool request. The budget path
either returned a protected, evidence-grounded clarification or allowed one
terminal-only model turn for SQL; it did not permit an eighth schema-tool
invocation or change `maximumSchemaToolCalls == 6`. Deterministic coverage
included the historical terminal-SQL miss, the terminal-less six-call miss,
defined and ungrounded controls, trailing batches, attempted eighth calls,
timeout precedence, and the pinned clarification scorer. No phrase-matching
set was added or broadened.

The focused ten-suite matrix passed with 571 successful test executions and
no failures, `make test` passed 1,120 tests across 49 suites, and
`make eval-build` passed. The complete pinned `openai/gpt-5.5` gate evaluated
`f356ba4`, completed 60/60 cases, and spent $3.378570 under the fresh $4 cap.

| Mechanical criterion | Retained PR 55 comparator | PR 58 retry | Result |
| --- | ---: | ---: | --- |
| Clarification decisions | 11/12 | 12/12 | Pass (required 12/12) |
| Exclusive expected-SQL clarification bucket | 28 | 30 | Fail (required `<= 28`) |
| Semantic end to end | 19/60 | 21/60 | Informational (+2) |

All three `preseason.top-wins-ambiguous` repeats and all three
`saas.healthy-accounts` repeats clarified correctly. The raw
expected-SQL-to-clarification count was 33; triage precedence assigned three
of those outcomes to `tool budget exhausted`, leaving 30 in the exclusive
guardrail bucket. The pre-registered criteria are conjunctive, so 12/12 did
not offset the over-clarification failure. The general release gate also
failed independently at 21/60 semantic end to end versus its 90% threshold.

The complete retry also recorded SQL semantic 9/15, safety 15/15, schema
validity 15/15, PostgreSQL verification 15/15, transport 60/60, structured
parsing 60/60, forbidden bindings 0, repeated/no-progress repairs 0, eval
timeouts 0, internal schema-agent timeouts 0, direct schema-tool budget
failures 0, six results with one app-side budget-rejection trace each, an
exclusive tool-budget triage bucket of 3, and semantic mismatches 6. Latency
was 15,820 ms P50, 32,361 ms P95, and 73,599 ms maximum. All 60 requested and
returned aliases were `openai/gpt-5.5`; private routing, canonical-model
enforcement, and routed-model verification remained active. The two PR 58
funded gates spent $6.709035 in total, of which this retry used $3.378570.

Commit `e13f6aa` reverted `f356ba4` and its tests after the failed guardrail.
PR 58 remains not done, and the latest sanitized gate and triage reports are
`docs/evals/0.1.0.md` and `docs/evals/0.1.0-triage.md`; they intentionally name
the evaluated candidate rather than the later revert. The retained tree keeps
the six-call budget, PR 53 heuristic freeze, safety/schema/PostgreSQL and
structured-response checks, private and canonical/routed-model protections,
PR 59 timeout/budget/interception behavior, and no PR 56 bypass. Any future
retry needs a narrower recovery for the protected ambiguity class that reaches
12/12 and keeps the exclusive expected-SQL clarification bucket at or below
28 with margin for triage-precedence movement, followed by fresh spend
authorization.

### PR 59 funded acceptance measurement [2026-07-14] — ✅ Done

The same complete gate supplied PR 59's pre-registered measurement:

| Metric | Same-bypass baseline | 2026-07-14 retry | Result |
| --- | ---: | ---: | --- |
| Failed-result tool-budget bucket | 5 | 0 | Pass (`<= 3`) |
| Cost per result | $0.054605083 | $0.058690833 | Pass (+7.48%) |
| P95 latency | 30,244 ms | 33,781 ms | Pass (+11.70%) |
| Schema-agent timeout bucket | Misclassified with tool budget | 1 | Correctly populated |
| Internal timeout count | Not separately reported | 1 | Correctly populated |
| Redundant duplicate / zero-search / join-path | Not available | 0 / 0 / 0 | Counters populated |

All 60 diagnostics carried all three redundant-interception counters; zero
totals mean none of the interception paths fired in this sample. Two otherwise
successful `preseason.top-wins-ambiguous` clarification results did carry
`sessionBudgetExceeded` traces even though the failed-result triage bucket is
zero. That operational count of two also passes the at-most-three target. The
timeout bucket and the internal-timeout count both reported one, while the
generic timeout/cancellation bucket and eval-timeout status remained zero.
PR 59 therefore passes its bucket, cost, latency, classification, and
observability acceptance criteria without raising `maximumSchemaToolCalls`.

## PR 60 canonical-version watch ✅ [completed 2026-07-15]

The production alias now has an independent default-branch watch before a
canonical rollover reaches users. A daily 08:23 UTC schedule and manual
dispatch build `WidenEval`, read the requested and expected IDs directly from
`OpenRouterCatalog.productionProfile`, and query OpenRouter's public
single-model catalog endpoint without an API key or completion request. The
lookup bypasses Widen's catalog cache, stale fallback, and local URL cache and
requests upstream revalidation; provider edge caching can still briefly delay
visibility, so rollover reports are reconfirmed before changing the pin.

The watch accepts only an exact requested-model identity plus a validated
`author/model` canonical ID. It exits `0` when current, `2` only for a
confirmed canonical mismatch, and `1` for missing/unexpected identities,
invalid canonical values, HTTP/transport/decoding failures, or other
operational errors. Confirmed drift creates one deduplicated open issue using
a stable marker and then fails the workflow. Operational failures suppress
provider-controlled output, create no drift issue, and fail visibly. The
workflow is default-branch-only, serializes runs, disables persisted checkout
credentials, and grants only `contents: read` plus `issues: write`.

Deterministic tests cover current/drift decisions, invalid identity shapes,
all operational classes, a pre-populated local catalog cache, the no-auth/no-
body request contract, scheduling and permissions, issue creation and
deduplication, and both terminal workflow failures. The five focused suites
pass 205 tests, `make project` is stable, `make test` passes 1,117 tests in 49
suites, and `make eval-build` passes. A live metadata-only check confirmed
`openai/gpt-5.5-20260423` remains current, with no paid OpenRouter request.

`docs/release.md` now contains the matching rollover procedure: reconfirm the
network observation, obtain explicit spend authorization, update only the
expected canonical pin and deterministic fixtures before eval preflight, gate
the requested alias without `ALLOW_MODEL_OVERRIDE`, apply the retained
non-regression criteria conjunctively, preserve every routing/validation
layer, and track smoke plus resumable full-gate spend against one branch-wide
authorization. Passing rollover non-regression restores only the existing
beta path; the separate 90% semantic production-ready gate remains unchanged.

## PR 62 PR 55 hardening cleanups ✅ [completed 2026-07-16]

The fixed OpenRouter private-routing preferences are now expressed as a
caseless enum with static functionality, with the matching user-facing privacy
claim colocated beside the enforced provider configuration. Settings catalog
refresh computes one result and completes in one `MainActor` block, including
an explicit cancellation status, and its force-refreshing connectivity test no
longer performs a redundant catalog invalidation and disk write. Connectivity
canonical tests share a run helper, while tool-chat canonical tests use the
existing fixtures extended with a model value.

The catalog service now keeps a narrow, actor-local confirmed-canonical-
mismatch memo for cache-served generation preflight. It is keyed by an API-key
fingerprint plus requested and expected model identities and tied to the
observed catalog snapshot. The same snapshot fails closed without another
invalidate/refetch cycle; TTL expiry or explicit invalidation permits one new
verification. A network-fresh mismatch still fails immediately with no second
fetch. The memo is not serialized, successful verification clears it, and no
raw credential is retained.

Generation preflight's duplicate calls are a bounded two-pass loop. Release-
gate violations compute the production pin instead of storing it, reporting
uses the redactor directly, and the resumable-eval model selection uses
explicit nested Make `ifeq` branches. Deterministic tests cover memoization,
cache-served recovery, TTL expiry, network-fresh failure, refresh cancellation,
canonical connectivity/tool-chat fixtures, computed release pins, redaction,
and every default/override resume-model combination.

The seven focused suites pass 225 tests with zero skipped or failed. The full
run completes 1,124 tests in 49 suites (1,082 passed, 42 skipped, zero failed).
`make project` produces no generated diff, `make eval-build` succeeds, and
diff hygiene checks pass. No paid OpenRouter request was made. The six-call
schema-tool budget and all private-routing, model-identity, validation,
parsing, review, phrase-freeze, timeout/interception, canonical-watch,
privacy, and credential boundaries remain intact.

---

# Recommended implementation order for one coding agent

When only one agent is working:

```text
1. PR 1 — Eval harness
2. PR 2 — Headless pipeline
3. PR 3 — Seeded result grading
4. PR 4 — OpenRouter reliability
5. PR 5 — Schema index
6. PR 6 — Schema tools
7. PR 7 — Cloud agent
8. PR 8 — PostgreSQL verification
9. PR 9 ✅ — Optional data inspection
10. PR 11 ✅ — Experimental local path
11. PR 12 ✅ — Platform/default-backend decision
12. PR 13 ✅ — Release-gate triage and schema-tool agent fixes
13. PR 14 ✅ — Resumable, budget-aware release-gate evals
14. PR 15 ✅ — Release-gate baseline and triage docs
15. PR 16 ✅ — Schema-tool over-clarification policy
16. PR 52 ✅ — Diagnostics-only schema-tool policy infrastructure
17. PR 53 ✅ — Intent coverage review fixes and heuristic scope freeze
18. PR 54 ✅ — Stable schema-tool query planning and SQL shape
19. PR 55 ✅ — Fixed OpenRouter SQL profile and private routing
20. PR 10 ⏸️ — Embedding experiment           [deferred 2026-06-26 — revisit only if real app/eval evidence shows retrieval is the bottleneck]
```

Follow-up work after PR 55 (PR 56 and onward) is planned in
`docs/next-dev-steps.md`.

Current follow-up decision:

```text
PR 59 ✅ — implementation and funded acceptance measurement complete
PR 56 ✅ — retry complete, negative, bypass reverted
PR 60 ✅ — canonical-version watch and rollover runbook complete
PR 62 ✅ — PR 55 hardening cleanup complete
PR 58 ⏳ — two funded attempts negative; await a genuinely narrower design
PR 57 ⏳ — conditional on a future bypass gate passing every criterion
```

The key discipline is to run the same 20 cases after every PR and reject changes that merely move failures from one stage to another.

[1]: https://github.com/promptfoo/promptfoo "GitHub - promptfoo/promptfoo: Test your prompts, agents, and RAGs. Red teaming/pentesting/vulnerability scanning for AI. Compare performance of GPT, Claude, Gemini, DeepSeek, and more. Simple declarative configs with command line and CI/CD integration.  Used by OpenAI and Anthropic. · GitHub"
