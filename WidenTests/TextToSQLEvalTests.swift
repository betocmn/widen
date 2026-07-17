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

    private struct RepairRetryFailureGenerator: SQLGenerator {
        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            if context.mode == .initial {
                return SQLGenerationResult(
                    sql: "SELECT missing_column FROM public.orders LIMIT 10",
                    explanation: "Intentionally references a missing column.",
                    assumptions: [],
                    referencedTables: [],
                    confidence: 0.5,
                    riskLevel: .medium,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    generationCallCount: 1
                )
            }
            throw OpenRouterFailure(
                category: .rateLimited,
                message: "Rate limit exceeded.",
                httpStatus: 429,
                requestedModelID: "test/model",
                attemptCount: 3
            )
        }
    }

    private struct AgentBudgetFailureGenerator: SQLGenerator {
        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            var metadata = OpenRouterGenerationMetadata(
                requestedModelID: "test/model",
                returnedModelID: "test/returned",
                providerName: "TestProvider",
                completionID: "cmpl-agent-failure",
                requestID: "req-agent-failure",
                structuredOutputMode: .promptOnlyJSON,
                requestCount: 3,
                retryCount: 1,
                promptTokens: 30,
                completionTokens: 12,
                reasoningTokens: 2,
                totalTokens: 42,
                costUSD: 0.001,
                serviceTier: nil,
                finishReason: "tool_calls",
                nativeFinishReason: nil
            )
            metadata.agentSelectionReason = "tools"
            metadata.agentLogicalTurnCount = 2
            metadata.agentHTTPAttemptCount = 3
            metadata.agentSchemaToolCallCount = 1
            throw OpenRouterSchemaToolAgentFailure(
                category: .schemaToolCallBudgetExhausted,
                message: "Schema tool call budget exhausted.",
                backendMetadata: metadata,
                schemaToolCalls: [
                    SchemaToolCallTrace(
                        callID: "search-over-budget",
                        toolName: "search_schema",
                        outcome: .error,
                        latencyMs: 1,
                        returnedObjectCount: 0,
                        outputByteCount: 128,
                        truncated: false,
                        errorCode: .sessionBudgetExceeded,
                        schemaFingerprintPrefix: "abcdef123456",
                        cacheHit: false
                    ),
                ]
            )
        }
    }

    private struct RepairAgentFailureGenerator: SQLGenerator {
        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            if context.mode == .initial {
                var metadata = OpenRouterGenerationMetadata(
                    requestedModelID: "test/model",
                    structuredOutputMode: .promptOnlyJSON,
                    requestCount: 1,
                    retryCount: 0
                )
                metadata.agentSelectionReason = "tools"
                metadata.agentHTTPAttemptCount = 1
                return SQLGenerationResult(
                    sql: "SELECT missing_column FROM public.orders LIMIT 10",
                    explanation: "Intentionally references a missing column.",
                    assumptions: [],
                    referencedTables: [],
                    confidence: 0.5,
                    riskLevel: .medium,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    generationCallCount: 1,
                    backendMetadata: metadata
                )
            }
            var metadata = OpenRouterGenerationMetadata(
                requestedModelID: "test/model",
                structuredOutputMode: .promptOnlyJSON,
                requestCount: 1,
                retryCount: 0
            )
            metadata.agentSelectionReason = "tools"
            metadata.agentLogicalTurnCount = 1
            metadata.agentHTTPAttemptCount = 1
            metadata.agentSchemaToolCallCount = 1
            throw OpenRouterSchemaToolAgentFailure(
                category: .schemaToolCallBudgetExhausted,
                message: "Schema tool call budget exhausted.",
                backendMetadata: metadata,
                schemaToolCalls: [TextToSQLEvalTests.schemaToolTrace(callID: "repair-agent-failure")]
            )
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

    private struct UsageReportingHangingGenerator: SQLGenerator {
        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            config.usageSink?(.httpAttempts(2))
            config.usageSink?(
                SQLGenerationUsageEvent(
                    httpAttemptCount: 0,
                    promptTokens: 12,
                    completionTokens: 8,
                    reasoningTokens: 2,
                    totalTokens: 20,
                    costUSD: 0.02
                )
            )
            try await Task.sleep(nanoseconds: 60_000_000_000)
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

    @Test func identifierSpecificClarificationPassesQualityScoring() async {
        let evalCase = TextToSQLEvalCase(
            id: "preseason.top-wins-ambiguous",
            schemaFixture: "preseason",
            question: "Tools with the most wins in the last two weeks",
            expected: TextToSQLEvalExpectation(
                decision: .clarify,
                clarificationMustMentionAny: ["win", "winner"]
            )
        )
        let generator = StaticGenerator(
            result: SQLGenerationResult(
                sql: "",
                explanation: "Needs a database decision.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.2,
                riskLevel: .medium,
                needsClarification: true,
                clarificationQuestion: "Should wins use non-null winner_id?"
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

    @Test func singularProtectedMetricClarificationPassesWithoutChangingScorerRules() async {
        let evalCase = TextToSQLEvalCase(
            id: "preseason.top-wins-ambiguous",
            schemaFixture: "preseason",
            question: "Tools with the most wins in the last two weeks",
            expected: TextToSQLEvalExpectation(
                decision: .clarify,
                clarificationMustMentionAny: ["win", "winner"]
            )
        )
        let generation = SQLGenerationResult(
            sql: "",
            explanation: "Needs a metric definition.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.2,
            riskLevel: .medium,
            needsClarification: true,
            clarificationQuestion: "What should count as one win?"
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makePreseasonSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model"),
            latencyMs: 0
        )

        #expect(result.status == .passed)
        #expect(result.metrics.decisionMatches)
        #expect(result.metrics.clarificationQuality == true)
    }

    @Test func pluralProtectedMetricClarificationStillFailsPinnedScorer() async {
        let evalCase = TextToSQLEvalCase(
            id: "preseason.top-wins-ambiguous",
            schemaFixture: "preseason",
            question: "Tools with the most wins in the last two weeks",
            expected: TextToSQLEvalExpectation(
                decision: .clarify,
                clarificationMustMentionAny: ["win", "winner"]
            )
        )
        let generation = SQLGenerationResult(
            sql: "",
            explanation: "Needs a metric definition.",
            assumptions: [],
            referencedTables: [],
            confidence: 0.2,
            riskLevel: .medium,
            needsClarification: true,
            clarificationQuestion: "Which metric should define wins?"
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makePreseasonSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model"),
            latencyMs: 0
        )

        #expect(result.status == .wrongDecision)
        #expect(result.metrics.decisionMatches)
        #expect(result.metrics.clarificationQuality == false)
    }

    @Test func genericUnderscoredClarificationFailsQualityScoring() async {
        let evalCase = TextToSQLEvalCase(
            id: "preseason.top-wins-ambiguous",
            schemaFixture: "preseason",
            question: "Tools with the most wins in the last two weeks",
            expected: TextToSQLEvalExpectation(
                decision: .clarify,
                clarificationMustMentionAny: ["win", "winner"]
            )
        )
        let generator = StaticGenerator(
            result: SQLGenerationResult(
                sql: "",
                explanation: "Needs a database decision.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.2,
                riskLevel: .medium,
                needsClarification: true,
                clarificationQuestion: "What do you mean by winner_id?"
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

    @Test func measureSpecificClarificationPassesQualityScoring() async {
        let evalCase = TextToSQLEvalCase(
            id: "openrouter.clarification",
            schemaFixture: "commerce",
            question: "Which products perform best?",
            expected: TextToSQLEvalExpectation(
                decision: .clarify,
                clarificationMustMentionAny: ["measure", "performance"]
            )
        )
        let generator = StaticGenerator(
            result: SQLGenerationResult(
                sql: "",
                explanation: "Needs a database decision.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.2,
                riskLevel: .medium,
                needsClarification: true,
                clarificationQuestion: "Which performance measure should I use?"
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

    @Test func businessMetricAlternativeClarificationPassesQualityScoring() async {
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
                explanation: "Needs a database decision.",
                assumptions: [],
                referencedTables: [],
                confidence: 0.2,
                riskLevel: .medium,
                needsClarification: true,
                clarificationQuestion: "Should best customers mean highest revenue or largest spend?"
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

    @Test func currentClarificationCasesRequireConcreteDatabaseDecision() async {
        let cases: [(TextToSQLEvalCase, good: String, bad: String)] = [
            (
                TextToSQLEvalCase(
                    id: "commerce.best-customers",
                    schemaFixture: "commerce",
                    question: "Who are our best customers?",
                    expected: TextToSQLEvalExpectation(
                        decision: .clarify,
                        clarificationMustMentionAny: ["metric", "revenue", "spend", "orders", "best"]
                    )
                ),
                "Which metric should define best customers: revenue, spend, or order count?",
                "What do you mean by best?"
            ),
            (
                TextToSQLEvalCase(
                    id: "support.important-cluster",
                    schemaFixture: "support",
                    question: "What is our most important feedback cluster?",
                    expected: TextToSQLEvalExpectation(
                        decision: .clarify,
                        clarificationMustMentionAny: ["important", "priority", "impact", "frequency"]
                    )
                ),
                "Which metric should define important clusters: priority, impact, or frequency?",
                "What do you mean by important?"
            ),
            (
                TextToSQLEvalCase(
                    id: "saas.healthy-accounts",
                    schemaFixture: "saas",
                    question: "Which accounts are healthy?",
                    expected: TextToSQLEvalExpectation(
                        decision: .clarify,
                        clarificationMustMentionAny: ["healthy", "health", "status", "usage"]
                    )
                ),
                "Which status or usage filter should define healthy accounts?",
                "What do you mean by healthy?"
            ),
            (
                TextToSQLEvalCase(
                    id: "preseason.top-wins-ambiguous",
                    schemaFixture: "preseason",
                    question: "Tools with the most wins in the last two weeks",
                    expected: TextToSQLEvalExpectation(
                        decision: .clarify,
                        clarificationMustMentionAny: ["win", "winner", "status", "decision", "date", "time"]
                    )
                ),
                "Should wins mean counting rows where winner_id is not null, and which date field sets the time window?",
                "What do you mean by wins?"
            ),
        ]

        for (evalCase, good, bad) in cases {
            let goodResult = await TextToSQLEvalCaseRunner.run(
                evalCase: evalCase,
                schema: makeCommerceSchema(),
                generator: StaticGenerator(
                    result: SQLGenerationResult(
                        sql: "",
                        explanation: "Needs a database decision.",
                        assumptions: [],
                        referencedTables: [],
                        confidence: 0.2,
                        riskLevel: .medium,
                        needsClarification: true,
                        clarificationQuestion: good
                    )
                ),
                options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
            )
            #expect(goodResult.status == .passed)
            #expect(goodResult.metrics.clarificationQuality == true)

            let badResult = await TextToSQLEvalCaseRunner.run(
                evalCase: evalCase,
                schema: makeCommerceSchema(),
                generator: StaticGenerator(
                    result: SQLGenerationResult(
                        sql: "",
                        explanation: "Generic clarification.",
                        assumptions: [],
                        referencedTables: [],
                        confidence: 0.2,
                        riskLevel: .medium,
                        needsClarification: true,
                        clarificationQuestion: bad
                    )
                ),
                options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
            )
            #expect(badResult.status == .wrongDecision)
            #expect(badResult.metrics.clarificationQuality == false)
        }
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

    @Test func openRouterPaymentRequiredIsDistinctFromTransportFailure() async {
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
                error: OpenRouterFailure(
                    category: .paymentRequired,
                    message: "Payment required.",
                    httpStatus: 402,
                    openRouterErrorType: "insufficient_credits",
                    providerCode: "credits",
                    requestedModelID: "test/model"
                )
            ),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .paymentRequired)
        #expect(result.metrics.backendAvailable == true)
        #expect(result.metrics.transportSuccess == false)
        #expect(result.diagnostics.openRouterFailureCategory == "paymentRequired")
    }

    @Test func openRouterProviderLimitIsDistinctFromTransportFailure() async {
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
                error: OpenRouterFailure(
                    category: .providerLimit,
                    message: "Provider limit.",
                    openRouterErrorType: "provider_limit_exceeded",
                    providerCode: "provider_limit",
                    requestedModelID: "test/model"
                )
            ),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .providerLimit)
        #expect(result.metrics.backendAvailable == true)
        #expect(result.metrics.transportSuccess == false)
        #expect(result.diagnostics.openRouterFailureCategory == "providerLimit")
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

    @Test func httpBudgetExhaustionBecomesSkippedBudgetLimit() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )
        let metadata = OpenRouterGenerationMetadata(
            requestedModelID: "test/model",
            structuredOutputMode: .promptOnlyJSON,
            requestCount: 2,
            retryCount: 0
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: ThrowingGenerator(
                error: OpenRouterHTTPAttemptBudgetExhausted(
                    message: "OpenRouter HTTP-attempt budget exhausted.",
                    backendMetadata: metadata
                )
            ),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .skippedBudgetLimit)
        #expect(result.status.isCompletedEvaluation == false)
        #expect(result.metrics.transportSuccess == false)
        #expect(result.metrics.modelCallCount == 2)
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

    @Test func caseTimeoutPreservesObservedCloudUsage() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: UsageReportingHangingGenerator(),
            options: TextToSQLEvalRunOptions(
                backend: .cloud,
                model: "test/model",
                caseTimeoutSeconds: 0.01
            )
        )

        #expect(result.status == .evalTimeout)
        #expect(result.metrics.modelCallCount == 2)
        #expect(result.metrics.tokenUsage == 20)
        #expect(result.metrics.estimatedCloudCostUSD == 0.02)
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

    @Test func openRouterFailureUsageReachesEvalCostMetrics() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )
        let failure = OpenRouterFailure(
            category: .malformedStructuredResponse,
            message: "Malformed completion.",
            requestedModelID: "test/model",
            promptTokens: 4,
            completionTokens: 5,
            reasoningTokens: 2,
            totalTokens: 9,
            costUSD: 0.25
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: ThrowingGenerator(error: failure),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .parseFailure)
        #expect(result.metrics.tokenUsage == 9)
        #expect(result.metrics.estimatedCloudCostUSD == 0.25)
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

    @Test func repairOpenRouterFailureCountsRetryAttempts() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: RepairRetryFailureGenerator(),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .transportFailure)
        #expect(result.metrics.modelCallCount == 4)
        #expect(result.metrics.openRouterRetryCount == 2)
        #expect(result.diagnostics.openRouterAttemptCount == 3)
    }

    @Test func pipelineFailurePreservesAgentAggregateMetadata() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: AgentBudgetFailureGenerator(),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .generationFailure)
        #expect(result.metrics.modelCallCount == 3)
        #expect(result.metrics.openRouterRetryCount == 1)
        #expect(result.metrics.tokenUsage == 42)
        #expect(result.metrics.estimatedCloudCostUSD == 0.001)
        #expect(result.metrics.openRouterRequestedModelID == "test/model")
        #expect(result.metrics.openRouterReturnedModelID == "test/returned")
        #expect(result.metrics.openRouterProviderName == "TestProvider")
        #expect(result.metrics.openRouterAgentSelectionReason == "tools")
        #expect(result.metrics.openRouterAgentLogicalTurnCount == 2)
        #expect(result.metrics.openRouterAgentHTTPAttemptCount == 3)
        #expect(result.metrics.openRouterSchemaToolCallCount == 1)
        #expect(result.trace?.schemaToolCalls.first?.errorCode == .sessionBudgetExceeded)
    }

    @Test func failedAgentRepairDoesNotDoubleCountCurrentAttempt() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )

        let result = await TextToSQLEvalCaseRunner.run(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generator: RepairAgentFailureGenerator(),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .generationFailure)
        #expect(result.metrics.modelCallCount == 2)
        #expect(result.metrics.openRouterAgentHTTPAttemptCount == 2)
        #expect(result.metrics.openRouterSchemaToolCallCount == 1)
    }

    @Test func evalMetricsPreferTraceAgentTotals() {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.recent-orders",
            schemaFixture: "commerce",
            question: "Show the 10 most recent orders",
            expected: TextToSQLEvalExpectation(decision: .sql)
        )
        var metadata = OpenRouterGenerationMetadata(
            requestedModelID: "test/model",
            structuredOutputMode: .promptOnlyJSON,
            requestCount: 1,
            retryCount: 0
        )
        metadata.agentSelectionReason = "tools"
        metadata.agentHTTPAttemptCount = 1
        metadata.agentSchemaToolCallCount = 1
        let generation = SQLGenerationResult(
            sql: "SELECT id FROM public.orders LIMIT 100",
            explanation: "Lists orders.",
            assumptions: [],
            referencedTables: ["public.orders"],
            confidence: 0.8,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil,
            backendMetadata: metadata
        )

        let result = TextToSQLEvalScorer.score(
            evalCase: evalCase,
            schema: makeCommerceSchema(),
            generation: generation,
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model"),
            latencyMs: 12,
            trace: TextToSQLTrace(
                stages: [],
                modelCalls: 2,
                elapsedMs: 12,
                schemaToolCalls: [
                    Self.schemaToolTrace(callID: "initial-search"),
                    Self.schemaToolTrace(callID: "repair-search"),
                ]
            )
        )

        #expect(result.metrics.openRouterSchemaToolCallCount == 2)
        #expect(result.metrics.openRouterAgentHTTPAttemptCount == 2)
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

    @Test func staticSuiteValidationAllowsSQLCasesWithoutSemanticMetadata() throws {
        let schemaDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widen-validator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: schemaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: schemaDirectory) }

        try JSONEncoder().encode(makeCommerceSchema())
            .write(to: schemaDirectory.appendingPathComponent("commerce-schema.json"))

        let suite = TextToSQLEvalSuite(
            name: "Static only",
            version: "1",
            cases: [
                TextToSQLEvalCase(
                    id: "commerce.static-only",
                    schemaFixture: "commerce",
                    question: "List customer ids",
                    expected: TextToSQLEvalExpectation(
                        decision: .sql,
                        requiredTables: ["public.customers"],
                        requiredColumnBindings: ["public.customers.id"],
                        requiredOperations: [.limit],
                        goldenSQL: "SELECT c.id FROM public.customers AS c ORDER BY c.id LIMIT 100"
                    )
                )
            ]
        )

        try TextToSQLEvalSuiteValidator.validate(
            suite: suite,
            schemaDirectory: schemaDirectory
        )
        #expect(throws: TextToSQLEvalSuiteValidationError.self) {
            try TextToSQLEvalSuiteValidator.validate(
                suite: suite,
                schemaDirectory: schemaDirectory,
                requireSemanticExpectations: true
            )
        }
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

    private static func schemaToolTrace(callID: String) -> SchemaToolCallTrace {
        SchemaToolCallTrace(
            callID: callID,
            toolName: "search_schema",
            outcome: .success,
            latencyMs: 1,
            returnedObjectCount: 1,
            outputByteCount: 128,
            truncated: false,
            errorCode: nil,
            schemaFingerprintPrefix: "abcdef123456",
            cacheHit: false
        )
    }
}
