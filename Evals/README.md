# Text-to-SQL Evals

`WidenEval` is the native Swift evaluation runner for Widen's text-to-SQL
pipeline. It invokes the same production pipeline as the app from an
already-prepared generation request through local validation and
validation-only repair, then writes per-run artifacts under `.eval-results/`.

**Evaluation scope:** The production pipeline produces the final SQL,
clarification, or typed failure. A static-shape pass then verifies the decision,
SQL safety, schema references, and configured structural expectations. Seeded
Postgres DB evals additionally execute safe, schema-valid SQL decisions against
synthetic throwaway databases and compare result bags. Static and semantic
outcomes are reported separately.

Static eval commands do not execute generated SQL or compare result sets. DB
eval commands provision synthetic PostgreSQL fixtures, run only eligible final
SQL decisions, and keep clarification or failed decisions out of SQL execution.
Committed baselines record deterministic hashes for the suite file,
pipeline/scorer sources, schema fixtures, setup fixtures, and semantic
comparison metadata to establish baseline compatibility.

## Commands

```sh
make eval-local
make eval-cloud
make eval-all
make eval-case CASE=preseason.top-wins-defined BACKEND=local
make eval-db-local
make eval-db-cloud
make eval-release
make eval-db-case CASE=preseason.top-wins-defined BACKEND=local
make eval-retrieval
make eval-retrieval RETRIEVER=index
make eval-retrieval-case CASE=preseason.top-wins-defined RETRIEVER=both
```

Cloud mode reads the OpenRouter key only from:

```sh
WIDEN_EVAL_OPENROUTER_API_KEY
```

For local development, a gitignored `.env.eval.local` file can export that
variable. Do not commit API keys, prompts, or raw model output.

## CLI

```text
--backend local|cloud|both
--model <openrouter-model-id>
--suite <path>
--case <case-id>
--repeat <n>
--case-timeout-seconds <n>
--output <directory>
--record-prompts
--fail-under <percentage>
--release-gate-version <version>
--max-cloud-cost-usd <decimal>
--semantic-db
--retriever legacy|index|both
```

Each case has a default 120-second timeout, covering schema discovery,
generation, and validation repair. When the timeout fires, WidenEval cancels
the pipeline task and records `evalTimeout` rather than a transport failure,
then continues with the remaining cases. Foundation Models cancellation is
cooperative; if the framework does not return after task cancellation, the
cancelled model work can continue in process until the framework returns.
WidenEval does not use detached model tasks and cannot force Foundation Models
to stop earlier than the framework allows.

Prompt recording defaults to off. When it is off, the eval process also
disables Widen's append-only generation log for that process. Reported
`estimatedInitialPromptCharacters` and optional `estimatedInitialPrompt`
values are eval-runner estimates, not the exact model prompt after discovery,
truncation, or retry behavior.

Seeded DB evals use a local PostgreSQL server only for synthetic fixtures. By
default they connect to `localhost:5432` as the current macOS user and use the
`postgres` maintenance database to create one throwaway database per schema
fixture from PostgreSQL's empty `template0`. Override with
`WIDEN_EVAL_DB_HOST`, `WIDEN_EVAL_DB_PORT`, `WIDEN_EVAL_DB_USER`,
`WIDEN_EVAL_DB_PASSWORD`,
`WIDEN_EVAL_DB_MAINTENANCE_DB`, and `WIDEN_EVAL_DB_SSLMODE`.

The provisioning user creates and drops databases only; no cluster roles are
created, so `CREATEDB` is sufficient for local seeded evals. Semantic execution
reuses that user against each throwaway fixture database after revoking public
CREATE/TEMP privileges. Each golden/candidate comparison opens a fresh
connection, begins `REPEATABLE READ READ ONLY`, sets UTC timezone,
deterministic date/interval styles, statement/lock/idle timeouts, and a
`pg_catalog` plus fixture-schema search path, executes golden SQL before
candidate SQL, rolls back, and never rewrites either query. Strict row, cell,
and cell-size caps fail the case and close the comparison connection. A missing
local PostgreSQL server is reported as `semanticEnvironmentUnavailable`, not as
a model backend or transport failure.

## Artifacts

Each run writes:

```text
.eval-results/<timestamp>/
  run.json
  cases.jsonl
  summary.md
```

`.eval-results/` is ignored by git. Committed baseline summaries must be
sanitized and should not include estimated prompts, raw model responses,
credentials, or private schema data.

Baselines whose `Evaluation mode` is not `production-pipeline-static-shape`
predate the shared production pipeline and must be treated as stale. Regenerate
local baselines after pipeline/scorer changes. Regenerate cloud baselines only
with a real `WIDEN_EVAL_OPENROUTER_API_KEY`; do not replace a cloud baseline
with an all-`backendUnavailable` run.

Semantic reports contain row counts, comparison status, end-to-end status,
SQL semantic pass rate, clarification pass rate, semantic environment
availability, static/semantic cross-tabs, stable result digests, and concise
mismatch categories. They do not include raw result rows. Detailed synthetic
diffs, if added later, must stay under `.eval-results/`.

## Release Gate

`make eval-release` is the PR 12 release gate and defaults to the fixed
production alias `openai/gpt-5.5`. An explicit `MODEL=<model>` or CLI `--model`
remains available for engineering experiments without changing the app's
production profile. The target runs
`Evals/suites/text-to-sql-v1.json` with `--backend cloud`, `--cloud-agent tools`,
`--semantic-db`, and `--repeat 3`. This intentionally tests the OpenRouter
schema-tool agent because that is the default connected-session product path for
fresh installs. The normal `.eval-results/<timestamp>/` artifacts are written,
then `docs/evals/<CFBundleShortVersionString>.md` is written with the gate
result.

The gate exits nonzero unless all thresholds pass: 60 total results, at least
90% end-to-end semantic pass rate, 100% evaluated safety validity, 100%
evaluated schema validity, 100% clarification decision accuracy, at least 95%
transport reliability, and zero repeated repair fingerprint/no-progress repair
failures.

## Schema Retrieval Evals

`Evals/suites/schema-retrieval-v1.json` evaluates deterministic schema
retrieval only. It does not call Foundation Models, OpenRouter, SQL generation,
repair, validation, or PostgreSQL.

`--retriever legacy|index|both` compares the existing `SchemaRelevanceRanker`
and the local schema index against the same query inputs. Each case declares
its expected primary table, required tables, optional acceptable alternatives,
required join-path endpoints, optional required matched columns, and optional
forbidden top-K distractors. Retrieval expectations are explicit in the suite;
they are not derived from golden SQL during the run.

Retrieval reports include required-table Recall@3/5/8,
all-required-tables-present@3/5/8, primary-table reciprocal rank, mean
reciprocal rank, required join-path recall, wrong-schema collision count,
no-result or low-signal count, index build duration, serialized index size,
query latency p50/p95, and score explanations for misses.

The local index is persisted under
`~/Library/Application Support/Widen/schema-indexes/`. It contains schema
metadata only: exact table and column names, comments, types, constraints,
enum/check values, and grouped FK edges. It does not contain database row data,
credentials, database context, user questions, prompts, model output, or
generated SQL, and PR 5 does not send indexed content over the network.
