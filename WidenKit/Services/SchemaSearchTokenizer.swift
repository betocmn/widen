import Foundation

enum SchemaSearchTokenizer {
    static let version = "schema-search-tokenizer-v2"

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "get", "give",
        "in", "is", "it", "last", "list", "me", "most", "of", "on", "or", "over", "per",
        "show", "that", "the", "these", "this", "to", "top", "what", "which", "with",
    ]

    static func queryTokens(in text: String) -> [String] {
        tokens(in: text, dropStopwords: true)
    }

    static func indexTokens(in text: String) -> [String] {
        tokens(in: text, dropStopwords: false)
    }

    static func tokens(in text: String, dropStopwords: Bool) -> [String] {
        let sanitized = text
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "'", with: " ")
        var expanded = ""
        var previous: Character?
        for character in sanitized {
            if let previous,
                ((previous.isLowercase && character.isUppercase)
                    || (previous.isNumber && character.isLetter)
                    || (previous.isLetter && character.isNumber))
            {
                expanded.append(" ")
            }
            expanded.append(character)
            previous = character
        }

        let rawTokens = expanded
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var result: [String] = []
        for token in rawTokens {
            for normalized in normalizedForms(for: token) {
                guard !normalized.isEmpty else { continue }
                if dropStopwords, stopwords.contains(normalized) {
                    continue
                }
                if seen.insert(normalized).inserted {
                    result.append(normalized)
                }
            }
        }
        return result
    }

    static func normalizedForms(for token: String) -> [String] {
        var forms = [token]
        if token.hasSuffix("ies"), token.count > 4 {
            forms.append(String(token.dropLast(3)) + "y")
        } else if token.hasSuffix("es"), token.count > 4 {
            forms.append(String(token.dropLast(2)))
        } else if token.hasSuffix("s"), token.count > 3 {
            forms.append(String(token.dropLast()))
        }
        return Array(Set(forms)).sorted()
    }

    static func sanitizedComment(_ text: String?, limit: Int = 2_048) -> String {
        guard let text, !text.isEmpty else { return "" }
        let scalars = text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }
        return String(scalars.joined().prefix(limit))
    }

    static func canFuzzyMatch(_ token: String) -> Bool {
        token.count >= 6
    }

    static func fuzzyDistanceLimit(for token: String) -> Int {
        token.count >= 9 ? 2 : 1
    }

    static func similarity(queryToken: String, indexedToken: String) -> Double {
        guard queryToken != indexedToken else { return 1 }
        guard queryToken.count >= 3, indexedToken.count >= 3 else { return 0 }
        if indexedToken.hasPrefix(queryToken) || queryToken.hasPrefix(indexedToken) {
            return min(queryToken.count, indexedToken.count) >= 3 ? 0.28 : 0
        }
        if queryToken.count >= 4, indexedToken.contains(queryToken) {
            return 0.16
        }
        guard canFuzzyMatch(queryToken), canFuzzyMatch(indexedToken) else {
            return 0
        }
        let limit = min(fuzzyDistanceLimit(for: queryToken), fuzzyDistanceLimit(for: indexedToken))
        let distance = levenshtein(queryToken, indexedToken, limit: limit)
        return distance <= limit ? (distance == 1 ? 0.42 : 0.24) : 0
    }

    static func levenshtein(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if abs(a.count - b.count) > limit {
            return limit + 1
        }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit {
                return limit + 1
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func identifierAliases(schema: String, table: String) -> Set<String> {
        var aliases = Set(identifierForms(table))
        for schemaPart in identifierForms(schema) {
            for tablePart in identifierForms(table) {
                aliases.insert("\(schemaPart).\(tablePart)")
            }
        }
        return aliases
    }

    static func identifierAliases(schema: String, table: String, column: String) -> Set<String> {
        var aliases = Set(identifierForms(column))
        for tablePart in identifierForms(table) {
            for columnPart in identifierForms(column) {
                aliases.insert("\(tablePart).\(columnPart)")
            }
        }
        for schemaPart in identifierForms(schema) {
            for tablePart in identifierForms(table) {
                for columnPart in identifierForms(column) {
                    aliases.insert("\(schemaPart).\(tablePart).\(columnPart)")
                }
            }
        }
        return aliases
    }

    private static func identifierForms(_ identifier: String) -> [String] {
        let quoted = quotedIdentifier(identifier)
        if canReferenceUnquoted(identifier) {
            return [identifier, quoted]
        }
        return [quoted]
    }

    static func canReferenceUnquoted(_ identifier: String) -> Bool {
        guard let first = identifier.first,
            first == "_" || (first >= "a" && first <= "z")
        else { return false }

        return identifier.dropFirst().allSatisfy {
            $0 == "_" || $0 == "$" || ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9")
        }
    }
}
