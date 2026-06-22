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

    private func makeCommerceSchema() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public", name: "customers", type: .baseTable,
                    columns: [
                        column("customers", "id", type: "integer", ordinal: 1),
                        column("customers", "email", type: "text", ordinal: 2),
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
                        column("preseason_match_evaluation", "winner_id", ordinal: 3),
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
