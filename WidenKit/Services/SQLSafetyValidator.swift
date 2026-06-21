import Foundation

/// The kind of statement a validated SQL string represents. Reads run
/// read-only and may auto-retry; writes can only run after an explicit Run and
/// never auto-execute. DDL/admin statements never classify here — they are
/// rejected outright.
public enum SQLStatementKind: String, Codable, Sendable, Equatable {
    case read
    case insert
    case update
    case delete

    public var isWrite: Bool { self != .read }
}

public struct SQLValidationResult: Equatable, Sendable {
    public var isValid: Bool
    public var normalizedSQL: String?
    public var errors: [String]
    public var warnings: [String]
    /// True when the stripped SQL contains a top-level LIMIT token; the
    /// executor wraps the query in a `LIMIT n` subquery when absent.
    public var hasLimit: Bool
    /// What the statement does. Drives the read-only vs. write execution path.
    public var kind: SQLStatementKind
    /// True when the user must confirm before this write runs: every DELETE and
    /// any UPDATE without a top-level WHERE clause.
    public var requiresConfirmation: Bool

    public init(
        isValid: Bool,
        normalizedSQL: String?,
        errors: [String],
        warnings: [String],
        hasLimit: Bool,
        kind: SQLStatementKind = .read,
        requiresConfirmation: Bool = false
    ) {
        self.isValid = isValid
        self.normalizedSQL = normalizedSQL
        self.errors = errors
        self.warnings = warnings
        self.hasLimit = hasLimit
        self.kind = kind
        self.requiresConfirmation = requiresConfirmation
    }
}

/// Deterministic gatekeeper for every statement that reaches the database.
/// The language model is never trusted; only single SELECT/WITH reads and
/// single INSERT/UPDATE/DELETE writes pass. Every other statement (DDL, admin,
/// transaction control) is rejected. Conservative false positives are
/// acceptable. The returned `kind` decides the execution path: reads run
/// read-only and may auto-retry; writes only ever run from an explicit Run.
public enum SQLSafetyValidator {
    /// Data-modifying verbs that are allowed as the leading keyword of a
    /// statement, but never anywhere inside a SELECT/WITH read (which would be
    /// a data-modifying CTE or a `FOR UPDATE` lock clause).
    public static let writeKeywords: Set<String> = ["INSERT", "UPDATE", "DELETE"]

    public static let forbiddenKeywords: Set<String> = [
        "MERGE", "ALTER", "DROP", "CREATE",
        "TRUNCATE", "GRANT", "REVOKE", "CALL", "DO", "COPY", "EXECUTE",
        "PREPARE", "VACUUM", "ANALYZE", "REINDEX", "REFRESH", "SET", "RESET",
        "BEGIN", "COMMIT", "ROLLBACK",
    ]

    public static let forbiddenFunctions: Set<String> = [
        "PG_SLEEP", "DBLINK", "DBLINK_EXEC", "LO_IMPORT", "LO_EXPORT",
        "PG_CANCEL_BACKEND", "PG_TERMINATE_BACKEND",
        "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "PG_PROMOTE",
        "PG_SWITCH_WAL", "PG_CREATE_RESTORE_POINT",
        "PG_READ_FILE", "PG_READ_BINARY_FILE", "PG_LS_DIR",
        "PG_LS_LOGDIR", "PG_LS_WALDIR", "PG_LS_ARCHIVE_STATUSDIR", "PG_LS_TMPDIR",
        "PG_STAT_FILE",
        "PG_START_BACKUP", "PG_STOP_BACKUP", "PG_BACKUP_START", "PG_BACKUP_STOP",
        "PG_STAT_RESET", "PG_STAT_RESET_SHARED",
        "PG_STAT_RESET_SINGLE_TABLE_COUNTERS", "PG_STAT_RESET_SINGLE_FUNCTION_COUNTERS",
        "PG_STAT_RESET_REPLICATION_SLOT", "PG_REPLICATION_SLOT_ADVANCE",
        "PG_NOTIFY",
        "PG_ADVISORY_LOCK", "PG_ADVISORY_LOCK_SHARED", "PG_TRY_ADVISORY_LOCK",
        "PG_TRY_ADVISORY_LOCK_SHARED", "PG_ADVISORY_UNLOCK",
        "PG_ADVISORY_UNLOCK_SHARED", "PG_ADVISORY_UNLOCK_ALL",
        "SET_CONFIG",
    ]

