import Foundation
import Testing

@testable import WidenKit

@Suite("WidenKit smoke")
@MainActor
struct WidenKitSmokeTests {
    @Test func appStateInitialStatus() async throws {
        let state = AppState()
        #expect(state.connectionStatus == .notConnected)
    }

    @Test func refreshSchemaClearsStaleSchemaWhenIntrospectionFails() async {
        let state = AppState()
        state.connectionStatus = .connected
        state.schema = makeSchema()
        state.schemaVM.selectedTableID = "public.users"

        await state.refreshSchema()

        #expect(state.schema == nil)
        #expect(state.schemaVM.selectedTableID == nil)
        #expect(state.errorBanner != nil)
        #expect(state.isLoadingSchema == false)
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
        let state = connectedAppState()
        let viewModel = QueryResultViewModel(executor: ImmediateExecutor())
        viewModel.sqlText = "SELECT 1"

        viewModel.startRun(appState: state)
        await waitUntil { viewModel.result != nil && !viewModel.isRunning }
        #expect(viewModel.result != nil)

        viewModel.sqlText = "DELETE FROM users"
        viewModel.startRun(appState: state)
        await waitUntil { !viewModel.isRunning }

        #expect(viewModel.result == nil)
        #expect(viewModel.validation?.isValid == false)
    }

    @Test func cancelRunReleasesRunningStateImmediately() async {
        let state = connectedAppState()
        let viewModel = QueryResultViewModel(executor: SlowExecutor())
        viewModel.sqlText = "SELECT 1"

        viewModel.startRun(appState: state)
        #expect(viewModel.isRunning)

        viewModel.cancelRun()

        #expect(viewModel.isRunning == false)
        #expect(viewModel.runError?.contains("Stopped waiting") == true)
        await Task.yield()
        #expect(viewModel.result == nil)
    }

    private func connectedAppState() -> AppState {
        let state = AppState()
        state.connectionStatus = .connected
        state.config = DatabaseConnectionConfig()
        return state
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
