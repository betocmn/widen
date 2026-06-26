# Widen Text-to-SQL Rebuild Plan

## Background / Motivation

Widen’s current text-to-SQL pipeline is unreliable across both local and cloud models. It sends a preselected schema excerpt to an LLM in one shot, then relies on increasingly complex validation and repair logic. In practice, relevant relationships can be present in the schema while the model still selects the wrong tables or columns, and repair attempts often repeat the same invalid SQL.

This refactor changes the process from prompt-by-prompt debugging to measurable system development: establish a fixed evaluation suite, improve schema retrieval, let models inspect schema through bounded tools, verify generated SQL with PostgreSQL, and compare every change against the same baseline.

The initial evaluation tool will be a small, native Swift command-line target named `WidenEval`, built inside this repository and using the same generators and validators as the app. It requires no paid or external evaluation framework, is easy to run locally against both Apple Foundation Models and OpenRouter, and keeps Widen’s production pipeline as the source of truth. An optional open-source reporting layer such as Promptfoo may be added later, but it will not own execution or scoring.

As part of this rebuild, you may find stuff you might want to clean/delete as we don't want a hardcoded custom natural-language parser, grounder, SQL compiler, and conformance engine. That is creating a second database engine full of edge cases so we want to avoid that.

## Tool choice

Use a **native Swift command-line eval runner** as the source of truth.

This is simpler than introducing an external eval framework because it can call the exact same `FoundationModelsSQLGenerator`, `OpenRouterSQLGenerator`, schema code, and validators used by Widen. The current project already requires Xcode 26 and macOS 26 for Foundation Models, so the runner can share that build environment.

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
          └── PR 10 — Embedding retrieval experiment       [parallel]

PR 2 + PR 4 + PR 6
  └── PR 7 ✅ — Cloud tool-using SQL agent                  [done 2026-06-25]

PR 2 + PR 3
  └── PR 8 — PostgreSQL verification and one repair        [parallel with PR 7]

PR 6 + PR 8
  └── PR 9 — Optional data-inspection tools

PR 2 + PR 5 + PR 6
  └── PR 11 — Constrained local-model path                 [parallel with PR 7–10]

PR 7 + PR 8 + PR 11 + eval evidence
  └── PR 12 — Backend defaults, older macOS, release gate
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
* Added the persisted `experimentalCloudSchemaAgentEnabled` preference under OpenRouter Advanced / Experimental settings. Default remains false.
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

# PR 8 — Verify SQL with PostgreSQL and allow one repair — Done

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

# PR 9 — Add optional metadata and data-inspection tools

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

---

# PR 10 — Experiment with local schema embeddings

Suggested title:

```text
experiment: add hybrid embedding schema retrieval
```

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

# PR 11 — Add a constrained experimental local path

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

---

# PR 12 — Backend defaults, older macOS, and release gate

Suggested title:

```text
refactor: make text-to-sql cloud-first with optional on-device mode
```

Only start this after eval evidence from PR 7 and PR 11.

## Implementation

* Isolate `FoundationModels` imports behind availability and conditional compilation.
* Lower the deployment target to the oldest macOS version supported by the rest of Widen’s dependencies.
* Cloud becomes the recommended/default text-to-SQL backend.
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
9. PR 10 — Embedding experiment
10. PR 9 — Optional data inspection
11. PR 11 — Experimental local path
12. PR 12 — Platform/default-backend decision
```

The key discipline is to run the same 20 cases after every PR and reject changes that merely move failures from one stage to another.

[1]: https://github.com/promptfoo/promptfoo "GitHub - promptfoo/promptfoo: Test your prompts, agents, and RAGs. Red teaming/pentesting/vulnerability scanning for AI. Compare performance of GPT, Claude, Gemini, DeepSeek, and more. Simple declarative configs with command line and CI/CD integration.  Used by OpenAI and Anthropic. · GitHub"
