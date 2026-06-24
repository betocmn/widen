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
make eval-cloud MODEL=openai/gpt-5.5
make eval-all MODEL=openai/gpt-5.5
make eval-case CASE=preseason.top-wins-defined BACKEND=local
make eval-db-local
make eval-db-cloud MODEL=openai/gpt-5.5
make eval-db-case CASE=preseason.top-wins-defined BACKEND=local
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

The provisioning user creates and drops databases only. Semantic execution uses
a unique restricted login role per fixture database with CONNECT, schema USAGE,
and SELECT grants only; CREATE, TEMP, SUPERUSER, CREATEDB, CREATEROLE, and write
privileges are not granted. Each golden/candidate comparison opens a fresh
restricted connection, begins `REPEATABLE READ READ ONLY`, sets UTC timezone,
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
