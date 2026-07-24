# Next Development Steps

Follow-up PRs after PR 55 (pinned OpenRouter profile, private routing,
canonical-version enforcement, release-gate hardening) merges to `main`.
Numbering continues from `docs/refactoring-plan.md`.

## Completed and remaining work

* ✅ **Done — PR 56 experiment and retry:** restored the trusted
  schema-tool SQL bypass, ran the complete pinned GPT-5.5 gate before and
  after PR 59, applied every pre-registered criterion, and published sanitized
  evidence. The post-PR 59 retry cleared the semantic and clarification floors
  but recorded one internal schema-agent timeout, so the conjunctive decision
  rule rejected the bypass again. It is not part of the final product diff.
* ✅ **Done — routed-model verification:** retained the
  OpenRouter metadata fix needed to verify the concrete model behind a
  completion alias, including fail-closed handling for missing, ambiguous,
  unexpected, or contradictory routing evidence.
* ✅ **Done — PRs 57–59 evidence work:** re-ranked the fresh
  failure buckets, identified PR 59 as the next implementation, and documented
  what PRs 57 and 58 should evaluate afterward. No PR 57, 58, or 59 behavior
  change was implemented here.
* ✅ **Done — PR 59 budget/timeout fix:** separated wall-clock timeouts from
  schema-tool budget exhaustion end to end (agent failure category, redacted
  diagnostics, eval status, triage bucket, gate reporting) and added
  deterministic interception of provably redundant schema-tool calls so they
  no longer consume the six-call budget, which stays at six. The post-PR 59
  full gate completed the bucket, cost, latency, timeout-reporting, and
  counter-population acceptance measurement.
* ✅ **Done — PR 60 canonical-version watch:** added a daily/manual,
  credential-free public catalog check with drift-only issue creation,
  fail-closed operational handling, deterministic coverage, and a
  spend-accounted canonical rollover runbook.
* ✅ **Done — PR 62 PR 55 hardening cleanups:** simplified the fixed private-
  routing preferences, catalog refresh completion, canonical test fixtures,
  release-policy/reporting code, and resume-model Make logic; removed one
  redundant cache write; and bounded cache-served canonical-mismatch
  reverification to once per catalog TTL while keeping network-fresh
  mismatches fail-closed without another fetch.
* ⏳ **Not done:** PR 58 clarification behavior (two funded attempts were
  reverted; the latest reached 12/12 clarification but failed the retained
  over-clarification guardrail), and structured plan validation or
  compilation.

## Where things stand

* The product path is fixed: OpenRouter schema-tool agent, pinned
  `openai/gpt-5.5` (canonical `openai/gpt-5.5-20260423`), zero-data-retention
  routing, fail-closed canonical checks in the app and in pinned-model evals
  (with one forced-refresh recovery so a stale cache cannot fail a freshly
  updated app). A completion alias is now accepted only when router metadata
  also names the requested alias and exactly one selected endpoint reports
  the pinned canonical version; missing, ambiguous, or conflicting evidence
  still fails closed. Release-gate/triage doc publication is pin-enforced in
  both the Makefile and the eval CLI (`--allow-model-override` to opt out).
* The release gate still fails, so text-to-SQL stays beta. The complete
  2026-07-14 post-PR 59 retry (pinned GPT-5.5, private routing, canonical
  enforcement, $3.521450) reached 26/60 semantic and 11/12 clarification.
  Safety/schema stayed 42/42, transport was 60/60, structured parsing was
  59/60, and forbidden bindings, repeated repairs, and eval timeouts were
  zero. One 93.7-second internal schema-agent timeout was correctly reported
  as a `generationFailure`, the `schema-agent timeout` triage bucket, and an
  `Internal schema-agent timeouts` count of one. The pre-registered PR 56
  criteria are conjunctive and require both timeout kinds to stay at zero, so
  the bypass was rejected and reverted in follow-up commit `842bd42`.
* Against the 2026-07-10 retained product comparator, the retry moved
  expected-SQL clarification 28 -> 5, semantic mismatch triage 6 -> 26,
  tool-budget failure triage 6 -> 0, and static schema failure 1 -> 0. The
  semantic-status total is 27 mismatches because one result with an earlier
  zero-hit search is classified by triage precedence as `no schema match`.
* PR 59 now passes its funded acceptance measurement. Cost was $0.058690833
  per case versus $0.054605083 (+7.48%, below the 15% ceiling), and P95 was
  33,781 ms versus 30,244 ms (+11.70%). The failed-result tool-budget bucket
  was zero; two otherwise successful clarification results carried genuine
  `sessionBudgetExceeded` traces, which also remain within the at-most-three
  target. All 60 diagnostics populated the three redundant-interception
  counters; no interception fired in this run (duplicate/zero-hit/join-path
  totals 0/0/0).
