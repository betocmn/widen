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
        safetyMarginTokens: 256
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
        let input = SchemaRankingInput(
            question: question,
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
        let pinnedIDs = pinnedTableIDs(schema: schema, ranked: ranked, input: input)
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

    private static func fullTableSection(_ table: TableInfo, schema: DatabaseSchema) -> String {
        var lines = ["TABLE \(qualifiedName(table))"]
        for column in table.columns {
            let nullability = column.isNullable ? "" : " NOT NULL"
            lines.append("  \(quotedIdentifier(column.name)) \(column.dataType.lowercased())\(nullability)")
        }
        for foreignKey in schema.foreignKeys where foreignKey.sourceSchema == table.schema && foreignKey.sourceTable == table.name {
            lines.append(
                "  FK \(quotedIdentifier(foreignKey.sourceColumn)) -> \(qualifiedName(schema: foreignKey.targetSchema, table: foreignKey.targetTable)).\(quotedIdentifier(foreignKey.targetColumn))"
            )
        }
        return lines.joined(separator: "\n")
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

    private static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
