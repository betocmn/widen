import Foundation
import Testing

@testable import WidenKit

@Suite("AppState schema selection")
@MainActor
struct AppStateSchemaTests {
    private func makeState() -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            connectionStore: ConnectionStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            schemaStore: SchemaStore(directory: dir)
        )
        return (state, dir)
    }

    private func makeSchema(
        schemas: [String],
        loadedAt: Date = Date()
    ) -> DatabaseSchema {
        DatabaseSchema(
            schemas: schemas.map(SchemaInfo.init(name:)),
            tables: schemas.flatMap { schema in
                [
                    TableInfo(
                        schema: schema, name: "users", type: .baseTable,
                        columns: [
                            ColumnInfo(
                                tableSchema: schema, tableName: "users", name: "id",
                                dataType: "integer", isNullable: false, ordinalPosition: 1)
                        ]),
                    TableInfo(
                        schema: schema, name: "orders", type: .baseTable,
                        columns: [
                            ColumnInfo(
                                tableSchema: schema, tableName: "orders", name: "user_id",
                                dataType: "integer", isNullable: false, ordinalPosition: 1)
                        ]),
                ]
            },
            foreignKeys: schemas.map { schema in
                ForeignKeyInfo(
                    constraintName: "orders_user_id_fkey",
                    sourceSchema: schema, sourceTable: "orders", sourceColumn: "user_id",
                    targetSchema: schema, targetTable: "users", targetColumn: "id")
            },
            loadedAt: loadedAt
        )
    }

    private func cleanDefaults() {
        UserDefaults.standard.removeObject(forKey: "WidenSelectedSchemaNames")
    }

    @Test func currentSchemaFallsBackToPublicThenFirst() {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()

        #expect(state.currentSchemaName(for: id) == nil)

        state.schemas[id] = makeSchema(schemas: ["analytics", "public"])
        #expect(state.currentSchemaName(for: id) == "public")

        state.schemas[id] = makeSchema(schemas: ["analytics", "sales"])
        #expect(state.currentSchemaName(for: id) == "analytics")
    }

    @Test func selectedSchemaWinsWhileItExists() {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        state.schemas[id] = makeSchema(schemas: ["analytics", "public"])

        state.selectSchema("analytics", for: id)
        #expect(state.currentSchemaName(for: id) == "analytics")

        // A refresh that drops the chosen schema silently falls back.
        state.schemas[id] = makeSchema(schemas: ["public", "sales"])
        #expect(state.currentSchemaName(for: id) == "public")
    }

    @Test func promptSchemaIsScopedToOpenSchema() {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        state.schemas[id] = makeSchema(schemas: ["analytics", "public"])
        state.selectSchema("analytics", for: id)

        let prompt = state.promptSchema(for: id)

        #expect(prompt?.schemas.map(\.name) == ["analytics"])
        #expect(prompt?.tables.allSatisfy { $0.schema == "analytics" } == true)
        #expect(prompt?.tables.count == 2)
        #expect(prompt?.foreignKeys.count == 1)
        #expect(prompt?.foreignKeys.allSatisfy { $0.sourceSchema == "analytics" } == true)
    }

    @Test func confirmedSemanticBindingStoresNormalizedObjectMetadata() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()
        let schema = makeSchema(schemas: ["public"])
        let option = ClarificationOption(
            label: "public.users.status",
            replyText: "Use public.users.status",
            definition: "public.users.status    =   'enabled'",
            evidence: ["public.users.status"]
        )
        let pending = PendingClarification(
            concept: SQLGroundingConcept(
                term: "active account",
                kind: .businessTerm,
                state: .unsupported,
                required: true
            ),
            originalQuestion: "show active accounts",
            plan: GroundedQueryPlan(
                intent: QueryIntentFrame(customBusinessTerms: ["active"]),
                slots: [
                    GroundingSlot(
                        id: .customBusinessTerm,
                        kind: .customBusinessTerm,
                        phrase: "active account",
                        required: true,
                        candidates: [
                            GroundingCandidate(
                                id: "column:public.users.status",
                                label: "public.users.status",
                                objectIDs: ["column:public.users.status"],
                                evidence: ["public.users.status"]
                            )
                        ],
                        state: .ambiguous
                    )
                ],
                readiness: .needsClarification
            ),
            slotID: .customBusinessTerm,
            question: "What should active account mean?",
            options: [option],
            evidence: ["public.users.status"]
        )

        state.confirmSemanticBinding(
            connectionID: connectionID,
            pending: pending,
            replyText: option.replyText,
            selectedOption: option,
            schema: schema
        )

        #expect(state.semanticBindings.count == 1)
        #expect(state.semanticBindings[0].concept == "active account")
        #expect(state.semanticBindings[0].normalizedDefinition == "public.users.status = 'enabled'")
        #expect(state.semanticBindings[0].referencedObjectIDs == ["column:public.users.status"])
        #expect(state.semanticBindings[0].originatingClarificationID == pending.id)
    }

    @Test func genericOperatorSemanticBindingIsNotPersisted() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pending = PendingClarification(
            concept: SQLGroundingConcept(
                term: "frequent",
                kind: .metric,
                state: .unsupported,
                required: true
            ),
            originalQuestion: "most frequent users",
            question: "What defines frequent?"
        )

        state.confirmSemanticBinding(
            connectionID: UUID(),
            pending: pending,
            replyText: "COUNT(*)",
            selectedOption: nil,
            schema: makeSchema(schemas: ["public"])
        )

        #expect(state.semanticBindings.isEmpty)
    }

    @Test func generatedSessionRestoreUsesSavedGenerationSchema() throws {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(database: "db", username: "u")
        let generation = SQLGenerationResult(
            sql: "SELECT id FROM analytics.users",
            explanation: "Lists users.",
            assumptions: [],
            referencedTables: ["analytics.users"],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil,
            generationSchemaName: "analytics"
        )
        let session = QuerySession(
            connectionID: config.id,
            sqlText: generation.sql,
            lastGeneration: generation
        )
        state.connections = [config]
        state.schemas[config.id] = makeSchema(schemas: ["analytics", "public"])
        state.selectSchema("public", for: config.id)
        state.sessions = [session]

        state.selectSession(session.id)
        let controller = try #require(state.selectedController)

        #expect(controller.queryVM.validation?.isValid == true)
        #expect(controller.queryVM.schemaValidation?.referencedTables == ["analytics.users"])
    }

    @Test func legacyGeneratedSessionRestoreInfersQualifiedSchema() throws {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(database: "db", username: "u")
        let generation = SQLGenerationResult(
            sql: "SELECT id FROM analytics.users",
            explanation: "Lists users.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil,
            generationSchemaName: nil
        )
        let session = QuerySession(
            connectionID: config.id,
            sqlText: generation.sql,
            lastGeneration: generation
        )
        state.connections = [config]
        state.schemas[config.id] = makeSchema(schemas: ["analytics", "public"])
        state.selectSchema("public", for: config.id)
        state.sessions = [session]

        state.selectSession(session.id)
        let controller = try #require(state.selectedController)

        #expect(controller.queryVM.validation?.isValid == true)
        #expect(controller.queryVM.schemaValidation?.referencedTables == ["analytics.users"])
    }

    @Test func launchHydratesCachedSchemasForConfiguredConnections() async throws {
        defer { cleanDefaults() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionStore = ConnectionStore(directory: dir)
        let sessionStore = SessionStore(directory: dir)
        let schemaStore = SchemaStore(directory: dir)
        let config = DatabaseConnectionConfig(database: "db", username: "u")
        let cachedSchema = makeSchema(
            schemas: ["public"], loadedAt: Date(timeIntervalSince1970: 1_750_000_000))
        try connectionStore.save([config])
        try schemaStore.save([config.id: cachedSchema])
        let state = AppState(
            connectionStore: connectionStore, sessionStore: sessionStore,
            schemaStore: schemaStore)

        await state.onLaunch()

        #expect(state.schemas[config.id] == cachedSchema)
    }

    @Test func launchIgnoresCachedSchemasForMissingConnections() async throws {
        defer { cleanDefaults() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionStore = ConnectionStore(directory: dir)
        let sessionStore = SessionStore(directory: dir)
        let schemaStore = SchemaStore(directory: dir)
        let config = DatabaseConnectionConfig(database: "db", username: "u")
        let staleID = UUID()
        let cachedSchema = makeSchema(
            schemas: ["public"], loadedAt: Date(timeIntervalSince1970: 1_750_000_000))
        try connectionStore.save([config])
        try schemaStore.save([
            config.id: cachedSchema,
            staleID: makeSchema(
                schemas: ["analytics"], loadedAt: Date(timeIntervalSince1970: 1_750_000_100)),
        ])
        let state = AppState(
            connectionStore: connectionStore, sessionStore: sessionStore,
            schemaStore: schemaStore)

        await state.onLaunch()

        #expect(state.schemas[config.id] == cachedSchema)
        #expect(state.schemas[staleID] == nil)
    }

    @Test func filteredDropsCrossSchemaForeignKeys() {
        var schema = makeSchema(schemas: ["public", "analytics"])
        schema.foreignKeys.append(
            ForeignKeyInfo(
                constraintName: "events_user_id_fkey",
                sourceSchema: "analytics", sourceTable: "events", sourceColumn: "user_id",
                targetSchema: "public", targetTable: "users", targetColumn: "id"))

        let filtered = schema.filtered(toSchema: "analytics")

        #expect(filtered.foreignKeys.count == 1)
        #expect(filtered.foreignKeys.first?.constraintName == "orders_user_id_fkey")
    }

    @Test func deleteConnectionPrunesSchemaSelectionAndCache() throws {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(id: UUID())
        state.connections = [config]
        state.selectSchema("analytics", for: config.id)
        state.schemas[config.id] = makeSchema(schemas: ["analytics"])
        try state.schemaStore.save(state.schemas)

        state.deleteConnection(config.id)

        #expect(state.selectedSchemaNames[config.id] == nil)
        #expect(state.schemas[config.id] == nil)
        #expect(try state.schemaStore.load()[config.id] == nil)
    }

    @Test func endpointEditClearsPersistedSchemaCache() throws {
        defer { cleanDefaults() }
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = DatabaseConnectionConfig(database: "db", username: "u")
        state.connections = [config]
        state.schemas[config.id] = makeSchema(schemas: ["public"])
        try state.schemaStore.save(state.schemas)

        config.database = "other"
        try state.addOrUpdateConnection(config, password: "")

        #expect(state.schemas[config.id] == nil)
        #expect(try state.schemaStore.load()[config.id] == nil)
    }

    @Test func schemaViewModelListsOnlyOpenSchemaTables() {
        let schemaVM = SchemaViewModel()
        let schema = makeSchema(schemas: ["analytics", "public"])

        let tables = schemaVM.tables(in: schema, schemaName: "analytics")
        #expect(tables.map(\.name) == ["orders", "users"])
        #expect(tables.allSatisfy { $0.schema == "analytics" })

        schemaVM.searchText = "use"
        #expect(schemaVM.tables(in: schema, schemaName: "analytics").map(\.name) == ["users"])

        // The schema name itself must not match every table.
        schemaVM.searchText = "analytics"
        #expect(schemaVM.tables(in: schema, schemaName: "analytics").isEmpty)

        schemaVM.searchText = ""
        #expect(schemaVM.tables(in: nil, schemaName: "analytics").isEmpty)
        #expect(schemaVM.tables(in: schema, schemaName: nil).isEmpty)
    }
}