* Clarification was 11/12 in both the retained PR 55 comparator and the
  post-PR 59 PR 56-bypass retry. The retry's sole miss was
  `preseason.top-wins-ambiguous` repeat 3 returning SQL without a timeout,
  budget error, or app-side rejection. Two later PR 58 attempts were rejected;
  this miss still does not justify expanding the frozen phrase heuristics.
* The 2026-07-14 funded PR 58 attempt confirmed that the terminal ambiguity
  policy can override an otherwise accepted SQL response, but it failed the
  complete gate: clarification was 10/12 and the exclusive expected-SQL
  clarification bucket was 30, against requirements of 12/12 and at most 28.
  The behavioral commit was reverted; no unproven PR 58 behavior remains.
* The 2026-07-15 funded retry fixed both observed ambiguity-path mechanisms
  in deterministic coverage and reached 12/12 clarification decisions in the
  complete gate. It still recorded 30 in the exclusive expected-SQL
  clarification bucket, above the retained PR 55 ceiling of 28, so the
  conjunctive PR 58 acceptance rule rejected it too. Commit `e13f6aa` reverted
  candidate `f356ba4`; only sanitized evidence remains.
* PR 60 now checks the production alias-to-canonical mapping every day and on
  manual dispatch without an API key or completion. Confirmed drift opens one
  deduplicated rollover issue; lookup, transport, decoding, and invalid
  identity failures fail visibly without claiming drift. The live metadata
  check on 2026-07-15 confirmed the current pin.
* PR 62 now remembers a confirmed cache-served canonical mismatch only for
  that catalog snapshot and TTL. Repeated generations fail immediately from
  the memo; TTL expiry or invalidation permits a fresh verification, while a
  mismatch observed on a network-fresh lookup still fails immediately without
  a second catalog request. The memo is memory-only and never stores an API
  key.
* Standing conclusions to respect: the intent-coverage phrase heuristics are
  frozen (PR 53); more force-SQL prompt pressure does not help (PR 52); the
  next accuracy lever is stable query planning / deterministic synthesis
  (PR 52/54 conclusions); PR 10 embeddings stay deferred because retrieval
  already hits 100% required-table recall.

## Recommended order

1. ✅ Done — PR 59 budget/timeout fix and funded acceptance: pre-tool
   timeouts are now classified
   and reported separately from genuine six-call exhaustion, redundant
   schema-tool exploration is deterministically intercepted without burning
   budget, the six-call limit is unchanged, and the full-gate bucket/cost/
   latency criteria pass
2. ✅ Done — PR 56 retry: every criterion except zero internal schema-agent
   timeouts passed, so the bypass was reverted and PR 57 remains conditional
3. ✅ Done — PR 60 canonical-version watch and rollover runbook
4. ✅ Done — PR 62 independent PR 55 hardening cleanups
5. PR 58 remains open after two negative funded attempts; retry only with a
   genuinely narrower, pre-registered design that can preserve 12/12 without
   exceeding the retained over-clarification comparator
6. PR 57 only after a future bypass iteration clears every PR 56 criterion
7. PR 63 GPT-5.6 Sol pin upgrade: candidate and offline checks are complete;
   run the funded smoke plus full gate once its spend cap is authorized

---

## PR 56 — GPT-5.5 grounding-bypass full-gate experiment

**Status: ✅ Done.** The experiment and decision are complete. The bypass
failed its conjunctive gate and was reverted; only the routed-model verifier
and sanitized evidence remain.

**Why:** The trusted-agent grounding bypass (commit `7d6baff`, reverted in
`0e7d430`) raised Terra's full gate from 17/60 to 22/60, but was only ever
full-gated on Terra. GPT-5.5, the pinned model, never got the full-gate
comparison; its 24/60 baseline predates the bypass.

**What:** Cherry-pick the reverted bypass, run `make eval-release-triage`
(pinned model, ~$1.5–3.5), and apply pre-registered criteria covering the
full approved gate, not just the headline: merge only if semantic pass
exceeds 19/60 (the HEAD baseline) AND clarification decision accuracy stays
at or above 11/12 AND safety/schema validity stays 100% on evaluated SQL AND
transport and structured-response parsing stay at or above 95% AND
forbidden-binding violations, repeated/no-progress repairs, and eval
timeouts and internal schema-agent timeouts all stay at zero. Otherwise
revert again and record the negative result here and in the refactoring plan.

