import Foundation

/// Builds the instructions and prompt text for SQL generation. Pure functions,
/// so output is unit-testable and identical for every generator backend.
public enum SQLPromptBuilder {
    /// System instructions for the model, with the app's safety rules.
    public static func instructions(defaultRowLimit: Int) -> String {
        """
        You are an expert PostgreSQL assistant inside a local Mac database GUI.

        Your task is to generate exactly one safe PostgreSQL read-only query for the user's question.

        Rules:
        - Generate PostgreSQL syntax only.
        - Generate SELECT or WITH ... SELECT only.
        - Never generate INSERT, UPDATE, DELETE, MERGE, ALTER, DROP, CREATE, TRUNCATE, GRANT, REVOKE, CALL, DO, COPY, EXECUTE, PREPARE, VACUUM, ANALYZE, REINDEX, REFRESH, SET, RESET, BEGIN, COMMIT, or ROLLBACK.
        - Do not include semicolons.
        - Do not generate multiple statements.
        - Do not use tables or columns that are not present in the provided schema.
        - Prefer clear explicit joins.
        - Prefer readable column aliases.
        - Include LIMIT unless the query is an aggregate query that naturally returns a small number of rows.
        - Use a default LIMIT of \(defaultRowLimit).
        - If the request is ambiguous, make the safest reasonable assumption and include it in assumptions.
        - If the request cannot be answered from the schema, set needsClarification to true and ask a concise clarification question.
        - Output only the requested structured result.
        """
    }

    /// The per-question prompt: schema summary plus the user's question.
    public static func prompt(
        question: String,
        schema: DatabaseSchema,
        maxSchemaCharacters: Int = 8_000
    ) -> String {
        """
        \(schemaSummary(schema, maxCharacters: maxSchemaCharacters))

        User question: \(question)
        """
    }

    /// Renders the schema in the concise text format the model is prompted
    /// with. Whole tables are dropped once the character budget is exceeded;
    /// a truncation note tells the model (and the UI) that the schema is
    /// incomplete.
    public static func schemaSummary(
        _ schema: DatabaseSchema,
        maxCharacters: Int = 8_000
    ) -> String {
        var sections: [String] = ["Database schema:"]
        var used = sections[0].count
        var includedTables: Set<String> = []
        var omittedTables = 0

        for table in schema.tables {
            var lines = ["Table \(qualifiedIdentifier(schema: table.schema, name: table.name))"]
            for column in table.columns {
                let nullability = column.isNullable ? "" : " not null"
                lines.append(
                    "- \(quotedIdentifier(column.name)) \(column.dataType.lowercased())\(nullability)"
                )
            }
            let section = lines.joined(separator: "\n")
            if used + section.count + 2 > maxCharacters {
                omittedTables += 1
                continue
            }
            used += section.count + 2
            sections.append(section)
            includedTables.insert(table.id)
        }

        // Only foreign keys between included tables are relevant to the model.
        let fkLines = schema.foreignKeys
            .filter {
                includedTables.contains("\($0.sourceSchema).\($0.sourceTable)")
                    && includedTables.contains("\($0.targetSchema).\($0.targetTable)")
            }
            .map { foreignKeyLine($0) }
        if !fkLines.isEmpty {
            let section = (["Foreign keys:"] + fkLines).joined(separator: "\n")
            if used + section.count + 2 <= maxCharacters {
                sections.append(section)
            }
        }

        if omittedTables > 0 {
            sections.append("(Schema truncated: \(omittedTables) more tables omitted.)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// True when the schema does not fit the character budget — used by the
    /// UI to warn that generation sees an incomplete schema.
    public static func isSchemaTruncated(
        _ schema: DatabaseSchema,
        maxCharacters: Int = 8_000
    ) -> Bool {
        schemaSummary(schema, maxCharacters: maxCharacters)
            .contains("(Schema truncated:")
    }

    private static func foreignKeyLine(_ foreignKey: ForeignKeyInfo) -> String {
        let source = qualifiedIdentifier(
            schema: foreignKey.sourceSchema,
            name: foreignKey.sourceTable,
            column: foreignKey.sourceColumn
        )
        let target = qualifiedIdentifier(
            schema: foreignKey.targetSchema,
            name: foreignKey.targetTable,
            column: foreignKey.targetColumn
        )
        return "- \(source) -> \(target)"
    }

    private static func qualifiedIdentifier(
        schema: String,
        name: String,
        column: String? = nil
    ) -> String {
        var parts = [schema, name].map(quotedIdentifier)
        if let column {
            parts.append(quotedIdentifier(column))
        }
        return parts.joined(separator: ".")
    }

    private static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
