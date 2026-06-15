import Foundation
import Testing

@testable import WidenKit

@Suite("SessionController")
@MainActor
struct SessionControllerTests {
    private struct ImmediateExecutor: QueryExecuting {
        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            QueryResult(
                columns: ["value"],
                rows: [["1"], ["2"]],
                rowCount: 2,
                truncated: false,
                executionTimeMs: 5
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

    private actor SQLRecorder {
        private var statements: [String] = []

        func record(_ sql: String) {
            statements.append(sql)
        }

        func all() -> [String] {
            statements
        }
    }

    private struct BadTableExecutor: QueryExecuting {
        let recorder: SQLRecorder

        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            await recorder.record(sql)
            if sql.contains("bad_table") {
                throw AppError.executionFailed(#"relation "public.bad_table" does not exist"#)
            }
            return QueryResult(
                columns: ["id"],
                rows: [["1"]],
                rowCount: 1,
                truncated: false,
                executionTimeMs: 6
            )
        }
    }

    private struct AlwaysFailingExecutor: QueryExecuting {
        let recorder: SQLRecorder

        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            await recorder.record(sql)
            throw AppError.executionFailed(#"relation "public.bad_table" does not exist"#)
        }
    }

    private final class RecordingRepairGenerator: SQLGenerator, @unchecked Sendable {
        private let results: [SQLGenerationResult]
        private(set) var contexts: [SQLGenerationContext] = []

        init(results: [SQLGenerationResult]) {
            self.results = results
        }

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            contexts.append(context)
            return results[min(contexts.count - 1, results.count - 1)]
        }
    }