**First attempt 2026-07-13 — inconclusive:** Commit `747eef5` restored the bypass
and passed 182 focused tests plus the full 1,094-test suite. The pinned gate
then produced 35/35 typed `modelVersionMismatch` failures from HTTP-successful
Azure responses: the authenticated catalog reported the expected canonical
ID, while every completion reported only `openai/gpt-5.5`. The run had zero
completed/evaluable results, zero schema-tool calls, 25 results still missing,
P95 latency 4,748 ms, and $0.204335 cost when it was stopped. Because none of
the pre-registered accuracy or reliability criteria could be evaluated, this
is neither a pass nor a negative bypass result. Commit `30c5cb9` reverted the
bypass, the committed release reports were left at the last valid complete
gate, and PRs 57–59 did not receive fresh triage. Retry this experiment only
after the response model-ID behavior is resolved or positively confirmed;
do not weaken fail-closed canonical enforcement to manufacture a gate result.

**Completed retry 2026-07-13 — negative:** Commit `9d8eb1a` resolved the
response-contract blocker without trusting the top-level alias alone, and
`cd10d86` restored the bypass. The canonical parser suites passed 126 tests,
the bypass validator/pipeline suites passed 182 tests, and `make test` passed
1,097 tests. The complete pinned gate then recorded:

```text
results: 60/60 complete
semantic end-to-end: 22/60 (criterion >= 20: pass)
clarification decisions: 9/12 (criterion >= 11: fail)
safety/schema: 41/41 each (100%: pass)
transport: 60/60 (100%: pass)
structured parsing: 57/60 (95%: pass)
forbidden bindings / repeated repairs: 0 / 0 (pass)
eval-timeout status: 0; internal schema-agent timeout: 1 (strict criterion: fail)
latency: p50 16,977 ms; p95 30,244 ms; max 91,012 ms
gate cost: $3.276305
cumulative OpenRouter spend: $3.481360
```

The headline improved 19 -> 22, but the pre-registered criteria are
conjunctive, so the 9/12 clarification result rejects the bypass regardless
of how the misclassified internal timeout is counted. The fresh
bucket movement was false clarification 28 -> 5, semantic mismatch 6 -> 28,
tool-budget triage 6 -> 5, and static schema failure 1 -> 0. The sanitized
gate and triage reports retain this negative evidence; raw prompts, model
responses, rows, schemas, and `.eval-results` remain uncommitted.

**Post-review hardening — ✅ Done:** Commit `33f37e3` made the
routed-model verifier reject contradictions even when the top-level response
already names the expected canonical model. The final parser suites passed
128 tests, and `make test` passed 1,092 tests across 49 suites.

**Post-PR 59 retry 2026-07-14 — negative, ✅ Done:** Commit `bcaf957`
restored the exact patch last tested in `cd10d86`; comparison with both restore/
revert cycles (`cd10d86` / `55d7d63` and `747eef5` / `30c5cb9`) confirmed the
two newer restore patches are identical. The routed-model verifier and
canonical enforcement were untouched, the bypass validator/pipeline suites
passed 182 tests, and `make test` passed 1,117 tests in 49 suites before the
first paid request. The complete pinned gate recorded:

```text
results: 60/60 complete
semantic end-to-end: 26/60 (criterion >= 20: pass)
clarification decisions: 11/12 (criterion >= 11: pass)
safety/schema: 42/42 each (100%: pass)
transport: 60/60 (100%: pass)
structured parsing: 59/60 (98.3%: pass)
forbidden bindings / repeated repairs: 0 / 0 (pass)
eval-timeout status: 0 (pass)
internal schema-agent timeouts: 1 (criterion 0: fail)
latency: p50 17,968 ms; p95 33,781 ms; max 93,681 ms
gate cost: $3.521450
```

The criteria are conjunctive. The separately typed internal schema-agent
timeout therefore rejects the bypass even though every other PR 56 criterion
passed. It was reported consistently as a `generationFailure`, the
`schema-agent timeout` triage bucket, and an `Internal schema-agent timeouts`
count of one; eval timeouts stayed zero. Commit `842bd42` reverted only the
bypass. The routed-model verifier, canonical enforcement, and sanitized gate
evidence remain.

## PR 57 — Plan-then-compile SQL synthesis for covered shapes

**Status: re-triage ✅ Done; implementation ⏳ Not started.** PR 57 is not
next because the post-PR 59 bypass retry failed and was reverted. It remains
conditional on a future bypass iteration passing every promotion criterion.

**Why:** Semantic result mismatch was 6 on the retained PR 55 behavior and
grew to the largest experimental bucket, 28 in the 2026-07-13 experiment and
26 in the post-PR 59 retry, when PR 56 stopped discarding model SQL. Because
both bypass runs were rejected and reverted, treat those results as evidence
for the next passing bypass iteration, not as the current product baseline.
PR 54 added a redacted `query_plan` to the terminal contract as diagnostics;
PR 52 concluded the fix is stable query-plan and SQL-shape generation, not
more prompt pressure or phrase heuristics.

