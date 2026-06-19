import Foundation

public struct SQLRelationReference: Equatable, Hashable, Sendable {
    public enum Role: Equatable, Hashable, Sendable {
        case source
        case updateTarget
        case insertTarget
        case deleteTarget
    }

    public var schema: String?
    public var name: String
    public var alias: String?
    public var schemaIsQuoted: Bool
    public var nameIsQuoted: Bool
    public var aliasIsQuoted: Bool
    public var role: Role
    public var isDerived: Bool
    public var derivedColumns: Set<SQLDerivedColumn>?

    public init(
        schema: String? = nil,
        name: String,
        alias: String? = nil,
        schemaIsQuoted: Bool = false,
        nameIsQuoted: Bool = false,
        aliasIsQuoted: Bool = false,
        role: Role = .source,
        isDerived: Bool = false,
        derivedColumns: Set<SQLDerivedColumn>? = nil
    ) {
        self.schema = schema
        self.name = name
        self.alias = alias
        self.schemaIsQuoted = schemaIsQuoted
        self.nameIsQuoted = nameIsQuoted
        self.aliasIsQuoted = aliasIsQuoted
        self.role = role
        self.isDerived = isDerived
        self.derivedColumns = derivedColumns
    }

    public var displayName: String {
        if let schema { return "\(schema).\(name)" }
        return name
    }
}

public struct SQLDerivedColumn: Equatable, Hashable, Sendable {
    public var name: String
    public var isQuoted: Bool

    public init(name: String, isQuoted: Bool) {
        self.name = isQuoted ? name : name.lowercased()
        self.isQuoted = isQuoted
    }

    init(token: SQLToken) {
        self.init(name: token.identifierValue, isQuoted: token.kind == .quotedIdentifier)
    }

    public func matches(_ column: SQLColumnReference) -> Bool {
        if isQuoted {
            return column.isQuoted && column.name == name
        }
        if column.isQuoted {
            return column.name == name
        }
        return column.name.lowercased() == name
    }
}

public struct SQLColumnReference: Equatable, Hashable, Sendable {
    public enum Context: Equatable, Hashable, Sendable {
        case expression
        case insertTarget
        case joinUsing
        case updateSetTarget
    }

    public var qualifier: String?
    public var name: String
    public var qualifierIsQuoted: Bool
    public var isQuoted: Bool
    public var context: Context
    public var startOffset: Int?
    public var endOffset: Int?

