import Foundation
import Testing

@testable import WidenKit

@Suite("Text-to-SQL eval")
struct TextToSQLEvalTests {
    private struct StaticGenerator: SQLGenerator {
        var result: SQLGenerationResult

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            result
        }
    }

    private struct ThrowingGenerator: SQLGenerator {
        var error: any Error

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            throw error
        }
    }

    private final class HangingGenerator: SQLGenerator, @unchecked Sendable {
        private let lock = NSLock()
        private var cancellationObserved = false

        var wasCancelled: Bool {
            lock.withLock { cancellationObserved }
        }

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch is CancellationError {
                lock.withLock { cancellationObserved = true }
                throw CancellationError()
            }
            throw SQLGenerationFailure.generation("Hanging generator unexpectedly completed.")
        }
    }

    private struct BlockingGenerator: SQLGenerator {
        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline {}
            throw SQLGenerationFailure.generation("Blocking generator unexpectedly completed.")
        }
    }

    private struct UntypedGeneratorFailure: Error {}

    @Test func scoresValidSQLShapeAsPassed() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.customer-order-ids",
            schemaFixture: "commerce",
            question: "List customers and their order ids",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.customers", "public.orders"],
                requiredColumnBindings: [
                    "public.customers.id",
                    "public.orders.customer_id",
                ],
                requiredOperations: [.join, .limit]
            )
        )
        let generation = SQLGenerationResult(
            sql: """
                SELECT c.id, c.email
                FROM public.customers AS c
                JOIN public.orders AS o ON o.customer_id = c.id
                ORDER BY c.id
                LIMIT 100
                """,
            explanation: "Lists customers without orders.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .local),
            latencyMs: 12
        )

        #expect(result.status == .passed)
        #expect(result.metrics.safetyValid == true)
        #expect(result.metrics.schemaValid == true)
        #expect(result.metrics.requiredTableCoverage == .some(1.0))
        #expect(result.metrics.requiredColumnBindingCoverage == .some(1.0))
    }

    @Test func successfulScoringUsesPipelineTraceModelCalls() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.customer-order-ids",
            schemaFixture: "commerce",
            question: "List customers and their order ids",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.customers", "public.orders"],
                requiredColumnBindings: [
                    "public.customers.id",
                    "public.orders.customer_id",
                ],
                requiredOperations: [.join, .limit]
            )
        )
        let generation = SQLGenerationResult(
            sql: """
                SELECT c.id, c.email
                FROM public.customers AS c
                JOIN public.orders AS o ON o.customer_id = c.id
                ORDER BY c.id
                LIMIT 100
                """,
            explanation: "Lists customers without orders.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil,
            generationCallCount: nil
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .local),
            latencyMs: 12,
            trace: TextToSQLTrace(stages: [], modelCalls: 2, elapsedMs: 12)
        )

        #expect(result.status == .passed)
        #expect(result.metrics.modelCallCount == 2)
    }

    @Test func repeatedNoProgressFailureCountsAsSchemaInvalid() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.ambiguous-id",
            schemaFixture: "commerce",
            question: "List customer order ids",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.customers", "public.orders"]
            )
        )
        let generator = StaticGenerator(
            result: SQLGenerationResult(
                sql: """
                    SELECT id
                    FROM public.customers
                    JOIN public.orders ON customers.id = orders.customer_id
                    LIMIT 100
                    """,
                explanation: "Uses an ambiguous id column.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.7,
                riskLevel: .medium,
                needsClarification: false,
                clarificationQuestion: nil
            )
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: generator,
            options: TextToSQLEvalRunOptions(backend: .local)
        )

        #expect(result.status == .wrongSchemaObjects)
        #expect(result.metrics.schemaValid == false)
    }

    @Test func scoresClarificationAsPassed() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.best-customers",
            schemaFixture: "commerce",
            question: "Who are our best customers?",
            expected: TextToSQLEvalExpectation(
                decision: .clarify,
                clarificationMustMentionAny: ["metric", "revenue", "spend", "orders", "best"]
            )
        )
        let generator = StaticGenerator(
            result: SQLGenerationResult(
                sql: "",
                explanation: "Needs a definition.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.2,
                riskLevel: .medium,
                needsClarification: true,
                clarificationQuestion: "What metric defines best customers?"
            )
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: generator,
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .passed)
        #expect(result.metrics.clarificationQuality == true)
    }

    @Test func scoresImperativeClarificationAsPassed() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.best-customers",
            schemaFixture: "commerce",
            question: "Who are our best customers?",
            expected: TextToSQLEvalExpectation(
                decision: .clarify,
                clarificationMustMentionAny: ["metric", "revenue", "spend", "orders", "best"]
            )
        )
        let generator = StaticGenerator(
            result: SQLGenerationResult(
                sql: "",
                explanation: "Needs a definition.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.2,
                riskLevel: .medium,
                needsClarification: true,
                clarificationQuestion: "Please specify the metric for best customers."
            )
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: generator,
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .passed)
        #expect(result.metrics.clarificationQuality == true)
    }

    @Test func genericClarificationQuestionFailsQualityScoring() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.best-customers",
            schemaFixture: "commerce",
            question: "Who are our best customers?",
            expected: TextToSQLEvalExpectation(
                decision: .clarify,
                clarificationMustMentionAny: ["metric", "revenue", "spend", "orders", "best"]
            )
        )
        let generator = StaticGenerator(
            result: SQLGenerationResult(
                sql: "",
                explanation: "Needs a definition.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.2,
                riskLevel: .medium,
                needsClarification: true,
                clarificationQuestion: "What do you mean?"
            )
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: generator,
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .wrongDecision)
        #expect(result.metrics.clarificationQuality == false)
    }

    @Test func evalRunnerUsesProductionGroundingByDefault() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.active-customers",
            schemaFixture: "commerce",
            question: "Show active customers",
            expected: TextToSQLEvalExpectation(
                decision: .clarify,
                clarificationMustMentionAny: ["active", "status"]
            )
        )
        let generator = StaticGenerator(
            result: SQLGenerationResult(
                sql: "SELECT id FROM public.customers WHERE status = 'active' LIMIT 100",
                explanation: "Lists active customers.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.8,
                riskLevel: .medium,
                needsClarification: false,
                clarificationQuestion: nil
            )
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: generator,
            options: TextToSQLEvalRunOptions(backend: .local)
        )

        #expect(result.status == .passed)
        #expect(result.metrics.decisionMatches)
        #expect(result.clarificationQuestion?.localizedCaseInsensitiveContains("active") == true)
    }

    @Test func testOnlyNoGroundingOptionKeepsInitialSQL() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.active-customers",
            schemaFixture: "commerce",
            question: "Show active customers",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.customers"],
                requiredColumnBindings: [
                    "public.customers.id",
                    "public.customers.status",
                ],
                requiredOperations: [.limit]
            )
        )
        let generator = StaticGenerator(
            result: SQLGenerationResult(
                sql: "SELECT id FROM public.customers WHERE status = 'active' LIMIT 100",
                explanation: "Lists active customers.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.8,
                riskLevel: .medium,
                needsClarification: false,
                clarificationQuestion: nil
            )
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: generator,
            options: TextToSQLEvalRunOptions(
                backend: .local,
                testOnlyDisableGroundingClarification: true
            )
        )

        #expect(result.status == .passed)
        #expect(result.metrics.decisionMatches)
    }

    @Test func forbiddenColumnBindingFailsShapeScore() async {
        let evalCase = TextToSQLEvalCase(
            id: "preseason.forbidden-tool-a",
            schemaFixture: "preseason",
            question: "List evaluation tool A ids",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.preseason_match_evaluation"],
                forbiddenColumnBindings: [
                    "public.preseason_match_evaluation.tool_a_id"
                ]
            )
        )
        let generation = SQLGenerationResult(
            sql: """
                SELECT tool_a_id, COUNT(*) AS wins
                FROM public.preseason_match_evaluation
                GROUP BY tool_a_id
                ORDER BY wins DESC
                LIMIT 10
                """,
            explanation: "Ranks tools.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.7,
            riskLevel: .medium,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makePreseasonSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .local),
            latencyMs: 12
        )

        #expect(result.status == .wrongSchemaObjects)
        #expect(result.metrics.forbiddenBindingViolations.isEmpty)
        #expect(
            result.diagnostics.schemaErrors.contains {
                $0.contains("tool_a_id is not on public.preseason_match_evaluation")
            })
    }

    @Test func detectsFormattedJoinAndOrderingOperations() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.customers-without-orders",
            schemaFixture: "commerce",
            question: "Which customers have never placed an order?",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.customers", "public.orders"],
                requiredColumnBindings: [
                    "public.customers.id",
                    "public.orders.customer_id",
                    "public.orders.id",
                ],
                requiredOperations: [.leftJoin, .nullFilter, .descendingOrder, .limit]
            )
        )
        let generation = SQLGenerationResult(
            sql: """
                SELECT c.id
                FROM public.customers AS c
                LEFT JOIN public.orders AS o
                  ON o.customer_id = c.id
                WHERE o.id IS NULL
                ORDER BY c.id DESC
                LIMIT 100
                """,
            explanation: "Lists customers without orders.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .local),
            latencyMs: 12
        )

        #expect(result.status == .passed)
        #expect(result.diagnostics.missingOperations.isEmpty)
    }

    @Test func notExistsSatisfiesAbsenceOperations() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.customers-without-orders",
            schemaFixture: "commerce",
            question: "Which customers have never placed an order?",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.customers", "public.orders"],
                requiredColumnBindings: [
                    "public.customers.id",
                    "public.orders.customer_id",
                ],
                requiredOperations: [.leftJoin, .nullFilter, .limit]
            )
        )
        let generation = SQLGenerationResult(
            sql: """
                SELECT c.id
                FROM public.customers AS c
                WHERE NOT EXISTS (
                  SELECT 1
                  FROM public.orders AS o
                  WHERE o.customer_id = c.id
                )
                FETCH FIRST 100 ROWS ONLY
                """,
            explanation: "Lists customers without orders.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .local),
            latencyMs: 12
        )

        #expect(result.status == .passed)
        #expect(result.diagnostics.missingOperations.isEmpty)
    }

    @Test func modelUnavailableBecomesBackendUnavailable() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: ThrowingGenerator(error: SQLGenerationFailure.backendUnavailable("No model.")),
            options: TextToSQLEvalRunOptions(backend: .local)
        )

        #expect(result.status == .backendUnavailable)
        #expect(result.metrics.backendAvailable == false)
        #expect(result.metrics.transportSuccess == false)
    }

    @Test func untypedGeneratorFailureBecomesGenerationFailure() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: ThrowingGenerator(error: UntypedGeneratorFailure()),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .generationFailure)
        #expect(result.metrics.backendAvailable == true)
        #expect(result.metrics.transportSuccess == true)
        #expect(result.metrics.structuredResponseParsed == false)
    }

    @Test func cancellationFailureIsNotTransportFailure() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: ThrowingGenerator(error: CancellationError()),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .generationFailure)
        #expect(result.metrics.backendAvailable == true)
        #expect(result.metrics.transportSuccess == true)
        #expect(result.diagnostics.errorMessage?.contains("cancelled") == true)
    }

    @Test func caseTimeoutCancelsHangingGeneratorAndAllowsNextCase() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )
        let hangingGenerator = HangingGenerator()

        let timeoutResult = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: hangingGenerator,
            options: TextToSQLEvalRunOptions(
                backend: .local,
                caseTimeoutSeconds: 0.01
            )
        )

        #expect(timeoutResult.status == .evalTimeout)
        #expect(timeoutResult.caseID == "commerce.recent-orders")
        #expect(timeoutResult.metrics.latencyMs >= 0)
        #expect(timeoutResult.metrics.transportSuccess)
        #expect(timeoutResult.diagnostics.errorMessage?.contains("commerce.recent-orders") == true)
        let deadline = Date().addingTimeInterval(1)
        while !hangingGenerator.wasCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(hangingGenerator.wasCancelled)

        let nextResult = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: StaticGenerator(
                result: SQLGenerationResult(
                    sql: "SELECT id FROM public.orders LIMIT 10",
                    explanation: "Lists orders.",
                    assumptions: [],
                    referencedTables: [],
                    confidence: 0.9,
                    riskLevel: .low,
                    needsClarification: false,
                    clarificationQuestion: nil
                )
            ),
            options: TextToSQLEvalRunOptions(backend: .local)
        )

        #expect(nextResult.status == .passed)
    }

    @Test func parentCancellationCancelsTimedCasePromptly() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )
        let hangingGenerator = HangingGenerator()
        let task = Task {
            await TextToSQLEvalCaseRunner.run(
                evalCase: evalCase,
                schema: makeCommerceSchema(),
                generator: hangingGenerator,
                options: TextToSQLEvalRunOptions(
                    backend: .local,
                    caseTimeoutSeconds: 60
                )
            )
        }

        task.cancel()
        let result = await task.value
        let deadline = Date().addingTimeInterval(1)
        while !hangingGenerator.wasCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        #expect(result.status == .generationFailure)
        #expect(result.diagnostics.errorMessage?.contains("cancelled") == true)
        #expect(hangingGenerator.wasCancelled)
    }

    @Test func caseTimeoutDoesNotWaitForNonCooperativeGenerator() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )
        let started = Date()

        let timeoutResult = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: BlockingGenerator(),
            options: TextToSQLEvalRunOptions(
                backend: .local,
                caseTimeoutSeconds: 0.01
            )
        )

        let elapsed = Date().timeIntervalSince(started)
        #expect(timeoutResult.status == .evalTimeout)
        #expect(elapsed < 0.2)
    }

    @Test func largeCaseTimeoutDoesNotOverflowNanoseconds() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: StaticGenerator(
                result: SQLGenerationResult(
                    sql: "SELECT id FROM public.orders LIMIT 10",
                    explanation: "Lists orders.",
                    assumptions: [],
                    referencedTables: [],
                    confidence: 0.9,
                    riskLevel: .low,
                    needsClarification: false,
                    clarificationQuestion: nil
                )
            ),
            options: TextToSQLEvalRunOptions(
                backend: .local,
                caseTimeoutSeconds: .greatestFiniteMagnitude
            )
        )

        #expect(result.status == .passed)
    }

    @Test func parseFailureKeepsTransportSuccessSeparate() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: ThrowingGenerator(
                error: SQLGenerationFailure.structuredResponseParsing(
                    "The cloud model returned an unparseable response."
                )
            ),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .parseFailure)
        #expect(result.metrics.backendAvailable == true)
        #expect(result.metrics.transportSuccess == true)
        #expect(result.metrics.structuredResponseParsed == false)
        #expect(result.metrics.requiredTableCoverage == nil)
        #expect(result.metrics.requiredColumnBindingCoverage == nil)
    }

    @Test func localStructuredDecodeFailureCountsAsParseFailure() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: ThrowingGenerator(
                error: SQLGenerationFailure.structuredResponseParsing(
                    "The local model failed to decode structured output."
                )
            ),
            options: TextToSQLEvalRunOptions(backend: .local)
        )

        #expect(result.status == .parseFailure)
        #expect(result.metrics.transportSuccess)
        #expect(result.metrics.structuredResponseParsed == false)
    }

    @Test func contextWindowFailureIsNotTransportFailure() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: ThrowingGenerator(
                error: SQLGenerationFailure.contextWindow(
                    "The schema and question exceed the local model's context window."
                )
            ),
            options: TextToSQLEvalRunOptions(backend: .local)
        )

        #expect(result.status == .contextWindowFailure)
        #expect(result.metrics.backendAvailable == true)
        #expect(result.metrics.transportSuccess == true)
    }

    @Test func modelGenerationFailureIsNotAlwaysTransportFailure() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: ThrowingGenerator(
                error: SQLGenerationFailure.generation("The local model declined to answer.")
            ),
            options: TextToSQLEvalRunOptions(backend: .local)
        )

        #expect(result.status == .generationFailure)
        #expect(result.metrics.transportSuccess == true)
    }

    @Test func wrongSQLDecisionDoesNotInflateShapeCoverage() {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.orders"],
                requiredColumnBindings: ["public.orders.created_at"]
            )
        )
        let generation = SQLGenerationResult(
            sql: "",
            explanation: "Needs clarification.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.2,
            riskLevel: .medium,
            needsClarification: true,
            clarificationQuestion: "Which orders should count?"
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .local),
            latencyMs: 12
        )

        #expect(result.status == .wrongDecision)
        #expect(result.metrics.requiredTableCoverage == nil)
        #expect(result.metrics.requiredColumnBindingCoverage == nil)
    }

    @Test func notNullDoesNotSatisfyAbsenceFilter() {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.customers-without-orders",
            schemaFixture: "commerce",
            question: "Which customers have never placed an order?",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.customers", "public.orders"],
                requiredColumnBindings: [
                    "public.customers.id",
                    "public.orders.customer_id",
                    "public.orders.id",
                ],
                requiredOperations: [.leftJoin, .nullFilter]
            )
        )
        let generation = SQLGenerationResult(
            sql: """
                SELECT c.id
                FROM public.customers AS c
                LEFT JOIN public.orders AS o ON o.customer_id = c.id
                WHERE o.id IS NOT NULL
                LIMIT 100
                """,
            explanation: "Lists customers with orders.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .local),
            latencyMs: 12
        )

        #expect(result.status == .wrongSchemaObjects)
        #expect(result.diagnostics.missingOperations == [.nullFilter])
    }

    @Test func unrelatedNullFilterDoesNotSatisfyAbsenceAntiJoin() {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.customers-without-orders",
            schemaFixture: "commerce",
            question: "Which customers have never placed an order?",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.customers", "public.orders"],
                requiredColumnBindings: [
                    "public.customers.id",
                    "public.orders.customer_id",
                ],
                requiredOperations: [.leftJoin, .nullFilter]
            )
        )
        let generation = SQLGenerationResult(
            sql: """
                SELECT c.id
                FROM public.customers AS c
                LEFT JOIN public.orders AS o ON o.customer_id = c.id
                WHERE c.status IS NULL
                LIMIT 100
                """,
            explanation: "Filters customers with missing status.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.9,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .local),
            latencyMs: 12
        )

        #expect(result.status == .wrongSchemaObjects)
        #expect(result.diagnostics.missingOperations == [.nullFilter])
    }

    @Test func starProjectionDoesNotFlagHallucinatedForbiddenColumns() {
        let evalCase = TextToSQLEvalCase(
            id: "preseason.hallucinated-forbidden-star",
            schemaFixture: "preseason",
            question: "List evaluation wins",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.preseason_match_evaluation"],
                forbiddenColumnBindings: [
                    "public.preseason_match_evaluation.tool_a_id",
                    "public.preseason_match_evaluation.tool_b_id",
                ],
                requiredOperations: [.limit]
            )
        )
        let sqls = [
            "SELECT * FROM public.preseason_match_evaluation LIMIT 100",
            "SELECT e.* FROM public.preseason_match_evaluation AS e LIMIT 100",
        ]

        for sql in sqls {
            let generation = SQLGenerationResult(
                sql: sql,
                explanation: "Lists evaluation rows.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.7,
                riskLevel: .medium,
                needsClarification: false,
                clarificationQuestion: nil
            )

            let result = TextToSQLEvalScorer.score(
                evalCase: evalCase,
                schema: makePreseasonSchema(),
                generation: generation,
                options: TextToSQLEvalRunOptions(backend: .local),
                latencyMs: 12
            )

            #expect(result.status == .passed)
            #expect(result.metrics.forbiddenBindingViolations.isEmpty)
        }
    }

    @Test func starProjectionFlagsExistingForbiddenColumns() {
        let evalCase = TextToSQLEvalCase(
            id: "preseason.forbidden-batch-star",
            schemaFixture: "preseason",
            question: "List evaluation batches",
            expected: TextToSQLEvalExpectation(
                decision: .sql,
                requiredTables: ["public.preseason_match_batch"],
                forbiddenColumnBindings: [
                    "public.preseason_match_batch.tool_a_id",
                    "public.preseason_match_batch.tool_b_id",
                ],
                requiredOperations: [.limit]
            )
        )
        let generation = SQLGenerationResult(
            sql: "SELECT * FROM public.preseason_match_batch LIMIT 100",
            explanation: "Lists batch rows.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.7,
            riskLevel: .medium,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makePreseasonSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .local),
            latencyMs: 12
        )

        #expect(result.status == .wrongSchemaObjects)
        #expect(
            result.metrics.forbiddenBindingViolations == [
                "public.preseason_match_batch.tool_a_id",
                "public.preseason_match_batch.tool_b_id",
            ])
    }

    @Test func validatesActualTextToSQLV1Suite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let suiteURL = root.appendingPathComponent("Evals/suites/text-to-sql-v1.json")
        let suiteData = try Data(contentsOf: suiteURL)
        let suite = try JSONDecoder().decode(TextToSQLEvalSuite.self, from: suiteData)

        try TextToSQLEvalSuiteValidator.validate(suite: suite, suiteURL: suiteURL)
    }

    private func makeCommerceSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "customers", type: .baseTable,
                    columns: [
                        column("customers", "id", type: "integer", ordinal: 1),
                        column("customers", "email", type: "text", ordinal: 2),
                        column("customers", "status", type: "text", ordinal: 3),
                    ]),
                TableInfo(
                    schema: "public", name: "orders", type: .baseTable,
                    columns: [
                        column("orders", "id", type: "integer", ordinal: 1),
                        column("orders", "customer_id", type: "integer", ordinal: 2),
                    ]),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "orders_customer_id_fkey",
                    sourceSchema: "public",
                    sourceTable: "orders",
                    sourceColumn: "customer_id",
                    targetSchema: "public",
                    targetTable: "customers",
                    targetColumn: "id"
                )
            ]
        )
    }

    private func makePreseasonSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "preseason_match_evaluation", type: .baseTable,
                    columns: [
                        column("preseason_match_evaluation", "id", ordinal: 1),
                        column("preseason_match_evaluation", "batch_id", ordinal: 2),
                        column("preseason_match_evaluation", "winner_id", ordinal: 3),
                        column("preseason_match_evaluation", "createdAt", type: "timestamp with time zone", ordinal: 4),
                    ]),
                TableInfo(
                    schema: "public", name: "preseason_match_batch", type: .baseTable,
                    columns: [
                        column("preseason_match_batch", "id", ordinal: 1),
                        column("preseason_match_batch", "tool_a_id", ordinal: 2),
                        column("preseason_match_batch", "tool_b_id", ordinal: 3),
                    ])
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "preseason_match_evaluation_batch_id_fkey",
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
}