**What:** Promote the query plan from prose diagnostics to a small structured
contract (grain, joins with roles, filters, aggregation, group/order/limit,
date anchors — all referencing schema-tool evidence IDs). Then use it in the
least invasive mode that moves the metric, in this order:

1. **Plan-validate-and-repair (default):** check the model's SQL against its
   own structured plan and against the plan's evidence bindings; on
   divergence, drive the existing single-repair path with the specific
   mismatch. No app-generated SQL.
2. **Plan-compile (requires an explicit architecture decision):** compiling
   joins/filters/aggregation in the app is exactly the custom SQL compiler
   the refactoring-plan background rejects, and fallback-on-unsupported does
   not protect against incorrectly compiled "supported" plans. Only pursue
   this if option 1 measurably stalls, record the decision in the
   refactoring plan, and build on a proven SQL AST/query-builder rather than
   string assembly.

**Acceptance:** Semantic mismatch shrinks against a complete, otherwise
passing grounding-bypass comparator with safety/schema at 100% and no growth
in wrong-decision or tool-budget buckets. Deterministic unit tests for the
plan decoder and every validation rule; plans that do not fit the contract
must fall back to current behavior, never error.

**Do not change:** eval goldens, seeded data, backend defaults, privacy
routing, frozen heuristics.

## PR 58 — Clarification decision accuracy to 12/12

**Status: two funded attempts complete, negative; implementation ⏳ Not
done.** Commit `bfc4ea2` selectively enforced the existing high-confidence
`mustClarify` terminal decision; commit `b3b69fe` reverted it after the first
gate failed both criteria. Candidate `f356ba4` then fixed the identified
wording and terminal-less budget paths and reached 12/12, but commit `e13f6aa`
reverted it after the retained over-clarification guardrail failed. The frozen
phrase heuristic set remains unchanged.

**Why:** The gate requires 100%; the retained PR 55 comparator and the
post-PR 59 retry both sit at 11/12. The earlier 9/12 experiment had three
operational misses, but the new sole miss was independent:
`preseason.top-wins-ambiguous` repeat 3 returned SQL without a timeout, budget
error, or app-side rejection. The two attempts below leave that retained-path
miss unresolved pending a design that also preserves the comparator guardrail.

**What:** Reproduce and triage the one independent clarification failure, then
fix its specific decision behavior (prompt guidance or clarification policy
fidelity for that ambiguity class). No new phrase heuristics — the PR 53
freeze stands.

**Acceptance (reconciled before the paid gate on 2026-07-14):** 12/12
clarification decisions across three repeats, with the exclusive
expected-SQL-got-clarification bucket no higher than the retained PR 55
product-path comparator of 28. The earlier ceiling of 3 came from the PR 16
configuration that PR 52 later made diagnostics-only; the rejected and
reverted grounding-bypass comparator of 5 is not the retained product path.
This comparator choice was explicitly approved before seeing PR 58 gate
results.

**Funded outcome 2026-07-14:** The complete pinned
`openai/gpt-5.5` release gate ran all 60 cases for $3.330465, below the $4
authorization. It evaluated commit `ff79bb2`; commit `4618375` records that
run's sanitized reports. The report paths now contain the later retry below.

| Mechanical criterion | Retained PR 55 comparator | PR 58 attempt | Result |
| --- | ---: | ---: | --- |
| Clarification decisions | 11/12 | 10/12 | Fail (required 12/12) |
| Exclusive expected-SQL clarification bucket | 28 | 30 | Fail (required `<= 28`) |
| Semantic end to end | 19/60 | 19/60 | No change |

The ambiguity guard did fire for `preseason.top-wins-ambiguous` repeat 2 and
changed the terminal decision from SQL to clarification. That result still
failed clarification quality because the deterministic fallback asked about
plural “wins,” while the scorer's expected concepts recognize singular “win”
or “winner” and do not stem the term. The other clarification miss,
`saas.healthy-accounts` repeat 2, was operational: six successful schema calls
were followed by a rejected seventh call, so no terminal response existed for
the guard to evaluate. `maximumSchemaToolCalls` remains six.

A reporting-only follow-up fixed the triage policy column so an intent-policy
decision is visible even when the separate clarification-policy field is
empty. Offline re-triage now exposes `unresolved: metric; intent: mustClarify`
for the ambiguity miss. This changes neither decisions nor scoring.

The raw expected-SQL-to-clarification count was 33 in both the comparator and
the attempt. Triage precedence assigned five comparator results but only
three attempt results to the tool-budget bucket, leaving the pre-registered
exclusive values of 28 and 30. The exclusive criterion was applied exactly as
registered rather than reinterpreted after the run.

