import Foundation

public struct SQLRelationReference: Equatable, Hashable, Sendable {
    public var schema: String?
    public var name: String
    public var alias: String?

    public var displayName: String {
        if let schema { return "\(schema).\(name)" }
        return name
    }
}

public struct SQLColumnReference: Equatable, Hashable, Sendable {
    public var qualifier: String?
    public var name: String
    public var isQuoted: Bool

    public init(qualifier: String?, name: String, isQuoted: Bool = false) {
        self.qualifier = qualifier
        self.name = name
        self.isQuoted = isQuoted
    }
}

public struct SQLReferenceAnalysis: Equatable, Sendable {
    public var relations: [SQLRelationReference]
    public var columns: [SQLColumnReference]
    public var cteNames: Set<String>
    public var cteOutputColumns: [String: Set<String>?]
    public var outputAliases: Set<String>
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
        var cteOutputColumns: [String: Set<String>?] = [:]
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
            scopes: scopes,
            analysisIncomplete: incomplete
        )
    }

    @discardableResult
    private static func parseCTEs(
        _ tokens: [SQLToken],
        cteNames: inout Set<String>,
        cteOutputColumns: inout [String: Set<String>?],
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

            var explicitColumns: Set<String>?
            if tokens[safe: index]?.text == "(" {
                let columns = identifiersInBalancedGroup(tokens, startingAt: index)
                explicitColumns = Set(columns.map { $0.lowercased() })
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
                let relations = parseRelations(
                    Array(tokens[index..<statementEnd]),
                    cteNames: cteNames,
                    incomplete: &incomplete,
                    skipCTEs: false
                )
                let outputAliases = parseOutputAliases(Array(tokens[index..<statementEnd]))
                let columns = parseColumnReferences(
                    Array(tokens[index..<statementEnd]),
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

            if isRelationStart {
                index += 1
                while index < tokens.count {
                    if let current = tokens[safe: index],
                        relationTerminatorKeywords.contains(current.normalized)
                    {
                        break
                    }
                    if tokens[safe: index]?.normalized == "only" {
                        index += 1
                    }
                    if tokens[safe: index]?.text == "(" {
                        if let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index) {
                            index = afterGroup
                            if let aliasIndex = skipOptionalAlias(tokens, startingAt: index) {
                                index = aliasIndex
                            }
                        } else {
                            incomplete = true
                            return relations
                        }
                    } else if let relation = parseRelation(at: &index, tokens: tokens) {
                        if !skipCTEs || !cteNames.contains(relation.name.lowercased()) {
                            relations.append(relation)
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
        index += 1
        if tokens[safe: index]?.text == ".",
            let second = tokens[safe: index + 1],
            second.isIdentifierLike
        {
            schema = name
            name = second.identifierValue
            index += 2
        }

        var alias: String?
        if tokens[safe: index]?.normalized == "as" {
            index += 1
            if let aliasToken = tokens[safe: index], aliasToken.isIdentifierLike {
                alias = aliasToken.identifierValue
                index += 1
            }
        } else if let aliasToken = tokens[safe: index],
            aliasToken.isIdentifierLike,
            !relationTerminatorKeywords.contains(aliasToken.normalized)
        {
            alias = aliasToken.identifierValue
            index += 1
        }

        return SQLRelationReference(schema: schema, name: name, alias: alias)
    }

    private static func parseOutputAliases(_ tokens: [SQLToken]) -> Set<String> {
        guard let selectIndex = tokens.firstIndex(where: { $0.normalized == "select" }) else {
            return []
        }
        let fromIndex = firstTopLevelIndex(ofAny: ["from"], in: tokens, after: selectIndex + 1)
            ?? tokens.count
        var aliases = Set<String>()
        var index = selectIndex + 1
        while index < fromIndex {
            if tokens[index].normalized == "as",
                let alias = tokens[safe: index + 1],
                alias.isIdentifierLike
            {
                aliases.insert(alias.identifierValue.lowercased())
                index += 2
                continue
            }
            index += 1
        }
        return aliases
    }

    private static func inferSelectOutputColumns(_ tokens: [SQLToken]) -> Set<String>? {
        guard let selectIndex = tokens.firstIndex(where: { $0.normalized == "select" }) else {
            return nil
        }
        let fromIndex = firstTopLevelIndex(ofAny: ["from"], in: tokens, after: selectIndex + 1)
            ?? tokens.count
        let items = splitTopLevelCommaSeparated(Array(tokens[(selectIndex + 1)..<fromIndex]))
        var columns = Set<String>()
        for item in items {
            let significant = item.filter { $0.text != "," }
            guard !significant.isEmpty else { continue }
            if significant.contains(where: { $0.text == "*" }) {
                return nil
            }
            if let asIndex = significant.lastIndex(where: { $0.normalized == "as" }),
                let alias = significant[safe: asIndex + 1],
                alias.isIdentifierLike
            {
                columns.insert(alias.identifierValue.lowercased())
                continue
            }
            if significant.count >= 2,
                let alias = significant.last,
                alias.isIdentifierLike,
                significant[safe: significant.count - 2]?.text != ".",
                significant[safe: significant.count - 2]?.text != ")"
            {
                columns.insert(alias.identifierValue.lowercased())
                continue
            }
            if significant.count == 1, let column = significant.first, column.isIdentifierLike {
                columns.insert(column.identifierValue.lowercased())
                continue
            }
            if significant.count == 3,
                significant[safe: 1]?.text == ".",
                let column = significant.last,
                column.isIdentifierLike
            {
                columns.insert(column.identifierValue.lowercased())
                continue
            }
            return nil
        }
        return columns
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
            relationAliases.insert(relation.name.lowercased())
            relationAliases.insert(relation.displayName.lowercased())
            if let alias = relation.alias {
                relationAliases.insert(alias.lowercased())
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
                        isQuoted: column.kind == .quotedIdentifier
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
                        isQuoted: column.kind == .quotedIdentifier
                    ))
                index += 3
                continue
            }

            let normalized = token.normalized
            if SQLToken.keywords.contains(normalized)
                || cteNames.contains(normalized)
                || outputAliases.contains(normalized)
                || relationAliases.contains(normalized)
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
                    isQuoted: token.kind == .quotedIdentifier
                ))
            index += 1
        }
        return columns
    }

    private static func identifiersInBalancedGroup(_ tokens: [SQLToken], startingAt start: Int) -> [String] {
        guard let end = indexAfterBalancedGroup(tokens, startingAt: start) else { return [] }
        return tokens[(start + 1)..<(end - 1)].compactMap { token in
            token.isIdentifierLike ? token.identifierValue : nil
        }
    }

    private static func skipOptionalAlias(_ tokens: [SQLToken], startingAt index: Int) -> Int? {
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
        return index + 1
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
    ]

    private static let relationStartKeywords: Set<String> = [
        "from", "join", "update", "into",
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
                tokens.append(SQLToken(text: String(chars[start..<min(index, chars.count)]), kind: .string))
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
                    SQLToken(text: String(chars[start..<min(index, chars.count)]), kind: .quotedIdentifier)
                )
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
                tokens.append(SQLToken(text: String(chars[start..<index]), kind: .identifier))
                continue
            }
            if character.isNumber {
                let start = index
                index += 1
                while index < chars.count, chars[index].isNumber || chars[index] == "." {
                    index += 1
                }
                tokens.append(SQLToken(text: String(chars[start..<index]), kind: .number))
                continue
            }
            tokens.append(SQLToken(text: String(character), kind: .symbol))
            index += 1
        }

        return tokens
    }

    static let keywords: Set<String> = [
        "select", "from", "where", "join", "on", "as", "with", "recursive", "group", "by",
        "order", "limit", "offset", "having", "and", "or", "not", "null", "is", "in",
        "between", "case", "when", "then", "else", "end", "asc", "desc", "insert", "into",
        "update", "delete", "set", "values", "returning", "distinct", "over", "partition",
        "filter", "left", "right", "inner", "outer", "full", "cross", "lateral", "only",
        "true", "false", "interval", "current_date", "current_timestamp", "now",
    ]
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