    public init(
        qualifier: String?,
        name: String,
        qualifierIsQuoted: Bool = false,
        isQuoted: Bool = false,
        context: Context = .expression,
        startOffset: Int? = nil,
        endOffset: Int? = nil
    ) {
        self.qualifier = qualifier
        self.name = name
        self.qualifierIsQuoted = qualifierIsQuoted
        self.isQuoted = isQuoted
        self.context = context
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

public struct SQLReferenceAnalysis: Equatable, Sendable {
    public var relations: [SQLRelationReference]
    public var columns: [SQLColumnReference]
    public var cteNames: Set<String>
    public var cteOutputColumns: [String: Set<SQLDerivedColumn>?]
    public var outputAliases: Set<String>
    public var upsertTargetRelations: [SQLRelationReference]
    public var scopes: [SQLReferenceScope]
    public var analysisIncomplete: Bool
}

public struct SQLReferenceScope: Equatable, Sendable {
    public var relations: [SQLRelationReference]
    public var columns: [SQLColumnReference]
    public var outputAliases: Set<String>
    public var parentIndex: Int?

    public init(
        relations: [SQLRelationReference],
        columns: [SQLColumnReference],
        outputAliases: Set<String>,
        parentIndex: Int?
    ) {
        self.relations = relations
        self.columns = columns
        self.outputAliases = outputAliases
        self.parentIndex = parentIndex
    }
}

public enum SQLReferenceAnalyzer {
    public static func analyze(_ sql: String) -> SQLReferenceAnalysis {
        let tokens = SQLToken.tokenize(sql)
        var cteNames = Set<String>()
        var cteOutputColumns: [String: Set<SQLDerivedColumn>?] = [:]
        var scopes: [SQLReferenceScope] = []
        var incomplete = false

        let mainStart = parseCTEs(
            tokens,
            cteNames: &cteNames,
            cteOutputColumns: &cteOutputColumns,
            scopes: &scopes,
            incomplete: &incomplete
        )
        parseScopes(
            Array(tokens[mainStart..<tokens.count]),
            cteNames: cteNames,
            parentIndex: nil,
            scopes: &scopes,
            incomplete: &incomplete
        )
        if scopes.isEmpty {
            let relations = parseRelations(tokens, cteNames: cteNames, incomplete: &incomplete)
            let outputAliases = parseOutputAliases(tokens)
            let columns = parseColumnReferences(
                tokens,
                relations: relations,
                cteNames: cteNames,
                outputAliases: outputAliases
            )
            scopes.append(
                SQLReferenceScope(
                    relations: relations,
                    columns: columns,
                    outputAliases: outputAliases,
                    parentIndex: nil
                ))
        }

        let relations = scopes.flatMap(\.relations)
        let columns = scopes.flatMap(\.columns)
        let outputAliases = scopes.reduce(into: Set<String>()) { result, scope in
            result.formUnion(scope.outputAliases)
        }

        return SQLReferenceAnalysis(
            relations: deduplicated(relations),
            columns: deduplicated(columns),
            cteNames: cteNames,
            cteOutputColumns: cteOutputColumns,
            outputAliases: outputAliases,
            upsertTargetRelations: parseUpsertTargetRelations(tokens),
            scopes: scopes,
            analysisIncomplete: incomplete
        )
    }

    @discardableResult
    private static func parseCTEs(
        _ tokens: [SQLToken],
        cteNames: inout Set<String>,
        cteOutputColumns: inout [String: Set<SQLDerivedColumn>?],
        scopes: inout [SQLReferenceScope],
        incomplete: inout Bool
    ) -> Int {
        guard tokens.first?.normalized == "with" else { return 0 }
        var index = 1
        if tokens[safe: index]?.normalized == "recursive" {
            index += 1
        }

        while index < tokens.count {
            guard let nameToken = tokens[safe: index], nameToken.isIdentifierLike else {
                incomplete = true
                return index
            }
            let cteName = nameToken.identifierValue.lowercased()
            cteNames.insert(cteName)
            index += 1

            var explicitColumns: Set<SQLDerivedColumn>?
            if tokens[safe: index]?.text == "(" {
                explicitColumns = Set(derivedColumnsInBalancedGroup(tokens, startingAt: index))
                index = indexAfterBalancedGroup(tokens, startingAt: index) ?? tokens.count
            }
            guard tokens[safe: index]?.normalized == "as" else {
                incomplete = true
                return index
            }
            index += 1
            if tokens[safe: index]?.normalized == "materialized"
                || (tokens[safe: index]?.normalized == "not"
                    && tokens[safe: index + 1]?.normalized == "materialized")
            {
                index += tokens[safe: index]?.normalized == "not" ? 2 : 1
            }
            guard tokens[safe: index]?.text == "(",
                let afterSubquery = indexAfterBalancedGroup(tokens, startingAt: index)
            else {
                incomplete = true
                return index
            }
            let innerTokens = Array(tokens[(index + 1)..<(afterSubquery - 1)])
            parseScopes(
                innerTokens,
                cteNames: cteNames,
                parentIndex: nil,
                scopes: &scopes,
                incomplete: &incomplete
            )
            if let explicitColumns {
                cteOutputColumns[cteName] = explicitColumns
            } else {
                let inferred = inferSelectOutputColumns(innerTokens)
                cteOutputColumns[cteName] = inferred
                if inferred == nil {
                    incomplete = true
                }
            }
            index = afterSubquery
            if tokens[safe: index]?.text == "," {
                index += 1
                continue
            }
            return index
        }
        return index
    }

    private static func parseScopes(
        _ tokens: [SQLToken],
        cteNames: Set<String>,
        parentIndex: Int?,
        scopes: inout [SQLReferenceScope],
        incomplete: inout Bool
    ) {
        var index = 0
        var foundTopLevelSelect = false
        while index < tokens.count {
            let token = tokens[index]
            if token.text == "(" {
                guard let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index) else {
                    incomplete = true
                    return
                }
                let innerTokens = Array(tokens[(index + 1)..<(afterGroup - 1)])
                if containsTopLevelSelect(innerTokens) {
                    parseScopes(
                        innerTokens,
                        cteNames: cteNames,
                        parentIndex: parentIndex,
                        scopes: &scopes,
                        incomplete: &incomplete
                    )
                }
                index = afterGroup
                continue
            }
            if token.normalized == "select" {
                foundTopLevelSelect = true
                let statementEnd = nextTopLevelIndex(
                    ofAny: ["union", "intersect", "except"],
                    in: tokens,
                    after: index + 1
                ) ?? tokens.count
                let statementStart = statementStartForSelect(at: index, tokens: tokens)
                let statementTokens = Array(tokens[statementStart..<statementEnd])
                let relations = parseRelations(
                    statementTokens,
                    cteNames: cteNames,
                    incomplete: &incomplete,
                    skipCTEs: false
                )
                let outputAliases = parseOutputAliases(statementTokens)
                let columns = parseColumnReferences(
                    statementTokens,
                    relations: relations,
                    cteNames: cteNames,
                    outputAliases: outputAliases,
                    skipNestedSubqueries: true
                )
                let scopeIndex = scopes.count
                scopes.append(
                    SQLReferenceScope(
                        relations: relations,
                        columns: columns,
                        outputAliases: outputAliases,
                        parentIndex: parentIndex
                    ))
                parseNestedSubqueryScopes(
                    Array(tokens[index..<statementEnd]),
                    cteNames: cteNames,
                    parentIndex: scopeIndex,
                    scopes: &scopes,
                    incomplete: &incomplete
                )
                index = statementEnd
                continue
            }
            index += 1
        }

        if !foundTopLevelSelect {
            let relations = parseRelations(
                tokens,
                cteNames: cteNames,
                incomplete: &incomplete,
                skipCTEs: false
            )
            guard !relations.isEmpty else { return }
            let outputAliases = parseOutputAliases(tokens)
            let columns = parseColumnReferences(
                tokens,
                relations: relations,
                cteNames: cteNames,
                outputAliases: outputAliases,
                skipNestedSubqueries: true
            )
            scopes.append(
                SQLReferenceScope(
                    relations: relations,
                    columns: columns,
                    outputAliases: outputAliases,
                    parentIndex: parentIndex
                ))
        }
    }

    private static func parseNestedSubqueryScopes(
        _ tokens: [SQLToken],
        cteNames: Set<String>,
        parentIndex: Int,
        scopes: inout [SQLReferenceScope],
        incomplete: inout Bool
    ) {
        var index = 0
        while index < tokens.count {
            guard tokens[index].text == "(" else {
                index += 1
                continue
            }
            guard let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index) else {
                incomplete = true
                return
            }
            let innerTokens = Array(tokens[(index + 1)..<(afterGroup - 1)])
            if containsTopLevelSelect(innerTokens) {
                parseScopes(
                    innerTokens,
                    cteNames: cteNames,
                    parentIndex: parentIndex,
                    scopes: &scopes,
                    incomplete: &incomplete
                )
            }
            index = afterGroup
        }
    }

