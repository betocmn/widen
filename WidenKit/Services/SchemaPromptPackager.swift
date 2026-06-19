import Foundation

public struct PromptBudget: Equatable, Sendable {
    public static let estimatedCharactersPerToken = 3

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

    public func inputTokenAllowance(scale: Double = 1.0) -> Int {
        let raw = contextWindowTokens - outputReserveTokens - safetyMarginTokens
        return max(256, Int(Double(raw) * scale))
    }

    public func inputCharacterAllowance(scale: Double = 1.0) -> Int {
        inputTokenAllowance(scale: scale) * Self.estimatedCharactersPerToken
    }

    public func estimatedTokenCount(for characters: Int) -> Int {
        max(0, Int(ceil(Double(characters) / Double(Self.estimatedCharactersPerToken))))
    }

    public func fits(inputCharacters: Int, scale: Double = 1.0) -> Bool {
        estimatedTokenCount(for: inputCharacters) <= inputTokenAllowance(scale: scale)
    }

    public func schemaCharacterAllowance(fixedPromptCharacters: Int) -> Int {
        schemaCharacterAllowance(fixedPromptCharacters: fixedPromptCharacters, scale: 1.0)
    }

    public func schemaCharacterAllowance(fixedPromptCharacters: Int, scale: Double) -> Int {
        let fixedTokens = estimatedTokenCount(for: max(0, fixedPromptCharacters))
        let availableTokens = max(
            256,
            inputTokenAllowance(scale: scale) - fixedTokens
        )
        return availableTokens * Self.estimatedCharactersPerToken
    }
}

public struct SchemaPromptPackage: Equatable, Sendable {
    public var text: String
    public var includedTables: [String]
    public var pinnedTables: [String]
    public var omittedTableCount: Int
    public var diagnostics: SchemaPromptPackager.PackageDiagnostics
}

