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
}

public struct SQLReferenceAnalysis: Equatable, Sendable {
    public var relations: [SQLRelationReference]
    public var columns: [SQLColumnReference]
    public var cteNames: Set<String>
    public var outputAliases: Set<String>
    public var analysisIncomplete: Bool
}

public enum SQLReferenceAnalyzer {
    public static func analyze(_ sql: String) -> SQLReferenceAnalysis {
        let tokens = SQLToken.tokenize(sql)
        var cteNames = Set<String>()
        var relations: [SQLRelationReference] = []
        var outputAliases = Set<String>()
        var incomplete = false

        parseCTEs(tokens, cteNames: &cteNames, incomplete: &incomplete)
        relations.append(contentsOf: parseRelations(tokens, cteNames: cteNames, incomplete: &incomplete))
        outputAliases.formUnion(parseOutputAliases(tokens))
        let columns = parseColumnReferences(
            tokens,
            relations: relations,
            cteNames: cteNames,
            outputAliases: outputAliases
        )

        return SQLReferenceAnalysis(
            relations: deduplicated(relations),
            columns: deduplicated(columns),
            cteNames: cteNames,
            outputAliases: outputAliases,
            analysisIncomplete: incomplete
        )
    }

    private static func parseCTEs(
        _ tokens: [SQLToken],
        cteNames: inout Set<String>,
        incomplete: inout Bool
    ) {
        guard tokens.first?.normalized == "with" else { return }
        var index = 1
        if tokens[safe: index]?.normalized == "recursive" {
            index += 1
        }

        while index < tokens.count {
            guard let nameToken = tokens[safe: index], nameToken.isIdentifierLike else {
                incomplete = true
                return
            }
            cteNames.insert(nameToken.identifierValue)
            index += 1

            if tokens[safe: index]?.text == "(" {
                index = indexAfterBalancedGroup(tokens, startingAt: index) ?? tokens.count
            }
            guard tokens[safe: index]?.normalized == "as" else {
                incomplete = true
                return
            }
            index += 1
            guard tokens[safe: index]?.text == "(",
                let afterSubquery = indexAfterBalancedGroup(tokens, startingAt: index)
            else {
                incomplete = true
                return
            }
            index = afterSubquery
            if tokens[safe: index]?.text == "," {
                index += 1
                continue
            }
            return
        }
    }

    private static func parseRelations(
        _ tokens: [SQLToken],
        cteNames: Set<String>,
        incomplete: inout Bool
    ) -> [SQLRelationReference] {
        var relations: [SQLRelationReference] = []
        var index = 0
        var previousKeyword: String?
        while index < tokens.count {
            let token = tokens[index]
            let normalized = token.normalized
            let isRelationStart =
                normalized == "from"
                || normalized == "join"
                || normalized == "update"
                || (normalized == "into" && previousKeyword == "insert")
                || (normalized == "from" && previousKeyword == "delete")

            if isRelationStart {
                index += 1
                if tokens[safe: index]?.normalized == "only" {
                    index += 1
                }
                if tokens[safe: index]?.text == "(" {
                    if let afterGroup = indexAfterBalancedGroup(tokens, startingAt: index) {
                        index = afterGroup
                    } else {
                        incomplete = true
                        return relations
                    }
                    continue
                }
                if let relation = parseRelation(at: &index, tokens: tokens) {
                    if !cteNames.contains(relation.name.lowercased()) {
                        relations.append(relation)
                    }
                    continue
                }
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

    private static func parseColumnReferences(
        _ tokens: [SQLToken],
        relations: [SQLRelationReference],
        cteNames: Set<String>,
        outputAliases: Set<String>
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
                if column.text != "*" {
                    columns.append(
                        SQLColumnReference(
                            qualifier: "\(token.identifierValue).\(table.identifierValue)",
                            name: column.identifierValue
                        ))
                }
                index += 5
                continue
            }

            if tokens[safe: index + 1]?.text == ".",
                let column = tokens[safe: index + 2],
                column.isIdentifierLike || column.text == "*"
            {
                if isQualifiedRelationTarget(at: index, tokens: tokens) {
                    index += 3
                    continue
                }
                if column.text != "*" {
                    columns.append(
                        SQLColumnReference(
                            qualifier: token.identifierValue,
                            name: column.identifierValue
                        ))
                }
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
            columns.append(SQLColumnReference(qualifier: nil, name: token.identifierValue))
            index += 1
        }
        return columns
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
