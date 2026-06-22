import Foundation

public struct RankedSchemaTable: Equatable, Sendable {
    public var table: TableInfo
    public var score: Int
    public var reasons: [String]
}

public struct SchemaRankingInput: Equatable, Sendable {
    public var question: String
    public var currentSQL: String?
    public var databaseContext: String
    public var diagnostic: DatabaseDiagnostic?
    public var forbiddenIdentifiers: [String]
    public var schemaSearchQueries: [String]
    public var semanticBindings: [String]

    public init(
        question: String,
        currentSQL: String? = nil,
        databaseContext: String = "",
        diagnostic: DatabaseDiagnostic? = nil,
        forbiddenIdentifiers: [String] = [],
        schemaSearchQueries: [String] = [],
        semanticBindings: [String] = []
    ) {
        self.question = question
        self.currentSQL = currentSQL
        self.databaseContext = databaseContext
        self.diagnostic = diagnostic
        self.forbiddenIdentifiers = forbiddenIdentifiers
        self.schemaSearchQueries = schemaSearchQueries
        self.semanticBindings = semanticBindings
    }
}

public enum SchemaRelevanceRanker {
    public static func rank(
        schema: DatabaseSchema,
        input: SchemaRankingInput
    ) -> [RankedSchemaTable] {
        let index = SchemaIndex(schema: schema)
        let questionTokens = Set(
            SchemaIndex.tokens(in: ([input.question] + input.schemaSearchQueries).joined(separator: " "))
        )
        let contextTokens = Set(SchemaIndex.tokens(in: input.databaseContext))
        let semanticBindingTokens = Set(
            SchemaIndex.tokens(in: input.semanticBindings.joined(separator: " "))
        )
        let failedSQLIdentifiers = Set(extractRelationLikeIdentifiers(from: input.currentSQL ?? ""))
        let failedSQLTokens = Set(SchemaIndex.tokens(in: (input.currentSQL ?? "") + " " + input.forbiddenIdentifiers.joined(separator: " ")))
        let diagnosticTokens = Set(SchemaIndex.tokens(in: diagnosticText(input.diagnostic)))
        let temporalIntent = containsTemporalIntent(input.question)

        var ranked: [RankedSchemaTable] = schema.tables.map { table in
            var score = 0
            var reasons: [String] = []
            let tableTokens = index.tokensByTableID[table.id] ?? []
            let tableNameTokens = Set(SchemaIndex.tokens(in: table.name))
            let qualifiedName = table.qualifiedName.lowercased()

            if failedSQLIdentifiers.contains(qualifiedName)
                || failedSQLIdentifiers.contains(table.name.lowercased())
            {
                score += 500
                reasons.append("already referenced")
            }

            let exactQuestionTableMatches = questionTokens.intersection(tableNameTokens).count
            if exactQuestionTableMatches > 0 {
                score += exactQuestionTableMatches * 150
                reasons.append("table name matches request")
            }

            let questionColumnMatches = questionTokens.intersection(tableTokens.subtracting(tableNameTokens)).count
            if questionColumnMatches > 0 {
                score += questionColumnMatches * 50
                reasons.append("column name matches request")
            }

            if temporalIntent, index.temporalColumnsByTableID[table.id]?.isEmpty == false {
                score += 100
                reasons.append("has temporal columns")
            }

            let contextMatches = contextTokens.intersection(tableTokens).count
            if contextMatches > 0 {
                score += min(contextMatches * 30, 150)
                reasons.append("database context matches")
            }

            let semanticBindingMatches = semanticBindingTokens.intersection(tableTokens).count
            if semanticBindingMatches > 0 {
                score += min(semanticBindingMatches * 70, 350)
                reasons.append("semantic binding matches")
            }

            let failedOverlap = failedSQLTokens.intersection(tableTokens).count
            if failedOverlap > 0 {
                score += failedOverlap * 50
                reasons.append("failed SQL identifier overlap")
            }

            let diagnosticOverlap = diagnosticTokens.intersection(tableTokens).count
            if diagnosticOverlap > 0 {
                score += diagnosticOverlap * 80
                reasons.append("database diagnostic overlap")
            }

            if isStrongReplacement(table: table, diagnostic: input.diagnostic, forbiddenIdentifiers: input.forbiddenIdentifiers) {
                score += 900
                reasons.append("strong replacement candidate")
            }

            score -= min(table.columns.count / 8, 30)
            return RankedSchemaTable(table: table, score: score, reasons: reasons)
        }

        let highRankedIDs = Set(ranked.filter { $0.score >= 150 }.map(\.table.id))
        ranked = ranked.map { entry in
            var entry = entry
            let adjacentToHighRank = index.foreignKeyAdjacency[entry.table.id, default: []].contains { foreignKey in
                let sourceID = "\(foreignKey.sourceSchema).\(foreignKey.sourceTable)"
                let targetID = "\(foreignKey.targetSchema).\(foreignKey.targetTable)"
                return highRankedIDs.contains(sourceID) || highRankedIDs.contains(targetID)
            }
            if adjacentToHighRank, !highRankedIDs.contains(entry.table.id) {
                entry.score += 80
                entry.reasons.append("foreign-key neighbor")
            }
            return entry
        }

        return ranked.sorted {
            if $0.score == $1.score {
                return $0.table.qualifiedName < $1.table.qualifiedName
            }
            return $0.score > $1.score
        }
    }

    static func containsTemporalIntent(_ text: String) -> Bool {
        let tokens = Set(SchemaIndex.tokens(in: text))
        let temporal = [
            "today", "yesterday", "week", "month", "year", "day", "date", "time", "recent",
            "last", "next", "since", "between", "before", "after",
        ]
        return !tokens.intersection(temporal).isEmpty
    }

    static func extractRelationLikeIdentifiers(from sql: String) -> [String] {
        guard !sql.isEmpty else { return [] }
        let pattern = #"(?i)\b(?:from|join|update|into|delete\s+from)\s+((?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)(?:\s*\.\s*(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*))?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(sql.startIndex..<sql.endIndex, in: sql)
        return regex.matches(in: sql, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: sql) else { return nil }
            return canonicalIdentifier(String(sql[matchRange]))
        }
    }

    static func canonicalIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
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

    private static func isStrongReplacement(
        table: TableInfo,
        diagnostic: DatabaseDiagnostic?,
        forbiddenIdentifiers: [String]
    ) -> Bool {
        let forbiddenText = (forbiddenIdentifiers + [diagnostic?.identifierForRepair].compactMap { $0 })
            .joined(separator: " ")
        let forbiddenTokens = Set(SchemaIndex.tokens(in: forbiddenText))
        guard !forbiddenTokens.isEmpty else { return false }
        let tableTokens = Set(SchemaIndex.tokens(in: table.name))
        let overlap = forbiddenTokens.intersection(tableTokens)
        return overlap.count >= max(1, forbiddenTokens.count - 1)
    }
}
