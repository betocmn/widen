# Text-to-SQL Eval Baseline

**Evaluation scope:** The eval invokes the shared production text-to-SQL pipeline through local validation and PostgreSQL verification, keeps the static-shape score, then independently executes eligible final SQL decisions against seeded PostgreSQL fixtures for semantic result-set grading.

## Run

| Field | Value |
| --- | --- |
| Suite | text-to-sql-v1 v1 |
| Evaluation mode | production-pipeline-static-shape-plus-seeded-postgres-semantic |
| Run ID | 223385F4-C939-4BD0-88A2-97AC0CAC3133 |
| Parent run ID | - |
| Resumed from | - |
| Commit | 98e17783866f4d00a4ee567947e31e4daa1a21ad |
| Started | 2026-11-02T03:22:05Z |
| Finished | 2026-11-02T03:34:26Z |
| Backend | cloud |
| Cloud agent | tools |
| Schema agent clarification correction | diagnosticsOnly |
| Schema agent intent coverage | diagnosticsOnly |
| Schema agent plan consistency | diagnosticsOnly |
| Schema agent critic | disabled |
| Schema agent grounding judge | enabled |
| Provider | particle |
| Endpoint host | api.particle.ai |
| Model | particle-1 |
| Expected returned model | particle-ai/particle-1 |
| Reasoning effort | high |
| OS | Version 27.0.1 (Build 26A434) |
| Architecture | arm64 |
| Cases | 20 |
| Repeats | 3 |
| Case timeout | 1200.0 seconds |
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
| Pipeline/scorer sources (production-pipeline-static-shape-v1) | 22cc65bbbfb6dc571a802faf46219f956a12ff5bfb7cb0bca041592558231c41 |

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
| Passed | 43 |
| Static-shape pass rate | 71.7% |
| Semantic end-to-end passed | 27 |
| Semantic end-to-end pass rate | 45.0% |
| SQL semantic pass rate | 18/37 |
| Clarification decision pass rate | 11/12 |
| Overall end-to-end pass rate | 27/60 (45.0%) |
| Semantic environment available | 37/37 |
| Semantic execution attempted | 37/60 |
| Semantic result equivalent | 18/37 |
| Golden execution succeeded | 37/37 |
| Candidate execution succeeded | 37/37 |
| Backend available | 60/60 |
| Transport success | 60/60 evaluated |
| Structured response parsed | 59/60 evaluated |
| Decision matches | 48/59 |
| Safety valid | 37/37 evaluated |
| Schema valid | 37/37 evaluated |
| PostgreSQL verification attempted pass rate | 37/37 |
| Forbidden binding violations | 0 |
| Average required-table coverage | 100.0% (37 SQL results evaluated) |
| Average required-column coverage | 100.0% (37 SQL results evaluated) |
| Total model calls | 274 |
| Schema-tool calls | 250 |
| Inspection-tool calls | 0 |
| Agent logical model turns | 233 |
| Agent HTTP attempts | 274 |
| Tool-budget failures | 1 |
| Forced final answers attempted | 3 |
| Forced final answers succeeded | 2 of 3 (66.7%) |
| Forced final answer reasons | toolBudget 3 |
| Forced final answers timed out | 0 |
| Forced requests rejected by the provider | 0 |
| Critic eligible SQL terminals | - |
| Critic reviewed results | - |
| Critic calls | - |
| Critic failed-open calls | - |
| Critic verdicts | - |
| Critic final outcomes | - |
| Critic revised results | - |
| Critic revisions | - |
| Critic releases of pre-revision SQL | - |
| SQL withheld by grounding | 18 |
| Withheld SQL where SQL was expected | 10 of 18 (55.6%) |
| Withheld SQL semantic passes | 3 of 10 (30.0%) |
| Withheld SQL semantic statuses | passed 3, resultMismatch 7 |
| Grounding judge eligible results | 40 |
| Grounding judge judgeable results | 40 |
| Grounding judge judged results | 40 of 40 (100.0%) |
| Grounding judge calls | 40 |
| Grounding judge failed results | 0 of 40 (0.0%) |
| Grounding judge skips | skippedNoFlags 15 |
| Grounding judge labels | context_defined 3, needs_definition 17, query_operation 25, question_defined 1, schema_match 6 |
| Grounding judge verified terms | 35 of 52 (67.3%) |
| Grounding judge postprocessor outcomes | lexical:mustClarify 8, lexical:unreleasableTerm 10, released 22 |
| Grounding judge vetoed releases | 1 |
| Grounding judge released results | 22 |
| Grounding judge re-aimed results | 0 |
| Grounding judge release rule violations | anchoredWindow 0, digestMismatch 0, literalRejected 0, mustClarify 0, undescribedTables 0, write 0 |
| Grounding judge releases on expected-clarify results | 0 |
| Grounding judge released expected-SQL semantic passes | 7 of 22 (31.8%) |
| Paired end-to-end passes (judge on, off) | on 27, off 20 of 60 |
| Paired clarification decision passes (judge on, off) | on 11, off 11 of 12 |
| Paired decision matches (judge on, off) | on 48, off 26 of 59 |
| Paired expected-SQL clarifications (judge on, off) | on 11, off 33 of 48 |
| Repeated repair fingerprint/no-progress repairs | 0 |
| Avg estimated initial prompt characters | 210 |
| Max estimated initial prompt characters | 417 |
| Token usage | 923715 |
| Estimated cloud cost | $0.190291 (token estimate at peak pricing; upper bound) |
| Estimated cloud cost source | estimatedPeakList |

