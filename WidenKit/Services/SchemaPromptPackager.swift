import Foundation

public struct PromptBudget: Equatable, Sendable {
    public var contextWindowTokens: Int
    public var outputReserveTokens: Int
    public var safetyMarginTokens: Int

    public init(
        contextWindowTokens: Int,
        outputReserveTokens: Int,
        safetyMarginTokens: Int
    ) {
        self.contextWindowTokens = contextWindowTokens
        self.outputReserveTokens = outputReserveTokens
        self.safetyMarginTokens = safetyMarginTokens
    }

    public static let localFoundationModels = PromptBudget(
        contextWindowTokens: 4_096,
        outputReserveTokens: 512,
        safetyMarginTokens: 512
    )

    public func schemaCharacterAllowance(fixedPromptCharacters: Int) -> Int {
        let fixedTokens = max(0, fixedPromptCharacters / 4)
        let availableTokens = max(
            512,
            contextWindowTokens - outputReserveTokens - safetyMarginTokens - fixedTokens
        )
        return availableTokens * 4
    }
}

public struct SchemaPromptPackage: Equatable, Sendable {
    public var text: String
    public var includedTables: [String]
    public var pinnedTables: [String]
    public var omittedTableCount: Int
}

public enum SchemaPromptPackager {
    public static func package(
        schema: DatabaseSchema,
        question: String,
        context: SQLGenerationContext,
        databaseContext: String,
        maxCharacters: Int
    ) -> SchemaPromptPackage {
        let repairContext = context.repairContext
        let rankingQuestion = contextualQuestion(question, context: context)
        let input = SchemaRankingInput(
            question: rankingQuestion,
            currentSQL: repairContext?.failedSQL ?? context.currentSQL,
            databaseContext: databaseContext,
            diagnostic: repairContext?.diagnostic,
            forbiddenIdentifiers: repairContext?.forbiddenIdentifiers ?? []
        )
        let ranked = SchemaRelevanceRanker.rank(schema: schema, input: input)
        return package(
            schema: schema,
            ranked: ranked,
            input: input,
            maxCharacters: maxCharacters
        )
    }

    public static func package(
        schema: DatabaseSchema,
        ranked: [RankedSchemaTable],
        input: SchemaRankingInput,
        maxCharacters: Int
    ) -> SchemaPromptPackage {
        let rankedIDs = ranked.map(\.table.id)
        let relationshipHints = relationshipHints(schema: schema, input: input)
        var pinnedIDs = pinnedTableIDs(schema: schema, ranked: ranked, input: input)
        for hint in relationshipHints {
            pinnedIDs.formUnion(hint.tableIDs)
        }
        var includedIDs = Set<String>()
        var sections: [String] = ["Database schema:"]

        func appendSection(_ title: String, tables: [TableInfo], force: Bool = false) {
            var tableSections: [String] = []
            for table in tables where !includedIDs.contains(table.id) {
                tableSections.append(fullTableSection(table, schema: schema))
            }
            guard !tableSections.isEmpty else { return }
            let section = ([title] + tableSections).joined(separator: "\n")
            if force || fits(sections: sections, adding: section, maxCharacters: maxCharacters) {
                sections.append(section)
                for table in tables {
                    includedIDs.insert(table.id)
                }
            }
        }

        let pinnedTables = ranked
            .map(\.table)
            .filter { pinnedIDs.contains($0.id) }
        appendSection("Pinned tables:", tables: pinnedTables, force: true)

        let primaryTables = ranked
            .filter { $0.score > 0 && !pinnedIDs.contains($0.table.id) }
            .prefix(8)
            .map(\.table)
        appendSection("Primary tables:", tables: Array(primaryTables))

        let relationshipLines = relationshipLines(
            schema: schema,
            touching: includedIDs
        )
        if !relationshipLines.isEmpty {
            let section = (["Relationships:"] + relationshipLines).joined(separator: "\n")
            if fits(sections: sections, adding: section, maxCharacters: maxCharacters) {
                sections.append(section)
            }
        }

        let relationshipHintLines = relationshipHints.map(\.text)
        if !relationshipHintLines.isEmpty {
            let section = (["Relationship hints:"] + relationshipHintLines).joined(separator: "\n")
            if fits(sections: sections, adding: section, maxCharacters: maxCharacters)
                || input.diagnostic != nil
                || !input.forbiddenIdentifiers.isEmpty
            {
                sections.append(section)
            }
        }

        let catalogLines = rankedIDs.compactMap { id -> String? in
            guard !includedIDs.contains(id),
                let table = schema.tables.first(where: { $0.id == id })
            else { return nil }
            let relevantColumns = relevantColumnNames(table, input: input).prefix(5)
            let columns = relevantColumns.isEmpty
                ? ""
                : " columns: \(relevantColumns.joined(separator: ", "))"
            return "TABLE \(qualifiedName(table))\(columns)"
        }
        if !catalogLines.isEmpty {
            var catalog: [String] = []
            for line in catalogLines {
                let candidate = (["Catalog tables:"] + catalog + [line]).joined(separator: "\n")
                if candidate.count + sections.joined(separator: "\n\n").count + 2 <= maxCharacters {
                    catalog.append(line)
                } else {
                    break
                }
            }
            if !catalog.isEmpty {
                sections.append((["Catalog tables:"] + catalog).joined(separator: "\n"))
            }
        }

        let text = sections.joined(separator: "\n\n")
        let omitted = max(0, schema.tables.count - includedIDs.count)
        let finalText = omitted > 0
            ? text + "\n\n(Schema focused: \(omitted) table\(omitted == 1 ? "" : "s") summarized or omitted.)"
            : text
        return SchemaPromptPackage(
            text: finalText,
            includedTables: Array(includedIDs).sorted(),
            pinnedTables: Array(pinnedIDs).sorted(),
            omittedTableCount: omitted
        )
    }

