import Foundation
import Testing

@testable import WidenKit

@Suite("SchemaSearchIndex")
struct SchemaSearchIndexTests {
    private let connectionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test func objectIDsPreserveCaseAndDistinguishSchemas() {
        let publicUsers = SchemaObjectID.table(schema: "public", name: "users")
        let authUsers = SchemaObjectID.table(schema: "auth", name: "users")
        let mixed = SchemaObjectID.table(schema: "public", name: "UserEvents")
        let lower = SchemaObjectID.table(schema: "public", name: "userevents")
        let delimiterInSchema = SchemaObjectID.table(schema: "public|audit", name: "events")
        let delimiterInTable = SchemaObjectID.table(schema: "public", name: "audit|events")

        #expect(publicUsers != authUsers)
        #expect(mixed != lower)
        #expect(delimiterInSchema.stableString != delimiterInTable.stableString)
        #expect(mixed.stableString.contains("UserEvents"))
    }

    @Test func exactSchemaQualifiedQueryBeatsSameNamedOtherSchema() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public"), SchemaInfo(name: "auth")],
            tables: [
                table(schema: "public", name: "users", columns: ["id", "email"]),
                table(schema: "auth", name: "users", columns: ["id", "provider"]),
            ]
        )
        let searcher = makeSearcher(schema: schema, selectedSchemas: ["auth", "public"])

        let response = searcher.search(
            SchemaSearchRequest(query: "auth.users", limit: 2),
            in: snapshot(schema, selectedSchemas: ["auth", "public"])
        )

        #expect(response.hits.first?.tableObjectID == .table(schema: "auth", name: "users"))
        #expect(response.exactIdentifierMatch)
    }

    @Test func quotedSchemaQualifiedQueryMatchesSimpleTableName() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "Sales"), SchemaInfo(name: "public")],
            tables: [
                table(schema: "Sales", name: "orders", columns: ["id", "total_cents"]),
                table(schema: "public", name: "orders", columns: ["id"]),
            ]
        )
        let selectedSchemas = ["Sales", "public"]
        let searcher = makeSearcher(schema: schema, selectedSchemas: selectedSchemas)

        let response = searcher.search(
            SchemaSearchRequest(query: #""Sales".orders"#, limit: 2),
            in: snapshot(schema, selectedSchemas: selectedSchemas)
        )

        let first = try #require(response.hits.first)
        #expect(first.tableObjectID == .table(schema: "Sales", name: "orders"))
        #expect(response.exactIdentifierMatch)
        #expect(first.exactMatchScore > 0)
    }

    @Test func exactIdentifierBoostRequiresIdentifierBoundaries() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "users", columns: ["id", "email"]),
                table(schema: "public", name: "users_archive", columns: ["id", "email"]),
            ]
        )
        let searcher = makeSearcher(schema: schema)

        let response = searcher.search(
            SchemaSearchRequest(query: "public.users_archive", limit: 2),
            in: snapshot(schema)
        )

        let archiveHit = response.hits.first {
            $0.tableObjectID == .table(schema: "public", name: "users_archive")
        }
        let usersHit = response.hits.first {
            $0.tableObjectID == .table(schema: "public", name: "users")
        }

        #expect(response.hits.first?.tableObjectID == .table(schema: "public", name: "users_archive"))
        #expect((archiveHit?.exactMatchScore ?? 0) > 30)
        #expect((usersHit?.exactMatchScore ?? 0) < 5)
    }

    @Test func exactIdentifierBoostTreatsDollarAsIdentifierBody() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "users", columns: ["id", "email"]),
                table(schema: "public", name: "users$archive", columns: ["id", "email"]),
            ]
        )
        let searcher = makeSearcher(schema: schema)

        let response = searcher.search(
            SchemaSearchRequest(query: "users$archive", limit: 2),
            in: snapshot(schema)
        )

        let archiveHit = response.hits.first {
            $0.tableObjectID == .table(schema: "public", name: "users$archive")
        }
        let usersHit = response.hits.first {
            $0.tableObjectID == .table(schema: "public", name: "users")
        }

        #expect(response.hits.first?.tableObjectID == .table(schema: "public", name: "users$archive"))
        #expect((archiveHit?.exactMatchScore ?? 0) > 12)
        #expect((usersHit?.exactMatchScore ?? 0) < 5)
    }

    @Test func quotedMixedCaseAndLowercaseTablesRemainDistinct() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "UserEvents", columns: ["id", "eventName"]),
                table(schema: "public", name: "userevents", columns: ["id", "event_name"]),
            ]
        )
        let searcher = makeSearcher(schema: schema)
        let mixed = searcher.search(
            SchemaSearchRequest(query: #"public."UserEvents""#),
            in: snapshot(schema)
        )
        let lower = searcher.search(
            SchemaSearchRequest(query: "public.userevents"),
            in: snapshot(schema)
        )
        let unquotedMixed = searcher.search(
            SchemaSearchRequest(query: "public.UserEvents", limit: 2),
            in: snapshot(schema)
        )
        let unqualifiedLower = searcher.search(
            SchemaSearchRequest(query: "userevents", limit: 2),
            in: snapshot(schema)
        )

        #expect(mixed.hits.first?.tableObjectID == .table(schema: "public", name: "UserEvents"))
        #expect(lower.hits.first?.tableObjectID == .table(schema: "public", name: "userevents"))
        #expect(unquotedMixed.hits.first?.tableObjectID == .table(schema: "public", name: "userevents"))
        #expect(unqualifiedLower.hits.first?.tableObjectID == .table(schema: "public", name: "userevents"))
        #expect(unqualifiedLower.exactIdentifierMatch)
        let quotedOnlyHit = unquotedMixed.hits.first {
            $0.tableObjectID == .table(schema: "public", name: "UserEvents")
        }
        #expect((quotedOnlyHit?.exactMatchScore ?? 0) == 0)
    }

    @Test func quotedIdentifierCaseMismatchDoesNotLowercaseExactMatch() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "UserEvents", columns: ["id", "eventName"]),
            ]
        )
        let searcher = makeSearcher(schema: schema)

        let response = searcher.search(
            SchemaSearchRequest(query: #"public."userevents""#),
            in: snapshot(schema)
        )
        let hit = response.hits.first {
            $0.tableObjectID == .table(schema: "public", name: "UserEvents")
        }

        #expect(!response.exactIdentifierMatch)
        #expect((hit?.exactMatchScore ?? 0) == 0)
    }

    @Test func unqualifiedDuplicateTableNameIsAmbiguous() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public"), SchemaInfo(name: "auth")],
            tables: [
                table(schema: "public", name: "users", columns: ["id", "email"]),
                table(schema: "auth", name: "users", columns: ["id", "provider"]),
            ]
        )
        let searcher = makeSearcher(schema: schema, selectedSchemas: ["auth", "public"])

        let response = searcher.search(
            SchemaSearchRequest(query: "users", limit: 2),
            in: snapshot(schema, selectedSchemas: ["auth", "public"])
        )

        #expect(response.hits.count == 2)
        #expect(!response.exactIdentifierMatch)
    }

    @Test func bm25CorpusStatisticsUseDocumentFrequency() {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "invoices", columns: ["id", "invoice_total"]),
                table(schema: "public", name: "tickets", columns: ["id", "status"]),
            ]
        )
        let index = LocalSchemaSearchIndex.build(
            snapshot: snapshot(schema),
            fingerprint: "test"
        )

        #expect(index.documentFrequency["invoice"] == 1)
        #expect(index.documentFrequency["id"] == 2)
    }

    @Test func exactNameBoostOutranksLexicalColumnMatch() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "orders", columns: ["id"]),
                table(schema: "public", name: "order_items", columns: ["id", "orders_count"]),
            ]
        )
        let searcher = makeSearcher(schema: schema)

        let response = searcher.search(
            SchemaSearchRequest(query: "public.orders"),
            in: snapshot(schema)
        )

        let first = try #require(response.hits.first)
        #expect(first.tableObjectID == .table(schema: "public", name: "orders"))
        #expect(first.exactMatchScore > first.lexicalBM25Score)
    }

    @Test func tableAndColumnCommentsAreSearchable() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "payments",
                    type: .baseTable,
                    comment: "Revenue ledger for settled customer charges",
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "payments",
                            name: "amount_cents",
                            comment: "Booked revenue amount",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                ),
                table(schema: "public", name: "tickets", columns: ["id", "status"]),
            ]
        )
        let response = makeSearcher(schema: schema).search(
            SchemaSearchRequest(query: "booked revenue"),
            in: snapshot(schema)
        )

        let first = try #require(response.hits.first)
        #expect(first.tableObjectID == .table(schema: "public", name: "payments"))
        #expect(first.matchedFields.contains { $0.field == .tableComment || $0.field == .columnComment })
    }

    @Test func enumAndCheckValuesAreSearchable() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "benchmark_runs",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "benchmark_runs",
                            name: "status",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 1,
                            valueConstraints: [
                                ColumnValueConstraint(
                                    kind: .check,
                                    values: ["scheduled", "running", "failed"],
                                    expression: "CHECK (status IN ('scheduled', 'running', 'failed'))",
                                    constraintName: "benchmark_runs_status_check"
                                )
                            ]
                        )
                    ]
                ),
                table(schema: "public", name: "tools", columns: ["id", "name"]),
            ]
        )

        let response = makeSearcher(schema: schema).search(
            SchemaSearchRequest(query: "failed runs"),
            in: snapshot(schema)
        )

        #expect(response.hits.first?.tableObjectID == .table(schema: "public", name: "benchmark_runs"))
    }

    @Test func longTablesDoNotWinFromColumnCountAlone() throws {
        let noisyColumns = (1...180).map { "generic_status_\($0)" }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "wide_noise", columns: noisyColumns),
                table(schema: "public", name: "revenue_summary", columns: ["id", "revenue_total"]),
            ]
        )

        let response = makeSearcher(schema: schema).search(
            SchemaSearchRequest(query: "revenue"),
            in: snapshot(schema)
        )

        #expect(response.hits.first?.tableObjectID == .table(schema: "public", name: "revenue_summary"))
    }

    @Test func prefixMatchScoresBelowExactIdentifierMatch() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "match_evaluations", columns: ["id", "winner_id"]),
            ]
        )
        let searcher = makeSearcher(schema: schema)
        let prefix = searcher.search(SchemaSearchRequest(query: "win"), in: snapshot(schema))
        let exact = searcher.search(SchemaSearchRequest(query: "winner"), in: snapshot(schema))

        #expect((exact.hits.first?.totalScore ?? 0) > (prefix.hits.first?.totalScore ?? 0))
    }

    @Test func shortTokenFuzzyMatchingIsDisabled() {
        #expect(SchemaSearchTokenizer.similarity(queryToken: "id", indexedToken: "if") == 0)
        #expect(SchemaSearchTokenizer.similarity(queryToken: "at", indexedToken: "ad") == 0)
    }

    @Test func deterministicTieOrderingUsesQualifiedName() {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "beta", columns: ["status"]),
                table(schema: "public", name: "alpha", columns: ["status"]),
            ]
        )
        let response = makeSearcher(schema: schema).search(
            SchemaSearchRequest(query: "status", limit: 2),
            in: snapshot(schema)
        )

        #expect(response.hits.map(\.tableObjectID) == [
            .table(schema: "public", name: "alpha"),
            .table(schema: "public", name: "beta"),
        ])
    }

    @Test func groupedCompositeForeignKeysPreserveOrderedPairsInPaths() throws {
        let schema = relationshipSchema()
        let searcher = makeSearcher(schema: schema)
        let paths = searcher.findJoinPaths(
            from: .table(schema: "public", name: "accounts"),
            to: .table(schema: "public", name: "account_events"),
            maxHops: 1,
            in: snapshot(schema)
        )

        let edge = try #require(paths.first?.edges.first)
        #expect(edge.traversalDirection == .reverse)
        #expect(edge.columnPairs == [
            SchemaForeignKeyColumnPair(
                sourceColumn: "tenant_id",
                targetColumn: "tenant_id",
                ordinalPosition: 1
            ),
            SchemaForeignKeyColumnPair(
                sourceColumn: "external_id",
                targetColumn: "external_id",
                ordinalPosition: 2
            ),
        ])
    }

    @Test func joinPathsAreShortestCycleSafeAndHopCapped() {
        let schema = graphSchema()
        let searcher = makeSearcher(schema: schema)
        let paths = searcher.findJoinPaths(
            from: .table(schema: "public", name: "a"),
            to: .table(schema: "public", name: "d"),
            maxHops: 3,
            in: snapshot(schema)
        )
        let capped = searcher.findJoinPaths(
            from: .table(schema: "public", name: "a"),
            to: .table(schema: "public", name: "d"),
            maxHops: 1,
            in: snapshot(schema)
        )

        #expect(paths.first?.hopCount == 2)
        #expect(paths.allSatisfy { Set($0.edges.map(\.fromTableID)).count == $0.edges.count })
        #expect(capped.isEmpty)
        #expect(paths.count <= 8)
    }

    @Test func selfReferentialForeignKeyReturnsJoinPath() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "employees", columns: ["id", "manager_id"]),
            ],
            foreignKeyConstraints: [
                SchemaForeignKeyConstraintInfo(
                    constraintName: "employees_manager_id_fkey",
                    sourceSchema: "public",
                    sourceTable: "employees",
                    targetSchema: "public",
                    targetTable: "employees",
                    columnPairs: [
                        SchemaForeignKeyColumnPair(
                            sourceColumn: "manager_id",
                            targetColumn: "id",
                            ordinalPosition: 1
                        )
                    ]
                )
            ]
        )
        let searcher = makeSearcher(schema: schema)

        let paths = searcher.findJoinPaths(
            from: .table(schema: "public", name: "employees"),
            to: .table(schema: "public", name: "employees"),
            maxHops: 1,
            in: snapshot(schema)
        )

        #expect(paths.contains { path in
            path.hopCount == 1
                && path.edges.first?.constraintName == "employees_manager_id_fkey"
        })
    }

    @Test func selectedSchemaIsolationUsesOnlySuppliedSnapshot() {
        let full = DatabaseSchema(
            schemas: [SchemaInfo(name: "public"), SchemaInfo(name: "auth")],
            tables: [
                table(schema: "public", name: "users", columns: ["id", "email"]),
                table(schema: "public", name: "sessions", columns: ["id", "auth_user_id"]),
                table(schema: "auth", name: "users", columns: ["id", "provider"]),
            ],
            foreignKeyConstraints: [
                SchemaForeignKeyConstraintInfo(
                    constraintName: "sessions_auth_user_fkey",
                    sourceSchema: "public",
                    sourceTable: "sessions",
                    targetSchema: "auth",
                    targetTable: "users",
                    columnPairs: [
                        SchemaForeignKeyColumnPair(
                            sourceColumn: "auth_user_id",
                            targetColumn: "id",
                            ordinalPosition: 1
                        )
                    ]
                )
            ]
        )
        let searcher = makeSearcher(schema: full, selectedSchemas: ["public"])
        let snapshot = snapshot(full, selectedSchemas: ["public"])
        let response = searcher.search(
            SchemaSearchRequest(query: "auth users"),
            in: snapshot
        )
        let descriptions = searcher.describe(
            objectIDs: [
                .schema("auth"),
                .table(schema: "auth", name: "users"),
                .table(schema: "public", name: "users"),
            ],
            in: snapshot
        )
        let paths = searcher.findJoinPaths(
            from: .table(schema: "public", name: "sessions"),
            to: .table(schema: "auth", name: "users"),
            maxHops: 1,
            in: snapshot
        )

        #expect(!response.hits.contains { $0.tableObjectID.schema == "auth" })
        #expect(!descriptions.contains { $0.schema == "auth" })
        #expect(descriptions.contains { $0.objectID == .table(schema: "public", name: "users") })
        #expect(paths.isEmpty)
    }

    @Test func describeSkipsMissingSchemaInAllSchemaSnapshot() {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "users", columns: ["id", "email"]),
            ]
        )
        let searcher = makeSearcher(schema: schema, selectedSchemas: [])

        let descriptions = searcher.describe(
            objectIDs: [
                .schema("public"),
                .schema("missing"),
            ],
            in: snapshot(schema, selectedSchemas: [])
        )

        #expect(descriptions.contains { $0.objectID == .schema("public") })
        #expect(!descriptions.contains { $0.objectID == .schema("missing") })
    }

    @Test func databaseContextIsQueryTimeBoostOnly() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "match_evaluations", columns: ["id", "winner_id"]),
                table(schema: "public", name: "match_batches", columns: ["id", "completed_evaluations"]),
            ]
        )
        let searcher = makeSearcher(schema: schema)
        let withoutContext = searcher.search(
            SchemaSearchRequest(query: "match records", limit: 2),
            in: snapshot(schema)
        )
        let withContext = searcher.search(
            SchemaSearchRequest(
                query: "match records",
                databaseContext: "winner_id records a win"
            ),
            in: snapshot(schema)
        )
        let evalID = SchemaObjectID.table(schema: "public", name: "match_evaluations")
        let withoutScore = withoutContext.hits.first { $0.tableObjectID == evalID }?.totalScore ?? 0
        let withHit = try #require(withContext.hits.first { $0.tableObjectID == evalID })

        #expect(withHit.contextBoost > 0)
        #expect(withHit.totalScore > withoutScore)
    }

    @Test func semanticBindingTermsContributeToStrongMatchCoverage() throws {
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                table(schema: "public", name: "orders", columns: ["id", "total_cents"]),
                table(schema: "public", name: "invoices", columns: ["id", "invoice_number"]),
            ]
        )
        let response = makeSearcher(schema: schema).search(
            SchemaSearchRequest(
                query: "thing",
                semanticBindingTerms: ["orders total_cents"]
            ),
            in: snapshot(schema)
        )

        #expect(response.hits.first?.tableObjectID == .table(schema: "public", name: "orders"))
        #expect(response.queryTokenCoverage >= 0.25)
        #expect(!response.noStrongMatch)
    }

    @Test func diskCacheHitAndFingerprintInvalidation() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [table(schema: "public", name: "orders", columns: ["id"])]
        )
        let schemaSnapshot = snapshot(schema)
        let key = try SchemaSearchIndexStore.cacheKey(for: schemaSnapshot)
        let file = directory.appendingPathComponent("\(key.cacheID).json")
        let firstStore = SchemaSearchIndexStore(directory: directory)
        let fresh = try await firstStore.searcher(for: schemaSnapshot)
        let freshResponse = fresh.search(SchemaSearchRequest(query: "orders"), in: schemaSnapshot)
        let freshData = try Data(contentsOf: file)
        #expect(freshResponse.indexSerializedSizeBytes == freshData.count)

        let secondStore = SchemaSearchIndexStore(directory: directory)
        let cached = try await secondStore.searcher(for: schemaSnapshot)
        let cachedResponse = cached.search(SchemaSearchRequest(query: "orders"), in: schemaSnapshot)
        #expect(cachedResponse.indexSerializedSizeBytes == freshData.count)

        let changed = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [table(schema: "public", name: "orders", columns: ["id", "status"])]
        )
        _ = try await secondStore.searcher(for: snapshot(changed))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
        #expect(files.count == 2)
    }

    @Test func selectedSchemaCacheKeyIgnoresUnselectedMetadata() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public"), SchemaInfo(name: "auth")],
            tables: [
                table(schema: "public", name: "orders", columns: ["id"]),
                table(schema: "auth", name: "users", columns: ["id"]),
            ]
        )
        let changedUnselectedSchema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public"), SchemaInfo(name: "auth")],
            tables: [
                table(schema: "public", name: "orders", columns: ["id"]),
                table(schema: "auth", name: "users", columns: ["id", "provider"]),
            ]
        )
        let store = SchemaSearchIndexStore(directory: directory)

        _ = try await store.searcher(for: snapshot(schema, selectedSchemas: ["public"]))
        _ = try await store.searcher(
            for: snapshot(changedUnselectedSchema, selectedSchemas: ["public"])
        )

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
        #expect(files.count == 1)
    }

    @Test func selectedSchemaCacheKeyDisambiguatesDelimiterCharacters() throws {
        let shared = (
            connectionID: connectionID,
            schemaFingerprint: "same-fingerprint",
            indexFormatVersion: LocalSchemaSearchIndex.formatVersion,
            tokenizerVersion: SchemaSearchTokenizer.version,
            scorerVersion: LocalSchemaSearchIndex.scorerVersion
        )
        let first = SchemaSearchIndexCacheKey(
            connectionID: shared.connectionID,
            selectedSchemas: ["a,b", "c"],
            schemaFingerprint: shared.schemaFingerprint,
            indexFormatVersion: shared.indexFormatVersion,
            tokenizerVersion: shared.tokenizerVersion,
            scorerVersion: shared.scorerVersion
        )
        let second = SchemaSearchIndexCacheKey(
            connectionID: shared.connectionID,
            selectedSchemas: ["a", "b,c"],
            schemaFingerprint: shared.schemaFingerprint,
            indexFormatVersion: shared.indexFormatVersion,
            tokenizerVersion: shared.tokenizerVersion,
            scorerVersion: shared.scorerVersion
        )

        #expect(first.cacheID != second.cacheID)
    }

    @Test func cacheFilesUseRestrictivePermissions() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [table(schema: "public", name: "orders", columns: ["id"])]
        )
        let store = SchemaSearchIndexStore(directory: directory)

        _ = try await store.searcher(for: snapshot(schema))

        let file = try #require(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            .first { $0.pathExtension == "json" }
        )
        let directoryPermissions = try #require(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        )
        let filePermissions = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                as? NSNumber
        )

        #expect(directoryPermissions.intValue & 0o777 == 0o700)
        #expect(filePermissions.intValue & 0o777 == 0o600)
    }

    @Test func indexVersionAndCorruptedCacheRebuild() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [table(schema: "public", name: "orders", columns: ["id"])]
        )
        let key = try SchemaSearchIndexStore.cacheKey(for: snapshot(schema))
        let file = directory.appendingPathComponent("\(key.cacheID).json")
        let store = SchemaSearchIndexStore(directory: directory)
        _ = try await store.searcher(for: snapshot(schema))

        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(
            of: #""formatVersion":\#(LocalSchemaSearchIndex.formatVersion)"#,
            with: #""formatVersion":999"#
        )
        try text.write(to: file, atomically: true, encoding: .utf8)
        let versionStore = SchemaSearchIndexStore(directory: directory)
        let rebuilt = try await versionStore.searcher(for: snapshot(schema))
        #expect(rebuilt.search(SchemaSearchRequest(query: "orders"), in: snapshot(schema)).hits.count == 1)

        try Data("not json".utf8).write(to: file)
        let corruptStore = SchemaSearchIndexStore(directory: directory)
        let recovered = try await corruptStore.searcher(for: snapshot(schema))
        #expect(recovered.search(SchemaSearchRequest(query: "orders"), in: snapshot(schema)).hits.count == 1)
    }

    @Test func concurrentBuildsDeduplicateAndCancelledCallerThrows() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [table(schema: "public", name: "orders", columns: ["id"])]
        )
        let store = SchemaSearchIndexStore(directory: directory, buildDelayNanoseconds: 50_000_000)
        async let first = store.searcher(for: snapshot(schema))
        async let second = store.searcher(for: snapshot(schema))
        _ = try await [first, second]
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
        #expect(files.count == 1)

        let cancelDirectory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: cancelDirectory) }
        let cancelStore = SchemaSearchIndexStore(
            directory: cancelDirectory,
            buildDelayNanoseconds: 500_000_000
        )
        let task = Task {
            try await cancelStore.searcher(for: snapshot(schema))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test func concurrentStoresTolerateFinalCacheWriteRace() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [table(schema: "public", name: "orders", columns: ["id"])]
        )
        let firstStore = SchemaSearchIndexStore(
            directory: directory,
            buildDelayNanoseconds: 50_000_000
        )
        let secondStore = SchemaSearchIndexStore(
            directory: directory,
            buildDelayNanoseconds: 50_000_000
        )

        async let first = firstStore.searcher(for: snapshot(schema))
        async let second = secondStore.searcher(for: snapshot(schema))
        let searchers = try await [first, second]
        for searcher in searchers {
            #expect(searcher.search(SchemaSearchRequest(query: "orders"), in: snapshot(schema)).hits.count == 1)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
        #expect(files.count == 1)
    }

    @Test func cancellingOneAwaiterDoesNotCancelSharedBuild() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [table(schema: "public", name: "orders", columns: ["id"])]
        )
        let store = SchemaSearchIndexStore(directory: directory, buildDelayNanoseconds: 80_000_000)
        let first = Task {
            try await store.searcher(for: snapshot(schema))
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let second = Task {
            try await store.searcher(for: snapshot(schema))
        }

        first.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        let searcher = try await second.value
        #expect(searcher.search(SchemaSearchRequest(query: "orders"), in: snapshot(schema)).hits.count == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
        #expect(files.count == 1)
    }

    @Test func clearingCacheCancelsInFlightBuilds() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [table(schema: "public", name: "orders", columns: ["id"])]
        )
        let store = SchemaSearchIndexStore(
            directory: directory,
            buildDelayNanoseconds: 500_000_000
        )

        let task = Task {
            try await store.searcher(for: snapshot(schema))
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        await store.removeAllCachedSearchers()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }) ?? []
        #expect(files.isEmpty)
    }

    @Test func persistedIndexDoesNotContainQueryContextSQLOrCredentials() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [table(schema: "public", name: "orders", columns: ["id", "status"])]
        )
        let store = SchemaSearchIndexStore(directory: directory)
        let searcher = try await store.searcher(for: snapshot(schema))
        _ = searcher.search(
            SchemaSearchRequest(
                query: "how many orders",
                databaseContext: "secret business context",
                semanticBindingTerms: ["SELECT * FROM orders", "password=hunter2"]
            ),
            in: snapshot(schema)
        )

        let file = try #require(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
        let text = try String(contentsOf: file, encoding: .utf8)

        #expect(!text.contains("how many orders"))
        #expect(!text.contains("secret business context"))
        #expect(!text.contains("SELECT * FROM orders"))
        #expect(!text.contains("hunter2"))
    }

    private func makeSearcher(
        schema: DatabaseSchema,
        selectedSchemas: [String] = ["public"]
    ) -> LocalSchemaSearcher {
        LocalSchemaSearcher(
            index: LocalSchemaSearchIndex.build(
                snapshot: snapshot(schema, selectedSchemas: selectedSchemas),
                fingerprint: "test"
            )
        )
    }

    private func snapshot(
        _ schema: DatabaseSchema,
        selectedSchemas: [String] = ["public"]
    ) -> SchemaSearchSnapshot {
        SchemaSearchSnapshot(
            connectionID: connectionID,
            selectedSchemas: selectedSchemas,
            schema: schema
        )
    }

    private func table(
        schema: String,
        name: String,
        columns: [String],
        comment: String? = nil
    ) -> TableInfo {
        TableInfo(
            schema: schema,
            name: name,
            type: .baseTable,
            comment: comment,
            columns: columns.enumerated().map { offset, name in
                ColumnInfo(
                    tableSchema: schema,
                    tableName: name == "" ? "" : name.replacingOccurrences(of: " ", with: "_"),
                    name: name,
                    dataType: "text",
                    isNullable: true,
                    ordinalPosition: offset + 1
                )
            }.map {
                ColumnInfo(
                    tableSchema: schema,
                    tableName: name,
                    name: $0.name,
                    dataType: $0.dataType,
                    isNullable: $0.isNullable,
                    ordinalPosition: $0.ordinalPosition
                )
            }
        )
    }

    private func relationshipSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "accounts",
                    type: .baseTable,
                    columns: [
                        column(table: "accounts", name: "tenant_id", ordinal: 1),
                        column(table: "accounts", name: "external_id", ordinal: 2),
                    ],
                    keyConstraints: [
                        SchemaKeyConstraintInfo(
                            constraintName: "accounts_tenant_external_key",
                            schema: "public",
                            table: "accounts",
                            kind: .unique,
                            columns: ["tenant_id", "external_id"]
                        )
                    ]
                ),
                table(schema: "public", name: "account_events", columns: ["tenant_id", "external_id"]),
            ],
            foreignKeyConstraints: [
                SchemaForeignKeyConstraintInfo(
                    constraintName: "account_events_account_fkey",
                    sourceSchema: "public",
                    sourceTable: "account_events",
                    targetSchema: "public",
                    targetTable: "accounts",
                    columnPairs: [
                        SchemaForeignKeyColumnPair(
                            sourceColumn: "tenant_id",
                            targetColumn: "tenant_id",
                            ordinalPosition: 1
                        ),
                        SchemaForeignKeyColumnPair(
                            sourceColumn: "external_id",
                            targetColumn: "external_id",
                            ordinalPosition: 2
                        ),
                    ]
                )
            ]
        )
    }

    private func graphSchema() -> DatabaseSchema {
        let tables = ["a", "b", "c", "d"].map {
            table(schema: "public", name: $0, columns: ["id", "\($0)_id"])
        }
        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: tables,
            foreignKeyConstraints: [
                fk("a_b", from: "a", to: "b"),
                fk("b_d", from: "b", to: "d"),
                fk("a_c", from: "a", to: "c"),
                fk("c_d", from: "c", to: "d"),
                fk("c_a_cycle", from: "c", to: "a"),
            ]
        )
    }

    private func fk(_ name: String, from source: String, to target: String)
        -> SchemaForeignKeyConstraintInfo
    {
        SchemaForeignKeyConstraintInfo(
            constraintName: name,
            sourceSchema: "public",
            sourceTable: source,
            targetSchema: "public",
            targetTable: target,
            columnPairs: [
                SchemaForeignKeyColumnPair(
                    sourceColumn: "\(target)_id",
                    targetColumn: "id",
                    ordinalPosition: 1
                )
            ]
        )
    }

    private func column(table: String, name: String, ordinal: Int) -> ColumnInfo {
        ColumnInfo(
            tableSchema: "public",
            tableName: table,
            name: name,
            dataType: "integer",
            isNullable: false,
            ordinalPosition: ordinal
        )
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-schema-search-\(UUID().uuidString)", isDirectory: true)
    }
}
