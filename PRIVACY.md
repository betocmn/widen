# Privacy

Widen is designed to run without a Widen-hosted backend, accounts, analytics,
or telemetry. This document explains what data is stored locally and what can
leave your Mac.

## Default Cloud Mode

Fresh installs default text-to-SQL generation to Cloud mode with OpenRouter and
Widen's schema-tool agent. Widen has no hosted backend of its own; cloud
requests go directly from your Mac to the provider you configure in
Settings > LLM.

The OpenRouter text-to-SQL profile is fixed to the evaluated GPT-5.5 alias and
canonical version shipped with the app. Users cannot enter an arbitrary model
ID or disable the connected-session schema-tool path. A model-version change
requires a new app release and release-gate evaluation.

Cloud mode sends the question and allowed schema metadata to the selected
provider so it can draft SQL. Schema metadata includes table names, column
names, comments, constraints, enum/check values, and foreign-key structure.
Prompt context can also include saved database context, recent conversation
context, the current SQL being revised, and the last validation or database
error being repaired. Those fields can include literals you typed and
database-returned error details.

For every OpenRouter completion, Widen requires zero-data-retention endpoints,
denies provider data collection, and requires an endpoint that supports all
request parameters. If no eligible private endpoint is available, generation
fails instead of relaxing those requirements. OpenRouter catalog requests do
not include question or schema context.

Inspected data values are sent to a cloud provider only when cloud data
inspection is explicitly enabled for that connection. Query result tables and
database credentials are not sent to the model provider by Widen.

Cloud mode uses credentials you provide. Review the provider's own privacy and
data-use terms before enabling it.

## Optional Local Mode

On eligible macOS 26+ Apple Silicon Macs, Widen can use Apple's on-device
Foundation Model. In local mode, your database schema, questions, generated
SQL, query results, connection settings, and sessions stay on your Mac except
for the PostgreSQL connection you configure.

## Local Storage

Widen stores non-secret app data in:

```text
~/Library/Application Support/Widen/
```

That includes:

- Non-secret database connection settings.
- Session transcripts, SQL text, and generation metadata.
- Cached schema snapshots.
- A plaintext `generation.log` debug log containing the full prompt and model
  outcome for each local, OpenRouter, or Private Cloud Compute generation.

The generation log can include schema context, saved database context, recent
questions, SQL, and validation or database error text. Delete
`~/Library/Application Support/Widen/generation.log` to remove it; Widen will
recreate the file when another generation runs. Widen does not persist query
result tables across restarts.

Passwords and API keys are stored in the macOS Keychain under the `Widen`
service.

## Network Connections

Depending on your settings, Widen can make these network connections:

- PostgreSQL servers you configure.
- The selected cloud model provider when cloud generation is used.
- GitHub Releases for Sparkle update checks in signed release builds.

Widen does not include analytics, telemetry, or a Widen-operated backend.

## Practical Guidance

- Use a read-only Postgres role when you only need analysis.
- Avoid connecting production databases until you have reviewed the SQL safety
  model and are comfortable with the app's behavior.
- Treat schema names, table names, column names, and inspected data values as
  sensitive when using cloud generation.
- Review saved database context, current SQL, and recent errors before using
  cloud generation on sensitive databases.
- Delete `~/Library/Application Support/Widen/generation.log` when you no
  longer need local prompt debugging history.
- Redact real database names, hostnames, schemas, and query results from bug
  reports unless they are essential.