    private static let aggregateFunctions: Set<String> = ["AVG", "SUM", "MIN", "MAX", "COUNT"]

    public static func validate(_ sql: String) -> SQLValidationResult {
        var errors: [String] = []
        var warnings: [String] = []

        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow exactly one trailing semicolon — people paste SQL ending in ';'.
        if trimmed.hasSuffix(";") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else {
            return SQLValidationResult(
                isValid: false, normalizedSQL: nil,
                errors: ["SQL is empty."], warnings: [], hasLimit: false
            )
        }

        let stripped = strip(trimmed)
        if stripped.unterminated {
            errors.append("SQL contains an unterminated string, identifier, or comment.")
        }
        if stripped.text.contains(";") {
            errors.append("Multiple statements are not allowed.")
        }

        let tokens = tokenize(stripped.text)
        var kind: SQLStatementKind = .read
        if let first = tokens.first {
            switch first {
            case "SELECT", "WITH":
                kind = .read
                // A data-modifying statement must be a plain INSERT/UPDATE/DELETE.
                // A read that still carries one is a data-modifying CTE
                // (`WITH … DELETE …`) or a `FOR UPDATE` lock clause — unsupported.
                if let writeToken = tokens.first(where: { writeKeywords.contains($0) }) {
                    errors.append(
                        "Data-modifying statements are not allowed inside a SELECT or WITH query: \(writeToken)."
                    )
                }
            case "INSERT":
                kind = .insert
            case "UPDATE":
                kind = .update
            case "DELETE":
                kind = .delete
            default:
                errors.append("Only SELECT, WITH, INSERT, UPDATE, or DELETE statements are allowed.")
            }
        } else {
            errors.append("No SQL statement found.")
        }

        var reported: Set<String> = []
        for token in tokens {
            // Forbidden command keywords are only dangerous as a leading
            // statement, which the first-token check already rejects. Inside a
            // write they are legitimate clause keywords (UPDATE … SET …,
            // INSERT … ON CONFLICT DO UPDATE), so only scan reads for them.
            if kind == .read, forbiddenKeywords.contains(token),
                reported.insert(token).inserted
            {
                errors.append("Forbidden keyword: \(token).")
            }
            if forbiddenFunctions.contains(token), reported.insert(token).inserted {
                errors.append("Forbidden function: \(token.lowercased())().")
            }
        }
        for token in stripped.quotedFunctionTokens {
            if forbiddenFunctions.contains(token), reported.insert(token).inserted {
                errors.append("Forbidden function: \(token.lowercased())().")
            }
        }
        if containsWindowFunctionInsideAggregate(stripped.text) {
            errors.append(
                "Aggregate functions cannot contain window functions. Count rows in a subquery or CTE, then aggregate those results in the outer SELECT."
            )
        }
        if containsAggregateFunctionInsideAggregate(stripped.text) {
            errors.append(
                "Aggregate functions cannot contain other aggregate functions. Count rows in a subquery or CTE, then aggregate those results in the outer SELECT."
            )
        }

        let hasLimit = hasTopLevelLimit(stripped.text)
        if errors.isEmpty {
            if kind == .read {
                if !hasLimit {
                    warnings.append("No LIMIT clause — the default row limit will be applied.")
                }
                if hasSelectStar(stripped.text) {
                    warnings.append(
                        "SELECT * returns every column; consider selecting specific columns.")
                }
                if !tokens.contains("WHERE"), tokens.contains("FROM") {
                    warnings.append("Query has no WHERE clause and may scan whole tables.")
                }
            } else {
                warnings.append("This query modifies data.")
            }
        }

        let requiresConfirmation: Bool
        switch kind {
        case .delete:
            requiresConfirmation = true
        case .update:
            requiresConfirmation = !hasTopLevelWhere(stripped.text)
                || hasTopLevelFrom(stripped.text)
        case .insert:
            requiresConfirmation = containsUpsertDoUpdate(tokens)
        case .read:
            requiresConfirmation = false
        }

        return SQLValidationResult(
            isValid: errors.isEmpty,
            normalizedSQL: errors.isEmpty ? trimmed : nil,
            errors: errors,
            warnings: warnings,
            hasLimit: hasLimit,
            kind: kind,
            requiresConfirmation: requiresConfirmation
        )
    }

