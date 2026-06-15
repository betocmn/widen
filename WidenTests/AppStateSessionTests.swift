import Foundation
import Testing

@testable import WidenKit

@Suite("AppState sessions")
@MainActor
struct AppStateSessionTests {
    private struct StubTitleGenerator: SessionTitleGenerating {
        var result: String
        func generateTitle(for question: String) async throws -> String {
            result
        }
    }

    private struct FailingTitleGenerator: SessionTitleGenerating {
        func generateTitle(for question: String) async throws -> String {
            throw AppError.modelUnavailable("The local model is unavailable.")
        }
    }

    private actor SQLRecorder {
        private var statements: [String] = []

        func record(_ sql: String) {
            statements.append(sql)
        }

        func all() -> [String] {
            statements
        }
    }

    private struct RecordingExecutor: QueryExecuting {
        let recorder: SQLRecorder

        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            await recorder.record(sql)
            return QueryResult(
                columns: ["id"],
                rows: [["1"], ["2"]],
                rowCount: 2,
                truncated: false,
                executionTimeMs: 5
            )
        }
    }

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

    @Test func createSessionSelectsAndPersistsIt() throws {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()

        let session = state.createSession(connectionID: connectionID)

        #expect(session.title == QuerySession.placeholderTitle)
        #expect(state.selectedSessionID == session.id)
        #expect(state.selectedController?.sessionID == session.id)
        #expect(state.sessions(for: connectionID).map(\.id) == [session.id])
        #expect(try state.sessionStore.load().map(\.id) == [session.id])
    }

    @Test func viewDataCreatesSelectedSessionAndRunsSelectAll() async throws {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(database: "analytics", username: "u")
        let recorder = SQLRecorder()
        state.connections = [config]
        state.connectionStates[config.id] = .connected
        state.queryExecutorOverride = RecordingExecutor(recorder: recorder)

        let table = TableInfo(schema: "public", name: "users", type: .baseTable, columns: [])

        await state.viewData(for: table, connectionID: config.id)
        await waitUntil {
            state.selectedController?.queryVM.isRunning == false
                && state.selectedController?.chatVM.messages.last?.role == .result
        }

        guard let sessionID = state.selectedSessionID,
            let session = state.session(for: sessionID),
            let controller = state.selectedController
        else {
            Issue.record("Expected a selected view-data session")
            return
        }

        let expectedSQL = #"SELECT * FROM "public"."users""#
        #expect(session.connectionID == config.id)
        #expect(session.title == "View public.users")
        #expect(session.titleWasManuallySet)
        #expect(session.viewDataTarget == QuerySession.ViewDataTarget(schema: "public", table: "users"))
        #expect(session.sqlText == expectedSQL)
        #expect(controller.queryVM.sqlText == expectedSQL)
        #expect(controller.queryVM.generation == nil)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .result])
        #expect(controller.chatVM.messages.first?.text == expectedSQL)
        #expect(controller.chatVM.messages.last?.runSummary?.sql == expectedSQL)
        #expect(controller.results.count == 1)
        #expect(await recorder.all() == [expectedSQL])
    }

    @Test func viewDataReusesExistingVisibleSelectAllSession() async throws {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(database: "analytics", username: "u")
        let recorder = SQLRecorder()
        state.connections = [config]
        state.connectionStates[config.id] = .connected
        state.queryExecutorOverride = RecordingExecutor(recorder: recorder)

        let table = TableInfo(schema: "public", name: "users", type: .baseTable, columns: [])
        let expectedSQL = #"SELECT * FROM "public"."users""#

        await state.viewData(for: table, connectionID: config.id)
        await waitUntil {
            state.selectedController?.queryVM.isRunning == false
                && state.selectedController?.chatVM.messages.last?.role == .result
        }
        let firstSessionID = state.selectedSessionID
        state.selectedController?.chatVM.messages.append(
            ChatMessage(role: .user, text: "Show only recent users")
        )
        state.selectedController?.queryVM.setDirectSQL("SELECT id FROM public.users")
        if let firstSessionID {
            state.sessionDidChange(firstSessionID)
        }

        await state.viewData(for: table, connectionID: config.id)
        await waitUntil {
            state.selectedController?.queryVM.isRunning == false
                && state.selectedController?.chatVM.messages.count == 4
        }

        #expect(state.selectedSessionID == firstSessionID)
        #expect(state.sessions(for: config.id).count == 1)
        #expect(state.selectedController?.queryVM.sqlText == expectedSQL)
        #expect(state.selectedController?.chatVM.messages.map(\.role) == [.user, .result, .user, .result])
        #expect(state.selectedController?.chatVM.messages.last?.runSummary?.sql == expectedSQL)
        #expect(await recorder.all() == [expectedSQL, expectedSQL])
    }

    @Test func selectingViewDataSessionSelectsSchemaTable() async throws {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(database: "analytics", username: "u")
        state.connections = [config]
        state.schemas[config.id] = DatabaseSchema(
            schemas: [SchemaInfo(name: "public"), SchemaInfo(name: "sales")],
            tables: [
                TableInfo(schema: "public", name: "users", type: .baseTable, columns: []),
                TableInfo(schema: "sales", name: "orders", type: .baseTable, columns: []),
            ],
            foreignKeys: []
        )
        let session = state.createSession(
            connectionID: config.id,
            title: "View sales.orders",
            titleWasManuallySet: true,
            viewDataTarget: QuerySession.ViewDataTarget(schema: "sales", table: "orders")
        )
        state.selectSchema("public", for: config.id)
        state.schemaVM.selectedTableID = "public.users"

        state.selectSession(session.id)

        #expect(state.currentSchemaName(for: config.id) == "sales")
        #expect(state.schemaVM.selectedTableID == "sales.orders")
    }

    @Test func viewDataSQLQuotesPostgresIdentifiers() {
        let table = TableInfo(
            schema: "Sales Data",
            name: "select \"odd\" table",
            type: .baseTable,
            columns: []
        )

        #expect(
            AppState.viewDataSQL(for: table)
                == "SELECT * FROM \"Sales Data\".\"select \"\"odd\"\" table\""
        )
    }

    @Test func controllerCacheKeepsRuntimeStateAcrossSwitches() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()
        let first = state.createSession(connectionID: connectionID)
        let second = state.createSession(connectionID: connectionID)

        state.selectSession(first.id)
        let controller = state.selectedController
        controller?.chatVM.input = "draft question"

        state.selectSession(second.id)
        state.selectSession(first.id)

        #expect(state.selectedController === controller)
        #expect(state.selectedController?.chatVM.input == "draft question")
    }

    @Test func switchingSessionsSnapshotsOutgoingEdits() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()
        let first = state.createSession(connectionID: connectionID)
        let second = state.createSession(connectionID: connectionID)

        state.selectSession(first.id)
        state.selectedController?.queryVM.sqlText = "SELECT 1"
        state.selectSession(second.id)

        #expect(state.session(for: first.id)?.sqlText == "SELECT 1")
    }

    @Test func archiveHidesSessionAndMovesSelection() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()
        let first = state.createSession(connectionID: connectionID)
        let second = state.createSession(connectionID: connectionID)
        state.selectSession(second.id)

        state.archiveSession(second.id)

        #expect(state.session(for: second.id)?.isArchived == true)
        #expect(state.sessions(for: connectionID).map(\.id) == [first.id])
        #expect(state.archivedSessions.map(\.id) == [second.id])
        #expect(state.selectedSessionID == first.id)
    }

    @Test func restoreUnarchivesSession() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionID = UUID()
        let session = state.createSession(connectionID: connectionID)
        state.archiveSession(session.id)

        state.restoreSession(session.id)

        #expect(state.session(for: session.id)?.isArchived == false)
        #expect(state.sessions(for: connectionID).map(\.id) == [session.id])
    }

    @Test func deleteForeverRemovesSessionFromDisk() throws {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = state.createSession(connectionID: UUID())
        state.archiveSession(session.id)

        state.deleteSessionForever(session.id)

        #expect(state.session(for: session.id) == nil)
        #expect(try state.sessionStore.load().isEmpty)
    }

    @Test func manualRenameBlocksGeneratedTitles() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = state.createSession(connectionID: UUID())

        state.renameSession(session.id, to: "MY TITLE")
        state.applyGeneratedTitle("Generated Title", to: session.id)

        #expect(state.session(for: session.id)?.title == "My Title")
        #expect(state.session(for: session.id)?.titleWasManuallySet == true)
    }

    @Test func generatedTitleOnlyReplacesThePlaceholder() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = state.createSession(connectionID: UUID())

        state.applyGeneratedTitle("Top Spenders", to: session.id)
        state.applyGeneratedTitle("Something Else", to: session.id)

        #expect(state.session(for: session.id)?.title == "Top Spenders")
        #expect(state.session(for: session.id)?.titleWasManuallySet == false)
    }

    @Test func emptyRenameIsIgnored() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = state.createSession(connectionID: UUID())

        state.renameSession(session.id, to: "   ")

        #expect(state.session(for: session.id)?.title == QuerySession.placeholderTitle)
        #expect(state.session(for: session.id)?.titleWasManuallySet == false)
    }

    @Test func autoTitleAppliesSanitizedGeneratedTitle() async {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.titleGeneratorOverride = StubTitleGenerator(result: "\"Top Spenders.\"")
        let session = state.createSession(connectionID: UUID())

        await state.autoTitleSession(session.id, question: "Which users have spent the most?")

        #expect(state.session(for: session.id)?.title == "Top Spenders")
        #expect(state.session(for: session.id)?.titleWasManuallySet == false)
    }

    @Test func autoTitleFallsBackToTruncatedQuestionOnFailure() async {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.titleGeneratorOverride = FailingTitleGenerator()
        let session = state.createSession(connectionID: UUID())

        await state.autoTitleSession(session.id, question: "Which users have spent the most?")

        #expect(state.session(for: session.id)?.title == "Which Users Have Spent The Most?")
    }

    @Test func autoTitleNeverOverridesAManualRename() async {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.titleGeneratorOverride = StubTitleGenerator(result: "Generated Title")
        let session = state.createSession(connectionID: UUID())
        state.renameSession(session.id, to: "My Title")

        await state.autoTitleSession(session.id, question: "anything")

        #expect(state.session(for: session.id)?.title == "My Title")
    }

    @Test func launchDoesNotAutoSelectRestoredSessionOrFirstDatabase() async throws {
        UserDefaults.standard.removeObject(forKey: "WidenSelectedSessionID")
        let (state, dir) = makeState()
        defer {
            UserDefaults.standard.removeObject(forKey: "WidenSelectedSessionID")
            try? FileManager.default.removeItem(at: dir)
        }
        let config = DatabaseConnectionConfig(database: "db", username: "u")
        let session = QuerySession(connectionID: config.id)
        try state.connectionStore.save([config])
        try state.sessionStore.save([session])
        UserDefaults.standard.set(session.id.uuidString, forKey: "WidenSelectedSessionID")

        await state.onLaunch()

        #expect(state.connections.map(\.id) == [config.id])
        #expect(state.sessions.map(\.id) == [session.id])
        #expect(state.sidebarSelection == nil)
        #expect(state.activeConnectionID == nil)
        #expect(state.openSettingsRequest == 0)
    }

    @Test func launchWithNoDatabasesLeavesWelcomeState() async {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }

        await state.onLaunch()

        #expect(state.connections.isEmpty)
        #expect(state.sidebarSelection == nil)
        #expect(state.openSettingsRequest == 0)
    }

    @Test func selectingDatabaseMakesItTheActiveConnection() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(database: "db", username: "u")
        state.connections = [config]

        state.selectDatabase(config.id)

        #expect(state.sidebarSelection == .database(config.id))
        #expect(state.activeConnectionID == config.id)
        #expect(state.selectedSessionID == nil)
        #expect(state.selectedController == nil)
    }

    @Test func selectingNilFallsBackToTheFirstDatabase() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(database: "db", username: "u")
        state.connections = [config]

        state.selectSession(nil)

        #expect(state.sidebarSelection == .database(config.id))
        #expect(state.activeConnectionID == config.id)
    }

    @Test func archivingTheLastSessionSelectsItsDatabase() {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(database: "db", username: "u")
        state.connections = [config]
        let session = state.createSession(connectionID: config.id)

        state.archiveSession(session.id)

        #expect(state.sidebarSelection == .database(config.id))
        #expect(state.selectedSessionID == nil)
    }

    @Test func deleteConnectionCascadesToItsSessions() throws {
        let (state, dir) = makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = DatabaseConnectionConfig(database: "db", username: "u")
        let other = DatabaseConnectionConfig(database: "other", username: "u")
        state.connections = [config, other]
        let doomed = state.createSession(connectionID: config.id)
        let survivor = state.createSession(connectionID: other.id)
        state.selectSession(doomed.id)

        state.deleteConnection(config.id)

        #expect(state.connections.map(\.id) == [other.id])
        #expect(state.sessions.map(\.id) == [survivor.id])
        #expect(state.selectedSessionID == survivor.id)
        #expect(try state.sessionStore.load().map(\.id) == [survivor.id])
        #expect(try state.connectionStore.load().map(\.id) == [other.id])
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}