Other complete-gate results were: safety 15/15, schema validity 15/15,
PostgreSQL verification 15/15, transport 60/60, structured parsing 59/60,
forbidden bindings 0, repeated/no-progress repairs 0, eval timeouts 0,
internal schema-agent timeouts 0, direct schema-tool budget failures 1
(exclusive triage bucket 4), and semantic mismatches 6. Latency was P50
15,717 ms, P95 27,042 ms, and maximum 30,725 ms. Requested and returned model
aliases were `openai/gpt-5.5` for all 60 cases, with the pinned canonical model
and private-routing verification still enforced.

The attempt did not change the six-call budget, safety/schema/PostgreSQL
validation, private routing, canonical/routed-model verification, structured
parsing, PR 59 timeout/budget/interception behavior, or the PR 53 phrase
heuristics, and it did not restore the reverted PR 56 grounding bypass. A
later attempt addressed the two identified ambiguity mechanisms, as recorded
below.

**Funded retry outcome 2026-07-15:** Candidate `f356ba4` made the existing
protected-metric ambiguity fallback ask what counts as one win, centralized
evidence-vetted ambiguity selection, and added a bounded response after a
real rejected seventh schema-tool request. The latter either returned a
protected, evidence-grounded clarification or allowed one terminal-only model
turn for SQL; it never raised `maximumSchemaToolCalls` above six. It added
deterministic coverage for the historical terminal-SQL miss, the terminal-less
six-call miss, defined and ungrounded controls, trailing batches, attempted
eighth calls, timeout precedence, and the pinned clarification scorer. No
phrase-matching set was added or broadened.

The focused ten-suite matrix passed with 571 successful test executions and
no failures, `make test` passed 1,120 tests across 49 suites, and
`make eval-build` passed. The complete pinned gate then evaluated `f356ba4`
and completed 60/60 cases for $3.378570 under the fresh $4 authorization.

| Mechanical criterion | Retained PR 55 comparator | PR 58 retry | Result |
| --- | ---: | ---: | --- |
| Clarification decisions | 11/12 | 12/12 | Pass (required 12/12) |
| Exclusive expected-SQL clarification bucket | 28 | 30 | Fail (required `<= 28`) |
| Semantic end to end | 19/60 | 21/60 | Informational (+2) |

The historical ambiguity case clarified correctly in all three repeats, and
`saas.healthy-accounts` also clarified correctly in all three repeats. The raw
expected-SQL-to-clarification count was 33. Triage precedence assigned three
of those results to `tool budget exhausted`, leaving 30 in the exclusive
guardrail bucket. Because acceptance was conjunctive, the 12/12 headline did
not permit retaining the behavior. The general release gate independently
remained below its semantic threshold at 21/60 versus the required 90%.

Other complete-gate results were: SQL semantic 9/15, safety 15/15, schema
validity 15/15, PostgreSQL verification 15/15, transport 60/60, structured
parsing 60/60, forbidden bindings 0, repeated/no-progress repairs 0, eval
timeouts 0, internal schema-agent timeouts 0, direct schema-tool budget
failures 0, six results with one app-side budget-rejection trace each, an
exclusive tool-budget triage bucket of 3, and semantic mismatches 6. Latency
was P50 15,820 ms, P95 32,361 ms, and maximum 73,599 ms. Requested and
returned model aliases were `openai/gpt-5.5` for all 60 cases, with pinned
canonical model, private-routing, and routed-model verification enforced. The
two PR 58 funded gates spent $6.709035 in total; this retry accounted for
$3.378570.

Commit `e13f6aa` reverted the candidate and its tests after the failed
guardrail. The retained tree still has the six-call budget, PR 53 heuristic
freeze, validation and routing protections, PR 59 timeout/budget/interception
behavior, and no PR 56 bypass. PR 58 remains not done. The latest sanitized
evidence is [evals/0.1.0.md](evals/0.1.0.md) and
[evals/0.1.0-triage.md](evals/0.1.0-triage.md); they intentionally identify
the evaluated candidate rather than the later revert. A future retry needs a
narrower way to recover the protected ambiguity class while reaching 12/12
and an exclusive expected-SQL clarification bucket at or below 28 with margin
for triage-precedence movement, plus fresh spend authorization.

## PR 59 — Tool-budget exhaustion bucket

**Status: ✅ Done, including funded acceptance.** The trace diagnosis
separated four genuine six-call exhaustions from one misclassified pre-tool
timeout, and the budget/timeout fix landed in commits `47d6ad1`, `2b28900`,
and `551ce3e`. The six-call budget is unchanged; the post-PR 59 full gate
completed the acceptance measurement below.