    private struct RelationshipHint {
        var text: String
        var tableIDs: Set<String>
    }

    private static func contextualQuestion(
        _ question: String,
        context: SQLGenerationContext
    ) -> String {
        var parts: [String] = []
        if let originalQuestion = context.originalQuestion {
            parts.append(originalQuestion)
        }
        parts.append(contentsOf: context.recentQuestions)
        parts.append(
            contentsOf: context.conversationMessages
                .filter { $0.role == .user }
                .suffix(3)
                .map(\.text)
        )
        parts.append(question)
        return parts.joined(separator: " ")
    }

    private static func pinnedTableIDs(
        schema: DatabaseSchema,
        ranked: [RankedSchemaTable],
        input: SchemaRankingInput
    ) -> Set<String> {
        var pinned = Set<String>()
        let referenced = Set(
            SchemaRelevanceRanker.extractRelationLikeIdentifiers(from: input.currentSQL ?? "")
        )
        for table in schema.tables {
            if referenced.contains(table.qualifiedName.lowercased())
                || referenced.contains(table.name.lowercased())
            {
                pinned.insert(table.id)
            }
        }
        for table in ranked.prefix(2).map(\.table) where ranked.first(where: { $0.table.id == table.id })?.score ?? 0 >= 300 {
            pinned.insert(table.id)
        }
        if let diagnostic = input.diagnostic,
            diagnostic.kind == .missingRelation
        {
            for entry in ranked.prefix(3) where entry.score >= 300 {
                pinned.insert(entry.table.id)
            }
        }
        return pinned
    }

    private static func relationshipHints(
        schema: DatabaseSchema,
        input: SchemaRankingInput
    ) -> [RelationshipHint] {
        var hints =
            winningToolRelationshipHints(schema: schema, input: input)
            + missingColumnRelationshipHints(schema: schema, input: input)
        var seen = Set<String>()
        hints = hints.filter { seen.insert($0.text).inserted }
        return Array(hints.prefix(6))
    }

