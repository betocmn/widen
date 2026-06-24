# Schema Retrieval Index

PR 5 adds a deterministic local schema-search subsystem for evaluation and
future bounded schema tools. Production text-to-SQL prompts, prompt packaging,
Foundation Models generation, OpenRouter generation, SQL repair, validation,
backend defaults, and tool calling do not route through this index in PR 5.

## Indexed Metadata

The index is built from the `DatabaseSchema` snapshot supplied by the caller.
If the caller selected a narrowed schema set, only that snapshot is indexed and
searched. The cache key includes the sorted selected-schema set so unrelated
schemas with duplicate table names cannot bleed into a narrowed search.

Each table or view becomes one primary fielded document. Indexed fields include:

```text
schema-qualified table name
unqualified table name
schema name
table comment
column names
column comments
column data types
primary key columns
unique constraint columns
constraint names
enum and check values
grouped foreign-key relationships
connected table names
ordered foreign-key column pairs
```

Object identities preserve exact PostgreSQL spelling and case. Normalized
tokens are search aliases only and never replace the exact object names used
for lookup or later SQL generation. Comments are capped and control characters
are stripped before indexing.

The index does not contain row data, credentials, database context, user
questions, chat history, generated SQL, prompts, model output, or semantic
binding prose. Confirmed semantic bindings and database context are accepted
only as query-time signals.

## Storage

Persistent indexes are written under:

```text
~/Library/Application Support/Widen/schema-indexes/
```

The directory is created with owner-only permissions, and each index file is
written with restrictive local permissions. Writes are atomic. Index files are
local JSON envelopes containing the cache key and the serialized lexical index.
No cloud or network access is used to build, load, query, or evaluate an index.

Indexes are keyed by:

```text
connection UUID
sorted selected-schema set
deterministic schema fingerprint
index format version
tokenizer version
scorer version
```

The schema fingerprint includes retrieval-relevant metadata: exact
schema/table/column names, table types, types, nullability, comments,
primary/unique constraints, enum/check metadata, and grouped foreign keys. It
excludes nondeterministic timestamps such as schema load time.

Unknown versions, mismatched keys, missing files, and corrupted files are
treated as cache misses and trigger a rebuild. Schema refreshes produce a new
fingerprint. Stale local index files are pruned by a bounded retention policy.
Index load or build failure must not prevent ordinary database browsing.

`SchemaSearchIndexStore` is an actor. It deduplicates concurrent builds,
manages the memory cache, propagates cancellation, and performs disk work away
from the main actor.

## Search Behavior

`SchemaSearching` exposes three deterministic operations:

```swift
search(_:in:) -> SchemaSearchResponse
describe(objectIDs:in:) -> [SchemaObjectDescription]
findJoinPaths(from:to:maxHops:in:) -> [SchemaJoinPath]
```

Search uses a two-stage strategy. Stage 1 retrieves direct lexical candidates
with a field-weighted BM25-style scorer. Stage 2 reranks those candidates using
exact identifier and table-token matches, query-time database context,
selected-schema isolation, constraints, and bounded one-hop FK connectivity.

The scorer uses corpus document frequency, length normalization, exact
identifier boosts, snake_case and camelCase splitting, generic singular/plural
normalization, low-weight prefix/substring matching, and limited typo tolerance
only for sufficiently long identifier tokens. It does not include domain
synonyms or embeddings. Short tokens such as `id`, `at`, `to`, and `a` are not
fuzzy matched.

Graph expansion uses grouped logical foreign-key edges, preserves ordered
source/target column pairs, traverses edges in either direction for path
finding, avoids cycles, returns shortest simple paths first, and caps both hop
count and returned path count. It does not infer joins from shared column names.

Search hits return stable object IDs and score diagnostics, not prompt-ready
prose. Diagnostics include total score, matched table terms, matched column
IDs, matched fields, exact score, lexical score, context boost, graph boost,
rank, query token coverage, top-to-second score margin, `noStrongMatch`, and
`exactIdentifierMatch`. Raw comments, context text, and complete indexed schema
content are not logged by default.

## Retrieval Evals

The deterministic retrieval suite lives at:

```text
Evals/suites/schema-retrieval-v1.json
```

Run it with:

```sh
make eval-retrieval
make eval-retrieval RETRIEVER=index
make eval-retrieval RETRIEVER=legacy
make eval-retrieval-case CASE=preseason.top-wins-defined
```

The suite runs the legacy `SchemaRelevanceRanker` and the local index against
the same query inputs when `RETRIEVER=both`. It does not call Foundation
Models, OpenRouter, SQL generation, repair, validation, or PostgreSQL.

Reports include required-table Recall@3/5/8, all-required-tables-present at
3/5/8, primary-table reciprocal rank and MRR, required join-path recall,
wrong-schema collisions, no-result or low-signal count, forbidden distractor
count, index build duration, serialized size, p50/p95 query latency, and score
explanations for misses.

The suite deliberately includes noisy and adversarial fixtures: duplicate table
names across schemas, quoted mixed-case names, 100+ irrelevant tables, bridge
tables, multiple FKs between the same tables, composite FKs, common `id/name`
columns, enum/check matches, comment-only business terminology, no-match
queries, schema-qualified requests, and singular/plural or mild identifier
spelling differences.

Latency is reported as a diagnostic only. The suite is not a replacement for
later SQL generation or semantic-result evals; it verifies retrieval behavior
at the schema-object boundary.
