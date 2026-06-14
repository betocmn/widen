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

    /// The first whitespace-delimited token containing a postgres scheme,
    /// trimmed to start at the scheme so `DATABASE_URL=postgres://…` works.
    /// Quote characters can wrap the URL, but after the scheme they can also
    /// be valid userinfo characters.
    static func firstConnectionURL(in text: String) -> String? {
        let schemes = ["postgresql://", "postgres://"]
        let firstScheme = schemes
            .compactMap { text.range(of: $0, options: .caseInsensitive) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let firstScheme else { return nil }

        let wrappingQuote: Character? =
            if firstScheme.lowerBound > text.startIndex {
                switch text[text.index(before: firstScheme.lowerBound)] {
                case "'", "\"":
                    text[text.index(before: firstScheme.lowerBound)]
                default:
                    nil
                }
            } else {
                nil
            }

        var end = firstScheme.lowerBound
        while end < text.endIndex, !text[end].isWhitespace {
            if let wrappingQuote,
                text[end] == wrappingQuote,
                isWrappingQuoteTerminator(in: text, at: end)
            {
                break
            }
            end = text.index(after: end)
        }
        return trimmedURLToken(
            String(text[firstScheme.lowerBound..<end]),
            wrappingQuote: wrappingQuote
        )
    }

    /// Splits `scheme://[user[:password]@]host[:port][/database][?query]` by
    /// hand. The boundaries are found in an order that tolerates unencoded
    /// special characters in the password: userinfo is taken up to the *last*
    /// `@` (host and path never contain one), and only then are query and path
    /// split off the host part.
    static func details(fromURLString string: String) -> ParsedConnectionDetails {
        guard let schemeRange = string.range(of: "://") else {
            return ParsedConnectionDetails()
        }
        var rest = String(string[schemeRange.upperBound...])

        // Userinfo up to the last "@": real passwords contain unencoded "@"
        // and punctuation, but the host and path never do.
        var user: String?
        var password: String?
        var hostPart = rest
        if let at = userinfoDelimiter(in: rest) {
            let userinfo = String(rest[..<at])
            hostPart = String(rest[rest.index(after: at)...])
            if let colon = userinfo.firstIndex(of: ":") {
                user = String(userinfo[..<colon])
                password = String(userinfo[userinfo.index(after: colon)...])
            } else {
                user = userinfo
            }
        }

        // Query string (?sslmode=require&…) belongs to the host/path side, so
        // split it only after userinfo has been isolated.
        var query = ""
        if let mark = hostPart.firstIndex(of: "?") {
            query = String(hostPart[hostPart.index(after: mark)...])
            hostPart = String(hostPart[..<mark])
        }

        // Path (database) is the first "/" in the host part.
        var database: String?
        if let slash = hostPart.firstIndex(of: "/") {
            database = String(hostPart[hostPart.index(after: slash)...])
            hostPart = String(hostPart[..<slash])
        }

        let (host, port) = hostAndPort(in: hostPart)
        let queryValues = queryParameters(in: query)
        let parsedUser = user ?? queryValues["user"] ?? queryValues["username"]
        let parsedPassword = password ?? queryValues["password"]

        return .sanitized(
            host: decoded(host),
            port: port,
            database: database.map(decoded),
            username: parsedUser.map(decoded),
            password: parsedPassword.map(decoded),
            sslModeText: sslMode(inQuery: query),
            preservesEmptyPassword: parsedPassword != nil
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

    private static func queryParameters(in query: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(
                separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[decoded(String(parts[0])).lowercased()] = decoded(String(parts[1]))
        }
        return values
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

    private static func userinfoDelimiter(in rest: String) -> String.Index? {
        var candidate = rest.startIndex
        while candidate < rest.endIndex {
            guard let at = rest[candidate...].firstIndex(of: "@") else { return nil }
            if isValidUserinfoDelimiter(at, in: rest) { return at }
            candidate = rest.index(after: at)
        }
        return nil
    }

    private static func isValidUserinfoDelimiter(
        _ delimiter: String.Index, in rest: String
    ) -> Bool {
        let userinfo = rest[..<delimiter]
        guard !userinfo.isEmpty, !looksLikeQueryAtSign(in: userinfo) else {
            return false
        }

        let suffix = rest[rest.index(after: delimiter)...]
        let beforeQuery =
            suffix.firstIndex(of: "?").map { suffix[..<$0] } ?? suffix[...]
        guard !beforeQuery.contains("@") else { return false }

        let hostToken = beforeQuery.split(separator: "/", maxSplits: 1).first ?? ""
        return isPlausibleHostToken(hostToken)
    }

    private static func looksLikeQueryAtSign(in userinfo: Substring) -> Bool {
        guard let structural = userinfo.firstIndex(where: { $0 == "/" || $0 == "?" }) else {
            return false
        }
        guard let colon = userinfo.firstIndex(of: ":"), colon < structural else {
            return true
        }

        let valueBeforeStructural = userinfo[userinfo.index(after: colon)..<structural]
        return !valueBeforeStructural.isEmpty
            && valueBeforeStructural.allSatisfy(\.isNumber)
    }

    private static func isPlausibleHostToken(_ hostToken: Substring) -> Bool {
        !hostToken.isEmpty
            && !hostToken.contains { $0.isWhitespace || $0 == "&" || $0 == "=" }
    }

    /// Percent-decodes a component, falling back to the raw value when it
    /// contains a stray `%` that is not valid percent-encoding.
    private static func decoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func trimmedURLToken(_ token: String, wrappingQuote: Character?) -> String {
        var value = token
        let delimiters = CharacterSet(charactersIn: ".,;)]}>`")
        while let last = value.unicodeScalars.last, delimiters.contains(last) {
            if last == "]", !hasUnmatchedClosingBracket(value) {
                break
            }
            value.removeLast()
        }
        if let wrappingQuote, value.last == wrappingQuote {
            value.removeLast()
        }
        return value
    }

    private static func isWrappingQuoteTerminator(
        in text: String, at quoteIndex: String.Index
    ) -> Bool {
        let next = text.index(after: quoteIndex)
        guard next < text.endIndex else { return true }
        return text[next].isWhitespace || text[next] == "," || text[next] == "}" || text[next] == "]"
    }

    private static func hasUnmatchedClosingBracket(_ value: String) -> Bool {
        value.filter { $0 == "]" }.count > value.filter { $0 == "[" }.count
    }
}