    private static func winningToolRelationshipHints(
        schema: DatabaseSchema,
        input: SchemaRankingInput
    ) -> [RelationshipHint] {
        let tokens = inputTokens(input)
        guard hasWinningToolIntent(tokens) else { return [] }

        return schema.foreignKeys.compactMap { foreignKey in
            let sourceColumnTokens = Set(SchemaIndex.tokens(in: foreignKey.sourceColumn))
            guard !sourceColumnTokens.intersection(winTokens).isEmpty else { return nil }
            guard let sourceTable = table(
                schemaName: foreignKey.sourceSchema,
                tableName: foreignKey.sourceTable,
                in: schema
            ),
                let targetTable = table(
                    schemaName: foreignKey.targetSchema,
                    tableName: foreignKey.targetTable,
                    in: schema
                )
            else { return nil }

            let targetTokens = Set(
                SchemaIndex.tokens(in: targetTable.name)
                    + targetTable.columns.flatMap { SchemaIndex.tokens(in: $0.name) }
            )
            guard targetTokens.contains("tool") else { return nil }

            let sourceColumn = qualifiedColumn(
                schema: foreignKey.sourceSchema,
                table: foreignKey.sourceTable,
                column: foreignKey.sourceColumn
            )
            let targetColumn = qualifiedColumn(
                schema: foreignKey.targetSchema,
                table: foreignKey.targetTable,
                column: foreignKey.targetColumn
            )
            var guidance =
                "For winning-tool questions, \(sourceColumn) is the winning tool id: join \(qualifiedName(targetTable)) on \(targetColumn) = \(sourceColumn), filter \(sourceColumn) IS NOT NULL, count/group by \(sourceColumn), and use label columns from \(qualifiedName(targetTable))."
            if let temporalColumn = temporalColumn(in: sourceTable, tokens: tokens) {
                guidance +=
                    " For requested time windows, filter \(qualifiedColumn(schema: sourceTable.schema, table: sourceTable.name, column: temporalColumn.name)) with PostgreSQL intervals such as NOW() - INTERVAL '14 days'."
            }
            if !sourceTable.columns.contains(where: {
                SchemaRelevanceRanker.canonicalIdentifier($0.name) == "tool_id"
            }) {
                guidance += " Do not select a generic \(quotedIdentifier("tool_id")) from \(qualifiedName(sourceTable)); it is not a column on that table."
            }
            let participantColumns = sourceTable.columns.filter {
                ["tool_a_id", "tool_b_id"].contains(SchemaRelevanceRanker.canonicalIdentifier($0.name))
            }
            if participantColumns.isEmpty {
                guidance +=
                    " Do not use participant columns \(quotedIdentifier("tool_a_id")) or \(quotedIdentifier("tool_b_id")) as wins unless the user asks for participants."
            }
            let decisionColumns = sourceTable.columns.filter {
                SchemaIndex.tokens(in: $0.name).contains("decision")
                    || SchemaRelevanceRanker.canonicalIdentifier($0.name).contains("status")
            }
            let constrainedDecisionColumns = decisionColumns.compactMap { column -> String? in
                guard let summary = valueConstraintSummary(column) else { return nil }
                return "\(qualifiedColumn(schema: sourceTable.schema, table: sourceTable.name, column: column.name)) \(summary)"
            }
            if !constrainedDecisionColumns.isEmpty {
                guidance +=
                    " Schema-defined decision/status values: \(constrainedDecisionColumns.joined(separator: "; ")). Do not invent other literal values."
            } else if !decisionColumns.isEmpty {
                guidance +=
                    " Do not compare decision/status fields to invented literal values unless Database context defines those values."
            }

            return RelationshipHint(
                text: guidance,
                tableIDs: [sourceTable.id, targetTable.id]
            )
        }
    }

