# Text-to-SQL Eval Baseline

**Evaluation scope:** The eval invokes the shared production text-to-SQL pipeline through local validation and validation-only repair, then applies a static-shape score to the final decision. It does not establish result-set or semantic correctness.

## Run

| Field | Value |
| --- | --- |
| Suite | text-to-sql-v1 v1 |
| Evaluation mode | production-pipeline-static-shape |
| Run ID | 38B0DC69-1962-4F67-B5B0-9F1B29C3EEAE |
| Parent run ID | - |
| Resumed from | - |
| Commit | 125a06d725bae028158e6c94b15787e80c9a8b4c |
| Started | 2026-07-25T03:33:01Z |
| Finished | 2026-07-25T03:38:43Z |
| Backend | local |
| Cloud agent | - |
| Schema agent clarification correction | - |
| Schema agent intent coverage | - |
| Schema agent plan consistency | - |
| Model | - |
| Expected canonical model | - |
| OS | Version 26.5.1 (Build 25F80) |
| Architecture | arm64 |
| Cases | 20 |
| Repeats | 3 |
| Case timeout | 120.0 seconds |
| Complete | Yes |
| Expected results | 60 |
| Completed results | 60 |
| Missing results | 0 |
| Skipped by budget | 0 |
| Provider budget unavailable | 0 |
| Budget stop | - |

## Baseline Compatibility Hashes

These deterministic hashes establish baseline compatibility for the suite, pipeline/scorer sources, and schema fixtures. The commit that adds a baseline cannot be recorded in that baseline's own committed content.

| Artifact | SHA-256 |
| --- | --- |
| Suite file | 69c9324b505f62ee4e23a1c5c306120dc9b28108e75e95974ae78ef7fc25c96e |
| Pipeline/scorer sources (production-pipeline-static-shape-v1) | 97609ae722e30923d76cd1c9374dd4d3a06d70e3d11f3fdfaa9b49cce20baf35 |

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
| Passed | 12 |
| Static-shape pass rate | 20.0% |
| Semantic end-to-end passed | - |
| Semantic end-to-end pass rate | - |
| SQL semantic pass rate | - |
| Clarification decision pass rate | - |
| Overall end-to-end pass rate | - |
| Semantic environment available | - |
| Semantic execution attempted | - |
| Semantic result equivalent | - |
| Golden execution succeeded | - |
| Candidate execution succeeded | - |
| Backend available | 60/60 |
| Transport success | 60/60 evaluated |
| Structured response parsed | 30/60 evaluated |
| Decision matches | 15/30 |
| Safety valid | 9/9 evaluated |
| Schema valid | 9/9 evaluated |
| PostgreSQL verification attempted pass rate | - |
| Forbidden binding violations | 0 |
| Average required-table coverage | 100.0% (9 SQL results evaluated) |
| Average required-column coverage | 100.0% (9 SQL results evaluated) |
| Total model calls | 84 |
| Schema-tool calls | - |
| Inspection-tool calls | - |
| Agent logical model turns | - |
| Agent HTTP attempts | - |
| Tool-budget failures | - |
| Repeated repair fingerprint/no-progress repairs | 0 |
| Avg estimated initial prompt characters | 2013 |
| Max estimated initial prompt characters | 5243 |
| Token usage | - |
| Estimated cloud cost | - |

### Latency

| Metric | Milliseconds |
| --- | ---: |
| Min | 3192 |
| Average | 5677.1 |
| P50 | 4994 |
| P95 | 8066 |
| Max | 10877 |

## Status Counts

| Status | Count |
| --- | ---: |
| passed | 12 |
| semanticReviewRequired | 0 |
| semanticEnvironmentUnavailable | 0 |
| fixtureInvalid | 0 |
| wrongDecision | 15 |
| invalidSQL | 0 |
| wrongSchemaObjects | 3 |
| contextWindowFailure | 0 |
| generationFailure | 27 |
| evalTimeout | 0 |
| transportFailure | 0 |
| paymentRequired | 0 |
| providerLimit | 0 |
| skippedBudgetLimit | 0 |
| parseFailure | 3 |
| backendUnavailable | 0 |

## PostgreSQL Verification Status Counts

| Status | Count |
| --- | ---: |
| notAvailable | 9 |
| skippedNoConnection | 0 |
| skippedNonRead | 0 |
| skippedStaticValidationFailed | 27 |
| passed | 0 |
| failed | 0 |

## Repeat Stability

| Backend | Stable passes | Cases | Stable pass rate | Flaky cases |
| --- | ---: | ---: | ---: | --- |
| local | 4 | 20 | 20.0% | - |

## Per Case Repeat Stability

| Case | Backend | Pass count | Statuses |
| --- | --- | ---: | --- |
| commerce.average-order-value-country | local | 0/3 | generationFailure, generationFailure, generationFailure |
| commerce.best-customers | local | 3/3 | passed, passed, passed |
| commerce.customer-paid-revenue | local | 0/3 | wrongDecision, wrongDecision, wrongDecision |
| commerce.customers-without-orders | local | 0/3 | generationFailure, generationFailure, generationFailure |
| commerce.recent-orders | local | 3/3 | passed, passed, passed |
| preseason.active-match-configs | local | 0/3 | generationFailure, generationFailure, generationFailure |
| preseason.latest-failed-runs | local | 3/3 | passed, passed, passed |
| preseason.top-wins-ambiguous | local | 0/3 | generationFailure, generationFailure, generationFailure |
| preseason.top-wins-defined | local | 0/3 | parseFailure, parseFailure, parseFailure |
| preseason.verified-tools | local | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| saas.active-users-by-org | local | 0/3 | generationFailure, generationFailure, generationFailure |
| saas.expiring-subscriptions | local | 0/3 | wrongDecision, wrongDecision, wrongDecision |
| saas.healthy-accounts | local | 0/3 | generationFailure, generationFailure, generationFailure |
| saas.overallocated-seats | local | 0/3 | generationFailure, generationFailure, generationFailure |
| saas.users-without-membership | local | 0/3 | generationFailure, generationFailure, generationFailure |
| support.average-first-response | local | 0/3 | generationFailure, generationFailure, generationFailure |
| support.frequent-feedback-cluster | local | 0/3 | wrongDecision, wrongDecision, wrongDecision |
| support.important-cluster | local | 3/3 | passed, passed, passed |
| support.unclustered-feedback | local | 0/3 | wrongDecision, wrongDecision, wrongDecision |
| support.unresolved-by-assignee | local | 0/3 | wrongDecision, wrongDecision, wrongDecision |

