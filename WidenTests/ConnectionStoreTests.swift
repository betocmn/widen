import Foundation
import Testing

@testable import WidenKit

@Suite("ConnectionStore")
struct ConnectionStoreTests {
    private func makeTempStore() -> (ConnectionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        return (ConnectionStore(directory: dir), dir)
    }

    @Test func loadFromEmptyDirectoryReturnsNoConnections() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.load().isEmpty)
    }

    @Test func saveAndLoadRoundTripPreservesMultipleConnections() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var first = DatabaseConnectionConfig(
            name: "Test",
            host: "localhost",
            port: 5433,
            database: "widen_test",
            username: "beto",
            sslMode: .prefer,
            defaultRowLimit: 250,
            statementTimeoutSeconds: 30,
            databaseContext: "orders.user_id joins users.id",
            allowCloudSchemaMetadata: true,
            allowLocalDataInspection: true,
            allowCloudDataInspection: true,
            allowSampleRowInspection: true,
            sensitiveColumnRules: ["customer_email"],
            redactedColumnIDs: ["column-stable-id"]
        )
        first.updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let second = DatabaseConnectionConfig(
            name: "Staging", host: "10.0.0.5", database: "staging", username: "svc")
        try store.save([first, second])

        let all = try store.load()
        #expect(all.count == 2)
        let loaded = try #require(all.first)
        #expect(loaded.id == first.id)
        #expect(loaded.name == "Test")
        #expect(loaded.host == "localhost")
        #expect(loaded.port == 5433)
        #expect(loaded.database == "widen_test")
        #expect(loaded.username == "beto")
        #expect(loaded.sslMode == .prefer)
        #expect(loaded.defaultRowLimit == 250)
        #expect(loaded.statementTimeoutSeconds == 30)
        #expect(loaded.databaseContext == "orders.user_id joins users.id")
        #expect(loaded.allowCloudSchemaMetadata)
        #expect(loaded.allowLocalDataInspection)
        #expect(loaded.allowCloudDataInspection)
        #expect(loaded.allowSampleRowInspection)
        #expect(loaded.sensitiveColumnRules == ["customer_email"])
        #expect(loaded.redactedColumnIDs == ["column-stable-id"])
        #expect(all.last?.id == second.id)
        #expect(all.last?.name == "Staging")
    }

    @Test func legacyConnectionsWithoutDatabaseContextDecode() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = """
            [
              {
                "id": "11111111-2222-3333-4444-555555555555",
                "name": "Legacy",
                "host": "localhost",
                "port": 5432,
                "database": "legacy_db",
                "username": "postgres",
                "sslMode": "disable",
                "defaultRowLimit": 100,
                "statementTimeoutSeconds": 10,
                "createdAt": "2025-06-15T12:00:00Z",
                "updatedAt": "2025-06-15T12:00:00Z"
              }
            ]
            """
        try Data(legacy.utf8).write(to: store.fileURL)

        let loaded = try #require(store.load().first)

        #expect(loaded.name == "Legacy")
        #expect(loaded.databaseContext == "")
        #expect(loaded.allowCloudSchemaMetadata)
        #expect(!loaded.allowLocalDataInspection)
        #expect(!loaded.allowCloudDataInspection)
        #expect(!loaded.allowSampleRowInspection)
        #expect(loaded.sensitiveColumnRules.isEmpty)
        #expect(loaded.redactedColumnIDs.isEmpty)
    }

    @Test func savedFileNeverContainsPasswordField() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save([DatabaseConnectionConfig(database: "db", username: "user")])
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!raw.lowercased().contains("password"))
    }

    @Test func saveOverwritesPreviousContents() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save([DatabaseConnectionConfig(name: "One", database: "a", username: "u")])
        try store.save([DatabaseConnectionConfig(name: "Two", database: "b", username: "u")])
        let all = try store.load()
        #expect(all.count == 1)
        #expect(all.first?.name == "Two")
    }
}

