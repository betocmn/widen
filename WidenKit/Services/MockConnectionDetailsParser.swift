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
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("export ") {
                trimmed = String(trimmed.dropFirst("export ".count))
            }
            guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == ":" }) else {
                continue
            }
            let key = trimmed[..<separator]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = Self.cleanedValue(String(trimmed[trimmed.index(after: separator)...]))
            guard !key.isEmpty else { continue }
            values[key] = value
        }

        // Sorted so repeated fragments resolve deterministically. Values
        // containing a URL scheme are skipped — a DATABASE_URL that failed
        // URL parsing should not land in a single field.
        let sortedValues = values.sorted { $0.key < $1.key }
        func value(where matches: (String) -> Bool) -> String? {
            sortedValues
                .first { matches($0.key) && !$0.value.contains("://") }?
                .value
        }
        func value(containing fragment: String) -> String? {
            value { $0.contains(fragment) }
        }
        func value(endingWith suffix: String) -> String? {
            value { $0.hasSuffix(suffix) }
        }

        let password = value(containing: "pass")
        let sslMode = value(endingWith: "sslmode") ?? value(endingWith: "ssl_mode")
            ?? value(containing: "ssl")
        return .sanitized(
            host: value(containing: "host"),
            port: value(containing: "port").flatMap { Int($0) },
            database: values["dbname"] ?? values["db"]
                ?? value(containing: "database") ?? value(containing: "db_name")
                ?? value(endingWith: "_db"),
            username: value(containing: "user"),
            password: password,
            sslModeText: sslMode,
            preservesEmptyPassword: password != nil
        )
    }

    private static func cleanedValue(_ rawValue: String) -> String {
        stripUnquotedComment(from: rawValue)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
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
}
