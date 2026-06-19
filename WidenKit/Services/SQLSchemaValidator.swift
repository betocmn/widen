import Foundation

public struct SQLSchemaValidationIssue: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case error
        case warning
    }

    public enum Kind: Equatable, Sendable {
        case missingRelation
        case unresolvedQualifier
        case missingColumn
        case ambiguousColumn
        case requiresQuotedIdentifier
        case invalidTemporalComparison
        case analysisIncomplete
        case other
    }

    public var severity: Severity
    public var message: String
    public var kind: Kind
    public var identifier: String?
    public var suggestedIdentifier: String?

    public init(
        severity: Severity,
        message: String,
        kind: Kind = .other,
        identifier: String? = nil,
        suggestedIdentifier: String? = nil
    ) {
        self.severity = severity
        self.message = message
        self.kind = kind
        self.identifier = identifier
        self.suggestedIdentifier = suggestedIdentifier
    }
}

public struct SQLSchemaValidationResult: Equatable, Sendable {
    public var analysis: SQLReferenceAnalysis
    public var issues: [SQLSchemaValidationIssue]
    public var referencedTables: [String]

    public var errors: [String] {
        issues.filter { $0.severity == .error }.map(\.message)
    }

    public var warnings: [String] {
        issues.filter { $0.severity == .warning }.map(\.message)
    }

    public var hasDefiniteErrors: Bool {
        !errors.isEmpty
    }
}

public enum SQLSchemaValidator {
    public static func validate(
        sql: String,
        against schema: DatabaseSchema
    ) -> SQLSchemaValidationResult {
        let analysis = SQLReferenceAnalyzer.analyze(sql)
        return validate(analysis, against: schema, sql: sql)
    }

    public static func validate(
        _ analysis: SQLReferenceAnalysis,
        against schema: DatabaseSchema
    ) -> SQLSchemaValidationResult {
        validate(analysis, against: schema, sql: nil)
    }

    private static func validate(
        _ analysis: SQLReferenceAnalysis,
        against schema: DatabaseSchema,
        sql: String?
    ) -> SQLSchemaValidationResult {
        let schemaIndex = SchemaLookup(schema: schema)
        var issues: [SQLSchemaValidationIssue] = []
        var scopeSources = Array(repeating: [ResolvedRelationSource](), count: analysis.scopes.count)
        var referencedTables: [String] = []

        for (scopeIndex, scope) in analysis.scopes.enumerated() {
            for relation in scope.relations {
                if let derivedColumns = relation.derivedColumns {
                    scopeSources[scopeIndex].append(
                        ResolvedRelationSource.cte(
                            name: relation.alias ?? relation.name,
                            alias: relation.alias,
                            columns: derivedColumns
                        ))
                    continue
                }
                if relation.schema == nil, analysis.cteNames.contains(relation.name.lowercased()) {
                    let cteName = relation.name.lowercased()
                    scopeSources[scopeIndex].append(
                        ResolvedRelationSource.cte(
                            name: cteName,
                            alias: relation.alias,
                            columns: analysis.cteOutputColumns[cteName] ?? nil
                        ))
                    continue
                }
                guard let table = schemaIndex.resolve(relation) else {
                    issues.append(
                        SQLSchemaValidationIssue(
                            severity: .error,
                            message: "Schema validation failed: table \(relation.displayName) is not in the selected schema.",
                            kind: .missingRelation,
                            identifier: relation.displayName
                        ))
                    continue
                }
                referencedTables.append(table.qualifiedName)
                scopeSources[scopeIndex].append(.table(table, alias: relation.alias))
            }
        }

        for (scopeIndex, scope) in analysis.scopes.enumerated() {
            for column in scope.columns {
                validate(
                    column: column,
                    scopeIndex: scopeIndex,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex,
                    issues: &issues
                )
            }
        }

        if analysis.scopes.isEmpty {
            for column in analysis.columns {
                validateLegacy(
                    column: column,
                    analysis: analysis,
                    schemaIndex: schemaIndex,
                    issues: &issues
                )
            }
        }

        if let sql {
            issues.append(
                contentsOf: temporalIntervalComparisonIssues(
                    sql: sql,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex
                ))
        }

        if analysis.analysisIncomplete {
            issues.append(
                SQLSchemaValidationIssue(
                    severity: .warning,
                    message: "Schema validation was incomplete for part of this SQL.",
                    kind: .analysisIncomplete
                ))
        }

        return SQLSchemaValidationResult(
            analysis: analysis,
            issues: issues,
            referencedTables: Array(Set(referencedTables)).sorted()
        )
    }

