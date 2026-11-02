# How we gate text-to-SQL releases

Widen's text-to-SQL is labeled beta because it has not passed our release
gate. This page explains what the gate measures, why the model is pinned, and
what happens when an experiment fails.

## The release gate

`make eval-release` runs a 20-case suite three times (60 results) through the
Particle-1 schema-tool agent the app uses, with seeded Postgres semantic
grading: each candidate query executes against a synthetic fixture database
and its result set is compared to a hand-written golden query's. Some app
paths are left out; see
[What the gate does not measure](#what-the-gate-does-not-measure). The gate
passes only if all of the following hold:

| Criterion | Required |
| --- | --- |
| Complete evaluation | 60/60 results |
| End-to-end semantic pass rate | >= 90% |
| Safety validity | 100% of evaluated results |
| Schema validity | 100% of evaluated results |
| Clarification decision accuracy | 100% of evaluated results |
| Transport reliability | >= 95% |
| Repeated/no-progress repair failures | 0 |

("Clarification" means that when a question is ambiguous, the model should ask
a follow-up question instead of guessing at SQL.)

Particle-1 failed the 0.2.0 gate on end-to-end semantic pass rate (25/60)
and clarification decision accuracy (11/12), so text-to-SQL stays beta and is
not described as production-ready. The previous OpenRouter GPT-5.5 profile
failed the 0.1.0 gate on semantic pass rate. The committed gate report for
each release lives in [docs/evals/](.). The [0.2.0 regression check](0.2.0-regate.md)
passed its pre-registered limits against the previous Particle-1 baseline;
that permits the beta release and does not establish production readiness.

### What the gate does not measure

- **Execution repair.** When a query fails against your database, the app can
  send the error to Particle-1 for a fix. The gate grades each result's final
  SQL but never sends an execution failure back for repair.
- **Data inspection.** The eval builds the agent with no inspection policy and
  no schema fingerprint, so the gate never offers the tools that read row
  counts, column statistics or values, and never runs the check that the
  schema did not change during generation.
- **Session titles.** The gate sends no title request.

A passing gate says nothing about these paths.

## Pinned model and identity check

- The app requests `particle-1`. Users cannot select another model; changing
  the model requires a new app release that passed the gate.
- Every completion must report `particle-ai/particle-1`. A missing or
  different model name fails the request, and Widen discards the response
  rather than use an unevaluated model.
- Particle publishes no dated snapshots, so that check verifies the model name
  only. Particle can change the model behind the name without a Widen release,
  and Widen cannot detect it. Instead of version pinning, the gate is rerun
  before each minor release and whenever a model change is announced or
  observed ([re-gate procedure](../release.md#particle-model-change-and-re-gate)).
- Particle states it keeps no inference data by default. That is Particle's
  policy, not something Widen enforces: Particle's API has no per-request
  routing or retention setting, so Widen sends none.

## Pre-registered experiments, published negatives

Pipeline changes are pre-registered: acceptance criteria are written down
before the paid gate run, and the criteria are conjunctive — one miss rejects
the whole candidate. Rejected candidates are reverted from the product; the
sanitized evidence stays published.

### Particle-1 (0.2.0)

| Experiment | Outcome |
| --- | --- |
| Extra-calls layer: larger agent budgets, repair accounting by logical invocation, a forced final answer and an LLM critic pass | Rejected — clarification decisions rose from 7/12 to 11/12 and tool-budget failures fell to zero, but end-to-end semantic passes fell from 16/60 to 12/60 because the critic trimmed projections; all eleven commits were reverted. |
| Budget layer with the critic off (the same eleven commits re-landed, critic disabled by default) | Kept — end-to-end semantic passes 16/60 → 19/60, clarification decisions 7/12 → 11/12, tool-budget failures 4 → 1, P95 latency 15.5 s → 11.7 s, cost per result +13%; no case lost two passes. |
| Verified grounding judge (one Particle-1 call labels each word the lexical grounder flags; verified labels release the agent's SQL) | Rejected — end-to-end semantic passes 19/60 → 27/60 paired in the same run, false clarifications 33 → 6, held-out probe decisions 16/34 → 32/34, but P95 latency 29.2 s exceeded the 26.7 s ceiling; all fifteen commits were reverted. |
| The same grounding judge at low reasoning effort | Kept — end-to-end semantic passes 20/60 → 27/60 paired (19/60 in Stage 4), false clarifications 33 → 11, clarification decisions 11/12, held-out probe decisions 18/36 → 34/36 with no release on an ambiguous question, P95 24.9 s, cost per result $0.0032. |

### Previous provider (OpenRouter GPT-5.5/5.6, before 0.2.0) — results don't transfer

These experiments ran on OpenRouter models before Widen moved to Particle-1
in 0.2.0.

| Experiment | Outcome |
| --- | --- |
| Pin the newer GPT-5.6 Sol model | Rejected — failed the false-clarification ceiling and the zero-internal-timeout rule; the pin was reverted and `openai/gpt-5.5` stays. |
| Trusted-SQL bypass (trust SQL the schema agent already produced instead of regenerating it) | Rejected twice — once over a single internal timeout under the conjunctive rule, and again when it released semantically failing SQL. |
| Sol pin + bypass + plan-consistency enforcement | Rejected — enforcement worked mechanically, but the released SQL stayed below the semantic floor; all candidate commits were reverted. |
| Ambiguity-policy tuning (three funded attempts) | Rejected three times — no attempt met both the 12/12 clarification requirement and the false-clarification ceiling at once. |

Negative results cost real eval spend, and we publish them anyway: they are
why the gate will mean something when it eventually passes.
