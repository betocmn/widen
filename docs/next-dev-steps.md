# Next Development Steps

Follow-up PRs after PR 55 (pinned OpenRouter profile, private routing,
canonical-version enforcement, release-gate hardening) merges to `main`.
Numbering continues from `docs/refactoring-plan.md`.

## Completed and remaining work

* ✅ **Done — PR 56 experiment:** restored the trusted
  schema-tool SQL bypass, ran the complete pinned GPT-5.5 gate, applied every
  pre-registered criterion, published sanitized evidence, and reverted the
  bypass after it missed the clarification floor. The experiment is complete;
  the bypass is not part of the final product diff.
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
  no longer consume the six-call budget, which stays at six. The bucket-size
  acceptance still needs the next funded full gate.
* ⏳ **Not done:** a PR 56 retry, structured plan validation or compilation,
  clarification behavior changes, canonical rollover monitoring, a second
  model, and cleanup work.

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
  2026-07-13 PR 56 experiment (pinned GPT-5.5, private routing, canonical
  enforcement, $3.276305) reached 22/60 semantic but only 9/12 clarification
  decisions. Safety/schema stayed 41/41, transport was 60/60, structured
  parsing was 57/60, and forbidden bindings and repeated repairs were zero.
  The reported eval-timeout status was zero, but one 91-second schema-agent
  timeout surfaced as a parse failure. Because clarification missed the
  pre-registered 11/12 floor (and a strict any-timeout reading also fails),
  the grounding bypass is rejected and reverted in the following commit.
* The experiment moved primary failure buckets from the 2026-07-10 comparator
  as expected but too aggressively: expected-SQL clarification fell 28 -> 5,
  while semantic mismatch grew 6 -> 28; tool-budget triage moved 6 -> 5 and
  static schema failure 1 -> 0. The five remaining wrong SQL decisions were
  not trusted grounding candidates: four terminal SQL results were rejected
  by deterministic validation, and one was an explicit model clarification.
* The clarification shortfall was operational, not evidence for new phrase
  rules. Two `saas.healthy-accounts` repeats genuinely exhausted the six-call
  schema-tool budget. One `preseason.top-wins-ambiguous` repeat timed out after
  91 seconds before any tool call but was grouped into the same redacted
  triage bucket; that classification/observability gap belongs in PR 59.
* Standing conclusions to respect: the intent-coverage phrase heuristics are
  frozen (PR 53); more force-SQL prompt pressure does not help (PR 52); the
  next accuracy lever is stable query planning / deterministic synthesis
  (PR 52/54 conclusions); PR 10 embeddings stay deferred because retrieval
  already hits 100% required-table recall.

## Recommended order

1. ✅ Done — PR 59 budget/timeout fix: pre-tool timeouts are now classified
   and reported separately from genuine six-call exhaustion, redundant
   schema-tool exploration is deterministically intercepted without burning
   budget, and the six-call limit is unchanged
2. Retry PR 56 next; the bypass remains experimental because the complete
   run missed 11/12, and that gate run doubles as the PR 59 acceptance
   measurement (tool-budget bucket at or below 3 with cost and p95 latency
   within 15% of baseline)
3. If a retry clears every PR 56 criterion, PR 57 becomes the next accuracy
   lever: semantic mismatch was the largest fresh actionable bucket at 28
4. PR 58 only if clarification remains independently below 12/12 after the
   budget/timeout cases are fixed; PR 60 and PR 61 remain independent

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
timeouts all stay at zero. Otherwise revert again and record the negative
result here and in the refactoring plan.

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

## PR 57 — Plan-then-compile SQL synthesis for covered shapes

**Status: ✅ Done — re-triage only.** The implementation has not started and
remains conditional on a future PR 56 retry passing every promotion criterion.

**Why:** Semantic result mismatch was 6 on the retained PR 55 behavior and
grew to the largest experimental bucket, 28, when PR 56 stopped discarding
model SQL. Because PR 56 was rejected and reverted, treat 28 as evidence for
the next passing bypass iteration, not as the current product baseline. PR 54
added a redacted `query_plan` to the terminal contract as diagnostics; PR 52
concluded the fix is stable query-plan and SQL-shape generation, not more
prompt pressure or phrase heuristics.

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

