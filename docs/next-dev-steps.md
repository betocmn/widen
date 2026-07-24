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
* ⏳ **Not done:** PR 58 has now completed three negative funded attempts. The
  latest evidence-narrow candidate passed every offline check but failed both
  paid criteria at 10/12 clarification decisions and 31 exclusive false
  clarifications; its behavior and candidate-only tests were reverted.
  Structured plan validation or compilation also remains unimplemented.

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
  budget error, or app-side rejection. Three later PR 58 attempts were
  rejected; the latest recovered this case in all three repeats but failed two
  `saas.healthy-accounts` repeats through the retained tool-budget path and did
  not reduce false clarifications. This still does not justify expanding the
  frozen phrase heuristics.
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
* The 2026-07-18 evidence-narrow retry also failed both PR 58 criteria. It
  reached 10/12 clarification decisions and 31 exclusive expected-SQL
  clarifications. The raw false-clarification count remained 33, and all three
  pre-registered `saas.users-without-membership` controls still clarified, so
  no genuine reduction occurred. Commit `5ee77da` reverted candidate
  `ddf4e12`; only sanitized reports and roadmap evidence remain.
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
5. PR 58 remains open after three negative funded attempts; do not retry the
   latest policy without new diagnostics-only evidence that explains both the
   healthy-account budget misses and why the intended anti-join controls did
   not move
6. PR 57 option 1 is implemented with deterministic coverage after the
   PR 63/64 evidence chain confirmed projection drift as the dominant
   failure; next is its funded diagnostics probe, then a fresh
   pre-registered Sol-plus-bypass-plus-enforcement gate candidate
7. Done, negative — PR 63 GPT-5.6 Sol pin upgrade: the funded gate failed
   the exclusive-clarification ceiling and the zero internal-timeout rule,
   so the candidate pin was reverted and only evidence remains

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

**Status: option 1 implemented and probe-validated 2026-07-24; merged as
diagnostics-only infrastructure. Enforcement waits for the follow-on
pre-registered gate candidate.** The earlier sequencing rule made PR 57 conditional on a
passing bypass iteration; the maintainer directed implementation now because
the PR 63/64 evidence chain (Sol gate triage plus the calibrated offline
superset re-score) established model-independently that projection-shape
drift — not clarification behavior and not comparator strictness — is the
dominant accuracy failure, which is exactly the failure class option 1
validates.

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

**Implementation record 2026-07-24 (option 1, plan-validate-and-repair):**

* The terminal tool's `query_plan` is promoted from a prose string to a
  structured object contract — grain, joins (table/role), filters,
  projection (expression/alias), aggregation (function/column/alias),
  grouping, ordering, limit, date_anchors — declared in the terminal tool
  schema and decoded by `SchemaToolAgentStructuredQueryPlan.decode`
  (`WidenKit/Services/SchemaToolAgentPlanConsistencyPolicy.swift`).
  Decoding is all-or-nothing and bounded; any unknown key, wrong type, or
  exceeded cap makes the plan non-conforming. Non-conforming or prose plans
  fall back to the existing redacted summary diagnostics and never error.
* `SchemaToolAgentPlanConsistencyPolicy.evaluate` deterministically checks
  the terminal SQL against its own plan: symmetric projection output-name
  comparison (aliases, plain column paths, PostgreSQL default function
  naming, DISTINCT/ALL stripped), aggregation function-call presence,
  plan-join tables referenced in the SQL and present in described schema
  evidence, top-level GROUP BY/ORDER BY presence when the plan declares
  grouping/ordering, and top-level LIMIT value equality. Free-prose
  sections (grain, filters, date anchors) are deliberately not validation
  inputs. Identifiers compare case-insensitively with quotes stripped.
* A new `SchemaToolAgentPlanConsistencyMode` (disabled | diagnosticsOnly |
  correctAndRetryExperimental) defaults to diagnosticsOnly, so the app and
  default eval runs record decisions without changing behavior. In the
  experimental mode a divergence drives exactly one in-session correction
  (`plan_sql_divergence` tool error plus a specific-divergence correction
  prompt, mirroring the intent-coverage single-correction pattern); a
  second divergence fails closed with the new typed
  `planConsistencyNoProgress` category and `planConsistencyRejected`
  rejection reason.
