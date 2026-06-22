# Text-to-SQL Eval Baseline

## Run

| Field | Value |
| --- | --- |
| Suite | text-to-sql-v1 v1 |
| Commit | b05dbf1e7f6a2f27a78fba3cd2f3f16c20f3f974 |
| Started | 2026-06-22T12:20:46Z |
| Finished | 2026-06-22T12:22:33Z |
| Backend | local |
| Model | - |
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
| Passed | 3 |
| Pass rate | 15.0% |
| Backend available | 20 |
| Transport success | 20 |
| Structured response parsed | 20 |
| Decision matches | 13 |
| Safety valid | 11 |
| Schema valid | 2 |
| Forbidden binding violations | 1 |
| Avg required-table coverage | 83.3% |
| Avg required-column coverage | 82.4% |
| Total model calls | 20 |
| Avg prompt size | 1715 |
| Max prompt size | 3564 |
| Token usage | unavailable |
| Estimated cloud cost | unavailable |

## Latency

| Metric | Milliseconds |
| --- | ---: |
| Min | 3257 |
| Average | 5346.9 |
| P50 | 4977 |
| P95 | 7402 |
| Max | 8515 |

## Status Counts

| Status | Count |
| --- | ---: |
| passed | 3 |
| semanticReviewRequired | 0 |
| wrongDecision | 7 |
| invalidSQL | 0 |
| wrongSchemaObjects | 10 |
| transportFailure | 0 |
| parseFailure | 0 |
| backendUnavailable | 0 |

## Per Case

| Case | Backend | Repeat | Status | Diagnostics |
| --- | --- | ---: | --- | --- |
| commerce.average-order-value-country | local | 1 | wrongSchemaObjects | missing tables: public.customers; missing columns: public.customers.country, public.customers.id, public.orders.customer_id; missing ops: join; schema: Schema validation failed: column customer_country is not on public.orders. Schema validation failed: column customer_country is not on public.orders. |
| commerce.best-customers | local | 1 | passed | - |
| commerce.customer-paid-revenue | local | 1 | wrongDecision | - |
| commerce.customers-without-orders | local | 1 | wrongSchemaObjects | missing tables: public.orders; missing columns: public.orders.customer_id; missing ops: left-join; schema: Schema validation failed: column customer_id is not on public.customers. |
| commerce.recent-orders | local | 1 | passed | - |
| preseason.active-match-configs | local | 1 | wrongSchemaObjects | missing tables: public.preseason_tool, public.preseason_category; missing columns: public.preseason_tool.id, public.preseason_category.id; missing ops: join; schema: Schema validation failed: column name is not on public.preseason_match_config. |
| preseason.latest-failed-runs | local | 1 | wrongSchemaObjects | schema: Schema validation failed: column createdAt must be quoted as "createdAt" on public.preseason_benchmark_run. |
| preseason.top-wins-ambiguous | local | 1 | wrongDecision | - |
| preseason.top-wins-defined | local | 1 | wrongSchemaObjects | missing tables: public.preseason_tool; missing columns: public.preseason_tool.id; forbidden: public.preseason_match_evaluation.tool_b_id; schema: Schema validation failed: column createdAt must be quoted as "createdAt" on public.preseason_match_evaluation. Schema validation failed: column createdAt is timestamp with time zone and cannot be compared directly to an INTERVAL. Compare it to a date or timestamp expression such as NOW() - INTERVAL '7 days'. |
| preseason.verified-tools | local | 1 | wrongSchemaObjects | missing ops: limit; schema: Schema validation failed: column tool_b_id is not on public.preseason_tool. Schema validation failed: column tool_b_id is not on public.preseason_tool. |
| saas.active-users-by-org | local | 1 | wrongSchemaObjects | missing tables: public.organization, public.app_user; missing columns: public.organization.id, public.organization_membership.user_id, public.app_user.id, public.app_user.last_seen_at; missing ops: join |
| saas.expiring-subscriptions | local | 1 | wrongDecision | - |
| saas.healthy-accounts | local | 1 | wrongDecision | - |
| saas.overallocated-seats | local | 1 | wrongSchemaObjects | missing tables: public.organization_membership; missing columns: public.organization.id, public.organization_membership.organization_id, public.organization_membership.status; missing ops: count, group, join; schema: Schema validation failed: column organization_id is not on public.organization. Schema validation failed: column seats_used is not on public.organization. |
| saas.users-without-membership | local | 1 | wrongSchemaObjects | missing columns: public.organization_membership.user_id; missing ops: left-join, null-filter; schema: Schema validation failed: column app_user_id is not on public.organization_membership. |
| support.average-first-response | local | 1 | wrongSchemaObjects | schema: Schema validation failed: column first_response_at is not an output column of last_30_days; project it from the CTE or do not reference it outside the CTE. Schema validation failed: column created_at is not an output column of last_30_days; project it from the CTE or do not reference it outside the CTE. |
| support.frequent-feedback-cluster | local | 1 | wrongDecision | - |
| support.important-cluster | local | 1 | passed | - |
| support.unclustered-feedback | local | 1 | wrongDecision | - |
| support.unresolved-by-assignee | local | 1 | wrongDecision | - |

Raw prompts and raw model output are intentionally omitted from this summary.