    // MARK: - Lexing

    struct StripResult {
        var text: String
        var unterminated: Bool
        var quotedFunctionTokens: [String]
    }

    /// Replaces string literals, quoted identifiers, dollar-quoted strings,
    /// and comments with spaces, so keyword checks cannot be fooled by their
    /// contents. Anything unterminated is flagged.
    ///
    /// Backslashes are treated as escapes only inside PostgreSQL `E'...'`
    /// escape strings. Standard single-quoted strings only escape via `''`.
    static func strip(_ sql: String) -> StripResult {
        var output = ""
        var unterminated = false
        var quotedFunctionTokens: [String] = []
        let chars = Array(sql)
        let count = chars.count
        var i = 0

        func char(at offset: Int) -> Character? {
            offset < count ? chars[offset] : nil
        }

        func consumeStringLiteral(openingQuoteIndex: Int, allowBackslashEscapes: Bool) {
            i = openingQuoteIndex + 1
            var closed = false
            while i < count {
                if allowBackslashEscapes, chars[i] == "\\" {
                    i += 2
                    continue
                }
                if chars[i] == "'" {
                    if char(at: i + 1) == "'" {
                        i += 2
                        continue
                    }
                    closed = true
                    i += 1
                    break
                }
                i += 1
            }
            if !closed { unterminated = true }
            output.append(" ")
        }

        func indexAfterTrivia(from offset: Int) -> Int {
            var j = offset
            while j < count {
                if chars[j].isWhitespace {
                    j += 1
                    continue
                }
                if chars[j] == "-", char(at: j + 1) == "-" {
                    j += 2
                    while j < count, chars[j] != "\n" { j += 1 }
                    continue
                }
                if chars[j] == "/", char(at: j + 1) == "*" {
                    var depth = 1
                    j += 2
                    while j < count, depth > 0 {
                        if chars[j] == "/", char(at: j + 1) == "*" {
                            depth += 1
                            j += 2
                        } else if chars[j] == "*", char(at: j + 1) == "/" {
                            depth -= 1
                            j += 2
                        } else {
                            j += 1
                        }
                    }
                    continue
                }
                break
            }
            return j
        }

        func isFunctionCall(after offset: Int) -> Bool {
            let j = indexAfterTrivia(from: offset)
            return j < count && chars[j] == "("
        }

        while i < count {
            let c = chars[i]

            // Escape string literal: E'…'. Backslashes only escape quotes in
            // this PostgreSQL-specific string form, not in ordinary strings.
            if (c == "E" || c == "e"), char(at: i + 1) == "'" {
                consumeStringLiteral(openingQuoteIndex: i + 1, allowBackslashEscapes: true)
                continue
            }

            // Line comment: -- … end of line
            if c == "-", char(at: i + 1) == "-" {
                while i < count, chars[i] != "\n" { i += 1 }
                output.append(" ")
                continue
            }

            // Block comment: /* … */ — PostgreSQL block comments nest.
            if c == "/", char(at: i + 1) == "*" {
                var depth = 1
                i += 2
                while i < count, depth > 0 {
                    if chars[i] == "/", char(at: i + 1) == "*" {
                        depth += 1
                        i += 2
                    } else if chars[i] == "*", char(at: i + 1) == "/" {
                        depth -= 1
                        i += 2
                    } else {
                        i += 1
                    }
                }
                if depth > 0 { unterminated = true }
                output.append(" ")
                continue
            }

            // String literal: '…' with '' escapes.
            if c == "'" {
                consumeStringLiteral(openingQuoteIndex: i, allowBackslashEscapes: false)
                continue
            }

            // Quoted identifier: "…" with "" escapes. Contents are blanked so
            // a column named "drop table" cannot trip the keyword check.
            if c == "\"" {
                i += 1
                var identifier = ""
                var closed = false
                while i < count {
                    if chars[i] == "\"" {
                        if char(at: i + 1) == "\"" {
                            identifier.append("\"")
                            i += 2
                            continue
                        }
                        closed = true
                        i += 1
                        break
                    }
                    identifier.append(chars[i])
                    i += 1
                }
                if !closed { unterminated = true }
                if closed, isFunctionCall(after: i) {
                    quotedFunctionTokens.append(identifier.uppercased())
                }
                output.append(" ")
                continue
            }

            // Dollar-quoted string: $tag$ … $tag$
            if c == "$" {
                var j = i + 1
                while j < count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    j += 1
                }
                if j < count, chars[j] == "$" {
                    let tag = chars[i...j]
                    var k = j + 1
                    var closingStart: Int?
                    while k + tag.count <= count {
                        if chars[k] == "$", Array(chars[k..<(k + tag.count)]) == Array(tag) {
                            closingStart = k
                            break
                        }
                        k += 1
                    }
                    if let closingStart {
                        i = closingStart + tag.count
                    } else {
                        unterminated = true
                        i = count
                    }
                    output.append(" ")
                    continue
                }
            }

            output.append(c)
            i += 1
        }

