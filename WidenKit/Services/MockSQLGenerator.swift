import Foundation

/// Deterministic stand-in for the real model. Used in tests, when
/// FoundationModels is unavailable at compile time, and behind the
/// "Use mock AI" developer toggle.
public struct MockSQLGenerator: SQLGenerator {
    public init() {}

    public func generateSQL(
        question: String,
        schema: DatabaseSchema,
        config: SQLGenerationConfig
    ) async throws -> SQLGenerationResult {
        SQLGenerationResult(
            sql: "SELECT 1 AS test_value",
            explanation:
                "Mock mode returned a constant query instead of answering: “\(question)”.",
            assumptions: ["Mock AI mode is enabled — no language model was used."],
            referencedTables: [],
            confidence: 1.0,
            riskLevel: .low,
            needsClarification: false,
            clarificationQuestion: nil
        )
    }
}