    private func makeState(connectionID: UUID, connected: Bool) -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-tests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            connectionStore: ConnectionStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            schemaStore: SchemaStore(directory: dir)
        )
        state.connections = [DatabaseConnectionConfig(id: connectionID)]
        if connected {
            state.connectionStates[connectionID] = .connected
        }
        return (state, dir)
    }

    private func makeController(
        connectionID: UUID,
        executor: any QueryExecuting = ImmediateExecutor()
    ) -> SessionController {
        SessionController(
            session: QuerySession(connectionID: connectionID),
            executor: executor
        )
    }

    private func makeSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "users", type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeGeneration(
        sql: String,
        explanation: String = "Generated SQL."
    ) -> SQLGenerationResult {
        SQLGenerationResult(
            sql: sql,
            explanation: explanation,
            assumptions: [],
            referencedTables: ["public.users"],
            confidence: 0.8,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )
    }

    @Test func completedRunAppendsResultRecordWithSnapshottedSQL() async throws {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID)
        controller.queryVM.setDirectSQL("SELECT id FROM users")

        controller.runQuery(appState: state)
        await waitUntil { !controller.queryVM.isRunning }

        let record = controller.chatVM.messages.last
        #expect(record?.role == .result)
        #expect(record?.runSummary?.rowCount == 2)
        #expect(record?.runSummary?.executionTimeMs == 5)
        #expect(record?.runSummary?.sql == "SELECT id FROM users")
        // The materialized result is kept per record, so every run's card
        // stays in the transcript for the life of the session.
        let recordID = try #require(record?.id)
        #expect(controller.results[recordID]?.rowCount == 2)
    }

    @Test func failedRunAppendsErrorMessage() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID)
        controller.queryVM.setDirectSQL("SELECT 1")

        controller.runQuery(appState: state)
        await waitUntil { !controller.queryVM.isRunning }

        #expect(controller.chatVM.messages.last?.role == .error)
        #expect(
            controller.chatVM.messages.last?.text
                == AppError.notConnected.errorDescription)
    }

    @Test func generatedRunErrorRetriesWithDatabaseErrorAndShowsFixedResult() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(
            sql: "SELECT id FROM public.bad_table",
            explanation: "Uses the wrong table."
        )
        let fixedGeneration = makeGeneration(
            sql: "SELECT id FROM public.users LIMIT 100",
            explanation: "Uses the users table."
        )
        let generator = RecordingRepairGenerator(results: [fixedGeneration])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: BadTableExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show users"),
            ChatMessage(role: .assistant, text: badGeneration.explanation, generation: badGeneration),
        ]
        controller.queryVM.setGeneration(badGeneration)

        controller.runQuery(appState: state)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.last?.role == .result
        }

        let statements = await recorder.all()
        #expect(statements == [badGeneration.sql, fixedGeneration.sql])
        #expect(generator.contexts.count == 1)
        #expect(generator.contexts[0].currentSQL == badGeneration.sql)
        #expect(generator.contexts[0].lastRunError?.contains("bad_table") == true)
        #expect(generator.contexts[0].recentQuestions.isEmpty)
        #expect(controller.queryVM.sqlText == fixedGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant, .result])
        #expect(controller.chatVM.messages[1].generation?.sql == fixedGeneration.sql)
        #expect(controller.chatVM.messages[2].runSummary?.sql == fixedGeneration.sql)
    }

    @Test func generatedValidationErrorRetriesAndShowsFixedResult() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(
            sql: "SELECT AVG(COUNT(*) OVER ()) FROM public.users",
            explanation: "Uses an invalid nested aggregate."
        )
        let fixedGeneration = makeGeneration(
            sql: "WITH daily_counts AS (SELECT COUNT(*) AS row_count FROM public.users) SELECT AVG(row_count) FROM daily_counts",
            explanation: "Counts rows first, then averages the counts."
        )
        let generator = RecordingRepairGenerator(results: [fixedGeneration])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: BadTableExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "average users"),
            ChatMessage(role: .assistant, text: badGeneration.explanation, generation: badGeneration),
        ]
        controller.queryVM.setGeneration(badGeneration)

        controller.runQuery(appState: state)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.last?.role == .result
        }

        let statements = await recorder.all()
        #expect(statements == [fixedGeneration.sql])
        #expect(generator.contexts.count == 1)
        #expect(generator.contexts[0].currentSQL == badGeneration.sql)
        #expect(generator.contexts[0].lastRunError?.contains("Aggregate functions cannot contain") == true)
        #expect(controller.queryVM.sqlText == fixedGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant, .result])
    }

    @Test func generatedRunErrorGivesUpAfterFiveRepairsAndShowsFinalSQLAndErrors() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(sql: "SELECT id FROM public.bad_table")
        let generator = RecordingRepairGenerator(
            results: Array(repeating: badGeneration, count: 5)
        )
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: AlwaysFailingExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show users"),
            ChatMessage(role: .assistant, text: badGeneration.explanation, generation: badGeneration),
        ]
        controller.queryVM.setGeneration(badGeneration)

        controller.runQuery(appState: state)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.last?.role == .error
        }

        let statements = await recorder.all()
        #expect(statements.count == 1)
        #expect(generator.contexts.count == 5)
        #expect(generator.contexts.last?.lastRunError?.contains("repeated the exact same SQL") == true)
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.queryVM.generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant, .error])
        #expect(controller.chatVM.messages[1].generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.last?.text.contains("repair the generated SQL 5 times") == true)
        #expect(controller.chatVM.messages.last?.text.contains("Initial run") == true)
        #expect(controller.chatVM.messages.last?.text.contains("Retry 5/5") == true)
        #expect(controller.chatVM.messages.last?.text.contains("Last error:") == true)
        #expect(controller.chatVM.messages.last?.text.contains("repeated the exact same SQL") == true)
        #expect(controller.chatVM.messages.last?.text.contains("smarter cloud model") == true)
    }

    @Test func submitWithDirectSQLSkipsGenerator() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "select id from users"

        await controller.submit(appState: state)

        #expect(controller.chatVM.messages.count == 1)
        #expect(controller.chatVM.messages[0].role == .user)
        #expect(controller.queryVM.sqlText == "select id from users")
        #expect(controller.queryVM.generation == nil)
    }

    @Test func clearConversationCancelsActiveRunWithoutAppendingCompletion() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID, executor: SlowExecutor())
        controller.queryVM.setDirectSQL("SELECT id FROM users")

        controller.runQuery(appState: state)
        #expect(controller.queryVM.isRunning)

        controller.clearConversation()
        await Task.yield()

        #expect(controller.queryVM.isRunning == false)
        #expect(controller.chatVM.messages.isEmpty)
        #expect(controller.queryVM.sqlText.isEmpty)
        #expect(controller.queryVM.runError == nil)
        #expect(controller.results.isEmpty)
    }

    @Test func submitIsIgnoredWhileQueryIsRunning() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID, executor: SlowExecutor())
        controller.queryVM.setDirectSQL("SELECT id FROM users")
        controller.runQuery(appState: state)
        controller.chatVM.input = "SELECT email FROM users"

        await controller.submit(appState: state)

        #expect(controller.queryVM.isRunning)
        #expect(controller.queryVM.sqlText == "SELECT id FROM users")
        #expect(controller.chatVM.input == "SELECT email FROM users")
        #expect(controller.chatVM.messages.isEmpty)

        controller.queryVM.cancelRun()
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}