* Plumbing follows the existing policy-mode pattern end to end: agent
  configuration, `--schema-agent-plan-consistency` eval flag, run manifest
  field with resume inheritance and nil-normalized resume compatibility,
  run-header rows in the summary/gate/triage reports, a `plan:` entry in
  the triage Policy cell, and lenient backward-compatible diagnostics
  decoding. Release-gate Make recipes remain flag-free.
* Deterministic coverage: 25 policy tests (decoder conformance bounds and
  every validation rule) plus 4 agent integration tests
  (correction-then-success, correction-then-fail-closed, diagnostics-only
  recording, non-conforming fallback). The full suite passes 1,152 tests
  in 50 suites; `make eval-build` passes.

**Funded validation probe (pre-registered; authorized by the maintainer
2026-07-24 before any completion request, with latitude to iterate the
contract prompt and re-probe once if conformance falls below the 16/20
reporting threshold — cumulative probe spend capped at $3.00):** `make eval-db-cloud-agent MODEL=openai/gpt-5.5 REPEAT=1
MAX_CLOUD_COST_USD=1.50` on this branch — the pinned production model with
every policy in diagnostics-only mode, exercising the new structured
contract on all 20 cases with seeded semantic grading. Conjunctive
criteria: 20/20 complete results, transport 100%, structured parsing at
least 95%, zero eval and internal schema-agent timeouts. Reported (not
gated): structured-plan conformance rate on SQL terminals, plan-consistency
decision distribution, and the decision/semantic profile against the
retained comparator's same-case expectations. A conformance rate below
16/20 SQL terminals sends the contract prompt back for iteration before
any enforcement experiment. The follow-on candidate — Sol pin, trusted-SQL
bypass, 105-second margin, and `correctAndRetryExperimental` plan
consistency through the complete release gate — requires its own fresh
pre-registration and authorization after this probe's evidence is recorded.

**Probe outcome 2026-07-24 — passed; one authorized lenience improvement
applied:** run `.eval-results/20260724-085024-125` (pinned GPT-5.5,
$1.264485 of the $1.50 stage cap; cumulative probe spend $1.264485 of the
$3.00 authorization). 20/20 complete, transport 20/20, structured parsing
20/20, zero eval and internal schema-agent timeouts, P50 14,856 ms, P95
25,770 ms, max 27,606 ms. All 15 SQL terminals emitted conforming
structured plans; 13 evaluated consistent and 2 divergent, with the
decision and semantic profile at the retained comparator's single-repeat
expectation (6/20 end-to-end, clarification 4/4, 11 expected-SQL
clarification statuses unchanged in character). Both divergences were the
same contract-usage quirk rather than SQL drift: the model wrote a full
join description or an "as alias" phrase into the join `table` field, so
the evidence-binding rule could not match the actually-inspected table.
The authorized improvement extracts the leading qualified identifier from
the join table field before both join rules and skips entries without one;
deterministic tests reproduce both recorded shapes, and both recorded
divergences deterministically become consistent because their leading
identifiers name tables the acceptance gate had already verified. The
instruction text now asks for exact inspected table names in joins. With
every conjunctive probe criterion green and conformance at 100%, the
diagnostics-only infrastructure merges; enforcement stays behind the
follow-on candidate's own pre-registration.

## PR 58 — Clarification decision accuracy to 12/12

**Status: three funded attempts complete, negative; implementation ⏳ Not
done.** Commit `bfc4ea2` selectively enforced the existing high-confidence
`mustClarify` terminal decision; commit `b3b69fe` reverted it after the first
gate failed both criteria. Candidate `f356ba4` then fixed the identified
wording and terminal-less budget paths and reached 12/12, but commit `e13f6aa`
reverted it after the retained over-clarification guardrail failed. Candidate
`ddf4e12` implemented the evidence-narrow two-sided policy pre-registered
below and passed every offline check, but the complete funded gate failed both
criteria. Commit `5ee77da` reverted its behavior and candidate-only tests. The
frozen phrase heuristic set remains unchanged.

