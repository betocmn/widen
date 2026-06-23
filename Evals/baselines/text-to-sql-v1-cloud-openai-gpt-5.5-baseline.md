# Text-to-SQL Eval Baseline

## Run

| Field | Value |
| --- | --- |
| Suite | text-to-sql-v1 v1 |
| Commit | 629b3b2aa12a451312ec9bcbbcf9fa419e440ab0 |
| Started | 2026-06-23T00:41:20Z |
| Finished | 2026-06-23T00:43:28Z |
| Backend | cloud |
| Model | openai/gpt-5.5 |
| OS | Version 26.5.1 (Build 25F80) |
| Architecture | arm64 |
| Cases | 20 |
| Repeats | 1 |

## Schema Fixtures

| Fixture | SHA-256 |
| --- | --- |
| commerce | b437184f76046ed9c933d2711db2e4e74a25fad40278ed937f2eebb196754490 |
| preseason | 1f82f79e9754d949f7808ae440044da225e3928cd242c82df61ce5e8f45cf6ee |
| saas | fa8219ec2dc6590c0af82010af752f7cf6988444bcd6616736f42f8b4b47a7f3 |
| support | ef8cfdf76af1c4b9049cc58ce0a3b620d77da18fee05b2e78c43ec4d16ce7f3c |

## Summary

| Metric | Value |
| --- | ---: |
| Results | 20 |
| Passed | 9 |
| Pass rate | 45.0% |
| Backend available | 20 |
| Transport success | 20 |
| Structured response parsed | 20 |
| Decision matches | 9 |
| Safety valid | 5 |
| Schema valid | 5 |
| Forbidden binding violations | 0 |
| Avg required-table coverage | 45.0% |
| Avg required-column coverage | 45.0% |
| Total model calls | 20 |
| Avg prompt size | 1715 |
| Max prompt size | 3564 |
| Token usage | unavailable |
| Estimated cloud cost | unavailable |

## Latency

| Metric | Milliseconds |
| --- | ---: |
| Min | 2334 |
| Average | 6420.0 |
| P50 | 6291 |
| P95 | 9068 |
| Max | 10466 |

## Status Counts

| Status | Count |
| --- | ---: |
| passed | 9 |
| semanticReviewRequired | 0 |
| wrongDecision | 11 |
| invalidSQL | 0 |
| wrongSchemaObjects | 0 |
| transportFailure | 0 |
| parseFailure | 0 |
| backendUnavailable | 0 |

## Per Case

| Case | Backend | Repeat | Status | Diagnostics |
| --- | --- | ---: | --- | --- |
| commerce.average-order-value-country | cloud | 1 | wrongDecision | - |
| commerce.best-customers | cloud | 1 | passed | - |
| commerce.customer-paid-revenue | cloud | 1 | wrongDecision | - |
| commerce.customers-without-orders | cloud | 1 | wrongDecision | - |
| commerce.recent-orders | cloud | 1 | passed | - |
| preseason.active-match-configs | cloud | 1 | passed | - |
| preseason.latest-failed-runs | cloud | 1 | passed | - |
| preseason.top-wins-ambiguous | cloud | 1 | passed | - |
| preseason.top-wins-defined | cloud | 1 | wrongDecision | - |
| preseason.verified-tools | cloud | 1 | passed | - |
| saas.active-users-by-org | cloud | 1 | passed | - |
| saas.expiring-subscriptions | cloud | 1 | wrongDecision | - |
| saas.healthy-accounts | cloud | 1 | passed | - |
| saas.overallocated-seats | cloud | 1 | wrongDecision | - |
| saas.users-without-membership | cloud | 1 | wrongDecision | - |
| support.average-first-response | cloud | 1 | wrongDecision | - |
| support.frequent-feedback-cluster | cloud | 1 | wrongDecision | - |
| support.important-cluster | cloud | 1 | passed | - |
| support.unclustered-feedback | cloud | 1 | wrongDecision | - |
| support.unresolved-by-assignee | cloud | 1 | wrongDecision | - |

Raw prompts and raw model output are intentionally omitted from this summary.
