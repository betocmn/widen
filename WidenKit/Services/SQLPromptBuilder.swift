import Foundation

/// Builds the instructions and prompt text for SQL generation. Pure functions,
/// so output is unit-testable and identical for every generator backend.
public enum SQLPromptBuilder {
    public static let maxDatabaseContextCharacters = 2_000

    public struct PromptBundle: Equatable, Sendable {
        public var prompt: String
        public var schemaPackage: SchemaPromptPackage
    }

    /// System instructions for the model, with the app's safety rules.
    public static func instructions(defaultRowLimit: Int) -> String {
        """
        You are an expert PostgreSQL assistant inside a local Mac database GUI.

        Your task is to generate exactly one safe PostgreSQL statement for the user's question.

        Rules:
        - The provided database schema is a closed world. Every base relation in SQL MUST appear in <database_schema>. Every source column MUST appear under its base relation in <database_schema>.
        - Generate PostgreSQL syntax only.
        - Use PostgreSQL date and time syntax: CURRENT_DATE, CURRENT_TIMESTAMP, NOW(), DATE_TRUNC('day', timestamp_column), and quoted intervals like INTERVAL '7 days'. Never use MySQL functions such as CURDATE(), DATE_SUB(), DAY(timestamp_column), or unquoted interval units like INTERVAL 7 DAY.
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
        - For average counts per day/week/month, first count rows per period in a subquery or CTE, then AVG those counts in the outer SELECT. Never put a window function or another aggregate directly inside AVG, SUM, MIN, MAX, or COUNT. Never generate AVG(COUNT(...)), SUM(COUNT(...)), AVG(COUNT(*) / ...), or similar aggregate-inside-aggregate SQL.
        - For simple "per day" order/event averages, group by DATE_TRUNC('day', the timestamp column) or timestamp_column::date. State whether the average is across days with records unless the user asks to include zero-activity days.
        - If a Database context section is present, use it as user-provided guidance about relationships, business rules, data meaning, and preferred filters. The schema remains authoritative for available tables and columns.
        - The prompt is organized with XML-style sections such as <database_schema>, <conversation_context>, and <current_user_request>. Treat <ordered_chat_history> messages as a chronological back-and-forth chat transcript between the user and the assistant.
        - The prompt may include conversation context: earlier questions, the current SQL, and the error of its last run. Treat the user's question as a follow-up to that context — adjust the current SQL when asked, and when an error is shown, produce a corrected version of that query that still answers the earlier questions.
        - If the user answers affirmatively to a previous assistant clarification question, treat that answer as approval to use the proposed definition or constraint. Generate SQL for the original request with that approved interpretation; do not ask the same clarification question again.
        - If a required entity, metric, business meaning, relationship, or time interpretation is undefined by the Database context or provided schema, set needsClarification to true and ask a concise clarification question.
        - Assumptions may resolve presentation choices such as LIMIT, sort direction, or inclusive date boundaries. Assumptions MUST NOT invent schema objects, joins, metric definitions, status meanings, ownership rules, or other business semantics.
        - Business terms can have database-specific meanings. If the Database context and schema do not define the requested term, ask what column, condition, or table defines it. Do not infer it from a nearby count or status.
        - A plausible-looking query that does not answer the user's requested metric is incorrect.
        - If the request cannot be answered from the schema, set needsClarification to true and ask a concise clarification question.
        - Output only the requested structured result.
        """
    }