**Why:** The gate requires 100%; the retained PR 55 comparator and the
post-PR 59 retry both sit at 11/12. The earlier 9/12 experiment had three
operational misses, but the new sole miss was independent:
`preseason.top-wins-ambiguous` repeat 3 returned SQL without a timeout, budget
error, or app-side rejection. The latest candidate recovered that case in all
three repeats, but its narrower evidence gate did not recover two protected
budget misses and its SQL allowance moved none of the registered expected-SQL
controls.

**What next:** Add no product behavior yet. First obtain diagnostics-only,
redacted reason codes that distinguish why the exact anti-join terminal
responses failed the candidate's structured gate and why protected budget
evidence remained incomplete. A future policy must prove at least two genuine
false-clarification removals in deterministic replay while preserving all
protected cases. No new phrase heuristics — the PR 53 freeze stands.

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

**Offline candidate and pre-registration 2026-07-17:** Commit `ddf4e12`
implements a two-sided policy from the retained failure mechanics. Protected
metric recovery now requires the existing `mustClarify` metric decision plus
complete, subject-linked exact-search, described-table, exposed-column, and
foreign-key evidence. A clean terminal SQL response can be converted to that
clarification only when exactly one protected metric remains unresolved. The
terminal-less path is limited to a standalone initial request with exactly six
successful schema calls followed by a rejected seventh call, no inspection
calls, default policy modes, and the same evidence/intent agreement; it never
invokes an eighth call. Existing context or confirmed semantic bindings that
define the metric close this branch.

The SQL side is independently limited to an actual clean terminal response
whose two referenced tables form one exact exposed foreign-key `LEFT JOIN`,
with no join modifiers and one positive non-nullable joined-side `IS NULL`
filter. The request must bind the retained and excluded entities to the
correct join sides, and every other meaningful grounded request concept must
bind to that anti-join trigger or those endpoints. Unrelated, schema-only, and
protected-metric-only search overlap does not count as question-relevant
evidence. This uses the existing vocabulary and adds no phrase list, prompt
pressure, triage rule, scorer rule, or golden change.

The registered expected movements are all three
`saas.users-without-membership` repeats from clarification to SQL, taking the
raw expected-SQL-to-clarification count from 33 to 30 and, if all other
outcomes stay fixed, the exclusive bucket from 30 to 27. The registered
protected outcomes are clarification for all four ambiguity cases across all
three repeats, including the historical terminal-SQL miss and the exact
six-success/rejected-seventh-call miss. Defined-metric, confirmed-binding,
ungrounded, incomplete-evidence, unrelated-relationship, terminal
clarification, terminal-less ordinary failure, cancellation, stale-schema,
timeout, trailing-batch, attempted-eighth-call, routing, validation, scorer,
and triage controls must not move. The retained comparator is PR 55 at 11/12
clarification decisions and 28 exclusive false clarifications; the negative
`f356ba4` comparator is 12/12, raw 33, and exclusive 30.

Acceptance remains conjunctive: the complete private-routing 60-result,
three-repeat gate for requested `openai/gpt-5.5` and expected canonical
`openai/gpt-5.5-20260423` must produce 12/12 clarification decisions and an
exclusive expected-SQL-got-clarification bucket no higher than 28, with a
target below 28. The reduction must be a real decision change rather than triage-precedence
movement. Safety, schema validity, and PostgreSQL verification must remain
100% on evaluated SQL, and private routing, requested/canonical/routed-model
verification, structured parsing, forbidden bindings, repair progress,
timeouts, and six-call tool-budget behavior must not regress. Semantic
accuracy remains informational. If either PR 58 criterion fails, revert
`ddf4e12` behavior and candidate-only tests, retain only sanitized evidence
and roadmap notes, and leave PR 58 not done. Retain the candidate and mark PR
58 done only if every criterion passes.

The maximum newly authorized spend requested for that gate was **$4.00**.
Historical authorization did not carry forward. Before authorization, offline
results were: the four core policy/validator/agent suites passed 407/407; the
focused ten-suite matrix passed 565/565; `make project` regenerated identical
tracked output; `make test` recorded 1,162 total, 1,120 passed, 42 skipped, and
0 failed in the result bundle; `make eval-build` passed; and
`git diff --check` passed.

