import Foundation

/// A persistent query session tied to one database connection: the chat
/// transcript, the SQL editor contents, and the last generation metadata.
/// Runtime-only state (query results, validation, in-flight flags, the input
/// draft) is intentionally never persisted.
public struct QuerySession: Identifiable, Codable, Equatable, Sendable {
    public static let placeholderTitle = "New Session"

    public var id: UUID
    public var connectionID: UUID
    public var title: String
    /// True once the user renamed the session; guards the LLM auto-rename.
    public var titleWasManuallySet: Bool
    public var messages: [ChatMessage]
    /// SQL editor contents.
    public var sqlText: String
    /// Metadata of the last model generation that filled the editor.
    public var lastGeneration: SQLGenerationResult?
    /// Archived sessions are hidden from the sidebar and recoverable from
    /// Settings.
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        connectionID: UUID,
        title: String = QuerySession.placeholderTitle,
        titleWasManuallySet: Bool = false,
        messages: [ChatMessage] = [],
        sqlText: String = "",
        lastGeneration: SQLGenerationResult? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.connectionID = connectionID
        self.title = title
        self.titleWasManuallySet = titleWasManuallySet
        self.messages = messages
        self.sqlText = sqlText
        self.lastGeneration = lastGeneration
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
