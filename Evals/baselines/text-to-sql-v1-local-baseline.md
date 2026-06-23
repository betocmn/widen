# Text-to-SQL Eval Baseline

**Evaluation scope:** A static-shape pass verifies the decision, SQL safety, schema references, and configured structural expectations. It does not establish result-set or semantic correctness.

## Run

| Field | Value |
| --- | --- |
| Suite | text-to-sql-v1 v1 |
| Evaluation mode | static-shape |
| Commit | 8c6fc129ceb0686ac3ee8c9e966d82bf70ce3a31 |
| Started | 2026-06-23T03:26:45Z |
| Finished | 2026-06-23T03:32:17Z |
| Backend | local |
| Model | - |
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
| Passed | 9 |
| Static-shape pass rate | 15.0% |
| Backend available | 60/60 |
| Transport success | 60/60 evaluated |
| Structured response parsed | 60/60 evaluated |
| Decision matches | 48/60 |
| Safety valid | 48/48 evaluated |
| Schema valid | 24/48 evaluated |
| Forbidden binding violations | 0 |
| Average required-table coverage | 72.9% (48 SQL results evaluated) |
| Average required-column coverage | 67.1% (48 SQL results evaluated) |
| Total model calls | 60 |
| Avg estimated initial prompt characters | 2001 |
| Max estimated initial prompt characters | 5164 |
| Token usage | unavailable |
| Estimated cloud cost | unavailable |

### Latency

| Metric | Milliseconds |
| --- | ---: |
| Min | 3226 |
| Average | 5531.2 |
| P50 | 5036 |
| P95 | 7798 |
| Max | 8328 |

## Status Counts

| Status | Count |
| --- | ---: |
| passed | 9 |
| semanticReviewRequired | 0 |
| wrongDecision | 12 |
| invalidSQL | 0 |
| wrongSchemaObjects | 39 |
| contextWindowFailure | 0 |
| generationFailure | 0 |
| transportFailure | 0 |
| parseFailure | 0 |
| backendUnavailable | 0 |

## Repeat Stability

| Backend | Stable passes | Cases | Stable pass rate | Flaky cases |
| --- | ---: | ---: | ---: | --- |
| local | 3 | 20 | 15.0% | - |

## Per Case Repeat Stability

| Case | Backend | Pass count | Statuses |
| --- | --- | ---: | --- |
| commerce.average-order-value-country | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| commerce.best-customers | local | 0/3 | wrongDecision, wrongDecision, wrongDecision |
| commerce.customer-paid-revenue | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| commerce.customers-without-orders | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| commerce.recent-orders | local | 3/3 | passed, passed, passed |
| preseason.active-match-configs | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| preseason.latest-failed-runs | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| preseason.top-wins-ambiguous | local | 0/3 | wrongDecision, wrongDecision, wrongDecision |
| preseason.top-wins-defined | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| preseason.verified-tools | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| saas.active-users-by-org | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| saas.expiring-subscriptions | local | 3/3 | passed, passed, passed |
| saas.healthy-accounts | local | 0/3 | wrongDecision, wrongDecision, wrongDecision |
| saas.overallocated-seats | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| saas.users-without-membership | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| support.average-first-response | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| support.frequent-feedback-cluster | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| support.important-cluster | local | 0/3 | wrongDecision, wrongDecision, wrongDecision |
| support.unclustered-feedback | local | 3/3 | passed, passed, passed |
| support.unresolved-by-assignee | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |

## Per Case

