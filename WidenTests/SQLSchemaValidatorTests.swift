import Foundation
import Testing

@testable import WidenKit

@Suite("SQLSchemaValidator")
struct SQLSchemaValidatorTests {
    @Test func missingRelationIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT id FROM public.missing_table",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("table public.missing_table") == true)
    }

    @Test func missingQualifiedColumnIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT u.missing_column FROM public.users AS u",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("missing_column") == true)
    }

    @Test func cteNamesAreNotSchemaValidatedAsTables() {
        let result = SQLSchemaValidator.validate(
            sql: """
                WITH recent_users AS (
                  SELECT id FROM public.users
                )
                SELECT id FROM recent_users
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.users"])
    }

    @Test func aliasesQuotedIdentifiersAndOrderByAliasesResolve() {
        let result = SQLSchemaValidator.validate(
            sql: #"SELECT "u"."id" AS "User ID" FROM "public"."users" AS "u" ORDER BY "User ID""#,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.users"])
    }

    @Test func ambiguousUnqualifiedColumnIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT id
                FROM public.users
                JOIN public.orders ON users.id = orders.user_id
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("ambiguous") == true)
    }

    @Test func nestedSubqueryScopesDoNotFalseAmbiguateOuterColumn() {
        let result = SQLSchemaValidator.validate(
            sql: """
                SELECT id
                FROM public.users
                WHERE EXISTS (
                  SELECT 1
                  FROM public.orders
                  WHERE orders.user_id = users.id
                )
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(!result.hasDefiniteErrors)
        #expect(result.referencedTables == ["public.orders", "public.users"])
    }

    @Test func cteOutputColumnsAreValidated() {
        let result = SQLSchemaValidator.validate(
            sql: """
                WITH recent_users AS (
                  SELECT id FROM public.users
                )
                SELECT email FROM recent_users
                """,
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("email") == true)
    }

    @Test func unresolvedAliasStarIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT missing_alias.* FROM public.users AS u",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("missing_alias") == true)
    }

    @Test func commaSeparatedMissingRelationIsDefiniteError() {
        let result = SQLSchemaValidator.validate(
            sql: "SELECT u.id FROM public.users AS u, public.missing_table AS m",
            against: makeUsersOrdersSchema()
        )

        #expect(result.hasDefiniteErrors)
        #expect(result.errors.first?.contains("missing_table") == true)
    }

    @Test func generatedResultDerivesReferencedTables() {
        let generation = SQLGenerationResult(
            sql: "SELECT u.id FROM public.users AS u",
            explanation: "Lists users.",
            assumptions: [],
            referencedTables: ["public.fake"],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "show users",
            schema: makeUsersOrdersSchema(),
            databaseContext: ""
        )

        #expect(enriched.referencedTables == ["public.users"])
    }

    @Test func undefinedWinsMetricAsksForClarification() {
        let generation = SQLGenerationResult(
            sql: "SELECT tool_a_id, COUNT(*) FROM public.preseason_match_batch GROUP BY tool_a_id",
            explanation: "Counts tool A appearances.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "what tools have the most wins?",
            schema: makePreseasonSchemaWithoutWinner(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.sql.isEmpty)
        #expect(enriched.clarificationQuestion?.contains("which tool won") == true)
    }

    @Test func genericResultStatusAndScoreDoNotDefineWins() {
        let generation = SQLGenerationResult(
            sql: "SELECT tool_a_id, COUNT(*) FROM public.preseason_match_batch GROUP BY tool_a_id",
            explanation: "Counts appearances.",
            assumptions: [],
            referencedTables: [],
            confidence: 1,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )

        let enriched = GeneratedSQLPostprocessor.enriched(
            generation,
            question: "what tools have the most wins?",
            schema: makePreseasonSchemaWithGenericOutcomeFields(),
            databaseContext: ""
        )

        #expect(enriched.needsClarification)
        #expect(enriched.clarificationQuestion?.contains("which tool won") == true)
    }

    private func makeUsersOrdersSchema() -> DatabaseSchema {
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
                            name: "email",
                            dataType: "text",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                ),
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
                            name: "user_id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                    ]
                ),
            ],
            foreignKeys: []
        )
    }

    private func makePreseasonSchemaWithoutWinner() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "preseason_match_batch",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "tool_a_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "tool_b_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "completed_evaluations",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 3
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
    }

    private func makePreseasonSchemaWithGenericOutcomeFields() -> DatabaseSchema {
        DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "preseason_match_batch",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "tool_a_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "tool_b_id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 2
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "result",
                            dataType: "text",
                            isNullable: true,
                            ordinalPosition: 3
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "status",
                            dataType: "text",
                            isNullable: true,
                            ordinalPosition: 4
                        ),
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "preseason_match_batch",
                            name: "score",
                            dataType: "integer",
                            isNullable: true,
                            ordinalPosition: 5
                        ),
                    ]
                )
            ],
            foreignKeys: []
        )
    }
}