    private static func parseRelations(
        _ tokens: [SQLToken],
        cteNames: Set<String>,
        incomplete: inout Bool,
        skipCTEs: Bool = true
    ) -> [SQLRelationReference] {
        var relations: [SQLRelationReference] = []
        var index = 0
        var previousKeyword: String?
        while index < tokens.count {
            let token = tokens[index]
            if token.text == "(" {
                guard let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index) else {
                    incomplete = true
                    return relations
                }
                index = afterGroup
                continue
            }
            let normalized = token.normalized
            let isRelationStart =
                normalized == "from"
                || normalized == "join"
                || normalized == "update"
                || (normalized == "into" && previousKeyword == "insert")
                || (normalized == "from" && previousKeyword == "delete")
                || (normalized == "using" && tokens[safe: index + 1]?.text != "(")

            if isRelationStart {
                let role: SQLRelationReference.Role =
                    normalized == "update" ? .updateTarget
                    : (normalized == "into" && previousKeyword == "insert") ? .insertTarget
                    : (normalized == "from" && previousKeyword == "delete") ? .deleteTarget
                    : .source
                index += 1
                while index < tokens.count {
                    if let current = tokens[safe: index],
                        relationTerminatorKeywords.contains(current.normalized)
                    {
                        break
                    }
                    while let modifier = tokens[safe: index]?.normalized,
                        modifier == "only" || modifier == "lateral"
                    {
                        index += 1
                    }
                    if tokens[safe: index]?.text == "(" {
                        if let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index) {
                            let innerTokens = Array(tokens[(index + 1)..<(afterGroup - 1)])
                            index = afterGroup
                            let aliasParse = parseOptionalAliasAndColumns(tokens, startingAt: index)
                            if let aliasParse {
                                index = aliasParse.nextIndex
                            }
                            if containsTopLevelSelect(innerTokens) {
                                let inferredColumns = inferSelectOutputColumns(innerTokens)
                                relations.append(
                                    SQLRelationReference(
                                        name: aliasParse?.alias ?? "__derived_table",
                                        alias: aliasParse?.alias,
                                        aliasIsQuoted: aliasParse?.aliasIsQuoted ?? false,
                                        isDerived: true,
                                        derivedColumns: aliasParse?.columns ?? inferredColumns
                                    ))
                            }
                        } else {
                            incomplete = true
                            return relations
                        }
                    } else if role == .source,
                        let functionRelation = parseTableFunctionRelation(
                            at: &index,
                            tokens: tokens
                        )
                    {
                        relations.append(functionRelation)
                    } else if let relation = parseRelation(at: &index, tokens: tokens) {
                        var roleRelation = relation
                        roleRelation.role = role
                        if !skipCTEs || !cteNames.contains(roleRelation.name.lowercased()) {
                            relations.append(roleRelation)
                        }
                    } else {
                        break
                    }
                    if tokens[safe: index]?.text == "," {
                        index += 1
                        continue
                    }
                    break
                }
                continue
            }

