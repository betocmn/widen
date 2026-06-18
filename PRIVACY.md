# Privacy

Widen is designed to run without a Widen-hosted backend, accounts, analytics,
or telemetry. This document explains what data is stored locally and what can
leave your Mac.

## Default Local Mode

In local mode, Widen uses Apple's on-device Foundation Model when available.
Your database schema, questions, generated SQL, query results, connection
settings, and sessions stay on your Mac except for the PostgreSQL connection
you configure.

## Cloud Mode

If you choose a cloud model, Widen sends prompt context to the selected
provider so it can draft SQL. That prompt can include your question, relevant
schema context, saved database context, recent conversation context, the
current SQL being revised, and the last validation or database error being
repaired. Those fields can include literals you typed and database-returned
error details. Query result tables and database credentials are not sent to the
model provider by Widen.

Cloud mode is opt-in and uses credentials you provide. Review the provider's
own privacy and data-use terms before enabling it.

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
- The selected cloud model provider, only when cloud generation is enabled.
- GitHub Releases for Sparkle update checks in signed release builds.

Widen does not include analytics, telemetry, or a Widen-operated backend.

## Practical Guidance

- Use a read-only Postgres role when you only need analysis.
- Avoid connecting production databases until you have reviewed the SQL safety
  model and are comfortable with the app's behavior.
- Treat schema names, table names, column names, and sample values as sensitive
  when using cloud generation.
- Review saved database context, current SQL, and recent errors before using
  cloud generation on sensitive databases.
- Delete `~/Library/Application Support/Widen/generation.log` when you no
  longer need local prompt debugging history.
- Redact real database names, hostnames, schemas, and query results from bug
  reports unless they are essential.