**Why:** The retained comparator has 6 triaged tool-budget results. The PR 56
experiment had four genuine exhaustion records: each used six successful
schema calls and the seventh `inspect_column_constraints` call returned an
error. Two were `saas.active-users-by-org` wrong decisions and two were
`saas.healthy-accounts` generation failures that directly caused two of the
three clarification misses. A fifth triage entry was actually a 91-second
pre-tool timeout, exposing a reporting gap rather than schema-call exhaustion.

**What:** Re-derive the failure mechanics from fresh traces before touching
anything — earlier assumptions have gone stale once already: the budget is
six calls, not four, and repeated identical tool calls are already
intercepted with a correction response before invocation. From the traces,
classify why the observed distinct calls include repeated zero-result searches
and repeated join-path searches, and separately fix the timeout categorization.
Determine whether exhaustion comes from scattered near-duplicate exploration
(distinct arguments that add no evidence), from genuinely broad questions,
or from correction turns burning budget, then fix that specific mechanism
with cost/latency measured. Do not raise `maximumSchemaToolCalls` from six
without evidence that the added call is the bounded, correct remedy.

**Acceptance:** Bucket at or below 3 on the full gate with per-case cost and
p95 latency no worse than 15% over baseline.

**Outcome 2026-07-14:** The classification gap and the deterministic
redundancy mechanisms are fixed without touching the six-call budget, the
prompts, safety/schema validation, PostgreSQL verification, privacy routing,
canonical-model checks, or the frozen phrase heuristics:

* Wall-clock deadline expiry now throws a dedicated `wallClockTimeout`
  agent-failure category instead of `modelTurnBudgetExhausted`, at the
  turn-loop deadline check and both in-flight send deadline races. Redacted
  diagnostics record `timedOut` instead of `budgetExhausted`, the eval case
  status becomes `generationFailure` instead of `parseFailure`, triage
  buckets it as `schema-agent timeout` ahead of the tool-budget predicate,
  and the gate and triage run tables report an `Internal schema-agent
  timeouts` count. Genuine exhaustion still records `budgetExhausted` plus a
  `sessionBudgetExceeded` tool trace, so the tool-budget bucket now means
  actual exhaustion.
* Three provably redundant schema-tool call classes are intercepted before
  session invocation with structured tool errors, so they no longer consume
  the six-call budget: value-identical repeats of an already executed call
  (canonicalized JSON arguments), repeats of a search query that already
  returned zero hits (zero-hit search results are limit-independent), and
  `find_join_paths` requests whose unordered endpoint pair and hop/path
  scope are dominated by an already executed call (the foreign-key graph is
  bidirectional). Wider-scope join-path requests still execute, interception
  never counts toward the repeated-call hard-failure limit, and identifier
  case is preserved throughout. Redacted diagnostics count each interception
  kind and triage rows gained a `Redundant` column next to `Schema Tools`.
