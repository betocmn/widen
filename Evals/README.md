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
make eval-provider-probe   # probe Particle-1's API (at most 8 tiny completions)
make eval-smoke            # tiny transport and structured-response smoke suite
make eval-cloud            # text-to-SQL suite, static-shape scoring
make eval-case CASE=preseason.top-wins-defined
make eval-cloud-agent CLOUD_AGENT=legacy
make eval-cloud-agent-case CASE=preseason.top-wins-defined
make eval-db-cloud         # plus seeded Postgres semantic grading
make eval-db-cloud-agent CASES="<case-id> <case-id>"
make eval-db-cloud-agent-case CASE=preseason.top-wins-defined
make eval-db-case CASE=preseason.top-wins-defined
make eval-grounding-probe GROUNDING_JUDGE=on   # held-out grounding probe
make eval-release          # release gate (see Release Gate)
make eval-release-triage   # release gate plus redacted failure triage
make eval-release-resume RESUME=.eval-results/<timestamp>
make eval-retrieval
make eval-retrieval RETRIEVER=index
make eval-retrieval-case CASE=preseason.top-wins-defined RETRIEVER=both
make eval-schema-tools     # deterministic; no model or database calls
make eval-inspection-tools # deterministic; no model calls
```

Every target except `eval-retrieval*`, `eval-schema-tools` and
`eval-inspection-tools` sends paid requests. `MODEL` defaults to `particle-1`,
and `CLOUD_AGENT` to `tools`. `MODEL=openai/gpt-5.5` runs an OpenRouter
comparison on the non-gate targets; the release-gate targets refuse it (see
Release Gate). The `eval-smoke`, `eval-cloud*`, `eval-case`, `eval-db-*` and
`eval-grounding-probe` targets also pass `CASE`, `CASES`, `REPEAT`, `CASE_TIMEOUT_SECONDS`, `OUTPUT`,
`FAIL_UNDER`, `REASONING_EFFORT`, `GROUNDING_JUDGE` and `MAX_CLOUD_COST_USD`
through to WidenEval. The focused `eval-release-preseason`,
`eval-release-overclarification` and `eval-release-sql-shape` targets rerun
subsets of the gate suite with triage output in the run directory only.
`make eval-provider-probe` always probes Particle-1 and writes `probe.json`
and `probe.md` under `.eval-results/provider-probe-<timestamp>/`. A leftover
`BACKEND=local` fails: the on-device eval backend was removed.

The provider follows `--model`, and each run reads only that provider's key:

```sh
WIDEN_EVAL_PARTICLE_API_KEY    # --model particle-1 (the default)
WIDEN_EVAL_OPENROUTER_API_KEY  # --model <vendor/model>, e.g. openai/gpt-5.5
```

Any other model ID fails before a request is sent. A key is sent only to its
own provider's host, and a Particle key is never sent to OpenRouter or the
reverse. For local development, the make targets source a gitignored
`.env.eval.local` file that can export these variables. Never print, paste,
or commit that file, and do not commit API keys, prompts, or raw model output.
Without the key, every case records `backendUnavailable` with
`<variable> is not set.` and nothing is sent.

## CLI

`WidenEval --help` is the source of truth. Its options:

```text
--backend cloud
--cloud-agent legacy|tools (default: tools)
--schema-agent-clarification-correction disabled|diagnostics|experimental
--schema-agent-intent-coverage disabled|diagnostics|reject-only|experimental
--schema-agent-plan-consistency disabled|diagnostics|experimental
--model <model-id> (default: particle-1; a vendor/model ID runs through OpenRouter)
--reasoning-effort none|minimal|low|medium|high|xhigh|max|ultra (eval-only; particle-1 only)
--suite <path>
--case <case-id>
--repeat <n>
--case-timeout-seconds <n> (default: 1200)
--output <directory>
--record-prompts
--fail-under <percentage>
--release-gate-version <version>
--triage-release <run.json path>
--write-release-triage
--release-triage-version <version>
--allow-model-override
--resume-run <path-to-run-directory-or-run.json>
--resume-missing
--resume-failed
--resume-case-status <status[,status...]>
--max-cloud-cost-usd <decimal>
--max-http-attempts <int>
--max-completed-results <int>
--stop-before-provider-limit
--semantic-db
--retriever legacy|index|both
--schema-tools
--inspection-tools
--provider-probe
--help
```

`--model` picks the provider: `particle-1` runs Particle-1, and a
`vendor/model` ID runs an OpenRouter comparison. There is no provider flag.
`--backend` accepts only `cloud`; `local` and `both` fail because the
on-device backend was removed. `--cloud-agent` defaults to `tools`, the
schema-tool agent the app uses; `legacy` runs the one-shot generator. The
`--schema-agent-*` flags switch experimental agent policies and default to
diagnostics only.

`--reasoning-effort` is eval-only: it overrides the effort Particle-1 agent
turns and one-shot SQL send for the run, and is rejected for OpenRouter
models. A release-gate or triage run needs `--allow-model-override` to use
it, and then keeps its summaries in the run directory: only the production
effort writes the committed `docs/evals/` files. The run manifest records the
provider, its endpoint host, the effort sent, and the agent's call budgets.

`--max-cloud-cost-usd`, `--max-http-attempts` and `--max-completed-results`
cap a run. They are checked before each result, so a run can overshoot the
cost cap by up to one result; once a cap is reached, the remaining results are
recorded as skipped and the partial artifacts are written.
`--stop-before-provider-limit` stops the run after a result fails because the
account is out of credits or the key reached a usage limit. See Cost
Accounting for how the cost cap is enforced.

`--resume-run` continues an earlier run in a new run directory, reusing its
completed results. `--resume-missing` runs results that are missing or did
not complete, `--resume-failed` also reruns failed ones, and
`--resume-case-status` reruns results with the listed statuses. Resume
refuses a run whose suite, fixtures, scorer sources, provider, model, agent
settings, or reasoning effort differ. `--triage-release` rewrites the triage
report from an existing `run.json` without sending requests.

`--provider-probe` sends at most eight small Particle-1 completions after one
model-list request, using only `WIDEN_EVAL_PARTICLE_API_KEY`. It checks the
request shapes the agent depends on (a plain completion, a tool turn, four
second-turn message shapes, a named `tool_choice`, and `json_object`), writes
`probe.json` and `probe.md`, never writes the key, and exits nonzero when a
critical check fails.

Each case has a default 1,200-second timeout, covering schema discovery,
generation, and validation repair. That is longer than the agent's wall clock
multiplied by every generation and repair one case can run. When the timeout
fires, WidenEval cancels the pipeline task and records `evalTimeout` rather
than a transport failure, then continues with the remaining cases.

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

## Cost Accounting

Particle reports token usage but no `usage.cost`, so WidenEval estimates each
request's cost from its usage at Particle's peak list prices: $0.25 per 1M
uncached input tokens, $0.03 per 1M cached input tokens, and $1.00 per 1M
output tokens, which include reasoning tokens. Off-peak and flex discounts
can't be observed per response, so the estimate is an upper bound for the
requests that report usage. A request that returns no usage, such as one cut
off by a timeout, adds nothing to it, so a run's total can be lower than what
Particle bills. Reports label the total "token estimate at peak pricing; upper
bound". OpenRouter comparison runs use the `usage.cost` OpenRouter reports,
labelled "provider-reported".

`--max-cloud-cost-usd` sums these per-result costs. A profile with neither a
reported cost nor token prices fails before any request; Particle-1 has
prices and OpenRouter reports cost, so neither does. If a cost cap is set and
a result used tokens but recorded no cost, the cap can no longer be enforced:
WidenEval stops, records the remaining results as skipped, writes the partial
artifacts, and exits nonzero. Summaries report prompt, cached-prompt (with the
cache hit rate), completion and reasoning tokens, the cost, and its source.

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
predate the shared production pipeline and must be treated as stale.
Regenerate cloud baselines only with a real `WIDEN_EVAL_PARTICLE_API_KEY`,
from a run of the shipped configuration; do not replace a cloud baseline with
an all-`backendUnavailable` run.
`Evals/baselines/text-to-sql-v1-cloud-particle-1-baseline.md` is the current
cloud baseline: the summary of the 0.2.0 gate run of the shipped
configuration (Particle-1, budget layer, critic off, grounding judge on).
`Evals/baselines/text-to-sql-v1-cloud-openai-gpt-5.5-baseline.md` is a stale
record of the previous OpenRouter GPT-5.5 profile, kept as history; that
profile's gate evidence is `docs/evals/0.1.0.md` and
`docs/evals/0.1.0-triage.md`. Smoke results from before 0.2.0 ran the one-shot
generator, so they are not comparable with `make eval-smoke`, which runs the
schema-tool agent.

Semantic reports contain row counts, comparison status, end-to-end status,
SQL semantic pass rate, clarification pass rate, semantic environment
availability, static/semantic cross-tabs, stable result digests, and concise
mismatch categories. They do not include raw result rows. Detailed synthetic
diffs, if added later, must stay under `.eval-results/`.

When the grounding postprocessor replaces generated SQL with a clarification,
a semantic run also compares that withheld SQL with the golden SQL for cases
that expect SQL, after the same safety, read-only and schema guards. Results
record only `groundingWithheldSQL`, `withheldSQLSemanticStatus` and
`withheldSQLSemanticPassed`, never the withheld SQL, and the comparison never
changes a result's status. Summaries report the withheld counts as ungated
rows.

`--schema-agent-grounding-judge on|off` (`GROUNDING_JUDGE=on|off` on the
non-gate targets) turns the schema agent's grounding judge on or off; without
it the eval follows the app's default. The mode is recorded in the manifest's
agent configuration, a resume inherits it, and a manifest without it reads as
off. With the judge on, each result also records its paired judge-off arm from
the same run: where the judgment first changed what the grounding
postprocessor returned (`groundingJudgeDivergence`, `released` or `reAimed`),
the run would otherwise have ended on the lexical clarification, so the off
arm fails a case that expects SQL and otherwise scores that clarification's
quality. Results without a divergence are their own off arm. The
`groundingJudgeOffArm*` fields hold the paired values, never the clarification
or any SQL, and summaries report the judge's counts and both arms as ungated
rows.

`make eval-grounding-probe` runs `Evals/suites/grounding-probe-v1.json` through
the schema-tool agent with seeded Postgres semantic grading. The suite is a
held-out probe for the grounding judge: new questions over the existing
fixtures, half of them ambiguous where the fixture schema defines nothing, and
half answerable but with words the lexical grounding pass flags. It is not a
gate and writes no release docs.

## Release Gate

`make eval-release` is the release gate and runs the pinned production model,
`particle-1`. Engineering comparisons must opt in with
`make eval-release MODEL=<model> ALLOW_MODEL_OVERRIDE=1`; direct CLI runs that
publish release-gate or triage docs equally require `--allow-model-override`
for a non-pinned `--model` or a non-default recorded reasoning effort
(including offline `--triage-release` re-runs). Even with the override, such a
run never writes the committed `docs/evals/` files — its gate summary and
triage stay in the run directory.
Neither override changes the app's production profile. Committed docs also
require the run to expect the returned model `particle-ai/particle-1`, to use
the production reasoning effort, and to have at least one evaluated cloud
result.

The target runs `Evals/suites/text-to-sql-v1.json` with `--cloud-agent tools`,
`--semantic-db`, and `--repeat 3`, because the Particle-1 schema-tool agent is
the path every connected session uses. Of the pass-through variables, the gate
targets take only `MAX_CLOUD_COST_USD`; `CASE`, `CASES`, `REPEAT`,
`REASONING_EFFORT` and `GROUNDING_JUDGE` never change a gate run. The normal
`.eval-results/<timestamp>/` artifacts are written, then
`docs/evals/<RELEASE_VERSION>.md` is written with the gate result.
`RELEASE_VERSION` defaults to the app's `CFBundleShortVersionString`, so pass
it explicitly when gating a version that is not in `Info.plist` yet.
`make eval-release-triage` also writes
`docs/evals/<RELEASE_VERSION>-triage.md`.
`make eval-release-resume RESUME=<run>` completes an interrupted gate run and
writes both files from the resumed run, so the committed report and triage
always describe the same run.

The eval builds the agent with no database inspection policy and no schema
fingerprint, so the gate never offers data-inspection tools or runs the
stale-schema check. It also runs neither execution repair nor session titles;
see [what the gate does not measure](../docs/evals/how-we-gate.md#what-the-gate-does-not-measure).

The gate exits nonzero unless all thresholds pass: 60 total results, at least
90% end-to-end semantic pass rate, 100% evaluated safety validity, 100%
evaluated schema validity, 100% clarification decision accuracy, at least 95%
transport reliability, and zero repeated repair fingerprint/no-progress repair
failures.

## Schema Retrieval Evals

`Evals/suites/schema-retrieval-v1.json` evaluates deterministic schema
retrieval only. It does not call a model, SQL generation, repair, validation,
or PostgreSQL.

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
generated SQL, and the schema-index feature does not send indexed content
over the network.
