import Foundation

/// Deterministic stand-in for the on-device parser: handles connection URLs
/// and KEY=VALUE lines without any language model. Used in mock-AI mode and
/// tests.
public struct MockConnectionDetailsParser: ConnectionDetailsParsing {
    public init() {}

    public func parse(_ text: String) async throws -> ParsedConnectionDetails {
        // A pasted URL is parsed deterministically and wins over the
        // KEY=VALUE scan, matching the on-device parser's merge.
        let keyValues = Self.details(fromKeyValues: text)
        if let url = ConnectionURLParser.details(in: text) {
            return keyValues.overridden(by: url)
        }
        return keyValues
    }

    static func details(fromKeyValues text: String) -> ParsedConnectionDetails {
        var values = Self.jsonObjectValues(from: text) ?? [:]
        if values.isEmpty {
            for line in text.split(whereSeparator: \.isNewline) {
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#") else { continue }
                if trimmed.hasPrefix("export ") {
                    trimmed = String(trimmed.dropFirst("export ".count))
                }
                for (key, value) in keyValuePairs(in: String(trimmed)) {
                    values[key] = value
                }
            }
        }

        // Sorted so repeated fragments resolve deterministically. Values
        // containing a URL scheme are skipped — a DATABASE_URL that failed
        // URL parsing should not land in a single field.
        let sortedValues = values.sorted { $0.key < $1.key }
        func value(where matches: (String) -> Bool) -> String? {
            sortedValues
                .first { matches($0.key) && !isURLBearingValue(key: $0.key, value: $0.value) }?
                .value
        }
        func value(exactly key: String) -> String? {
            value { $0 == key }
        }
        func value(containing fragment: String) -> String? {
            value { $0.contains(fragment) }
        }
        func value(endingWith suffix: String) -> String? {
            value { $0.hasSuffix(suffix) }
        }

        let password = value(where: isPasswordKey)
        let sslMode = value(endingWith: "sslmode") ?? value(endingWith: "ssl_mode")
            ?? value(containing: "ssl")
        return .sanitized(
            host: value(containing: "host"),
            port: value(containing: "port").flatMap { Int($0) },
            database: values["dbname"] ?? values["db"] ?? values["pgdatabase"]
                ?? value(exactly: "database") ?? value(endingWith: "database_name")
                ?? value(endingWith: "_database") ?? value(endingWith: "db_name")
                ?? value(endingWith: "_db"),
            username: value(containing: "user"),
            password: password,
            sslModeText: sslMode,
            preservesEmptyPassword: password != nil
        )
    }

