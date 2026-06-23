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
        #expect(failure.category == .schemaValidation)
        #expect(result.events.map(\.error).contains {
            $0?.contains("data-modifying query") == true
        })
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