**Third funded outcome 2026-07-18 — negative, behavior reverted:** The fresh
$4 authorization was granted after that pre-registration. The first gate
process was interrupted when review confirmed that the runner's dollar limit
is checked only between cases. Provider usage was reconciled, all interrupted
results were resumed rather than rerun, and reduced cumulative runner ceilings
left a reserve for the between-case boundary. The final complete gate used a
conservatively accounted **$3.286685**, below authorization, and evaluated
commit `820f197`, whose parent contains candidate `ddf4e12`.

| Mechanical criterion | Retained PR 55 comparator | Third PR 58 attempt | Result |
| --- | ---: | ---: | --- |
| Clarification decisions | 11/12 | 10/12 | Fail (required 12/12) |
| Exclusive expected-SQL clarification bucket | 28 | 31 | Fail (required `<= 28`) |
| Raw expected-SQL-to-clarification decisions | 33 | 33 | Fail (required genuine reduction by at least 2; target 30) |
| Registered membership controls moved to SQL | - | 0/3 | Fail (expected 3/3) |
| Semantic end to end | 19/60 | 18/60 | Informational |

`preseason.top-wins-ambiguous` clarified correctly in all three repeats, as
did the other six protected best-customer and important-cluster results.
`saas.healthy-accounts` clarified only once: repeats 1 and 3 ended as
tool-budget generation failures after seven schema-tool records, so protected
clarification accuracy was 10/12. All three
`saas.users-without-membership` repeats still clarified. The raw false-
clarification count therefore stayed at 33; triage precedence assigned two
`saas.active-users-by-org` false clarifications to the tool-budget category,
leaving 31 in the exclusive bucket. The registered SQL recovery produced no
movement, and the exclusive result did not hide a genuine reduction.

The run completed 60/60 with 0 missing, 0 budget-skipped, and 0 provider-
budget-unavailable results. Safety, schema validity, and PostgreSQL
verification were 15/15; transport was 60/60; repeated/no-progress repairs,
model/tool protocol failures, missing or malformed terminal results, internal
schema-agent timeouts, and timeout/cancellation classifications were all 0.
The exclusive tool-budget category was 4: two active-user false
clarifications and the two healthy-account generation failures. The committed
sanitized report does not publish separate aggregate latency, forbidden-
binding, returned/routed-model, or global interception totals, so prior-run
values are not reused.

Both conjunctive PR 58 criteria failed. Commit `5ee77da` mechanically reverted
all `ddf4e12` behavior and candidate-only tests, restoring those 12 files to
`origin/main` while retaining the pre-registration, sanitized reports, and
this negative evidence. The six-call budget, PR 53 freeze, private and
canonical/routed-model enforcement, safety/schema/PostgreSQL validation,
structured parsing and deterministic review, PR 59 timeout/budget/
interception behavior, PR 60 workflow, PR 62 hardening, and the absence of the
PR 56 bypass remain unchanged. PR 58 is not done.

Post-revert validation passed: the same focused ten-suite matrix recorded 527
total, 527 passed, 0 skipped, and 0 failed; `make project` regenerated
identical tracked output; `make test` recorded 1,124 total, 1,082 passed, 42
skipped, and 0 failed; `make eval-build` passed; and `git diff --check`
passed.

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

**Status: Funded negative 2026-07-24; pin reverted, evidence retained.**

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
* Semantic end-to-end at least 20/60. The rollover floor is 19/60, but a
  model swap follows the PR 55 incremental promotion precedent (GPT-5.6
  Terra was not promoted despite clearing the floor), so the candidate must
  strictly exceed the retained 2026-07-10 comparator's 19/60.
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

**Spend plan (authorized 2026-07-24):** total branch cap $5.00, smoke
allocation $0.50 for `make eval-openrouter-smoke MODEL=openai/gpt-5.6-sol
REPEAT=3`, one-case overrun reserve $0.10, and a full-gate cumulative
ceiling of $4.00 for `make eval-release-triage MODEL=openai/gpt-5.6-sol`,
sized against the $3.276305 and $3.521450 prior full-gate costs. The
maintainer explicitly authorized this cap on 2026-07-24 before any
completion request. After the smoke, the full-gate ceiling stays $4.00 only
while actual smoke spend plus $4.00 plus the $0.10 reserve remains within
the $5.00 branch cap; otherwise it shrinks to fit. `ALLOW_MODEL_OVERRIDE`
stays unset so the gate exercises the production alias contract.

