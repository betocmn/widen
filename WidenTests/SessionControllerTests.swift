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

    private struct SlowWriteExecutor: QueryExecuting {
        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            throw AppError.executionFailed("read path used unexpectedly")
        }

        func runWrite(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService,
            confirmedDangerous: Bool
        ) async throws -> QueryResult {
            try await Task.sleep(for: .milliseconds(100))
            return QueryResult(
                columns: [],
                rows: [],
                rowCount: 1,
                truncated: false,
                executionTimeMs: 1,
                kind: .update
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

    private struct TimeoutColumnExecutor: QueryExecuting {
        let recorder: SQLRecorder

        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            await recorder.record(sql)
            if sql.contains("timeout") {
                throw AppError.executionFailed(#"column "timeout" does not exist"#)
            }
            return QueryResult(
                columns: ["id"],
                rows: [["1"]],
                rowCount: 1,
                truncated: false,
                executionTimeMs: 4
            )
        }
    }

    private struct CancelledAtColumnExecutor: QueryExecuting {
        let recorder: SQLRecorder

        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            await recorder.record(sql)
            if sql.contains("cancelled_at") {
                throw AppError.executionFailed(#"column "cancelled_at" does not exist"#)
            }
            return QueryResult(
                columns: ["id"],
                rows: [["1"]],
                rowCount: 1,
                truncated: false,
                executionTimeMs: 4
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

    private struct AlwaysFailingWithMessageExecutor: QueryExecuting {
        let recorder: SQLRecorder
        let message: String

        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            await recorder.record(sql)
            throw AppError.executionFailed(message)
        }
    }

    /// Records whether the read or write path was used, and always fails — so
    /// tests can assert which executor method ran without a real database.
    private struct FailingWriteExecutor: QueryExecuting {
        let recorder: SQLRecorder

        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            await recorder.record("READ:\(sql)")
            throw AppError.executionFailed("read path used unexpectedly")
        }

        func runWrite(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService,
            confirmedDangerous: Bool
        ) async throws -> QueryResult {
            await recorder.record("WRITE:\(sql)")
            throw AppError.executionFailed(
                #"null value in column "x" violates not-null constraint"#)
        }
    }

    private struct BadTableThenSlowExecutor: QueryExecuting {
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
            try await Task.sleep(for: .seconds(30))
            return QueryResult(
                columns: ["id"],
                rows: [["1"]],
                rowCount: 1,
                truncated: false,
                executionTimeMs: 6
            )
        }
    }

    private final class RecordingRepairGenerator: SQLGenerator, @unchecked Sendable {
        private let results: [SQLGenerationResult]
        private(set) var contexts: [SQLGenerationContext] = []
        private(set) var schemaNames: [String?] = []

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
            schemaNames.append(schema.singleSchemaName)
            return results[min(contexts.count - 1, results.count - 1)]
        }
    }

    private final class FailingRepairGenerator: SQLGenerator, @unchecked Sendable {
        private(set) var contexts: [SQLGenerationContext] = []

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            contexts.append(context)
            throw AppError.modelGenerationFailed(
                "OpenRouter is rate-limiting requests. Try again in a moment.")
        }
    }

    private final class FirstResultThenFailingGenerator: SQLGenerator, @unchecked Sendable {
        private let firstResult: SQLGenerationResult
        private(set) var contexts: [SQLGenerationContext] = []

        init(firstResult: SQLGenerationResult) {
            self.firstResult = firstResult
        }

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            contexts.append(context)
            guard contexts.count == 1 else {
                throw AppError.modelGenerationFailed(
                    "OpenRouter is rate-limiting requests. Try again in a moment.")
            }
            return firstResult
        }
    }

    private final class SuspendedRepairGenerator: SQLGenerator, @unchecked Sendable {
        private var continuation: CheckedContinuation<SQLGenerationResult, any Error>?
        private(set) var contexts: [SQLGenerationContext] = []

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            contexts.append(context)
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume(returning result: SQLGenerationResult) {
            continuation?.resume(returning: result)
            continuation = nil
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

    private func makeSchema(schemas: [String]) -> DatabaseSchema {
        DatabaseSchema(
            schemas: schemas.map(SchemaInfo.init(name:)),
            tables: schemas.map { schema in
                TableInfo(
                    schema: schema, name: "users", type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: schema,
                            tableName: "users",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                )
            },
            foreignKeys: []
        )
    }

    private func makeMixedCaseSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "events", type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "events",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "events",
                            name: "createdAt",
                            dataType: "timestamp with time zone",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                )
            ]
        )
    }

    private func makeJoinableToolSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "preseason_match_evaluation", type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_evaluation",
                            name: "id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_evaluation",
                            name: "batch_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                ),
                TableInfo(
                    schema: "public", name: "preseason_match_batch", type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "tool_a_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                ),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "match_evaluation_batch_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_evaluation",
                    sourceColumn: "batch_id",
                    targetSchema: "public",
                    targetTable: "preseason_match_batch",
                    targetColumn: "id"
                )
            ]
        )
    }

    private func makeGeneration(
        sql: String,
        explanation: String = "Generated SQL.",
        needsClarification: Bool = false,
        clarificationQuestion: String? = nil
    ) -> SQLGenerationResult {
        SQLGenerationResult(
            sql: sql,
            explanation: explanation,
            assumptions: [],
            referencedTables: ["public.users"],
            confidence: 0.8,
            riskLevel: .low,
            needsClarification: needsClarification,
            clarificationQuestion: clarificationQuestion
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

    @Test func generatedRunErrorRestoresOriginalSQLWhenRepairGeneratorFails() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(
            sql: "SELECT id FROM public.bad_table",
            explanation: "Uses the wrong table."
        )
        let generator = FailingRepairGenerator()
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
                && controller.chatVM.messages.last?.role == .error
        }

        let statements = await recorder.all()
        #expect(statements == [badGeneration.sql])
        #expect(generator.contexts.count == 1)
        #expect(generator.contexts[0].currentSQL == badGeneration.sql)
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.queryVM.generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant, .error])
        #expect(controller.chatVM.messages[1].generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.last?.text.contains("rate-limiting") == true)
    }

    @Test func generatedRunErrorDoesNotRepairNonRepairableFailures() async {
        let nonRepairableErrors = [
            "The query timed out (statement timeout exceeded).",
            "Authentication failed. password authentication failed",
            "Could not connect to the database. connection refused",
            "Query failed: permission denied for table users",
        ]

        for error in nonRepairableErrors {
            let connectionID = UUID()
            let (state, dir) = makeState(connectionID: connectionID, connected: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            state.schemas[connectionID] = makeSchema()
            let badGeneration = makeGeneration(sql: "SELECT id FROM public.users")
            let generator = RecordingRepairGenerator(
                results: [makeGeneration(sql: "SELECT id FROM public.users LIMIT 100")])
            state.sqlGeneratorOverride = generator
            let recorder = SQLRecorder()
            let controller = makeController(
                connectionID: connectionID,
                executor: AlwaysFailingWithMessageExecutor(recorder: recorder, message: error)
            )
            controller.chatVM.messages = [
                ChatMessage(role: .user, text: "show users"),
                ChatMessage(
                    role: .assistant,
                    text: badGeneration.explanation,
                    generation: badGeneration),
            ]
            controller.queryVM.setGeneration(badGeneration)

            controller.runQuery(appState: state)
            await waitUntil {
                !controller.queryVM.isRunning
                    && !controller.chatVM.isGenerating
                    && controller.chatVM.messages.last?.role == .error
            }

            let statements = await recorder.all()
            #expect(statements == [badGeneration.sql])
            #expect(generator.contexts.isEmpty)
            #expect(controller.queryVM.sqlText == badGeneration.sql)
            #expect(controller.chatVM.messages.last?.text.contains(error) == true)
        }
    }

    @Test func generatedRunErrorRepairsMissingColumnNamedTimeout() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(sql: "SELECT timeout FROM public.users")
        let fixedGeneration = makeGeneration(sql: "SELECT id FROM public.users LIMIT 100")
        let generator = RecordingRepairGenerator(results: [fixedGeneration])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: TimeoutColumnExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show user timeout"),
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
        #expect(generator.contexts[0].mode == .repair)
        #expect(generator.contexts[0].repairContext?.diagnostic?.kind == .missingColumn)
        #expect(generator.contexts[0].repairContext?.forbiddenIdentifiers.contains("timeout") == true)
        #expect(controller.queryVM.sqlText == fixedGeneration.sql)
    }

    @Test func generatedRunErrorRepairsMissingColumnNamedCancelledAt() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(sql: "SELECT cancelled_at FROM public.users")
        let fixedGeneration = makeGeneration(sql: "SELECT id FROM public.users LIMIT 100")
        let generator = RecordingRepairGenerator(results: [fixedGeneration])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: CancelledAtColumnExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show cancelled users"),
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
        #expect(generator.contexts[0].mode == .repair)
        #expect(generator.contexts[0].repairContext?.diagnostic?.kind == .missingColumn)
        #expect(generator.contexts[0].repairContext?.forbiddenIdentifiers.contains("cancelled_at") == true)
        #expect(controller.queryVM.sqlText == fixedGeneration.sql)
    }

    @Test func generatedRunErrorKeepsOriginalSQLWhileRepairGeneratorIsPending() async {
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
        let generator = SuspendedRepairGenerator()
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
            generator.contexts.count == 1
                && controller.chatVM.isGenerating
                && !controller.queryVM.isRunning
        }

        var snapshot = QuerySession(connectionID: connectionID)
        _ = controller.snapshot(into: &snapshot)

        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.queryVM.generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant])
        #expect(controller.chatVM.messages[1].generation?.sql == badGeneration.sql)
        #expect(snapshot.sqlText == badGeneration.sql)
        #expect(snapshot.lastGeneration?.sql == badGeneration.sql)
        #expect(snapshot.messages.map(\.role) == [.user, .assistant])

        generator.resume(returning: fixedGeneration)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.last?.role == .result
        }
    }

    @Test func generatedRepairExecutionCanBeCancelled() async {
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
            executor: BadTableThenSlowExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show users"),
            ChatMessage(role: .assistant, text: badGeneration.explanation, generation: badGeneration),
        ]
        controller.queryVM.setGeneration(badGeneration)

        controller.runQuery(appState: state)
        await waitUntil {
            controller.queryVM.isRunning
                && controller.chatVM.isGenerating
                && generator.contexts.count == 1
        }

        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.queryVM.generation?.sql == badGeneration.sql)

        controller.queryVM.cancelRun()
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.last?.role == .error
        }

        let statements = await recorder.all()
        #expect(statements == [badGeneration.sql, fixedGeneration.sql])
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.queryVM.generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant, .error])
        #expect(controller.chatVM.messages.last?.text.contains("Stopped waiting") == true)
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

    @Test func generatedRunRepairUsesGenerationSchema() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema(schemas: ["analytics", "public"])
        var badGeneration = makeGeneration(
            sql: "SELECT id FROM analytics.bad_table",
            explanation: "Uses a missing table."
        )
        badGeneration.generationSchemaName = "analytics"
        let fixedGeneration = makeGeneration(
            sql: "SELECT id FROM analytics.users LIMIT 100",
            explanation: "Uses the generated schema."
        )
        let generator = RecordingRepairGenerator(results: [fixedGeneration])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: BadTableExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show analytics users"),
            ChatMessage(role: .assistant, text: badGeneration.explanation, generation: badGeneration),
        ]
        controller.queryVM.setGeneration(
            badGeneration,
            schema: state.schemaForGeneration(badGeneration, connectionID: connectionID)
        )

        controller.runQuery(appState: state)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.last?.role == .result
        }

        let statements = await recorder.all()
        #expect(statements == [fixedGeneration.sql])
        #expect(generator.schemaNames == ["analytics"])
        #expect(controller.queryVM.sqlText == fixedGeneration.sql)
        #expect(controller.queryVM.generation?.generationSchemaName == "analytics")
    }

    @Test func submitRetriesInvalidGeneratedSQLBeforeShowingPreview() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(
            sql: "SELECT AVG(COUNT(*) OVER ()) FROM public.users",
            explanation: "Uses an invalid nested aggregate."
        )
        let fixedGeneration = makeGeneration(
            sql: "SELECT id FROM public.users LIMIT 100",
            explanation: "Lists users."
        )
        let generator = RecordingRepairGenerator(results: [badGeneration, fixedGeneration])
        state.sqlGeneratorOverride = generator
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "average users"

        await controller.submit(appState: state)

        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[0].isEmpty)
        #expect(generator.contexts[1].currentSQL == badGeneration.sql)
        #expect(generator.contexts[1].lastRunError?.contains("Aggregate functions cannot contain") == true)
        #expect(controller.queryVM.sqlText == fixedGeneration.sql)
        #expect(controller.queryVM.generation?.sql == fixedGeneration.sql)
        #expect(controller.queryVM.validation?.isValid == true)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant])
        #expect(controller.chatVM.messages[1].text == fixedGeneration.explanation)
        #expect(controller.chatVM.messages[1].generation?.sql == fixedGeneration.sql)
    }

    @Test func submitKeepsInvalidGeneratedSQLHiddenWhenRepairGeneratorFails() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(
            sql: "SELECT id FROM public.bad_table",
            explanation: "Uses a missing table."
        )
        let generator = FirstResultThenFailingGenerator(firstResult: badGeneration)
        state.sqlGeneratorOverride = generator
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "show users"

        await controller.submit(appState: state)

        #expect(generator.contexts.count == 2)
        #expect(controller.queryVM.sqlText.isEmpty)
        #expect(controller.queryVM.generation == nil)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .error])
        #expect(controller.chatVM.messages.last?.text.contains("rate-limiting") == true)
    }

    @Test func submitRepairForMissingGeneratedColumnForbidsColumnIdentifier() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(
            sql: "SELECT name FROM public.users",
            explanation: "Uses a missing column."
        )
        let fixedGeneration = makeGeneration(
            sql: "SELECT id FROM public.users LIMIT 100",
            explanation: "Uses an available column."
        )
        let generator = RecordingRepairGenerator(results: [badGeneration, fixedGeneration])
        state.sqlGeneratorOverride = generator
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "show users"

        await controller.submit(appState: state)

        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[1].mode == .repair)
        #expect(generator.contexts[1].repairContext?.diagnostic?.kind == .missingColumn)
        #expect(generator.contexts[1].repairContext?.forbiddenIdentifiers.contains("name") == true)
        #expect(controller.queryVM.sqlText == fixedGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant])
    }

    @Test func submitRepairForJoinableMissingColumnDoesNotForbidColumnIdentifier() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeJoinableToolSchema()
        let badGeneration = makeGeneration(
            sql: "SELECT tool_a_id FROM public.preseason_match_evaluation LIMIT 100",
            explanation: "Uses a column from the joined batch table."
        )
        let fixedGeneration = makeGeneration(
            sql: """
                SELECT b.tool_a_id
                FROM public.preseason_match_evaluation AS e
                JOIN public.preseason_match_batch AS b ON e.batch_id = b.id
                LIMIT 100
                """,
            explanation: "Joins to the batch table before selecting the tool."
        )
        let generator = RecordingRepairGenerator(results: [badGeneration, fixedGeneration])
        state.sqlGeneratorOverride = generator
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "show tools from evaluations"

        await controller.submit(appState: state)

        let repairContext = generator.contexts[1].repairContext
        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[1].mode == .repair)
        #expect(repairContext?.forbiddenIdentifiers.contains("tool_a_id") == false)
        #expect(
            repairContext?.repairConstraints.contains(.forbiddenIdentifier("tool_a_id")) == false)
        #expect(controller.queryVM.sqlText == fixedGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant])
    }

    @Test func submitAutoQuotesGeneratedMixedCaseColumnsBeforeRepairLoop() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeMixedCaseSchema()
        let generation = makeGeneration(
            sql: "SELECT createdAt FROM public.events LIMIT 100",
            explanation: "Shows event creation times."
        )
        let generator = RecordingRepairGenerator(results: [generation])
        state.sqlGeneratorOverride = generator
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "show event creation times"

        await controller.submit(appState: state)

        #expect(generator.contexts.count == 1)
        #expect(controller.queryVM.sqlText == #"SELECT "createdAt" FROM public.events LIMIT 100"#)
        #expect(controller.queryVM.generation?.sql == #"SELECT "createdAt" FROM public.events LIMIT 100"#)
        #expect(controller.queryVM.validation?.isValid == true)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant])
    }

    @Test func repairCoordinatorRejectsOnlyUnquotedMixedCaseIdentifier() {
        var coordinator = GeneratedSQLRepairCoordinator(
            failedSQL: "SELECT createdAt FROM public.events",
            firstError:
                #"Schema validation failed: column createdAt must be quoted as "createdAt" on public.events."#,
            diagnostic: DatabaseDiagnostic(
                kind: .missingColumn,
                sqlState: "42703",
                message: "createdAt must be quoted",
                columnName: "createdAt"
            ),
            forbiddenIdentifiers: [],
            repairConstraints: [.forbiddenUnquotedIdentifier("createdAt")]
        )

        let unquoted = coordinator.evaluateCandidate(
            makeGeneration(sql: "SELECT createdAt FROM public.events LIMIT 100"),
            mode: .repair,
            schema: makeMixedCaseSchema(),
            allowWrites: false
        )
        let quoted = coordinator.evaluateCandidate(
            makeGeneration(sql: #"SELECT "createdAt" FROM public.events LIMIT 100"#),
            mode: .repair,
            schema: makeMixedCaseSchema(),
            allowWrites: false
        )

        if case .rejected(let reason) = unquoted.outcome {
            #expect(reason == .forbiddenIdentifier("createdAt"))
        } else {
            Issue.record("Expected unquoted createdAt to be rejected")
        }
        #expect(quoted.outcome == .accepted)
    }

    @Test func repairCoordinatorAllowsQualifiedRepairForAmbiguousBareColumn() {
        var coordinator = GeneratedSQLRepairCoordinator(
            failedSQL: """
                SELECT id
                FROM public.users AS u
                JOIN public.users AS other_users ON u.id = other_users.id
                """,
            firstError: "Schema validation failed: column id is ambiguous across referenced tables.",
            diagnostic: DatabaseDiagnostic(
                kind: .ambiguousColumn,
                message: "column id is ambiguous",
                columnName: "id"
            ),
            forbiddenIdentifiers: ["id"]
        )

        let unqualified = coordinator.evaluateCandidate(
            makeGeneration(sql: "SELECT id FROM public.users AS u LIMIT 100"),
            mode: .repair,
            schema: makeSchema(),
            allowWrites: false
        )
        let qualified = coordinator.evaluateCandidate(
            makeGeneration(sql: "SELECT u.id FROM public.users AS u LIMIT 100"),
            mode: .repair,
            schema: makeSchema(),
            allowWrites: false
        )

        if case .rejected(let reason) = unqualified.outcome {
            #expect(reason == .forbiddenIdentifier("id"))
        } else {
            Issue.record("Expected unqualified id to remain forbidden")
        }
        #expect(qualified.outcome == .accepted)
    }

    @Test func sqlFingerprintPreservesStringLiteralCase() {
        let failed = SQLFingerprint("SELECT id FROM public.orders WHERE status = 'Paid'")
        let repaired = SQLFingerprint("select id from public.orders where status = 'paid'")
        let recasedSyntax = SQLFingerprint("select ID from PUBLIC.orders where status = 'Paid'")

        #expect(failed != repaired)
        #expect(failed == recasedSyntax)
    }

    @Test func generatedRunErrorGivesUpAfterRepairAndReconstruction() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(sql: "SELECT id FROM public.bad_table")
        let generator = RecordingRepairGenerator(results: [badGeneration, badGeneration])
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
        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[0].mode == .repair)
        #expect(generator.contexts[0].currentSQL == badGeneration.sql)
        #expect(generator.contexts[0].repairContext?.failedSQL == badGeneration.sql)
        #expect(generator.contexts[1].mode == .reconstructAfterFailedRepair)
        #expect(generator.contexts[1].currentSQL == nil)
        #expect(generator.contexts[1].repairContext?.failedSQL == nil)
        #expect(generator.contexts[1].repairContext?.forbiddenIdentifiers.contains("public.bad_table") == true)
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.queryVM.generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant, .error])
        #expect(controller.chatVM.messages[1].generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.last?.text.contains("focused repair") == true)
        #expect(controller.chatVM.messages.last?.text.contains("Initial generation") == true)
        #expect(controller.chatVM.messages.last?.text.contains("Reconstruction") == true)
        #expect(controller.chatVM.messages.last?.text.contains("Last error:") == true)
        #expect(controller.chatVM.messages.last?.text.contains("repeated SQL") == true)
        #expect(controller.chatVM.messages.last?.text.contains("smarter cloud model") == true)
    }

    @Test func generatedRunErrorDoesNotReexecuteAnyPriorFailedSQL() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let firstBadGeneration = makeGeneration(sql: "SELECT id FROM public.bad_table")
        let secondBadGeneration = makeGeneration(sql: "SELECT id FROM public.other_table")
        let generator = RecordingRepairGenerator(
            results: [
                secondBadGeneration,
                firstBadGeneration,
                secondBadGeneration,
                firstBadGeneration,
                firstBadGeneration,
            ]
        )
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: AlwaysFailingExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show users"),
            ChatMessage(
                role: .assistant,
                text: firstBadGeneration.explanation,
                generation: firstBadGeneration),
        ]
        controller.queryVM.setGeneration(firstBadGeneration)

        controller.runQuery(appState: state)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.last?.role == .error
        }

        let statements = await recorder.all()
        #expect(statements == [firstBadGeneration.sql])
        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[0].mode == .repair)
        #expect(generator.contexts[1].mode == .reconstructAfterFailedRepair)
        #expect(controller.chatVM.messages.last?.text.contains("Reconstruction") == true)
    }

    @Test func generatedRunErrorRejectsForbiddenRepairSQLBeforeExecution() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(sql: "SELECT id FROM public.bad_table")
        let forbiddenRepair = makeGeneration(sql: "SELECT id FROM public.bad_table LIMIT 100")
        let generator = RecordingRepairGenerator(results: [forbiddenRepair, forbiddenRepair])
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
                && controller.chatVM.messages.last?.role == .error
        }

        let statements = await recorder.all()
        #expect(statements == [badGeneration.sql])
        #expect(generator.contexts.count == 2)
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.queryVM.generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages[1].generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.last?.text.contains("forbidden identifier") == true)
    }

    @Test func generatedRunErrorAsksForClarificationWhenRepairRepeatsMissingColumn() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let missingColumnError =
            #"Query failed: column "tool_id" does not exist Hint: Perhaps you meant to reference the column "preseason_match_batch.tool_a_id" or the column "preseason_match_batch.tool_b_id"."#
        let badGeneration = makeGeneration(
            sql: "SELECT DISTINCT tool_id FROM public.preseason_match_batch")
        let generator = RecordingRepairGenerator(
            results: Array(repeating: badGeneration, count: 5)
        )
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: AlwaysFailingWithMessageExecutor(
                recorder: recorder,
                message: missingColumnError
            )
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "top tools"),
            ChatMessage(role: .assistant, text: badGeneration.explanation, generation: badGeneration),
        ]
        controller.queryVM.setGeneration(badGeneration)

        controller.runQuery(appState: state)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.count == 3
        }

        let statements = await recorder.all()
        #expect(statements == [badGeneration.sql])
        #expect(generator.contexts.count == 1)
        #expect(generator.contexts[0].lastRunError?.contains(missingColumnError) == true)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(controller.chatVM.messages.last?.text.contains("\"tool_id\"") == true)
        #expect(
            controller.chatVM.messages.last?.text.contains(
                "\"preseason_match_batch.tool_a_id\"") == true)
        #expect(
            controller.chatVM.messages.last?.text.contains(
                "\"preseason_match_batch.tool_b_id\"") == true)
        #expect(!(controller.chatVM.messages.last?.text.contains("Previous error") ?? true))
    }

    @Test func generatedRunRepairClarificationStopsRetryLoop() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(sql: "SELECT id FROM public.bad_table")
        let clarification = makeGeneration(
            sql: "",
            explanation: "",
            needsClarification: true,
            clarificationQuestion: "Which table should I use for users?"
        )
        let generator = RecordingRepairGenerator(results: [clarification])
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
                && controller.chatVM.messages.count == 3
        }

        let statements = await recorder.all()
        #expect(statements == [badGeneration.sql])
        #expect(generator.contexts.count == 1)
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(controller.chatVM.messages.last?.text == "Which table should I use for users?")
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

    @Test func submitWithDirectWriteSQLSkipsGenerator() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "UPDATE public.users SET name = 'A' WHERE id = 1"

        await controller.submit(appState: state)

        #expect(controller.chatVM.messages.count == 1)
        #expect(controller.chatVM.messages[0].role == .user)
        #expect(controller.queryVM.sqlText == "UPDATE public.users SET name = 'A' WHERE id = 1")
        #expect(controller.queryVM.validation?.kind == .update)
        #expect(controller.queryVM.generation == nil)
    }

    @Test func submitWithNaturalLanguageWriteUsesGenerator() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let generated = makeGeneration(sql: "UPDATE public.users SET id = 2 WHERE id = 1")
        let generator = RecordingRepairGenerator(results: [generated])
        state.sqlGeneratorOverride = generator
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "Update Alice's email to alice@example.com"

        await controller.submit(appState: state)

        var expectedGeneration = generated
        expectedGeneration.generationSchemaName = "public"
        #expect(generator.contexts.count == 1)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant])
        #expect(controller.queryVM.sqlText == generated.sql)
        #expect(controller.queryVM.generation == expectedGeneration)
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

    @Test func writeRunErrorDoesNotAutoRetryAndOffersTryAgain() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        // The generator would only be consulted by an auto-retry, which writes
        // must never trigger.
        let generator = RecordingRepairGenerator(
            results: [makeGeneration(sql: "UPDATE public.users SET id = 3 WHERE id = 1")])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: FailingWriteExecutor(recorder: recorder)
        )
        let writeGeneration = makeGeneration(sql: "UPDATE public.users SET id = 2 WHERE id = 1")
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "bump ids"),
            ChatMessage(role: .assistant, text: writeGeneration.explanation, generation: writeGeneration),
        ]
        controller.queryVM.setGeneration(writeGeneration)

        controller.runQuery(appState: state)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.last?.role == .error
        }

        let statements = await recorder.all()
        #expect(statements == ["WRITE:UPDATE public.users SET id = 2 WHERE id = 1"])
        #expect(generator.contexts.isEmpty)
        #expect(controller.chatVM.messages.last?.failedWriteSQL == writeGeneration.sql)
    }

    @Test func generatedWriteIgnoresStopWaitingUntilServerFinishes() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(
            connectionID: connectionID,
            executor: SlowWriteExecutor()
        )
        let writeGeneration = makeGeneration(sql: "UPDATE public.users SET id = 2 WHERE id = 1")
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "bump ids"),
            ChatMessage(role: .assistant, text: writeGeneration.explanation, generation: writeGeneration),
        ]
        controller.queryVM.setGeneration(writeGeneration)

        controller.runQuery(appState: state)
        await waitUntil { controller.queryVM.isRunning && !controller.queryVM.canStopWaiting }
        controller.queryVM.cancelRun()
        #expect(controller.queryVM.isRunning)
        #expect(controller.chatVM.messages.last?.role == .assistant)

        await waitUntil {
            !controller.queryVM.isRunning
                && controller.chatVM.messages.last?.role == .result
        }

        #expect(controller.chatVM.messages.last?.failedWriteSQL == nil)
    }

    @Test func retryFailedWriteRegeneratesWithoutExecuting() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let fixed = makeGeneration(
            sql: "UPDATE public.users SET id = 2 WHERE id = 1", explanation: "Fixed it.")
        let generator = RecordingRepairGenerator(results: [fixed])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: FailingWriteExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [ChatMessage(role: .user, text: "bump ids")]

        await controller.retryFailedWrite(
            appState: state, failedSQL: "UPDATE public.users SET id = 9", error: "boom")

        let statements = await recorder.all()
        #expect(statements.isEmpty)
        #expect(generator.contexts.count == 1)
        #expect(generator.contexts[0].currentSQL == "UPDATE public.users SET id = 9")
        #expect(generator.contexts[0].lastRunError == "boom")
        #expect(controller.queryVM.sqlText == fixed.sql)
        #expect(controller.chatVM.messages.last?.role == .assistant)
    }

    @Test func retryFailedWriteUsesGenerationSchema() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema(schemas: ["analytics", "public"])
        var failed = makeGeneration(
            sql: "UPDATE analytics.users SET id = 9 WHERE id = 1",
            explanation: "Uses analytics."
        )
        failed.generationSchemaName = "analytics"
        let fixed = makeGeneration(
            sql: "UPDATE analytics.users SET id = 2 WHERE id = 1",
            explanation: "Fixed analytics."
        )
        let generator = RecordingRepairGenerator(results: [fixed])
        state.sqlGeneratorOverride = generator
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "bump analytics ids"),
            ChatMessage(role: .assistant, text: failed.explanation, generation: failed),
        ]
        controller.queryVM.setGeneration(
            failed,
            schema: state.schemaForGeneration(failed, connectionID: connectionID)
        )

        await controller.retryFailedWrite(appState: state, failedSQL: failed.sql, error: "boom")

        #expect(generator.schemaNames == ["analytics"])
        #expect(controller.queryVM.sqlText == fixed.sql)
        #expect(controller.queryVM.generation?.generationSchemaName == "analytics")
    }

    @Test func autoRetryRefusesAGeneratedWrite() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badRead = makeGeneration(sql: "SELECT id FROM public.bad_table")
        let writeAttempt = makeGeneration(sql: "DELETE FROM public.users WHERE id = 1")
        let generator = RecordingRepairGenerator(results: [writeAttempt])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: BadTableExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show users"),
            ChatMessage(role: .assistant, text: badRead.explanation, generation: badRead),
        ]
        controller.queryVM.setGeneration(badRead)

        controller.runQuery(appState: state)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.last?.role == .error
        }

        // Only the initial failing read reached the executor. The generated
        // DELETE was refused by the auto-retry guard, never executed, and
        // never became the active runnable SQL.
        let statements = await recorder.all()
        #expect(statements == [badRead.sql])
        #expect(!statements.contains { $0.contains("DELETE") })
        #expect(generator.contexts.count == 1)
        #expect(controller.queryVM.sqlText == badRead.sql)
        #expect(controller.queryVM.generation?.sql == badRead.sql)
        #expect(controller.chatVM.messages.last?.text.contains("data-modifying query") == true)
    }

    @Test func runSummaryDecodesLegacyJSONWithoutKindAsRead() throws {
        let legacy = #"{"rowCount":3,"executionTimeMs":12,"truncated":false,"sql":"SELECT 1"}"#
        let summary = try JSONDecoder().decode(
            ChatMessage.RunSummary.self, from: Data(legacy.utf8))
        #expect(summary.kind == .read)
        #expect(summary.rowCount == 3)
    }

    @Test func runSummaryRoundTripsWriteKind() throws {
        let summary = ChatMessage.RunSummary(
            rowCount: 5, executionTimeMs: 9, truncated: false, sql: "DELETE FROM t", kind: .delete)
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ChatMessage.RunSummary.self, from: data)
        #expect(decoded == summary)
        #expect(decoded.kind == .delete)
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }
}
