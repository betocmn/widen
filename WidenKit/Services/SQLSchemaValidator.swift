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
        case missingBaseColumn
        case missingDerivedColumn
        case columnNotProjectedByCTE
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
        let upsertTargetSources = analysis.upsertTargetRelations.compactMap { relation in
            schemaIndex.resolve(relation).map {
                ResolvedRelationSource.table(
                    $0,
                    alias: nil,
                    role: relation.role,
                    startOffset: relation.startOffset
                )
            }
        }

        for (scopeIndex, scope) in analysis.scopes.enumerated() {
            for relation in scope.relations {
                if relation.isDerived {
                    let cteName =
                        relation.schema == nil
                        ? analysis.cteNames.first(where: {
                            $0.matches(name: relation.name, isQuoted: relation.nameIsQuoted)
                        })
                        : nil
                    let columns =
                        relation.derivedColumns
                        ?? cteName.flatMap {
                            derivedColumns(
                                from: analysis.cteOutputRelations[$0],
                                schemaIndex: schemaIndex
                            )
                        }
                        ?? derivedColumns(
                            from: relation.derivedOutputRelations,
                            schemaIndex: schemaIndex
                        )
                    scopeSources[scopeIndex].append(
                        ResolvedRelationSource.cte(
                            name: relation.alias ?? relation.name,
                            nameIsQuoted: relation.alias == nil && relation.nameIsQuoted,
                            alias: relation.alias,
                            aliasIsQuoted: relation.aliasIsQuoted,
                            columns: columns,
                            kind: cteName == nil ? .derived : .cte,
                            role: relation.role,
                            startOffset: relation.startOffset
                        ))
                    continue
                }
                if relation.schema == nil,
                    let cteName = analysis.cteNames.first(where: {
                        $0.matches(name: relation.name, isQuoted: relation.nameIsQuoted)
                    })
                {
                    let columns =
                        analysis.cteOutputColumns[cteName] ?? nil
                        ?? derivedColumns(
                            from: analysis.cteOutputRelations[cteName],
                            schemaIndex: schemaIndex
                        )
                    scopeSources[scopeIndex].append(
                        ResolvedRelationSource.cte(
                            name: cteName.name,
                            nameIsQuoted: cteName.isQuoted,
                            alias: relation.alias,
                            aliasIsQuoted: relation.aliasIsQuoted,
                            columns: columns,
                            kind: .cte,
                            role: relation.role,
                            startOffset: relation.startOffset
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
                    scopeSources[scopeIndex].append(.unresolved(relation))
                    continue
                }
                referencedTables.append(table.qualifiedName)
                scopeSources[scopeIndex].append(
                    .table(
                        table,
                        alias: relation.alias,
                        aliasIsQuoted: relation.aliasIsQuoted,
                        role: relation.role,
                        startOffset: relation.startOffset
                    )
                )
            }
        }

        for (scopeIndex, scope) in analysis.scopes.enumerated() {
            for column in scope.columns {
                validate(
                    column: column,
                    scopeIndex: scopeIndex,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    upsertTargetSources: upsertTargetSources,
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
        upsertTargetSources: [ResolvedRelationSource],
        schemaIndex: SchemaLookup,
        issues: inout [SQLSchemaValidationIssue]
    ) {
        let scope = analysis.scopes[scopeIndex]
        if column.context == .insertTarget {
            validateTargetColumn(
                column: column,
                rolePriority: [.insertTarget],
                scopeIndex: scopeIndex,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex,
                issues: &issues
            )
            return
        }
        if column.context == .joinUsing {
            validateJoinUsingColumn(
                column: column,
                scope: scope,
                scopeIndex: scopeIndex,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex,
                issues: &issues
            )
            return
        }
        if column.context == .updateSetTarget {
            validateTargetColumn(
                column: column,
                rolePriority: [.updateTarget, .insertTarget],
                scopeIndex: scopeIndex,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex,
                issues: &issues
            )
            return
        }
        let excludedRoles: Set<SQLRelationReference.Role> =
            column.context == .insertValuesExpression ? [.insertTarget] : []
        if let qualifier = column.qualifier {
            let source = resolveSource(
                qualifier,
                isQuoted: column.qualifierIsQuoted,
                quotedAsSingleIdentifier: column.qualifierIsSingleQuotedIdentifier,
                excludingRoles: excludedRoles,
                from: scopeIndex,
                analysis: analysis,
                scopeSources: scopeSources
            ) ?? resolveExcludedSource(
                qualifier,
                upsertTargetSources: upsertTargetSources
            )
            guard let source else {
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
                    missingColumnIssue(column: column, source: source)
                )
            }
            return
        }

        let localResolution = resolveUnqualified(
            column,
            in: scopeIndex,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex,
            excludingRoles: excludedRoles
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
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex,
                excludingRoles: excludedRoles
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

        issues.append(
            missingUnqualifiedColumnIssue(
                column: column,
                scopeSources: scopeSources[safe: scopeIndex] ?? []
            ))
    }

    private static func validateTargetColumn(
        column: SQLColumnReference,
        rolePriority: [SQLRelationReference.Role],
        scopeIndex: Int,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup,
        issues: inout [SQLSchemaValidationIssue]
    ) {
        guard let sources = scopeSources[safe: scopeIndex],
            let source = rolePriority.lazy.compactMap({ role in
                sources.first { $0.role == role }
            }).first
        else {
            return
        }
        guard !source.definitelyContainsColumn(column, schemaIndex: schemaIndex) else { return }
        if source.hasUnknownColumns {
            return
        }
        if let actualName = source.quotedColumnName(for: column, schemaIndex: schemaIndex) {
            issues.append(
                quotedIdentifierIssue(
                    column: column,
                    actualName: actualName,
                    source: source.displayName
                )
            )
            return
        }
        issues.append(
            missingColumnIssue(column: column, source: source)
        )
    }

    private static func validateJoinUsingColumn(
        column: SQLColumnReference,
        scope: SQLReferenceScope,
        scopeIndex: Int,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup,
        issues: inout [SQLSchemaValidationIssue]
    ) {
        guard let sources = scopeSources[safe: scopeIndex] else { return }
        let sourceRelations = sources.filter { $0.role == .source }
        guard let groupOffset = column.joinUsingGroupStartOffset else {
            if joinUsingColumn(column, isAvailableFromAtLeastTwo: sourceRelations, schemaIndex: schemaIndex) {
                return
            }
            appendMissingJoinUsingIssue(column: column, issues: &issues)
            return
        }

        guard let rightSourceIndex = sourceRelations.lastIndex(where: { source in
            guard let startOffset = source.startOffset else { return false }
            return startOffset < groupOffset
        }),
            rightSourceIndex > sourceRelations.startIndex
        else {
            appendMissingJoinUsingIssue(column: column, issues: &issues)
            return
        }

        let leftSources = sourceRelations.prefix(upTo: rightSourceIndex)
        let rightSource = sourceRelations[rightSourceIndex]
        let leftContains = leftSources.contains {
            $0.definitelyContainsColumn(column, schemaIndex: schemaIndex) || $0.hasUnknownColumns
        }
        let rightContains =
            rightSource.definitelyContainsColumn(column, schemaIndex: schemaIndex)
            || rightSource.hasUnknownColumns
        if leftContains && rightContains {
            return
        }
        appendMissingJoinUsingIssue(column: column, issues: &issues)
    }

    private static func joinUsingColumn(
        _ column: SQLColumnReference,
        isAvailableFromAtLeastTwo sources: [ResolvedRelationSource],
        schemaIndex: SchemaLookup
    ) -> Bool {
        var matches = 0
        var hasUnknown = false
        for source in sources {
            if source.definitelyContainsColumn(column, schemaIndex: schemaIndex) {
                matches += 1
            } else if source.hasUnknownColumns {
                hasUnknown = true
            }
        }
        return matches >= 2 || hasUnknown
    }

    private static func appendMissingJoinUsingIssue(
        column: SQLColumnReference,
        issues: inout [SQLSchemaValidationIssue]
    ) {
        issues.append(
            SQLSchemaValidationIssue(
                severity: .error,
                message: "Schema validation failed: JOIN USING column \(column.name) is not available from both joined relations.",
                kind: .missingBaseColumn,
                identifier: column.name
            ))
    }

    private static func missingColumnIssue(
        column: SQLColumnReference,
        source: ResolvedRelationSource
    ) -> SQLSchemaValidationIssue {
        switch source.kind {
        case .table:
            return SQLSchemaValidationIssue(
                severity: .error,
                message: "Schema validation failed: column \(column.name) is not on \(source.displayName).",
                kind: .missingBaseColumn,
                identifier: column.name
            )
        case .cte:
            return SQLSchemaValidationIssue(
                severity: .error,
                message:
                    "Schema validation failed: column \(column.name) is not an output column of \(source.displayName); project it from the CTE or do not reference it outside the CTE.",
                kind: .columnNotProjectedByCTE,
                identifier: column.name
            )
        case .derived:
            return SQLSchemaValidationIssue(
                severity: .error,
                message:
                    "Schema validation failed: column \(column.name) is not an output column of \(source.displayName); project it from the derived query or do not reference it outside the derived query.",
                kind: .missingDerivedColumn,
                identifier: column.name
            )
        case .unresolved:
            return SQLSchemaValidationIssue(
                severity: .error,
                message: "Schema validation failed: column \(column.name) is not available from the referenced tables.",
                kind: .missingColumn,
                identifier: column.name
            )
        }
    }

    private static func missingUnqualifiedColumnIssue(
        column: SQLColumnReference,
        scopeSources: [ResolvedRelationSource]
    ) -> SQLSchemaValidationIssue {
        let knownSources = scopeSources.filter { !$0.hasUnknownColumns }
        if knownSources.count == 1, let source = knownSources.first {
            return missingColumnIssue(column: column, source: source)
        }
        if !knownSources.isEmpty, knownSources.allSatisfy(\.isDerivedLike) {
            return SQLSchemaValidationIssue(
                severity: .error,
                message:
                    "Schema validation failed: column \(column.name) is not an output column of the referenced derived relations.",
                kind: knownSources.contains { $0.kind == .cte }
                    ? .columnNotProjectedByCTE : .missingDerivedColumn,
                identifier: column.name
            )
        }
        if knownSources.contains(where: { $0.kind == .table }) {
            return SQLSchemaValidationIssue(
                severity: .error,
                message: "Schema validation failed: column \(column.name) is not available from the referenced base tables.",
                kind: .missingBaseColumn,
                identifier: column.name
            )
        }
        return SQLSchemaValidationIssue(
            severity: .error,
            message: "Schema validation failed: column \(column.name) is not available from the referenced tables.",
            kind: .missingColumn,
            identifier: column.name
        )
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
            if let alias = relation.alias {
                aliasToTable[alias.lowercased()] = table
            } else {
                aliasToTable[table.name.lowercased()] = table
                aliasToTable[table.qualifiedName.lowercased()] = table
            }
        }

        if let qualifier = column.qualifier {
            guard let table = aliasToTable[qualifier.lowercased()] else {
                if analysis.cteNames.contains(where: {
                    $0.matches(name: qualifier, isQuoted: column.qualifierIsQuoted)
                }) {
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
                        kind: .missingBaseColumn,
                        identifier: column.name
                    ))
            }
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
                        message: "Schema validation failed: column \(column.name) is not available from the referenced base tables.",
                        kind: .missingBaseColumn,
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
        isQuoted: Bool = false,
        quotedAsSingleIdentifier: Bool = false,
        excludingRoles: Set<SQLRelationReference.Role> = [],
        from scopeIndex: Int,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]]
    ) -> ResolvedRelationSource? {
        var index: Int? = scopeIndex
        while let current = index {
            if let source = scopeSources[current].first(where: {
                !excludingRoles.contains($0.role)
                    && $0.matches(
                        qualifier,
                        isQuoted: isQuoted,
                        quotedAsSingleIdentifier: quotedAsSingleIdentifier
                    )
            }) {
                return source
            }
            index = analysis.scopes[current].parentIndex
        }
        return nil
    }

    private static func resolveExcludedSource(
        _ qualifier: String,
        upsertTargetSources: [ResolvedRelationSource]
    ) -> ResolvedRelationSource? {
        guard qualifier.lowercased() == "excluded" else { return nil }
        return upsertTargetSources.count == 1 ? upsertTargetSources[0] : nil
    }

    private static func resolveUnqualified(
        _ column: SQLColumnReference,
        in scopeIndex: Int,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup,
        excludingRoles: Set<SQLRelationReference.Role> = []
    ) -> ColumnResolution {
        var matches = 0
        var hasUnknown = false
        var quotedMatches: [(actualName: String, sourceName: String)] = []
        for source in scopeSources[scopeIndex] {
            guard !excludingRoles.contains(source.role) else { continue }
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
            if isMergedUsingColumn(column, in: analysis.scopes[scopeIndex], matchCount: matches)
                || isMergedNaturalJoinColumn(
                    column,
                    in: analysis.scopes[scopeIndex],
                    sources: scopeSources[scopeIndex],
                    schemaIndex: schemaIndex
                )
            {
                return .resolved
            }
            return .ambiguous
        }
    }

    private static func isMergedUsingColumn(
        _ column: SQLColumnReference,
        in scope: SQLReferenceScope,
        matchCount: Int
    ) -> Bool {
        let mergedJoinCount = scope.columns.filter { usingColumn in
            guard usingColumn.context == .joinUsing else { return false }
            if usingColumn.isQuoted || column.isQuoted {
                return usingColumn.isQuoted == column.isQuoted
                    && usingColumn.name == column.name
            }
            return usingColumn.name.lowercased() == column.name.lowercased()
        }.count
        return mergedJoinCount >= max(1, matchCount - 1)
    }

    private static func isMergedNaturalJoinColumn(
        _ column: SQLColumnReference,
        in scope: SQLReferenceScope,
        sources: [ResolvedRelationSource],
        schemaIndex: SchemaLookup
    ) -> Bool {
        guard scope.relations.contains(where: \.isNaturalJoin) else { return false }
        var previousSources: [ResolvedRelationSource] = []
        for (index, relation) in scope.relations.enumerated() {
            guard let source = sources[safe: index] else { break }
            if relation.isNaturalJoin,
                source.definitelyContainsColumn(column, schemaIndex: schemaIndex),
                previousSources.contains(where: {
                    $0.definitelyContainsColumn(column, schemaIndex: schemaIndex)
                })
            {
                return true
            }
            previousSources.append(source)
        }
        return false
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
            if tokens[index].normalized == "between" {
                appendTemporalBetweenIntervalIssue(
                    at: index,
                    tokens: tokens,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex,
                    reported: &reported,
                    issues: &issues
                )
                index += 1
                continue
            }

            guard let comparison = comparisonOperator(at: index, tokens: tokens) else {
                index += 1
                continue
            }

            if isIntervalLiteral(startingAt: comparison.nextIndex, tokens: tokens),
                !isTemporalDifferenceExpression(
                    endingAt: index - 1,
                    tokens: tokens,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex
                ),
                let expression = temporalExpressionRange(
                    endingAt: index - 1,
                    tokens: tokens,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex
                )
            {
                appendTemporalIntervalIssue(
                    for: expression,
                    tokens: tokens,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex,
                    reported: &reported,
                    issues: &issues
                )
            }

            if isIntervalLiteral(endingAt: index - 1, tokens: tokens),
                !isTemporalDifferenceExpression(
                    startingAt: comparison.nextIndex,
                    tokens: tokens,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex
                ),
                let expression = temporalExpressionRange(
                    startingAt: comparison.nextIndex,
                    tokens: tokens,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex
                )
            {
                appendTemporalIntervalIssue(
                    for: expression,
                    tokens: tokens,
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

    private static func appendTemporalBetweenIntervalIssue(
        at betweenIndex: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup,
        reported: inout Set<String>,
        issues: inout [SQLSchemaValidationIssue]
    ) {
        let expressionEnd =
            tokens[safe: betweenIndex - 1]?.normalized == "not" ? betweenIndex - 2 : betweenIndex - 1
        guard isIntervalLiteral(startingAt: betweenIndex + 1, tokens: tokens)
            || betweenUpperBoundStartIndex(at: betweenIndex, tokens: tokens).map({
                isIntervalLiteral(startingAt: $0, tokens: tokens)
            }) == true,
            !isTemporalDifferenceExpression(
                endingAt: expressionEnd,
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            ),
            let expression = temporalExpressionRange(
                endingAt: expressionEnd,
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            )
        else {
            return
        }
        appendTemporalIntervalIssue(
            for: expression,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex,
            reported: &reported,
            issues: &issues
        )
    }

    private static func appendTemporalIntervalIssue(
        for expression: TemporalExpression,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup,
        reported: inout Set<String>,
        issues: inout [SQLSchemaValidationIssue]
    ) {
        guard let identifier = expression.identifier else { return }
        let columns = resolvedColumns(
            for: identifier,
            scopeIndex: scopeIndexForIdentifier(
                tokenRange: expression.identifierRange ?? expression.range,
                tokens: tokens,
                analysis: analysis
            ),
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
        scopeIndex: Int?,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> [ColumnInfo] {
        if let scopeIndex {
            return resolvedColumns(
                for: identifier,
                from: scopeIndex,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            )
        }

        if let qualifier = identifier.qualifier {
            var columns: [ColumnInfo] = []
            for scopeIndex in analysis.scopes.indices {
                guard let source = resolveSource(
                    qualifier,
                    isQuoted: identifier.qualifierIsQuoted,
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

    private static func resolvedColumns(
        for identifier: IdentifierExpression,
        from scopeIndex: Int,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> [ColumnInfo] {
        if let qualifier = identifier.qualifier {
            guard let source = resolveSource(
                qualifier,
                isQuoted: identifier.qualifierIsQuoted,
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
            else {
                return []
            }
            return [column]
        }

        var index: Int? = scopeIndex
        while let current = index {
            let columns = scopeSources[current].compactMap { source -> ColumnInfo? in
                guard let table = source.table else { return nil }
                return schemaIndex.column(
                    on: table,
                    named: identifier.name,
                    isQuoted: identifier.isQuoted
                )
            }
            if !columns.isEmpty {
                return deduplicatedColumns(columns)
            }
            index = analysis.scopes[current].parentIndex
        }
        return []
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
        intervalLiteralRange(startingAt: index, tokens: tokens) != nil
    }

    private static func isIntervalLiteral(endingAt index: Int, tokens: [SQLToken]) -> Bool {
        intervalLiteralRange(endingAt: index, tokens: tokens) != nil
    }

    private static func intervalLiteralRange(startingAt index: Int, tokens: [SQLToken])
        -> Range<Int>?
    {
        guard index >= 0, index < tokens.count else { return nil }
        if tokens[safe: index]?.normalized == "interval",
            tokens[safe: index + 1]?.kind == .string
        {
            return index..<(index + 2)
        }
        guard tokens[index].text == "(",
            let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index),
            let innerRange = intervalLiteralRange(startingAt: index + 1, tokens: tokens),
            innerRange.upperBound == afterGroup - 1
        else {
            return nil
        }
        return index..<afterGroup
    }

    private static func intervalLiteralRange(endingAt index: Int, tokens: [SQLToken])
        -> Range<Int>?
    {
        guard index >= 0, index < tokens.count else { return nil }
        if index - 1 >= 0,
            tokens[safe: index - 1]?.normalized == "interval",
            tokens[safe: index]?.kind == .string
        {
            return (index - 1)..<(index + 1)
        }
        guard tokens[index].text == ")",
            let openIndex = matchingOpeningParenthesis(endingAt: index, tokens: tokens),
            let innerRange = intervalLiteralRange(endingAt: index - 1, tokens: tokens),
            innerRange.lowerBound == openIndex + 1
        else {
            return nil
        }
        return openIndex..<(index + 1)
    }

    private static func betweenUpperBoundStartIndex(
        at betweenIndex: Int,
        tokens: [SQLToken]
    ) -> Int? {
        var depth = 0
        var index = betweenIndex + 1
        while index < tokens.count {
            let token = tokens[index]
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, token.normalized == "and" {
                return index + 1
            } else if depth == 0,
                [
                    "where", "group", "having", "order", "limit", "offset", "union",
                    "returning",
                ].contains(token.normalized)
            {
                return nil
            }
            index += 1
        }
        return nil
    }

    private static func isTemporalDifferenceExpression(
        endingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> Bool {
        guard let right = temporalExpressionRange(
            endingAt: index,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        ),
            tokens[safe: right.range.lowerBound - 1]?.text == "-",
            let left = temporalExpressionRange(
                endingAt: right.range.lowerBound - 2,
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            )
        else {
            return false
        }
        return temporalDifferenceProducesInterval(left: left.kind, right: right.kind)
    }

    private static func isTemporalDifferenceExpression(
        startingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> Bool {
        guard let left = temporalExpressionRange(
            startingAt: index,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        ),
            tokens[safe: left.range.upperBound]?.text == "-",
            let right = temporalExpressionRange(
                startingAt: left.range.upperBound + 1,
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            )
        else {
            return false
        }
        return temporalDifferenceProducesInterval(left: left.kind, right: right.kind)
    }

    private static func temporalDifferenceProducesInterval(
        left: TemporalExpressionKind,
        right: TemporalExpressionKind
    ) -> Bool {
        !(left == .date && right == .date)
    }

    private static func temporalExpressionRange(
        endingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpression? {
        if let cast = castTemporalExpression(
            endingAt: index,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        ) {
            return cast
        }

        if tokens[safe: index]?.text == ")",
            let openIndex = matchingOpeningParenthesis(endingAt: index, tokens: tokens),
            let function = tokens[safe: openIndex - 1],
            function.isIdentifierLike
        {
            if let kind = temporalSQLValueKind(function.normalized) {
                return TemporalExpression(range: (openIndex - 1)..<(index + 1), kind: kind)
            }
            if function.normalized == "date_trunc",
                let argument = temporalArgumentExpression(
                    in: (openIndex + 1)..<index,
                    tokens: tokens,
                    analysis: analysis,
                    scopeSources: scopeSources,
                    schemaIndex: schemaIndex
                )
            {
                return TemporalExpression(
                    range: (openIndex - 1)..<(index + 1),
                    kind: .timestampOrTime,
                    identifier: argument.identifier,
                    identifierRange: argument.identifierRange
                )
            }
        }

        if tokens[safe: index]?.text == ")",
            let openIndex = matchingOpeningParenthesis(endingAt: index, tokens: tokens),
            let inner = temporalExpressionRange(
                endingAt: index - 1,
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            ),
            inner.range.lowerBound == openIndex + 1
        {
            return TemporalExpression(
                range: openIndex..<(index + 1),
                kind: inner.kind,
                identifier: inner.identifier,
                identifierRange: inner.identifierRange
            )
        }

        guard let identifier = identifierExpressionRange(endingAt: index, tokens: tokens) else {
            return nil
        }
        guard let kind = expressionResolvesToTemporalKind(
            identifier.identifier,
            scopeIndex: scopeIndexForIdentifier(
                tokenRange: identifier.range,
                tokens: tokens,
                analysis: analysis
            ),
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        ) else {
            return nil
        }
        return TemporalExpression(
            range: identifier.range,
            kind: kind,
            identifier: identifier.identifier,
            identifierRange: identifier.range
        )
    }

    private static func temporalExpressionRange(
        startingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpression? {
        if let cast = castTemporalExpression(
            startingAt: index,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        ) {
            return cast
        }

        if tokens[safe: index]?.text == "(",
            let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index),
            let inner = temporalExpressionRange(
                startingAt: index + 1,
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            ),
            inner.range.upperBound == afterGroup - 1
        {
            return TemporalExpression(
                range: index..<afterGroup,
                kind: inner.kind,
                identifier: inner.identifier,
                identifierRange: inner.identifierRange
            )
        }

        return baseTemporalExpressionRange(
            startingAt: index,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        )
    }

    private static func baseTemporalExpressionRange(
        startingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpression? {
        if let token = tokens[safe: index],
            token.isIdentifierLike,
            let kind = temporalSQLValueKind(token.normalized),
            tokens[safe: index + 1]?.text == "(",
            let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index + 1)
        {
            return TemporalExpression(range: index..<afterGroup, kind: kind)
        }

        if let token = tokens[safe: index],
            token.isIdentifierLike,
            token.normalized == "date_trunc",
            tokens[safe: index + 1]?.text == "(",
            let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index + 1),
            let argument = temporalArgumentExpression(
                in: (index + 2)..<(afterGroup - 1),
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            )
        {
            return TemporalExpression(
                range: index..<afterGroup,
                kind: .timestampOrTime,
                identifier: argument.identifier,
                identifierRange: argument.identifierRange
            )
        }

        guard let identifier = identifierExpressionRange(startingAt: index, tokens: tokens) else {
            return nil
        }
        guard let kind = expressionResolvesToTemporalKind(
            identifier.identifier,
            scopeIndex: scopeIndexForIdentifier(
                tokenRange: identifier.range,
                tokens: tokens,
                analysis: analysis
            ),
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        ) else {
            return nil
        }
        return TemporalExpression(
            range: identifier.range,
            kind: kind,
            identifier: identifier.identifier,
            identifierRange: identifier.range
        )
    }

    private static func castTemporalExpression(
        endingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpression? {
        if let doubleColon = doubleColonCastTemporalExpression(
            endingAt: index,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        ) {
            return doubleColon
        }
        return castFunctionTemporalExpression(
            endingAt: index,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        )
    }

    private static func castTemporalExpression(
        startingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpression? {
        if let doubleColon = doubleColonCastTemporalExpression(
            startingAt: index,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        ) {
            return doubleColon
        }
        return castFunctionTemporalExpression(
            startingAt: index,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        )
    }

    private static func doubleColonCastTemporalExpression(
        endingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpression? {
        guard let kind = temporalCastTypeKind(at: index, tokens: tokens),
            tokens[safe: index - 1]?.text == ":",
            tokens[safe: index - 2]?.text == ":",
            let operand = temporalExpressionRange(
                endingAt: index - 3,
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            )
        else {
            return nil
        }
        return TemporalExpression(
            range: operand.range.lowerBound..<(index + 1),
            kind: kind,
            identifier: operand.identifier,
            identifierRange: operand.identifierRange
        )
    }

    private static func doubleColonCastTemporalExpression(
        startingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpression? {
        guard let operand = baseTemporalExpressionRange(
            startingAt: index,
            tokens: tokens,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        ),
            tokens[safe: operand.range.upperBound]?.text == ":",
            tokens[safe: operand.range.upperBound + 1]?.text == ":",
            let kind = temporalCastTypeKind(
                at: operand.range.upperBound + 2,
                tokens: tokens
            )
        else {
            return nil
        }
        return TemporalExpression(
            range: operand.range.lowerBound..<(operand.range.upperBound + 3),
            kind: kind,
            identifier: operand.identifier,
            identifierRange: operand.identifierRange
        )
    }

    private static func castFunctionTemporalExpression(
        endingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpression? {
        guard tokens[safe: index]?.text == ")",
            let openIndex = matchingOpeningParenthesis(endingAt: index, tokens: tokens),
            tokens[safe: openIndex - 1]?.normalized == "cast",
            let asIndex = topLevelIndex(of: "as", in: (openIndex + 1)..<index, tokens: tokens),
            let kind = temporalCastTypeKind(at: asIndex + 1, tokens: tokens),
            let operand = temporalExpressionRange(
                endingAt: asIndex - 1,
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            )
        else {
            return nil
        }
        return TemporalExpression(
            range: (openIndex - 1)..<(index + 1),
            kind: kind,
            identifier: operand.identifier,
            identifierRange: operand.identifierRange
        )
    }

    private static func castFunctionTemporalExpression(
        startingAt index: Int,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpression? {
        guard tokens[safe: index]?.normalized == "cast",
            tokens[safe: index + 1]?.text == "(",
            let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index + 1),
            let asIndex = topLevelIndex(
                of: "as",
                in: (index + 2)..<(afterGroup - 1),
                tokens: tokens
            ),
            let kind = temporalCastTypeKind(at: asIndex + 1, tokens: tokens),
            let operand = temporalExpressionRange(
                endingAt: asIndex - 1,
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            )
        else {
            return nil
        }
        return TemporalExpression(
            range: index..<afterGroup,
            kind: kind,
            identifier: operand.identifier,
            identifierRange: operand.identifierRange
        )
    }

    private static func temporalArgumentExpression(
        in range: Range<Int>,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpression? {
        for argumentRange in topLevelArgumentRanges(in: range, tokens: tokens).dropFirst().reversed() {
            guard let expression = temporalExpressionRange(
                endingAt: argumentRange.upperBound - 1,
                tokens: tokens,
                analysis: analysis,
                scopeSources: scopeSources,
                schemaIndex: schemaIndex
            ),
                expression.range.lowerBound >= argumentRange.lowerBound
            else {
                continue
            }
            return expression
        }
        return nil
    }

    private static func topLevelArgumentRanges(
        in range: Range<Int>,
        tokens: [SQLToken]
    ) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var depth = 0
        var start = range.lowerBound
        for index in range {
            let token = tokens[index]
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, token.text == "," {
                if start < index {
                    ranges.append(start..<index)
                }
                start = index + 1
            }
        }
        if start < range.upperBound {
            ranges.append(start..<range.upperBound)
        }
        return ranges
    }

    private static func topLevelIndex(
        of normalized: String,
        in range: Range<Int>,
        tokens: [SQLToken]
    ) -> Int? {
        var depth = 0
        for index in range {
            let token = tokens[index]
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, token.normalized == normalized {
                return index
            }
        }
        return nil
    }

    private static func expressionResolvesToTemporalKind(
        _ identifier: IdentifierExpression,
        scopeIndex: Int?,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpressionKind? {
        if identifier.qualifier == nil,
            let kind = temporalSQLValueKind(identifier.name.lowercased())
        {
            return kind
        }
        return expressionResolvesToTemporalColumnKind(
            identifier,
            scopeIndex: scopeIndex,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        )
    }

    private struct TemporalExpression {
        var range: Range<Int>
        var kind: TemporalExpressionKind
        var identifier: IdentifierExpression?
        var identifierRange: Range<Int>?
    }

    private enum TemporalExpressionKind {
        case date
        case timestampOrTime
    }

    private static func temporalSQLValueKind(_ normalized: String) -> TemporalExpressionKind? {
        switch normalized {
        case "current_date":
            return .date
        case
            "clock_timestamp",
            "current_time",
            "current_timestamp",
            "localtime",
            "localtimestamp",
            "now",
            "statement_timestamp",
            "transaction_timestamp":
            return .timestampOrTime
        default:
            return nil
        }
    }

    private static func temporalCastTypeKind(
        at index: Int,
        tokens: [SQLToken]
    ) -> TemporalExpressionKind? {
        guard let token = tokens[safe: index], token.isIdentifierLike else { return nil }
        switch token.normalized {
        case "date":
            return .date
        case "time", "timetz", "timestamp", "timestamptz":
            return .timestampOrTime
        default:
            return nil
        }
    }

    private static func expressionResolvesToTemporalColumnKind(
        _ identifier: IdentifierExpression,
        scopeIndex: Int?,
        analysis: SQLReferenceAnalysis,
        scopeSources: [[ResolvedRelationSource]],
        schemaIndex: SchemaLookup
    ) -> TemporalExpressionKind? {
        resolvedColumns(
            for: identifier,
            scopeIndex: scopeIndex,
            analysis: analysis,
            scopeSources: scopeSources,
            schemaIndex: schemaIndex
        ).compactMap { temporalKind(for: $0) }.first
    }

    private static func temporalKind(for column: ColumnInfo) -> TemporalExpressionKind? {
        let type = column.dataType.lowercased()
        guard !type.contains("interval") else { return nil }
        if type == "date" { return .date }
        if type.hasPrefix("timestamp")
            || type.hasPrefix("time ")
            || type == "time"
            || type.contains("timestamp")
        {
            return .timestampOrTime
        }
        return nil
    }

    private static func scopeIndexForIdentifier(
        tokenRange: Range<Int>,
        tokens: [SQLToken],
        analysis: SQLReferenceAnalysis
    ) -> Int? {
        guard let nameToken = tokens[safe: tokenRange.upperBound - 1],
            nameToken.isIdentifierLike
        else {
            return nil
        }
        for (scopeIndex, scope) in analysis.scopes.enumerated() {
            if scope.columns.contains(where: {
                $0.startOffset == nameToken.startOffset
                    && $0.endOffset == nameToken.endOffset
                    && $0.name == nameToken.identifierValue
                    && $0.isQuoted == (nameToken.kind == .quotedIdentifier)
            }) {
                return scopeIndex
            }
        }
        return nil
    }

    private static func identifierExpressionRange(
        endingAt index: Int,
        tokens: [SQLToken]
    ) -> (identifier: IdentifierExpression, range: Range<Int>)? {
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
        guard let identifier = IdentifierExpression(parts: parts) else { return nil }
        return (identifier, current..<(index + 1))
    }

    private static func identifierExpressionRange(
        startingAt index: Int,
        tokens: [SQLToken]
    ) -> (identifier: IdentifierExpression, range: Range<Int>)? {
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
        guard let identifier = IdentifierExpression(parts: parts) else { return nil }
        return (identifier, index..<(current + 1))
    }

    private static func matchingOpeningParenthesis(
        endingAt closeIndex: Int,
        tokens: [SQLToken]
    ) -> Int? {
        guard tokens[safe: closeIndex]?.text == ")" else { return nil }
        var depth = 0
        var index = closeIndex
        while index >= 0 {
            if tokens[index].text == ")" {
                depth += 1
            } else if tokens[index].text == "(" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }

    private static func indexAfterBalancedGroup(
        _ tokens: [SQLToken],
        startingAt openIndex: Int
    ) -> Int? {
        guard tokens[safe: openIndex]?.text == "(" else { return nil }
        var depth = 0
        for index in openIndex..<tokens.count {
            if tokens[index].text == "(" {
                depth += 1
            } else if tokens[index].text == ")" {
                depth -= 1
                if depth == 0 {
                    return index + 1
                }
            }
        }
        return nil
    }

    private static func isDateOrTimeColumn(_ column: ColumnInfo) -> Bool {
        temporalKind(for: column) != nil
    }

    private static func deduplicatedColumns(_ columns: [ColumnInfo]) -> [ColumnInfo] {
        var seen = Set<String>()
        return columns.filter { seen.insert($0.id).inserted }
    }

    private static func derivedColumns(
        from relations: [SQLRelationReference]?,
        schemaIndex: SchemaLookup
    ) -> Set<SQLDerivedColumn>? {
        guard let relations, !relations.isEmpty else { return nil }
        var columns = Set<SQLDerivedColumn>()
        for relation in relations {
            if let relationColumns = relation.derivedColumns {
                columns.formUnion(relationColumns)
                continue
            }
            if let nestedColumns = derivedColumns(
                from: relation.derivedOutputRelations,
                schemaIndex: schemaIndex
            ) {
                columns.formUnion(nestedColumns)
                continue
            }
            guard let table = schemaIndex.resolve(relation) else { return nil }
            for column in table.columns {
                columns.insert(
                    SQLDerivedColumn(
                        name: column.name,
                        isQuoted: !isUnquotedPostgresIdentifier(column.name)
                    ))
            }
        }
        return columns
    }

    private static func isUnquotedPostgresIdentifier(_ value: String) -> Bool {
        guard let first = value.first,
            first == "_" || (first >= "a" && first <= "z")
        else {
            return false
        }
        return value.allSatisfy { character in
            character == "_"
                || character == "$"
                || (character >= "a" && character <= "z")
                || (character >= "0" && character <= "9")
        }
    }
}

private struct IdentifierExpression: Equatable {
    var qualifier: String?
    var qualifierIsQuoted: Bool
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
            self.qualifierIsQuoted = parts.dropLast().contains { $0.isQuoted }
        } else {
            self.qualifier = nil
            self.qualifierIsQuoted = false
        }
    }
}

public enum GeneratedSQLPostprocessor {
    public static func enriched(
        _ generation: SQLGenerationResult,
        question: String,
        schema: DatabaseSchema,
        databaseContext: String,
        confirmedSemanticBindings: [String] = [],
        allowGroundingClarification: Bool = true
    ) -> SQLGenerationResult {
        var copy = generation
        copy.generationSchemaName = schema.singleSchemaName
        guard !copy.needsClarification else { return copy }
        let sql = generation.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return copy }

        let schemaValidation = SQLSchemaValidator.validate(sql: sql, against: schema)
        copy.referencedTables = schemaValidation.referencedTables
        if !schemaValidation.hasDefiniteErrors {
            let grounding = groundingEvaluation(
                question: question,
                sql: sql,
                referencedTables: schemaValidation.referencedTables,
                schema: schema,
                databaseContext: databaseContext,
                confirmedSemanticBindings: confirmedSemanticBindings
            )
            copy.groundingConcepts = grounding.concepts
            if allowGroundingClarification,
                let pending = grounding.pendingClarification
            {
                copy.sql = ""
                copy.explanation = pending.question
                copy.needsClarification = true
                copy.clarificationQuestion = pending.question
                copy.clarificationOptions = pending.options
                copy.pendingClarificationID = pending.id
                copy.pendingClarification = pending
                copy.confidence = min(copy.confidence, 0.2)
                copy.riskLevel = .medium
            }
        }
        return copy
    }

    public static func groundingEvaluation(
        question: String,
        sql: String,
        referencedTables: [String],
        schema: DatabaseSchema,
        databaseContext: String,
        confirmedSemanticBindings: [String] = []
    ) -> SQLGroundingEvaluation {
        let availableTokens = referencedSchemaTokens(
            referencedTables: referencedTables,
            schema: schema
        )
        .union(Set(SchemaIndex.tokens(in: databaseContext)))
        .union(Set(SchemaIndex.tokens(in: confirmedSemanticBindings.joined(separator: "\n"))))

        let terms = meaningfulRequestWords(question)
        guard !terms.isEmpty else {
            return SQLGroundingEvaluation(concepts: notRequiredConcepts(question))
        }
        let literalTokens = literalValueTokenEvaluation(
            in: sql,
            referencedTables: referencedTables,
            schema: schema,
            availableTokens: availableTokens
        )
        let unresolved = terms.filter { word in
            let variants = SchemaIndex.tokens(in: word)
            guard !variants.isEmpty else { return false }
            if variants.contains(where: literalTokens.rejected.contains) {
                return true
            }
            if variants.contains(where: literalTokens.accepted.contains) {
                return false
            }
            return !variants.contains { variant in
                tokenSet(availableTokens, containsRelatedTo: variant)
            }
        }

        var concepts = terms.map { term -> SQLGroundingConcept in
            let variants = SchemaIndex.tokens(in: term)
            let state: GroundingState
            let evidence: [String]
            if variants.contains(where: literalTokens.rejected.contains) || unresolved.contains(term) {
                state = .unsupported
                evidence = []
            } else if variants.contains(where: literalTokens.accepted.contains)
                || variants.contains(where: {
                    tokenSet(availableTokens, containsRelatedTo: $0)
                })
            {
                state = .grounded
                evidence = groundingEvidence(
                    for: variants,
                    schema: schema,
                    databaseContext: databaseContext,
                    confirmedSemanticBindings: confirmedSemanticBindings
                )
            } else {
                state = .notRequired
                evidence = []
            }
            return SQLGroundingConcept(
                term: term,
                kind: conceptKind(for: term, question: question),
                state: state,
                required: state == .unsupported || state == .ambiguous,
                evidence: evidence
            )
        }

        concepts.append(contentsOf: notRequiredConcepts(question))
        guard let first = concepts.first(where: {
            $0.required && ($0.state == .unsupported || $0.state == .ambiguous)
        }) else {
            return SQLGroundingEvaluation(concepts: concepts)
        }

        let options = clarificationOptions(for: first, schema: schema, referencedTables: referencedTables)
        let clarificationQuestion =
            "What column, condition, or table defines \"\(first.term)\" for this question?"
        let pending = PendingClarification(
            concept: first,
            originalQuestion: question,
            question: clarificationQuestion,
            options: options,
            evidence: first.evidence
        )
        return SQLGroundingEvaluation(concepts: concepts, pendingClarification: pending)
    }

    private static func notRequiredConcepts(_ question: String) -> [SQLGroundingConcept] {
        let tokens = Set(SchemaIndex.tokens(in: question))
        var concepts: [SQLGroundingConcept] = []
        if !tokens.intersection(metricOperatorStopWords).isEmpty {
            concepts.append(
                SQLGroundingConcept(
                    term: "aggregate operator",
                    kind: .metric,
                    state: .notRequired,
                    required: false,
                    evidence: []
                ))
        }
        if !tokens.intersection(
            Set(["day", "days", "week", "weeks", "month", "months", "year", "years"])
        ).isEmpty {
            concepts.append(
                SQLGroundingConcept(
                    term: "time window",
                    kind: .time,
                    state: .notRequired,
                    required: false,
                    evidence: []
                ))
        }
        return concepts
    }

    private static func conceptKind(for term: String, question: String) -> SQLGroundingConcept.Kind {
        let tokens = Set(SchemaIndex.tokens(in: term))
        if !tokens.intersection(["status", "active", "inactive", "paid", "refunded"]).isEmpty {
            return .filter
        }
        if hasMetricIntent(question) {
            return .businessTerm
        }
        return .entity
    }

    private static func groundingEvidence(
        for variants: [String],
        schema: DatabaseSchema,
        databaseContext: String,
        confirmedSemanticBindings: [String]
    ) -> [String] {
        var evidence: [String] = []
        for table in schema.tables {
            let tableTokens = Set(SchemaIndex.tokens(in: table.name))
            if variants.contains(where: { tokenSet(tableTokens, containsRelatedTo: $0) }) {
                evidence.append(table.qualifiedName)
            }
            for column in table.columns {
                let columnTokens = Set(SchemaIndex.tokens(in: column.name))
                if variants.contains(where: { tokenSet(columnTokens, containsRelatedTo: $0) }) {
                    evidence.append("\(table.qualifiedName).\(column.name)")
                }
                for constraint in column.valueConstraints ?? [] {
                    for value in constraint.values {
                        let valueTokens = Set(SchemaIndex.tokens(in: value))
                        if variants.contains(where: { tokenSet(valueTokens, containsRelatedTo: $0) }) {
                            evidence.append("\(table.qualifiedName).\(column.name) = '\(value)'")
                        }
                    }
                }
            }
        }
        if variants.contains(where: { token in
            tokenSet(Set(SchemaIndex.tokens(in: databaseContext)), containsRelatedTo: token)
        }) {
            evidence.append("Database context")
        }
        for binding in confirmedSemanticBindings {
            if variants.contains(where: { token in
                tokenSet(Set(SchemaIndex.tokens(in: binding)), containsRelatedTo: token)
            }) {
                evidence.append("Confirmed semantic binding")
                break
            }
        }
        var seen = Set<String>()
        return evidence.filter { seen.insert($0).inserted }.prefix(6).map { $0 }
    }

    private static func clarificationOptions(
        for concept: SQLGroundingConcept,
        schema: DatabaseSchema,
        referencedTables: [String]
    ) -> [ClarificationOption] {
        let referenced = Set(referencedTables.map { $0.lowercased() })
        let termTokens = Set(SchemaIndex.tokens(in: concept.term))
        var options: [ClarificationOption] = []
        for table in schema.tables where referenced.isEmpty || referenced.contains(table.qualifiedName.lowercased()) {
            for column in table.columns {
                for constraint in column.valueConstraints ?? [] {
                    for value in constraint.values {
                        let valueTokens = Set(SchemaIndex.tokens(in: value))
                        guard !termTokens.intersection(valueTokens).isEmpty else { continue }
                        let definition = "\(quotedIdentifier(table.schema)).\(quotedIdentifier(table.name)).\(quotedIdentifier(column.name)) = '\(value.replacingOccurrences(of: "'", with: "''"))'"
                        options.append(
                            ClarificationOption(
                                label: "\(column.name) = \(value)",
                                replyText: "Use \(definition)",
                                definition: definition,
                                evidence: ["\(table.qualifiedName).\(column.name)"]
                            ))
                    }
                }
            }
        }
        var seen = Set<String>()
        return options.filter { seen.insert($0.definition).inserted }.prefix(3).map { $0 }
    }

    private struct ConstrainedColumnValueTokens {
        var tableID: String
        var qualifiers: Set<String>
        var values: Set<String>
    }

    private struct ComparisonColumnReference {
        var qualifier: String?
        var qualifierIsQuoted: Bool
        var name: String
        var isQuoted: Bool
        var startOffset: Int?
        var endOffset: Int?
    }

    private struct LiteralValueTokenEvaluation {
        var accepted: Set<String> = []
        var rejected: Set<String> = []
    }

    private static func literalValueTokenEvaluation(
        in sql: String,
        referencedTables: [String],
        schema: DatabaseSchema,
        availableTokens: Set<String>
    ) -> LiteralValueTokenEvaluation {
        let analysis = SQLReferenceAnalyzer.analyze(sql)
        let schemaLookup = SchemaLookup(schema: schema)
        let constrainedValues = constrainedValueTokensByColumnName(
            referencedTables: referencedTables,
            schema: schema,
            sql: sql,
            analysis: analysis
        )
        let sqlTokens = SQLToken.tokenize(sql)
        return sqlTokens.enumerated().reduce(into: LiteralValueTokenEvaluation()) { result, pair in
            let (index, token) = pair
            guard token.kind == .string else { return }
            let literalValue = stringLiteralBody(token.text)
            let literalTokens = Set(SchemaIndex.tokens(in: literalValue))
            guard !literalTokens.isEmpty else { return }
            if let comparison = comparisonColumnReference(beforeLiteralAt: index, tokens: sqlTokens) {
                if let entries = constrainedValues[comparison.name.lowercased()] {
                    let matchingEntries = constrainedValueEntries(
                        matching: comparison,
                        entries: entries,
                        analysis: analysis,
                        schemaLookup: schemaLookup
                    )
                    if !matchingEntries.isEmpty {
                        if comparison.qualifier == nil, matchingEntries.count > 1 {
                            guard matchingEntries.allSatisfy({
                                $0.values.contains(literalValue)
                            }) else {
                                result.rejected.formUnion(literalTokens)
                                return
                            }
                        } else {
                            guard matchingEntries.contains(where: {
                                $0.values.contains(literalValue)
                            }) else {
                                result.rejected.formUnion(literalTokens)
                                return
                            }
                        }
                    } else if requiresConstrainedLiteralProof(comparison)
                        && !literalHasAvailableProof(literalTokens, availableTokens: availableTokens)
                    {
                        result.rejected.formUnion(literalTokens)
                        return
                    }
                } else if requiresConstrainedLiteralProof(comparison)
                    && !literalHasAvailableProof(literalTokens, availableTokens: availableTokens)
                {
                    result.rejected.formUnion(literalTokens)
                    return
                }
            }
            result.accepted.formUnion(literalTokens)
        }
    }

    private static func constrainedValueTokensByColumnName(
        referencedTables: [String],
        schema: DatabaseSchema,
        sql: String,
        analysis: SQLReferenceAnalysis
    ) -> [String: [ConstrainedColumnValueTokens]] {
        let referenced = Set(referencedTables.map { $0.lowercased() })
        guard !referenced.isEmpty else { return [:] }

        let schemaLookup = SchemaLookup(schema: schema)
        var qualifiersByTableID: [String: Set<String>] = [:]
        for table in schema.tables where referenced.contains(table.qualifiedName.lowercased()) {
            qualifiersByTableID[table.id, default: []].formUnion([
                table.name.lowercased(),
                table.qualifiedName.lowercased(),
            ])
        }
        for relation in analysis.relations {
            guard let table = schemaLookup.resolve(relation),
                referenced.contains(table.qualifiedName.lowercased())
            else {
                continue
            }
            if let alias = relation.alias {
                qualifiersByTableID[table.id, default: []].insert(
                    relation.aliasIsQuoted ? alias : alias.lowercased()
                )
            } else {
                qualifiersByTableID[table.id, default: []].insert(
                    relation.nameIsQuoted ? relation.name : relation.name.lowercased()
                )
                qualifiersByTableID[table.id, default: []].insert(relation.displayName.lowercased())
            }
        }

        var tokensByColumn: [String: [ConstrainedColumnValueTokens]] = [:]
        for table in schema.tables where referenced.contains(table.qualifiedName.lowercased()) {
            for column in table.columns {
                var values = Set<String>()
                for constraint in column.valueConstraints ?? [] {
                    for value in constraint.values {
                        values.insert(value)
                    }
                }
                if !values.isEmpty {
                    tokensByColumn[column.name.lowercased(), default: []].append(
                        ConstrainedColumnValueTokens(
                            tableID: table.id,
                            qualifiers: qualifiersByTableID[table.id, default: []],
                            values: values
                        ))
                }
            }
        }
        return tokensByColumn
    }

    private static func literalHasAvailableProof(
        _ literalTokens: Set<String>,
        availableTokens: Set<String>
    ) -> Bool {
        literalTokens.contains { tokenSet(availableTokens, containsRelatedTo: $0) }
    }

    private static func constrainedValueEntries(
        matching comparison: ComparisonColumnReference,
        entries: [ConstrainedColumnValueTokens],
        analysis: SQLReferenceAnalysis,
        schemaLookup: SchemaLookup
    ) -> [ConstrainedColumnValueTokens] {
        if let qualifier = comparison.qualifier {
            let lookup = comparison.qualifierIsQuoted ? qualifier : qualifier.lowercased()
            return entries.filter { $0.qualifiers.contains(lookup) }
        }
        if let scopedEntries = scopedConstrainedValueEntries(
            matching: comparison,
            entries: entries,
            analysis: analysis,
            schemaLookup: schemaLookup
        ) {
            return scopedEntries
        }
        return entries
    }

    private static func scopedConstrainedValueEntries(
        matching comparison: ComparisonColumnReference,
        entries: [ConstrainedColumnValueTokens],
        analysis: SQLReferenceAnalysis,
        schemaLookup: SchemaLookup
    ) -> [ConstrainedColumnValueTokens]? {
        guard let startOffset = comparison.startOffset,
            let endOffset = comparison.endOffset,
            let scopeIndex = analysis.scopes.firstIndex(where: { scope in
                scope.columns.contains { column in
                    column.startOffset == startOffset
                        && column.endOffset == endOffset
                        && column.name == comparison.name
                        && column.isQuoted == comparison.isQuoted
                }
            })
        else {
            return nil
        }

        let column = SQLColumnReference(
            qualifier: nil,
            name: comparison.name,
            isQuoted: comparison.isQuoted
        )
        var currentScopeIndex: Int? = scopeIndex
        while let current = currentScopeIndex {
            let tableIDs = Set(
                analysis.scopes[current].relations.compactMap { relation -> String? in
                    guard let table = schemaLookup.resolve(relation),
                        schemaLookup.table(table, containsColumn: column)
                    else {
                        return nil
                    }
                    return table.id
                }
            )
            if tableIDs.count == 1 {
                let scoped = entries.filter { tableIDs.contains($0.tableID) }
                return scoped.isEmpty ? nil : scoped
            }
            if tableIDs.count > 1 {
                return nil
            }
            currentScopeIndex = analysis.scopes[current].parentIndex
        }
        return nil
    }

    private static func requiresConstrainedLiteralProof(_ comparison: ComparisonColumnReference)
        -> Bool
    {
        guard !comparison.isQuoted else { return false }
        let name = comparison.name.lowercased()
        return name == "status" || name.hasSuffix("_status")
    }

    private static func comparisonColumnReference(
        beforeLiteralAt literalIndex: Int,
        tokens: [SQLToken]
    ) -> ComparisonColumnReference? {
        equalityComparisonColumnReference(beforeLiteralAt: literalIndex, tokens: tokens)
            ?? membershipComparisonColumnReference(containingLiteralAt: literalIndex, tokens: tokens)
    }

    private static func equalityComparisonColumnReference(
        beforeLiteralAt literalIndex: Int,
        tokens: [SQLToken]
    ) -> ComparisonColumnReference? {
        guard let operatorIndex = previousSignificantIndex(before: literalIndex, tokens: tokens),
            tokens[operatorIndex].text == "=",
            let columnIndex = previousSignificantIndex(before: operatorIndex, tokens: tokens)
        else {
            return nil
        }
        return comparisonColumnReference(endingAt: columnIndex, tokens: tokens)
    }

    private static func membershipComparisonColumnReference(
        containingLiteralAt literalIndex: Int,
        tokens: [SQLToken]
    ) -> ComparisonColumnReference? {
        for group in enclosingGroups(containing: literalIndex, tokens: tokens) {
            let functionIndex = group.openIndex - 1
            guard functionIndex >= 0,
                tokens[safe: functionIndex]?.isIdentifierLike == true
            else {
                continue
            }
            let function = tokens[functionIndex].normalized
            if function == "in" {
                guard var columnIndex = previousSignificantIndex(
                    before: functionIndex,
                    tokens: tokens
                ) else { continue }
                if tokens[columnIndex].normalized == "not" {
                    guard let beforeNot = previousSignificantIndex(
                        before: columnIndex,
                        tokens: tokens
                    ) else { continue }
                    columnIndex = beforeNot
                }
                if let comparison = comparisonColumnReference(endingAt: columnIndex, tokens: tokens) {
                    return comparison
                }
            } else if function == "any" || function == "all" {
                guard let operatorIndex = previousSignificantIndex(
                    before: functionIndex,
                    tokens: tokens
                ),
                    tokens[operatorIndex].text == "=",
                    let columnIndex = previousSignificantIndex(before: operatorIndex, tokens: tokens),
                    let comparison = comparisonColumnReference(endingAt: columnIndex, tokens: tokens)
                else {
                    continue
                }
                return comparison
            }
        }
        return nil
    }

    private static func comparisonColumnReference(
        endingAt columnIndex: Int,
        tokens: [SQLToken]
    ) -> ComparisonColumnReference? {
        guard tokens[safe: columnIndex]?.isIdentifierLike == true else { return nil }
        var qualifier: String?
        var qualifierIsQuoted = false
        if tokens[safe: columnIndex - 1]?.text == ".",
            let tableIndex = previousSignificantIndex(before: columnIndex - 1, tokens: tokens),
            tokens[safe: tableIndex]?.isIdentifierLike == true
        {
            var parts = [tokens[tableIndex]]
            if tokens[safe: tableIndex - 1]?.text == ".",
                let schemaIndex = previousSignificantIndex(before: tableIndex - 1, tokens: tokens),
                tokens[safe: schemaIndex]?.isIdentifierLike == true
            {
                parts.insert(tokens[schemaIndex], at: 0)
            }
            qualifier = parts.map(\.identifierValue).joined(separator: ".")
            qualifierIsQuoted = parts.contains { $0.kind == .quotedIdentifier }
        }
        return ComparisonColumnReference(
            qualifier: qualifier,
            qualifierIsQuoted: qualifierIsQuoted,
            name: tokens[columnIndex].identifierValue,
            isQuoted: tokens[columnIndex].kind == .quotedIdentifier,
            startOffset: tokens[columnIndex].startOffset,
            endOffset: tokens[columnIndex].endOffset
        )
    }

    private static func enclosingGroups(
        containing index: Int,
        tokens: [SQLToken]
    ) -> [(openIndex: Int, closeIndex: Int)] {
        guard index > 0 else { return [] }
        var stack: [Int] = []
        for cursor in 0...min(index, tokens.count - 1) {
            if tokens[cursor].text == "(" {
                stack.append(cursor)
            } else if tokens[cursor].text == ")" {
                _ = stack.popLast()
            }
        }
        return stack.reversed().compactMap { openIndex in
            guard let afterGroup = indexAfterBalancedGroup(tokens, startingAt: openIndex) else {
                return nil
            }
            return (openIndex, afterGroup - 1)
        }
    }

    private static func indexAfterBalancedGroup(
        _ tokens: [SQLToken],
        startingAt openIndex: Int
    ) -> Int? {
        guard tokens[safe: openIndex]?.text == "(" else { return nil }
        var depth = 0
        for index in openIndex..<tokens.count {
            if tokens[index].text == "(" {
                depth += 1
            } else if tokens[index].text == ")" {
                depth -= 1
                if depth == 0 {
                    return index + 1
                }
            }
        }
        return nil
    }

    private static func previousSignificantIndex(before index: Int, tokens: [SQLToken]) -> Int? {
        guard index > 0 else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            let token = tokens[cursor]
            if token.text != "," && token.text != "(" && token.text != ")" {
                return cursor
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        return nil
    }

    private static func stringLiteralBody(_ text: String) -> String {
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if text.hasPrefix("$"),
            let delimiterEnd = text.dropFirst().firstIndex(of: "$")
        {
            let delimiter = String(text[...delimiterEnd])
            if text.hasSuffix(delimiter), text.count >= delimiter.count * 2 {
                return String(text.dropFirst(delimiter.count).dropLast(delimiter.count))
            }
        }
        return text
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
            guard !variants.contains(where: genericVerbStopWords.contains) else { return false }
            guard !variants.contains(where: metricOperatorStopWords.contains) else { return false }
            guard !variants.contains(where: comparisonOperatorStopWords.contains) else { return false }
            return seen.insert(word).inserted
        }
    }

    private static func rawWords(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(
                of: #"([[:alnum:]])['’ʼ]s\b"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([[:alnum:]])['’ʼ]\b"#,
                with: "$1",
                options: .regularExpression
            )
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
        guard queryToken.count >= 4 else { return false }
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

    private static let comparisonOperatorStopWords: Set<String> = [
        "after", "before", "below", "earlier", "equal", "equaling", "equals", "exceed",
        "exceeding", "exceeds", "fewer", "greater", "higher", "later", "less", "lower",
        "more", "newer", "older", "than", "younger",
    ]

    private static let genericVerbStopWords: Set<String> = [
        "create", "creating", "make", "makes", "making",
        "delete", "deleting", "insert", "inserting", "remove",
        "removing", "set", "update", "updating",
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
        "sort", "placed", "that", "the", "their", "them", "then", "there", "these", "they", "this",
        "those", "to", "today", "top", "under", "up", "us", "was", "we", "week", "weeks",
        "were", "what", "when", "where", "which", "who", "whom", "whose", "why", "with",
        "would", "year", "years", "you", "your",
    ]
}

public enum GeneratedSQLValidator {
    public static func canonicalize(sql: String, schema: DatabaseSchema) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let safety = SQLSafetyValidator.validate(trimmed)
        let normalized = safety.normalizedSQL ?? trimmed
        return quoteUnquotedIdentifiers(sql: normalized, schema: schema) ?? normalized
    }

    public static func validate(sql: String, schema: DatabaseSchema) -> SQLValidationResult {
        combine(
            safety: SQLSafetyValidator.validate(sql),
            schemaValidation: SQLSchemaValidator.validate(sql: sql, against: schema)
        )
    }

    public static func repairQuotedIdentifiers(sql: String, schema: DatabaseSchema) -> String? {
        guard let repaired = quoteUnquotedIdentifiers(sql: sql, schema: schema),
            repaired != sql,
            validate(sql: repaired, schema: schema).isValid
        else { return nil }
        return repaired
    }

    private static func quoteUnquotedIdentifiers(sql: String, schema: DatabaseSchema) -> String? {
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

        let replacementRanges = schemaValidation.analysis.columns.compactMap {
            column -> IdentifierReplacement? in
            guard !column.isQuoted,
                let start = column.startOffset,
                let end = column.endOffset,
                let replacement = replacements[column.name.lowercased()]
            else { return nil }
            return IdentifierReplacement(start: start, end: end, replacement: replacement)
        }
        guard !replacementRanges.isEmpty else { return nil }

        return rewriteUnquotedIdentifiers(in: sql, replacementRanges: replacementRanges)
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
        replacementRanges: [IdentifierReplacement]
    ) -> String {
        let characters = Array(sql)
        var output = ""
        var index = 0
        let replacementsByStart = Dictionary(
            uniqueKeysWithValues: replacementRanges.map { ($0.start, $0) }
        )

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
                if let replacement = replacementsByStart[start],
                    replacement.end == index
                {
                    output += quotedIdentifier(replacement.replacement)
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

private struct IdentifierReplacement {
    var start: Int
    var end: Int
    var replacement: String
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
    enum Kind {
        case table
        case cte
        case derived
        case unresolved
    }

    var displayName: String
    var unquotedNames: Set<String>
    var quotedNames: Set<String>
    var singleQuotedNames: Set<String>
    var kind: Kind
    var table: TableInfo?
    var cteColumns: Set<SQLDerivedColumn>?
    var hasUnknownColumns: Bool
    var role: SQLRelationReference.Role
    var startOffset: Int?

    var isDerivedLike: Bool {
        kind == .cte || kind == .derived
    }

    static func table(
        _ table: TableInfo,
        alias: String?,
        aliasIsQuoted: Bool = false,
        role: SQLRelationReference.Role = .source,
        startOffset: Int? = nil
    ) -> ResolvedRelationSource {
        let unquotedNames: Set<String>
        let quotedNames: Set<String>
        let singleQuotedNames: Set<String>
        if let alias {
            unquotedNames =
                aliasIsQuoted
                ? (isUnquotedPostgresIdentifier(alias) ? [alias.lowercased()] : [])
                : [alias.lowercased()]
            quotedNames = aliasIsQuoted ? [alias] : []
            singleQuotedNames = quotedNames
        } else {
            unquotedNames = unquotedTableNames(for: table)
            quotedNames = Set([table.name, table.qualifiedName])
            singleQuotedNames = Set([table.name])
        }
        return ResolvedRelationSource(
            displayName: table.qualifiedName,
            unquotedNames: unquotedNames,
            quotedNames: quotedNames,
            singleQuotedNames: singleQuotedNames,
            kind: .table,
            table: table,
            cteColumns: nil,
            hasUnknownColumns: false,
            role: role,
            startOffset: startOffset
        )
    }

    static func cte(
        name: String,
        nameIsQuoted: Bool = false,
        alias: String?,
        aliasIsQuoted: Bool = false,
        columns: Set<SQLDerivedColumn>?,
        kind: Kind = .cte,
        role: SQLRelationReference.Role = .source,
        startOffset: Int? = nil
    ) -> ResolvedRelationSource {
        let unquotedNames: Set<String>
        let quotedNames: Set<String>
        let singleQuotedNames: Set<String>
        if let alias {
            unquotedNames =
                aliasIsQuoted
                ? (isUnquotedPostgresIdentifier(alias) ? [alias.lowercased()] : [])
                : [alias.lowercased()]
            quotedNames = aliasIsQuoted ? [alias] : []
            singleQuotedNames = quotedNames
        } else {
            unquotedNames =
                nameIsQuoted
                ? (isUnquotedPostgresIdentifier(name) ? [name.lowercased()] : [])
                : [name.lowercased()]
            quotedNames = nameIsQuoted ? [name] : []
            singleQuotedNames = quotedNames
        }
        return ResolvedRelationSource(
            displayName: name,
            unquotedNames: unquotedNames,
            quotedNames: quotedNames,
            singleQuotedNames: singleQuotedNames,
            kind: kind,
            table: nil,
            cteColumns: columns,
            hasUnknownColumns: columns == nil,
            role: role,
            startOffset: startOffset
        )
    }

    static func unresolved(_ relation: SQLRelationReference) -> ResolvedRelationSource {
        let unquotedNames: Set<String>
        let quotedNames: Set<String>
        let singleQuotedNames: Set<String>
        if let alias = relation.alias {
            unquotedNames =
                relation.aliasIsQuoted
                ? (isUnquotedPostgresIdentifier(alias) ? [alias.lowercased()] : [])
                : [alias.lowercased()]
            quotedNames = relation.aliasIsQuoted ? [alias] : []
            singleQuotedNames = quotedNames
        } else {
            var unquoted = Set<String>()
            if !relation.nameIsQuoted && isUnquotedPostgresIdentifier(relation.name) {
                unquoted.insert(relation.name.lowercased())
            }
            if let schema = relation.schema,
                !relation.schemaIsQuoted,
                !relation.nameIsQuoted,
                isUnquotedPostgresIdentifier(schema),
                isUnquotedPostgresIdentifier(relation.name)
            {
                unquoted.insert(relation.displayName.lowercased())
            }
            unquotedNames = unquoted
            quotedNames = Set([relation.name, relation.displayName])
            singleQuotedNames = Set([relation.name])
        }
        return ResolvedRelationSource(
            displayName: relation.displayName,
            unquotedNames: unquotedNames,
            quotedNames: quotedNames,
            singleQuotedNames: singleQuotedNames,
            kind: .unresolved,
            table: nil,
            cteColumns: nil,
            hasUnknownColumns: true,
            role: relation.role,
            startOffset: relation.startOffset
        )
    }

    func matches(
        _ qualifier: String,
        isQuoted: Bool = false,
        quotedAsSingleIdentifier: Bool = false
    ) -> Bool {
        if isQuoted {
            if quotedAsSingleIdentifier {
                return singleQuotedNames.contains(qualifier)
            }
            return quotedNames.contains(qualifier)
        }
        return unquotedNames.contains(qualifier.lowercased())
    }

    private static func unquotedTableNames(for table: TableInfo) -> Set<String> {
        var names = Set<String>()
        if isUnquotedPostgresIdentifier(table.name) {
            names.insert(table.name.lowercased())
        }
        if isUnquotedPostgresIdentifier(table.schema)
            && isUnquotedPostgresIdentifier(table.name)
        {
            names.insert(table.qualifiedName.lowercased())
        }
        return names
    }

    private static func isUnquotedPostgresIdentifier(_ value: String) -> Bool {
        guard let first = value.first,
            first == "_" || (first >= "a" && first <= "z")
        else {
            return false
        }
        return value.allSatisfy { character in
            character == "_"
                || character == "$"
                || (character >= "a" && character <= "z")
                || (character >= "0" && character <= "9")
        }
    }

    func definitelyContainsColumn(_ column: SQLColumnReference, schemaIndex: SchemaLookup) -> Bool {
        if let table {
            return schemaIndex.table(table, containsColumn: column)
        }
        guard let cteColumns else { return false }
        return cteColumns.contains { $0.matches(column) }
    }

    func quotedColumnName(
        for column: SQLColumnReference,
        schemaIndex: SchemaLookup
    ) -> String? {
        if let cteColumns, !column.isQuoted {
            return cteColumns.first {
                $0.isQuoted && $0.name.lowercased() == column.name.lowercased()
            }?.name
        }
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
