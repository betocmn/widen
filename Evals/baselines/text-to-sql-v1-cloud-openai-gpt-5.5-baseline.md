# Text-to-SQL Eval Baseline

> Stale baseline: this file predates `production-pipeline-static-shape` eval
> mode and must not be treated as current. Regenerate only with a real
> `WIDEN_EVAL_OPENROUTER_API_KEY`; never replace it with an
> all-`backendUnavailable` run.

**Evaluation scope:** A static-shape pass verifies the decision, SQL safety, schema references, and configured structural expectations. It does not establish result-set or semantic correctness.

## Run

| Field | Value |
| --- | --- |
| Suite | text-to-sql-v1 v1 |
| Evaluation mode | static-shape |
| Commit | 8c6fc129ceb0686ac3ee8c9e966d82bf70ce3a31 |
| Started | 2026-06-23T03:32:31Z |
| Finished | 2026-06-23T03:32:31Z |
| Backend | cloud |
| Model | openai/gpt-5.5 |
| OS | Version 26.5.1 (Build 25F80) |
| Architecture | arm64 |
| Cases | 20 |
| Repeats | 3 |

## Baseline Compatibility Hashes

These deterministic hashes establish baseline compatibility for the suite, scorer, and schema fixtures. The commit that adds a baseline cannot be recorded in that baseline's own committed content.

| Artifact | SHA-256 |
| --- | --- |
| Suite file | 74bb7bc43ad81cdc23e7aedcd7186576ce8daa2e28dae07862e361ee11fd8137 |
| Scorer source (static-shape-v1) | dbd18ee26df8a80a60033681ab52559ff81abb211b61a2478d47bb7b5007724f |

## Schema Fixture Hashes

| Fixture | SHA-256 |
| --- | --- |
| commerce | b437184f76046ed9c933d2711db2e4e74a25fad40278ed937f2eebb196754490 |
| preseason | 3e1258fba6833848bc2517173e6b774d4a40365d27a6c4a2a709a5b393971696 |
| saas | fa8219ec2dc6590c0af82010af752f7cf6988444bcd6616736f42f8b4b47a7f3 |
| support | ef8cfdf76af1c4b9049cc58ce0a3b620d77da18fee05b2e78c43ec4d16ce7f3c |

## Summary

| Metric | Value |
| --- | --- |
| Results | 60 |
| Passed | 0 |
| Static-shape pass rate | 0.0% |
| Backend available | 0/60 |
| Transport success | 0/0 evaluated |
| Structured response parsed | 0/0 evaluated |
| Decision matches | 0/0 |
| Safety valid | 0/0 evaluated |
| Schema valid | 0/0 evaluated |
| Forbidden binding violations | 0 |
| Average required-table coverage | - (0 SQL results evaluated) |
| Average required-column coverage | - (0 SQL results evaluated) |
| Total model calls | - |
| Avg estimated initial prompt characters | - |
| Max estimated initial prompt characters | - |
| Token usage | unavailable |
| Estimated cloud cost | unavailable |

### Latency

| Metric | Milliseconds |
| --- | ---: |
| Min | 0 |
| Average | 0.0 |
| P50 | 0 |
| P95 | 0 |
| Max | 0 |

## Status Counts

| Status | Count |
| --- | ---: |
| passed | 0 |
| semanticReviewRequired | 0 |
| wrongDecision | 0 |
| invalidSQL | 0 |
| wrongSchemaObjects | 0 |
| contextWindowFailure | 0 |
| generationFailure | 0 |
| transportFailure | 0 |
| parseFailure | 0 |
| backendUnavailable | 60 |

## Repeat Stability

| Backend | Stable passes | Cases | Stable pass rate | Flaky cases |
| --- | ---: | ---: | ---: | --- |
| cloud | 0 | 20 | 0.0% | - |

## Per Case Repeat Stability

| Case | Backend | Pass count | Statuses |
| --- | --- | ---: | --- |
| commerce.average-order-value-country | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| commerce.best-customers | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| commerce.customer-paid-revenue | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| commerce.customers-without-orders | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| commerce.recent-orders | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| preseason.active-match-configs | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| preseason.latest-failed-runs | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| preseason.top-wins-ambiguous | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| preseason.top-wins-defined | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| preseason.verified-tools | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| saas.active-users-by-org | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| saas.expiring-subscriptions | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| saas.healthy-accounts | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| saas.overallocated-seats | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| saas.users-without-membership | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| support.average-first-response | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| support.frequent-feedback-cluster | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| support.important-cluster | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| support.unclustered-feedback | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |
| support.unresolved-by-assignee | cloud | 0/3 | backendUnavailable, backendUnavailable, backendUnavailable |

## Per Case

| Case | Backend | Repeat | Status | Diagnostics |
| --- | --- | ---: | --- | --- |
| commerce.average-order-value-country | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.average-order-value-country | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.average-order-value-country | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.best-customers | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.best-customers | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.best-customers | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.customer-paid-revenue | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.customer-paid-revenue | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.customer-paid-revenue | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.customers-without-orders | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.customers-without-orders | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.customers-without-orders | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.recent-orders | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.recent-orders | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| commerce.recent-orders | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.active-match-configs | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.active-match-configs | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.active-match-configs | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.latest-failed-runs | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.latest-failed-runs | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.latest-failed-runs | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.top-wins-ambiguous | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.top-wins-ambiguous | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.top-wins-ambiguous | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.top-wins-defined | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.top-wins-defined | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.top-wins-defined | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.verified-tools | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.verified-tools | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| preseason.verified-tools | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.active-users-by-org | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.active-users-by-org | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.active-users-by-org | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.expiring-subscriptions | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.expiring-subscriptions | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.expiring-subscriptions | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.healthy-accounts | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.healthy-accounts | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.healthy-accounts | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.overallocated-seats | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.overallocated-seats | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.overallocated-seats | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.users-without-membership | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.users-without-membership | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| saas.users-without-membership | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.average-first-response | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.average-first-response | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.average-first-response | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.frequent-feedback-cluster | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.frequent-feedback-cluster | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.frequent-feedback-cluster | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.important-cluster | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.important-cluster | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.important-cluster | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.unclustered-feedback | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.unclustered-feedback | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.unclustered-feedback | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.unresolved-by-assignee | cloud | 1 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.unresolved-by-assignee | cloud | 2 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |
| support.unresolved-by-assignee | cloud | 3 | backendUnavailable | WIDEN_EVAL_OPENROUTER_API_KEY is not set. |

Estimated initial prompts and raw model output are intentionally omitted from this summary.
The estimated initial prompt character metrics are pre-call estimates from the eval runner, not the exact model prompt after discovery, truncation, or retry behavior.