@Suite("DatabaseSemanticBindingStore")
struct DatabaseSemanticBindingStoreTests {
    private func makeSchema(
        includeName: Bool = true,
        statusValues: [String]? = nil
    ) -> DatabaseSchema {
        let statusColumns =
            statusValues.map { values in
                [
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "users",
                        name: "status",
                        dataType: "text",
                        isNullable: false,
                        ordinalPosition: 3,
                        valueConstraints: [
                            ColumnValueConstraint(
                                kind: .check,
                                values: values,
                                expression: "CHECK (status IN (\(values.map { "'\($0)'" }.joined(separator: ", "))))"
                            )
                        ]
                    )
                ]
            } ?? []
        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "users",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                    ] + (includeName ? [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "name",
                            dataType: "text",
                            isNullable: true,
                            ordinalPosition: 2
                        )
                    ] : []) + statusColumns
                )
            ],
            foreignKeys: []
        )
    }

    @Test func roundTripIsSeparateFromConnectionCredentials() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-bindings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()
        let schema = makeSchema()
        let bindingStore = DatabaseSemanticBindingStore(directory: dir)
        let connectionStore = ConnectionStore(directory: dir)
        let binding = DatabaseSemanticBinding(
            connectionID: connectionID,
            schemaNames: schema.semanticBindingSchemaNames,
            schemaFingerprint: schema.semanticFingerprint,
            concept: "active users",
            definition: #"status = 'active'"#,
            evidence: ["public.users.status"],
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        try connectionStore.save([DatabaseConnectionConfig(id: connectionID, database: "db", username: "u")])
        try bindingStore.save([binding])

        #expect(try bindingStore.load() == [binding])
        let connectionJSON = try String(contentsOf: connectionStore.fileURL, encoding: .utf8)
        #expect(!connectionJSON.contains("active users"))
        #expect(!connectionJSON.contains("semantic"))
    }

    @Test func currentBindingsExcludeSchemaDrift() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-bindings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DatabaseSemanticBindingStore(directory: dir)
        let connectionID = UUID()
        let original = makeSchema()
        let drifted = makeSchema(includeName: false)
        let binding = DatabaseSemanticBinding(
            connectionID: connectionID,
            schemaNames: original.semanticBindingSchemaNames,
            schemaFingerprint: original.semanticFingerprint,
            concept: "active users",
            definition: #"status = 'active'"#
        )

        #expect(store.currentBindings([binding], connectionID: connectionID, schema: original) == [binding])
        #expect(store.currentBindings([binding], connectionID: connectionID, schema: drifted).isEmpty)
    }

    @Test func currentBindingsExcludeConstraintDrift() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-bindings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DatabaseSemanticBindingStore(directory: dir)
        let connectionID = UUID()
        let original = makeSchema(statusValues: ["active", "inactive"])
        let drifted = makeSchema(statusValues: ["enabled", "disabled"])
        let binding = DatabaseSemanticBinding(
            connectionID: connectionID,
            schemaNames: original.semanticBindingSchemaNames,
            schemaFingerprint: original.semanticFingerprint,
            concept: "active users",
            definition: #"status = 'active'"#
        )

        #expect(store.currentBindings([binding], connectionID: connectionID, schema: original) == [binding])
        #expect(store.currentBindings([binding], connectionID: connectionID, schema: drifted).isEmpty)
    }
}

@Suite("ConnectionSettingsViewModel validation")
@MainActor
struct ConnectionSettingsViewModelTests {
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

    private func makeValidViewModel() -> ConnectionSettingsViewModel {
        let viewModel = ConnectionSettingsViewModel()
        viewModel.host = "localhost"
        viewModel.portText = "5432"
        viewModel.database = "widen_test"
        viewModel.username = "beto"
        return viewModel
    }

    @Test func validFormBuildsConfig() {
        let viewModel = makeValidViewModel()
        let config = viewModel.buildConfig()
        #expect(config != nil)
        #expect(viewModel.validationErrors.isEmpty)
        #expect(config?.port == 5432)
        #expect(config?.defaultRowLimit == 100)
        #expect(config?.statementTimeoutSeconds == 10)
        #expect(config?.allowLocalDataInspection == false)
        #expect(config?.allowCloudDataInspection == false)
    }

    @Test func queryContextIsTrimmedAndSaved() {
        let viewModel = makeValidViewModel()
        viewModel.databaseContext = "  orders.user_id joins users.id\n"

        let config = viewModel.buildConfig()

        #expect(config?.databaseContext == "orders.user_id joins users.id")
    }

    @Test func privacySettingsAreSavedAndCloudDataRequiresLocalInspection() {
        let viewModel = makeValidViewModel()
        viewModel.allowLocalDataInspection = true
        viewModel.allowCloudDataInspection = true

        let enabled = viewModel.buildConfig()

        #expect(enabled?.allowLocalDataInspection == true)
        #expect(enabled?.allowCloudDataInspection == true)

        viewModel.allowLocalDataInspection = false
        let cloudOnly = viewModel.buildConfig()

        #expect(cloudOnly?.allowLocalDataInspection == false)
        #expect(cloudOnly?.allowCloudDataInspection == false)
    }

