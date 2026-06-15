import Foundation

/// A persistent query session tied to one database connection: the chat
/// transcript, the SQL editor contents, and the last generation metadata.
/// Runtime-only state (query results, validation, in-flight flags, the input
/// draft) is intentionally never persisted.
public struct QuerySession: Identifiable, Codable, Equatable, Sendable {
    public static let placeholderTitle = "New Session"

    public struct ViewDataTarget: Codable, Equatable, Sendable {
        public var schema: String
        public var table: String

        public var tableID: String { "\(schema).\(table)" }
        public var qualifiedName: String { "\(schema).\(table)" }

        public init(schema: String, table: String) {
            self.schema = schema
            self.table = table
        }

        public init(table: TableInfo) {
            self.init(schema: table.schema, table: table.name)
        }
    }

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
    /// Present for deterministic "View Data" sessions so they can be reused
    /// even after the user edits the SQL or continues the conversation.
    public var viewDataTarget: ViewDataTarget?
    /// Archived sessions are hidden from the sidebar and recoverable from
    /// Settings.
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public var displayTitle: String {
        guard title != Self.placeholderTitle else { return title }
        return SessionTitleFallback.titleCase(title)
    }

    public init(
        id: UUID = UUID(),
        connectionID: UUID,
        title: String = QuerySession.placeholderTitle,
        titleWasManuallySet: Bool = false,
        messages: [ChatMessage] = [],
        sqlText: String = "",
        lastGeneration: SQLGenerationResult? = nil,
        viewDataTarget: ViewDataTarget? = nil,
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
        self.viewDataTarget = viewDataTarget
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