### Latency

| Metric | Milliseconds |
| --- | ---: |
| Min | 3052 |
| Average | 12106.0 |
| P50 | 10616 |
| P95 | 24948 |
| Max | 31699 |

## Status Counts

| Status | Count |
| --- | ---: |
| passed | 43 |
| semanticReviewRequired | 0 |
| semanticEnvironmentUnavailable | 0 |
| fixtureInvalid | 0 |
| wrongDecision | 11 |
| invalidSQL | 0 |
| wrongSchemaObjects | 5 |
| contextWindowFailure | 0 |
| generationFailure | 1 |
| evalTimeout | 0 |
| transportFailure | 0 |
| paymentRequired | 0 |
| providerLimit | 0 |
| skippedBudgetLimit | 0 |
| parseFailure | 0 |
| backendUnavailable | 0 |

## PostgreSQL Verification Status Counts

| Status | Count |
| --- | ---: |
| notAvailable | 0 |
| skippedNoConnection | 0 |
| skippedNonRead | 0 |
| skippedStaticValidationFailed | 0 |
| passed | 37 |
| failed | 0 |

## Provider Transport (Particle)

| Metric | Value |
| --- | --- |
| HTTP success | 60/60 |
| Structured parse success | 59/60 |
| Provider budget unavailable | 0 |
| Typed provider failures | 0 |
| Retry total | 0 |
| Retry average | 0.00 |
| Schema-tool calls | 250 |
| Inspection-tool calls | - |
| Agent logical model turns | 233 |
| Agent HTTP attempts | 274 |
| Prompt tokens | 849790 |
| Cached prompt tokens | 436736 (51.4% hit rate) |
| Completion tokens | 73925 |
| Reasoning tokens | 28435 |
| Token usage | 923715 |
| Estimated cloud cost | $0.190291 (token estimate at peak pricing; upper bound) |
| Cost source | estimatedPeakList |

### Output Modes

| Mode | Count |
| --- | ---: |
| promptOnlyJSON | 60 |

### Agent Selection

| Selection | Count |
| --- | ---: |
| tools | 60 |

### Agent Terminal Outcomes

| Outcome | Count |
| --- | ---: |
| clarify | 3 |
| clarify_fallback | 1 |
| sql | 55 |

### Provider Failures

| Category | Count |
| --- | ---: |
| - | 0 |

### Returned Models

| Model | Count |
| --- | ---: |
| particle-ai/particle-1 | 60 |

## Semantic Status Counts

| Semantic Status | Count |
| --- | ---: |
| passed | 18 |
| resultMismatch | 19 |
| candidateExecutionFailure | 0 |
| goldenFixtureFailure | 0 |
| resultLimitExceeded | 0 |
| semanticEnvironmentUnavailable | 0 |
| fixtureInvalid | 0 |
| notApplicable | 23 |

## Static/Semantic Cross-Tab

| Category | Count |
| --- | ---: |
| static pass / semantic pass | 16 |
| static pass / semantic fail | 16 |
| static fail / semantic pass | 2 |
| static fail / semantic fail | 3 |