public enum SchemaDiscoveryService {
    public static func compactCatalog(
        schema: DatabaseSchema,
        question: String,
        databaseContext: String,
        maxCharacters: Int
    ) -> String {
        let input = SchemaRankingInput(
            question: question,
            databaseContext: databaseContext
        )
        let ranked = SchemaRelevanceRanker.rank(schema: schema, input: input)
        var lines = [
            "Schema catalog:",
            "Return up to 3 schema search queries that would help answer the user request. Do not write SQL.",
        ]

        for entry in ranked {
            guard lines.joined(separator: "\n").count < maxCharacters else { break }
            let table = entry.table
            let columns = catalogColumns(table, input: input)
            let line =
                "TABLE \(quotedIdentifier(table.schema)).\(quotedIdentifier(table.name)) columns: \(columns.joined(separator: ", "))"
            if lines.joined(separator: "\n").count + line.count + 1 <= maxCharacters {
                lines.append(line)
            }
        }

        let foreignKeyLines = schema.foreignKeys.prefix(80).map {
            "FK \(quotedIdentifier($0.sourceSchema)).\(quotedIdentifier($0.sourceTable)).\(quotedIdentifier($0.sourceColumn)) -> \(quotedIdentifier($0.targetSchema)).\(quotedIdentifier($0.targetTable)).\(quotedIdentifier($0.targetColumn))"
        }
        if !foreignKeyLines.isEmpty {
            for line in ["Relationships:"] + foreignKeyLines {
                if lines.joined(separator: "\n").count + line.count + 1 <= maxCharacters {
                    lines.append(line)
                } else {
                    break
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    public static func search(
        schema: DatabaseSchema,
        queries: [String],
        limit: Int = 8
    ) -> [TableInfo] {
        let searchText = queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !searchText.isEmpty else { return [] }
        let ranked = SchemaRelevanceRanker.rank(
            schema: schema,
            input: SchemaRankingInput(question: searchText)
        )
        return Array(ranked.filter { $0.score > 0 }.prefix(limit).map(\.table))
    }

    private static func catalogColumns(
        _ table: TableInfo,
        input: SchemaRankingInput
    ) -> [String] {
        let tokens = Set(SchemaIndex.tokens(in: input.question + " " + input.databaseContext))
        let matches = table.columns.filter {
            let columnTokens = Set(SchemaIndex.tokens(in: $0.name))
            return !tokens.intersection(columnTokens).isEmpty
                || SchemaRelevanceRanker.canonicalIdentifier($0.name) == "id"
                || SchemaRelevanceRanker.canonicalIdentifier($0.name).hasSuffix("_id")
                || ["name", "slug"].contains(SchemaRelevanceRanker.canonicalIdentifier($0.name))
                || $0.valueConstraints?.isEmpty == false
        }
        let selected = matches.isEmpty ? Array(table.columns.prefix(4)) : Array(matches.prefix(8))
        return selected.map {
            var text = quotedIdentifier($0.name)
            if let constraints = $0.valueConstraints, !constraints.isEmpty {
                let values = constraints.flatMap(\.values).prefix(8)
                if !values.isEmpty {
                    text += " values: \(values.joined(separator: "|"))"
                }
            }
            return text
        }
    }

    private static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

public enum SchemaPromptPackager {
    public enum CompressionLevel: String, Codable, Equatable, Sendable {
        case full
        case focused
        case minimal
    }

    public struct PackageOptions: Equatable, Sendable {
        public var maxCharacters: Int
        public var compressionLevel: CompressionLevel?
        public var maxPrimaryTables: Int
        public var includeCatalog: Bool

        public init(
            maxCharacters: Int,
            compressionLevel: CompressionLevel? = nil,
            maxPrimaryTables: Int = 8,
            includeCatalog: Bool = true
        ) {
            self.maxCharacters = maxCharacters
            self.compressionLevel = compressionLevel
            self.maxPrimaryTables = maxPrimaryTables
            self.includeCatalog = includeCatalog
        }
    }

    public struct PackageDiagnostics: Equatable, Sendable {
        public var estimatedTokens: Int
        public var maxCharacters: Int
        public var compressionLevel: CompressionLevel
        public var includedTables: [String]
        public var pinnedTables: [String]
        public var omittedTableCount: Int
        public var overflowedBudget: Bool
    }

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
            forbiddenIdentifiers: repairContext?.forbiddenIdentifiers ?? [],
            schemaSearchQueries: context.schemaSearchQueries
        )
        let ranked = SchemaRelevanceRanker.rank(schema: schema, input: input)
        return package(
            schema: schema,
            ranked: ranked,
            input: input,
            options: PackageOptions(maxCharacters: maxCharacters)
        )
    }

    public static func package(
        schema: DatabaseSchema,
        ranked: [RankedSchemaTable],
        input: SchemaRankingInput,
        maxCharacters: Int
    ) -> SchemaPromptPackage {
        package(
            schema: schema,
            ranked: ranked,
            input: input,
            options: PackageOptions(maxCharacters: maxCharacters)
        )
    }

    public static func package(
        schema: DatabaseSchema,
        ranked: [RankedSchemaTable],
        input: SchemaRankingInput,
        options: PackageOptions
    ) -> SchemaPromptPackage {
        let maxCharacters = options.maxCharacters
        let compression = options.compressionLevel ?? automaticCompression(
            maxCharacters: maxCharacters,
            input: input
        )
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
                tableSections.append(
                    tableSection(
                        table,
                        schema: schema,
                        input: input,
                        compression: compression
                    ))
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
            .prefix(options.maxPrimaryTables)
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
            var keptHints: [String] = []
            for line in relationshipHintLines {
                let candidate = (["Relationship hints:"] + keptHints + [line]).joined(separator: "\n")
                if fits(sections: sections, adding: candidate, maxCharacters: maxCharacters) {
                    keptHints.append(line)
                } else {
                    break
                }
            }
            if !keptHints.isEmpty {
                sections.append((["Relationship hints:"] + keptHints).joined(separator: "\n"))
            }
        }

        let catalogLines = options.includeCatalog ? rankedIDs.compactMap { id -> String? in
            guard !includedIDs.contains(id),
                let table = schema.tables.first(where: { $0.id == id })
            else { return nil }
            let relevantColumns = relevantColumnNames(table, input: input).prefix(5)
            let columns = relevantColumns.isEmpty
                ? ""
                : " columns: \(relevantColumns.joined(separator: ", "))"
            return "TABLE \(qualifiedName(table))\(columns)"
        } : []
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
        let suffix = "\n\n(Schema focused: \(omitted) table\(omitted == 1 ? "" : "s") summarized or omitted.)"
        let finalText =
            omitted > 0 && text.count + suffix.count <= maxCharacters
            ? text + suffix
            : text
        let diagnostics = PackageDiagnostics(
            estimatedTokens: PromptBudget.localFoundationModels.estimatedTokenCount(
                for: finalText.count
            ),
            maxCharacters: maxCharacters,
            compressionLevel: compression,
            includedTables: Array(includedIDs).sorted(),
            pinnedTables: Array(pinnedIDs).sorted(),
            omittedTableCount: omitted,
            overflowedBudget: finalText.count > maxCharacters
        )
        return SchemaPromptPackage(
            text: finalText,
            includedTables: Array(includedIDs).sorted(),
            pinnedTables: Array(pinnedIDs).sorted(),
            omittedTableCount: omitted,
            diagnostics: diagnostics
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
        parts.append(contentsOf: context.schemaSearchQueries)
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
            var parts = [
                "Winning-tool relation: \(sourceColumn) -> \(targetColumn)",
                "count non-null \(sourceColumn)",
                "group by \(sourceColumn)",
                "label from \(qualifiedName(targetTable))",
            ]
            if let temporalColumn = temporalColumn(in: sourceTable, tokens: tokens) {
                parts.append(
                    "time filter: \(qualifiedColumn(schema: sourceTable.schema, table: sourceTable.name, column: temporalColumn.name)) >= NOW() - INTERVAL '14 days'"
                )
            }
            if !sourceTable.columns.contains(where: {
                SchemaRelevanceRanker.canonicalIdentifier($0.name) == "tool_id"
            }) {
                parts.append("no generic \(quotedIdentifier("tool_id")) on \(qualifiedName(sourceTable))")
            }
            let participantColumns = sourceTable.columns.filter {
                ["tool_a_id", "tool_b_id"].contains(SchemaRelevanceRanker.canonicalIdentifier($0.name))
            }
            if participantColumns.isEmpty {
                parts.append("do not use \(quotedIdentifier("tool_a_id"))/\(quotedIdentifier("tool_b_id")) as wins unless requested")
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
                parts.append("decision/status values: \(constrainedDecisionColumns.joined(separator: "; "))")
            } else if !decisionColumns.isEmpty {
                parts.append("do not invent decision/status literal values")
            }

            return RelationshipHint(
                text: parts.joined(separator: "; ") + ".",
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
                                "Column \(quotedIdentifier(columnName)) lives on \(qualifiedName(candidateTable)), not \(qualifiedName(referencedTable)); join \(join) if that column is needed.",
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

    private static func automaticCompression(
        maxCharacters: Int,
        input: SchemaRankingInput
    ) -> CompressionLevel {
        if maxCharacters < 1_200 {
            return .minimal
        }
        if maxCharacters < 5_000 || input.diagnostic != nil || !input.forbiddenIdentifiers.isEmpty {
            return .focused
        }
        return .full
    }

    private static func tableSection(
        _ table: TableInfo,
        schema: DatabaseSchema,
        input: SchemaRankingInput,
        compression: CompressionLevel
    ) -> String {
        switch compression {
        case .full:
            return tableSection(table, schema: schema, columns: table.columns, omittedCount: 0)
        case .focused, .minimal:
            let columns = focusedColumns(
                table,
                schema: schema,
                input: input,
                compression: compression
            )
            return tableSection(
                table,
                schema: schema,
                columns: columns,
                omittedCount: max(0, table.columns.count - columns.count)
            )
        }
    }

    private static func tableSection(
        _ table: TableInfo,
        schema: DatabaseSchema,
        columns: [ColumnInfo],
        omittedCount: Int
    ) -> String {
        var lines = ["TABLE \(qualifiedName(table))"]
        let columnNames = Set(columns.map(\.name))
        for column in columns {
            let nullability = column.isNullable ? "" : " NOT NULL"
            let constraints = valueConstraintSummary(column).map { " \($0)" } ?? ""
            lines.append(
                "  \(quotedIdentifier(column.name)) \(column.dataType.lowercased())\(nullability)\(constraints)"
            )
        }
        if omittedCount > 0 {
            lines.append("  ... \(omittedCount) low-relevance column\(omittedCount == 1 ? "" : "s") omitted")
        }
        var seenForeignKeys = Set<String>()
        for foreignKey in schema.foreignKeys
        where foreignKey.sourceSchema == table.schema
            && foreignKey.sourceTable == table.name
            && (columnNames.contains(foreignKey.sourceColumn) || omittedCount == 0)
        {
            let key =
                "\(foreignKey.sourceColumn)->\(foreignKey.targetSchema).\(foreignKey.targetTable).\(foreignKey.targetColumn)"
            guard seenForeignKeys.insert(key).inserted else { continue }
            lines.append(
                "  FK \(quotedIdentifier(foreignKey.sourceColumn)) -> \(qualifiedName(schema: foreignKey.targetSchema, table: foreignKey.targetTable)).\(quotedIdentifier(foreignKey.targetColumn))"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func focusedColumns(
        _ table: TableInfo,
        schema: DatabaseSchema,
        input: SchemaRankingInput,
        compression: CompressionLevel
    ) -> [ColumnInfo] {
        if table.columns.count <= 12, compression == .focused {
            return table.columns
        }

        let inputTokens = Set(
            SchemaIndex.tokens(
                in: [
                    input.question,
                    input.databaseContext,
                    input.currentSQL ?? "",
                    input.forbiddenIdentifiers.joined(separator: " "),
                    diagnosticText(input.diagnostic),
                    input.schemaSearchQueries.joined(separator: " "),
                ].joined(separator: " ")
            )
        )
        let winningIntent = hasWinningToolIntent(inputTokens)
        let foreignKeyColumns = Set(schema.foreignKeys.flatMap { foreignKey -> [String] in
            var names: [String] = []
            if foreignKey.sourceSchema == table.schema && foreignKey.sourceTable == table.name {
                names.append(foreignKey.sourceColumn)
            }
            if foreignKey.targetSchema == table.schema && foreignKey.targetTable == table.name {
                names.append(foreignKey.targetColumn)
            }
            return names
        })
        let maxColumns = compression == .minimal ? 8 : 16

        var required: [ColumnInfo] = []
        var optional: [ColumnInfo] = []
        var selectedNames = Set<String>()
        func append(_ column: ColumnInfo, to columns: inout [ColumnInfo]) {
            guard selectedNames.insert(column.name).inserted else { return }
            columns.append(column)
        }

        for column in table.columns {
            let canonical = SchemaRelevanceRanker.canonicalIdentifier(column.name)
            let columnTokens = Set(SchemaIndex.tokens(in: column.name))
            if canonical == "id"
                || canonical.hasSuffix("_id")
                || foreignKeyColumns.contains(column.name)
                || isLabelColumn(column)
                || isTemporalColumn(column)
                || column.valueConstraints?.isEmpty == false
                || !inputTokens.intersection(columnTokens).isEmpty
                || (winningIntent && !columnTokens.intersection(winTokens).isEmpty)
            {
                append(column, to: &required)
            }
        }

        if required.count < maxColumns, compression == .focused {
            for column in table.columns where !isLowValueWideColumn(column) {
                append(column, to: &optional)
                if required.count + optional.count >= maxColumns { break }
            }
        }

        let optionalLimit = max(0, maxColumns - required.count)
        let columns = required + optional.prefix(optionalLimit)
        return columns
            .sorted { $0.ordinalPosition < $1.ordinalPosition }
            .map { $0 }
    }

    private static func diagnosticText(_ diagnostic: DatabaseDiagnostic?) -> String {
        guard let diagnostic else { return "" }
        return [
            diagnostic.sqlState,
            diagnostic.message,
            diagnostic.detail,
            diagnostic.hint,
            diagnostic.schemaName,
            diagnostic.tableName,
            diagnostic.columnName,
            diagnostic.identifierForRepair,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private static func isLabelColumn(_ column: ColumnInfo) -> Bool {
        let canonical = SchemaRelevanceRanker.canonicalIdentifier(column.name)
        return ["name", "slug", "title", "label", "display_name"].contains(canonical)
    }

    private static func isTemporalColumn(_ column: ColumnInfo) -> Bool {
        let type = column.dataType.lowercased()
        let tokens = Set(SchemaIndex.tokens(in: column.name))
        return type.contains("timestamp")
            || type == "date"
            || !tokens.intersection(["created", "updated", "started", "completed", "scheduled", "date", "time"]).isEmpty
    }

    private static func isLowValueWideColumn(_ column: ColumnInfo) -> Bool {
        let canonical = SchemaRelevanceRanker.canonicalIdentifier(column.name)
        if canonical.hasPrefix("raw")
            || canonical.hasPrefix("appendix")
            || canonical.contains("snapshot")
            || canonical.contains("rendered")
        {
            return true
        }
        let type = column.dataType.lowercased()
        return type.contains("json") || type == "text"
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