            if token.kind == .identifier || token.kind == .quotedIdentifier {
                previousKeyword = normalized
            }
            index += 1
        }
        return relations
    }

    private static func parseRelation(at index: inout Int, tokens: [SQLToken]) -> SQLRelationReference? {
        guard let first = tokens[safe: index], first.isIdentifierLike else { return nil }
        var schema: String?
        var name = first.identifierValue
        var schemaIsQuoted = false
        var nameIsQuoted = first.kind == .quotedIdentifier
        index += 1
        if tokens[safe: index]?.text == ".",
            let second = tokens[safe: index + 1],
            second.isIdentifierLike
        {
            schema = name
            schemaIsQuoted = first.kind == .quotedIdentifier
            name = second.identifierValue
            nameIsQuoted = second.kind == .quotedIdentifier
            index += 2
        }

        var alias: String?
        var aliasIsQuoted = false
        if tokens[safe: index]?.normalized == "as" {
            index += 1
            if let aliasToken = tokens[safe: index], aliasToken.isIdentifierLike {
                alias = aliasToken.identifierValue
                aliasIsQuoted = aliasToken.kind == .quotedIdentifier
                index += 1
            }
        } else if let aliasToken = tokens[safe: index],
            aliasToken.isIdentifierLike,
            !relationTerminatorKeywords.contains(aliasToken.normalized)
        {
            alias = aliasToken.identifierValue
            aliasIsQuoted = aliasToken.kind == .quotedIdentifier
            index += 1
        }

        return SQLRelationReference(
            schema: schema,
            name: name,
            alias: alias,
            schemaIsQuoted: schemaIsQuoted,
            nameIsQuoted: nameIsQuoted,
            aliasIsQuoted: aliasIsQuoted
        )
    }

    private static func parseTableFunctionRelation(
        at index: inout Int,
        tokens: [SQLToken]
    ) -> SQLRelationReference? {
        guard let first = tokens[safe: index], first.isIdentifierLike else { return nil }
        var functionName = first.identifierValue
        var cursor = index + 1
        if tokens[safe: cursor]?.text == ".",
            let second = tokens[safe: cursor + 1],
            second.isIdentifierLike
        {
            functionName = second.identifierValue
            cursor += 2
        }
        guard tokens[safe: cursor]?.text == "(",
            let afterArguments = indexAfterBalancedGroup(tokens, startingAt: cursor)
        else {
            return nil
        }

        let aliasParse = parseOptionalAliasAndColumns(tokens, startingAt: afterArguments)
        index = aliasParse?.nextIndex ?? afterArguments
        return SQLRelationReference(
            name: aliasParse?.alias ?? functionName,
            alias: aliasParse?.alias,
            aliasIsQuoted: aliasParse?.aliasIsQuoted ?? false,
            isDerived: true,
            derivedColumns: aliasParse?.columns
        )
    }

    private static func parseOutputAliases(_ tokens: [SQLToken]) -> Set<String> {
        guard let selectIndex = tokens.firstIndex(where: { $0.normalized == "select" }) else {
            return []
        }
        let fromIndex = firstTopLevelIndex(ofAny: ["from"], in: tokens, after: selectIndex + 1)
            ?? tokens.count
        let items = splitTopLevelCommaSeparated(Array(tokens[(selectIndex + 1)..<fromIndex]))
        var aliases = Set<String>()
        for item in items {
            let significant = item.filter { $0.text != "," }
            if let alias = explicitOutputAlias(in: significant)
                ?? implicitOutputAlias(in: significant)
            {
                aliases.insert(alias.identifierValue.lowercased())
            }
        }
        return aliases
    }

    private static func inferSelectOutputColumns(_ tokens: [SQLToken]) -> Set<SQLDerivedColumn>? {
        guard let selectIndex = tokens.firstIndex(where: { $0.normalized == "select" }) else {
            return nil
        }
        let fromIndex = firstTopLevelIndex(ofAny: ["from"], in: tokens, after: selectIndex + 1)
            ?? tokens.count
        let items = splitTopLevelCommaSeparated(Array(tokens[(selectIndex + 1)..<fromIndex]))
        var columns = Set<SQLDerivedColumn>()
        for item in items {
            let significant = item.filter { $0.text != "," }
            guard !significant.isEmpty else { continue }
            if let alias = explicitOutputAlias(in: significant) {
                columns.insert(SQLDerivedColumn(token: alias))
                continue
            }
            if let alias = implicitOutputAlias(in: significant) {
                columns.insert(SQLDerivedColumn(token: alias))
                continue
            }
            if significant.contains(where: { $0.text == "*" }) {
                return nil
            }
            if significant.count == 1, let column = significant.first, column.isIdentifierLike {
                columns.insert(SQLDerivedColumn(token: column))
                continue
            }
            if significant.count == 3,
                significant[safe: 1]?.text == ".",
                let column = significant.last,
                column.isIdentifierLike
            {
                columns.insert(SQLDerivedColumn(token: column))
                continue
            }
            return nil
        }
        return columns
    }

    private static func explicitOutputAlias(in tokens: [SQLToken]) -> SQLToken? {
        var depth = 0
        var alias: SQLToken?
        for index in tokens.indices {
            let token = tokens[index]
            if token.text == "(" {
                depth += 1
                continue
            }
            if token.text == ")" {
                depth = max(0, depth - 1)
                continue
            }
            if depth == 0,
                token.normalized == "as",
                let candidate = tokens[safe: index + 1],
                candidate.isIdentifierLike
            {
                alias = candidate
            }
        }
        return alias
    }

    private static func implicitOutputAlias(in tokens: [SQLToken]) -> SQLToken? {
        guard tokens.count >= 2,
            let alias = tokens.last,
            alias.isIdentifierLike,
            !SQLToken.keywords.contains(alias.normalized),
            let previous = tokens[safe: tokens.count - 2],
            canPrecedeImplicitOutputAlias(previous)
        else {
            return nil
        }
        return alias
    }

    private static func splitTopLevelCommaSeparated(_ tokens: [SQLToken]) -> [[SQLToken]] {
        var groups: [[SQLToken]] = []
        var current: [SQLToken] = []
        var depth = 0
        for token in tokens {
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth = max(0, depth - 1)
            }
            if depth == 0, token.text == "," {
                groups.append(current)
                current = []
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func parseColumnReferences(
        _ tokens: [SQLToken],
        relations: [SQLRelationReference],
        cteNames: Set<String>,
        outputAliases: Set<String>,
        skipNestedSubqueries: Bool = false
    ) -> [SQLColumnReference] {
        var columns: [SQLColumnReference] = []
        var relationAliases = Set<String>()
        for relation in relations {
            if let alias = relation.alias {
                relationAliases.insert(alias.lowercased())
            } else {
                relationAliases.insert(relation.name.lowercased())
                relationAliases.insert(relation.displayName.lowercased())
            }
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if skipNestedSubqueries, token.text == "(" {
                guard let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index) else {
                    break
                }
                let innerTokens = Array(tokens[(index + 1)..<(afterGroup - 1)])
                if containsTopLevelSelect(innerTokens) {
                    index = afterGroup
                    continue
                }
            }
            guard token.isIdentifierLike else {
                index += 1
                continue
            }

            if isSetAssignmentTarget(at: index, tokens: tokens) {
                columns.append(
                    SQLColumnReference(
                        qualifier: nil,
                        name: token.identifierValue,
                        isQuoted: token.kind == .quotedIdentifier,
                        context: .updateSetTarget,
                        startOffset: token.startOffset,
                        endOffset: token.endOffset
                    ))
                index += 1
                continue
            }

            if isInsertTargetColumn(at: index, tokens: tokens) {
                columns.append(
                    SQLColumnReference(
                        qualifier: nil,
                        name: token.identifierValue,
                        isQuoted: token.kind == .quotedIdentifier,
                        context: .insertTarget,
                        startOffset: token.startOffset,
                        endOffset: token.endOffset
                    ))
                index += 1
                continue
            }

            if isJoinUsingColumn(at: index, tokens: tokens) {
                columns.append(
                    SQLColumnReference(
                        qualifier: nil,
                        name: token.identifierValue,
                        isQuoted: token.kind == .quotedIdentifier,
                        context: .joinUsing,
                        startOffset: token.startOffset,
                        endOffset: token.endOffset
                    ))
                index += 1
                continue
            }

            if tokens[safe: index + 1]?.text == ".",
                let table = tokens[safe: index + 2],
                table.isIdentifierLike,
                tokens[safe: index + 3]?.text == ".",
                let column = tokens[safe: index + 4],
                column.isIdentifierLike || column.text == "*"
            {
                columns.append(
                    SQLColumnReference(
                        qualifier: "\(token.identifierValue).\(table.identifierValue)",
                        name: column.text == "*" ? "*" : column.identifierValue,
                        qualifierIsQuoted: token.kind == .quotedIdentifier
                            || table.kind == .quotedIdentifier,
                        isQuoted: column.kind == .quotedIdentifier,
                        startOffset: column.startOffset,
                        endOffset: column.endOffset
                    ))
                index += 5
                continue
            }

            if tokens[safe: index + 1]?.text == ".",
                let column = tokens[safe: index + 2],
                column.isIdentifierLike || column.text == "*"
            {
                let qualifiedName = "\(token.identifierValue).\(column.identifierValue)".lowercased()
                if isQualifiedRelationTarget(at: index, tokens: tokens)
                    || relationAliases.contains(qualifiedName)
                {
                    index += 3
                    continue
                }
                columns.append(
                    SQLColumnReference(
                        qualifier: token.identifierValue,
                        name: column.text == "*" ? "*" : column.identifierValue,
                        qualifierIsQuoted: token.kind == .quotedIdentifier,
                        isQuoted: column.kind == .quotedIdentifier,
                        startOffset: column.startOffset,
                        endOffset: column.endOffset
                    ))
                index += 3
                continue
            }

            let normalized = token.normalized
            if SQLToken.keywords.contains(normalized)
                || cteNames.contains(normalized)
                || (outputAliases.contains(normalized)
                    && isPermittedOutputAliasReference(at: index, tokens: tokens))
                || relationAliases.contains(normalized)
                || isCastTypeName(at: index, tokens: tokens)
                || isInsideExtractField(at: index, tokens: tokens)
                || isOnConflictConstraintName(at: index, tokens: tokens)
                || tokens[safe: index + 1]?.text == "("
                || tokens[safe: index - 1]?.text == "."
                || tokens[safe: index + 1]?.text == "."
            {
                index += 1
                continue
            }
            columns.append(
                SQLColumnReference(
                    qualifier: nil,
                    name: token.identifierValue,
                    isQuoted: token.kind == .quotedIdentifier,
                    startOffset: token.startOffset,
                    endOffset: token.endOffset
                ))
            index += 1
        }
        return columns
    }

    private static func parseUpsertTargetRelations(_ tokens: [SQLToken]) -> [SQLRelationReference] {
        guard hasTopLevelOnConflictDoUpdate(tokens) else { return [] }
        var index = 0
        while index < tokens.count {
            if tokens[index].normalized == "insert",
                let intoIndex = nextTopLevelIndex(ofAny: ["into"], in: tokens, after: index + 1)
            {
                var relationIndex = intoIndex + 1
                if let relation = parseRelation(at: &relationIndex, tokens: tokens) {
                    return [relation]
                }
                return []
            }
            index += 1
        }
        return []
    }

    private static func hasTopLevelOnConflictDoUpdate(_ tokens: [SQLToken]) -> Bool {
        var index = 0
        while index < tokens.count {
            guard let onIndex = nextTopLevelIndex(ofAny: ["on"], in: tokens, after: index) else {
                return false
            }
            if tokens[safe: onIndex + 1]?.normalized == "conflict",
                let doIndex = nextTopLevelIndex(ofAny: ["do"], in: tokens, after: onIndex + 2),
                tokens[safe: doIndex + 1]?.normalized == "update"
            {
                return true
            }
            index = onIndex + 1
        }
        return false
    }

    private static func isPermittedOutputAliasReference(
        at index: Int,
        tokens: [SQLToken]
    ) -> Bool {
        isOutputAliasDefinition(at: index, tokens: tokens)
            || topLevelClause(containing: index, tokens: tokens) == "order"
            || topLevelClause(containing: index, tokens: tokens) == "group"
    }

    private static func isOutputAliasDefinition(at index: Int, tokens: [SQLToken]) -> Bool {
        guard isWithinTopLevelSelectList(index, tokens: tokens) else { return false }
        if tokens[safe: index - 1]?.normalized == "as" {
            return true
        }
        guard let groupRange = topLevelSelectItemRange(containing: index, tokens: tokens),
            let lastIndex = lastSignificantIndex(in: groupRange, tokens: tokens),
            lastIndex == index,
            let previous = tokens[safe: index - 1],
            canPrecedeImplicitOutputAlias(previous)
        else {
            return false
        }
        return true
    }

    private static func isWithinTopLevelSelectList(_ index: Int, tokens: [SQLToken]) -> Bool {
        guard let selectIndex = previousTopLevelIndex(ofAny: ["select"], in: tokens, before: index),
            let fromIndex = nextTopLevelIndex(ofAny: ["from"], in: tokens, after: selectIndex + 1)
        else {
            return false
        }
        return index > selectIndex && index < fromIndex
    }

    private static func topLevelSelectItemRange(
        containing index: Int,
        tokens: [SQLToken]
    ) -> Range<Int>? {
        guard let selectIndex = previousTopLevelIndex(ofAny: ["select"], in: tokens, before: index),
            let fromIndex = nextTopLevelIndex(ofAny: ["from"], in: tokens, after: selectIndex + 1),
            index > selectIndex,
            index < fromIndex
        else {
            return nil
        }
        var start = selectIndex + 1
        var cursor = selectIndex + 1
        var depth = 0
        while cursor < fromIndex {
            if tokens[cursor].text == "(" {
                depth += 1
            } else if tokens[cursor].text == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, tokens[cursor].text == "," {
                if index >= start && index < cursor {
                    return start..<cursor
                }
                start = cursor + 1
            }
            cursor += 1
        }
        return index >= start && index < fromIndex ? start..<fromIndex : nil
    }

    private static func lastSignificantIndex(
        in range: Range<Int>,
        tokens: [SQLToken]
    ) -> Int? {
        range.reversed().first { tokens[$0].text != "," }
    }

    private static func isSetAssignmentTarget(at index: Int, tokens: [SQLToken]) -> Bool {
        guard tokens[safe: index + 1]?.text == "=",
            topLevelClause(containing: index, tokens: tokens) == "set"
        else {
            return false
        }
        return true
    }

    private static func isInsertTargetColumn(at index: Int, tokens: [SQLToken]) -> Bool {
        guard let group = enclosingGroup(containing: index, tokens: tokens),
            let insertIndex = previousTopLevelIndex(ofAny: ["insert"], in: tokens, before: group.openIndex),
            let intoIndex = nextTopLevelIndex(ofAny: ["into"], in: tokens, after: insertIndex + 1),
            intoIndex < group.openIndex
        else {
            return false
        }
        if let clauseBeforeTargetList = nextTopLevelIndex(
            ofAny: ["select", "values", "default", "on", "returning"],
            in: tokens,
            after: intoIndex + 1
        ), clauseBeforeTargetList < group.openIndex {
            return false
        }
        return index > group.openIndex && index < group.closeIndex
    }

    private static func isJoinUsingColumn(at index: Int, tokens: [SQLToken]) -> Bool {
        guard let group = enclosingGroup(containing: index, tokens: tokens),
            tokens[safe: group.openIndex - 1]?.normalized == "using"
        else {
            return false
        }
        return index > group.openIndex && index < group.closeIndex
    }

    private static func isInsideExtractField(at index: Int, tokens: [SQLToken]) -> Bool {
        guard let group = enclosingGroup(containing: index, tokens: tokens),
            tokens[safe: group.openIndex - 1]?.normalized == "extract"
        else {
            return false
        }
        var depth = 0
        for cursor in (group.openIndex + 1)..<index {
            if tokens[cursor].text == "(" {
                depth += 1
            } else if tokens[cursor].text == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, tokens[cursor].normalized == "from" {
                return false
            }
        }
        return true
    }

    private static func enclosingGroup(
        containing index: Int,
        tokens: [SQLToken]
    ) -> (openIndex: Int, closeIndex: Int)? {
        guard index > 0 else { return nil }
        var stack: [Int] = []
        for cursor in 0...min(index, tokens.count - 1) {
            if tokens[cursor].text == "(" {
                stack.append(cursor)
            } else if tokens[cursor].text == ")" {
                _ = stack.popLast()
            }
        }
        guard let openIndex = stack.last,
            let afterGroup = indexAfterBalancedGroup(tokens, startingAt: openIndex)
        else {
            return nil
        }
        return (openIndex, afterGroup - 1)
    }

    private static func derivedColumnsInBalancedGroup(
        _ tokens: [SQLToken],
        startingAt start: Int
    ) -> [SQLDerivedColumn] {
        guard let end = indexAfterBalancedGroup(tokens, startingAt: start) else { return [] }
        return tokens[(start + 1)..<(end - 1)].compactMap { token in
            token.isIdentifierLike ? SQLDerivedColumn(token: token) : nil
        }
    }

    private static func parseOptionalAliasAndColumns(
        _ tokens: [SQLToken],
        startingAt index: Int
    ) -> (alias: String, aliasIsQuoted: Bool, columns: Set<SQLDerivedColumn>?, nextIndex: Int)? {
        var index = index
        if tokens[safe: index]?.normalized == "as" {
            index += 1
        }
        guard let alias = tokens[safe: index],
            alias.isIdentifierLike,
            !relationTerminatorKeywords.contains(alias.normalized)
        else {
            return nil
        }
        let aliasIsQuoted = alias.kind == .quotedIdentifier
        index += 1
        var columns: Set<SQLDerivedColumn>?
        if tokens[safe: index]?.text == "(" {
            columns = Set(derivedColumnsInBalancedGroup(tokens, startingAt: index))
            index = indexAfterBalancedGroup(tokens, startingAt: index) ?? index
        }
        return (alias.identifierValue, aliasIsQuoted, columns, index)
    }

    private static func isCastTypeName(at index: Int, tokens: [SQLToken]) -> Bool {
        if isDoubleColonCastTypeName(at: index, tokens: tokens) {
            return true
        }
        return isInsideCastTypeClause(at: index, tokens: tokens)
    }

    private static func isDoubleColonCastTypeName(at index: Int, tokens: [SQLToken]) -> Bool {
        guard tokens[safe: index]?.isIdentifierLike == true else { return false }
        var cursor = index - 1
        while cursor >= 0 {
            let token = tokens[cursor]
            if token.text == ":",
                tokens[safe: cursor - 1]?.text == ":"
            {
                return true
            }
            if doubleColonCastTypeBoundary(token) {
                return false
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        return false
    }

    private static func doubleColonCastTypeBoundary(_ token: SQLToken) -> Bool {
        if [",", "(", ")", "[", "]", "+", "-", "*", "/", "%", "=", "<", ">", "!"].contains(token.text) {
            return true
        }
        return [
            "as", "select", "from", "where", "group", "having", "order", "limit", "offset",
            "union", "intersect", "except", "join", "on", "set", "values", "returning",
            "and", "or",
        ].contains(token.normalized)
    }

    private static func isInsideCastTypeClause(at index: Int, tokens: [SQLToken]) -> Bool {
        var openParens: [Int] = []
        for cursor in 0..<index {
            if tokens[cursor].text == "(" {
                openParens.append(cursor)
            } else if tokens[cursor].text == ")" {
                _ = openParens.popLast()
            }
        }
        guard let castOpen = openParens.last,
            tokens[safe: castOpen - 1]?.normalized == "cast"
        else {
            return false
        }
        var depth = 0
        for cursor in (castOpen + 1)..<index {
            if tokens[cursor].text == "(" {
                depth += 1
            } else if tokens[cursor].text == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, tokens[cursor].normalized == "as" {
                return true
            }
        }
        return false
    }

    private static func isQualifiedRelationTarget(at index: Int, tokens: [SQLToken]) -> Bool {
        guard tokens[safe: index + 1]?.text == ".",
            tokens[safe: index + 2]?.isIdentifierLike == true
        else {
            return false
        }

        let previous = previousSignificantToken(before: index, in: tokens)?.normalized
        if relationStartKeywords.contains(previous ?? "") {
            return true
        }
        if previous == "only" {
            let beforeOnlyIndex = (0..<index).last { tokens[$0].normalized != "only" }
            if let beforeOnlyIndex {
                return relationStartKeywords.contains(
                    previousSignificantToken(before: beforeOnlyIndex + 1, in: tokens)?.normalized
                        ?? ""
                )
            }
        }
        return false
    }

    private static func isOnConflictConstraintName(at index: Int, tokens: [SQLToken]) -> Bool {
        guard tokens[safe: index - 1]?.normalized == "constraint" else { return false }
        var cursor = index - 2
        while cursor >= 0 {
            if tokens[cursor].normalized == "conflict",
                tokens[safe: cursor - 1]?.normalized == "on"
            {
                return true
            }
            if [",", "(", ")"].contains(tokens[cursor].text)
                || ["select", "from", "where", "returning"].contains(tokens[cursor].normalized)
            {
                return false
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        return false
    }

    private static func statementStartForSelect(at index: Int, tokens: [SQLToken]) -> Int {
        guard let insertIndex = previousTopLevelIndex(ofAny: ["insert"], in: tokens, before: index),
            nextTopLevelIndex(ofAny: ["select"], in: tokens, after: insertIndex + 1) == index
        else {
            return index
        }
        return insertIndex
    }

    private static func canPrecedeImplicitOutputAlias(_ token: SQLToken) -> Bool {
        if token.normalized == "as" || token.text == "." || token.text == ":" {
            return false
        }
        if ["+", "-", "*", "/", "%", "=", "<", ">", "!", "||"].contains(token.text) {
            return false
        }
        if token.kind == .symbol && token.text != ")" {
            return false
        }
        return true
    }

    private static func previousSignificantToken(before index: Int, in tokens: [SQLToken]) -> SQLToken?
    {
        guard index > 0 else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            let token = tokens[cursor]
            if token.text != "," && token.text != "(" && token.text != ")" {
                return token
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        return nil
    }

    private static func firstTopLevelIndex(
        ofAny words: Set<String>,
        in tokens: [SQLToken],
        after start: Int
    ) -> Int? {
        nextTopLevelIndex(ofAny: words, in: tokens, after: start)
    }

    private static func nextTopLevelIndex(
        ofAny words: Set<String>,
        in tokens: [SQLToken],
        after start: Int
    ) -> Int? {
        var depth = 0
        for index in start..<tokens.count {
            if tokens[index].text == "(" {
                depth += 1
            } else if tokens[index].text == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, words.contains(tokens[index].normalized) {
                return index
            }
        }
        return nil
    }

    private static func previousTopLevelIndex(
        ofAny words: Set<String>,
        in tokens: [SQLToken],
        before end: Int
    ) -> Int? {
        var depth = 0
        var index = 0
        var result: Int?
        while index < min(end, tokens.count) {
            if tokens[index].text == "(" {
                depth += 1
            } else if tokens[index].text == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, words.contains(tokens[index].normalized) {
                result = index
            }
            index += 1
        }
        return result
    }

    private static func topLevelClause(containing index: Int, tokens: [SQLToken]) -> String? {
        let clauseKeywords: Set<String> = [
            "select", "from", "where", "group", "having", "order", "limit", "offset", "set",
            "values", "returning", "on", "using",
        ]
        return previousTopLevelIndex(ofAny: clauseKeywords, in: tokens, before: index + 1)
            .map { tokens[$0].normalized }
    }

    private static func containsTopLevelSelect(_ tokens: [SQLToken]) -> Bool {
        nextTopLevelIndex(ofAny: ["select"], in: tokens, after: 0) != nil
            || tokens.first?.normalized == "select"
    }

    private static func indexAfterBalancedGroup(_ tokens: [SQLToken], startingAt start: Int) -> Int? {
        guard tokens[safe: start]?.text == "(" else { return nil }
        var depth = 0
        for index in start..<tokens.count {
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

    private static func deduplicated<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static let relationTerminatorKeywords: Set<String> = [
        "on", "using", "where", "join", "left", "right", "inner", "outer", "full", "cross",
        "group", "order", "limit", "offset", "union", "returning", "set", "values",
        "default", "conflict", "do", "nothing",
    ]

    private static let relationStartKeywords: Set<String> = [
        "from", "join", "update", "into", "using",
    ]
}

struct SQLToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case identifier
        case quotedIdentifier
        case string
        case number
        case symbol
    }

    var text: String
    var kind: Kind
    var startOffset: Int
    var endOffset: Int

    init(text: String, kind: Kind, startOffset: Int = -1, endOffset: Int = -1) {
        self.text = text
        self.kind = kind
        self.startOffset = startOffset
        self.endOffset = endOffset
    }

    var normalized: String {
        identifierValue.lowercased()
    }

    var identifierValue: String {
        switch kind {
        case .quotedIdentifier:
            String(text.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        default:
            text
        }
    }

    var isIdentifierLike: Bool {
        kind == .identifier || kind == .quotedIdentifier
    }

    static func tokenize(_ sql: String) -> [SQLToken] {
        let chars = Array(sql)
        var tokens: [SQLToken] = []
        var index = 0

        while index < chars.count {
            let character = chars[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "-", chars[safe: index + 1] == "-" {
                index += 2
                while index < chars.count, chars[index] != "\n" {
                    index += 1
                }
                continue
            }
            if character == "/", chars[safe: index + 1] == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") {
                    index += 1
                }
                index = min(chars.count, index + 2)
                continue
            }
            if character == "'" {
                let start = index
                index += 1
                while index < chars.count {
                    if chars[index] == "'" {
                        if chars[safe: index + 1] == "'" {
                            index += 2
                        } else {
                            index += 1
                            break
                        }
                    } else {
                        index += 1
                    }
                }
                tokens.append(
                    SQLToken(
                        text: String(chars[start..<min(index, chars.count)]),
                        kind: .string,
                        startOffset: start,
                        endOffset: min(index, chars.count)
                    ))
                continue
            }
            if character == "$" {
                let start = index
                index += 1
                while index < chars.count,
                    chars[index].isLetter || chars[index].isNumber || chars[index] == "_"
                {
                    index += 1
                }
                if index < chars.count, chars[index] == "$" {
                    let delimiter = String(chars[start...index])
                    index += 1
                    while index < chars.count {
                        let possibleEnd = min(chars.count, index + delimiter.count)
                        if String(chars[index..<possibleEnd]) == delimiter {
                            index = possibleEnd
                            break
                        }
                        index += 1
                    }
                    tokens.append(
                        SQLToken(
                            text: String(chars[start..<min(index, chars.count)]),
                            kind: .string,
                            startOffset: start,
                            endOffset: min(index, chars.count)
                        ))
                    continue
                }
                tokens.append(
                    SQLToken(
                        text: String(chars[start..<index]),
                        kind: .symbol,
                        startOffset: start,
                        endOffset: index
                    ))
                continue
            }
            if character == "\"" {
                let start = index
                index += 1
                while index < chars.count {
                    if chars[index] == "\"" {
                        if chars[safe: index + 1] == "\"" {
                            index += 2
                        } else {
                            index += 1
                            break
                        }
                    } else {
                        index += 1
                    }
                }
                tokens.append(
                    SQLToken(
                        text: String(chars[start..<min(index, chars.count)]),
                        kind: .quotedIdentifier,
                        startOffset: start,
                        endOffset: min(index, chars.count)
                    )
                )
                continue
            }
            if isPrefixedStringLiteralStart(chars, at: index) {
                let start = index
                let allowsBackslashEscapes = String(chars[index]).lowercased() == "e"
                index = consumeSingleQuotedString(
                    chars,
                    startingAt: index + 1,
                    allowsBackslashEscapes: allowsBackslashEscapes
                )
                tokens.append(
                    SQLToken(
                        text: String(chars[start..<min(index, chars.count)]),
                        kind: .string,
                        startOffset: start,
                        endOffset: min(index, chars.count)
                    ))
                continue
            }
            if character.isLetter || character == "_" {
                let start = index
                index += 1
                while index < chars.count,
                    chars[index].isLetter || chars[index].isNumber || chars[index] == "_" || chars[index] == "$"
                {
                    index += 1
                }
                tokens.append(
                    SQLToken(
                        text: String(chars[start..<index]),
                        kind: .identifier,
                        startOffset: start,
                        endOffset: index
                    ))
                continue
            }
            if character.isNumber {
                let start = index
                index += 1
                while index < chars.count, chars[index].isNumber || chars[index] == "." {
                    index += 1
                }
                tokens.append(
                    SQLToken(
                        text: String(chars[start..<index]),
                        kind: .number,
                        startOffset: start,
                        endOffset: index
                    ))
                continue
            }
            tokens.append(
                SQLToken(
                    text: String(character),
                    kind: .symbol,
                    startOffset: index,
                    endOffset: index + 1
                ))
            index += 1
        }

        return tokens
    }

    private static func isPrefixedStringLiteralStart(_ chars: [Character], at index: Int) -> Bool {
        guard let character = chars[safe: index],
            ["e", "b", "x"].contains(String(character).lowercased()),
            chars[safe: index + 1] == "'"
        else {
            return false
        }
        return true
    }

    private static func consumeSingleQuotedString(
        _ chars: [Character],
        startingAt quoteIndex: Int,
        allowsBackslashEscapes: Bool
    ) -> Int {
        var index = quoteIndex + 1
        while index < chars.count {
            if allowsBackslashEscapes, chars[index] == "\\" {
                index = min(chars.count, index + 2)
                continue
            }
            if chars[index] == "'" {
                if chars[safe: index + 1] == "'" {
                    index += 2
                } else {
                    index += 1
                    break
                }
            } else {
                index += 1
            }
        }
        return min(index, chars.count)
    }

    static let keywords: Set<String> = [
        "select", "from", "where", "join", "on", "as", "with", "recursive", "group", "by",
        "order", "limit", "offset", "having", "and", "or", "not", "null", "is", "in",
        "between", "case", "when", "then", "else", "end", "asc", "desc", "insert", "into",
        "update", "delete", "set", "values", "returning", "distinct", "over", "partition",
        "filter", "left", "right", "inner", "outer", "full", "cross", "lateral", "only",
        "using", "at", "time", "zone",
        "true", "false", "interval", "current_date", "current_timestamp", "now", "like",
        "ilike", "similar", "escape", "nulls", "first", "last", "default", "conflict",
        "do", "nothing", "constraint", "rows", "row", "range", "groups", "unbounded",
        "preceding", "current", "following",
    ]
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