## Per Case

| Case | Backend | Repeat | Static Status | PostgreSQL Verification | Semantic Status | Semantic Result | Diagnostics |
| --- | --- | ---: | --- | --- | --- | --- | --- |
| commerce.average-order-value-country | local | 1 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| commerce.average-order-value-country | local | 2 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| commerce.average-order-value-country | local | 3 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| commerce.best-customers | local | 1 | passed | - | - | - | - |
| commerce.best-customers | local | 2 | passed | - | - | - | - |
| commerce.best-customers | local | 3 | passed | - | - | - | - |
| commerce.customer-paid-revenue | local | 1 | wrongDecision | - | - | - | - |
| commerce.customer-paid-revenue | local | 2 | wrongDecision | - | - | - | - |
| commerce.customer-paid-revenue | local | 3 | wrongDecision | - | - | - | - |
| commerce.customers-without-orders | local | 1 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| commerce.customers-without-orders | local | 2 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| commerce.customers-without-orders | local | 3 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| commerce.recent-orders | local | 1 | passed | notAvailable | - | - | - |
| commerce.recent-orders | local | 2 | passed | notAvailable | - | - | - |
| commerce.recent-orders | local | 3 | passed | notAvailable | - | - | - |
| preseason.active-match-configs | local | 1 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| preseason.active-match-configs | local | 2 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| preseason.active-match-configs | local | 3 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| preseason.latest-failed-runs | local | 1 | passed | notAvailable | - | - | - |
| preseason.latest-failed-runs | local | 2 | passed | notAvailable | - | - | - |
| preseason.latest-failed-runs | local | 3 | passed | notAvailable | - | - | - |
| preseason.top-wins-ambiguous | local | 1 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| preseason.top-wins-ambiguous | local | 2 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| preseason.top-wins-ambiguous | local | 3 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| preseason.top-wins-defined | local | 1 | parseFailure | - | - | - | SQL generation failed: Failed to deserialize a Generable type from model output |
| preseason.top-wins-defined | local | 2 | parseFailure | - | - | - | SQL generation failed: Failed to deserialize a Generable type from model output |
| preseason.top-wins-defined | local | 3 | parseFailure | - | - | - | SQL generation failed: Failed to deserialize a Generable type from model output |
| preseason.verified-tools | local | 1 | wrongSchemaObjects | notAvailable | - | - | missing ops: limit |
| preseason.verified-tools | local | 2 | wrongSchemaObjects | notAvailable | - | - | missing ops: limit |
| preseason.verified-tools | local | 3 | wrongSchemaObjects | notAvailable | - | - | missing ops: limit |
| saas.active-users-by-org | local | 1 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.active-users-by-org | local | 2 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.active-users-by-org | local | 3 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.expiring-subscriptions | local | 1 | wrongDecision | - | - | - | - |
| saas.expiring-subscriptions | local | 2 | wrongDecision | - | - | - | - |
| saas.expiring-subscriptions | local | 3 | wrongDecision | - | - | - | - |
| saas.healthy-accounts | local | 1 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.healthy-accounts | local | 2 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.healthy-accounts | local | 3 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.overallocated-seats | local | 1 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.overallocated-seats | local | 2 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.overallocated-seats | local | 3 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.users-without-membership | local | 1 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.users-without-membership | local | 2 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| saas.users-without-membership | local | 3 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| support.average-first-response | local | 1 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| support.average-first-response | local | 2 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| support.average-first-response | local | 3 | generationFailure | skippedStaticValidationFailed | - | - | SQL generation failed: On-device experimental mode has already used this request's two model-call budget. Try a narrower question or switch to Cloud. |
| support.frequent-feedback-cluster | local | 1 | wrongDecision | - | - | - | - |
| support.frequent-feedback-cluster | local | 2 | wrongDecision | - | - | - | - |
| support.frequent-feedback-cluster | local | 3 | wrongDecision | - | - | - | - |
| support.important-cluster | local | 1 | passed | - | - | - | - |
| support.important-cluster | local | 2 | passed | - | - | - | - |
| support.important-cluster | local | 3 | passed | - | - | - | - |
| support.unclustered-feedback | local | 1 | wrongDecision | - | - | - | - |
| support.unclustered-feedback | local | 2 | wrongDecision | - | - | - | - |
| support.unclustered-feedback | local | 3 | wrongDecision | - | - | - | - |
| support.unresolved-by-assignee | local | 1 | wrongDecision | - | - | - | - |
| support.unresolved-by-assignee | local | 2 | wrongDecision | - | - | - | - |
| support.unresolved-by-assignee | local | 3 | wrongDecision | - | - | - | - |

Estimated initial prompts and raw model output are intentionally omitted from this summary.
The estimated initial prompt character metrics are pre-call estimates from the eval runner, not the exact model prompt after discovery, truncation, or retry behavior.