    /// Shorter system prompt for Apple's local Foundation Models. The local
    /// model has a small context window, and Widen performs deterministic
    /// schema validation and SQL safety validation before execution.
    public static func compactInstructions(defaultRowLimit: Int) -> String {
        """
        You generate one safe PostgreSQL statement for Widen.

        Rules:
        - The provided <database_schema> is closed-world. Use only listed base relations and columns.
        - Generate PostgreSQL only. Use NOW(), CURRENT_DATE, DATE_TRUNC, and INTERVAL '7 days'. Do not use MySQL date functions.
        - Return exactly one SELECT/WITH SELECT, or a write only when the user clearly asks to modify data.
        - Do not generate DDL, admin commands, transaction commands, COPY, CALL, EXECUTE, PREPARE, VACUUM, ANALYZE, REFRESH, SET, DO, MERGE, or multiple statements.
        - Do not include semicolons.
        - Use schema-qualified table names exactly as shown.
        - Prefer explicit joins and readable aliases.
        - For read queries, include LIMIT \(defaultRowLimit) unless the result is naturally small.
        - Use real date/timestamp columns for time windows. If none exists, set needsClarification true.
        - For average counts per period, count per period in a CTE/subquery, then average those counts outside.
        - Use <database_context> as business guidance when present. Schema remains authoritative.
        - In repair mode, the diagnostic and repair constraints are authoritative.
        - If a needed table, column, relationship, metric, status value, or business term is undefined, set needsClarification true and ask one concise question.
        - Do not invent metric, status, ownership, or business-term definitions.
        - A plausible query that answers a different metric is wrong.
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
        promptBundle(
            question: question,
            schema: schema,
            context: context,
            databaseContext: databaseContext,
            maxSchemaCharacters: maxSchemaCharacters
        ).prompt
    }

    public static func promptBundle(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext = SQLGenerationContext(),
        databaseContext: String? = nil,
        maxSchemaCharacters: Int = 8_000
    ) -> PromptBundle {
        let databaseContextText = databaseContextSection(databaseContext)
        let schemaPackage = SchemaPromptPackager.package(
            schema: schema,
            question: question,
            context: context,
            databaseContext: databaseContext ?? "",
            maxCharacters: maxSchemaCharacters
        )
        var sections = [
            taggedSection(
                "database_schema",
                schemaPackage.text
            )
        ]

        if let databaseContextSection = databaseContextText {
            sections.append(taggedSection("database_context", databaseContextSection))
        }

        switch context.mode {
        case .repair:
            sections.append(repairTaskSection(question: question, context: context))
        case .reconstructAfterFailedRepair:
            sections.append(reconstructionTaskSection(question: question, context: context))
        case .initial, .followUp:
            if let contextSection = contextSection(context) {
                sections.append(contextSection)
            }
            sections.append(
                taggedSection(
                    "current_user_request",
                    "User question: \(question)"
                ))
        }
        return PromptBundle(
            prompt: sections.joined(separator: "\n\n"),
            schemaPackage: schemaPackage
        )
    }

    static func repairTaskSection(question: String, context: SQLGenerationContext) -> String {
        let repair = context.repairContext
        let failedSQL = repair?.failedSQL ?? context.currentSQL ?? ""
        var lines = [
            "<repair_task>",
            taggedCDATASection("original_request", context.originalQuestion ?? question),
        ]
        if !failedSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(taggedCDATASection("failed_sql", failedSQL))
        }
        lines.append(databaseDiagnosticSection(repair?.diagnostic, fallbackError: context.lastRunError))
        lines.append(repairConstraintsSection(repair))
        lines.append(
            taggedCDATASection(
                "repair_instruction",
                """
                The database diagnostic is authoritative.

                Every identifier listed in <forbidden_identifier> MUST be absent from the next SQL. Reformatting, changing aliases, changing LIMIT, or changing whitespace does not constitute a repair.

                Every identifier listed in <forbidden_unquoted_identifier> may be used only when it is double quoted exactly as shown.

                A repair is acceptable only when it removes the diagnosed cause and passes the closed-world schema checklist.

                If the schema does not provide an unambiguous, intent-preserving repair, set needsClarification to true immediately.
                """
            ))
        lines.append("</repair_task>")
        return lines.joined(separator: "\n")
    }

    static func reconstructionTaskSection(question: String, context: SQLGenerationContext) -> String {
        let repair = context.repairContext
        var lines = [
            "<reconstruction_task>",
            taggedCDATASection("original_request", context.originalQuestion ?? question),
        ]
        if let repair {
            lines.append("<must_not_use>")
            for identifier in repair.forbiddenIdentifiers {
                lines.append(taggedCDATASection("identifier", identifier))
            }
            lines.append("</must_not_use>")
            if !repair.priorFingerprints.isEmpty {
                lines.append("<prior_attempts>")
                for fingerprint in repair.priorFingerprints {
                    lines.append(taggedCDATASection("fingerprint", fingerprint))
                }
                lines.append("</prior_attempts>")
            }
        }
        lines.append(
            taggedCDATASection(
                "reconstruction_instruction",
                """
                Construct the answer from the original request and focused schema.
                Do not patch or imitate any previous SQL.
                If the schema does not define the requested business meaning, set needsClarification to true.
                """
            ))
        lines.append("</reconstruction_task>")
        return lines.joined(separator: "\n")
    }

    private static func databaseDiagnosticSection(
        _ diagnostic: DatabaseDiagnostic?,
        fallbackError: String?
    ) -> String {
        var lines = ["<database_diagnostic>"]
        if let diagnostic {
            lines.append("<kind>\(diagnostic.kind.rawValue)</kind>")
            if let sqlState = diagnostic.sqlState {
                lines.append("<sqlstate>\(sqlState)</sqlstate>")
            }
            if let identifier = diagnostic.identifierForRepair {
                lines.append(taggedCDATASection("missing_identifier", identifier))
            }
            lines.append(taggedCDATASection("message", diagnostic.message))
            if let detail = diagnostic.detail {
                lines.append(taggedCDATASection("detail", detail))
            }
            if let hint = diagnostic.hint {
                lines.append(taggedCDATASection("hint", hint))
            }
            if let position = diagnostic.position {
                lines.append("<position>\(position)</position>")
            }
        } else if let fallbackError,
            !fallbackError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            lines.append(taggedCDATASection("message", fallbackError))
        } else {
            lines.append(taggedCDATASection("message", "The previous generated SQL failed."))
        }
        lines.append("</database_diagnostic>")
        return lines.joined(separator: "\n")
    }

    private static func repairConstraintsSection(_ repair: SQLRepairContext?) -> String {
        var lines = ["<repair_constraints>"]
        let constraints =
            repair?.repairConstraints
            ?? repair?.forbiddenIdentifiers.map { .forbiddenIdentifier($0) }
            ?? []
        for constraint in constraints {
            switch constraint.kind {
            case .forbiddenIdentifier:
                lines.append(taggedCDATASection("forbidden_identifier", constraint.identifier))
            case .forbiddenUnquotedIdentifier:
                lines.append(
                    taggedCDATASection("forbidden_unquoted_identifier", constraint.identifier)
                )
            }
        }
        if let fingerprints = repair?.priorFingerprints, !fingerprints.isEmpty {
            lines.append("<prior_fingerprints>")
            for fingerprint in fingerprints {
                lines.append(taggedCDATASection("fingerprint", fingerprint))
            }
            lines.append("</prior_fingerprints>")
        }
        lines.append("<require_new_fingerprint>true</require_new_fingerprint>")
        lines.append("</repair_constraints>")
        return lines.joined(separator: "\n")
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

        if let confirmedClarification = confirmedClarificationSection(in: orderedMessages) {
            lines.append(confirmedClarification)
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

    private static func confirmedClarificationSection(
        in messages: [SQLConversationMessage]
    ) -> String? {
        guard messages.count >= 2 else { return nil }
        var confirmed: [(question: String, answer: String)] = []
        for index in messages.indices.dropFirst() {
            let answer = messages[index]
            let question = messages[messages.index(before: index)]
            guard answer.role == .user, question.role == .assistant else { continue }
            guard isAffirmativeClarificationAnswer(answer.text),
                isAssistantClarificationQuestion(question.text)
            else { continue }
            confirmed.append((question: question.text, answer: answer.text))
        }
        guard let latest = confirmed.last else { return nil }
        return [
            "<confirmed_clarification>",
            "The user answered an assistant clarification question affirmatively.",
            "Use the approved definition or constraint below to answer the original request.",
            "If the current user request is only an affirmative answer, the active task is still the original user question.",
            "Do not ask the same clarification question again.",
            taggedCDATASection("approved_question", truncated(latest.question, to: 900)),
            taggedCDATASection("user_answer", truncated(latest.answer, to: 120)),
            "</confirmed_clarification>",
        ].joined(separator: "\n")
    }

    private static func isAffirmativeClarificationAnswer(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let stripped = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ".!?, "))
        let affirmativeAnswers: Set<String> = [
            "y", "yes", "yeah", "yep", "correct", "right", "that's right", "that is right",
            "sounds good", "ok", "okay", "sure", "use that", "do that", "exactly",
        ]
        return affirmativeAnswers.contains(stripped)
    }

    private static func isAssistantClarificationQuestion(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.hasSuffix("?") else { return false }
        let clarificationMarkers = [
            "should i",
            "do you mean",
            "did you mean",
            "which ",
            "what column",
            "what table",
            "what field",
            "how should",
            "can you clarify",
            "please clarify",
            "define",
            "definition",
            "mean by",
            "interpret",
        ]
        return clarificationMarkers.contains { normalized.contains($0) }
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
        guard lowercased.contains("column"),
            lowercased.contains("does not exist")
                || lowercased.contains("not available from the referenced tables")
                || lowercased.contains("not on ")
        else {
            return nil
        }

        let candidates = missingColumnCandidates(in: text)
        let missingColumns = missingColumnNames(in: text)
        let missingColumnText =
            missingColumns.isEmpty
            ? "a column"
            : "column \(missingColumns.map { "\"\($0)\"" }.joined(separator: ", "))"

        if candidates.isEmpty {
            return
                "The previous SQL used \(missingColumnText) that is not available from the referenced tables. Use only columns present in the schema. If no available column clearly matches the user's intent, set needsClarification to true and ask which entity or relationship they mean."
        }

        return
            "The previous SQL used \(missingColumnText) that is not available from the referenced tables. Candidate columns from the database hint: \(candidates.joined(separator: ", ")). Use a candidate only if it matches the user's intent; otherwise set needsClarification to true and ask which entity or relationship they mean."
    }

    static func missingColumnClarificationQuestion(
        for text: String,
        question: String? = nil,
        schema: DatabaseSchema? = nil
    ) -> String? {
        let lowercased = text.lowercased()
        guard lowercased.contains("column"),
            lowercased.contains("does not exist")
                || lowercased.contains("not available from the referenced tables")
                || lowercased.contains("not on ")
        else {
            return nil
        }

        let missingColumns = missingColumnNames(in: text)
        let missingColumn =
            missingColumns.first
            ?? quotedIdentifiers(in: text).first
            ?? "the missing column"
        let missingColumnList = missingColumns.isEmpty
            ? "\"\(missingColumn)\""
            : missingColumns.map { "\"\($0)\"" }.joined(separator: ", ")
        let candidates = missingColumnCandidates(in: text)
        switch candidates.count {
        case 0:
            return
                "I'm having trouble identifying which schema column should replace \(missingColumnList). Can you clarify which table, join, or relationship defines that value?"
        case 1:
            return
                "I'm having trouble confirming whether \"\(candidates[0])\" should replace \"\(missingColumn)\". Can you clarify which entity or relationship you mean?"
        default:
            let options = candidates.dropLast().joined(separator: "\", \"")
            return
                "I'm having trouble identifying which column should replace \"\(missingColumn)\". Did you mean \"\(options)\", or \"\(candidates.last!)\", or something else?"
        }
    }

    private static func missingColumnNames(in text: String) -> [String] {
        var names = quotedIdentifiers(in: text).filter { !$0.contains(".") }
        names.append(
            contentsOf: capturedValues(
                in: text,
                pattern:
                    #"Schema validation failed: column ([A-Za-z_][A-Za-z0-9_$]*) is (?:not available from the referenced tables|not on [^.\s]+(?:\.[^.\s]+)?|ambiguous across referenced tables)"#
            ))
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
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

    private static func capturedValues(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
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

    public static func taggedCDATASectionForGenerator(_ tag: String, _ content: String) -> String {
        taggedCDATASection(tag, content)
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
                let constraints = valueConstraintSummary(column).map { " \($0)" } ?? ""
                lines.append(
                    "- \(quotedIdentifier(column.name)) \(column.dataType.lowercased())\(nullability)\(constraints)"
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

    private static func valueConstraintSummary(_ column: ColumnInfo) -> String? {
        guard let constraints = column.valueConstraints, !constraints.isEmpty else {
            return nil
        }
        let parts = constraints.compactMap { constraint -> String? in
            switch constraint.kind {
            case .enumValues:
                guard !constraint.values.isEmpty else { return nil }
                return "values: \(quotedLiterals(constraint.values))"
            case .check:
                if !constraint.values.isEmpty {
                    return "check values: \(quotedLiterals(constraint.values))"
                }
                guard let expression = constraint.expression,
                    !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    return nil
                }
                return "check: \(truncated(expression, to: 180))"
            }
        }
        return parts.isEmpty ? nil : "(\(parts.joined(separator: "; ")))"
    }

    private static func quotedLiterals(_ values: [String]) -> String {
        values.prefix(20)
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ", ")
    }
}