* Deterministic reproductions preceded the fix: against the pre-fix agent,
  all three interception tests failed with `schemaToolCallBudgetExhausted`,
  and the timeout tests could not express the timeout/budget distinction at
  all. An adversarial review pass then hardened three edge cases with
  regression tests: a timeout after a recovered correction now overrides the
  stale rejection reason instead of hiding under it, a join-path scope is
  recorded as fully explored only when the response provably contains every
  path (truncated results are direction-dependent), and out-of-range
  join-path arguments fall through to the session's validation error instead
  of being intercepted. A PR review round tightened three more edge cases:
  the redundant interception now runs before repeated-call tracking (so
  provably redundant byte-identical repeats no longer consume the one
  repeated-call correction or escalate to the typed no-progress failure,
  while repeats of failed calls still do), search and join-path argument
  shapes are fully validated before interception (malformed repeats still
  get the session's validation error), and a transport-level timeout that
  surfaces after the agent deadline has passed is classified as the
  wall-clock timeout it is. After the fixes the focused agent and
  eval-planning suites pass and `make test` passes 1,110 tests in 49 suites.

**Funded acceptance measurement — ✅ Passed:** The post-PR 59 PR 56 retry
provided the complete pinned comparator:

| Metric | Same-bypass baseline | 2026-07-14 retry | Result |
| --- | ---: | ---: | --- |
| Failed-result tool-budget bucket | 5 | 0 | Pass (`<= 3`) |
| Cost per result | $0.054605083 | $0.058690833 | Pass (+7.48%) |
| P95 latency | 30,244 ms | 33,781 ms | Pass (+11.70%) |
| Schema-agent timeout bucket | Misclassified with tool budget | 1 | Correctly populated |
| Internal timeout count | Not separately reported | 1 | Correctly populated |
| Redundant duplicate / zero-search / join-path | Not available | 0 / 0 / 0 | Counters populated |

All three redundant-interception counters were present on 60/60 diagnostics;
their zero totals mean no redundant interception fired in this run. Two
otherwise successful `preseason.top-wins-ambiguous` clarification results did
carry genuine `sessionBudgetExceeded` traces even though the failure-only
triage bucket is zero. That operational count is also within the at-most-three
target and is retained here so the bucket semantics are explicit. The timeout
bucket and run-table count both reported one, while the generic timeout/
cancellation bucket and eval-timeout status stayed zero. PR 59 therefore
passes its acceptance criteria even though the observed internal timeout
independently fails PR 56's stricter zero-timeout rule.

## PR 60 — Canonical-version watch and rollover runbook

**Status: ✅ Done.**

**Why:** The app fails closed if OpenRouter rolls `openai/gpt-5.5` to a new
canonical version; users then need an app update. Today nothing warns the
team before users hit it.

**What:** A scheduled check (CI cron) that fetches the OpenRouter catalog and
compares `canonical_slug` for the pinned model against
`OpenRouterCatalog.productionProfile.expectedCanonicalModelID`; on drift it
opens an issue. Add a rollover section to `docs/release.md`: run the release
gate on the new canonical, update the profile constant, ship a Sparkle
release. The in-app pre-flight and eval-side enforcement added in PR 55
already fail loudly (after one self-healing cache refresh), and Settings warns
when the catalog canonical has rolled; this PR is about the team hearing it
before users do.

**Outcome 2026-07-15:** The default-branch workflow runs daily at 08:23 UTC
and on manual dispatch. It reads both production IDs directly from
`OpenRouterCatalog.productionProfile`, performs one public single-model
lookup without an API key or completion, bypasses Widen/local cache state,
requests upstream revalidation, and accepts drift only when the response
model identity and canonical ID are strictly validated. The CLI exits `0`
for current, `2` for confirmed drift, and `1` for an operational failure.

Confirmed drift creates at most one open issue identified by a stable hidden
marker and then fails the workflow. Operational failures suppress provider
output, create no issue, and still fail visibly. Tests cover current and
rolled canonicals, missing/unexpected/malformed identities, invalid model-ID
shapes, HTTP/transport/decoding failures, a primed local catalog cache, no
credential or request body, workflow permissions/scheduling/deduplication,
and both failure paths. `make project`, 205 focused tests in five suites, all
1,117 tests in 49 suites, and `make eval-build` pass. The live metadata-only
check returned current for `openai/gpt-5.5-20260423`; no paid OpenRouter
request was made. The release runbook now pre-registers rollover criteria,
preserves the requested alias and enforcement layers, accounts for cumulative
branch spend and resumable gate ceilings, and keeps beta exit separate from
rollover non-regression.

## PR 62 — PR 55 hardening cleanups

**Status: ✅ Done [2026-07-16].**

The fixed private-routing policy is now a caseless enum with static
functionality, and its user-facing privacy claim lives beside the enforced
provider configuration. Catalog refresh computes one result and completes in
one `MainActor` block; cancellation records an explicit final status instead
of retaining stale text. The user-initiated model test no longer invalidates
and writes the catalog immediately before its force-refreshing connectivity
check. Connectivity canonical cases share a run helper, and tool-chat
canonical cases use the model-aware `assistantToolCalls` and `toolCall`
fixtures.

Generation preflight now uses a bounded two-pass loop. A confirmed canonical
mismatch from a cache-served catalog snapshot is memoized in memory by API-key
fingerprint and model identity, so subsequent generations fail closed without
invalidating and refetching until that snapshot's TTL expires. An expired or
explicitly invalidated snapshot can verify again. A network-fresh mismatch
still fails immediately without a second fetch. Successful verification and
relevant invalidation clear the memo; raw credentials and memo state are never
persisted.

The remaining review cleanups are also complete: release-gate violations
compute the production pin, reporting calls the redactor directly, and the
resume-model Make logic uses explicit nested `ifeq` branches. Deterministic
coverage exercises memo reuse, cache-served one-time recovery, TTL expiry,
network-fresh immediate failure, refresh cancellation, the consolidated
canonical fixtures, the computed release pin, direct redaction, and all four
resume-model override combinations.

Validation passed with 225 focused tests in seven suites (225 passed, zero
skipped or failed). The full run completed 1,124 tests in 49 suites: 1,082
passed, 42 skipped, and zero failed. `make project` regenerated an unchanged
project, `make eval-build` succeeded, and both working-tree and branch diff
checks passed. No paid OpenRouter request was made. The six-call schema-tool
limit, private routing, requested/canonical/routed-model enforcement, safety/
schema/PostgreSQL validation, structured parsing, deterministic SQL review,
frozen phrase heuristics, PR 59 timeout/tool-budget/interception behavior, and
PR 60 watch/rollover workflow remain unchanged.

## PR 63 — GPT-5.6 Sol production model upgrade

**Status: ⏳ Candidate prepared 2026-07-24; funded gate awaiting spend
authorization.**

**Why:** OpenRouter now lists the GPT-5.6 family. `openai/gpt-5.6-sol` is
priced identically to the retained `openai/gpt-5.5` pin ($5/M prompt, $30/M
completion, observed 2026-07-24) with the same 1,050,000-token context, so
the upgrade is per-token cost-neutral. A newer-generation model is the kind
of change that could move the semantic bucket, which is the current
release-gate bottleneck, but that claim must be proven on the full gate, not
assumed.

**What:** Branch `upgrade-gpt-5.6-sol-pin` repins
`OpenRouterCatalog.productionProfile` to requested `openai/gpt-5.6-sol`,
expected canonical `openai/gpt-5.6-sol-20260709`, and display name
"GPT-5.6 Sol", plus the Makefile pin, the deterministic fixtures that assert
the production pin, and current-state wording in README, PRIVACY,
CONTRIBUTING, `docs/release.md`, `Evals/README.md`, and
`docs/implementation-guide.md`. No prompt, private-routing, safety, schema,
PostgreSQL-verification, schema-tool-budget, frozen-heuristic, or
release-gate-enforcement change is included.

Offline validation on 2026-07-24: `make project` regenerated cleanly; the
five focused canonical/routing/planning suites passed 212 tests; the full
`make test` run passed; `make eval-build` succeeded; and the credential-free
`--check-openrouter-canonical` metadata check observed canonical
`openai/gpt-5.6-sol-20260709` for the requested alias (exit 0, no completion
spend).

**Pre-registered acceptance criteria (conjunctive, recorded before any
completion request):** identical to the retained rollover non-regression
criteria in `docs/release.md`, applied to the new alias:

* 60/60 complete results.
* Semantic end-to-end at least 19/60.
* Clarification decisions at least 11/12.
* Exclusive expected-SQL clarification at most 28.
* Tool-budget triage at most 6 and static schema failures at most 1.
* Safety, schema, and PostgreSQL verification at 100% for evaluated SQL.
* Transport and structured parsing at least 95%.
* Zero forbidden bindings, repeated/no-progress repairs, eval timeouts, and
  internal schema-agent timeouts.
* Private routing plus requested/routed/canonical model verification on
  every completion request.

Also report cumulative branch spend, total and per-result gate cost,
P50/P95/maximum latency, semantic mismatches, and every triage bucket even
where no threshold applies. If any criterion fails, revert the candidate pin,
record the negative result, and do not merge; the cheaper `terra` and `luna`
GPT-5.6 tiers may be evaluated only as separate pre-registered experiments.

**Spend plan (pending authorization):** total branch cap $5.00, smoke
allocation $0.50 for `make eval-openrouter-smoke MODEL=openai/gpt-5.6-sol
REPEAT=3`, one-case overrun reserve $0.10, and a full-gate cumulative
ceiling of $4.00 for `make eval-release-triage MODEL=openai/gpt-5.6-sol`,
sized against the $3.276305 and $3.521450 prior full-gate costs. No paid
request may be made before this cap is explicitly authorized, and
`ALLOW_MODEL_OVERRIDE` stays unset so the gate exercises the production
alias contract.

Passing restores the existing beta cloud path on GPT-5.6 Sol. It does not
satisfy the separate 90% semantic production-readiness gate and does not
authorize removing beta wording.

## Later / conditional

* **PR 10 embeddings** — stays deferred unless a future triage shows required
  tables missing from retrieval, which has not happened since the index
  landed (100% required-table Recall@5).
* **On-device path** — remains "On-Device — Experimental" (20% eval pass).
  Revisit when Apple ships stronger on-device or Private Cloud Compute
  models; the PCC provider path is already in place. Promotion criteria stay
  those of PR 11 (all simple single-table and quoted-identifier cases, at
  least 14/20 total, zero unsafe SQL).
* **Beta exit** — when `make eval-release` passes every threshold (>= 90%
  semantic, 100% clarification, 100% safety/schema, >= 95% transport, 0
  repeated repairs), update README/PRIVACY beta wording and commit the
  passing `docs/evals/<version>.md` as the production-ready record.
* **Second vetted model in the allowlist (formerly PR 61)** — dropped from
  planned work; keep as optional future work. If accounts whose OpenRouter
  provider policies hide GPT-5.6 Sol's ZDR endpoints ever need a cloud path,
  evaluate one fallback candidate through the full release gate under
  identical private routing and add it to the profile list only if it meets
  or beats the pinned baseline with all hard gates green.
