import Foundation

/// Builds the instructions and prompt text for SQL generation. Pure functions,
/// so output is unit-testable and identical for every generator backend.
public enum SQLPromptBuilder {
    public static let maxDatabaseContextCharacters = 2_000

    /// System instructions for the model, with the app's safety rules.
    public static func instructions(defaultRowLimit: Int) -> String {
        """
        You are an expert PostgreSQL assistant inside a local Mac database GUI.

        Your task is to generate exactly one safe PostgreSQL statement for the user's question.

        Rules:
        - Generate PostgreSQL syntax only.
        - Use PostgreSQL date and time syntax: CURRENT_DATE, CURRENT_TIMESTAMP, NOW(), and quoted intervals like INTERVAL '7 days'. Never use MySQL functions such as CURDATE(), DATE_SUB(), or unquoted interval units like INTERVAL 7 DAY.
        - Generate a single SELECT, WITH ... SELECT, INSERT, UPDATE, or DELETE statement.
        - Only generate a write (INSERT, UPDATE, or DELETE) when the user clearly asks to add, change, or remove data; otherwise generate a read query.
        - Prefer a WHERE clause to scope UPDATE and DELETE statements; an UPDATE or DELETE without a WHERE affects every row in the table.
        - You may use RETURNING to show the affected rows.
        - Do not put INSERT, UPDATE, or DELETE inside a WITH/CTE; write a plain INSERT, UPDATE, or DELETE statement.
        - Never generate MERGE, ALTER, DROP, CREATE, TRUNCATE, GRANT, REVOKE, CALL, COPY, EXECUTE, PREPARE, VACUUM, ANALYZE, REINDEX, REFRESH, RESET, BEGIN, COMMIT, or ROLLBACK.
        - Do not generate standalone SET or DO statements. SET may appear only as an UPDATE clause; DO may appear only as part of ON CONFLICT DO UPDATE or ON CONFLICT DO NOTHING.
        - Do not include semicolons.
        - Do not generate multiple statements.
        - Do not use tables or columns that are not present in the provided schema.
        - Use schema-qualified table names exactly as shown in the schema, for example public.orders or "Sales Data"."Q1.Orders".
        - Prefer clear explicit joins.
        - Prefer readable column aliases.
        - For read queries, include LIMIT unless the query is an aggregate query that naturally returns a small number of rows.
        - Use a default LIMIT of \(defaultRowLimit).
        - For date or time periods, use actual date/timestamp columns from the relevant table (for example created_at, updated_at, scheduled_for, or occurred_at). Do not group or partition by CURRENT_DATE itself. If no date/timestamp column exists for the requested period, set needsClarification to true.
        - For average counts per day/week/month, first count rows per period in a subquery or CTE, then AVG those counts in the outer SELECT. Never put a window function or another aggregate directly inside AVG, SUM, MIN, MAX, or COUNT.
        - For simple "per day" order/event averages, group by DATE_TRUNC('day', the timestamp column) or timestamp_column::date. State whether the average is across days with records unless the user asks to include zero-activity days.
        - If a Database context section is present, use it as user-provided guidance about relationships, business rules, data meaning, and preferred filters. The schema remains authoritative for available tables and columns.
        - The prompt is organized with XML-style sections such as <database_schema>, <conversation_context>, and <current_user_request>. Treat <ordered_chat_history> messages as a chronological back-and-forth chat transcript between the user and the assistant.
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
        var sections = [
            taggedSection(
                "database_schema",
                schemaSummary(schema, maxCharacters: maxSchemaCharacters)
            )
        ]
        if let databaseContextSection = databaseContextSection(databaseContext) {
            sections.append(taggedSection("database_context", databaseContextSection))
        }
        if let contextSection = contextSection(context) {
            sections.append(contextSection)
        }
        sections.append(
            taggedSection(
                "current_user_request",
                "User question: \(question)"
            ))
        return sections.joined(separator: "\n\n")
    }

    /// Renders the conversation context with tight per-item budgets. The
    /// transcript is ordered so the model can follow the back-and-forth chat
    /// without treating the current request as an isolated question.
    static func contextSection(_ context: SQLGenerationContext) -> String? {
        guard !context.isEmpty else { return nil }
        var lines = [
            "<conversation_context>",
            "This is an ongoing back-and-forth chat between the user and Widen.",
            "Messages are chronological. Use them to understand what the user has already asked, what responses or SQL were already shown, and what failed.",
            "The <current_user_request> section after this context is the request to answer now.",
        ]

        if let originalQuestion = context.originalQuestion
            ?? context.conversationMessages.first(where: { $0.role == .user })?.text
            ?? context.recentQuestions.first
        {
            lines.append(taggedCDATASection("original_user_question", originalQuestion))
        }

        let orderedMessages = context.conversationMessages.isEmpty
            ? context.recentQuestions.suffix(3).map {
                SQLConversationMessage(role: .user, text: $0)
            }
            : context.conversationMessages
        if !orderedMessages.isEmpty {
            lines.append("<ordered_chat_history>")
            for (index, message) in orderedMessages.enumerated() {
                let text = truncated(message.text, to: 700)
                lines.append(
                    taggedCDATASection(
                        #"message index="\#(index + 1)" role="\#(message.role.rawValue)""#,
                        text
                    ))
            }
            lines.append("</ordered_chat_history>")
        }

        if let sql = context.currentSQL,
            !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            lines.append(taggedCDATASection("current_sql_on_screen", truncated(sql, to: 700)))
        }
        if let error = context.lastRunError,
            !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            lines.append(taggedCDATASection("last_run_error", truncated(error, to: 300)))
        }
        if let hint = repairHint(for: context) {
            lines.append(taggedCDATASection("repair_requirement", hint))
        }
        lines.append("</conversation_context>")
        return lines.joined(separator: "\n")
    }

    static func repairHint(for context: SQLGenerationContext) -> String? {
        let sql = context.currentSQL ?? ""
        let error = context.lastRunError ?? ""
        let combined = "\(sql)\n\(error)"
        var requirements: [String] = []
        if combined.localizedCaseInsensitiveContains("repeated the exact same SQL") {
            requirements.append(
                "Do not return the current SQL again. Produce a structurally different query that fixes the database error, or set needsClarification to true if the schema does not make the right fix clear."
            )
        }
        if combined.localizedCaseInsensitiveContains(
            "aggregate function calls cannot contain window function calls"
        )
            || SQLSafetyValidator.containsWindowFunctionInsideAggregate(
                SQLSafetyValidator.strip(sql).text
            )
        {
            requirements.append(
                "PostgreSQL rejected an aggregate wrapped around a window function. Do not use OVER inside AVG, SUM, MIN, MAX, or COUNT. For average counts over time, use a CTE like WITH counts AS (SELECT DATE_TRUNC('day', created_at) AS period, COUNT(*) AS row_count FROM table GROUP BY 1) SELECT AVG(row_count) FROM counts."
            )
        }
        if let missingColumnHint = missingColumnRepairHint(for: combined) {
            requirements.append(missingColumnHint)
        }
        return requirements.isEmpty ? nil : requirements.joined(separator: " ")
    }

    private static func missingColumnRepairHint(for text: String) -> String? {
        let lowercased = text.lowercased()
        guard lowercased.contains("column"), lowercased.contains("does not exist") else {
            return nil
        }

        let candidates = missingColumnCandidates(in: text)

        if candidates.isEmpty {
            return
                "PostgreSQL says a column is missing. Use only columns present in the schema. If no available column clearly matches the user's intent, set needsClarification to true and ask which entity or relationship they mean."
        }

        return
            "PostgreSQL says a column is missing. Candidate columns from the database hint: \(candidates.joined(separator: ", ")). Use a candidate only if it matches the user's intent; otherwise set needsClarification to true and ask which entity or relationship they mean."
    }

    static func missingColumnClarificationQuestion(for text: String) -> String? {
        let lowercased = text.lowercased()
        guard lowercased.contains("column"), lowercased.contains("does not exist") else {
            return nil
        }

        let missingColumn = quotedIdentifiers(in: text).first ?? "the missing column"
        let candidates = missingColumnCandidates(in: text)
        switch candidates.count {
        case 0:
            return
                "I'm having trouble identifying which schema column should replace \"\(missingColumn)\". Can you clarify which entity or relationship you mean?"
        case 1:
            return
                "I'm having trouble confirming whether \"\(candidates[0])\" should replace \"\(missingColumn)\". Can you clarify which entity or relationship you mean?"
        default:
            let options = candidates.dropLast().joined(separator: "\", \"")
            return
                "I'm having trouble identifying which column should replace \"\(missingColumn)\". Did you mean \"\(options)\", or \"\(candidates.last!)\", or something else?"
        }
    }

    private static func missingColumnCandidates(in text: String) -> [String] {
        quotedIdentifiers(in: text)
            .filter { $0.contains(".") }
            .reduce(into: [String]()) { result, identifier in
                if !result.contains(identifier) {
                    result.append(identifier)
                }
            }
    }

    private static func quotedIdentifiers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)""#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func taggedSection(_ tag: String, _ content: String) -> String {
        """
        <\(tag)>
        \(content)
        </\(tag)>
        """
    }

    private static func taggedCDATASection(_ tag: String, _ content: String) -> String {
        """
        <\(tag)>
        <![CDATA[
        \(cdataEscaped(content))
        ]]>
        </\(closingTagName(tag))>
        """
    }

    private static func closingTagName(_ tag: String) -> String {
        tag.split(separator: " ").first.map(String.init) ?? tag
    }

    private static func cdataEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
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
