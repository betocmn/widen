# Privacy

Widen is designed to run without a Widen-hosted backend, accounts, analytics,
or telemetry. This document explains what data is stored locally and what can
leave your Mac.

## Text-to-SQL With Particle-1

Text-to-SQL uses Particle-1, a cloud model from Particle, with your own
Particle API key, which you add in Settings > LLM. Widen has no hosted backend
of its own; requests go directly from your Mac to Particle at
`https://api.particle.ai/v1`, and Widen sends the key to no other host.
Without a key, Widen still browses schemas and runs SQL, and sends nothing to
Particle.

The model is fixed. Widen requests `particle-1` and discards any response that
does not report `particle-ai/particle-1`; users cannot choose another model.
Particle publishes no dated snapshots, so this check verifies the model name
only, and Particle can change the model behind that name without a Widen
release.

Text-to-SQL sends the question and the schema metadata the connection allows
to Particle so Particle-1 can draft SQL. Schema metadata includes table names,
column names, comments, constraints, enum/check values, and foreign-key
structure. Prompt context can also include saved database context, remembered
definitions, recent questions, the current SQL being revised, and the last
validation or database error being repaired. Database error messages from the
session are sent so Particle-1 can fix failed queries; they can quote a value
from your data, and other fields can include literals you typed.

Each connection has its own controls under Advanced Privacy in
Settings > Databases:

- Schema metadata sharing is on by default and required for text-to-SQL.
  Turning it off turns off text-to-SQL for that connection; you can still
  browse the schema and run SQL.
- Data inspection is off by default. When it is on, Widen runs bounded
  read-only inspection queries and sends Particle only approximate row counts
  and column statistics, such as the share of nulls and the number of
  distinct values.
- Sending inspected data values is off by default and needs data inspection.
  Only with it on does Widen send Particle inspected values, such as distinct
  values and, when sample row inspection is also on, sample rows.

Query result tables and database credentials are not sent to Particle by
Widen.

Particle states that it keeps no inference data by default. That zero data
retention is Particle's policy, not something Widen enforces or can verify,
and Particle's API has no per-request routing or retention setting for Widen
to send. Review Particle's own privacy and data-use terms before adding a key.

Test Connection in Settings > LLM calls `GET /v1/models` to check your key and
that Particle-1 is listed with tool calling, then sends one tiny completion
that contains no question, schema, or database context. It may incur a tiny
charge.

Widen also uses Particle-1 to name sessions. When the first message in a
session is a plain-English question, a key is set, and the connection allows
schema metadata sharing, Widen sends that question (at most 500 characters) in
one more small request, with no schema or database context. Otherwise, or if
that request fails, the title is the message's first words, made on your Mac.

The first launch of Widen 0.2.0 deletes the OpenRouter API key that earlier
versions stored in the Keychain (service `Widen`, account
`openrouter-api-key`) and the cached OpenRouter model catalog
(`openrouter-model-catalog-cache.json`), and removes the retired AI
preferences. The old key is only deleted, never read or reused.

## Local Storage

Widen stores non-secret app data in:

```text
~/Library/Application Support/Widen/
```

That includes:

- Non-secret database connection settings.
- Session transcripts, SQL text, and generation metadata.
- Cached schema snapshots.
- A plaintext `generation.log` debug log, if one exists. Only Widen's
  one-shot SQL generator writes it, with the full prompt and model outcome of
  each generation. The schema-tool agent that drafts SQL in sessions does not
  write it, so a log there usually comes from an earlier Widen version.

The generation log is local-only; Widen never uploads it. It can include
schema context, saved database context, recent questions, SQL, and validation
or database error text. Delete
`~/Library/Application Support/Widen/generation.log` to remove it. Widen does
not persist query result tables across restarts.

Passwords and API keys are stored in the macOS Keychain under the `Widen`
service; the Particle API key uses the account `particle-api-key`.

## Network Connections

Depending on your settings, Widen can make these network connections:

- PostgreSQL servers you configure.
- Particle (`api.particle.ai`) for text-to-SQL, session titles, and Test
  Connection, only when a Particle API key is set.
- GitHub Releases for Sparkle update checks in signed release builds.

Widen does not include analytics, telemetry, or a Widen-operated backend.

## Practical Guidance

- Use a read-only Postgres role when you only need analysis.
- Avoid connecting production databases until you have reviewed the SQL safety
  model and are comfortable with the app's behavior.
- Treat schema names, table names, column names, and inspected data values as
  sensitive when using text-to-SQL.
- Review saved database context, current SQL, and recent errors before using
  text-to-SQL on sensitive databases.
- Delete `~/Library/Application Support/Widen/generation.log` if it exists
  and you no longer need its prompt debugging history.
- Redact real database names, hostnames, schemas, and query results from bug
  reports unless they are essential.
