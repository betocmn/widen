import Foundation
import Testing

@testable import WidenKit

@Suite("TextToSQLPipeline")
struct TextToSQLPipelineTests {
    private class ScriptedGenerator: SQLGenerator, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Result<SQLGenerationResult, Error>]
        private let echoModelCallCount: Bool
        private(set) var contexts: [SQLGenerationContext] = []

        init(_ queue: [Result<SQLGenerationResult, Error>], echoModelCallCount: Bool = false) {
            self.queue = queue
            self.echoModelCallCount = echoModelCallCount
        }

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            try lock.withLock {
                contexts.append(context)
                guard !queue.isEmpty else {
                    throw SQLGenerationFailure.generation("No scripted response.")
                }
                var result = try queue.removeFirst().get()
                if echoModelCallCount {
                    result.generationCallCount = max(1, context.modelCallCount)
                }
                return result
            }
        }
    }

    private final class ConstrainedScriptedGenerator: ScriptedGenerator, ConstrainedLocalSQLGenerator,
        @unchecked Sendable
    {}

    private final class ScriptedVerifier: GeneratedSQLVerifying, @unchecked Sendable {
        struct Request: Sendable, Equatable {
            var sql: String
            var safetyMode: SQLSafetyMode
        }

        private let lock = NSLock()
        private var queue: [Result<SQLVerificationResult, Error>]
        private(set) var requests: [Request] = []

        init(_ queue: [Result<SQLVerificationResult, Error>]) {
            self.queue = queue
        }

        func verify(
            sql: String,
            connection: PostgresConnectionHandle,
            safetyMode: SQLSafetyMode
        ) async throws -> SQLVerificationResult {
            try lock.withLock {
                requests.append(Request(sql: sql, safetyMode: safetyMode))
                guard !queue.isEmpty else {
                    throw SQLGenerationFailure.generation("No scripted verification response.")
                }
                return try queue.removeFirst().get()
            }
        }
    }

    private final class DelayedRepairFailureGenerator: SQLGenerator, @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
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
            let call = lock.withLock {
                contexts.append(context)
                callCount += 1
                return callCount
            }
            guard call > 1 else { return firstResult }

            try await Task.sleep(for: .milliseconds(25))
            throw SQLGenerationFailure.transport("Timed out.")
        }
    }

    private actor EventCollector {
        private var events: [TextToSQLPipelineEvent] = []

        func record(_ event: TextToSQLPipelineEvent) {
            events.append(event)
        }

        func all() -> [TextToSQLPipelineEvent] {
            events
        }
    }

    private func makeSchema() -> DatabaseSchema {
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
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "users",
                            name: "createdAt",
                            dataType: "timestamp with time zone",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makeStatusSchema() -> DatabaseSchema {
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
                            dataType: "integer",
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

    private func makePreseasonSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "preseason_match_evaluation",
                    type: .baseTable,
                    columns: [
                        column("preseason_match_evaluation", "id", ordinal: 1),
                        column("preseason_match_evaluation", "batch_id", ordinal: 2),
                        column("preseason_match_evaluation", "winner_id", ordinal: 3),
                        column(
                            "preseason_match_evaluation",
                            "createdAt",
                            type: "timestamp with time zone",
                            ordinal: 4
                        ),
                    ]
                ),
                TableInfo(
                    schema: "public",
                    name: "preseason_tool",
                    type: .baseTable,
                    columns: [
                        column("preseason_tool", "id", ordinal: 1),
                        column(
                            "preseason_tool",
                            "name",
                            type: "character varying",
                            ordinal: 2
                        ),
                    ]
                ),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "preseason_match_evaluation_winner_id_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_evaluation",
                    sourceColumn: "winner_id",
                    targetSchema: "public",
                    targetTable: "preseason_tool",
                    targetColumn: "id"
                )
            ]
        )
    }

    private func column(
        _ tableName: String,
        _ name: String,
        type: String = "uuid",
        ordinal: Int
    ) -> ColumnInfo {
        ColumnInfo(
            tableSchema: "public",
            tableName: tableName,
            name: name,
            dataType: type,
            isNullable: false,
            ordinalPosition: ordinal
        )
    }

    private func generation(
        sql: String,
        explanation: String = "Generated SQL.",
        needsClarification: Bool = false,
        clarificationQuestion: String? = nil,
        generationCallCount: Int? = nil,
        schemaToolCalls: [SchemaToolCallTrace] = [],
        inspectionToolCalls: [DatabaseInspectionToolCallTrace] = []
    ) -> SQLGenerationResult {
        SQLGenerationResult(
            sql: needsClarification ? "" : sql,
            explanation: explanation,
            assumptions: [],
            referencedTables: [],
            confidence: needsClarification ? 0.2 : 0.9,
            riskLevel: needsClarification ? .medium : .low,
            needsClarification: needsClarification,
            clarificationQuestion: clarificationQuestion,
            generationCallCount: generationCallCount,
            schemaToolCalls: schemaToolCalls,
            inspectionToolCalls: inspectionToolCalls
        )
    }

    private func diagnostic(
        _ kind: DatabaseDiagnosticKind,
        sqlState: String,
        message: String = "PostgreSQL rejected the generated SQL."
    ) -> DatabaseDiagnostic {
        DatabaseDiagnostic(
            kind: kind,
            sqlState: sqlState,
            severity: "ERROR",
            message: message
        )
    }

    private func verificationFailure(
        _ kind: DatabaseDiagnosticKind,
        sqlState: String,
        message: String = "PostgreSQL rejected the generated SQL.",
        elapsedMs: Int = 7
    ) -> SQLVerificationResult {
        .failed(
            diagnostic: diagnostic(kind, sqlState: sqlState, message: message),
            elapsedMs: elapsedMs,
            stage: .prepare
        )
    }

    private func verificationConnection() -> PostgresConnectionHandle {
        PostgresConnectionHandle(postgres: PostgresService())
    }

    private func run(
        _ generator: ScriptedGenerator,
        verifier: (any GeneratedSQLVerifying)? = nil,
        verificationConnection: PostgresConnectionHandle? = nil
    ) async throws -> TextToSQLRun {
        try await TextToSQLPipeline(generator: generator).run(
            TextToSQLRequest(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100),
                sqlVerifier: verifier,
                verificationConnection: verificationConnection
            )
        )
    }

    private func schemaToolTrace(callID: String, toolName: String) -> SchemaToolCallTrace {
        SchemaToolCallTrace(
            callID: callID,
            toolName: toolName,
            outcome: .success,
            latencyMs: 1,
            returnedObjectCount: 1,
            outputByteCount: 128,
            truncated: false,
            schemaFingerprintPrefix: "abcdef12",
            cacheHit: true
        )
    }

    private func inspectionToolTrace(callID: String, toolName: String) -> DatabaseInspectionToolCallTrace {
        DatabaseInspectionToolCallTrace(
            callID: callID,
            toolName: toolName,
            outcome: .success,
            tableID: "tbl_users",
            columnIDs: [],
            rowCount: 0,
            valueCount: 0,
            outputByteCount: 256,
            redactionCount: 0,
            cloudShareable: true,
            latencyMs: 1,
            truncated: false,
            errorCode: nil
        )
    }

    @Test func validGenerationReturnsFinalSQL() async throws {
        let result = try await run(
            ScriptedGenerator([
                .success(generation(sql: "SELECT id FROM public.users LIMIT 100"))
            ])
        )

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected SQL decision")
            return
        }
        #expect(generation.sql == "SELECT id FROM public.users LIMIT 100")
        #expect(result.trace.stages.contains { $0.stage == .finalDecision && $0.outcome == .success })
    }

    @Test func postgresVerificationPassesAndReturnsFinalSQL() async throws {
        let sql = "SELECT id FROM public.users LIMIT 100"
        let generator = ScriptedGenerator([.success(generation(sql: sql))])
        let verifier = ScriptedVerifier([.success(.passed(elapsedMs: 4))])

        let result = try await run(
            generator,
            verifier: verifier,
            verificationConnection: verificationConnection()
        )

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected SQL decision")
            return
        }
        #expect(generation.sql == sql)
        #expect(verifier.requests == [.init(sql: sql, safetyMode: .generatedRead)])
        #expect(result.trace.stages.contains {
            $0.stage == .postgresVerification
                && $0.outcome == .success
                && $0.verificationStatus == .passed
                && $0.elapsedMs == 4
        })
    }

    @Test func postgresVerificationFailureCallsOneRepair() async throws {
        let originalSQL = "SELECT id FROM public.users LIMIT 100"
        let repairedSQL = #"SELECT "createdAt" FROM public.users LIMIT 100"#
        let generator = ScriptedGenerator([
            .success(generation(sql: originalSQL)),
            .success(generation(sql: repairedSQL)),
        ])
        let verifier = ScriptedVerifier([
            .success(
                verificationFailure(
                    .undefinedFunction,
                    sqlState: "42883",
                    message: "function date_sub(timestamp with time zone, interval) does not exist"
                )
            ),
            .success(.passed(elapsedMs: 3)),
        ])

        let result = try await run(
            generator,
            verifier: verifier,
            verificationConnection: verificationConnection()
        )

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected repaired SQL decision")
            return
        }
        #expect(generation.sql == repairedSQL)
        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[1].mode == .repair)
        #expect(verifier.requests.map(\.sql) == [originalSQL, repairedSQL])
        #expect(result.events.map(\.kind).contains(.postgresVerificationRepairStarted))
        #expect(result.events.map(\.kind).contains(.postgresVerificationRepairPassed))
        #expect(result.trace.stages.contains {
            $0.stage == .postgresVerification
                && $0.outcome == .failure
                && $0.verificationStatus == .failed
                && $0.sqlState == "42883"
                && $0.databaseDiagnosticKind == .undefinedFunction
        })
        #expect(result.trace.stages.contains {
            $0.stage == .postgresVerificationRepair
                && $0.outcome == .success
                && $0.verificationStatus == .passed
                && $0.verificationRepairAttempted == true
        })
    }

    @Test func repairedSQLThatFailsPostgresVerificationStopsWithoutSecondRepair() async throws {
        let originalSQL = "SELECT id FROM public.users LIMIT 100"
        let repairedSQL = #"SELECT "createdAt" FROM public.users LIMIT 100"#
        let generator = ScriptedGenerator([
            .success(generation(sql: originalSQL)),
            .success(generation(sql: repairedSQL)),
            .success(generation(sql: "SELECT id FROM public.users")),
        ])
        let verifier = ScriptedVerifier([
            .success(verificationFailure(.undefinedFunction, sqlState: "42883")),
            .success(verificationFailure(.missingColumn, sqlState: "42703")),
        ])

        let result = try await run(
            generator,
            verifier: verifier,
            verificationConnection: verificationConnection()
        )

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.stage == .postgresVerificationRepair)
        #expect(failure.category == .postgresVerification)
        #expect(failure.databaseDiagnostic?.sqlState == "42703")
        #expect(generator.contexts.count == 2)
        #expect(verifier.requests.map(\.sql) == [originalSQL, repairedSQL])
        #expect(!result.events.map(\.kind).contains(.validationRepairStarted))
    }

    @Test func postgresPermissionFailureDoesNotRepair() async throws {
        let sql = "SELECT id FROM public.users LIMIT 100"
        let generator = ScriptedGenerator([.success(generation(sql: sql))])
        let verifier = ScriptedVerifier([
            .success(
                verificationFailure(
                    .insufficientPrivilege,
                    sqlState: "42501",
                    message: "permission denied for table users"
                )
            )
        ])

        let result = try await run(
            generator,
            verifier: verifier,
            verificationConnection: verificationConnection()
        )

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.stage == .postgresVerification)
        #expect(failure.category == .postgresVerification)
        #expect(failure.databaseDiagnostic?.kind == .insufficientPrivilege)
        #expect(generator.contexts.count == 1)
        #expect(verifier.requests.count == 1)
        #expect(!result.events.map(\.kind).contains(.postgresVerificationRepairStarted))
    }

    @Test func postgresStatementTimeoutDoesNotRepair() async throws {
        let sql = "SELECT id FROM public.users LIMIT 100"
        let generator = ScriptedGenerator([.success(generation(sql: sql))])
        let verifier = ScriptedVerifier([
            .success(
                verificationFailure(
                    .timedOut,
                    sqlState: "57014",
                    message: "canceling statement due to statement timeout"
                )
            )
        ])

        let result = try await run(
            generator,
            verifier: verifier,
            verificationConnection: verificationConnection()
        )

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.stage == .postgresVerification)
        #expect(failure.category == .postgresVerification)
        #expect(failure.databaseDiagnostic?.kind == .timedOut)
        #expect(generator.contexts.count == 1)
        #expect(verifier.requests.count == 1)
        #expect(!result.events.map(\.kind).contains(.postgresVerificationRepairStarted))
    }

    @Test func postgresConnectionFailureDoesNotRepair() async throws {
        let sql = "SELECT id FROM public.users LIMIT 100"
        let generator = ScriptedGenerator([.success(generation(sql: sql))])
        let verifier = ScriptedVerifier([.failure(AppError.notConnected)])

        let result = try await run(
            generator,
            verifier: verifier,
            verificationConnection: verificationConnection()
        )

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.stage == .postgresVerification)
        #expect(failure.category == .postgresVerification)
        #expect(failure.databaseDiagnostic == nil)
        #expect(generator.contexts.count == 1)
        #expect(verifier.requests.count == 1)
        #expect(!result.events.map(\.kind).contains(.postgresVerificationRepairStarted))
    }

    @Test func postgresVerificationCancellationPropagates() async {
        let generator = ScriptedGenerator([
            .success(generation(sql: "SELECT id FROM public.users LIMIT 100"))
        ])
        let verifier = ScriptedVerifier([.failure(CancellationError())])

        do {
            _ = try await run(
                generator,
                verifier: verifier,
                verificationConnection: verificationConnection()
            )
            Issue.record("expected cancellation")
        } catch is CancellationError {
            #expect(true)
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test func postgresVerificationSkipsWhenUnavailableOrNoConnection() async throws {
        let noVerifierResult = try await run(
            ScriptedGenerator([
                .success(generation(sql: "SELECT id FROM public.users LIMIT 100"))
            ])
        )
        #expect(noVerifierResult.trace.stages.contains {
            $0.stage == .postgresVerification
                && $0.outcome == .skipped
                && $0.verificationStatus == .notAvailable
        })

        let verifier = ScriptedVerifier([.success(.passed(elapsedMs: 1))])
        let noConnectionResult = try await run(
            ScriptedGenerator([
                .success(generation(sql: "SELECT id FROM public.users LIMIT 100"))
            ]),
            verifier: verifier
        )
        #expect(verifier.requests.isEmpty)
        #expect(noConnectionResult.trace.stages.contains {
            $0.stage == .postgresVerification
                && $0.outcome == .skipped
                && $0.verificationStatus == .skippedNoConnection
        })
    }

    @Test func postgresVerifierRejectsBindPlaceholders() async throws {
        let verifier = PostgresSQLVerifier()
        let handle = PostgresConnectionHandle(postgres: PostgresService())

        let rejected = try await verifier.verify(
            sql: "SELECT id FROM public.users WHERE id = $1",
            connection: handle,
            safetyMode: .generatedRead
        )
        #expect(rejected.status == .failed)
        #expect(rejected.diagnostic?.kind == .syntaxError)
        #expect(rejected.message?.contains("bind parameter") == true)

        let literalResult = try await verifier.verify(
            sql: "SELECT '$1' AS literal FROM public.users LIMIT 1",
            connection: handle,
            safetyMode: .generatedRead
        )
        #expect(literalResult.status == .skippedNoConnection)
    }

    @Test func postgresVerificationRepairRejectedCandidateReportsRepairStage() async throws {
        let originalSQL = "SELECT id FROM public.users LIMIT 100"
        let generator = ScriptedGenerator([
            .success(generation(sql: originalSQL)),
            .success(generation(sql: originalSQL)),
        ])
        let verifier = ScriptedVerifier([
            .success(verificationFailure(.undefinedFunction, sqlState: "42883")),
        ])

        let result = try await run(
            generator,
            verifier: verifier,
            verificationConnection: verificationConnection()
        )

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.stage == .postgresVerificationRepair)
        #expect(failure.category == .repeatedNoProgressRepair)
        #expect(result.trace.stages.contains { $0.stage == .postgresVerificationRepair })
        #expect(!result.trace.stages.contains { $0.stage == .validationRepair })
        #expect(generator.contexts.count == 2)
        #expect(verifier.requests.count == 1)
        #expect(result.events.map(\.kind).contains(.postgresVerificationRepairRejected))
    }

    @Test func validationRepairThenPostgresVerificationRepairProducesSQL() async throws {
        let invalidSQL = "SELECT missing FROM public.users"
        let validationRepairedSQL = "SELECT id FROM public.users LIMIT 100"
        let verificationRepairedSQL = "SELECT id FROM public.users WHERE id > 0 LIMIT 100"
        let generator = ScriptedGenerator([
            .success(generation(sql: invalidSQL)),
            .success(generation(sql: validationRepairedSQL)),
            .success(generation(sql: verificationRepairedSQL)),
        ])
        let verifier = ScriptedVerifier([
            .success(verificationFailure(.undefinedFunction, sqlState: "42883")),
            .success(.passed(elapsedMs: 3)),
        ])

        let result = try await run(
            generator,
            verifier: verifier,
            verificationConnection: verificationConnection()
        )

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected repaired SQL decision")
            return
        }
        #expect(generation.sql == verificationRepairedSQL)
        #expect(generator.contexts.count == 3)
        #expect(generator.contexts[1].mode == .repair)
        #expect(generator.contexts[2].mode == .repair)
        #expect(verifier.requests.map(\.sql) == [validationRepairedSQL, verificationRepairedSQL])
        #expect(result.events.map(\.kind).contains(.postgresVerificationRepairStarted))
        #expect(result.events.map(\.kind).contains(.postgresVerificationRepairPassed))
        #expect(result.trace.stages.contains { $0.stage == .postgresVerificationRepair })
    }

    @Test func constrainedLocalStopsAfterValidationRepairWhenVerificationFails() async throws {
        let invalidSQL = "SELECT missing FROM public.users"
        let validationRepairedSQL = "SELECT id FROM public.users LIMIT 100"
        let generator = ConstrainedScriptedGenerator(
            [
                .success(generation(sql: invalidSQL)),
                .success(generation(sql: validationRepairedSQL)),
                .success(generation(sql: "SELECT id FROM public.users WHERE id > 0 LIMIT 100")),
            ],
            echoModelCallCount: true
        )
        let verifier = ScriptedVerifier([
            .success(verificationFailure(.undefinedFunction, sqlState: "42883"))
        ])

        let result = try await run(
            generator,
            verifier: verifier,
            verificationConnection: verificationConnection()
        )

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failed decision")
            return
        }
        #expect(failure.stage == .postgresVerificationRepair)
        #expect(failure.category == .postgresVerification)
        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[1].modelCallCount == 2)
        #expect(verifier.requests.map(\.sql) == [validationRepairedSQL])
        #expect(!result.events.map(\.kind).contains(.postgresVerificationRepairStarted))
    }

    @Test func constrainedLocalRejectsWritesBeforeRepairBudgetIsSpent() async throws {
        let generator = ConstrainedScriptedGenerator([
            .success(generation(sql: "INSERT INTO public.users (id) VALUES (1)", generationCallCount: 2))
        ])

        let result = try await run(generator)

        guard case .failed = result.finalDecision else {
            Issue.record("expected failed decision")
            return
        }
        #expect(generator.contexts.count == 1)
        #expect(result.events.contains {
            $0.kind == .validationFailed
                && $0.stage == .safetyValidation
                && $0.failureCategory == .safetyValidation
        })
        #expect(result.trace.stages.contains {
            $0.stage == .safetyValidation
                && $0.outcome == .failure
        })
    }

    @Test func clarificationReturnsFinalClarification() async throws {
        let result = try await run(
            ScriptedGenerator([
                .success(
                    generation(
                        sql: "",
                        explanation: "Needs a metric.",
                        needsClarification: true,
                        clarificationQuestion: "Which metric defines best?"
                    )
                )
            ])
        )

        guard case .clarification(let generation) = result.finalDecision else {
            Issue.record("expected clarification decision")
            return
        }
        #expect(generation.clarificationQuestion == "Which metric defines best?")
    }

    @Test func productionDefaultAllowsGroundingClarification() async throws {
        let generator = ScriptedGenerator([
            .success(
                generation(
                    sql: "SELECT id FROM public.users WHERE status = 'active' LIMIT 100"
                )
            )
        ])

        let result = try await TextToSQLPipeline(generator: generator).run(
            TextToSQLRequest(
                question: "show active users",
                schema: makeStatusSchema()
            )
        )

        guard case .clarification(let generation) = result.finalDecision else {
            Issue.record("expected grounding clarification decision")
            return
        }
        #expect(generator.contexts.count == 1)
        #expect(generation.pendingClarification?.concept.term == "active")
        #expect(generation.needsClarification)
    }

    @Test func mixedCaseIdentifierIsDeterministicallyQuoted() async throws {
        let result = try await run(
            ScriptedGenerator([
                .success(generation(sql: "SELECT createdAt FROM public.users LIMIT 100"))
            ])
        )

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected SQL decision")
            return
        }
        #expect(generation.sql == #"SELECT "createdAt" FROM public.users LIMIT 100"#)
        #expect(
            result.trace.stages.contains {
                $0.stage == .canonicalization
                    && $0.canonicalizationFixes.contains("quote-repair")
            }
        )
    }

    @Test func preseasonCreatedAtIsFixedBeforePostgresVerification() async throws {
        let generator = ScriptedGenerator([
            .success(
                generation(
                    sql: "SELECT createdAt FROM public.preseason_match_evaluation LIMIT 100"
                )
            )
        ])
        let verifier = ScriptedVerifier([.success(.passed(elapsedMs: 1))])

        let result = try await TextToSQLPipeline(generator: generator).run(
            TextToSQLRequest(
                question: "show recent preseason evaluations",
                schema: makePreseasonSchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100),
                sqlVerifier: verifier,
                verificationConnection: verificationConnection()
            )
        )

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected SQL decision")
            return
        }
        #expect(
            generation.sql
                == #"SELECT "createdAt" FROM public.preseason_match_evaluation LIMIT 100"#
        )
        #expect(verifier.requests.map(\.sql) == [generation.sql])
        #expect(result.trace.stages.contains {
            $0.stage == .canonicalization
                && $0.canonicalizationFixes.contains("quote-repair")
        })
    }

    @Test func preseasonDateSubCurdateFailsInPostgresVerificationWhenStaticValidationMissesIt()
        async throws
    {
        let badSQL = #"""
        SELECT e.id
        FROM public.preseason_match_evaluation AS e
        WHERE e."createdAt" >= DATE_SUB(CURDATE(), INTERVAL '7 days')
        LIMIT 100
        """#
        let repairedSQL = #"""
        SELECT e.id
        FROM public.preseason_match_evaluation AS e
        WHERE e."createdAt" >= DATE_SUB(NOW(), INTERVAL '7 days')
        LIMIT 100
        """#
        let generator = ScriptedGenerator([
            .success(generation(sql: badSQL)),
            .success(generation(sql: repairedSQL)),
        ])
        let verifier = ScriptedVerifier([
            .success(
                verificationFailure(
                    .undefinedFunction,
                    sqlState: "42883",
                    message: "function curdate() does not exist"
                )
            ),
            .success(
                verificationFailure(
                    .undefinedFunction,
                    sqlState: "42883",
                    message: "function date_sub(timestamp with time zone, interval) does not exist"
                )
            ),
        ])

        let result = try await TextToSQLPipeline(generator: generator).run(
            TextToSQLRequest(
                question: "show recent preseason evaluations",
                schema: makePreseasonSchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100),
                sqlVerifier: verifier,
                verificationConnection: verificationConnection()
            )
        )

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected verification failure")
            return
        }
        #expect(failure.category == .postgresVerification)
        #expect(failure.databaseDiagnostic?.kind == .undefinedFunction)
        #expect(verifier.requests.count == 2)
        #expect(result.trace.stages.contains {
            $0.stage == .schemaValidation && $0.outcome == .success
        })
    }

    @Test func preseasonToolAAndToolBReferencesFailBeforeFinalSuccess() async throws {
        let badSQL = """
        SELECT tool_a_id, tool_b_id
        FROM public.preseason_match_evaluation
        LIMIT 100
        """
        let repairedSQL = """
        SELECT winner_id
        FROM public.preseason_match_evaluation
        WHERE winner_id IS NOT NULL
        LIMIT 100
        """
        let generator = ScriptedGenerator([
            .success(generation(sql: badSQL)),
            .success(generation(sql: repairedSQL)),
        ])
        let verifier = ScriptedVerifier([.success(.passed(elapsedMs: 1))])

        let result = try await TextToSQLPipeline(generator: generator).run(
            TextToSQLRequest(
                question: "show preseason winners",
                schema: makePreseasonSchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100),
                sqlVerifier: verifier,
                verificationConnection: verificationConnection()
            )
        )

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected repaired SQL decision")
            return
        }
        #expect(generation.sql == repairedSQL)
        #expect(verifier.requests.map(\.sql) == [repairedSQL])
        #expect(result.trace.stages.contains {
            $0.stage == .schemaValidation && $0.outcome == .failure
        })
        #expect(result.trace.stages.contains {
            $0.stage == .postgresVerification
                && $0.outcome == .skipped
                && $0.verificationStatus == .skippedStaticValidationFailed
        })
    }

    @Test func preseasonWinnerIDToToolIDSQLVerifies() async throws {
        let sql = """
        SELECT t.id, t.name, count(*) AS wins
        FROM public.preseason_match_evaluation AS e
        JOIN public.preseason_tool AS t ON e.winner_id = t.id
        WHERE e.winner_id IS NOT NULL
        GROUP BY t.id, t.name
        ORDER BY wins DESC
        LIMIT 100
        """
        let generator = ScriptedGenerator([.success(generation(sql: sql))])
        let verifier = ScriptedVerifier([.success(.passed(elapsedMs: 2))])

        let result = try await TextToSQLPipeline(generator: generator).run(
            TextToSQLRequest(
                question: "show top preseason tools by wins",
                schema: makePreseasonSchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100),
                allowGroundingClarification: false,
                sqlVerifier: verifier,
                verificationConnection: verificationConnection()
            )
        )

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected SQL decision")
            return
        }
        #expect(generation.sql == sql)
        #expect(verifier.requests.map(\.sql) == [sql])
        #expect(result.trace.stages.contains {
            $0.stage == .postgresVerification
                && $0.outcome == .success
                && $0.verificationStatus == .passed
        })
    }

    @Test func quoteRepairRevalidatesBeforeReturningSQL() async throws {
        let partialSQL = "SELECT createdAt, missing FROM public.users"
        let fixedSQL = "SELECT id FROM public.users LIMIT 100"
        let generator = ScriptedGenerator([
            .success(generation(sql: partialSQL)),
            .success(generation(sql: fixedSQL)),
        ])

        let result = try await run(generator)

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected SQL decision")
            return
        }
        #expect(generation.sql == fixedSQL)
        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[1].mode == .repair)
        #expect(result.events.contains { $0.kind == .validationFailed })
    }

    @Test func invalidInitialSQLCanRepairToValidSQL() async throws {
        let generator = ScriptedGenerator([
            .success(generation(sql: "SELECT missing FROM public.users")),
            .success(generation(sql: "SELECT id FROM public.users LIMIT 100")),
        ])

        let result = try await run(generator)

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected repaired SQL decision")
            return
        }
        #expect(generation.sql == "SELECT id FROM public.users LIMIT 100")
        #expect(generator.contexts.count == 2)
        #expect(generator.contexts[1].mode == .repair)
    }

    @Test func validationRepairHonorsDisabledGroundingClarification() async throws {
        let generator = ScriptedGenerator([
            .success(generation(sql: "SELECT missing FROM public.users")),
            .success(
                generation(sql: "SELECT id FROM public.users WHERE status = 'active' LIMIT 100")
            ),
        ])

        let result = try await TextToSQLPipeline(generator: generator).run(
            TextToSQLRequest(
                question: "show active users",
                schema: makeStatusSchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100),
                allowGroundingClarification: false
            )
        )

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected repaired SQL decision")
            return
        }
        #expect(generation.sql == "SELECT id FROM public.users WHERE status = 'active' LIMIT 100")
        #expect(!generation.needsClarification)
        #expect(generator.contexts.count == 2)
    }

    @Test func repeatedSafetyRepairReturnsSafetyFailure() async throws {
        let sql = "SELECT AVG(COUNT(*) OVER ()) FROM public.users"
        let generator = ScriptedGenerator([
            .success(generation(sql: sql)),
            .success(generation(sql: sql)),
        ])

        let result = try await run(generator)

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.stage == .validationRepair)
        #expect(failure.category == .safetyValidation)
        #expect(generator.contexts.count == 2)
    }

    @Test func repeatedUnsafeRepairPreservesSafetyFailure() async throws {
        let unsafeSQL = "SELECT id FROM public.users; DROP TABLE public.users"
        let generator = ScriptedGenerator([
            .success(generation(sql: unsafeSQL)),
            .success(generation(sql: unsafeSQL)),
        ])

        let result = try await run(generator)

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.stage == .validationRepair)
        #expect(failure.category == .safetyValidation)
        #expect(result.trace.stages.contains {
            $0.stage == .validationRepair
                && $0.outcome == .failure
                && $0.failureCategory == .safetyValidation
        })
    }

    @Test func repairThatRemainsInvalidReturnsSchemaFailure() async throws {
        let generator = ScriptedGenerator([
            .success(generation(sql: "SELECT missing FROM public.users")),
            .success(generation(sql: "SELECT absent FROM public.users")),
            .success(generation(sql: "SELECT nope FROM public.users")),
        ])

        let result = try await run(generator)

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.category == .schemaValidation)
        #expect(failure.message.contains("still failed validation"))
        #expect(failure.message.contains("I did not show the rejected SQL"))
        #expect(!failure.message.contains("rejected SQL and repair attempts are shown above"))
    }

    @Test func repairGeneratorFailureReturnsFailedDecision() async throws {
        let generator = ScriptedGenerator([
            .success(generation(sql: "SELECT missing FROM public.users")),
            .failure(SQLGenerationFailure.transport("Network failed.")),
        ])

        let result = try await run(generator)

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.stage == .validationRepair)
        #expect(failure.category == .transport)
        #expect(generator.contexts.count == 2)
        #expect(result.trace.modelCalls == 2)
    }

    @Test func unsafeWriteRepairForReadIsRejected() async throws {
        let generator = ScriptedGenerator([
            .success(generation(sql: "SELECT missing FROM public.users")),
            .success(generation(sql: "INSERT INTO public.users (id) VALUES (1)")),
        ])

        let result = try await run(generator)

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.category == .safetyValidation)
        #expect(result.events.contains {
            $0.kind == .validationRepairRejected
                && $0.failureCategory == .safetyValidation
        })
        #expect(result.trace.stages.contains {
            $0.stage == .validationRepair
                && $0.outcome == .failure
                && $0.failureCategory == .safetyValidation
        })
    }

    @Test func unsafeValidationRepairReturnsSafetyFailure() async throws {
        let unsafeSQL = "SELECT id FROM public.users; DROP TABLE public.users"
        let generator = ScriptedGenerator([
            .success(generation(sql: "SELECT missing FROM public.users", generationCallCount: 2)),
            .success(generation(sql: unsafeSQL)),
        ])

        let result = try await run(generator)

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.stage == .validationRepair)
        #expect(failure.category == .safetyValidation)
        #expect(result.events.contains {
            $0.kind == .validationRepairRejected
                && $0.failureCategory == .safetyValidation
        })
        #expect(result.trace.stages.contains {
            $0.stage == .validationRepair
                && $0.outcome == .failure
                && $0.failureCategory == .safetyValidation
        })
    }

    @Test func validationRepairEventsAreTypedRedactedAndObservational() async throws {
        let badSQL = "SELECT missing FROM public.users"
        let fixedSQL = "SELECT id FROM public.users LIMIT 100"
        let collector = EventCollector()
        let generator = ScriptedGenerator([
            .success(generation(sql: badSQL)),
            .success(generation(sql: fixedSQL)),
        ])

        let result = try await TextToSQLPipeline(generator: generator).run(
            TextToSQLRequest(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100),
                eventSink: { event in
                    await collector.record(event)
                }
            )
        )

        guard case .sql(let generation) = result.finalDecision else {
            Issue.record("expected SQL decision")
            return
        }
        #expect(generation.sql == fixedSQL)
        #expect(result.events.map(\.kind) == [
            .validationFailed,
            .validationRepairStarted,
            .validationRepairPassedValidation,
        ])
        let eventText = result.events.map { "\($0.title)\n\($0.summary ?? "")" }
            .joined(separator: "\n")
        #expect(!eventText.contains(badSQL))
        #expect(!eventText.contains(fixedSQL))

        #expect(await collector.all() == result.events)
    }

    @Test func safetyValidationTraceIssueIDsAreRedacted() async throws {
        let unsafeSQL = "DROP TABLE public.users"
        let generator = ScriptedGenerator([
            .success(generation(sql: unsafeSQL)),
            .failure(SQLGenerationFailure.generation("No repair available.")),
        ])

        let result = try await run(generator)

        guard case .failed = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(result.events.contains {
            $0.kind == .validationFailed
                && $0.stage == .safetyValidation
                && $0.failureCategory == .safetyValidation
        })
        let issueIDs = result.trace.stages
            .filter { $0.stage == .safetyValidation && $0.outcome == .failure }
            .flatMap(\.validationIssueIDs)
        #expect(!issueIDs.isEmpty)
        #expect(issueIDs.allSatisfy { $0.hasPrefix("safety:") })

        let joinedIssueIDs = issueIDs.joined(separator: " ")
        #expect(!joinedIssueIDs.localizedCaseInsensitiveContains("drop"))
        #expect(!joinedIssueIDs.localizedCaseInsensitiveContains("public.users"))
        #expect(!joinedIssueIDs.contains(unsafeSQL))
    }

    @Test(arguments: [
        (SQLGenerationFailure.backendUnavailable("No model."), TextToSQLFailureCategory.backendUnavailable),
        (SQLGenerationFailure.transport("Network failed."), TextToSQLFailureCategory.transport),
        (SQLGenerationFailure.contextWindow("Too large."), TextToSQLFailureCategory.contextWindow),
        (
            SQLGenerationFailure.structuredResponseParsing("Bad JSON."),
            TextToSQLFailureCategory.structuredResponseParsing
        ),
        (SQLGenerationFailure.generation("Refused."), TextToSQLFailureCategory.modelGeneration),
    ])
    func typedGeneratorFailuresRemainDistinct(
        error: SQLGenerationFailure,
        category: TextToSQLFailureCategory
    ) async throws {
        let result = try await run(ScriptedGenerator([.failure(error)]))

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.category == category)
        #expect(failure.stage == .modelGeneration)
    }

    @Test func cancellationPropagates() async {
        do {
            _ = try await run(ScriptedGenerator([.failure(CancellationError())]))
            Issue.record("expected cancellation")
        } catch is CancellationError {
            #expect(true)
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test func modelCallCountIncludesValidationRepair() async throws {
        let generator = ScriptedGenerator(
            [
                .success(generation(sql: "SELECT missing FROM public.users")),
                .success(generation(sql: "SELECT id FROM public.users LIMIT 100")),
            ],
            echoModelCallCount: true
        )

        let result = try await run(generator)

        #expect(result.trace.modelCalls == 2)
        #expect(generator.contexts[1].modelCallCount == 2)
    }

    @Test func repairSchemaToolTracesPreserveRepeatedProviderCallIDs() async throws {
        let initialTrace = schemaToolTrace(callID: "search", toolName: "search_schema")
        let repairTrace = schemaToolTrace(callID: "search", toolName: "search_schema")
        let generator = ScriptedGenerator([
            .success(
                generation(
                    sql: "SELECT missing FROM public.users",
                    schemaToolCalls: [initialTrace]
                )
            ),
            .success(
                generation(
                    sql: "SELECT id FROM public.users LIMIT 100",
                    schemaToolCalls: [repairTrace]
                )
            ),
        ])

        let result = try await run(generator)

        #expect(result.trace.schemaToolCalls.map(\.callID) == ["search", "search"])
        #expect(result.trace.schemaToolCalls.count == 2)
    }

    @Test func repairInspectionToolTracesPreserveRepeatedProviderCallIDs() async throws {
        let initialTrace = inspectionToolTrace(callID: "inspect", toolName: "inspect_relation_size")
        let repairTrace = inspectionToolTrace(callID: "inspect", toolName: "inspect_relation_size")
        let generator = ScriptedGenerator([
            .success(
                generation(
                    sql: "SELECT missing FROM public.users",
                    inspectionToolCalls: [initialTrace]
                )
            ),
            .success(
                generation(
                    sql: "SELECT id FROM public.users LIMIT 100",
                    inspectionToolCalls: [repairTrace]
                )
            ),
        ])

        let result = try await run(generator)

        #expect(result.trace.inspectionToolCalls.map(\.callID) == ["inspect", "inspect"])
        #expect(result.trace.inspectionToolCalls.count == 2)
    }

    @Test func postgresVerificationRepairPreservesSchemaToolTraces() async throws {
        let initialTrace = schemaToolTrace(callID: "search", toolName: "search_schema")
        let repairTrace = schemaToolTrace(callID: "search", toolName: "search_schema")
        let generator = ScriptedGenerator([
            .success(
                generation(
                    sql: "SELECT id FROM public.users LIMIT 100",
                    schemaToolCalls: [initialTrace]
                )
            ),
            .success(
                generation(
                    sql: #"SELECT "createdAt" FROM public.users LIMIT 100"#,
                    schemaToolCalls: [repairTrace]
                )
            ),
        ])
        let verifier = ScriptedVerifier([
            .success(verificationFailure(.undefinedFunction, sqlState: "42883")),
            .success(.passed(elapsedMs: 2)),
        ])

        let result = try await run(
            generator,
            verifier: verifier,
            verificationConnection: verificationConnection()
        )

        #expect(result.trace.schemaToolCalls.map(\.callID) == ["search", "search"])
        #expect(result.trace.schemaToolCalls.count == 2)
        #expect(result.trace.stages.contains { $0.stage == .postgresVerificationRepair })
    }

    @Test func repairFailureTraceKeepsGeneratorElapsedTime() async throws {
        let generator = DelayedRepairFailureGenerator(
            firstResult: generation(sql: "SELECT missing FROM public.users")
        )

        let result = try await TextToSQLPipeline(generator: generator).run(
            TextToSQLRequest(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100)
            )
        )

        guard case .failed(let failure) = result.finalDecision else {
            Issue.record("expected failure decision")
            return
        }
        #expect(failure.category == .transport)
        let repairFailureStage = result.trace.stages.last {
            $0.stage == .validationRepair && $0.outcome == .failure
        }
        #expect((repairFailureStage?.elapsedMs ?? 0) >= 10)
    }

    @Test func evalRunnerScoresFinalPipelineResult() async throws {
        let evalCase = TextToSQLEvalCase(
            id: "users.valid-after-repair",
            schemaFixture: "users",
            question: "show users",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.users"],
                requiredColumnBindings: ["public.users.id"]
            )
        )
        let generator = ScriptedGenerator([
            .success(generation(sql: "SELECT missing FROM public.users")),
            .success(generation(sql: "SELECT id FROM public.users LIMIT 100")),
        ])

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeSchema(),
            generator: generator,
            options: TextToSQLEvalRunOptions(backend: .local)
        )

        #expect(result.status == .passed)
        #expect(result.generatedSQL == "SELECT id FROM public.users LIMIT 100")
        #expect(result.trace?.stages.contains { $0.stage == .validationRepair } == true)
    }
}
