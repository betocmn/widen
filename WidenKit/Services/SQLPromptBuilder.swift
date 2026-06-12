import Foundation

/// Builds the instructions and prompt text for SQL generation. Pure functions,
/// so output is unit-testable and identical for every generator backend.
public enum SQLPromptBuilder {
    public static let maxDatabaseContextCharacters = 2_000

    /// System instructions for the model, with the app's safety rules.
    public static func instructions(defaultRowLimit: Int) -> String {
        """
        You are an expert PostgreSQL assistant inside a local Mac database GUI.

        Your task is to generate exactly one safe PostgreSQL read-only query for the user's question.

        Rules:
        - Generate PostgreSQL syntax only.
        - Use PostgreSQL date and time syntax: CURRENT_DATE, CURRENT_TIMESTAMP, NOW(), and quoted intervals like INTERVAL '7 days'. Never use MySQL functions such as CURDATE(), DATE_SUB(), or unquoted interval units like INTERVAL 7 DAY.
        - Generate SELECT or WITH ... SELECT only.
        - Never generate INSERT, UPDATE, DELETE, MERGE, ALTER, DROP, CREATE, TRUNCATE, GRANT, REVOKE, CALL, DO, COPY, EXECUTE, PREPARE, VACUUM, ANALYZE, REINDEX, REFRESH, SET, RESET, BEGIN, COMMIT, or ROLLBACK.
        - Do not include semicolons.
        - Do not generate multiple statements.
        - Do not use tables or columns that are not present in the provided schema.
        - Prefer clear explicit joins.
        - Prefer readable column aliases.
        - Include LIMIT unless the query is an aggregate query that naturally returns a small number of rows.
        - Use a default LIMIT of \(defaultRowLimit).
        - If a Database context section is present, use it as user-provided guidance about relationships, business rules, data meaning, and preferred filters. The schema remains authoritative for available tables and columns.
        - The prompt may include conversation context: earlier questions, the current SQL, and the error of its last run. Treat the user's question as a follow-up to that context — adjust the current SQL when asked, and when an error is shown, produce a corrected version of that query that still answers the earlier questions.
        - If the request is ambiguous, make the safest reasonable assumption and include it in assumptions.
        - If the request cannot be answered from the schema, set needsClarification to true and ask a concise clarification question.
        - Output only the requested structured result.
        """
    }

    /// The per-question prompt: schema summary, compact conversation context
    /// (when present), and the user's question.
    public static func prompt(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext = SQLGenerationContext(),
        databaseContext: String? = nil,
        maxSchemaCharacters: Int = 8_000
    ) -> String {
        var sections = [schemaSummary(schema, maxCharacters: maxSchemaCharacters)]
        if let databaseContextSection = databaseContextSection(databaseContext) {
            sections.append(databaseContextSection)
        }
        if let contextSection = contextSection(context) {
            sections.append(contextSection)
        }
        sections.append("User question: \(question)")
        return sections.joined(separator: "\n\n")
    }

    /// Renders the conversation context with tight per-item budgets — the
    /// on-device model's context window is small, so follow-ups get the
    /// minimum they need: a few earlier questions, the SQL on screen, and
    /// the last error.
    static func contextSection(_ context: SQLGenerationContext) -> String? {
        guard !context.isEmpty else { return nil }
        var lines = ["Conversation context:"]
        for question in context.recentQuestions.suffix(3) {
            lines.append("- Earlier question: \(truncated(question, to: 200))")
        }
        if let sql = context.currentSQL,
            !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            lines.append("- Current SQL on screen:\n\(truncated(sql, to: 700))")
        }
        if let error = context.lastRunError,
            !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            lines.append("- The last run of that SQL failed with: \(truncated(error, to: 300))")
        }
        return lines.joined(separator: "\n")
    }

    /// Renders user-authored database guidance from settings. This is capped
    /// separately from the schema budget so saved notes cannot consume the
    /// full local model context window.
    static func databaseContextSection(
        _ databaseContext: String?,
        maxCharacters: Int = maxDatabaseContextCharacters
    ) -> String? {
        guard let databaseContext else { return nil }
        let trimmed = databaseContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "Database context:\n\(truncated(trimmed, to: maxCharacters))"
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
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
