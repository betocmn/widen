import Foundation

/// A backend that turns an English question plus a schema into one read-only
/// PostgreSQL query. Implementations: `FoundationModelsSQLGenerator` (Apple's
/// on-device model) and `MockSQLGenerator` (tests / developer mode).
public protocol SQLGenerator: Sendable {
    func generateSQL(
        question: String,
        schema: DatabaseSchema,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult
}