        return StripResult(
            text: output,
            unterminated: unterminated,
            quotedFunctionTokens: quotedFunctionTokens
        )
    }

    /// Word tokens (`[A-Za-z_][A-Za-z0-9_$]*`), uppercased. Identifiers like
    /// `created_at` stay one token, so they can never match `CREATE`.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in text {
            if char.isLetter || char == "_"
                || (!current.isEmpty && (char.isNumber || char == "$"))
            {
                current.append(char)
            } else if !current.isEmpty {
                tokens.append(current.uppercased())
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current.uppercased())
        }
        return tokens
    }

    static func hasSelectStar(_ strippedText: String) -> Bool {
        strippedText.range(
            of: #"(?i)\bselect\s+(distinct\s+)?\*"#,
            options: .regularExpression
        ) != nil
    }

    static func hasTopLevelLimit(_ strippedText: String) -> Bool {
        let chars = Array(strippedText)
        var depth = 0
        var i = 0

        while i < chars.count {
            let char = chars[i]
            if isWordStart(char) {
                var token = ""
                while i < chars.count, isWordPart(chars[i], tokenStarted: !token.isEmpty) {
                    token.append(chars[i])
                    i += 1
                }
                if depth == 0, token.uppercased() == "LIMIT" {
                    return topLevelLimitIsBounded(chars, after: i)
                }
                continue
            }
            if char == "(" {
                depth += 1
            } else if char == ")", depth > 0 {
                depth -= 1
            }
            i += 1
        }
        return false
    }

    /// True when a `WHERE` token appears at parenthesis depth zero. Mirrors
    /// `hasTopLevelLimit`: a WHERE buried inside a subquery does not count, so
    /// an UPDATE whose only WHERE is in a sub-SELECT still requires confirmation.
    static func hasTopLevelWhere(_ strippedText: String) -> Bool {
        hasTopLevelKeyword("WHERE", in: strippedText)
    }

    static func hasTopLevelFrom(_ strippedText: String) -> Bool {
        hasTopLevelKeyword("FROM", in: strippedText)
    }

    private static func hasTopLevelKeyword(_ keyword: String, in strippedText: String) -> Bool {
        let chars = Array(strippedText)
        var depth = 0
        var i = 0
        let target = keyword.uppercased()

        while i < chars.count {
            let char = chars[i]
            if isWordStart(char) {
                var token = ""
                while i < chars.count, isWordPart(chars[i], tokenStarted: !token.isEmpty) {
                    token.append(chars[i])
                    i += 1
                }
                if depth == 0, token.uppercased() == target {
                    return true
                }
                continue
            }
            if char == "(" {
                depth += 1
            } else if char == ")", depth > 0 {
                depth -= 1
            }
            i += 1
        }
        return false
    }

    static func containsUpsertDoUpdate(_ tokens: [String]) -> Bool {
        guard let conflictIndex = tokens.firstIndex(of: "CONFLICT") else { return false }
        var index = tokens.index(after: conflictIndex)
        while index < tokens.endIndex {
            if tokens[index] == "DO" {
                let next = tokens.index(after: index)
                if next < tokens.endIndex, tokens[next] == "UPDATE" {
                    return true
                }
            }
            index = tokens.index(after: index)
        }
        return false
    }

    static func containsWindowFunctionInsideAggregate(_ strippedText: String) -> Bool {
        let chars = Array(strippedText)
        var i = 0

        while i < chars.count {
            guard isWordStart(chars[i]) else {
                i += 1
                continue
            }

            let tokenStart = i
            var token = ""
            while i < chars.count, isWordPart(chars[i], tokenStarted: !token.isEmpty) {
                token.append(chars[i])
                i += 1
            }

            guard aggregateFunctions.contains(token.uppercased()) else { continue }
            let openIndex = indexOfOpeningParenthesis(chars, after: i)
            guard let openIndex else { continue }
            let closeIndex = matchingClosingParenthesis(chars, openingAt: openIndex)
            guard let closeIndex else { continue }
            let argumentText = String(chars[(openIndex + 1)..<closeIndex])
            if containsWord(argumentText, named: ["OVER"]) {
                return true
            }

            // Continue after the function call so nested scans do not report
            // the inner window aggregate itself, which may be valid.
            i = max(closeIndex + 1, tokenStart + 1)
        }

        return false
    }

    static func containsAggregateFunctionInsideAggregate(_ strippedText: String) -> Bool {
        let chars = Array(strippedText)
        var i = 0

        while i < chars.count {
            guard isWordStart(chars[i]) else {
                i += 1
                continue
            }

            let tokenStart = i
            var token = ""
            while i < chars.count, isWordPart(chars[i], tokenStarted: !token.isEmpty) {
                token.append(chars[i])
                i += 1
            }

            guard aggregateFunctions.contains(token.uppercased()) else { continue }
            let openIndex = indexOfOpeningParenthesis(chars, after: i)
            guard let openIndex else { continue }
            let closeIndex = matchingClosingParenthesis(chars, openingAt: openIndex)
            guard let closeIndex else { continue }
            let argumentText = String(chars[(openIndex + 1)..<closeIndex])
            if aggregateCallIsWindowFunction(chars, closingAt: closeIndex) {
                i = max(closeIndex + 1, tokenStart + 1)
                continue
            }
            if containsFunctionCall(argumentText, named: aggregateFunctions) {
                return true
            }
            i = max(closeIndex + 1, tokenStart + 1)
        }

        return false
    }

    private static func aggregateCallIsWindowFunction(
        _ chars: [Character],
        closingAt closeIndex: Int
    ) -> Bool {
        var cursor = closeIndex + 1
        guard let next = nextWord(chars, startingAt: cursor) else { return false }
        if next.word.uppercased() == "OVER" {
            return true
        }
        guard next.word.uppercased() == "FILTER" else { return false }
        cursor = next.end
        while cursor < chars.count, chars[cursor].isWhitespace {
            cursor += 1
        }
        if cursor < chars.count,
            chars[cursor] == "(",
            let afterFilter = matchingClosingParenthesis(chars, openingAt: cursor).map({ $0 + 1 })
        {
            cursor = afterFilter
        }
        return nextWord(chars, startingAt: cursor)?.word.uppercased() == "OVER"
    }

    private static func nextWord(
        _ chars: [Character],
        startingAt offset: Int
    ) -> (word: String, end: Int)? {
        var cursor = offset
        while cursor < chars.count, chars[cursor].isWhitespace {
            cursor += 1
        }
        guard cursor < chars.count, isWordStart(chars[cursor]) else { return nil }
        var word = ""
        while cursor < chars.count, isWordPart(chars[cursor], tokenStarted: !word.isEmpty) {
            word.append(chars[cursor])
            cursor += 1
        }
        return (word, cursor)
    }

    private static func containsFunctionCall(_ text: String, named names: Set<String>) -> Bool {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "(",
                let closeIndex = matchingClosingParenthesis(chars, openingAt: i),
                groupContainsTopLevelSelect(chars, startingAt: i + 1, endingAt: closeIndex)
            {
                i = closeIndex + 1
                continue
            }
            guard isWordStart(chars[i]) else {
                i += 1
                continue
            }
            var token = ""
            while i < chars.count, isWordPart(chars[i], tokenStarted: !token.isEmpty) {
                token.append(chars[i])
                i += 1
            }
            guard names.contains(token.uppercased()) else { continue }
            if indexOfOpeningParenthesis(chars, after: i) != nil {
                return true
            }
        }
        return false
    }

    private static func containsWord(_ text: String, named names: Set<String>) -> Bool {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "(",
                let closeIndex = matchingClosingParenthesis(chars, openingAt: i),
                groupContainsTopLevelSelect(chars, startingAt: i + 1, endingAt: closeIndex)
            {
                i = closeIndex + 1
                continue
            }
            guard isWordStart(chars[i]) else {
                i += 1
                continue
            }
            var token = ""
            while i < chars.count, isWordPart(chars[i], tokenStarted: !token.isEmpty) {
                token.append(chars[i])
                i += 1
            }
            if names.contains(token.uppercased()) {
                return true
            }
        }
        return false
    }

    private static func indexOfOpeningParenthesis(
        _ chars: [Character],
        after offset: Int
    ) -> Int? {
        var i = offset
        while i < chars.count {
            if chars[i].isWhitespace {
                i += 1
                continue
            }
            return chars[i] == "(" ? i : nil
        }
        return nil
    }

    private static func matchingClosingParenthesis(
        _ chars: [Character],
        openingAt openIndex: Int
    ) -> Int? {
        var depth = 0
        var i = openIndex
        while i < chars.count {
            if chars[i] == "(" {
                depth += 1
            } else if chars[i] == ")" {
                depth -= 1
                if depth == 0 {
                    return i
                }
            }
            i += 1
        }
        return nil
    }

    private static func groupContainsTopLevelSelect(
        _ chars: [Character],
        startingAt start: Int,
        endingAt end: Int
    ) -> Bool {
        var depth = 0
        var i = start
        while i < end {
            if chars[i] == "(" {
                depth += 1
                i += 1
                continue
            }
            if chars[i] == ")" {
                depth = max(0, depth - 1)
                i += 1
                continue
            }
            guard depth == 0, isWordStart(chars[i]) else {
                i += 1
                continue
            }
            var token = ""
            while i < end, isWordPart(chars[i], tokenStarted: !token.isEmpty) {
                token.append(chars[i])
                i += 1
            }
            if token.uppercased() == "SELECT" {
                return true
            }
        }
        return false
    }

    private static func topLevelLimitIsBounded(_ chars: [Character], after offset: Int) -> Bool {
        var i = offset
        while i < chars.count {
            if chars[i].isWhitespace || chars[i] == "(" {
                i += 1
                continue
            }
            break
        }

        var token = ""
        while i < chars.count, isWordPart(chars[i], tokenStarted: !token.isEmpty) {
            token.append(chars[i])
            i += 1
        }
        let uppercased = token.uppercased()
        return uppercased != "ALL" && uppercased != "NULL"
    }

    private static func isWordStart(_ char: Character) -> Bool {
        char.isLetter || char == "_"
    }

    private static func isWordPart(_ char: Character, tokenStarted: Bool) -> Bool {
        char.isLetter || char == "_" || (tokenStarted && (char.isNumber || char == "$"))
    }
}
