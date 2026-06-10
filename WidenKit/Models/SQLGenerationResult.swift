import Foundation

public enum SQLRiskLevel: String, Codable, CaseIterable, Equatable, Sendable {
    case low
    case medium
    case high
}

/// Structured output of a SQL generation request.
public struct SQLGenerationResult: Codable, Equatable, Sendable {
    public var sql: String
    public var explanation: String
    public var assumptions: [String]
    public var referencedTables: [String]
    public var confidence: Double
    public var riskLevel: SQLRiskLevel
    public var needsClarification: Bool
    public var clarificationQuestion: String?

    public init(
        sql: String,
        explanation: String,
        assumptions: [String],
        referencedTables: [String],
        confidence: Double,
        riskLevel: SQLRiskLevel,
        needsClarification: Bool,
        clarificationQuestion: String?
    ) {
        self.sql = sql
        self.explanation = explanation
        self.assumptions = assumptions
        self.referencedTables = referencedTables
        self.confidence = confidence
        self.riskLevel = riskLevel
        self.needsClarification = needsClarification
        self.clarificationQuestion = clarificationQuestion
    }
}

public struct SQLGenerationConfig: Equatable, Sendable {
    public var defaultRowLimit: Int

    public init(defaultRowLimit: Int = 100) {
        self.defaultRowLimit = defaultRowLimit
    }
}
