import Foundation
import Testing

@testable import WidenKit

@Suite("SQLPromptBuilder")
struct SQLPromptBuilderTests {
    private func makeSampleSchema() -> DatabaseSchema {
        let users = TableInfo(
            schema: "public",
            name: "users",
            type: .baseTable,
            columns: [
                ColumnInfo(
                    tableSchema: "public", tableName: "users", name: "id",
                    dataType: "integer", isNullable: false, ordinalPosition: 1),
                ColumnInfo(
                    tableSchema: "public", tableName: "users", name: "email",
                    dataType: "text", isNullable: false, ordinalPosition: 2),
                ColumnInfo(
                    tableSchema: "public", tableName: "users", name: "name",
                    dataType: "text", isNullable: true, ordinalPosition: 3),
            ]
        )
        let orders = TableInfo(
            schema: "public",
            name: "orders",
            type: .baseTable,
            columns: [
                ColumnInfo(
                    tableSchema: "public", tableName: "orders", name: "id",
                    dataType: "integer", isNullable: false, ordinalPosition: 1),
                ColumnInfo(
                    tableSchema: "public", tableName: "orders", name: "user_id",
                    dataType: "integer", isNullable: false, ordinalPosition: 2),
                ColumnInfo(
                    tableSchema: "public", tableName: "orders", name: "total_cents",
                    dataType: "integer", isNullable: false, ordinalPosition: 3),
            ]
        )
        let fk = ForeignKeyInfo(
            constraintName: "orders_user_id_fkey",
            sourceSchema: "public", sourceTable: "orders", sourceColumn: "user_id",
            targetSchema: "public", targetTable: "users", targetColumn: "id"
        )
        return DatabaseSchema(
            schemas: [SchemaInfo(name: "public")],
            tables: [users, orders],
            foreignKeys: [fk]
        )
    }

    @Test func schemaSummaryIncludesTablesColumnsTypesAndForeignKeys() {
        let summary = SQLPromptBuilder.schemaSummary(makeSampleSchema())
        #expect(summary.contains("Table \"public\".\"users\""))
        #expect(summary.contains("- \"id\" integer not null"))
        #expect(summary.contains("- \"email\" text not null"))
        // Nullable columns get no suffix, matching the roadmap format.
        #expect(summary.contains("- \"name\" text\n"))
        #expect(summary.contains("Table \"public\".\"orders\""))
        #expect(summary.contains("Foreign keys:"))
        #expect(summary.contains("- \"public\".\"orders\".\"user_id\" -> \"public\".\"users\".\"id\""))
    }

    @Test func schemaSummaryQuotesPostgresIdentifiers() {
        let table = TableInfo(
            schema: "Sales Data",
            name: "Q1.Orders",
            type: .baseTable,
            columns: [
                ColumnInfo(
                    tableSchema: "Sales Data", tableName: "Q1.Orders", name: "select",
                    dataType: "text", isNullable: true, ordinalPosition: 1),
                ColumnInfo(
                    tableSchema: "Sales Data", tableName: "Q1.Orders", name: "quoted\"name",
                    dataType: "integer", isNullable: false, ordinalPosition: 2),
            ]
        )
        let schema = DatabaseSchema(
            schemas: [SchemaInfo(name: "Sales Data")],
            tables: [table],
            foreignKeys: []
        )

        let summary = SQLPromptBuilder.schemaSummary(schema)

        #expect(summary.contains("Table \"Sales Data\".\"Q1.Orders\""))
        #expect(summary.contains("- \"select\" text"))
        #expect(summary.contains("- \"quoted\"\"name\" integer not null"))
    }

    @Test func promptContainsQuestionAndSchema() {
        let prompt = SQLPromptBuilder.prompt(
            question: "Show me the 10 most recent users.",
            schema: makeSampleSchema()
        )
        #expect(prompt.contains("Database schema:"))
        #expect(prompt.contains("User question: Show me the 10 most recent users."))
    }

    @Test func instructionsContainSafetyRulesAndRowLimit() {
        let instructions = SQLPromptBuilder.instructions(defaultRowLimit: 250)
        #expect(instructions.contains("SELECT or WITH ... SELECT only"))
        #expect(instructions.contains("Use a default LIMIT of 250."))
        #expect(instructions.contains("Never generate INSERT, UPDATE, DELETE"))
        #expect(instructions.contains("Do not include semicolons."))
        #expect(instructions.contains("needsClarification"))
    }

    @Test func truncatesWholeTablesWhenOverBudget() {
        var schema = makeSampleSchema()
        // Add many wide tables so the budget is exceeded.
        for index in 0..<50 {
            let columns = (0..<30).map { col in
                ColumnInfo(
                    tableSchema: "public", tableName: "big_table_\(index)",
                    name: "column_with_a_long_name_\(col)",
                    dataType: "character varying", isNullable: true,
                    ordinalPosition: col + 1)
            }
            schema.tables.append(
                TableInfo(
                    schema: "public", name: "big_table_\(index)",
                    type: .baseTable, columns: columns))
        }

        let summary = SQLPromptBuilder.schemaSummary(schema, maxCharacters: 2_000)
        #expect(summary.count < 2_500)
        #expect(summary.contains("(Schema truncated:"))
        #expect(SQLPromptBuilder.isSchemaTruncated(schema, maxCharacters: 2_000))
        #expect(!SQLPromptBuilder.isSchemaTruncated(makeSampleSchema()))
    }

    @Test func excludedTablesDropTheirForeignKeys() {
        var schema = makeSampleSchema()
        // Make `users` enormous so it never fits in a small budget; its FK
        // (orders -> users) must then disappear from the summary too.
        let hugeColumns = (0..<200).map { col in
            ColumnInfo(
                tableSchema: "public", tableName: "users",
                name: "very_long_padding_column_name_number_\(col)",
                dataType: "character varying", isNullable: true,
                ordinalPosition: col + 10)
        }
        schema.tables[0].columns.append(contentsOf: hugeColumns)

        let summary = SQLPromptBuilder.schemaSummary(schema, maxCharacters: 400)
        #expect(!summary.contains("\"orders\".\"user_id\" ->"))
    }

    @Test func systemSchemasAreNotInTheSummary() {
        // Introspection already excludes pg_catalog/information_schema; the
        // summary must simply reflect the schema it is given.
        let summary = SQLPromptBuilder.schemaSummary(makeSampleSchema())
        #expect(!summary.contains("pg_catalog"))
        #expect(!summary.contains("information_schema"))
    }
}