    @Test func invalidPortIsRejected() {
        let viewModel = makeValidViewModel()
        viewModel.portText = "70000"
        #expect(viewModel.buildConfig() == nil)
        #expect(viewModel.validationErrors.contains { $0.contains("Port") })
    }

    @Test func missingRequiredFieldsAreRejected() {
        let viewModel = ConnectionSettingsViewModel()
        viewModel.host = " "
        viewModel.database = ""
        viewModel.username = ""
        #expect(viewModel.buildConfig() == nil)
        #expect(viewModel.validationErrors.count >= 3)
    }

    @Test func rowLimitAndTimeoutRangesAreEnforced() {
        let viewModel = makeValidViewModel()
        viewModel.rowLimitText = "0"
        viewModel.timeoutText = "500"
        #expect(viewModel.buildConfig() == nil)
        #expect(viewModel.validationErrors.contains { $0.contains("Row limit") })
        #expect(viewModel.validationErrors.contains { $0.contains("Timeout") })
    }

    @Test func queryContextLengthIsEnforced() {
        let viewModel = makeValidViewModel()
        viewModel.databaseContext = String(
            repeating: "x",
            count: SQLPromptBuilder.maxDatabaseContextCharacters + 1
        )

        #expect(viewModel.buildConfig() == nil)
        #expect(viewModel.validationErrors.contains { $0.contains("Query context") })
    }

    @Test func emptyPasswordIsAllowed() {
        let viewModel = makeValidViewModel()
        viewModel.password = ""
        #expect(viewModel.buildConfig() != nil)
    }

    @Test func newFormStartsCleanAndTracksEdits() {
        let viewModel = ConnectionSettingsViewModel()
        viewModel.startNew()

        #expect(!viewModel.hasUnsavedChanges)
        #expect(viewModel.name.isEmpty)
        #expect(viewModel.username == "postgres")

        viewModel.database = "widen_test"
        #expect(viewModel.hasUnsavedChanges)

        viewModel.startNew()
        #expect(!viewModel.hasUnsavedChanges)
    }

    @Test func loadedFormStartsCleanAndTracksEdits() {
        let config = DatabaseConnectionConfig(
            name: "Local",
            host: "localhost",
            database: "widen_test",
            username: NSUserName()
        )
        let viewModel = ConnectionSettingsViewModel()

        viewModel.load(from: config)
        #expect(!viewModel.hasUnsavedChanges)

        viewModel.host = "127.0.0.1"
        #expect(viewModel.hasUnsavedChanges)

        viewModel.load(from: config)
        #expect(!viewModel.hasUnsavedChanges)
    }

    @Test func successfulSaveUpdatesCleanSnapshot() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let viewModel = makeValidViewModel()

        #expect(viewModel.hasUnsavedChanges)

        let saved = viewModel.save(appState: state)

        #expect(saved != nil)
        #expect(!viewModel.hasUnsavedChanges)

        viewModel.rowLimitText = "250"
        #expect(viewModel.hasUnsavedChanges)
    }

    @Test func emptyNicknameFallsBackToDatabaseNameOnSave() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let viewModel = makeValidViewModel()
        viewModel.name = " "

        let saved = viewModel.save(appState: state)

        #expect(saved?.name == "widen_test")
        #expect(state.connections.first?.name == "widen_test")
    }

    @Test func testConnectionValidationUsesFooterState() async {
        let viewModel = ConnectionSettingsViewModel()
        viewModel.startNew()

        await viewModel.testConnection()

        #expect(viewModel.validationErrors.isEmpty)
        #expect(viewModel.testState == .failure("Database is required."))
    }

    @Test func saveStillWorksAfterConnectionTestFailure() async {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let viewModel = ConnectionSettingsViewModel { _, _ in
            throw AppError.notConnected
        }
        viewModel.host = "localhost"
        viewModel.portText = "5432"
        viewModel.database = "widen_test"
        viewModel.username = "postgres"

        await viewModel.testConnection()
        let saved = viewModel.save(appState: state)

        #expect(saved != nil)
        #expect(state.connections.map(\.id) == [saved?.id])
        #expect(viewModel.testState == .failure(AppError.notConnected.errorDescription ?? ""))
    }
}