## Repeat Stability

| Backend | Stable passes | Cases | Stable pass rate | Flaky cases |
| --- | ---: | ---: | ---: | --- |
| cloud | 12 | 20 | 60.0% | preseason.top-wins-defined, saas.expiring-subscriptions, saas.healthy-accounts, support.frequent-feedback-cluster |

## Per Case Repeat Stability

| Case | Backend | Pass count | Statuses |
| --- | --- | ---: | --- |
| commerce.average-order-value-country | cloud | 3/3 | passed, passed, passed |
| commerce.best-customers | cloud | 3/3 | passed, passed, passed |
| commerce.customer-paid-revenue | cloud | 0/3 | wrongDecision, wrongDecision, wrongDecision |
| commerce.customers-without-orders | cloud | 3/3 | passed, passed, passed |
| commerce.recent-orders | cloud | 3/3 | passed, passed, passed |
| preseason.active-match-configs | cloud | 3/3 | passed, passed, passed |
| preseason.latest-failed-runs | cloud | 3/3 | passed, passed, passed |
| preseason.top-wins-ambiguous | cloud | 3/3 | passed, passed, passed |
| preseason.top-wins-defined | cloud | 1/3 | wrongSchemaObjects, passed, wrongSchemaObjects |
| preseason.verified-tools | cloud | 3/3 | passed, passed, passed |
| saas.active-users-by-org | cloud | 0/3 | wrongSchemaObjects, wrongSchemaObjects, wrongSchemaObjects |
| saas.expiring-subscriptions | cloud | 2/3 | passed, passed, wrongDecision |
| saas.healthy-accounts | cloud | 2/3 | passed, generationFailure, passed |
| saas.overallocated-seats | cloud | 3/3 | passed, passed, passed |
| saas.users-without-membership | cloud | 3/3 | passed, passed, passed |
| support.average-first-response | cloud | 0/3 | wrongDecision, wrongDecision, wrongDecision |
| support.frequent-feedback-cluster | cloud | 2/3 | passed, passed, wrongDecision |
| support.important-cluster | cloud | 3/3 | passed, passed, passed |
| support.unclustered-feedback | cloud | 3/3 | passed, passed, passed |
| support.unresolved-by-assignee | cloud | 0/3 | wrongDecision, wrongDecision, wrongDecision |

## Per Case