    private static func missingColumnRelationshipHints(
        schema: DatabaseSchema,
        input: SchemaRankingInput
    ) -> [RelationshipHint] {
        let referencedTables = referencedTables(in: input.currentSQL ?? "", schema: schema)
        guard !referencedTables.isEmpty else { return [] }

        let forbiddenColumns = input.forbiddenIdentifiers
            .filter { !$0.contains(".") }
            .map { SchemaRelevanceRanker.canonicalIdentifier($0) }
            .filter { !$0.isEmpty }
        guard !forbiddenColumns.isEmpty else { return [] }

        var hints: [RelationshipHint] = []
        for columnName in forbiddenColumns {
            let candidateTables = schema.tables.filter { table in
                table.columns.contains {
                    SchemaRelevanceRanker.canonicalIdentifier($0.name) == columnName
                }
            }
            for candidateTable in candidateTables {
                for referencedTable in referencedTables where referencedTable.id != candidateTable.id {
                    guard let join = directJoin(
                        from: referencedTable,
                        to: candidateTable,
                        schema: schema
                    ) else { continue }
                    hints.append(
                        RelationshipHint(
                            text:
                                "Column \(quotedIdentifier(columnName)) is on \(qualifiedName(candidateTable)), not \(qualifiedName(referencedTable)); if participant columns are needed, join \(join).",
                            tableIDs: [referencedTable.id, candidateTable.id]
                        ))
                }
            }
        }
        return hints
    }

    private static func directJoin(
        from sourceTable: TableInfo,
        to targetTable: TableInfo,
        schema: DatabaseSchema
    ) -> String? {
        if let foreignKey = schema.foreignKeys.first(where: {
            $0.sourceSchema == sourceTable.schema
                && $0.sourceTable == sourceTable.name
                && $0.targetSchema == targetTable.schema
                && $0.targetTable == targetTable.name
        }) {
            return
                "\(qualifiedColumn(schema: foreignKey.sourceSchema, table: foreignKey.sourceTable, column: foreignKey.sourceColumn)) -> \(qualifiedColumn(schema: foreignKey.targetSchema, table: foreignKey.targetTable, column: foreignKey.targetColumn))"
        }
        if let foreignKey = schema.foreignKeys.first(where: {
            $0.sourceSchema == targetTable.schema
                && $0.sourceTable == targetTable.name
                && $0.targetSchema == sourceTable.schema
                && $0.targetTable == sourceTable.name
        }) {
            return
                "\(qualifiedColumn(schema: foreignKey.sourceSchema, table: foreignKey.sourceTable, column: foreignKey.sourceColumn)) -> \(qualifiedColumn(schema: foreignKey.targetSchema, table: foreignKey.targetTable, column: foreignKey.targetColumn))"
        }
        return nil
    }

    private static func referencedTables(in sql: String, schema: DatabaseSchema) -> [TableInfo] {
        var seen = Set<String>()
        return SchemaRelevanceRanker.extractRelationLikeIdentifiers(from: sql).compactMap {
            identifier in
            guard let table = resolveTable(identifier, schema: schema),
                seen.insert(table.id).inserted
            else { return nil }
            return table
        }
    }

    private static func resolveTable(_ identifier: String, schema: DatabaseSchema) -> TableInfo? {
        let canonical = SchemaRelevanceRanker.canonicalIdentifier(identifier)
        let qualifiedMatches = schema.tables.filter {
            SchemaRelevanceRanker.canonicalIdentifier($0.qualifiedName) == canonical
        }
        if qualifiedMatches.count == 1 { return qualifiedMatches[0] }
        let unqualifiedMatches = schema.tables.filter {
            SchemaRelevanceRanker.canonicalIdentifier($0.name) == canonical
        }
        return unqualifiedMatches.count == 1 ? unqualifiedMatches[0] : nil
    }

    private static func table(
        schemaName: String,
        tableName: String,
        in schema: DatabaseSchema
    ) -> TableInfo? {
        schema.tables.first { $0.schema == schemaName && $0.name == tableName }
    }

    private static func inputTokens(_ input: SchemaRankingInput) -> Set<String> {
        Set(
            SchemaIndex.tokens(
                in: [
                    input.question,
                    input.databaseContext,
                    input.currentSQL ?? "",
                    input.forbiddenIdentifiers.joined(separator: " "),
                ].joined(separator: " ")
            ))
    }

    private static func hasWinningToolIntent(_ tokens: Set<String>) -> Bool {
        !tokens.intersection(winTokens).isEmpty && tokens.contains("tool")
    }