**Smoke result 2026-07-24 — passed:** `make eval-openrouter-smoke
MODEL=openai/gpt-5.6-sol REPEAT=3 MAX_CLOUD_COST_USD=0.50` completed 15/15
with transport 15/15, structured parse 15/15, strictJSONSchema on every
call, zero retries, returned model `openai/gpt-5.6-sol` verified on all 15
completions, single ZDR provider, and $0.156745 spend against the $0.50
allocation (P50 2,654 ms, P95 4,380 ms). Static-shape was 9/15 with the
same two legacy-agent cases missing as the recorded 2026-06-25 GPT-5.5
smoke (also 9/15, $0.181115), so decision behavior matches the incumbent's
known smoke profile. Remaining full-gate ceiling stays $4.00: $0.156745
smoke plus $4.00 plus the $0.10 reserve is within the $5.00 branch cap.

Passing restores the existing beta cloud path on GPT-5.6 Sol. It does not
satisfy the separate 90% semantic production-readiness gate and does not
authorize removing beta wording.

**Full-gate outcome 2026-07-24 — negative, pin reverted:** the complete
`make eval-release-triage MODEL=openai/gpt-5.6-sol` run (60/60 results,
commit `729755a`, run `.eval-results/20260724-040546-370`, recorded in
`docs/evals/0.1.0.md` and `docs/evals/0.1.0-triage.md`) failed two of the
pre-registered conjunctive criteria, so candidate `27ed6a0` was reverted in
`3a653f5` and `openai/gpt-5.5` remains the retained pin:

* Exclusive expected-SQL clarification was 31 against the ceiling of 28.
* Internal schema-agent timeouts were 1 against the required zero: one
  `saas.users-without-membership` repeat ended as a `generationFailure`
  after four schema-tool calls, the same failure class that rejected the
  PR 56 bypass retry.

Every other criterion passed: semantic end-to-end 22/60 (above both the
19/60 retained comparator and the amended 20/60 promotion bar),
clarification decisions 12/12, semantic-mismatch triage 5 (retained
comparator 6), tool-budget triage 1 (ceiling 6), static schema failures 0,
safety and schema validity 15/15 evaluated SQL, PostgreSQL verification
failures 0, transport 60/60, structured parsing 59/60 (98.3%), forbidden
bindings 0, repeated/no-progress repairs 0, eval timeouts 0, and the
returned model verified as `openai/gpt-5.6-sol` on all 60 completions via
one ZDR provider with canonical enforcement active.

Reported per the pre-registration: gate cost $2.941500 ($0.049025 per
result, below the retained $0.058690833 comparator), latency P50 12,087 ms,
P95 66,390 ms, maximum 94,735 ms; cumulative branch spend $3.098245
($0.156745 smoke plus $2.941500 gate), within the $4.00 gate ceiling and
the $5.00 branch authorization.

Standing read for any retry: GPT-5.6 Sol's failure profile is almost
entirely over-clarification, not SQL quality — it reached 12/12
clarification accuracy, which three funded PR 58 attempts could not, and
nearly halved the per-result cost, but falsely clarified 31 expected-SQL
results. A future candidate pairing the Sol pin with an over-clarification
remedy (or evaluating `gpt-5.6-sol-pro`) requires a fresh pre-registration
and new spend authorization, and must not weaken fail-closed behavior.

## PR 64 — Trusted schema-tool SQL with GPT-5.6 Sol Pro

**Status: Funded negative at stage 2 on 2026-07-24; candidate reverted,
evidence retained, $7.14 of the $9.00 authorization unspent.**

**Why:** The PR 63 gate produced the diagnostics-only evidence that the
exclusive expected-SQL clarification bucket is not model behavior. All 31
false clarifications in the Sol run — and all 28 in the retained GPT-5.5
comparator — carry a terminal agent decision of `sql` with a complete query
plan; the grounded regeneration step then discards that SQL and emits a
clarification. The PR 56 bypass demonstrated the fix on GPT-5.5 (bucket
28 to 5, semantic 19 to 26) and was rejected twice solely on single
90-second wall-clock timeouts (91.0 s and 93.7 s), a flake class GPT-5.6
Sol also recorded once (its slowest completed case ran 94.7 s). Sol
additionally showed the strongest decision profile yet measured: 12/12
clarification decisions and a semantic-mismatch bucket of 5 with no
behavior change.

