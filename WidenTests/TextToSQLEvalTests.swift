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
        var error: AppError

        func generateSQL(
            question: String,
            schema: DatabaseSchema,
            context: SQLGenerationContext,
            config: SQLGenerationConfig
        ) async throws -> SQLGenerationResult {
            throw error
        }
    }

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
        #expect(result.metrics.requiredTableCoverage == 1)
        #expect(result.metrics.requiredColumnBindingCoverage == 1)
    }

    @Test func scoresClarificationAsPassed() async {
        let evalCase = TextToSQLEvalCase(
            id: "commerce.best-customers",
            schemaFixture: "commerce",
            question: "Who are our best customers?",
            expected: TextToSQLEvalExpectation(decision: .clarify)
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
            expected: TextToSQLEvalExpectation(decision: .clarify)
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

    @Test func evalRunnerKeepsInitialSQLWhenGroundingWouldAskClarification() async {
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
            options: TextToSQLEvalRunOptions(backend: .local)
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
        #expect(
            result.metrics.forbiddenBindingViolations
                == ["public.preseason_match_evaluation.tool_a_id"])
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
            generator: ThrowingGenerator(error: .modelUnavailable("No model.")),
            options: TextToSQLEvalRunOptions(backend: .local)
        )

        #expect(result.status == .backendUnavailable)
        #expect(result.metrics.backendAvailable == false)
        #expect(result.metrics.transportSuccess == false)
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
                error: .modelGenerationFailed("The cloud model returned an unparseable response.")
            ),
            options: TextToSQLEvalRunOptions(backend: .cloud, model: "test/model")
        )

        #expect(result.status == .parseFailure)
        #expect(result.metrics.backendAvailable == true)
        #expect(result.metrics.transportSuccess == true)
        #expect(result.metrics.structuredResponseParsed == false)
        #expect(result.metrics.requiredTableCoverage == 0)
        #expect(result.metrics.requiredColumnBindingCoverage == 0)
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
                error: .modelGenerationFailed(
                    "The local model failed to decode structured output."
                )
            ),
            options: TextToSQLEvalRunOptions(backend: .local)
        )

        #expect(result.status == .parseFailure)
        #expect(result.metrics.transportSuccess)
        #expect(result.metrics.structuredResponseParsed == false)
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
        #expect(result.metrics.requiredTableCoverage == 0)
        #expect(result.metrics.requiredColumnBindingCoverage == 0)
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

    @Test func starProjectionFlagsForbiddenColumns() {
        let evalCase = TextToSQLEvalCase(
            id: "preseason.forbidden-star",
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

            #expect(result.status == .wrongSchemaObjects)
            #expect(
                result.metrics.forbiddenBindingViolations == [
                    "public.preseason_match_evaluation.tool_a_id",
                    "public.preseason_match_evaluation.tool_b_id",
                ])
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
                        column("preseason_match_evaluation", "tool_a_id", ordinal: 2),
                        column("preseason_match_evaluation", "tool_b_id", ordinal: 3),
                        column("preseason_match_evaluation", "winner_id", ordinal: 4),
                    ])
            ],
            foreignKeys: []
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
