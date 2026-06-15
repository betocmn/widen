import Foundation
import Testing

@testable import WidenKit

@Suite("WidenKit smoke")
@MainActor
struct WidenKitSmokeTests {
    @Test func appStateInitialStatus() async throws {
        let state = AppState()
        #expect(state.connections.isEmpty)
        #expect(state.connectionState(UUID()) == .notConnected)
        #expect(state.selectedSessionID == nil)
        #expect(state.selectedController == nil)
    }

    @Test func openNewDatabaseSettingsSelectsDatabasesAndRequestsDraft() {
        let state = AppState()

        state.openNewDatabaseSettings()

        #expect(state.settingsTab == .databases)
        #expect(state.openSettingsRequest == 1)
        #expect(state.newDatabaseSettingsRequest == 1)
        #expect(state.databaseSettingsRequest == 1)
        #expect(state.pendingDatabaseSettingsRequest == .new)
    }

    @Test func openDatabaseSettingsSelectsDatabasesAndRequestsConnection() {
        let state = AppState()
        let id = UUID()

        state.openDatabaseSettings(connectionID: id)

        #expect(state.settingsTab == .databases)
        #expect(state.openSettingsRequest == 1)
        #expect(state.editDatabaseSettingsRequest == 1)
        #expect(state.editDatabaseSettingsID == id)
        #expect(state.databaseSettingsRequest == 1)
        #expect(state.pendingDatabaseSettingsRequest == .edit(id))
    }

    @Test func refreshSchemaPreservesCachedSchemaWhenIntrospectionFails() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState(
            connectionStore: ConnectionStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            schemaStore: SchemaStore(directory: dir)
        )
        let id = UUID()
        let cachedSchema = makeSchema()
        state.connectionStates[id] = .connected
        state.schemas[id] = cachedSchema

        await state.refreshSchema(for: id)

        #expect(state.schemas[id] == cachedSchema)
        #expect(state.errorBanner != nil)
        #expect(!state.loadingSchemas.contains(id))
    }

    private func makeSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "users", type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public", tableName: "users", name: "id",
                            dataType: "integer", isNullable: false, ordinalPosition: 1)
                    ])
            ],
            foreignKeys: []
        )
    }
}

@Suite("QueryResultDisplayPolicy")
struct QueryResultDisplayPolicyTests {
    @Test func displayRowsAreCappedButCSVKeepsAllRows() {
        let rows = (1...45).map { [Optional("\($0)")] }
        let result = QueryResult(
            columns: ["id"],
            rows: rows,
            rowCount: rows.count,
            truncated: false,
            executionTimeMs: 1
        )

        let firstPage = QueryResultDisplayPolicy.rows(result.rows, page: 0)
        let secondPage = QueryResultDisplayPolicy.rows(result.rows, page: 1)
        let lastPage = QueryResultDisplayPolicy.rows(result.rows, page: 99)

        #expect(QueryResultDisplayPolicy.maxRowsPerPage == 20)
        #expect(QueryResultDisplayPolicy.pageCount(forRowCount: result.rows.count) == 3)
        #expect(firstPage.count == 20)
        #expect(secondPage[0][0] == "21")
        #expect(lastPage.count == 5)
        #expect(lastPage[4][0] == "45")
        #expect(result.csv().split(separator: "\n").count == 46)
    }
}

