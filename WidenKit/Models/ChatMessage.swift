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
        /// What ran. For writes `rowCount` is the affected-row count and the
        /// record reads "Inserted/Updated/Deleted N rows".
        public var kind: SQLStatementKind

        public init(
            rowCount: Int,
            executionTimeMs: Int,
            truncated: Bool,
            sql: String,
            kind: SQLStatementKind = .read
        ) {
            self.rowCount = rowCount
            self.executionTimeMs = executionTimeMs
            self.truncated = truncated
            self.sql = sql
            self.kind = kind
        }

        private enum CodingKeys: String, CodingKey {
            case rowCount, executionTimeMs, truncated, sql, kind
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rowCount = try container.decode(Int.self, forKey: .rowCount)
            executionTimeMs = try container.decode(Int.self, forKey: .executionTimeMs)
            truncated = try container.decode(Bool.self, forKey: .truncated)
            sql = try container.decode(String.self, forKey: .sql)
            // Transcripts saved before writes existed have no `kind` — they are
            // all reads. Decoding a non-optional key directly would throw.
            kind = try container.decodeIfPresent(SQLStatementKind.self, forKey: .kind) ?? .read
        }
    }

    public let id: UUID
    public var role: Role
    public var text: String
    /// Present on assistant messages produced by a generation.
    public var generation: SQLGenerationResult?
    /// Present on `.result` messages recording a finished run.
    public var runSummary: RunSummary?
    /// Present on `.error` messages from a failed write that was AI-generated:
    /// the failing SQL the "Try Again" button asks the model to repair. Writes
    /// never auto-retry, so the retry is a one-shot, execution-free regenerate.
    public var failedWriteSQL: String?
    /// Present on assistant clarification messages that can be resolved by
    /// choosing an option or by replying in free form.
    public var pendingClarification: PendingClarification?
    public var timestamp: Date

    public init(
        role: Role,
        text: String,
        generation: SQLGenerationResult? = nil,
        runSummary: RunSummary? = nil,
        failedWriteSQL: String? = nil,
        pendingClarification: PendingClarification? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.generation = generation
        self.runSummary = runSummary
        self.failedWriteSQL = failedWriteSQL
        self.pendingClarification = pendingClarification
        self.timestamp = Date()
    }

    /// A `.result` message for a finished run, with human-readable text so
    /// persisted transcripts read sensibly on their own.
    public static func runRecord(_ summary: RunSummary) -> ChatMessage {
        let rows = "\(summary.rowCount) row\(summary.rowCount == 1 ? "" : "s")"
        var text: String
        switch summary.kind {
        case .read:
            text = "Returned \(rows)"
        case .insert:
            text = summary.isUpsertDoUpdate ? "Affected \(rows)" : "Inserted \(rows)"
        case .update:
            text = "Updated \(rows)"
        case .delete:
            text = "Deleted \(rows)"
        }
        text += " in \(summary.executionTimeMs) ms"
        if summary.truncated {
            text += " (truncated at row limit)"
        }
        return ChatMessage(role: .result, text: text, runSummary: summary)
    }
}

extension ChatMessage.RunSummary {
    fileprivate var isUpsertDoUpdate: Bool {
        let stripped = SQLSafetyValidator.strip(sql).text
        let tokens = SQLSafetyValidator.tokenize(stripped)
        return SQLSafetyValidator.containsUpsertDoUpdate(tokens)
    }
}

extension SQLConversationMessage.Role {
    init(_ role: ChatMessage.Role) {
        switch role {
        case .user:
            self = .user
        case .assistant:
            self = .assistant
        case .result:
            self = .result
        case .error:
            self = .error
        }
    }
}

extension ChatMessage {
    var promptContextText: String {
        var lines = [text]
        if let generation {
            let sql = generation.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sql.isEmpty {
                lines.append("Generated SQL:\n\(sql)")
            }
            if generation.needsClarification,
                let clarification = generation.clarificationQuestion,
                !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                lines.append("Clarification requested:\n\(clarification)")
            }
            if let pendingClarification {
                lines.append("Pending clarification ID: \(pendingClarification.id.uuidString)")
                lines.append("Pending concept: \(pendingClarification.concept.term)")
                if !pendingClarification.options.isEmpty {
                    lines.append(
                        "Clarification options:\n"
                            + pendingClarification.options
                            .map { "- \($0.label): \($0.definition)" }
                            .joined(separator: "\n")
                    )
                }
            }
        }
        if let runSummary {
            lines.append("SQL run:\n\(runSummary.sql)")
            lines.append(
                "Run summary: \(runSummary.kind.rawValue), \(runSummary.rowCount) row(s), \(runSummary.executionTimeMs) ms"
            )
        }
        if let failedWriteSQL {
            lines.append("Failed write SQL:\n\(failedWriteSQL)")
        }
        return lines.joined(separator: "\n")
    }
}

extension Array where Element == ChatMessage {
    func originalUserQuestion(upTo upperBound: Int? = nil) -> String? {
        let bounded = prefix(upTo: Swift.min(upperBound ?? count, count))
        return bounded.first(where: { $0.role == .user })?.text
    }

    func sqlConversationMessages(upTo upperBound: Int? = nil, limit: Int = 8)
        -> [SQLConversationMessage]
    {
        let bounded = prefix(upTo: Swift.min(upperBound ?? count, count))
        return bounded.suffix(limit).map { message in
            SQLConversationMessage(
                role: SQLConversationMessage.Role(message.role),
                text: message.promptContextText
            )
        }
    }
}
