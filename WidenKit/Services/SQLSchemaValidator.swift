import Foundation

public struct SQLSchemaValidationIssue: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case error
        case warning
    }

    public var severity: Severity
    public var message: String

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
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
        validate(SQLReferenceAnalyzer.analyze(sql), against: schema)
    }

    public static func validate(
        _ analysis: SQLReferenceAnalysis,
        against schema: DatabaseSchema
    ) -> SQLSchemaValidationResult {
        let schemaIndex = SchemaLookup(schema: schema)
        var issues: [SQLSchemaValidationIssue] = []
        var scopeSources = Array(repeating: [ResolvedRelationSource](), count: analysis.scopes.count)
        var referencedTables: [String] = []

        for (scopeIndex, scope) in analysis.scopes.enumerated() {
            for relation in scope.relations {
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
                            message: "Schema validation failed: table \(relation.displayName) is not in the selected schema."
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

        if analysis.analysisIncomplete {
            issues.append(
                SQLSchemaValidationIssue(
                    severity: .warning,
                    message: "Schema validation was incomplete for part of this SQL."
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
                        message: "Schema validation failed: qualifier \(qualifier) does not resolve to a selected-schema table."
                    ))
                return
            }
            guard column.name != "*" else { return }
            if !source.definitelyContainsColumn(column.name, schemaIndex: schemaIndex) {
                if source.hasUnknownColumns {
                    return
                }
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: column \(column.name) is not on \(source.displayName)."
                    ))
            }
            return
        }

        if scope.outputAliases.contains(column.name.lowercased()) {
            return
        }
        let localResolution = resolveUnqualified(
            column.name,
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
                    message: "Schema validation failed: column \(column.name) is ambiguous across referenced tables."
                ))
            return
        case .missing:
            break
        }

        var parentIndex = scope.parentIndex
        while let index = parentIndex {
            let parentResolution = resolveUnqualified(
                column.name,
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
                        message: "Schema validation failed: column \(column.name) is ambiguous across referenced tables."
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
                    message: "Schema validation failed: column \(column.name) is not available from the referenced tables."
                ))
        }
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
                        message: "Schema validation failed: qualifier \(qualifier) does not resolve to a selected-schema table."
                    ))
                return
            }
            guard column.name != "*" else { return }
            if !schemaIndex.table(table, containsColumn: column.name) {
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: column \(column.name) is not on \(table.qualifiedName)."
                    ))
            }
            return
        }

        if analysis.outputAliases.contains(column.name.lowercased()) {
            return
        }
        let matchingTables = resolvedRelations.values.filter {
            schemaIndex.table($0, containsColumn: column.name)
        }
        switch matchingTables.count {
        case 0:
            if !resolvedRelations.isEmpty {
                issues.append(
                    SQLSchemaValidationIssue(
                        severity: .error,
                        message: "Schema validation failed: column \(column.name) is not available from the referenced tables."
                    ))
            }
        case 1:
            break
        default:
            issues.append(
                SQLSchemaValidationIssue(
                    severity: .error,
                    message: "Schema validation failed: column \(column.name) is ambiguous across referenced tables."
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
        _ column: String,
        in scopeIndex: Int,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> ColumnResolution {
        var matches = 0
        var hasUnknown = false
        for source in scopeSources[scopeIndex] {
            if source.definitelyContainsColumn(column, schemaIndex: schemaIndex) {
                matches += 1
            } else if source.hasUnknownColumns {
                hasUnknown = true
            }
        }
        switch matches {
        case 0:
            return hasUnknown ? .unknown : .missing
        case 1:
            return .resolved
        default:
            return .ambiguous
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
        if let clarification = businessTermClarification(
            question: question,
            schemaValidation: schemaValidation,
            schema: schema,
            databaseContext: databaseContext
        ) {
            return SQLGenerationResult(
                sql: "",
                explanation: "",
                assumptions: [],
                referencedTables: schemaValidation.referencedTables,
                confidence: 0,
                riskLevel: .high,
                needsClarification: true,
                clarificationQuestion: clarification
            )
        }

        var copy = generation
        copy.referencedTables = schemaValidation.referencedTables
        return copy
    }

    public static func businessTermClarification(
        question: String,
        schemaValidation: SQLSchemaValidationResult,
        schema: DatabaseSchema,
        databaseContext: String
    ) -> String? {
        let questionTokens = Set(SchemaIndex.tokens(in: question))
        guard !questionTokens.intersection(highRiskBusinessTerms).isEmpty else { return nil }
        let contextTokens = Set(SchemaIndex.tokens(in: databaseContext))
        let referencedTableIDs = Set(schemaValidation.referencedTables)
        let referencedTables = schema.tables.filter { referencedTableIDs.contains($0.qualifiedName) }
        let schemaTokens = Set(referencedTables.flatMap { table in
            SchemaIndex.tokens(in: table.name)
                + table.columns.flatMap(columnSemanticTokens)
        })

        if !questionTokens.intersection(winBusinessTerms).isEmpty {
            if !contextTokens.intersection(winDefinitionTokens).isEmpty
                || !schemaTokens.intersection(winDefinitionTokens).isEmpty
            {
                return nil
            }
            return
                "I found match or tool fields, but the selected schema does not define which tool won. What table, column, or condition represents a win?"
        }

        if !contextTokens.intersection(highRiskBusinessTerms.union(supportingBusinessTokens)).isEmpty {
            return nil
        }
        guard schemaTokens.intersection(highRiskBusinessTerms.union(supportingBusinessTokens)).isEmpty
        else { return nil }
        return
            "I need the database-specific definition for this metric before I can write SQL safely. What table, column, or condition defines it?"
    }

    private static let highRiskBusinessTerms: Set<String> = [
        "win", "wins", "winner", "revenue", "active", "churn", "conversion", "success",
        "owner", "retained", "best",
    ]

    private static let winBusinessTerms: Set<String> = [
        "win", "wins", "winner",
    ]

    private static let winDefinitionTokens: Set<String> = [
        "winner", "winning", "won", "win", "wins", "victor", "victory", "lost", "loss",
        "loser",
    ]

    private static let supportingBusinessTokens: Set<String> = [
        "winner", "winning", "won", "win", "wins", "result", "outcome", "verdict",
        "score", "rank", "revenue", "amount", "active", "status", "success",
    ]

    private static func columnSemanticTokens(_ column: ColumnInfo) -> [String] {
        var tokens = SchemaIndex.tokens(in: column.name)
        for constraint in column.valueConstraints ?? [] {
            tokens += constraint.values.flatMap { SchemaIndex.tokens(in: $0) }
            if let expression = constraint.expression {
                tokens += SchemaIndex.tokens(in: expression)
            }
        }
        return tokens
    }
}

public enum GeneratedSQLValidator {
    public static func validate(sql: String, schema: DatabaseSchema) -> SQLValidationResult {
        combine(
            safety: SQLSafetyValidator.validate(sql),
            schemaValidation: SQLSchemaValidator.validate(sql: sql, against: schema)
        )
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
}

private struct SchemaLookup {
    private var tablesByQualifiedName: [String: TableInfo] = [:]
    private var tablesByName: [String: [TableInfo]] = [:]
    private var columnsByTableID: [String: Set<String>] = [:]

    init(schema: DatabaseSchema) {
        for table in schema.tables {
            tablesByQualifiedName[table.qualifiedName.lowercased()] = table
            tablesByName[table.name.lowercased(), default: []].append(table)
            columnsByTableID[table.id] = Set(table.columns.map { $0.name.lowercased() })
        }
    }

    func resolve(_ relation: SQLRelationReference) -> TableInfo? {
        if let schema = relation.schema {
            return tablesByQualifiedName["\(schema).\(relation.name)".lowercased()]
        }
        let matches = tablesByName[relation.name.lowercased()] ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    func table(_ table: TableInfo, containsColumn column: String) -> Bool {
        columnsByTableID[table.id]?.contains(column.lowercased()) == true
    }
}

private enum ColumnResolution {
    case resolved
    case missing
    case ambiguous
    case unknown
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

    func definitelyContainsColumn(_ column: String, schemaIndex: SchemaLookup) -> Bool {
        if let table {
            return schemaIndex.table(table, containsColumn: column)
        }
        guard let cteColumns else { return false }
        return cteColumns.contains(column.lowercased())
    }
}
