# Next Development Steps

Follow-up PRs after the PR 55 branch (pinned OpenRouter profile, private
routing, canonical-version enforcement, release-gate hardening) merges to
`main`. Numbering continues from `docs/refactoring-plan.md`.

## Where things stand

* The product path is fixed: OpenRouter schema-tool agent, pinned
  `openai/gpt-5.5` (canonical `openai/gpt-5.5-20260423`), zero-data-retention
  routing, fail-closed canonical checks in the app and in pinned-model evals.
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
(pinned model, ~$1.5–3.5), and apply the same pre-registered criteria:
merge only if semantic pass exceeds 19/60 (the HEAD baseline) with 100%
safety/schema validity, at least 95% transport, and zero repeated repairs.
Otherwise revert again and record the negative result here and in the
refactoring plan.

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
date anchors — all referencing schema-tool evidence IDs). For a closed set of
plan shapes that dominate the suite (grouped aggregate + order + limit,
anti-join "without", anchored date-window filters, distinct counts), compile
the plan to SQL deterministically in the app and prefer the compiled SQL when
the plan is complete; fall back to the model's SQL otherwise. This is
synthesis from the model's own structured plan over inspected schema
evidence — not a natural-language parser — which keeps the "no second
database engine" principle intact.

**Acceptance:** Semantic mismatch bucket strictly below 24 and semantic pass
at or above 30/60 on the full gate, with safety/schema at 100% and no growth
in wrong-decision or tool-budget buckets. Deterministic unit tests for the
plan decoder and each compiled shape; unsupported plans must fall back, never
error.

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

**Why:** 6 HEAD full-gate results die on the four-call schema-tool budget,
concentrated in saas status/filter cases.

**What:** Measure before changing: from triage, classify whether exhaustion
comes from repeated identical calls (fix: serve repeated `describe_tables`
from the evidence ledger without consuming budget), scattered exploration
(fix: prompt guidance on budget), or genuinely needing a fifth call (fix:
raise the budget for multi-table questions only, with cost/latency measured).

**Acceptance:** Bucket at or below 4 on the full gate with per-case cost and
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
branch already fail loudly; this PR is about hearing it first.

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