    private static func keyValuePairs(in line: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        var index = line.startIndex

        while index < line.endIndex {
            skipPairDelimiters(in: line, from: &index)
            guard index < line.endIndex else { break }

            let keyStart = index
            if line[index] == "\"" || line[index] == "'" {
                let quote = line[index]
                index = line.index(after: index)
                while index < line.endIndex, line[index] != quote {
                    index = line.index(after: index)
                }
                if index < line.endIndex { index = line.index(after: index) }
            } else {
                while index < line.endIndex,
                    !line[index].isWhitespace,
                    line[index] != "=",
                    line[index] != ":",
                    line[index] != ","
                {
                    index = line.index(after: index)
                }
            }

            let rawKey = String(line[keyStart..<index])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}"))
                .lowercased()
            skipSpaces(in: line, from: &index)
            guard index < line.endIndex, line[index] == "=" || line[index] == ":" else {
                continue
            }
            index = line.index(after: index)
            skipSpaces(in: line, from: &index)

            let rawValue = rawValue(in: line, from: &index)
            guard !rawKey.isEmpty else { continue }
            pairs.append((rawKey, cleanedValue(rawValue)))
        }
        return pairs
    }

    private static func rawValue(in line: String, from index: inout String.Index) -> String {
        let valueStart = index
        if index < line.endIndex, line[index] == "\"" || line[index] == "'" {
            let quote = line[index]
            index = line.index(after: index)
            var isEscaped = false
            while index < line.endIndex {
                let character = line[index]
                if isEscaped {
                    isEscaped = false
                } else if character == "\\", quote == "\"" {
                    isEscaped = true
                } else if character == quote {
                    index = line.index(after: index)
                    break
                }
                index = line.index(after: index)
            }
            return String(line[valueStart..<index])
        }

        while index < line.endIndex {
            if line[index] == "," {
                let next = indexAfterPairDelimiter(in: line, from: index)
                if beginsKeyValuePair(in: line, at: next) { break }
            }
            if startsInlineComment(in: line, at: index, after: valueStart) {
                break
            }
            if line[index].isWhitespace {
                let next = indexAfterSpaces(in: line, from: index)
                if beginsKeyValuePair(in: line, at: next) { break }
            }
            index = line.index(after: index)
        }
        return String(line[valueStart..<index])
    }

    private static func skipPairDelimiters(in line: String, from index: inout String.Index) {
        while index < line.endIndex,
            line[index].isWhitespace || line[index] == "," || line[index] == "{" || line[index] == "}"
        {
            index = line.index(after: index)
        }
    }

    private static func skipSpaces(in line: String, from index: inout String.Index) {
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
    }

    private static func indexAfterSpaces(in line: String, from index: String.Index) -> String.Index {
        var next = index
        skipSpaces(in: line, from: &next)
        return next
    }

    private static func indexAfterPairDelimiter(
        in line: String, from index: String.Index
    ) -> String.Index {
        var next = line.index(after: index)
        skipSpaces(in: line, from: &next)
        return next
    }

    private static func beginsKeyValuePair(in line: String, at index: String.Index) -> Bool {
        var cursor = index
        guard cursor < line.endIndex else { return false }

        if line[cursor] == "\"" || line[cursor] == "'" {
            let quote = line[cursor]
            cursor = line.index(after: cursor)
            while cursor < line.endIndex, line[cursor] != quote {
                cursor = line.index(after: cursor)
            }
            guard cursor < line.endIndex else { return false }
            cursor = line.index(after: cursor)
        } else {
            while cursor < line.endIndex,
                !line[cursor].isWhitespace,
                line[cursor] != "=",
                line[cursor] != ":",
                line[cursor] != ","
            {
                cursor = line.index(after: cursor)
            }
        }

        skipSpaces(in: line, from: &cursor)
        return cursor < line.endIndex && (line[cursor] == "=" || line[cursor] == ":")
    }

    private static func startsInlineComment(
        in line: String, at index: String.Index, after valueStart: String.Index
    ) -> Bool {
        guard line[index] == "#" else { return false }
        return startsComment(after: String(line[valueStart..<index]))
    }

    private static func cleanedValue(_ rawValue: String) -> String {
        var value = stripUnquotedComment(from: rawValue)
            .trimmingCharacters(in: .whitespaces)
        while value.last == "," {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func stripUnquotedComment(from value: String) -> String {
        var result = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        for character in value {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }

            if character == "\\", inDoubleQuote {
                result.append(character)
                isEscaped = true
                continue
            }
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                result.append(character)
                continue
            }
            if character == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                result.append(character)
                continue
            }
            if character == "#", !inSingleQuote, !inDoubleQuote,
                startsComment(after: result)
            {
                break
            }
            result.append(character)
        }
        return result
    }

    private static func startsComment(after prefix: String) -> Bool {
        prefix.trimmingCharacters(in: .whitespaces).isEmpty
            || prefix.last?.isWhitespace == true
    }

    private static func isURLBearingValue(key: String, value: String) -> Bool {
        key.contains("url") && value.contains("://")
    }

    private static func isPasswordKey(_ key: String) -> Bool {
        key.contains("pass")
            && !key.contains("passfile")
            && !key.contains("pass_file")
            && !key.contains("password_file")
    }

    private static func jsonObjectValues(from text: String) -> [String: String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        var values: [String: String] = [:]
        for (key, value) in object {
            guard let stringValue = stringValue(from: value) else { continue }
            values[key.lowercased()] = stringValue
        }
        return values
    }

    private static func stringValue(from value: Any) -> String? {
        switch value {
        case let value as String:
            value
        case let value as Bool:
            value ? "true" : "false"
        case let value as NSNumber:
            value.stringValue
        default:
            nil
        }
    }
}
