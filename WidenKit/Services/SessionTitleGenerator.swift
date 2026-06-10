import Foundation

/// Generates a short session title from the user's first question.
public protocol SessionTitleGenerating: Sendable {
    func generateTitle(for question: String) async throws -> String
}

/// Deterministic stand-in for the real model. Used in tests and behind the
/// "Use mock AI" developer toggle.
public struct MockTitleGenerator: SessionTitleGenerating {
    public init() {}

    public func generateTitle(for question: String) async throws -> String {
        SessionTitleFallback.title(from: question)
    }
}

/// Deterministic session-title helpers: a fallback title derived from the
/// user's question, and a sanitizer for model-generated titles.
public enum SessionTitleFallback {
    /// Builds a title from the first question by collapsing whitespace and
    /// truncating at a word boundary to at most 40 characters (plus an
    /// ellipsis when truncated).
    public static func title(from question: String) -> String {
        let collapsed = collapseWhitespace(question)
        guard collapsed.count > 40 else { return collapsed }
        let prefix = String(collapsed.prefix(40))
        // Cut back to the last full word so the ellipsis never splits one.
        let truncated =
            if let lastSpace = prefix.lastIndex(of: " ") {
                String(prefix[..<lastSpace])
            } else {
                prefix
            }
        return truncated + "…"
    }

    /// Cleans a model-generated title: strips wrapping quotes and trailing
    /// periods, collapses whitespace, and caps the length at 60 characters.
    /// Returns nil when nothing usable remains.
    public static func sanitize(_ raw: String) -> String? {
        var text = collapseWhitespace(raw)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`"))
        while text.hasSuffix(".") {
            text.removeLast()
        }
        text = collapseWhitespace(text)
        guard !text.isEmpty else { return nil }
        if text.count > 60 {
            text = String(text.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : text
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
