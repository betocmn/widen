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
}
