import Foundation

/// One entry in the (session-only, in-memory) chat transcript.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case user
        case assistant
        case error
    }

    public let id: UUID
    public var role: Role
    public var text: String
    /// Present on assistant messages produced by a generation.
    public var generation: SQLGenerationResult?
    public var timestamp: Date

    public init(role: Role, text: String, generation: SQLGenerationResult? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.generation = generation
        self.timestamp = Date()
    }
}
