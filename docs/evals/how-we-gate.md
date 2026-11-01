# How we gate text-to-SQL releases

Widen's text-to-SQL is labeled beta because it has not passed our release
gate. This page explains what the gate measures, why the model is pinned, and
what happens when an experiment fails.

## The release gate

`make eval-release` runs a 20-case suite three times (60 results) through the
same Particle-1 schema-tool pipeline the app uses, with seeded Postgres
semantic grading: each candidate query executes against a synthetic fixture
database and its result set is compared to a hand-written golden query's. The
gate passes only if all of the following hold:

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

Particle-1 has not been gated yet, so text-to-SQL stays beta and is not
described as production-ready. The previous OpenRouter GPT-5.5 profile failed
the 0.1.0 gate on semantic pass rate. The committed gate report for each
release lives in [docs/evals/](.).

## Pinned model and identity check

- The app requests `particle-1`. Users cannot select another model; changing
  the model requires a new app release that passed the gate.
- Every completion must report `particle-ai/particle-1`. A missing or
  different model name fails the request, and Widen discards the response
  rather than use an unevaluated model.
- Particle publishes no dated snapshots, so that check verifies the model name
  only. Particle can change the model behind the name without a Widen release,
  and Widen cannot detect it. Periodic re-gates stand in for version pinning.
- Particle states it keeps no inference data by default. That is Particle's
  policy, not something Widen enforces: Particle's API has no per-request
  routing or retention setting, so Widen sends none.

## Pre-registered experiments, published negatives

Pipeline changes are pre-registered: acceptance criteria are written down
before the paid gate run, and the criteria are conjunctive — one miss rejects
the whole candidate. Rejected candidates are reverted from the product; the
sanitized evidence stays published.

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
