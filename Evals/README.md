# Text-to-SQL Evals

`WidenEval` is the native Swift evaluation runner for Widen's text-to-SQL
pipeline. It invokes the same production pipeline as the app from an
already-prepared generation request through local validation and
validation-only repair, then writes per-run artifacts under `.eval-results/`.

**Evaluation scope:** The production pipeline produces the final SQL,
clarification, or typed failure. A static-shape pass then verifies the decision,
SQL safety, schema references, and configured structural expectations. It does
not establish result-set or semantic correctness.

The runner does not execute generated SQL or compare result sets. Committed
baselines record deterministic hashes for the suite file, pipeline/scorer
sources, and schema fixtures to establish baseline compatibility. Baseline
changes after PR 2 can reflect the move from generator-only evaluation to the
full production pipeline, including canonicalization, local validation, and
validation-only repair.

## Commands

```sh
make eval-local
make eval-cloud MODEL=openai/gpt-5.5
make eval-all MODEL=openai/gpt-5.5
make eval-case CASE=preseason.top-wins-defined BACKEND=local
```

Cloud mode reads the OpenRouter key only from:

```sh
WIDEN_EVAL_OPENROUTER_API_KEY
```

For local development, a gitignored `.env.eval.local` file can export that
variable. Do not commit API keys, prompts, or raw model output.

## CLI

```text
--backend local|cloud|both
--model <openrouter-model-id>
--suite <path>
--case <case-id>
--repeat <n>
--output <directory>
--record-prompts
--fail-under <percentage>
```

Prompt recording defaults to off. When it is off, the eval process also
disables Widen's append-only generation log for that process. Reported
`estimatedInitialPromptCharacters` and optional `estimatedInitialPrompt`
values are eval-runner estimates, not the exact model prompt after discovery,
truncation, or retry behavior.

## Artifacts

Each run writes:

```text
.eval-results/<timestamp>/
  run.json
  cases.jsonl
  summary.md
```

`.eval-results/` is ignored by git. Committed baseline summaries must be
sanitized and should not include estimated prompts, raw model responses,
credentials, or private schema data.
