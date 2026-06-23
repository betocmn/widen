import Foundation

public struct UnavailableSQLGenerator: SQLGenerator, Sendable {
    private let message: String

    public init(message: String) {
        self.message = message
    }

    public func generateSQL(
        question: String,
        schema: DatabaseSchema,
        context: SQLGenerationContext,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult {
        throw SQLGenerationFailure.backendUnavailable(message)
    }
}
