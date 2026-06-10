import Foundation

/// One entry in a session's chat transcript. Persisted as part of
/// `QuerySession`, so the whole struct is Codable.
public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Equatable, Sendable {
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
