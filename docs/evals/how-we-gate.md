# How we gate text-to-SQL releases

Widen's text-to-SQL is labeled beta because it has not passed our release
gate. This page explains what the gate measures, why the model is pinned, and
what happens when an experiment fails.

## The release gate

`make eval-release` runs a 20-case suite three times (60 results) through the
same OpenRouter pipeline fresh installs use, with seeded Postgres semantic
grading: each candidate query executes against a synthetic fixture database
and its result set is compared to a hand-written golden query's. The gate
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

The gate currently fails on semantic pass rate, so text-to-SQL stays beta and
is not described as production-ready. The committed gate report for each
release lives in [docs/evals/](.).

## Pinned model, fail-closed verification, private routing

- The cloud profile is fixed to an evaluated `openai/gpt-5.5` version. Users
  cannot select another model; changing the model requires a new app release
  that passed the gate on that exact version.
- Providers can silently change what a model alias serves. Widen verifies the
  concrete model version routed for each completion against the pinned one;
  missing, ambiguous, or conflicting evidence fails the request rather than
  running an unevaluated model.
- Every OpenRouter completion requires zero-data-retention endpoints and
  denies provider data collection. If no eligible endpoint is available,
  generation fails instead of relaxing those requirements.

## Pre-registered experiments, published negatives

Pipeline changes are pre-registered: acceptance criteria are written down
before the paid gate run, and the criteria are conjunctive — one miss rejects
the whole candidate. Rejected candidates are reverted from the product; the
sanitized evidence stays published.

| Experiment | Outcome |
| --- | --- |
| Pin the newer GPT-5.6 Sol model | Rejected — failed the false-clarification ceiling and the zero-internal-timeout rule; the pin was reverted and `openai/gpt-5.5` stays. |
| Trusted-SQL bypass (trust SQL the schema agent already produced instead of regenerating it) | Rejected twice — once over a single internal timeout under the conjunctive rule, and again when it released semantically failing SQL. |
| Sol pin + bypass + plan-consistency enforcement | Rejected — enforcement worked mechanically, but the released SQL stayed below the semantic floor; all candidate commits were reverted. |
| Ambiguity-policy tuning (three funded attempts) | Rejected three times — no attempt met both the 12/12 clarification requirement and the false-clarification ceiling at once. |

Negative results cost real eval spend, and we publish them anyway: they are
why the gate will mean something when it eventually passes.
