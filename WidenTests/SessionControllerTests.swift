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

    private struct FavoriteColorColumnExecutor: QueryExecuting {
        let recorder: SQLRecorder

        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            await recorder.record(sql)
            if sql.contains("favorite_color") {
                throw AppError.executionFailed(#"column "favorite_color" does not exist"#)
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

    private struct MissingRelationExecutor: QueryExecuting {
        let recorder: SQLRecorder
        let relation: String

        func run(
            sql: String,
            config: DatabaseConnectionConfig,
            postgres: PostgresService
        ) async throws -> QueryResult {
            await recorder.record(sql)
            if sql.contains(relation) {
                throw AppError.databaseFailed(
                    DatabaseDiagnostic(
                        kind: .missingRelation,
                        sqlState: "42P01",
                        message: "relation \"\(relation)\" does not exist"
                    )
                )
            }
            return QueryResult(
                columns: ["id"],
                rows: [["1"]],
                rowCount: 1,
                truncated: false,
                executionTimeMs: 5
            )
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
        private(set) var questions: [String] = []

        init(results: [SQLGenerationResult]) {
            self.results = results
        }

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            questions.append(question)
            contexts.append(context)
            schemaNames.append(schema.singleSchemaName)
            return results[min(contexts.count - 1, results.count - 1)]
        }
    }

    private final class ContextCallCountRepairGenerator: SQLGenerator, @unchecked Sendable {
        private let result: SQLGenerationResult
        private(set) var contexts: [SQLGenerationContext] = []

        init(result: SQLGenerationResult) {
            self.result = result
        }

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            contexts.append(context)
            var copy = result
            copy.generationCallCount = max(1, context.modelCallCount)
            return copy
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

    private func makeOrdersAccountsSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "orders",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "orders",
                            name: "account_id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "accounts",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "accounts",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "accounts",
                            name: "plan_name",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                ),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "orders_account_id_fkey",
                    sourceSchema: "public",
                    sourceTable: "orders",
                    sourceColumn: "account_id",
                    targetSchema: "public",
                    targetTable: "accounts",
                    targetColumn: "id"
                )
            ]
        )
    }

    private func makeUsersStatusSchema() -> DatabaseSchema {
        DatabaseSchema(
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
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "status",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 2,
                            valueConstraints: [
                                ColumnValueConstraint(
                                    kind: .check,
                                    values: ["active", "inactive"],
                                    expression: "CHECK (status IN ('active', 'inactive'))"
                                )
                            ]
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeUsersUnconstrainedStatusSchema() -> DatabaseSchema {
        DatabaseSchema(
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
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "status",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
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
        clarificationQuestion: String? = nil,
        generationCallCount: Int? = nil
    ) -> SQLGenerationResult {
        SQLGenerationResult(
            sql: sql,
            explanation: explanation,
            assumptions: [],
            referencedTables: ["public.users"],
            confidence: 0.8,
            riskLevel: .low,
            needsClarification: needsClarification,
            clarificationQuestion: clarificationQuestion,
            generationCallCount: generationCallCount
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

    @Test func generatedRunErrorSkipsRepairWhenModelCallBudgetIsExhausted() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(
            sql: "SELECT id FROM public.bad_table",
            explanation: "Uses the wrong table.",
            generationCallCount: 3
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
                && controller.chatVM.messages.last?.role == .error
        }

        let statements = await recorder.all()
        #expect(statements == [badGeneration.sql])
        #expect(generator.contexts.isEmpty)
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.queryVM.generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant, .error])
        #expect(controller.chatVM.messages.last?.text.contains("model-call budget") == true)
    }

    @Test func generatedRunRepairPreservesCumulativeModelCallCount() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(
            sql: "SELECT id FROM public.bad_table",
            explanation: "Uses the wrong table.",
            generationCallCount: 2
        )
        let fixedGeneration = makeGeneration(
            sql: "SELECT id FROM public.users LIMIT 100",
            explanation: "Uses the users table."
        )
        let generator = ContextCallCountRepairGenerator(result: fixedGeneration)
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

        #expect(generator.contexts.count == 1)
        #expect(generator.contexts[0].modelCallCount == 3)
        #expect(controller.queryVM.generation?.generationCallCount == 3)
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

    @Test func generatedRunErrorClarifiesWhenRepairDropsMissingColumnNamedTimeout() async {
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
                && controller.chatVM.messages.count == 3
        }

        let statements = await recorder.all()
        #expect(statements == [badGeneration.sql])
        #expect(generator.contexts.count == 1)
        #expect(generator.contexts[0].mode == .repair)
        #expect(generator.contexts[0].repairContext?.diagnostic?.kind == .missingColumn)
        #expect(generator.contexts[0].repairContext?.forbiddenIdentifiers.contains("timeout") == true)
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.chatVM.messages.last?.pendingClarification?.concept.term == "timeout")
    }

    @Test func generatedRunErrorClarifiesWhenRepairDropsMissingColumnNamedCancelledAt() async {
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
                && controller.chatVM.messages.count == 3
        }

        let statements = await recorder.all()
        #expect(statements == [badGeneration.sql])
        #expect(generator.contexts.count == 1)
        #expect(generator.contexts[0].mode == .repair)
        #expect(generator.contexts[0].repairContext?.diagnostic?.kind == .missingColumn)
        #expect(generator.contexts[0].repairContext?.forbiddenIdentifiers.contains("cancelled_at") == true)
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.chatVM.messages.last?.pendingClarification?.concept.term == "cancelled")
    }

    @Test func generatedRunErrorClarifiesWhenRepairDropsRequestedFavoriteColor() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let initialGeneration = makeGeneration(
            sql: "SELECT favorite_color FROM public.users",
            explanation: "Uses a missing favorite color column."
        )
        let repairedGeneration = makeGeneration(
            sql: "SELECT id FROM public.users",
            explanation: "Lists users."
        )
        let generator = RecordingRepairGenerator(results: [repairedGeneration])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: FavoriteColorColumnExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show users favorite color"),
            ChatMessage(
                role: .assistant,
                text: initialGeneration.explanation,
                generation: initialGeneration
            ),
        ]
        controller.queryVM.setGeneration(initialGeneration)

        controller.runQuery(appState: state)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.count == 3
        }

        let statements = await recorder.all()
        #expect(statements == [initialGeneration.sql])
        #expect(generator.contexts.count == 1)
        #expect(generator.contexts[0].mode == .repair)
        #expect(controller.queryVM.sqlText == initialGeneration.sql)
        #expect(controller.chatVM.messages.last?.pendingClarification?.concept.term == "favorite")
        #expect(controller.chatVM.messages.last?.generation?.needsClarification == true)
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

    @Test func submitValidationRepairRejectsWriteForGeneratedRead() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badRead = makeGeneration(
            sql: "SELECT missing FROM public.users",
            explanation: "Uses a missing column."
        )
        let writeAttempt = makeGeneration(
            sql: "INSERT INTO public.users (id) VALUES (1)",
            explanation: "Attempts to write instead."
        )
        let generator = RecordingRepairGenerator(results: [badRead, writeAttempt])
        state.sqlGeneratorOverride = generator
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "show users"

        await controller.submit(appState: state)

        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[1].mode == .repair)
        #expect(controller.queryVM.sqlText.isEmpty)
        #expect(controller.queryVM.generation == nil)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .error])
        #expect(controller.chatVM.messages.last?.text.contains("data-modifying query") == true)
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

    @Test func repairCoordinatorCanonicalizesUnquotedMixedCaseIdentifier() {
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

        #expect(unquoted.outcome == .accepted)
        #expect(unquoted.sql == #"SELECT "createdAt" FROM public.events LIMIT 100"#)
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

    @Test func structuralFingerprintHandlesGroupedQueryWithTerminator() {
        let fingerprint = SQLStructuralFingerprint(
            """
            SELECT user_id, COUNT(*)
            FROM public.orders
            GROUP BY user_id
            LIMIT 100
            """
        )

        #expect(fingerprint.value.contains("group:user_id"))
    }

    @Test func repairCoordinatorRejectsStructuralRepeatWithSameValidationIssue() {
        var coordinator = GeneratedSQLRepairCoordinator(
            failedSQL: "SELECT u.name FROM public.users AS u",
            firstError:
                "The SQL failed validation: Schema validation failed: column name is not on public.users.",
            diagnostic: DatabaseDiagnostic(
                kind: .missingColumn,
                sqlState: "42703",
                message: "column name is not on public.users",
                columnName: "name"
            ),
            forbiddenIdentifiers: []
        )

        let repeated = coordinator.evaluateCandidate(
            makeGeneration(sql: "SELECT x.name FROM public.users AS x LIMIT 100"),
            mode: .repair,
            schema: makeSchema(),
            allowWrites: false
        )

        if case .rejected(let reason) = repeated.outcome {
            #expect(reason == .repeatedFingerprint)
        } else {
            Issue.record("Expected structurally repeated SQL to be rejected")
        }
        #expect(!repeated.allowsReconstruction)
    }

    @Test func repairCoordinatorAllowsReconstructionForRepeatedJoinableMissingColumn() {
        let schema = makeOrdersAccountsSchema()
        let failedSQL = "SELECT plan_name FROM public.orders"
        let initialValidation = GeneratedSQLValidator.validate(sql: failedSQL, schema: schema)
        var coordinator = GeneratedSQLRepairCoordinator(
            failedSQL: failedSQL,
            firstError: AppError.validationFailed(initialValidation.errors).localizedDescription,
            diagnostic: nil,
            forbiddenIdentifiers: []
        )

        let repeated = coordinator.evaluateCandidate(
            makeGeneration(sql: failedSQL),
            mode: .repair,
            schema: schema,
            allowWrites: false
        )

        if case .rejected(let reason) = repeated.outcome {
            #expect(reason == .repeatedFingerprint)
        } else {
            Issue.record("Expected repeated SQL to be rejected before reconstruction")
        }
        #expect(repeated.allowsReconstruction)
    }

    @Test func repairCoordinatorKeepsDerivedAndBaseColumnIssuesDistinct() {
        let schema = makeSchema()
        let failedSQL = """
            WITH c AS (
              SELECT id FROM public.users
            )
            SELECT email FROM c
            """
        let initialValidation = GeneratedSQLValidator.validate(sql: failedSQL, schema: schema)
        var coordinator = GeneratedSQLRepairCoordinator(
            failedSQL: failedSQL,
            firstError: AppError.validationFailed(initialValidation.errors).localizedDescription,
            diagnostic: nil,
            forbiddenIdentifiers: []
        )

        let baseColumnFailure = coordinator.evaluateCandidate(
            makeGeneration(sql: "SELECT email FROM public.users"),
            mode: .repair,
            schema: schema,
            allowWrites: false
        )

        if case .rejected(let reason) = baseColumnFailure.outcome {
            #expect(reason == .validationFailure)
        } else {
            Issue.record("Expected base column failure to be rejected for validation")
        }
        #expect(baseColumnFailure.allowsReconstruction)
    }

    @Test func repairCoordinatorTreatsStrictSubsetOfValidationIssuesAsProgress() {
        let schema = makeSchema()
        let failedSQL = "SELECT email, name FROM public.users"
        let initialValidation = GeneratedSQLValidator.validate(sql: failedSQL, schema: schema)
        var coordinator = GeneratedSQLRepairCoordinator(
            failedSQL: failedSQL,
            firstError: AppError.validationFailed(initialValidation.errors).localizedDescription,
            diagnostic: nil,
            forbiddenIdentifiers: []
        )

        let partialFailure = coordinator.evaluateCandidate(
            makeGeneration(sql: "SELECT email FROM public.users"),
            mode: .repair,
            schema: schema,
            allowWrites: false
        )

        if case .rejected(let reason) = partialFailure.outcome {
            #expect(reason == .validationFailure)
        } else {
            Issue.record("Expected partial repair to remain invalid")
        }
        #expect(partialFailure.allowsReconstruction)
    }

    @Test func generatedRunErrorClarifiesAfterRepeatedRepair() async {
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
                && controller.chatVM.messages.last?.role == .assistant
                && controller.chatVM.messages.count == 3
        }

        let statements = await recorder.all()
        #expect(statements.count == 1)
        #expect(generator.contexts.count == 1)
        #expect(generator.contexts[0].mode == .repair)
        #expect(generator.contexts[0].currentSQL == badGeneration.sql)
        #expect(generator.contexts[0].repairContext?.failedSQL == badGeneration.sql)
        #expect(generator.contexts[0].repairContext?.priorFingerprints.isEmpty == true)
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.queryVM.generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(controller.chatVM.messages[1].generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.last?.text.contains("public.bad_table") == true)
        #expect(controller.chatVM.messages.last?.text.contains("Which table") == true)
    }

    @Test func generatedRunErrorClarifiesWhenRepairDropsMissingRelationIntent() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        state.schemas[connectionID] = makeSchema()
        let badGeneration = makeGeneration(
            sql: """
                SELECT users.id
                FROM public.users
                JOIN public.bad_orders ON bad_orders.user_id = users.id
                """
        )
        let fixedGeneration = makeGeneration(sql: "SELECT id FROM public.users LIMIT 100")
        let generator = RecordingRepairGenerator(results: [fixedGeneration])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: MissingRelationExecutor(recorder: recorder, relation: "public.bad_orders")
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show users with orders"),
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
        let forbiddenIdentifiers = generator.contexts[0].repairContext?.forbiddenIdentifiers ?? []
        #expect(forbiddenIdentifiers.contains("public.bad_orders"))
        #expect(!forbiddenIdentifiers.contains("public.users"))
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.chatVM.messages.last?.pendingClarification?.concept.term == "orders")
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
                && controller.chatVM.messages.last?.role == .assistant
                && controller.chatVM.messages.count == 3
        }

        let statements = await recorder.all()
        #expect(statements == [firstBadGeneration.sql])
        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[0].mode == .repair)
        #expect(generator.contexts[1].mode == .reconstructAfterFailedRepair)
        #expect(controller.chatVM.messages.last?.text.contains("public.bad_table") == true)
        #expect(controller.chatVM.messages.last?.text.contains("Which table") == true)
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
                && controller.chatVM.messages.last?.role == .assistant
                && controller.chatVM.messages.count == 3
        }

        let statements = await recorder.all()
        #expect(statements == [badGeneration.sql])
        #expect(generator.contexts.count == 1)
        #expect(controller.queryVM.sqlText == badGeneration.sql)
        #expect(controller.queryVM.generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages[1].generation?.sql == badGeneration.sql)
        #expect(controller.chatVM.messages.last?.text.contains("public.bad_table") == true)
        #expect(controller.chatVM.messages.last?.text.contains("Which table") == true)
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

    @Test func validationRepairRunsGroundingBeforeShowingRepairedSQL() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = makeUsersUnconstrainedStatusSchema()
        state.schemas[connectionID] = schema
        let invalidGeneration = makeGeneration(
            sql: "SELECT timeout FROM public.users WHERE status = 'active'",
            explanation: "Uses an invalid column."
        )
        let repairedGeneration = makeGeneration(
            sql: "SELECT id FROM public.users WHERE status = 'active'",
            explanation: "Lists active users."
        )
        let generator = RecordingRepairGenerator(results: [invalidGeneration, repairedGeneration])
        state.sqlGeneratorOverride = generator
        let controller = makeController(connectionID: connectionID)
        controller.chatVM.input = "show active users"

        await controller.submit(appState: state)

        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[1].mode == .repair)
        #expect(controller.queryVM.sqlText.isEmpty)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant])
        #expect(controller.chatVM.messages.last?.pendingClarification?.concept.term == "active")
        #expect(controller.chatVM.messages.last?.generation?.needsClarification == true)
    }

    @Test func generatedRunRepairRunsGroundingBeforeExecutingRepairedSQL() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = makeUsersUnconstrainedStatusSchema()
        state.schemas[connectionID] = schema
        let initialGeneration = makeGeneration(
            sql: "SELECT timeout FROM public.users",
            explanation: "Uses a missing timeout column."
        )
        let repairedGeneration = makeGeneration(
            sql: "SELECT id FROM public.users WHERE status = 'churned'",
            explanation: "Lists churned users."
        )
        let generator = RecordingRepairGenerator(results: [repairedGeneration])
        state.sqlGeneratorOverride = generator
        let recorder = SQLRecorder()
        let controller = makeController(
            connectionID: connectionID,
            executor: TimeoutColumnExecutor(recorder: recorder)
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "show churned users"),
            ChatMessage(
                role: .assistant,
                text: initialGeneration.explanation,
                generation: initialGeneration
            ),
        ]
        controller.queryVM.setGeneration(initialGeneration)

        controller.runQuery(appState: state)
        await waitUntil {
            !controller.queryVM.isRunning
                && !controller.chatVM.isGenerating
                && controller.chatVM.messages.count == 3
        }

        let statements = await recorder.all()
        #expect(statements == [initialGeneration.sql])
        #expect(generator.contexts.count == 1)
        #expect(controller.queryVM.sqlText == initialGeneration.sql)
        #expect(controller.chatVM.messages.last?.pendingClarification?.concept.term == "churned")
        #expect(controller.chatVM.messages.last?.generation?.needsClarification == true)
    }

    @Test func clarificationOptionReplyResolvesPendingClarificationAndStoresBinding() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = makeUsersUnconstrainedStatusSchema()
        state.schemas[connectionID] = schema
        let controller = makeController(connectionID: connectionID)
        let option = ClarificationOption(
            label: "status = active",
            replyText: #"Use "public"."users"."status" = 'active'"#,
            definition: #""public"."users"."status" = 'active'"#,
            evidence: ["public.users.status"]
        )
        let pending = PendingClarification(
            concept: SQLGroundingConcept(
                term: "active",
                kind: .filter,
                state: .unsupported,
                required: true
            ),
            originalQuestion: "how many active users?",
            question: "What defines active users?",
            options: [option]
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "how many active users?"),
            ChatMessage(
                role: .assistant,
                text: pending.question,
                pendingClarification: pending
            ),
        ]
        let fixed = makeGeneration(
            sql: "SELECT COUNT(*) FROM public.users WHERE status = 'active'",
            explanation: "Counts active users."
        )
        let generator = RecordingRepairGenerator(results: [fixed])
        state.sqlGeneratorOverride = generator

        await controller.selectClarificationOption(
            appState: state,
            pending: pending,
            option: option
        )

        #expect(controller.chatVM.messages.contains {
            $0.role == .user && $0.text == option.replyText
        })
        #expect(generator.questions == ["how many active users?"])
        #expect(generator.contexts.first?.confirmedSemanticBindings.contains {
            $0.contains(#""public"."users"."status" = 'active'"#)
        } == true)
        #expect(state.semanticBindings.count == 1)
        #expect(state.semanticBindings.first?.concept == "active")
        #expect(state.semanticBindings.first?.definition == option.definition)
        #expect(controller.queryVM.sqlText == fixed.sql)
        #expect(controller.chatVM.messages.last?.generation?.needsClarification == false)
    }

    @Test func staleClarificationOptionTapIsIgnored() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = makeUsersUnconstrainedStatusSchema()
        state.schemas[connectionID] = schema
        let controller = makeController(connectionID: connectionID)
        let oldOption = ClarificationOption(
            label: "old active",
            replyText: "Use old active definition",
            definition: "old active definition"
        )
        let oldPending = PendingClarification(
            concept: SQLGroundingConcept(
                term: "active",
                kind: .filter,
                state: .unsupported,
                required: true
            ),
            originalQuestion: "how many active users?",
            question: "What defines active users?",
            options: [oldOption]
        )
        let currentPending = PendingClarification(
            concept: SQLGroundingConcept(
                term: "churned",
                kind: .filter,
                state: .unsupported,
                required: true
            ),
            originalQuestion: "how many churned users?",
            question: "What defines churned users?"
        )
        let generator = RecordingRepairGenerator(results: [makeGeneration(sql: "SELECT 1")])
        state.sqlGeneratorOverride = generator
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: oldPending.originalQuestion),
            ChatMessage(
                role: .assistant,
                text: oldPending.question,
                pendingClarification: oldPending
            ),
            ChatMessage(role: .user, text: currentPending.originalQuestion),
            ChatMessage(
                role: .assistant,
                text: currentPending.question,
                pendingClarification: currentPending
            ),
        ]

        await controller.selectClarificationOption(
            appState: state,
            pending: oldPending,
            option: oldOption
        )

        #expect(generator.contexts.isEmpty)
        #expect(state.semanticBindings.isEmpty)
        #expect(controller.chatVM.input.isEmpty)
        #expect(controller.chatVM.messages.count == 4)
    }

    @Test func freeFormClarificationReplyResolvesSamePendingClarification() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = makeUsersUnconstrainedStatusSchema()
        state.schemas[connectionID] = schema
        let controller = makeController(connectionID: connectionID)
        let pending = PendingClarification(
            concept: SQLGroundingConcept(
                term: "active",
                kind: .filter,
                state: .unsupported,
                required: true
            ),
            originalQuestion: "how many active users?",
            question: "What defines active users?"
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "how many active users?"),
            ChatMessage(
                role: .assistant,
                text: pending.question,
                pendingClarification: pending
            ),
        ]
        controller.chatVM.input = "Active means users whose status is active."
        let fixed = makeGeneration(
            sql: "SELECT COUNT(*) FROM public.users WHERE status = 'active'",
            explanation: "Counts active users."
        )
        let generator = RecordingRepairGenerator(results: [fixed])
        state.sqlGeneratorOverride = generator

        await controller.submit(appState: state)

        #expect(generator.questions == ["how many active users?"])
        #expect(
            generator.contexts.first?.conversationMessages.last?.text
                == "Active means users whose status is active."
        )
        #expect(generator.contexts.first?.confirmedSemanticBindings.contains {
            $0.contains("Active means users whose status is active.")
        } == true)
        #expect(state.semanticBindings.first?.definition == "Active means users whose status is active.")
        #expect(controller.queryVM.sqlText == fixed.sql)
        #expect(controller.chatVM.messages.last?.generation?.needsClarification == false)
    }

    @Test func newQuestionAfterPendingClarificationStartsFreshRequest() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = makeUsersUnconstrainedStatusSchema()
        state.schemas[connectionID] = schema
        let controller = makeController(connectionID: connectionID)
        let pending = PendingClarification(
            concept: SQLGroundingConcept(
                term: "active",
                kind: .filter,
                state: .unsupported,
                required: true
            ),
            originalQuestion: "how many active users?",
            question: "What defines active users?"
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: pending.originalQuestion),
            ChatMessage(
                role: .assistant,
                text: pending.question,
                pendingClarification: pending
            ),
        ]
        controller.chatVM.input = "show all users"
        let fixed = makeGeneration(
            sql: "SELECT id FROM public.users",
            explanation: "Lists users."
        )
        let generator = RecordingRepairGenerator(results: [fixed])
        state.sqlGeneratorOverride = generator

        await controller.submit(appState: state)

        #expect(generator.questions == ["show all users"])
        #expect(generator.contexts.first?.originalQuestion == "show all users")
        #expect(generator.contexts.first?.conversationMessages.contains {
            $0.text == pending.question
        } == false)
        #expect(generator.contexts.first?.conversationMessages.contains {
            $0.text == pending.originalQuestion
        } == false)
        #expect(generator.contexts.first?.recentQuestions.contains(pending.originalQuestion) == false)
        #expect(state.semanticBindings.isEmpty)
        #expect(controller.queryVM.sqlText == fixed.sql)
    }

    @Test func questionLikeReplyAfterPendingClarificationStartsFreshRequest() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = makeUsersUnconstrainedStatusSchema()
        state.schemas[connectionID] = schema
        let controller = makeController(connectionID: connectionID)
        let pending = PendingClarification(
            concept: SQLGroundingConcept(
                term: "active",
                kind: .filter,
                state: .unsupported,
                required: true
            ),
            originalQuestion: "how many active users?",
            question: "What defines active users?"
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: pending.originalQuestion),
            ChatMessage(
                role: .assistant,
                text: pending.question,
                pendingClarification: pending
            ),
        ]
        controller.chatVM.input = "what is the count of all users?"
        let fixed = makeGeneration(
            sql: "SELECT COUNT(*) FROM public.users",
            explanation: "Counts users."
        )
        let generator = RecordingRepairGenerator(results: [fixed])
        state.sqlGeneratorOverride = generator

        await controller.submit(appState: state)

        #expect(generator.questions == ["what is the count of all users?"])
        #expect(generator.contexts.first?.originalQuestion == "what is the count of all users?")
        #expect(generator.contexts.first?.conversationMessages.contains {
            $0.text == pending.question
        } == false)
        #expect(generator.contexts.first?.conversationMessages.contains {
            $0.text == pending.originalQuestion
        } == false)
        #expect(generator.contexts.first?.recentQuestions.contains(pending.originalQuestion) == false)
        #expect(state.semanticBindings.isEmpty)
        #expect(controller.queryVM.sqlText == fixed.sql)
    }

    @Test func negativeClarificationReplyDoesNotStoreSemanticBinding() async {
        let connectionID = UUID()
        let (state, dir) = makeState(connectionID: connectionID, connected: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = makeUsersStatusSchema()
        state.schemas[connectionID] = schema
        let controller = makeController(connectionID: connectionID)
        let pending = PendingClarification(
            concept: SQLGroundingConcept(
                term: "active",
                kind: .filter,
                state: .unsupported,
                required: true
            ),
            originalQuestion: "how many active users?",
            question: "What defines active users?"
        )
        controller.chatVM.messages = [
            ChatMessage(role: .user, text: "how many active users?"),
            ChatMessage(
                role: .assistant,
                text: pending.question,
                pendingClarification: pending
            ),
        ]
        controller.chatVM.input = "no"
        let clarification = makeGeneration(
            sql: "",
            explanation: "Still needs clarification.",
            needsClarification: true,
            clarificationQuestion: "What defines active users?"
        )
        let generator = RecordingRepairGenerator(results: [clarification])
        state.sqlGeneratorOverride = generator

        await controller.submit(appState: state)

        #expect(state.semanticBindings.isEmpty)
        #expect(generator.contexts.first?.confirmedSemanticBindings.isEmpty == true)
        #expect(generator.contexts.first?.conversationMessages.last?.text == "no")
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
        controller.chatVM.input = "Update user id 1 to 2"

        await controller.submit(appState: state)

        #expect(generator.contexts.count == 1)
        #expect(controller.chatVM.messages.map(\.role) == [.user, .assistant])
        #expect(controller.queryVM.sqlText == generated.sql)
        #expect(controller.queryVM.generation?.generationSchemaName == "public")
        #expect(controller.queryVM.generation?.groundingConcepts.contains {
            $0.term == "id" && $0.state == .grounded
        } == true)
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