**Status: ✅ Done — re-triage only.** No clarification behavior or frozen
phrase heuristic changed. Revisit only if clarification remains independently
below 12/12 after PR 59.

**Why:** The gate requires 100%; the retained PR 55 comparator sits at 11/12.
The PR 56 experiment fell to 9/12, but all three misses were operational
(two genuine tool-budget exhaustions and one pre-tool timeout), so PR 58 is
not the next fix unless clarification remains low after PR 59.

**What:** After PR 59, rerun the clarification cases and triage only failures
that remain independently of budget or timeout behavior. Fix the specific
decision behavior (prompt guidance or clarification policy fidelity for those
ambiguity classes). No new phrase heuristics — the PR 53 freeze stands.

**Acceptance:** 12/12 clarification decisions across three repeats without
increasing the expected-SQL-got-clarification bucket above 3.

## PR 59 — Tool-budget exhaustion bucket

**Status: ✅ Done.** The trace diagnosis separated four genuine six-call
exhaustions from one misclassified pre-tool timeout, and the budget/timeout
fix landed in commits `47d6ad1`, `2b28900`, and `551ce3e`. The six-call
budget is unchanged; the bucket-size acceptance below still needs the next
funded full gate.

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
  of being intercepted. After the fixes the focused agent and eval-planning
  suites pass and `make test` passes 1,105 tests in 49 suites.

The acceptance criterion (bucket at or below 3 with per-case cost and p95
latency within 15% of baseline) requires a complete pinned gate. Per the
standing spend rule no paid evaluation was run here; measure it on the next
funded gate, which the PR 56 retry comparator provides.

## PR 60 — Canonical-version watch and rollover runbook

**Status: ⏳ Not started.**

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

## PR 61 — Second vetted model in the allowlist

**Status: ⏳ Not started.**

**Why:** Accounts whose OpenRouter provider policies hide GPT-5.5's
ZDR endpoints currently have no cloud path; the allowlist was always meant to
grow once evaluation capacity allowed.

**What:** Evaluate one fallback candidate (Claude Sonnet 5 tied Terra in the
original focused bake-off; re-survey current models first) through the full
release gate under identical private routing. Add it to the profile list only
if it meets or beats the pinned baseline on semantic pass with all hard gates
green. Settings picker grows to two vetted entries, each with its own
canonical pin; eval defaults stay on the primary.

## PR 62 — PR 55 hardening cleanups

**Status: ⏳ Not started.**

Deferred quality cleanups surfaced by the PR 55 review passes; none block the
merge and none change behavior:

* `OpenRouterProviderPreferences` is now a vacuous singleton struct (every
  value is fixed) — collapse it to a caseless enum with statics, and move
  `OpenRouterCatalog.privateRoutingClaim` next to it so the routing mechanism
  and the user-facing privacy claim live in one place.
* `refreshOpenRouterCatalog` repeats the guard/spinner boilerplate across
  three `MainActor.run` blocks, and its cancellation path silently keeps
  the previous status message — compute one result value and finish in a
  single block.
* The three connectivity-check canonical tests are ~25-line near-clones
  (extract a run helper), and the tool-chat parser canonical tests hand-build
  fixtures that the file's `assistantToolCalls`/`toolCall` helpers already
  cover once they take a `model` parameter.
* Pre-existing, user-initiated-only inefficiency: `testModel()` invalidates
  the cache (with a disk write) immediately before the connectivity check
  force-refreshes anyway.
* During a live canonical rollover, each cache-served generation pays one
  invalidate + catalog refetch before failing closed (bounded, but a
  confirmed-mismatch memo on the catalog service could re-verify once per
  TTL instead of once per generation). Network-fresh mismatches already skip
  the refetch.
* Micro-cleanups from the third review pass: `TextToSQLReleaseGateModelPolicy.Violation.pinnedModel`
  can be computed instead of stored; the one-line `redactedProviderMessage`
  wrapper in `ReleaseGateReporter` can be inlined; `validatedCapabilitiesForGeneration`'s
  duplicated preflight calls could collapse into a two-iteration loop; the
  `RESUME_MODEL_ARGS` make expression could become an explicit `ifeq` block.

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
