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

public enum RepairConstraintKind: String, Codable, Equatable, Sendable {
    case forbiddenIdentifier
    case forbiddenUnquotedIdentifier
}

public struct RepairConstraint: Codable, Equatable, Hashable, Sendable {
    public var kind: RepairConstraintKind
    public var identifier: String

    public init(kind: RepairConstraintKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    public static func forbiddenIdentifier(_ identifier: String) -> RepairConstraint {
        RepairConstraint(kind: .forbiddenIdentifier, identifier: identifier)
    }

    public static func forbiddenUnquotedIdentifier(_ identifier: String) -> RepairConstraint {
        RepairConstraint(kind: .forbiddenUnquotedIdentifier, identifier: identifier)
    }
}

public struct SQLRepairContext: Equatable, Sendable {
    public var failedSQL: String?
    public var diagnostic: DatabaseDiagnostic?
    public var forbiddenIdentifiers: [String]
    public var repairConstraints: [RepairConstraint]
    public var priorFingerprints: [String]

    public init(
        failedSQL: String? = nil,
        diagnostic: DatabaseDiagnostic? = nil,
        forbiddenIdentifiers: [String] = [],
        repairConstraints: [RepairConstraint] = [],
        priorFingerprints: [String] = []
    ) {
        self.failedSQL = failedSQL
        self.diagnostic = diagnostic
        self.forbiddenIdentifiers = forbiddenIdentifiers
        self.repairConstraints = Self.mergedConstraints(
            forbiddenIdentifiers: forbiddenIdentifiers,
            repairConstraints: repairConstraints
        )
        self.priorFingerprints = priorFingerprints
    }

    private static func mergedConstraints(
        forbiddenIdentifiers: [String],
        repairConstraints: [RepairConstraint]
    ) -> [RepairConstraint] {
        var result = repairConstraints
        var seen = Set(result.map { "\($0.kind.rawValue):\($0.identifier.lowercased())" })
        for identifier in forbiddenIdentifiers {
            let key = "\(RepairConstraintKind.forbiddenIdentifier.rawValue):\(identifier.lowercased())"
            if seen.insert(key).inserted {
                result.append(.forbiddenIdentifier(identifier))
            }
        }
        return result
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
    /// Optional app-controlled schema discovery hints. These are search terms,
    /// not schema objects, and are used only to bias deterministic packaging.
    public var schemaSearchQueries: [String]
    /// App-side count of model calls consumed for the current user request,
    /// including optional local discovery. Used for telemetry and local budget
    /// enforcement only; it is never rendered into prompts.
    public var modelCallCount: Int
    /// User-confirmed business definitions for this database/schema scope.
    /// These are app-managed semantic bindings, separate from connection
    /// credentials and database context notes.
    public var confirmedSemanticBindings: [String]

    public init(
        mode: SQLGenerationMode = .initial,
        recentQuestions: [String] = [],
        originalQuestion: String? = nil,
        conversationMessages: [SQLConversationMessage] = [],
        currentSQL: String? = nil,
        lastRunError: String? = nil,
        repairContext: SQLRepairContext? = nil,
        schemaSearchQueries: [String] = [],
        modelCallCount: Int = 0,
        confirmedSemanticBindings: [String] = []
    ) {
        self.mode = mode
        self.recentQuestions = recentQuestions
        self.originalQuestion = originalQuestion
        self.conversationMessages = conversationMessages
        self.currentSQL = currentSQL
        self.lastRunError = lastRunError
        self.repairContext = repairContext
        self.schemaSearchQueries = schemaSearchQueries
        self.modelCallCount = modelCallCount
        self.confirmedSemanticBindings = confirmedSemanticBindings
    }

    public var isEmpty: Bool {
        recentQuestions.isEmpty && originalQuestion == nil && conversationMessages.isEmpty
            && currentSQL == nil && lastRunError == nil && repairContext == nil
            && schemaSearchQueries.isEmpty && modelCallCount == 0
            && confirmedSemanticBindings.isEmpty && mode == .initial
    }
}

public struct SchemaDiscoveryRequestResult: Codable, Equatable, Sendable {
    public var searchQueries: [String]
    public var reason: String

    public init(searchQueries: [String], reason: String) {
        self.searchQueries = Array(searchQueries.prefix(3))
        self.reason = reason
    }

    public var sanitizedSearchQueries: [String] {
        var seen = Set<String>()
        return searchQueries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(3)
            .map { $0 }
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

/// Marker for the constrained on-device SQL path. The shared pipeline uses
/// this to apply stricter experimental limits without weakening cloud repair.
public protocol ConstrainedLocalSQLGenerator: SQLGenerator {}

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