    private static func validate(
        column: SQLColumnReference,
        scopeIndex: Int,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup,
        issues: inout [SQLSchemaValidationIssue]
    ) {
        let scope = analysis.scopes[scopeIndex]
        if let qualifier = column.qualifier {
            guard let source = resolveSource(
                qualifier,
                from: scopeIndex,
                analysis: analysis,
                scopeSources: scopeSources
            ) else {
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: qualifier \(qualifier) does not resolve to a selected-schema table.",
                        kind: .unresolvedQualifier,
                        identifier: qualifier
                    ))
                return
            }
            guard column.name != "*" else { return }
            if !source.definitelyContainsColumn(column, schemaIndex: schemaIndex) {
                if source.hasUnknownColumns {
                    return
                }
                if let actualName = source.quotedColumnName(for: column, schemaIndex: schemaIndex) {
                    issues.append(
                        quotedIdentifierIssue(
                            column: column,
                            actualName: actualName,
                            source: source.displayName
                        ))
                    return
                }
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: column \(column.name) is not on \(source.displayName).",
                        kind: .missingColumn,
                        identifier: column.name
                    ))
            }
            return
        }

        if scope.outputAliases.contains(column.name.lowercased()) {
            return
        }
        let localResolution = resolveUnqualified(
            column,
            in: scopeIndex,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        )
        switch localResolution {
        case .resolved:
            return
        case .unknown:
            return
        case .ambiguous:
            issues.append(
                SQLSchemaValidationIssue(
                    severity: .error,
                    message: "Schema validation failed: column \(column.name) is ambiguous across referenced tables.",
                    kind: .ambiguousColumn,
                    identifier: column.name
                ))
            return
        case .requiresQuoting(let actualName, let sourceName):
            issues.append(
                quotedIdentifierIssue(column: column, actualName: actualName, source: sourceName)
            )
            return
        case .missing:
            break
        }

        var parentIndex = scope.parentIndex
        while let index = parentIndex {
            let parentResolution = resolveUnqualified(
                column,
                in: index,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            )
            switch parentResolution {
            case .resolved, .unknown:
                return
            case .ambiguous:
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: column \(column.name) is ambiguous across referenced tables.",
                        kind: .ambiguousColumn,
                        identifier: column.name
                    ))
                return
            case .requiresQuoting(let actualName, let sourceName):
                issues.append(
                    quotedIdentifierIssue(
                        column: column,
                        actualName: actualName,
                        source: sourceName
                    ))
                return
            case .missing:
                parentIndex = analysis.scopes[index].parentIndex
            }
        }

        if !scopeSources[scopeIndex].isEmpty {
            issues.append(
                SQLSchemaValidationIssue(
                    severity: .error,
                    message: "Schema validation failed: column \(column.name) is not available from the referenced tables.",
                    kind: .missingColumn,
                    identifier: column.name
                ))
        }
    }

    private static func quotedIdentifierIssue(
        column: SQLColumnReference,
        actualName: String,
        source: String
    ) -> SQLSchemaValidationIssue {
        SQLSchemaValidationIssue(
            severity: .error,
            message:
                "Schema validation failed: column \(column.name) must be quoted as \(quotedIdentifier(actualName)) on \(source).",
            kind: .requiresQuotedIdentifier,
            identifier: column.name,
            suggestedIdentifier: actualName
        )
    }

    private static func validateLegacy(
        column: SQLColumnReference,
        analysis: SQLReferenceAnalysis,
        schemaIndex: SchemaLookup,
        issues: inout [SQLSchemaValidationIssue]
    ) {
        var resolvedRelations: [SQLRelationReference: TableInfo] = [:]
        var aliasToTable: [String: TableInfo] = [:]
        for relation in analysis.relations {
            guard let table = schemaIndex.resolve(relation) else { continue }
            resolvedRelations[relation] = table
            aliasToTable[table.name.lowercased()] = table
            aliasToTable[table.qualifiedName.lowercased()] = table
            if let alias = relation.alias {
                aliasToTable[alias.lowercased()] = table
            }
        }

        if let qualifier = column.qualifier {
            guard let table = aliasToTable[qualifier.lowercased()] else {
                if analysis.cteNames.contains(qualifier.lowercased()) {
                    return
                }
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: qualifier \(qualifier) does not resolve to a selected-schema table.",
                        kind: .unresolvedQualifier,
                        identifier: qualifier
                    ))
                return
            }
            guard column.name != "*" else { return }
            if !schemaIndex.table(table, containsColumn: column) {
                if let actualName = schemaIndex.actualColumnName(on: table, foldedName: column.name) {
                    issues.append(
                        quotedIdentifierIssue(
                            column: column,
                            actualName: actualName,
                            source: table.qualifiedName
                        ))
                    return
                }
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: column \(column.name) is not on \(table.qualifiedName).",
                        kind: .missingColumn,
                        identifier: column.name
                    ))
            }
            return
        }

        if analysis.outputAliases.contains(column.name.lowercased()) {
            return
        }
        let matchingTables = resolvedRelations.values.filter {
            schemaIndex.table($0, containsColumn: column)
        }
        switch matchingTables.count {
        case 0:
            if !resolvedRelations.isEmpty {
                if let quotedMatch = resolvedRelations.values.compactMap({
                    table -> (actualName: String, source: String)? in
                    guard let actualName = schemaIndex.actualColumnName(
                        on: table,
                        foldedName: column.name
                    ) else { return nil }
                    return (actualName, table.qualifiedName)
                }).first {
                    issues.append(
                        quotedIdentifierIssue(
                            column: column,
                            actualName: quotedMatch.actualName,
                            source: quotedMatch.source
                        ))
                    return
                }
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: column \(column.name) is not available from the referenced tables.",
                        kind: .missingColumn,
                        identifier: column.name
                    ))
            }
        case 1:
            break
        default:
            issues.append(
                SQLSchemaValidationIssue(
                    severity: .error,
                    message: "Schema validation failed: column \(column.name) is ambiguous across referenced tables.",
                    kind: .ambiguousColumn,
                    identifier: column.name
                ))
        }
    }

    private static func resolveSource(
        _ qualifier: String,
        from scopeIndex: Int,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]]
    ) -> ResolvedRelationSource? {
        var index: Int? = scopeIndex
        while let current = index {
            if let source = scopeSources[current].first(where: { $0.matches(qualifier) }) {
                return source
            }
            index = analysis.scopes[current].parentIndex
        }
        return nil
    }

    private static func resolveUnqualified(
        _ column: SQLColumnReference,
        in scopeIndex: Int,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> ColumnResolution {
        var matches = 0
        var hasUnknown = false
        var quotedMatches: [(actualName: String, sourceName: String)] = []
        for source in scopeSources[scopeIndex] {
            if source.definitelyContainsColumn(column, schemaIndex: schemaIndex) {
                matches += 1
            } else if source.hasUnknownColumns {
                hasUnknown = true
            } else if let actualName = source.quotedColumnName(for: column, schemaIndex: schemaIndex) {
                quotedMatches.append((actualName, source.displayName))
            }
        }
        switch matches {
        case 0:
            if let quotedMatch = quotedMatches.first, quotedMatches.count == 1 {
                return .requiresQuoting(
                    actualName: quotedMatch.actualName,
                    sourceName: quotedMatch.sourceName
                )
            }
            return hasUnknown ? .unknown : .missing
        case 1:
            return .resolved
        default:
            return .ambiguous
        }
    }

    private static func temporalIntervalComparisonIssues(
        sql: String,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> [SQLSchemaValidationIssue] {
        let tokens = SQLToken.tokenize(sql)
        guard !tokens.isEmpty else { return [] }

        var issues: [SQLSchemaValidationIssue] = []
        var reported = Set<String>()
        var index = 0
        while index < tokens.count {
            guard let comparison = comparisonOperator(at: index, tokens: tokens) else {
                index += 1
                continue
            }

            if isIntervalLiteral(startingAt: comparison.nextIndex, tokens: tokens),
                let identifier = identifierExpression(endingAt: index - 1, tokens: tokens)
            {
                appendTemporalIntervalIssue(
                    for: identifier,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex,
                    reported: &reported,
                    issues: &issues
                )
            }

            if isIntervalLiteral(endingAt: index - 1, tokens: tokens),
                let identifier = identifierExpression(startingAt: comparison.nextIndex, tokens: tokens)
            {
                appendTemporalIntervalIssue(
                    for: identifier,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex,
                    reported: &reported,
                    issues: &issues
                )
            }

            index = comparison.nextIndex
        }

        return issues
    }

    private static func appendTemporalIntervalIssue(
        for identifier: IdentifierExpression,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup,
        reported: inout Set<String>,
        issues: inout [SQLSchemaValidationIssue]
    ) {
        let columns = resolvedColumns(
            for: identifier,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        )
        guard let temporalColumn = columns.first(where: isDateOrTimeColumn) else { return }
        let key = "\(temporalColumn.id):\(identifier.displayName.lowercased())"
        guard reported.insert(key).inserted else { return }

        issues.append(
            SQLSchemaValidationIssue(
                severity: .error,
                message:
                    "Schema validation failed: column \(identifier.displayName) is \(temporalColumn.dataType.lowercased()) and cannot be compared directly to an INTERVAL. Compare it to a date or timestamp expression such as NOW() - INTERVAL '7 days'.",
                kind: .invalidTemporalComparison,
                identifier: identifier.name
            ))
    }

    private static func resolvedColumns(
        for identifier: IdentifierExpression,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> [ColumnInfo] {
        if let qualifier = identifier.qualifier {
            var columns: [ColumnInfo] = []
            for scopeIndex in analysis.scopes.indices {
                guard let source = resolveSource(
                    qualifier,
                    from: scopeIndex,
                    analysis: analysis,
                    scopeSources: scopeSources
                ),
                    let table = source.table,
                    let column = schemaIndex.column(
                        on: table,
                        named: identifier.name,
                        isQuoted: identifier.isQuoted
                    )
                else { continue }
                columns.append(column)
            }
            return deduplicatedColumns(columns)
        }

        let columns = scopeSources
            .flatMap { $0 }
            .compactMap { source -> ColumnInfo? in
                guard let table = source.table else { return nil }
                return schemaIndex.column(
                    on: table,
                    named: identifier.name,
                    isQuoted: identifier.isQuoted
                )
            }
        return deduplicatedColumns(columns)
    }

    private static func comparisonOperator(
        at index: Int,
        tokens: [SQLToken]
    ) -> (text: String, nextIndex: Int)? {
        guard let token = tokens[safe: index] else { return nil }
        switch token.text {
        case "=":
            return ("=", index + 1)
        case "<":
            if tokens[safe: index + 1]?.text == "=" {
                return ("<=", index + 2)
            }
            if tokens[safe: index + 1]?.text == ">" {
                return ("<>", index + 2)
            }
            return ("<", index + 1)
        case ">":
            if tokens[safe: index + 1]?.text == "=" {
                return (">=", index + 2)
            }
            return (">", index + 1)
        case "!":
            if tokens[safe: index + 1]?.text == "=" {
                return ("!=", index + 2)
            }
            return nil
        default:
            return nil
        }
    }

    private static func isIntervalLiteral(startingAt index: Int, tokens: [SQLToken]) -> Bool {
        tokens[safe: index]?.normalized == "interval"
            && tokens[safe: index + 1]?.kind == .string
    }

    private static func isIntervalLiteral(endingAt index: Int, tokens: [SQLToken]) -> Bool {
        index - 1 >= 0
            && tokens[safe: index - 1]?.normalized == "interval"
            && tokens[safe: index]?.kind == .string
    }

    private static func identifierExpression(
        endingAt index: Int,
        tokens: [SQLToken]
    ) -> IdentifierExpression? {
        guard index >= 0, tokens[safe: index]?.isIdentifierLike == true else { return nil }
        var parts: [(value: String, isQuoted: Bool)] = []
        var current = index
        while current >= 0, let token = tokens[safe: current], token.isIdentifierLike {
            parts.insert((token.identifierValue, token.kind == .quotedIdentifier), at: 0)
            guard current >= 2,
                tokens[safe: current - 1]?.text == ".",
                tokens[safe: current - 2]?.isIdentifierLike == true
            else { break }
            current -= 2
        }
        return IdentifierExpression(parts: parts)
    }

    private static func identifierExpression(
        startingAt index: Int,
        tokens: [SQLToken]
    ) -> IdentifierExpression? {
        guard tokens[safe: index]?.isIdentifierLike == true else { return nil }
        var parts: [(value: String, isQuoted: Bool)] = []
        var current = index
        while let token = tokens[safe: current], token.isIdentifierLike {
            parts.append((token.identifierValue, token.kind == .quotedIdentifier))
            guard tokens[safe: current + 1]?.text == ".",
                tokens[safe: current + 2]?.isIdentifierLike == true
            else { break }
            current += 2
        }
        return IdentifierExpression(parts: parts)
    }

    private static func isDateOrTimeColumn(_ column: ColumnInfo) -> Bool {
        let type = column.dataType.lowercased()
        guard !type.contains("interval") else { return false }
        return type == "date"
            || type.hasPrefix("timestamp")
            || type.hasPrefix("time ")
            || type == "time"
            || type.contains("timestamp")
    }

    private static func deduplicatedColumns(_ columns: [ColumnInfo]) -> [ColumnInfo] {
        var seen = Set<String>()
        return columns.filter { seen.insert($0.id).inserted }
    }
}

private struct IdentifierExpression: Equatable {
    var qualifier: String?
    var name: String
    var isQuoted: Bool

    var displayName: String {
        if let qualifier {
            return "\(qualifier).\(name)"
        }
        return name
    }

    init?(parts: [(value: String, isQuoted: Bool)]) {
        guard let last = parts.last else { return nil }
        self.name = last.value
        self.isQuoted = last.isQuoted
        if parts.count > 1 {
            self.qualifier = parts.dropLast().map(\.value).joined(separator: ".")
        } else {
            self.qualifier = nil
        }
    }
}

public enum GeneratedSQLPostprocessor {
    public static func enriched(
        _ generation: SQLGenerationResult,
        question: String,
        schema: DatabaseSchema,
        databaseContext: String
    ) -> SQLGenerationResult {
        guard !generation.needsClarification else { return generation }
        let sql = generation.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return generation }

        let schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)
        var copy = generation
        copy.referencedTables = schemaValidation.referencedTables
        if !schemaValidation.hasDefiniteErrors,
            let clarification = undefinedRequestTermClarification(
                question: question,
                referencedTables: schemaValidation.referencedTables,
                schema: schema,
                databaseContext: databaseContext
            )
        {
            copy.sql = ""
            copy.explanation = clarification
            copy.needsClarification = true
            copy.clarificationQuestion = clarification
            copy.confidence = min(copy.confidence, 0.2)
            copy.riskLevel = .medium
        }
        return copy
    }

    private static func undefinedRequestTermClarification(
        question: String,
        referencedTables: [String],
        schema: DatabaseSchema,
        databaseContext: String
    ) -> String? {
        guard hasMetricIntent(question) else { return nil }
        let availableTokens = referencedSchemaTokens(
            referencedTables: referencedTables,
            schema: schema
        ).union(Set(SchemaIndex.tokens(in: databaseContext)))

        let terms = meaningfulRequestWords(question)
        let unresolved = terms.filter { word in
            let variants = SchemaIndex.tokens(in: word)
            guard !variants.isEmpty else { return false }
            return !variants.contains { variant in
                tokenSet(availableTokens, containsRelatedTo: variant)
            }
        }

        guard let first = unresolved.first else { return nil }
        return "What column, condition, or table defines \"\(first)\" for this question?"
    }

    private static func referencedSchemaTokens(
        referencedTables: [String],
        schema: DatabaseSchema
    ) -> Set<String> {
        let referenced = Set(referencedTables.map { $0.lowercased() })
        guard !referenced.isEmpty else { return [] }

        var tokens = Set<String>()
        for table in schema.tables where referenced.contains(table.qualifiedName.lowercased()) {
            tokens.formUnion(SchemaIndex.tokens(in: table.schema))
            tokens.formUnion(SchemaIndex.tokens(in: table.name))
            for column in table.columns {
                tokens.formUnion(SchemaIndex.tokens(in: column.name))
                if let udtName = column.udtName {
                    tokens.formUnion(SchemaIndex.tokens(in: udtName))
                }
                for constraint in column.valueConstraints ?? [] {
                    for value in constraint.values {
                        tokens.formUnion(SchemaIndex.tokens(in: value))
                    }
                    if let expression = constraint.expression {
                        tokens.formUnion(SchemaIndex.tokens(in: expression))
                    }
                    if let constraintName = constraint.constraintName {
                        tokens.formUnion(SchemaIndex.tokens(in: constraintName))
                    }
                }
            }
        }
        return tokens
    }

    private static func meaningfulRequestWords(_ question: String) -> [String] {
        let words = rawWords(in: question)
        var seen = Set<String>()
        return words.filter { word in
            let variants = SchemaIndex.tokens(in: word)
            guard variants.contains(where: { !$0.allSatisfy(\.isNumber) }) else { return false }
            guard !variants.contains(where: requestStopWords.contains) else { return false }
            guard !variants.contains(where: metricOperatorStopWords.contains) else { return false }
            return seen.insert(word).inserted
        }
    }

    private static func rawWords(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func hasMetricIntent(_ question: String) -> Bool {
        let tokens = Set(SchemaIndex.tokens(in: question))
        return !tokens.intersection(metricIntentWords).isEmpty
    }

    private static func tokenSet(_ tokens: Set<String>, containsRelatedTo queryToken: String) -> Bool {
        guard !queryToken.isEmpty else { return false }
        if tokens.contains(queryToken) { return true }
        guard queryToken.count >= 3 else { return false }
        return tokens.contains { token in
            token.hasPrefix(queryToken) || (queryToken.hasPrefix(token) && token.count >= 3)
        }
    }

    private static let metricIntentWords: Set<String> = [
        "average", "avg", "best", "bottom", "count", "highest", "least", "lowest", "many",
        "max", "maximum", "min", "minimum", "most", "much", "number", "percent", "percentage",
        "rank", "rate", "ratio", "sum", "top", "total", "worst",
    ]

    private static let metricOperatorStopWords: Set<String> = [
        "average", "avg", "bottom", "count", "highest", "least", "lowest", "many", "max",
        "maximum", "min", "minimum", "most", "much", "number", "percent", "percentage",
        "rank", "rate", "ratio", "sum", "top", "total",
    ]

    private static let requestStopWords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any",
        "are", "as", "at", "back", "be", "been", "before", "being", "between", "bottom",
        "but", "by", "can", "could", "current", "day", "days", "did", "do", "does", "each",
        "for", "from", "get", "getting", "give", "got", "group", "had", "has", "have", "he",
        "her", "here", "him", "his", "hour", "hours", "how", "i", "in", "into", "is", "it",
        "last", "latest", "least", "limit", "list", "me", "minute", "minutes", "month",
        "months", "most", "my", "newest", "next", "not", "of", "oldest", "on", "or", "our",
        "over", "per", "please", "recent", "return", "select", "she", "show", "since",
        "sort", "that", "the", "their", "them", "then", "there", "these", "they", "this",
        "those", "to", "today", "top", "under", "up", "us", "was", "we", "week", "weeks",
        "were", "what", "when", "where", "which", "who", "whom", "whose", "why", "with",
        "would", "year", "years", "you", "your",
    ]
}