**What:** Branch `sol-pro-trusted-sql-gate`, three independently
revertable commits on top of the PR 63 evidence:

1. Cherry-pick of `bcaf957` (`fix: trust validated schema tool sql`) — the
   exact twice-gated PR 56 bypass patch; its validator and pipeline suites
   pass unchanged against current helpers.
2. Production pin `openai/gpt-5.6-sol-pro` (canonical
   `openai/gpt-5.6-sol-pro-20260709`, display "GPT-5.6 Sol Pro"), priced
   identically to GPT-5.5 and GPT-5.6 Sol ($5/M prompt, $30/M completion),
   with the same Makefile, fixture, and current-state doc updates as PR 63.
3. `wallClockTimeoutSeconds` default 90 to 105: every observed genuine
   completion killed by the 90-second deadline (91.0/93.7/94.7 s) finishes
   inside 105, which still leaves a 15-second validation-repair margin
   inside the unchanged 120-second eval case budget. Timeouts still fail
   closed; the zero-internal-timeout criterion is unchanged.

**Pre-registered acceptance criteria (conjunctive, unchanged from PR 63
plus the PR 56 bypass-specific floors):** 60/60 complete; semantic
end-to-end at least 20/60; clarification decisions at least 11/12;
exclusive expected-SQL clarification at most 28; tool-budget triage at
most 6; static schema failures at most 1; safety, schema, and PostgreSQL
verification at 100% of evaluated SQL; transport and structured parsing at
least 95%; zero forbidden bindings, repeated/no-progress repairs, eval
timeouts, and internal schema-agent timeouts; private routing plus
requested/routed/canonical verification on every completion. Report
cumulative branch spend, per-result cost, P50/P95/max latency, and every
triage bucket. Any failed criterion reverts the candidate commits and
records the negative result.

**Staged spend plan (authorized by the maintainer 2026-07-24 before any
completion request, $9.00 branch cap total):**

1. Sol Pro transport smoke, $0.50 allocation:
   `make eval-openrouter-smoke MODEL=openai/gpt-5.6-sol-pro REPEAT=3`.
   Abort the branch if transport, parsing, routing verification, or the
   canonical pin fail.
2. Focused semantic probe, $3.00 ceiling: the ten historical
   over-clarification cases, three repeats, seeded semantic grading, on
   the candidate. Proceed to the full gate only if the released SQL
   semantically passes at least 15/30 with zero internal timeouts.
3. Full pinned gate, $4.50 cumulative ceiling:
   `make eval-release-triage MODEL=openai/gpt-5.6-sol-pro`.
4. $1.00 unallocated reserve inside the $9.00 cap; stage ceilings shrink
   if earlier stages overrun so the branch cap holds.

No completion request before the cap is explicitly authorized;
`ALLOW_MODEL_OVERRIDE` stays unset for gate publication.

**Stage 1 outcome 2026-07-24 — Sol Pro disqualified on cost and latency;
candidate repinned to GPT-5.6 Sol before any stage 2 spend:** the Sol Pro
smoke (`.eval-results/20260724-045102-415`) hit its $0.50 allocation at 12
of 15 results ($0.529960). Everything evaluated was operationally clean —
transport 12/12, structured parse 12/12, zero retries, returned model
verified `openai/gpt-5.6-sol-pro` on all 12 via one ZDR provider — and the
static-shape profile matched the incumbent's known smoke fingerprint. But
Sol Pro consumed 94,625 tokens for 12 results versus Sol's 23,659 for 15
(5.0x tokens and 4.2x cost per identical case: $0.044163 versus $0.010450)
at 1.6x the latency (P50 4,355 ms versus 2,654 ms). Projected to the full
pipeline that is a $12-15 gate — outside the remaining $8.47 authorization
on its own — and a latency tail that projects past the 105-second deadline,
the exact flake class this candidate exists to eliminate. Under the
original cost-comparability rule and the branch cap, Sol Pro fails stage 1;
`9a3b08b` repinned the candidate to `openai/gpt-5.6-sol` (canonical
`openai/gpt-5.6-sol-20260709`), whose full-gate economics ($2.941500,
$0.049025 per result), tail latency (maximum 94.7 s, inside the 105-second
deadline), and decision profile (12/12 clarification, semantic-mismatch
bucket 5) are already measured. Remaining stages run on Sol with ceilings
restated inside the $9.00 cap: focused probe $2.00, full gate $4.50
cumulative, reserve $1.97 after the $0.53 stage 1 spend.

