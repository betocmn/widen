import Foundation

public struct SQLConversationMessage: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user
        case assistant
        case result
        case error
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// Compact conversational context for one generation. The on-device model
/// has a small context window, so this carries only what a follow-up needs:
/// a short ordered chat transcript, the SQL currently on screen, and the last
/// error when the previous run failed. With it, "make it last month instead"
/// or "the query is failing" can be answered against the right query.
public struct SQLGenerationContext: Equatable, Sendable {
    /// Earlier user questions, oldest first, excluding the current one.
    public var recentQuestions: [String]
    /// The first user question in this session, when known.
    public var originalQuestion: String?
    /// Recent chat messages in chronological order, excluding the current question.
    public var conversationMessages: [SQLConversationMessage]
    /// The SQL currently in the preview — the query a follow-up refers to.
    public var currentSQL: String?
    /// The most recent run error, when the last run of `currentSQL` failed.
    public var lastRunError: String?

    public init(
        recentQuestions: [String] = [],
        originalQuestion: String? = nil,
        conversationMessages: [SQLConversationMessage] = [],
        currentSQL: String? = nil,
        lastRunError: String? = nil
    ) {
        self.recentQuestions = recentQuestions
        self.originalQuestion = originalQuestion
        self.conversationMessages = conversationMessages
        self.currentSQL = currentSQL
        self.lastRunError = lastRunError
    }

    public var isEmpty: Bool {
        recentQuestions.isEmpty && originalQuestion == nil && conversationMessages.isEmpty
            && currentSQL == nil && lastRunError == nil
    }
}

/// A backend that turns an English question plus a schema into one PostgreSQL
/// statement — a SELECT/WITH read, or an INSERT/UPDATE/DELETE write when the
/// user asks to modify data. Implementations: `FoundationModelsSQLGenerator`
/// (Apple's on-device model) and `MockSQLGenerator` (tests / developer mode).
public protocol SQLGenerator: Sendable {
    func generateSQL(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult
}

extension SQLGenerator {
    /// Context-free convenience for callers without a conversation.
    public func generateSQL(
        question: String,
        schema: DatabaseSchema,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult {
        try await generateSQL(
            question: question,
            schema: schema,
            context: SQLGenerationContext(),
            config: config
        )
    }
}