public enum GeneratedSQLValidator {
    public static func validate(sql: String, schema: DatabaseSchema) -> SQLValidationResult {
        combine(
            safety: SQLSafetyValidator.validate(sql),
            schemaValidation: SQLSchemaValidator.validate(sql: sql, against: schema)
        )
    }

    public static func repairQuotedIdentifiers(sql: String, schema: DatabaseSchema) -> String? {
        let schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)
        let replacements = schemaValidation.issues.reduce(into: [String: String]()) {
            result,
            issue in
            guard issue.kind == .requiresQuotedIdentifier,
                let identifier = issue.identifier,
                let suggestedIdentifier = issue.suggestedIdentifier
            else { return }
            result[identifier.lowercased()] = suggestedIdentifier
        }
        guard !replacements.isEmpty else { return nil }

        let repaired = rewriteUnquotedIdentifiers(in: sql, replacements: replacements)
        guard repaired != sql,
            validate(sql: repaired, schema: schema).isValid
        else { return nil }
        return repaired
    }

    public static func combine(
        safety: SQLValidationResult,
        schemaValidation: SQLSchemaValidationResult
    ) -> SQLValidationResult {
        guard safety.isValid else { return safety }
        let errors = safety.errors + schemaValidation.errors
        return SQLValidationResult(
            isValid: errors.isEmpty,
            normalizedSQL: errors.isEmpty ? safety.normalizedSQL : nil,
            errors: errors,
            warnings: safety.warnings + schemaValidation.warnings,
            hasLimit: safety.hasLimit,
            kind: safety.kind,
            requiresConfirmation: safety.requiresConfirmation
        )
    }

    private static func rewriteUnquotedIdentifiers(
        in sql: String,
        replacements: [String: String]
    ) -> String {
        let characters = Array(sql)
        var output = ""
        var index = 0

        func char(at offset: Int) -> Character? {
            offset < characters.count ? characters[offset] : nil
        }

        func appendRange(_ range: Range<Int>) {
            output += String(characters[range])
        }

        while index < characters.count {
            let character = characters[index]
            if character == "-", char(at: index + 1) == "-" {
                let start = index
                index += 2
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
                appendRange(start..<index)
                continue
            }
            if character == "/", char(at: index + 1) == "*" {
                let start = index
                index += 2
                while index + 1 < characters.count,
                    !(characters[index] == "*" && characters[index + 1] == "/")
                {
                    index += 1
                }
                index = min(characters.count, index + 2)
                appendRange(start..<index)
                continue
            }
            if character == "$" {
                let start = index
                index += 1
                while index < characters.count,
                    characters[index].isLetter
                        || characters[index].isNumber
                        || characters[index] == "_"
                {
                    index += 1
                }
                if index < characters.count, characters[index] == "$" {
                    let delimiter = String(characters[start...index])
                    index += 1
                    while index < characters.count {
                        if String(characters[index..<min(characters.count, index + delimiter.count)])
                            == delimiter
                        {
                            index += delimiter.count
                            break
                        }
                        index += 1
                    }
                    appendRange(start..<min(index, characters.count))
                    continue
                }
                appendRange(start..<index)
                continue
            }
            if character == "'" {
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == "'" {
                        if char(at: index + 1) == "'" {
                            index += 2
                        } else {
                            index += 1
                            break
                        }
                    } else {
                        index += 1
                    }
                }
                appendRange(start..<min(index, characters.count))
                continue
            }
            if character == "\"" {
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == "\"" {
                        if char(at: index + 1) == "\"" {
                            index += 2
                        } else {
                            index += 1
                            break
                        }
                    } else {
                        index += 1
                    }
                }
                appendRange(start..<min(index, characters.count))
                continue
            }
            if character.isLetter || character == "_" {
                let start = index
                index += 1
                while index < characters.count,
                    characters[index].isLetter
                        || characters[index].isNumber
                        || characters[index] == "_"
                        || characters[index] == "$"
                {
                    index += 1
                }
                let identifier = String(characters[start..<index])
                if let replacement = replacements[identifier.lowercased()] {
                    output += quotedIdentifier(replacement)
                } else {
                    output += identifier
                }
                continue
            }

            output.append(character)
            index += 1
        }

        return output
    }
}