**Stage 2 outcome 2026-07-24 — negative; candidate reverted without a full
gate:** the focused probe (`.eval-results/20260724-045437-557`, 30/30
complete, $1.334325, P50 11,728 ms, P95 18,309 ms, zero internal
schema-agent timeouts, transport and parsing 30/30) ran the ten historical
over-clarification cases with the trusted-SQL bypass active on the Sol pin.
The bypass mechanically eliminated the false-clarification failure mode:
only 3 of 30 results still clarified, versus 30 of 30 for these cases in
the retained comparator. But the released SQL passed the seeded semantic
comparison in only 3 of 30 results against the pre-registered floor of 15,
with the 24 mismatches dominated by the known projection-shape class (18
`wrong projected columns` rows) that PR 56 first exposed on GPT-5.5. The
go/no-go rule therefore stopped stage 3, and `f16c9e8` reverted the four
candidate commits (`043afa7` bypass, `76d0fcb`/`9a3b08b` pins, `703afae`
timeout margin). Total plan spend $1.864285 of $9.00; no further paid run
under this authorization.

**Standing read:** the exclusive expected-SQL clarification bucket is now
fully explained end to end. The agent produces terminal SQL on every one of
those results; the grounding step discards it; and that discarded SQL is
not gate-passing — it computes plausible answers with the wrong projected
column sets. Releasing it converts useless clarifications into confidently
wrong-shaped results and cannot clear the gate on its own, on either
GPT-5.5 (26/60 ceiling across two funded bypass gates) or GPT-5.6 Sol
(3/30 on the released set). This reconfirms the PR 52/54/56 conclusion
that stable query planning / deterministic projection synthesis (PR 57) is
the accuracy lever, now with model-independent evidence. Two separately
actionable follow-ups fall out of the evidence: (1) the 105-second
wall-clock margin remains justified by three recorded genuine completions
killed at 90 seconds and can proceed as its own diagnostics-backed PR;
(2) whether the semantic comparator should accept supersets of the
required projected columns is a product-contract decision — required-column
coverage has measured 100% while `wrong projected columns` dominates every
bypass mismatch bucket — and would need its own pre-registered evaluation
if the maintainer chooses to relax it.

**Offline superset re-score 2026-07-24 — the comparator question is
answered; superset tolerance is not the lever:** a zero-completion-cost
re-scorer (`.context/rescore/rescore.py`) re-provisioned the committed
seeded fixtures on local PostgreSQL and re-executed the recorded golden and
candidate SQL for all 42 executed results across the stage 2 probe and the
PR 63 full gate. Method calibration was exact: the strict re-score
reproduced the recorded semantic verdict 42/42 and the recorded mismatch
subcategory 29/29, and reproduced all 26 recorded result digests. An
independent adversarial pass with a separate Swift-faithful comparator
confirmed every number. Under a superset-tolerant policy (candidate may
project extra columns beyond the golden's required set, all other
semantics unchanged), only 4 of the 29 result mismatches recover:
`support.unclustered-feedback` (all three probe repeats) and
`preseason.active-match-configs` repeat 1. The remaining failures are
genuine: 22 records miss required columns outright or rename them outside
the golden alias lists (name projected where email is required,
`average_paid_order_value`-style aggregate aliases, omitted `slug`), two
return row supersets (4 rows against a golden 2 on
`saas.expiring-subscriptions`), and one is a value mismatch. Conclusion:
the discarded terminal SQL fails for substantive reasons, not comparator
strictness. Relaxing projection matching would recover about 14% of the
mismatch bucket and cannot clear the gate; the levers remain deterministic
projection/planning synthesis (PR 57) and, narrowly, whether specific
near-miss aggregate aliases belong in the golden alias lists — a golden
change that must be justified case by case, never as bulk loosening to fit
observed model output.

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
