import Foundation

/// Deterministic stand-in for the on-device parser: handles connection URLs
/// and KEY=VALUE lines without any language model. Used in mock-AI mode and
/// tests.
public struct MockConnectionDetailsParser: ConnectionDetailsParsing {
    public init() {}

    public func parse(_ text: String) async throws -> ParsedConnectionDetails {
        if let url = Self.firstConnectionURL(in: text),
            let details = Self.details(from: url)
        {
            return details
        }
        return Self.details(fromKeyValues: text)
    }

    /// Finds the first postgres:// or postgresql:// URL, including one on the
    /// right-hand side of an assignment like DATABASE_URL=postgres://…
    static func firstConnectionURL(in text: String) -> URL? {
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) {
            for scheme in ["postgresql://", "postgres://"] {
                if let range = token.range(of: scheme, options: .caseInsensitive) {
                    return URL(string: String(token[range.lowerBound...]))
                }
            }
        }
        return nil
    }

    static func details(from url: URL) -> ParsedConnectionDetails? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let sslModeText = components.queryItems?
            .first { $0.name.lowercased() == "sslmode" }?.value
        return .sanitized(
            host: components.host,
            port: components.port,
            database: components.path,
            username: components.user,
            password: components.password,
            sslModeText: sslModeText
        )
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
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty, !value.isEmpty else { continue }
            values[key] = value
        }

        // Sorted so repeated fragments resolve deterministically. Values
        // containing a URL scheme are skipped — a DATABASE_URL that failed
        // URL parsing should not land in a single field.
        func value(containing fragment: String) -> String? {
            values
                .sorted { $0.key < $1.key }
                .first { $0.key.contains(fragment) && !$0.value.contains("://") }?
                .value
        }

        return .sanitized(
            host: value(containing: "host"),
            port: value(containing: "port").flatMap { Int($0) },
            database: values["dbname"] ?? values["db"]
                ?? value(containing: "database") ?? value(containing: "db_name"),
            username: value(containing: "user"),
            password: value(containing: "pass"),
            sslModeText: value(containing: "ssl")
        )
    }
}