private struct SchemaLookup {
    private var tablesByExactQualifiedName: [String: TableInfo] = [:]
    private var tablesByExactName: [String: [TableInfo]] = [:]
    private var columnsByTableID: [String: Set<String>] = [:]
    private var foldedColumnsByTableID: [String: [String: String]] = [:]

    init(schema: DatabaseSchema) {
        for table in schema.tables {
            tablesByExactQualifiedName[table.qualifiedName] = table
            tablesByExactName[table.name, default: []].append(table)
            columnsByTableID[table.id] = Set(table.columns.map(\.name))
            var foldedColumns: [String: String] = [:]
            for column in table.columns {
                foldedColumns[column.name.lowercased()] = column.name
            }
            foldedColumnsByTableID[table.id] = foldedColumns
        }
    }

    func resolve(_ relation: SQLRelationReference) -> TableInfo? {
        if let schema = relation.schema {
            let schemaName = relation.schemaIsQuoted ? schema : schema.lowercased()
            let tableName = relation.nameIsQuoted ? relation.name : relation.name.lowercased()
            return tablesByExactQualifiedName["\(schemaName).\(tableName)"]
        }
        let tableName = relation.nameIsQuoted ? relation.name : relation.name.lowercased()
        let matches = tablesByExactName[tableName] ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    func table(_ table: TableInfo, containsColumn column: SQLColumnReference) -> Bool {
        self.table(table, containsColumn: column.name, isQuoted: column.isQuoted)
    }

    func table(_ table: TableInfo, containsColumn column: String, isQuoted: Bool = false) -> Bool {
        let resolvedName = isQuoted ? column : column.lowercased()
        return columnsByTableID[table.id]?.contains(resolvedName) == true
    }

    func actualColumnName(on table: TableInfo, foldedName: String) -> String? {
        guard !foldedName.isEmpty else { return nil }
        let folded = foldedName.lowercased()
        guard let actualName = foldedColumnsByTableID[table.id]?[folded],
            actualName != folded
        else { return nil }
        return actualName
    }

    func column(on table: TableInfo, named name: String, isQuoted: Bool) -> ColumnInfo? {
        if isQuoted {
            return table.columns.first { $0.name == name }
        }
        let folded = name.lowercased()
        if let column = table.columns.first(where: { $0.name == folded }) {
            return column
        }
        guard let actualName = actualColumnName(on: table, foldedName: name) else { return nil }
        return table.columns.first { $0.name == actualName }
    }
}

private enum ColumnResolution {
    case resolved
    case missing
    case ambiguous
    case unknown
    case requiresQuoting(actualName: String, sourceName: String)
}

private struct ResolvedRelationSource {
    var displayName: String
    var names: Set<String>
    var table: TableInfo?
    var cteColumns: Set<String>?
    var hasUnknownColumns: Bool

