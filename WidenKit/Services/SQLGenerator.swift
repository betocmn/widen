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

public enum SQLGenerationMode: String, Codable, Equatable, Sendable {
    case initial
    case followUp
    case repair
    case reconstructAfterFailedRepair
}

public struct SQLRepairContext: Equatable, Sendable {
    public var failedSQL: String?
    public var diagnostic: DatabaseDiagnostic?
    public var forbiddenIdentifiers: [String]
    public var priorFingerprints: [String]

    public init(
        failedSQL: String? = nil,
        diagnostic: DatabaseDiagnostic? = nil,
        forbiddenIdentifiers: [String] = [],
        priorFingerprints: [String] = []
    ) {
        self.failedSQL = failedSQL
        self.diagnostic = diagnostic
        self.forbiddenIdentifiers = forbiddenIdentifiers
        self.priorFingerprints = priorFingerprints
    }
}

/// Compact conversational context for one generation. The on-device model
/// has a small context window, so this carries only what a follow-up needs:
/// a short ordered chat transcript, the SQL currently on screen, and the last
/// error when the previous run failed. With it, "make it last month instead"
/// or "the query is failing" can be answered against the right query.
public struct SQLGenerationContext: Equatable, Sendable {
    public var mode: SQLGenerationMode
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
    /// Structured repair metadata used only by repair/reconstruction prompts.
    public var repairContext: SQLRepairContext?

    public init(
        mode: SQLGenerationMode = .initial,
        recentQuestions: [String] = [],
        originalQuestion: String? = nil,
        conversationMessages: [SQLConversationMessage] = [],
        currentSQL: String? = nil,
        lastRunError: String? = nil,
        repairContext: SQLRepairContext? = nil
    ) {
        self.mode = mode
        self.recentQuestions = recentQuestions
        self.originalQuestion = originalQuestion
        self.conversationMessages = conversationMessages
        self.currentSQL = currentSQL
        self.lastRunError = lastRunError
        self.repairContext = repairContext
    }

    public var isEmpty: Bool {
        recentQuestions.isEmpty && originalQuestion == nil && conversationMessages.isEmpty
            && currentSQL == nil && lastRunError == nil && repairContext == nil
            && mode == .initial
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
