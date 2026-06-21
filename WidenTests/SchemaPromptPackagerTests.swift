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

    @Test func forcedPinnedTableSectionStaysWithinTinyBudget() {
        var columns = [
            column("large_status_events", "id", ordinal: 1),
            column(
                "large_status_events",
                "status",
                type: "text",
                ordinal: 2,
                valueConstraints: [
                    ColumnValueConstraint(
                        kind: .check,
                        values: (0..<20).map { "very_long_allowed_status_value_\($0)" },
                        expression:
                            "CHECK (status = ANY (ARRAY['very_long_allowed_status_value_0', 'very_long_allowed_status_value_1']))"
                    )
                ]
            ),
            column("large_status_events", "created_at", type: "timestamp with time zone", ordinal: 3),
        ]
        for index in 0..<20 {
            columns.append(
                column("large_status_events", "descriptive_payload_column_\(index)", type: "text", ordinal: 10 + index)
            )
        }
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [
                TableInfo(
                    schema: "public",
                    name: "large_status_events",
                    type: .baseTable,
                    columns: columns
                )
            ],
            foreignKeys: []
        )
        let context = SQLGenerationContext(
            mode: .followUp,
            currentSQL: "SELECT * FROM public.large_status_events",
            repairContext: nil
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "show the latest status events",
            context: context,
            databaseContext: "",
            maxCharacters: 500
        )

        #expect(package.text.count <= 500)
        #expect(!package.diagnostics.overflowedBudget)
        #expect(package.text.contains(#"TABLE "public"."large_status_events""#))
        #expect(package.pinnedTables.contains("public.large_status_events"))
    }

    @Test func quotedCurrentSQLRelationPinsCanonicalTableName() {
        let schema = makeQuotedSalesSchema(extraTables: 20)
        let context = SQLGenerationContext(
            mode: .followUp,
            currentSQL: #"SELECT id FROM "Sales Data"."Q1 Orders""#,
            repairContext: nil
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "show the same orders by status",
            context: context,
            databaseContext: "",
            maxCharacters: 350
        )

        #expect(package.text.contains(#"TABLE "Sales Data"."Q1 Orders""#))
        #expect(package.pinnedTables.contains("Sales Data.Q1 Orders"))
    }

    @Test func packagingDoesNotEmitDomainSpecificWinnerHints() {
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

        #expect(!package.text.contains("Winner relation:"))
        #expect(!package.text.contains("count non-null"))
        #expect(!package.text.contains(#"Should I define "most wins""#))
    }

    @Test func packagingDoesNotInferWinnerForeignKeysFromQuestionTerms() {
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

        #expect(!package.text.contains("Winner relation:"))
        #expect(!package.text.contains("count non-null"))
    }

    @Test func primaryTablesAreIncludedIncrementallyWhenFullSectionIsTooLarge() {
        let schema = makeIncrementalPrimarySchema()

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "order customer invoice product",
            context: SQLGenerationContext(),
            databaseContext: "",
            maxCharacters: 450
        )

        #expect(package.text.count <= 450)
        #expect(package.text.contains("Primary tables:"))
        #expect(!package.includedTables.isEmpty)
        #expect(package.includedTables.count < schema.tables.count)
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
                #"Column "tool_a_id" lives on "public"."preseason_match_batch", not "public"."preseason_match_evaluation""#
            ))
        #expect(
            package.text.contains(
                #"join "public"."preseason_match_evaluation"."batch_id" -> "public"."preseason_match_batch"."id""#
            ))
    }

    @Test func widePinnedRepairTableIsCompressedButKeepsRequiredColumns() {
        let schema = makeWideWinningToolSchema(extraTables: 30)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingColumn,
            sqlState: "42703",
            message:
                "Schema validation failed: column tool_id is not available from the referenced tables. Schema validation failed: column createdAt must be quoted as \"createdAt\" on public.preseason_match_evaluation.",
            columnName: "tool_id"
        )
        let context = SQLGenerationContext(
            mode: .repair,
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?",
            repairContext: SQLRepairContext(
                failedSQL:
                    "SELECT DISTINCT winner_id, tool_id FROM public.preseason_match_evaluation WHERE createdAt >= NOW() - INTERVAL '14 days' GROUP BY winner_id, tool_id",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["tool_id"],
                repairConstraints: [.forbiddenUnquotedIdentifier("createdAt")]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "what are tools that are getting the most wins in the last two weeks?",
            context: context,
            databaseContext: "",
            maxCharacters: 3_400
        )

        #expect(package.text.count <= 3_400)
        #expect(package.text.contains(#"TABLE "public"."preseason_match_evaluation""#))
        #expect(package.text.contains(#""winner_id" uuid NOT NULL"#))
        #expect(package.text.contains(#""createdAt" timestamp with time zone NOT NULL"#))
        #expect(package.text.contains(#"FK "winner_id" -> "public"."preseason_tool"."id""#))
        #expect(package.text.contains(#"TABLE "public"."preseason_tool""#))
        #expect(package.text.contains(#""name" character varying NOT NULL"#))
        #expect(!package.text.contains("raw_response"))
        #expect(!package.text.contains("appendix_json"))
        #expect(!package.text.contains("system_prompt_snapshot"))
    }

    @Test func relationshipHintsAreCappedAndNeverForceOverflow() {
        let schema = makeWideWinningToolSchema(extraTables: 50)
        let diagnostic = DatabaseDiagnostic(
            kind: .missingColumn,
            sqlState: "42703",
            message: "Schema validation failed: column tool_id is not available from the referenced tables.",
            columnName: "tool_id"
        )
        let context = SQLGenerationContext(
            mode: .repair,
            originalQuestion: "what are tools that are getting the most wins in the last two weeks?",
            repairContext: SQLRepairContext(
                failedSQL: "SELECT tool_id FROM public.preseason_match_evaluation",
                diagnostic: diagnostic,
                forbiddenIdentifiers: ["tool_id"]
            )
        )

        let package = SchemaPromptPackager.package(
            schema: schema,
            question: "what are tools that are getting the most wins in the last two weeks?",
            context: context,
            databaseContext: "",
            maxCharacters: 1_700
        )

        #expect(package.text.count <= 1_700)
        #expect(package.text.contains(#"TABLE "public"."preseason_match_evaluation""#))
        #expect(package.text.contains(#""winner_id" uuid NOT NULL"#))
        #expect(package.diagnostics.compressionLevel != .full)
    }

    @Test func schemaDiscoverySearchFindsWinningToolTables() {
        let schema = makeWinningToolSchema(extraTables: 30)
        let tables = SchemaDiscoveryService.search(
            schema: schema,
            queries: ["winning tools last two weeks match evaluation winner_id createdAt"],
            limit: 5
        ).map(\.qualifiedName)

        #expect(tables.contains("public.preseason_match_evaluation"))
        #expect(tables.contains("public.preseason_tool"))
    }

    private func makeIncrementalPrimarySchema() -> DatabaseSchema {
        let tableNames = ["customers", "invoices", "orders", "products"]
        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: tableNames.map { name in
                TableInfo(
                    schema: "public",
                    name: name,
                    type: .baseTable,
                    columns: [
                        column(name, "id", ordinal: 1),
                        column(name, "name", type: "text", ordinal: 2),
                        column(name, "status", type: "text", ordinal: 3),
                        column(name, "created_at", type: "timestamp with time zone", ordinal: 4),
                        column(name, "description", type: "text", ordinal: 5),
                    ]
                )
            },
            foreignKeys: []
        )
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

    private func makeQuotedSalesSchema(extraTables: Int) -> DatabaseSchema {
        var tables = [
            TableInfo(
                schema: "Sales Data",
                name: "Q1 Orders",
                type: .baseTable,
                columns: [
                    ColumnInfo(
                        tableSchema: "Sales Data",
                        tableName: "Q1 Orders",
                        name: "id",
                        dataType: "integer",
                        isNullable: false,
                        ordinalPosition: 1
                    ),
                    ColumnInfo(
                        tableSchema: "Sales Data",
                        tableName: "Q1 Orders",
                        name: "status",
                        dataType: "text",
                        isNullable: true,
                        ordinalPosition: 2
                    ),
                ]
            )
        ]
        for index in 0..<extraTables {
            tables.append(
                TableInfo(
                    schema: "public",
                    name: "unrelated_sales_table_\(index)",
                    type: .baseTable,
                    columns: [
                        ColumnInfo(
                            tableSchema: "public",
                            tableName: "unrelated_sales_table_\(index)",
                            name: "id",
                            dataType: "integer",
                            isNullable: false,
                            ordinalPosition: 1
                        )
                    ]
                ))
        }
        return DatabaseSchema(
            schemas: [SchemaInfo(name: "Sales Data"), SchemaInfo(name: "public")],
            tables: tables,
            foreignKeys: []
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
                        ordinal: 4,
                        valueConstraints: [
                            ColumnValueConstraint(
                                kind: .enumValues,
                                values: ["tool_a", "tool_b", "tie"]
                            )
                        ]
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

    private func makeWideWinningToolSchema(extraTables: Int) -> DatabaseSchema {
        var schema = makeWinningToolSchema(extraTables: extraTables)
        guard let index = schema.tables.firstIndex(where: {
            $0.qualifiedName == "public.preseason_match_evaluation"
        }) else { return schema }
        let extraColumns = [
            ("raw_response", "text"),
            ("appendix_json", "jsonb"),
            ("appendix_raw", "text"),
            ("system_prompt_snapshot", "text"),
            ("rendered_user_prompt", "text"),
        ] + (0..<30).map { ("debug_payload_\($0)", "jsonb") }
        for (offset, extraColumn) in extraColumns.enumerated() {
            schema.tables[index].columns.append(
                column(
                    "preseason_match_evaluation",
                    extraColumn.0,
                    type: extraColumn.1,
                    ordinal: 100 + offset
                ))
        }
        return schema
    }

    private func column(
        _ tableName: String,
        _ name: String,
        type: String = "uuid",
        ordinal: Int,
        valueConstraints: [ColumnValueConstraint]? = nil
    ) -> ColumnInfo {
        ColumnInfo(
            tableSchema: "public",
            tableName: tableName,
            name: name,
            dataType: type,
            isNullable: false,
            ordinalPosition: ordinal,
            valueConstraints: valueConstraints
        )
    }
}