| Case | Backend | Repeat | Static Status | PostgreSQL Verification | Semantic Status | Semantic Result | Diagnostics |
| --- | --- | ---: | --- | --- | --- | --- | --- |
| commerce.average-order-value-country | cloud | 1 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 74; mismatch: missingCandidateColumn; golden digest: 3923f9e1c654; candidate digest: fb309f3a2979 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| commerce.average-order-value-country | cloud | 2 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 74; mismatch: missingCandidateColumn; golden digest: 3923f9e1c654; candidate digest: d3feb21642a8 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| commerce.average-order-value-country | cloud | 3 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 70; mismatch: missingCandidateColumn; golden digest: 3923f9e1c654; candidate digest: abdc5ded48e2 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| commerce.best-customers | cloud | 1 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| commerce.best-customers | cloud | 2 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| commerce.best-customers | cloud | 3 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| commerce.customer-paid-revenue | cloud | 1 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: unordered | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| commerce.customer-paid-revenue | cloud | 2 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: unordered | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| commerce.customer-paid-revenue | cloud | 3 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: unordered | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| commerce.customers-without-orders | cloud | 1 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 1; candidate rows: 1; semantic ms: 47; mismatch: missingCandidateColumn; golden digest: a647360edbfb; candidate digest: d74b84ab6d9f | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit |
| commerce.customers-without-orders | cloud | 2 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 1; candidate rows: 1; semantic ms: 70; mismatch: missingCandidateColumn; golden digest: a647360edbfb; candidate digest: d74b84ab6d9f | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit |
| commerce.customers-without-orders | cloud | 3 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 1; candidate rows: 1; semantic ms: 67; mismatch: missingCandidateColumn; golden digest: a647360edbfb; candidate digest: d74b84ab6d9f | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit |
| commerce.recent-orders | cloud | 1 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 9; candidate rows: 9; semantic ms: 75; golden digest: 4ccf49d7ddf4; candidate digest: 4ccf49d7ddf4 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, projection, ordering, limit |
| commerce.recent-orders | cloud | 2 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 9; candidate rows: 9; semantic ms: 77; golden digest: 4ccf49d7ddf4; candidate digest: 4ccf49d7ddf4 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, projection, ordering, limit |
| commerce.recent-orders | cloud | 3 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 9; candidate rows: 9; semantic ms: 71; golden digest: 4ccf49d7ddf4; candidate digest: 4ccf49d7ddf4 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, projection, ordering, limit |
| preseason.active-match-configs | cloud | 1 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 85; mismatch: unexpectedExtraColumns; golden digest: a612c7b202f1; candidate digest: 34d19c82001b | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit |
| preseason.active-match-configs | cloud | 2 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 57; mismatch: unexpectedExtraColumns; golden digest: a612c7b202f1; candidate digest: 3572bf03b919 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit |
| preseason.active-match-configs | cloud | 3 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 82; mismatch: unexpectedExtraColumns; golden digest: a612c7b202f1; candidate digest: 27441210781b | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit |
| preseason.latest-failed-runs | cloud | 1 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 50; golden digest: 2eaecdc15931; candidate digest: 2eaecdc15931 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, filters, projection, ordering, limit |
| preseason.latest-failed-runs | cloud | 2 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 78; golden digest: 2eaecdc15931; candidate digest: 2eaecdc15931 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, filters, projection, ordering, limit |
| preseason.latest-failed-runs | cloud | 3 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 54; golden digest: 2eaecdc15931; candidate digest: 2eaecdc15931 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, filters, projection, ordering, limit |
| preseason.top-wins-ambiguous | cloud | 1 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit, date anchors |
| preseason.top-wins-ambiguous | cloud | 2 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit, date anchors |
| preseason.top-wins-ambiguous | cloud | 3 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit, date anchors |
| preseason.top-wins-defined | cloud | 1 | wrongSchemaObjects | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: false; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 60; golden digest: 936463e03e4c; candidate digest: 936463e03e4c | missing ops: relative-time-filter; mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit, date anchors |
| preseason.top-wins-defined | cloud | 2 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 61; golden digest: 936463e03e4c; candidate digest: 936463e03e4c | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit, date anchors |
| preseason.top-wins-defined | cloud | 3 | wrongSchemaObjects | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: false; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 34; golden digest: 936463e03e4c; candidate digest: 936463e03e4c | missing ops: relative-time-filter; mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit, date anchors |
| preseason.verified-tools | cloud | 1 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 56; golden digest: 8ef7cb7ed861; candidate digest: 8ef7cb7ed861 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, filters, projection, ordering, limit |
| preseason.verified-tools | cloud | 2 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 69; golden digest: 8ef7cb7ed861; candidate digest: 8ef7cb7ed861 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, filters, projection, ordering, limit |
| preseason.verified-tools | cloud | 3 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 3; candidate rows: 3; semantic ms: 68; mismatch: missingCandidateColumn; golden digest: 8ef7cb7ed861; candidate digest: 540c8637d6e4 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, filters, projection, ordering, limit |
| saas.active-users-by-org | cloud | 1 | wrongSchemaObjects | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 54; mismatch: missingCandidateColumn; golden digest: ecd46213fb8c; candidate digest: 1845a3aa973e | missing ops: relative-time-filter; mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit, date anchors |
| saas.active-users-by-org | cloud | 2 | wrongSchemaObjects | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 56; mismatch: missingCandidateColumn; golden digest: ecd46213fb8c; candidate digest: 1845a3aa973e | missing ops: relative-time-filter; mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit, date anchors |
| saas.active-users-by-org | cloud | 3 | wrongSchemaObjects | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 60; mismatch: missingCandidateColumn; golden digest: ecd46213fb8c; candidate digest: 1845a3aa973e | missing ops: relative-time-filter; mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit, date anchors |
| saas.expiring-subscriptions | cloud | 1 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 2; candidate rows: 4; semantic ms: 76; mismatch: missingCandidateColumn; golden digest: 6fe5273c08f5; candidate digest: cadc46d726aa | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit, date anchors |
| saas.expiring-subscriptions | cloud | 2 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 2; candidate rows: 4; semantic ms: 74; mismatch: missingCandidateColumn; golden digest: 6fe5273c08f5; candidate digest: 0481bd89b86a | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit, date anchors |
| saas.expiring-subscriptions | cloud | 3 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: ordered | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit, date anchors |
| saas.healthy-accounts | cloud | 1 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1 |
| saas.healthy-accounts | cloud | 2 | generationFailure | - | notApplicable | attempted: false; end-to-end: false | SQL generation failed: Schema or inspection tool call budget exhausted.; mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1 |
| saas.healthy-accounts | cloud | 3 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1 |
| saas.overallocated-seats | cloud | 1 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 1; candidate rows: 1; semantic ms: 51; mismatch: missingCandidateColumn; golden digest: 0385dc4952ef; candidate digest: da35bd05c12a | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| saas.overallocated-seats | cloud | 2 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 1; candidate rows: 1; semantic ms: 44; mismatch: missingCandidateColumn; golden digest: 0385dc4952ef; candidate digest: 19d53217acf4 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| saas.overallocated-seats | cloud | 3 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 1; candidate rows: 1; semantic ms: 98; mismatch: missingCandidateColumn; golden digest: 0385dc4952ef; candidate digest: 14f6ddd2f673 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| saas.users-without-membership | cloud | 1 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 82; golden digest: 5703a2d4d845; candidate digest: 5703a2d4d845 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit |
| saas.users-without-membership | cloud | 2 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 66; golden digest: 5703a2d4d845; candidate digest: 5703a2d4d845 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit |
| saas.users-without-membership | cloud | 3 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 69; golden digest: 5703a2d4d845; candidate digest: 5703a2d4d845 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit |
| support.average-first-response | cloud | 1 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: scalar | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, filters, projection, aggregation, limit, date anchors |
| support.average-first-response | cloud | 2 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: scalar | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, filters, projection, aggregation, limit, date anchors |
| support.average-first-response | cloud | 3 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: scalar | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, limit, date anchors |
| support.frequent-feedback-cluster | cloud | 1 | passed | passed | resultMismatch | attempted: true; env: true; equivalent: false; end-to-end: false; mode: ordered; golden rows: 1; candidate rows: 3; semantic ms: 77; mismatch: rowCountMismatch; golden digest: 1a6d6a9526d4; candidate digest: a27df1aa8c00 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, projection, aggregation, grouping, ordering, limit |
| support.frequent-feedback-cluster | cloud | 2 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 1; candidate rows: 1; semantic ms: 73; golden digest: 1a6d6a9526d4; candidate digest: 1a6d6a9526d4 | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| support.frequent-feedback-cluster | cloud | 3 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: ordered | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1 |
| support.important-cluster | cloud | 1 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, projection, aggregation, grouping, ordering, limit |
| support.important-cluster | cloud | 2 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, projection, aggregation, grouping, ordering, limit |
| support.important-cluster | cloud | 3 | passed | - | notApplicable | attempted: false; end-to-end: true | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1 |
| support.unclustered-feedback | cloud | 1 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 65; golden digest: c578d30d7f8c; candidate digest: c578d30d7f8c | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, filters, projection, ordering, limit |
| support.unclustered-feedback | cloud | 2 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 41; golden digest: c578d30d7f8c; candidate digest: c578d30d7f8c | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, ordering, limit |
| support.unclustered-feedback | cloud | 3 | passed | passed | passed | attempted: true; env: true; equivalent: true; end-to-end: true; mode: ordered; golden rows: 2; candidate rows: 2; semantic ms: 69; golden digest: c578d30d7f8c; candidate digest: c578d30d7f8c | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: false |
| support.unresolved-by-assignee | cloud | 1 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: ordered | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| support.unresolved-by-assignee | cloud | 2 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: ordered | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |
| support.unresolved-by-assignee | cloud | 3 | wrongDecision | - | notApplicable | attempted: false; end-to-end: false; mode: ordered | mode: promptOnlyJSON; retries: 0; returned: particle-ai/particle-1; query plan: present; structured: true; sections: grain, joins, filters, projection, aggregation, grouping, ordering, limit |

Estimated initial prompts and raw model output are intentionally omitted from this summary.
The estimated initial prompt character metrics are pre-call estimates from the eval runner, not the exact model prompt after discovery, truncation, or retry behavior.