| Case | Backend | Repeat | Status | Diagnostics |
| --- | --- | ---: | --- | --- |
| commerce.average-order-value-country | local | 1 | wrongSchemaObjects | missing tables: public.customers; missing columns: public.customers.country, public.customers.id, public.orders.customer_id; missing ops: join; schema: Schema validation failed: column customer_country is not on public.orders. Schema validation failed: column customer_country is not on public.orders. |
| commerce.average-order-value-country | local | 2 | wrongSchemaObjects | missing tables: public.customers; missing columns: public.customers.country, public.customers.id, public.orders.customer_id; missing ops: join; schema: Schema validation failed: column customer_country is not on public.orders. Schema validation failed: column customer_country is not on public.orders. |
| commerce.average-order-value-country | local | 3 | wrongSchemaObjects | missing tables: public.customers; missing columns: public.customers.country, public.customers.id, public.orders.customer_id; missing ops: join; schema: Schema validation failed: column customer_country is not on public.orders. Schema validation failed: column customer_country is not on public.orders. |
| commerce.best-customers | local | 1 | wrongDecision | - |
| commerce.best-customers | local | 2 | wrongDecision | - |
| commerce.best-customers | local | 3 | wrongDecision | - |
| commerce.customer-paid-revenue | local | 1 | wrongSchemaObjects | missing tables: public.customers; missing columns: public.customers.id; missing ops: join |
| commerce.customer-paid-revenue | local | 2 | wrongSchemaObjects | missing tables: public.customers; missing columns: public.customers.id; missing ops: join |
| commerce.customer-paid-revenue | local | 3 | wrongSchemaObjects | missing tables: public.customers; missing columns: public.customers.id; missing ops: join |
| commerce.customers-without-orders | local | 1 | wrongSchemaObjects | missing tables: public.orders; missing columns: public.orders.customer_id; missing ops: left-join; schema: Schema validation failed: column customer_id is not on public.customers. |
| commerce.customers-without-orders | local | 2 | wrongSchemaObjects | missing tables: public.orders; missing columns: public.orders.customer_id; missing ops: left-join; schema: Schema validation failed: column customer_id is not on public.customers. |
| commerce.customers-without-orders | local | 3 | wrongSchemaObjects | missing tables: public.orders; missing columns: public.orders.customer_id; missing ops: left-join; schema: Schema validation failed: column customer_id is not on public.customers. |
| commerce.recent-orders | local | 1 | passed | - |
| commerce.recent-orders | local | 2 | passed | - |
| commerce.recent-orders | local | 3 | passed | - |
| preseason.active-match-configs | local | 1 | wrongSchemaObjects | missing tables: public.preseason_tool, public.preseason_category; missing columns: public.preseason_match_config.tool_a_id, public.preseason_match_config.tool_b_id, public.preseason_match_config.category_id, public.preseason_match_config.is_active, public.preseason_tool.id, public.preseason_category.id; missing ops: limit; schema: Schema validation failed: column name is not on public.preseason_match_config. Schema validation failed: column slug is not on public.preseason_match_config. Schema validation failed: column is_active is not on public.preseason_match_batch. Schema validation failed: column createdAt must be quoted as "createdAt" on public.preseason_match_batch. Schema validation failed: column is_active is not on public.preseason_match_batch. Schema validation failed: column name is not on public.preseason_match_config. Schema validation failed: column slug is not on public.preseason_match_config. |
| preseason.active-match-configs | local | 2 | wrongSchemaObjects | missing tables: public.preseason_tool, public.preseason_category; missing columns: public.preseason_match_config.tool_a_id, public.preseason_match_config.tool_b_id, public.preseason_match_config.category_id, public.preseason_match_config.is_active, public.preseason_tool.id, public.preseason_category.id; missing ops: limit; schema: Schema validation failed: column name is not on public.preseason_match_config. Schema validation failed: column slug is not on public.preseason_match_config. Schema validation failed: column is_active is not on public.preseason_match_batch. Schema validation failed: column createdAt must be quoted as "createdAt" on public.preseason_match_batch. Schema validation failed: column is_active is not on public.preseason_match_batch. Schema validation failed: column name is not on public.preseason_match_config. Schema validation failed: column slug is not on public.preseason_match_config. |
| preseason.active-match-configs | local | 3 | wrongSchemaObjects | missing tables: public.preseason_tool, public.preseason_category; missing columns: public.preseason_match_config.tool_a_id, public.preseason_match_config.tool_b_id, public.preseason_match_config.category_id, public.preseason_match_config.is_active, public.preseason_tool.id, public.preseason_category.id; missing ops: limit; schema: Schema validation failed: column name is not on public.preseason_match_config. Schema validation failed: column slug is not on public.preseason_match_config. Schema validation failed: column is_active is not on public.preseason_match_batch. Schema validation failed: column createdAt must be quoted as "createdAt" on public.preseason_match_batch. Schema validation failed: column is_active is not on public.preseason_match_batch. Schema validation failed: column name is not on public.preseason_match_config. Schema validation failed: column slug is not on public.preseason_match_config. |
| preseason.latest-failed-runs | local | 1 | wrongSchemaObjects | schema: Schema validation failed: column createdAt must be quoted as "createdAt" on public.preseason_benchmark_run. |
| preseason.latest-failed-runs | local | 2 | wrongSchemaObjects | schema: Schema validation failed: column createdAt must be quoted as "createdAt" on public.preseason_benchmark_run. |
| preseason.latest-failed-runs | local | 3 | wrongSchemaObjects | schema: Schema validation failed: column createdAt must be quoted as "createdAt" on public.preseason_benchmark_run. |
| preseason.top-wins-ambiguous | local | 1 | wrongDecision | - |
| preseason.top-wins-ambiguous | local | 2 | wrongDecision | - |
| preseason.top-wins-ambiguous | local | 3 | wrongDecision | - |
| preseason.top-wins-defined | local | 1 | wrongSchemaObjects | missing tables: public.preseason_tool; missing columns: public.preseason_match_evaluation.createdAt, public.preseason_tool.id; missing ops: count, relative-time-filter; schema: Schema validation failed: column tool_a_id is not on public.preseason_match_evaluation. Schema validation failed: column tool_a_id is not on public.preseason_match_evaluation. |
| preseason.top-wins-defined | local | 2 | wrongSchemaObjects | missing tables: public.preseason_tool; missing columns: public.preseason_match_evaluation.createdAt, public.preseason_tool.id; missing ops: count, relative-time-filter; schema: Schema validation failed: column tool_a_id is not on public.preseason_match_evaluation. Schema validation failed: column tool_a_id is not on public.preseason_match_evaluation. |
| preseason.top-wins-defined | local | 3 | wrongSchemaObjects | missing tables: public.preseason_tool; missing columns: public.preseason_match_evaluation.createdAt, public.preseason_tool.id; missing ops: count, relative-time-filter; schema: Schema validation failed: column tool_a_id is not on public.preseason_match_evaluation. Schema validation failed: column tool_a_id is not on public.preseason_match_evaluation. |
| preseason.verified-tools | local | 1 | wrongSchemaObjects | missing ops: limit |
| preseason.verified-tools | local | 2 | wrongSchemaObjects | missing ops: limit |
| preseason.verified-tools | local | 3 | wrongSchemaObjects | missing ops: limit |
| saas.active-users-by-org | local | 1 | wrongSchemaObjects | missing tables: public.organization, public.app_user; missing columns: public.organization.id, public.organization_membership.user_id, public.app_user.id, public.app_user.last_seen_at; missing ops: join |
| saas.active-users-by-org | local | 2 | wrongSchemaObjects | missing tables: public.organization, public.app_user; missing columns: public.organization.id, public.organization_membership.user_id, public.app_user.id, public.app_user.last_seen_at; missing ops: join |
| saas.active-users-by-org | local | 3 | wrongSchemaObjects | missing tables: public.organization, public.app_user; missing columns: public.organization.id, public.organization_membership.user_id, public.app_user.id, public.app_user.last_seen_at; missing ops: join |
| saas.expiring-subscriptions | local | 1 | passed | - |
| saas.expiring-subscriptions | local | 2 | passed | - |
| saas.expiring-subscriptions | local | 3 | passed | - |
| saas.healthy-accounts | local | 1 | wrongDecision | - |
| saas.healthy-accounts | local | 2 | wrongDecision | - |
| saas.healthy-accounts | local | 3 | wrongDecision | - |
| saas.overallocated-seats | local | 1 | wrongSchemaObjects | missing tables: public.organization_membership; missing columns: public.organization.id, public.organization_membership.organization_id, public.organization_membership.status; missing ops: count, group, join; schema: Schema validation failed: column organization_id is not on public.organization. Schema validation failed: column seats_used is not on public.organization. |
| saas.overallocated-seats | local | 2 | wrongSchemaObjects | missing tables: public.organization_membership; missing columns: public.organization.id, public.organization_membership.organization_id, public.organization_membership.status; missing ops: count, group, join; schema: Schema validation failed: column organization_id is not on public.organization. Schema validation failed: column seats_used is not on public.organization. |
| saas.overallocated-seats | local | 3 | wrongSchemaObjects | missing tables: public.organization_membership; missing columns: public.organization.id, public.organization_membership.organization_id, public.organization_membership.status; missing ops: count, group, join; schema: Schema validation failed: column organization_id is not on public.organization. Schema validation failed: column seats_used is not on public.organization. |
| saas.users-without-membership | local | 1 | wrongSchemaObjects | missing columns: public.organization_membership.user_id; schema: Schema validation failed: column app_user_id is not on public.organization_membership. |
| saas.users-without-membership | local | 2 | wrongSchemaObjects | missing columns: public.organization_membership.user_id; schema: Schema validation failed: column app_user_id is not on public.organization_membership. |
| saas.users-without-membership | local | 3 | wrongSchemaObjects | missing columns: public.organization_membership.user_id; schema: Schema validation failed: column app_user_id is not on public.organization_membership. |
| support.average-first-response | local | 1 | wrongSchemaObjects | schema: Schema validation failed: column first_response_at is not an output column of last_30_days; project it from the CTE or do not reference it outside the CTE. Schema validation failed: column created_at is not an output column of last_30_days; project it from the CTE or do not reference it outside the CTE. |
| support.average-first-response | local | 2 | wrongSchemaObjects | schema: Schema validation failed: column first_response_at is not an output column of last_30_days; project it from the CTE or do not reference it outside the CTE. Schema validation failed: column created_at is not an output column of last_30_days; project it from the CTE or do not reference it outside the CTE. |
| support.average-first-response | local | 3 | wrongSchemaObjects | schema: Schema validation failed: column first_response_at is not an output column of last_30_days; project it from the CTE or do not reference it outside the CTE. Schema validation failed: column created_at is not an output column of last_30_days; project it from the CTE or do not reference it outside the CTE. |
| support.frequent-feedback-cluster | local | 1 | wrongSchemaObjects | missing tables: public.feedback_cluster; missing columns: public.feedback_cluster.id; missing ops: join |
| support.frequent-feedback-cluster | local | 2 | wrongSchemaObjects | missing tables: public.feedback_cluster; missing columns: public.feedback_cluster.id; missing ops: join |
| support.frequent-feedback-cluster | local | 3 | wrongSchemaObjects | missing tables: public.feedback_cluster; missing columns: public.feedback_cluster.id; missing ops: join |
| support.important-cluster | local | 1 | wrongDecision | - |
| support.important-cluster | local | 2 | wrongDecision | - |
| support.important-cluster | local | 3 | wrongDecision | - |
| support.unclustered-feedback | local | 1 | passed | - |
| support.unclustered-feedback | local | 2 | passed | - |
| support.unclustered-feedback | local | 3 | passed | - |
| support.unresolved-by-assignee | local | 1 | wrongSchemaObjects | missing ops: count |
| support.unresolved-by-assignee | local | 2 | wrongSchemaObjects | missing ops: count |
| support.unresolved-by-assignee | local | 3 | wrongSchemaObjects | missing ops: count |

Estimated initial prompts and raw model output are intentionally omitted from this summary.
The estimated initial prompt character metrics are pre-call estimates from the eval runner, not the exact model prompt after discovery, truncation, or retry behavior.
