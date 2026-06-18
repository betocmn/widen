import Foundation
import Testing

@testable import WidenKit

@Suite("Schema prompt packager")
struct SchemaPromptPackagerTests {
    @Test func missingMatchBatchRanksPreseasonMatchBatchFirst() {
        let schema = makePreseasonSchema(extraTables: 20)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingRelation,
            sqlState: "42P01",
            message: #"relation "public.match_batch" does not exist"#,
            tableName: "match_batch"
        )

        let ranked = SchemaRelevanceRanker.rank(
            schema: schema,
            input: SchemaRankingInput(
                question: "what are tools getting the most wins in the last two weeks?",
                currentSQL: "SELECT * FROM public.match_batch",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["public.match_batch"]
            )
        )

        #expect(ranked.first?.table.qualifiedName == "public.preseason_match_batch")
    }

    @Test func temporalRequestIncludesForeignKeyAdjacentBenchmarkRun() {
        let schema = makePreseasonSchema(extraTables: 15)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingRelation,
            sqlState: "42P01",
            message: #"relation "public.match_batch" does not exist"#,
            tableName: "match_batch"
        )
        let context = SQLGenerationContext(
            mode: .repair,
            repairContext: SQLRepairContext(
                failedSQL: "SELECT * FROM public.match_batch",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["public.match_batch"]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "what are tools getting the most wins in the last two weeks?",
            context: context,
            databaseContext: "",
            maxCharacters: 1_800
        )

        #expect(package.text.contains(#"TABLE "public"."preseason_match_batch""#))
        #expect(package.text.contains(#"TABLE "public"."preseason_benchmark_run""#))
        #expect(package.text.contains("scheduled_for"))
    }

    @Test func pinnedReplacementSurvivesTinyBudget() {
        let schema = makePreseasonSchema(extraTables: 50)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingRelation,
            sqlState: "42P01",
            message: #"relation "public.match_batch" does not exist"#,
            tableName: "match_batch"
        )
        let context = SQLGenerationContext(
            mode: .repair,
            repairContext: SQLRepairContext(
                failedSQL: "SELECT * FROM public.match_batch",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["public.match_batch"]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "most wins last two weeks",
            context: context,
            databaseContext: "",
            maxCharacters: 250
        )

        #expect(package.text.contains(#"TABLE "public"."preseason_match_batch""#))
        #expect(package.pinnedTables.contains("public.preseason_match_batch"))
    }

    @Test func winningToolRelationshipHintUsesOriginalQuestionAndPinsToolTable() {
        let schema = makeWinningToolSchema(extraTables: 12)
        let context = SQLGenerationContext(
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?",
            conversationMessages: [
                SQLConversationMessage(
                    role: .user,
                    text: "what are tools that are getting the most wins in the last two weeks?"
                )
            ]
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "Probably preseason_tool primary key",
            context: context,
            databaseContext: "",
            maxCharacters: 3_500
        )

        #expect(package.text.contains("Relationship hints:"))
        #expect(package.text.contains("For winning-tool questions"))
        #expect(
            package.text.contains(
                #""public"."preseason_match_evaluation"."winner_id" joins to "public"."preseason_tool"."id""#
            ))
        #expect(package.text.contains(#"TABLE "public"."preseason_tool""#))
        #expect(package.pinnedTables.contains("public.preseason_tool"))
    }

    @Test func winningToolRelationshipHintIgnoresNonToolWinnerRelations() {
        let schema = makeWinningToolSchema(extraTables: 12, includeNonToolWinnerRelation: true)
        let context = SQLGenerationContext(
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?"
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "Probably preseason_tool primary key",
            context: context,
            databaseContext: "",
            maxCharacters: 3_500
        )

        #expect(
            package.text.contains(
                #""public"."preseason_match_evaluation"."winner_id" joins to "public"."preseason_tool"."id""#
            ))
        #expect(
            !package.text.contains(
                #""public"."preseason_match_evaluation"."winner_scorekeeper_id" joins to "public"."preseason_scorekeeper"."id""#
            ))
    }

    @Test func missingColumnRelationshipHintShowsJoinToColumnOwner() {
        let schema = makeWinningToolSchema(extraTables: 8)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingColumn,
            sqlState: "42703",
            message: "column tool_a_id is not available from the referenced tables",
            columnName: "tool_a_id"
        )
        let context = SQLGenerationContext(
            mode: .repair,
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?",
            repairContext: SQLRepairContext(
                failedSQL: "SELECT tool_a_id FROM public.preseason_match_evaluation",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["tool_a_id"]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "what are tools that are getting the most wins in the last two weeks?",
            context: context,
            databaseContext: "",
            maxCharacters: 4_500
        )

        #expect(
            package.text.contains(
                #"Column "tool_a_id" is on "public"."preseason_match_batch", not "public"."preseason_match_evaluation""#
            ))
        #expect(
            package.text.contains(
                #"join "public"."preseason_match_evaluation"."batch_id" -> "public"."preseason_match_batch"."id""#
            ))
    }

    private func makePreseasonSchema(extraTables: Int) -> DatabaseSchema {
        var tables = [
            TableInfo(
                schema: "public",
                name: "preseason_benchmark_run",
                type: .baseTable,
                columns: [
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_benchmark_run",
                        name: "id",
                        dataType: "uuid",
                        isNullable: false,
                        ordinalPosition: 1
                    ),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_benchmark_run",
                        name: "scheduled_for",
                        dataType: "timestamp with time zone",
                        isNullable: true,
                        ordinalPosition: 2
                    ),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "preseason_match_batch",
                type: .baseTable,
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
                        name: "benchmark_run_id",
                        dataType: "uuid",
                        isNullable: true,
                        ordinalPosition: 2
                    ),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_match_batch",
                        name: "tool_a_id",
                        dataType: "uuid",
                        isNullable: false,
                        ordinalPosition: 3
                    ),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_match_batch",
                        name: "tool_b_id",
                        dataType: "uuid",
                        isNullable: false,
                        ordinalPosition: 4
                    ),
                    ColumnInfo(
                        tableSchema: "public",
                        tableName: "preseason_match_batch",
                        name: "completed_evaluations",
                        dataType: "integer",
                        isNullable: false,
                        ordinalPosition: 5
                    ),
                ]
            ),
        ]

        for index in 0..<extraTables {
            tables.append(
                TableInfo(
                    schema: "public",
                    name: "unrelated_table_\(index)",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "unrelated_table_\(index)",
                            name: "id",
                            dataType: "uuid",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                ))
        }

        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: tables,
            foreignKeys: [
                ForeignKeyInfo(
                    constraintName: "match_batch_run_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_batch",
                    sourceColumn: "benchmark_run_id",
                    targetSchema: "public",
                    targetTable: "preseason_benchmark_run",
                    targetColumn: "id"
                )
            ]
        )
    }

    private func makeWinningToolSchema(
        extraTables: Int,
        includeNonToolWinnerRelation: Bool = false
    ) -> DatabaseSchema {
        var tables = [
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
                        "winner_decision",
                        type: "user-defined",
                        ordinal: 4
                    ),
                    column(
                        "preseason_match_evaluation",
                        "createdAt",
                        type: "timestamp with time zone",
                        ordinal: 5
                    ),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "preseason_match_batch",
                type: .baseTable,
                columns: [
                    column("preseason_match_batch", "id", ordinal: 1),
                    column("preseason_match_batch", "tool_a_id", ordinal: 2),
                    column("preseason_match_batch", "tool_b_id", ordinal: 3),
                ]
            ),
            TableInfo(
                schema: "public",
                name: "preseason_tool",
                type: .baseTable,
                columns: [
                    column("preseason_tool", "id", ordinal: 1),
                    column("preseason_tool", "name", type: "character varying", ordinal: 2),
                    column("preseason_tool", "slug", type: "character varying", ordinal: 3),
                ]
            ),
        ]

        var foreignKeys = [
            ForeignKeyInfo(
                constraintName: "match_evaluation_batch_fkey",
                sourceSchema: "public",
                sourceTable: "preseason_match_evaluation",
                sourceColumn: "batch_id",
                targetSchema: "public",
                targetTable: "preseason_match_batch",
                targetColumn: "id"
            ),
            ForeignKeyInfo(
                constraintName: "match_evaluation_winner_fkey",
                sourceSchema: "public",
                sourceTable: "preseason_match_evaluation",
                sourceColumn: "winner_id",
                targetSchema: "public",
                targetTable: "preseason_tool",
                targetColumn: "id"
            ),
            ForeignKeyInfo(
                constraintName: "match_batch_tool_a_fkey",
                sourceSchema: "public",
                sourceTable: "preseason_match_batch",
                sourceColumn: "tool_a_id",
                targetSchema: "public",
                targetTable: "preseason_tool",
                targetColumn: "id"
            ),
            ForeignKeyInfo(
                constraintName: "match_batch_tool_b_fkey",
                sourceSchema: "public",
                sourceTable: "preseason_match_batch",
                sourceColumn: "tool_b_id",
                targetSchema: "public",
                targetTable: "preseason_tool",
                targetColumn: "id"
            ),
        ]

        if includeNonToolWinnerRelation {
            tables[0].columns.append(
                column("preseason_match_evaluation", "winner_scorekeeper_id", ordinal: 6)
            )
            tables.append(
                TableInfo(
                    schema: "public",
                    name: "preseason_scorekeeper",
                    type: .baseTable,
                    columns: [
                        column("preseason_scorekeeper", "id", ordinal: 1),
                        column(
                            "preseason_scorekeeper",
                            "name",
                            type: "character varying",
                            ordinal: 2
                        ),
                    ]
                ))
            foreignKeys.append(
                ForeignKeyInfo(
                    constraintName: "match_evaluation_scorekeeper_fkey",
                    sourceSchema: "public",
                    sourceTable: "preseason_match_evaluation",
                    sourceColumn: "winner_scorekeeper_id",
                    targetSchema: "public",
                    targetTable: "preseason_scorekeeper",
                    targetColumn: "id"
                ))
        }

        for index in 0..<extraTables {
            tables.append(
                TableInfo(
                    schema: "public",
                    name: "unrelated_tool_table_\(index)",
                    type: .baseTable,
                    columns: [
                        column("unrelated_tool_table_\(index)", "id", ordinal: 1)
                    ]
                ))
        }

        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: tables,
            foreignKeys: foreignKeys
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