@Suite("QueryResultViewModel")
@MainActor
struct QueryResultViewModelTests {
    private struct ImmediateExecutor: QueryExecuting {
        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            QueryResult(
                columns: ["value"],
                rows: [["1"]],
                rowCount: 1,
                truncated: false,
                executionTimeMs: 1
            )
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
                columns: ["value"],
                rows: [["1"]],
                rowCount: 1,
                truncated: false,
                executionTimeMs: 1
            )
        }
    }

    private struct SlowExecutor: QueryExecuting {
        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            try await Task.sleep(for: .seconds(30))
            return QueryResult(
                columns: ["value"],
                rows: [["1"]],
                rowCount: 1,
                truncated: false,
                executionTimeMs: 1
            )
        }
    }

    @Test func invalidRunClearsPreviousResult() async {
        let postgres = PostgresService()
        let viewModel = QueryResultViewModel(executor: ImmediateExecutor())
        viewModel.sqlText = "SELECT 1"

        viewModel.startRun(
            connection: DatabaseConnectionConfig(), postgres: postgres, isConnected: true)
        await waitUntil { viewModel.result != nil && !viewModel.isRunning }
        #expect(viewModel.result != nil)

        viewModel.sqlText = "DELETE FROM users"
        viewModel.startRun(
            connection: DatabaseConnectionConfig(), postgres: postgres, isConnected: true)
        await waitUntil { !viewModel.isRunning }

        #expect(viewModel.result == nil)
        #expect(viewModel.validation?.isValid == false)
        #expect(viewModel.runError?.contains("The SQL failed validation") == true)
    }

    @Test func runExecutesSQLSnapshottedAtStart() async {
        let recorder = SQLRecorder()
        let viewModel = QueryResultViewModel(executor: RecordingExecutor(recorder: recorder))
        viewModel.sqlText = "SELECT 1"

        viewModel.startRun(
            connection: DatabaseConnectionConfig(), postgres: PostgresService(), isConnected: true)
        viewModel.sqlText = "DELETE FROM users"
        await waitUntil { !viewModel.isRunning }

        let statements = await recorder.all()
        #expect(statements == ["SELECT 1"])
        #expect(viewModel.result?.rowCount == 1)
    }

    @Test func notConnectedRunReportsError() async {
        let viewModel = QueryResultViewModel(executor: ImmediateExecutor())
        viewModel.sqlText = "SELECT 1"

        viewModel.startRun(
            connection: DatabaseConnectionConfig(), postgres: PostgresService(),
            isConnected: false)
        await waitUntil { !viewModel.isRunning }

        #expect(viewModel.result == nil)
        #expect(viewModel.runError == AppError.notConnected.errorDescription)
    }

    @Test func restoreRehydratesEditorWithoutResults() {
        let viewModel = QueryResultViewModel(executor: ImmediateExecutor())
        let generation = SQLGenerationResult(
            sql: "SELECT 1",
            explanation: "Constant.",
            assumptions: [],
            referencedTables: [],
            confidence: 1.0,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        viewModel.restore(sqlText: "SELECT 1", generation: generation)

        #expect(viewModel.sqlText == "SELECT 1")
        #expect(viewModel.generation == generation)
        #expect(viewModel.result == nil)
        #expect(viewModel.validation?.isValid == true)
    }

    @Test func cancelRunReleasesRunningStateImmediately() async {
        let viewModel = QueryResultViewModel(executor: SlowExecutor())
        viewModel.sqlText = "SELECT 1"

        viewModel.startRun(
            connection: DatabaseConnectionConfig(), postgres: PostgresService(),
            isConnected: true)
        #expect(viewModel.isRunning)

        viewModel.cancelRun()

        #expect(viewModel.isRunning == false)
        #expect(viewModel.runError?.contains("Stopped waiting") == true)
        await Task.yield()
        #expect(viewModel.result == nil)
    }

    @Test func onFinishReceivesResultOnSuccess() async {
        let viewModel = QueryResultViewModel(executor: ImmediateExecutor())
        viewModel.sqlText = "SELECT 1"
        var completions: [(QueryResult?, String?)] = []

        viewModel.startRun(
            connection: DatabaseConnectionConfig(), postgres: PostgresService(),
            isConnected: true
        ) { result, error in
            completions.append((result, error))
        }
        await waitUntil { !viewModel.isRunning }

        #expect(completions.count == 1)
        #expect(completions.first?.0?.rowCount == 1)
        #expect(completions.first?.1 == nil)

        // A second run must not re-fire the first run's completion.
        viewModel.startRun(
            connection: DatabaseConnectionConfig(), postgres: PostgresService(),
            isConnected: true)
        await waitUntil { !viewModel.isRunning }
        #expect(completions.count == 1)
    }

    @Test func onFinishReceivesErrorWhenNotConnected() async {
        let viewModel = QueryResultViewModel(executor: ImmediateExecutor())
        viewModel.sqlText = "SELECT 1"
        var completions: [(QueryResult?, String?)] = []

        viewModel.startRun(
            connection: DatabaseConnectionConfig(), postgres: PostgresService(),
            isConnected: false
        ) { result, error in
            completions.append((result, error))
        }
        await waitUntil { !viewModel.isRunning }

        #expect(completions.count == 1)
        #expect(completions.first?.0 == nil)
        #expect(completions.first?.1 == AppError.notConnected.errorDescription)
    }

    @Test func onFinishReceivesValidationErrorWhenRunIsBlocked() async {
        let viewModel = QueryResultViewModel(executor: ImmediateExecutor())
        viewModel.sqlText = "SELECT AVG(COUNT(*) OVER ()) FROM users"
        var completions: [(QueryResult?, String?)] = []

        viewModel.startRun(
            connection: DatabaseConnectionConfig(), postgres: PostgresService(),
            isConnected: true
        ) { result, error in
            completions.append((result, error))
        }
        await waitUntil { !viewModel.isRunning }

        #expect(completions.count == 1)
        #expect(completions.first?.0 == nil)
        #expect(completions.first?.1?.contains("Aggregate functions cannot contain") == true)
    }

    @Test func onFinishFiresOnCancel() async {
        let viewModel = QueryResultViewModel(executor: SlowExecutor())
        viewModel.sqlText = "SELECT 1"
        var completions: [(QueryResult?, String?)] = []

        viewModel.startRun(
            connection: DatabaseConnectionConfig(), postgres: PostgresService(),
            isConnected: true
        ) { result, error in
            completions.append((result, error))
        }
        viewModel.cancelRun()

        #expect(completions.count == 1)
        #expect(completions.first?.0 == nil)
        #expect(completions.first?.1?.contains("Stopped waiting") == true)
    }

    @Test func setDirectSQLClearsGenerationAndValidates() {
        let viewModel = QueryResultViewModel(executor: ImmediateExecutor())
        viewModel.restore(
            sqlText: "SELECT 2",
            generation: SQLGenerationResult(
                sql: "SELECT 2",
                explanation: "Constant.",
                assumptions: [],
                referencedTables: [],
                confidence: 1.0,
                riskLevel: .low,
                needsClarification: false,
                clarificationQuestion: nil
            ))

        viewModel.setDirectSQL("SELECT 1")

        #expect(viewModel.sqlText == "SELECT 1")
        #expect(viewModel.generation == nil)
        #expect(viewModel.result == nil)
        #expect(viewModel.validation?.isValid == true)
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}

@Suite("SchemaIntrospectionService")
struct SchemaIntrospectionServiceTests {
    @Test func foreignKeySQLUsesReferencedConstraintJoin() {
        let sql = SchemaIntrospectionService.foreignKeysSQL
        #expect(sql.contains("information_schema.referential_constraints"))
        #expect(sql.contains("rc.unique_constraint_schema"))
        #expect(sql.contains("ccu.ordinal_position = kcu.position_in_unique_constraint"))
        #expect(!sql.contains("ccu.table_schema = tc.table_schema"))
    }

    @Test func introspectionSQLExcludesAllPostgresSystemSchemas() {
        let snippets = [
            SchemaIntrospectionService.tablesSQL,
            SchemaIntrospectionService.columnsSQL,
            SchemaIntrospectionService.foreignKeysSQL,
        ]

        for sql in snippets {
            #expect(sql.contains(#"NOT LIKE 'pg\_%' ESCAPE '\'"#))
            #expect(sql.contains("<> 'information_schema'"))
        }
    }
}
