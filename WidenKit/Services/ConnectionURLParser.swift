import Foundation

/// Deterministically extracts connection fields from a `postgres://` or
/// `postgresql://` URL found in pasted text.
///
/// A connection URL has a fixed structure, so it is parsed in code rather than
/// handed to the on-device model — the small model sometimes truncates a
/// dotted username (e.g. Supabase's `postgres.<project-ref>`) or mis-splits the
/// password. Parsing is done by hand instead of with `URLComponents` because
/// real-world Postgres passwords often contain unencoded `@`, `/`, or `:`,
/// which make `URL(string:)` return nil or split in the wrong place.
public enum ConnectionURLParser {
    /// Extracts the fields of the first connection URL in `text`, or nil when
    /// the text contains no recognizable `postgres`/`postgresql` URL.
    public static func details(in text: String) -> ParsedConnectionDetails? {
        guard let raw = firstConnectionURL(in: text) else { return nil }
        let details = details(fromURLString: raw)
        return details.isEmpty ? nil : details
    }

    /// The first whitespace/quote-delimited token containing a postgres scheme,
    /// trimmed to start at the scheme so `DATABASE_URL=postgres://…` works.
    static func firstConnectionURL(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) {
            for scheme in ["postgresql://", "postgres://"] {
                if let range = token.range(of: scheme, options: .caseInsensitive) {
                    return trimmedURLToken(String(token[range.lowerBound...]))
                }
            }
        }
        return nil
    }

    /// Splits `scheme://[user[:password]@]host[:port][/database][?query]` by
    /// hand. The boundaries are found in an order that tolerates unencoded
    /// special characters in the password: the query is removed first, the
    /// userinfo is taken up to the *last* `@` (host and path never contain
    /// one), and only then is the path split off the host part.
    static func details(fromURLString string: String) -> ParsedConnectionDetails {
        guard let schemeRange = string.range(of: "://") else {
            return ParsedConnectionDetails()
        }
        var rest = String(string[schemeRange.upperBound...])

        // Query string (?sslmode=require&…).
        var query = ""
        if let mark = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: mark)...])
            rest = String(rest[..<mark])
        }

        // Userinfo up to the last "@": real passwords contain unencoded "@"
        // and "/", but the host and path never do.
        var user: String?
        var password: String?
        var hostPart = rest
        if let at = rest.lastIndex(of: "@") {
            let userinfo = String(rest[..<at])
            hostPart = String(rest[rest.index(after: at)...])
            if let colon = userinfo.firstIndex(of: ":") {
                user = String(userinfo[..<colon])
                password = String(userinfo[userinfo.index(after: colon)...])
            } else {
                user = userinfo
            }
        }

        // Path (database) is the first "/" in the host part.
        var database: String?
        if let slash = hostPart.firstIndex(of: "/") {
            database = String(hostPart[hostPart.index(after: slash)...])
            hostPart = String(hostPart[..<slash])
        }

        let (host, port) = hostAndPort(in: hostPart)

        return .sanitized(
            host: decoded(host),
            port: port,
            database: database.map(decoded),
            username: user.map(decoded),
            password: password.map(decoded),
            sslModeText: sslMode(inQuery: query),
            preservesEmptyPassword: password != nil
        )
    }

    private static func sslMode(inQuery query: String) -> String? {
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "sslmode" {
                return decoded(String(parts[1]))
            }
        }
        return nil
    }

    private static func hostAndPort(in hostPart: String) -> (host: String, port: Int?) {
        if hostPart.hasPrefix("["),
            let closeBracket = hostPart.firstIndex(of: "]")
        {
            let host = String(hostPart[hostPart.index(after: hostPart.startIndex)..<closeBracket])
            let remainder = hostPart[hostPart.index(after: closeBracket)...]
            let port =
                remainder.first == ":"
                ? Int(remainder.dropFirst())
                : nil
            return (host, port)
        }

        guard hostPart.filter({ $0 == ":" }).count == 1,
            let colon = hostPart.lastIndex(of: ":")
        else {
            return (hostPart, nil)
        }
        return (
            String(hostPart[..<colon]),
            Int(hostPart[hostPart.index(after: colon)...])
        )
    }

    /// Percent-decodes a component, falling back to the raw value when it
    /// contains a stray `%` that is not valid percent-encoding.
    private static func decoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func trimmedURLToken(_ token: String) -> String {
        var value = token
        let delimiters = CharacterSet(charactersIn: ".,;)]}>`")
        while let last = value.unicodeScalars.last, delimiters.contains(last) {
            if last == "]", !hasUnmatchedClosingBracket(value) {
                break
            }
            value.removeLast()
        }
        return value
    }

    private static func hasUnmatchedClosingBracket(_ value: String) -> Bool {
        value.filter { $0 == "]" }.count > value.filter { $0 == "[" }.count
    }
}
