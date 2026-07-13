# Next Development Steps

Follow-up PRs after the PR 55 branch (pinned OpenRouter profile, private
routing, canonical-version enforcement, release-gate hardening) merges to
`main`. Numbering continues from `docs/refactoring-plan.md`.

## Where things stand

* The product path is fixed: OpenRouter schema-tool agent, pinned
  `openai/gpt-5.5` (canonical `openai/gpt-5.5-20260423`), zero-data-retention
  routing, fail-closed canonical checks in the app and in pinned-model evals
  (with one forced-refresh recovery so a stale cache cannot fail a freshly
  updated app). Release-gate/triage doc publication is pin-enforced in both
  the Makefile and the eval CLI (`--allow-model-override` to opt out).
* The release gate still fails, so text-to-SQL stays beta. The complete
  2026-07-10 gate at HEAD (pinned GPT-5.5, private routing, canonical
  enforcement, $3.18): 19/60 semantic, 11/12 clarification accuracy, 100%
  safety/schema, 60/60 transport, 0 repeated repairs.
* Failure buckets at HEAD, largest first: host-side false clarification
  (28 — the model returned SQL in every one; the legacy grounder discarded
  it), semantic result mismatch (6), tool budget exhausted (6),
  clarification accuracy (1/12 short). The June 24/60 baseline ran with
  PR 16 enforcement that PR 52 later defaulted off, which is why the
  wrong-decision bucket returned to its pre-PR 16 level.
* Standing conclusions to respect: the intent-coverage phrase heuristics are
  frozen (PR 53); more force-SQL prompt pressure does not help (PR 52); the
  next accuracy lever is stable query planning / deterministic synthesis
  (PR 52/54 conclusions); PR 10 embeddings stay deferred because retrieval
  already hits 100% required-table recall.

## Recommended order

1. PR 56 — now the main accuracy lever: the 28-case false-clarification
   bucket is exactly what the bypass addresses
2. PR 57 against the post-PR 56 triage (semantic mismatch is only 6 at HEAD;
   confirm it is still worth the build before starting)
3. PR 58 and PR 59 against fresh triage
4. PR 60 and PR 61 are independent and can land anytime

---

## PR 56 — GPT-5.5 grounding-bypass full-gate experiment

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

**Expectations:** High since the 2026-07-10 HEAD gate: 28 of 60 results are
valid model SQL discarded by the host grounder, which is precisely the path
the bypass trusts. Some converted results will land as semantic mismatches
instead (Terra showed that pattern), but that bucket is only 6 at HEAD.
Alternative worth considering in the same PR: instead of the bypass,
re-enable PR 16's over-clarification enforcement that PR 52 defaulted off —
the June 24/60 baseline shows that configuration held the bucket at 3.

## PR 57 — Plan-then-compile SQL synthesis for covered shapes

**Why:** Semantic result mismatch was the dominant bucket (~24/60) before
the PR 55 hardening gate; at HEAD it is 6, and it will likely grow again
once PR 56 stops discarding model SQL. Re-triage after PR 56 before
committing to this build. PR 54
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

**Acceptance:** Semantic mismatch bucket shrinks against the post-PR 56
triage baseline with safety/schema at 100% and no growth in wrong-decision
or tool-budget buckets. Deterministic unit tests for the plan decoder and
every validation rule; plans that do not fit the contract must fall back to
current behavior, never error.

**Do not change:** eval goldens, seeded data, backend defaults, privacy
routing, frozen heuristics.

## PR 58 — Clarification decision accuracy to 12/12

**Why:** The gate requires 100%; the HEAD gate sits at 11/12.

**What:** Triage the two failing ambiguity cases from the freshest gate run,
then fix the specific decision behavior (prompt guidance or clarification
policy fidelity for those ambiguity classes). No new phrase heuristics — the
PR 53 freeze stands.

**Acceptance:** 12/12 clarification decisions across three repeats without
increasing the expected-SQL-got-clarification bucket above 3.

## PR 59 — Tool-budget exhaustion bucket

**Why:** 6 HEAD full-gate results exhaust the schema-tool call budget
(production default: `maximumSchemaToolCalls = 6`), concentrated in saas
status/filter cases.

**What:** Re-derive the failure mechanics from fresh traces before touching
anything — earlier assumptions have gone stale once already: the budget is
six calls, not four, and repeated identical tool calls are already
intercepted with a correction response before invocation. From the traces,
classify whether exhaustion comes from scattered near-duplicate exploration
(distinct arguments that add no evidence), from genuinely broad questions,
or from correction turns burning budget, then fix that specific mechanism
with cost/latency measured.

**Acceptance:** Bucket at or below 3 on the full gate with per-case cost and
p95 latency no worse than 15% over baseline.

## PR 60 — Canonical-version watch and rollover runbook

**Why:** The app fails closed if OpenRouter rolls `openai/gpt-5.5` to a new
canonical version; users then need an app update. Today nothing warns the
team before users hit it.

**What:** A scheduled check (CI cron) that fetches the OpenRouter catalog and
compares `canonical_slug` for the pinned model against
`OpenRouterCatalog.productionProfile.expectedCanonicalModelID`; on drift it
opens an issue. Add a rollover section to `docs/release.md`: run the release
gate on the new canonical, update the profile constant, ship a Sparkle
release. The in-app pre-flight and eval-side enforcement from the PR 55
branch already fail loudly (after one self-healing cache refresh), and
Settings warns when the catalog canonical has rolled; this PR is about the
team hearing it before users do.

## PR 61 — Second vetted model in the allowlist

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

Deferred quality cleanups surfaced by the PR 55 review passes; none block the
merge and none change behavior:

* `OpenRouterProviderPreferences` is now a vacuous singleton struct (every
  value is fixed) — collapse it to a caseless enum with statics, and move
  `OpenRouterCatalog.privateRoutingClaim` next to it so the routing mechanism
  and the user-facing privacy claim live in one place.
* `refreshOpenRouterCatalog` repeats the guard/spinner boilerplate across
  three `MainActor.run` blocks, and its cancellation branch silently keeps
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