    static func table(_ table: TableInfo, alias: String?) -> ResolvedRelationSource {
        var names = Set([table.name.lowercased(), table.qualifiedName.lowercased()])
        if let alias {
            names.insert(alias.lowercased())
        }
        return ResolvedRelationSource(
            displayName: table.qualifiedName,
            names: names,
            table: table,
            cteColumns: nil,
            hasUnknownColumns: false
        )
    }

    static func cte(
        name: String,
        alias: String?,
        columns: Set<String>?
    ) -> ResolvedRelationSource {
        var names = Set([name.lowercased()])
        if let alias {
            names.insert(alias.lowercased())
        }
        return ResolvedRelationSource(
            displayName: name,
            names: names,
            table: nil,
            cteColumns: columns,
            hasUnknownColumns: columns == nil
        )
    }

    func matches(_ qualifier: String) -> Bool {
        names.contains(qualifier.lowercased())
    }

    func definitelyContainsColumn(_ column: SQLColumnReference, schemaIndex: SchemaLookup) -> Bool {
        if let table {
            return schemaIndex.table(table, containsColumn: column)
        }
        guard let cteColumns else { return false }
        return cteColumns.contains(column.name.lowercased())
    }

    func quotedColumnName(
        for column: SQLColumnReference,
        schemaIndex: SchemaLookup
    ) -> String? {
        guard !column.isQuoted, let table else { return nil }
        return schemaIndex.actualColumnName(on: table, foldedName: column.name)
    }
}

private func quotedIdentifier(_ identifier: String) -> String {
    "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
