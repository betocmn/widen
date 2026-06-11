import Foundation

/// One entry in a session's chat transcript. Persisted as part of
/// `QuerySession`, so the whole struct is Codable.
public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Equatable, Sendable {
        case user
        case assistant
        case error
        /// A persistent record of one finished query run.
        case result
    }

    /// Outcome of one finished query run. `sql` snapshots the statement that
    /// produced it, so the record stays meaningful after the editor moves on.
    public struct RunSummary: Codable, Equatable, Sendable {
        public var rowCount: Int
        public var executionTimeMs: Int
        public var truncated: Bool
        public var sql: String

        public init(rowCount: Int, executionTimeMs: Int, truncated: Bool, sql: String) {
            self.rowCount = rowCount
            self.executionTimeMs = executionTimeMs
            self.truncated = truncated
            self.sql = sql
        }
    }

    public let id: UUID
    public var role: Role
    public var text: String
    /// Present on assistant messages produced by a generation.
    public var generation: SQLGenerationResult?
    /// Present on `.result` messages recording a finished run.
    public var runSummary: RunSummary?
    public var timestamp: Date

    public init(
        role: Role,
        text: String,
        generation: SQLGenerationResult? = nil,
        runSummary: RunSummary? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.generation = generation
        self.runSummary = runSummary
        self.timestamp = Date()
    }

    /// A `.result` message for a finished run, with human-readable text so
    /// persisted transcripts read sensibly on their own.
    public static func runRecord(_ summary: RunSummary) -> ChatMessage {
        var text = "Returned \(summary.rowCount) row\(summary.rowCount == 1 ? "" : "s")"
        text += " in \(summary.executionTimeMs) ms"
        if summary.truncated {
            text += " (truncated at row limit)"
        }
        return ChatMessage(role: .result, text: text, runSummary: summary)
    }
}