    private static func temporalColumn(in table: TableInfo, tokens: Set<String>) -> ColumnInfo? {
        let temporalIntentTokens: Set<String> = [
            "last", "recent", "today", "yesterday", "week", "weeks", "month", "months",
            "day", "days", "date", "time", "since", "between",
        ]
        guard !tokens.intersection(temporalIntentTokens).isEmpty else { return nil }
        let temporalColumns = table.columns.filter { column in
            let dataType = column.dataType.lowercased()
            return dataType.contains("timestamp") || dataType == "date"
        }
        let preferredNames = [
            "createdat", "created_at", "completed_at", "completedat", "started_at",
            "startedat", "scheduled_for", "scheduledfor", "updatedat", "updated_at",
        ]
        for name in preferredNames {
            if let column = temporalColumns.first(where: {
                SchemaRelevanceRanker.canonicalIdentifier($0.name) == name
            }) {
                return column
            }
        }
        return temporalColumns.first
    }

    private static let winTokens: Set<String> = [
        "win", "winner", "winning", "won", "victory", "victor",
    ]

    private static func fullTableSection(_ table: TableInfo, schema: DatabaseSchema) -> String {
        var lines = ["TABLE \(qualifiedName(table))"]
        for column in table.columns {
            let nullability = column.isNullable ? "" : " NOT NULL"
            let constraints = valueConstraintSummary(column).map { " \($0)" } ?? ""
            lines.append(
                "  \(quotedIdentifier(column.name)) \(column.dataType.lowercased())\(nullability)\(constraints)"
            )
        }
        for foreignKey in schema.foreignKeys where foreignKey.sourceSchema == table.schema && foreignKey.sourceTable == table.name {
            lines.append(
                "  FK \(quotedIdentifier(foreignKey.sourceColumn)) -> \(qualifiedName(schema: foreignKey.targetSchema, table: foreignKey.targetTable)).\(quotedIdentifier(foreignKey.targetColumn))"
            )
        }
        return lines.joined(separator: "\n")
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

    private static func relationshipLines(schema: DatabaseSchema, touching tableIDs: Set<String>) -> [String] {
        schema.foreignKeys.compactMap { foreignKey in
            let sourceID = "\(foreignKey.sourceSchema).\(foreignKey.sourceTable)"
            let targetID = "\(foreignKey.targetSchema).\(foreignKey.targetTable)"
            guard tableIDs.contains(sourceID) || tableIDs.contains(targetID) else { return nil }
            return "FK \(qualifiedName(schema: foreignKey.sourceSchema, table: foreignKey.sourceTable)).\(quotedIdentifier(foreignKey.sourceColumn)) -> \(qualifiedName(schema: foreignKey.targetSchema, table: foreignKey.targetTable)).\(quotedIdentifier(foreignKey.targetColumn))"
        }
    }

    private static func relevantColumnNames(_ table: TableInfo, input: SchemaRankingInput) -> [String] {
        let tokens = Set(
            SchemaIndex.tokens(in: input.question + " " + input.databaseContext + " " + (input.currentSQL ?? ""))
        )
        let matches = table.columns.filter { column in
            !tokens.intersection(SchemaIndex.tokens(in: column.name)).isEmpty
        }
        let selected = matches.isEmpty ? Array(table.columns.prefix(3)) : matches
        return selected.map { quotedIdentifier($0.name) }
    }

    private static func fits(sections: [String], adding section: String, maxCharacters: Int) -> Bool {
        sections.joined(separator: "\n\n").count + section.count + 2 <= maxCharacters
    }

    private static func qualifiedName(_ table: TableInfo) -> String {
        qualifiedName(schema: table.schema, table: table.name)
    }

    private static func qualifiedName(schema: String, table: String) -> String {
        "\(quotedIdentifier(schema)).\(quotedIdentifier(table))"
    }

    private static func qualifiedColumn(schema: String, table: String, column: String) -> String {
        "\(qualifiedName(schema: schema, table: table)).\(quotedIdentifier(column))"
    }

    private static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func quotedLiterals(_ values: [String]) -> String {
        values.prefix(20)
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ", ")
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "..."
    }
}
