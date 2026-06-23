import Foundation
import Testing

@testable import WidenKit

@Suite("TextToSQLPipeline")
struct TextToSQLPipelineTests {
    private final class ScriptedGenerator: SQLGenerator, @unchecked Sendable {
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

    private func generation(
        sql: String,
        explanation: String = "Generated SQL.",
        needsClarification: Bool = false,
        clarificationQuestion: String? = nil,
        generationCallCount: Int? = nil
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
            generationCallCount: generationCallCount
        )
    }

    private func run(_ generator: ScriptedGenerator) async throws -> TextToSQLRun {
        try await TextToSQLPipeline(generator: generator).run(
            TextToSQLRequest(
                question: "show users",
                schema: makeSchema(),
                config: SQLGenerationConfig(defaultRowLimit: 100)
            )
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

    @Test func repeatedRepairReturnsTypedNoProgressFailure() async throws {
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
        #expect(failure.category == .repeatedNoProgressRepair)
        #expect(generator.contexts.count == 2)
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

        var collected: [TextToSQLPipelineEvent] = []
        for _ in 0..<20 {
            collected = await collector.all()
            if collected.count == result.events.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(collected == result.events)
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
