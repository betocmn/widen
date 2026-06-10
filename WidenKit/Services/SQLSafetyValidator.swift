import Foundation

public struct SQLValidationResult: Equatable, Sendable {
    public var isValid: Bool
    public var normalizedSQL: String?
    public var errors: [String]
    public var warnings: [String]
    /// True when the stripped SQL contains a LIMIT token; the executor wraps
    /// the query in a `LIMIT n` subquery when absent.
    public var hasLimit: Bool

    public init(
        isValid: Bool,
        normalizedSQL: String?,
        errors: [String],
        warnings: [String],
        hasLimit: Bool
    ) {
        self.isValid = isValid
        self.normalizedSQL = normalizedSQL
        self.errors = errors
        self.warnings = warnings
        self.hasLimit = hasLimit
    }
}

/// Deterministic gatekeeper for every statement that reaches the database.
/// The language model is never trusted; only single read-only SELECT/WITH
/// statements pass. Conservative false positives are acceptable.
public enum SQLSafetyValidator {
    public static let forbiddenKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "ALTER", "DROP", "CREATE",
        "TRUNCATE", "GRANT", "REVOKE", "CALL", "DO", "COPY", "EXECUTE",
        "PREPARE", "VACUUM", "ANALYZE", "REINDEX", "REFRESH", "SET", "RESET",
        "BEGIN", "COMMIT", "ROLLBACK",
    ]

    public static let forbiddenFunctions: Set<String> = [
        "PG_SLEEP", "DBLINK", "LO_IMPORT", "LO_EXPORT",
    ]

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
        if let first = tokens.first {
            if first != "SELECT" && first != "WITH" {
                errors.append("Only SELECT or WITH … SELECT queries are allowed.")
            }
        } else {
            errors.append("No SQL statement found.")
        }

        var reported: Set<String> = []
        for token in tokens {
            if forbiddenKeywords.contains(token), reported.insert(token).inserted {
                errors.append("Forbidden keyword: \(token).")
            }
            if forbiddenFunctions.contains(token), reported.insert(token).inserted {
                errors.append("Forbidden function: \(token.lowercased())().")
            }
        }

        let hasLimit = tokens.contains("LIMIT")
        if errors.isEmpty {
            if !hasLimit {
                warnings.append("No LIMIT clause — the default row limit will be applied.")
            }
            if hasSelectStar(stripped.text) {
                warnings.append("SELECT * returns every column; consider selecting specific columns.")
            }
            if !tokens.contains("WHERE"), tokens.contains("FROM") {
                warnings.append("Query has no WHERE clause and may scan whole tables.")
            }
        }

        return SQLValidationResult(
            isValid: errors.isEmpty,
            normalizedSQL: errors.isEmpty ? trimmed : nil,
            errors: errors,
            warnings: warnings,
            hasLimit: hasLimit
        )
    }

    // MARK: - Lexing

    struct StripResult {
        var text: String
        var unterminated: Bool
    }

    /// Replaces string literals, quoted identifiers, dollar-quoted strings,
    /// and comments with spaces, so keyword checks cannot be fooled by their
    /// contents. Anything unterminated is flagged.
    ///
    /// Backslashes are treated as escapes inside every single-quoted string
    /// (standard SQL only escapes via `''`); this can flag valid strings that
    /// end in a backslash as unterminated, which errs on the safe side.
    static func strip(_ sql: String) -> StripResult {
        var output = ""
        var unterminated = false
        let chars = Array(sql)
        let count = chars.count
        var i = 0

        func char(at offset: Int) -> Character? {
            offset < count ? chars[offset] : nil
        }

        while i < count {
            let c = chars[i]

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

            // String literal: '…' with '' escapes (and backslash, see above).
            if c == "'" {
                i += 1
                var closed = false
                while i < count {
                    if chars[i] == "\\" {
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
                continue
            }

            // Quoted identifier: "…" with "" escapes. Contents are blanked so
            // a column named "drop table" cannot trip the keyword check.
            if c == "\"" {
                i += 1
                var closed = false
                while i < count {
                    if chars[i] == "\"" {
                        if char(at: i + 1) == "\"" {
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

        return StripResult(text: output, unterminated: unterminated)
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
}
