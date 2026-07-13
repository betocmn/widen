import Foundation

public enum SQLRiskLevel: String, Codable, CaseIterable, Equatable, Sendable {
    case low
    case medium
    case high
}

public enum GroundingState: String, Codable, Equatable, Sendable {
    case grounded
    case ambiguous
    case unsupported
    case notRequired
}

public struct SQLGroundingConcept: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case entity
        case metric
        case relationship
        case filter
        case time
        case businessTerm
    }

    public var id: UUID
    public var term: String
    public var kind: Kind
    public var state: GroundingState
    public var required: Bool
    public var evidence: [String]

    public init(
        id: UUID = UUID(),
        term: String,
        kind: Kind,
        state: GroundingState,
        required: Bool,
        evidence: [String] = []
    ) {
        self.id = id
        self.term = term
        self.kind = kind
        self.state = state
        self.required = required
        self.evidence = evidence
    }
}

public struct ClarificationOption: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var replyText: String
    public var definition: String
    public var evidence: [String]

    public init(
        id: UUID = UUID(),
        label: String,
        replyText: String,
        definition: String,
        evidence: [String] = []
    ) {
        self.id = id
        self.label = label
        self.replyText = replyText
        self.definition = definition
        self.evidence = evidence
    }
}

public struct PendingClarification: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var concept: SQLGroundingConcept
    public var originalQuestion: String
    public var question: String
    public var options: [ClarificationOption]
    public var evidence: [String]

    public init(
        id: UUID = UUID(),
        concept: SQLGroundingConcept,
        originalQuestion: String,
        question: String,
        options: [ClarificationOption] = [],
        evidence: [String] = []
    ) {
        self.id = id
        self.concept = concept
        self.originalQuestion = originalQuestion
        self.question = question
        self.options = options
        self.evidence = evidence
    }
}

public struct SQLGroundingEvaluation: Codable, Equatable, Sendable {
    public var concepts: [SQLGroundingConcept]
    public var pendingClarification: PendingClarification?

    public init(
        concepts: [SQLGroundingConcept],
        pendingClarification: PendingClarification? = nil
    ) {
        self.concepts = concepts
        self.pendingClarification = pendingClarification
    }
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
    public var generationSchemaName: String?
    public var generationCallCount: Int?
    public var groundingConcepts: [SQLGroundingConcept]
    public var clarificationOptions: [ClarificationOption]
    public var pendingClarificationID: UUID?
    public var pendingClarification: PendingClarification?
    public var backendMetadata: OpenRouterGenerationMetadata?
    public var schemaToolCalls: [SchemaToolCallTrace]
    public var inspectionToolCalls: [DatabaseInspectionToolCallTrace]

    private enum CodingKeys: String, CodingKey {
        case sql
        case explanation
        case assumptions
        case referencedTables
        case confidence
        case riskLevel
        case needsClarification
        case clarificationQuestion
        case generationSchemaName
        case generationCallCount
        case groundingConcepts
        case clarificationOptions
        case pendingClarificationID
        case pendingClarification
        case backendMetadata
        case schemaToolCalls
        case inspectionToolCalls
    }

    public init(
        sql: String,
        explanation: String,
        assumptions: [String],
        referencedTables: [String],
        confidence: Double,
        riskLevel: SQLRiskLevel,
        needsClarification: Bool,
        clarificationQuestion: String?,
        generationSchemaName: String? = nil,
        generationCallCount: Int? = nil,
        groundingConcepts: [SQLGroundingConcept] = [],
        clarificationOptions: [ClarificationOption] = [],
        pendingClarificationID: UUID? = nil,
        pendingClarification: PendingClarification? = nil,
        backendMetadata: OpenRouterGenerationMetadata? = nil,
        schemaToolCalls: [SchemaToolCallTrace] = [],
        inspectionToolCalls: [DatabaseInspectionToolCallTrace] = []
    ) {
        self.sql = sql
        self.explanation = explanation
        self.assumptions = assumptions
        self.referencedTables = referencedTables
        self.confidence = confidence
        self.riskLevel = riskLevel
        self.needsClarification = needsClarification
        self.clarificationQuestion = clarificationQuestion
        self.generationSchemaName = generationSchemaName
        self.generationCallCount = generationCallCount
        self.groundingConcepts = groundingConcepts
        self.clarificationOptions = clarificationOptions
        self.pendingClarificationID = pendingClarificationID
        self.pendingClarification = pendingClarification
        self.backendMetadata = backendMetadata
        self.schemaToolCalls = schemaToolCalls
        self.inspectionToolCalls = inspectionToolCalls
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sql = try container.decode(String.self, forKey: .sql)
        explanation = try container.decode(String.self, forKey: .explanation)
        assumptions = try container.decode([String].self, forKey: .assumptions)
        referencedTables = try container.decode([String].self, forKey: .referencedTables)
        confidence = try container.decode(Double.self, forKey: .confidence)
        riskLevel = try container.decode(SQLRiskLevel.self, forKey: .riskLevel)
        needsClarification = try container.decode(Bool.self, forKey: .needsClarification)
        clarificationQuestion = try container.decodeIfPresent(
            String.self,
            forKey: .clarificationQuestion
        )
        generationSchemaName = try container.decodeIfPresent(
            String.self,
            forKey: .generationSchemaName
        )
        generationCallCount = try container.decodeIfPresent(
            Int.self,
            forKey: .generationCallCount
        )
        groundingConcepts = try container.decodeIfPresent(
            [SQLGroundingConcept].self,
            forKey: .groundingConcepts
        ) ?? []
        clarificationOptions = try container.decodeIfPresent(
            [ClarificationOption].self,
            forKey: .clarificationOptions
        ) ?? []
        pendingClarificationID = try container.decodeIfPresent(
            UUID.self,
            forKey: .pendingClarificationID
        )
        pendingClarification = try container.decodeIfPresent(
            PendingClarification.self,
            forKey: .pendingClarification
        )
        backendMetadata = try container.decodeIfPresent(
            OpenRouterGenerationMetadata.self,
            forKey: .backendMetadata
        )
        schemaToolCalls = try container.decodeIfPresent(
            [SchemaToolCallTrace].self,
            forKey: .schemaToolCalls
        ) ?? []
        inspectionToolCalls = try container.decodeIfPresent(
            [DatabaseInspectionToolCallTrace].self,
            forKey: .inspectionToolCalls
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sql, forKey: .sql)
        try container.encode(explanation, forKey: .explanation)
        try container.encode(assumptions, forKey: .assumptions)
        try container.encode(referencedTables, forKey: .referencedTables)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(riskLevel, forKey: .riskLevel)
        try container.encode(needsClarification, forKey: .needsClarification)
        try container.encodeIfPresent(clarificationQuestion, forKey: .clarificationQuestion)
        try container.encodeIfPresent(generationSchemaName, forKey: .generationSchemaName)
        try container.encodeIfPresent(generationCallCount, forKey: .generationCallCount)
        if !groundingConcepts.isEmpty {
            try container.encode(groundingConcepts, forKey: .groundingConcepts)
        }
        if !clarificationOptions.isEmpty {
            try container.encode(clarificationOptions, forKey: .clarificationOptions)
        }
        try container.encodeIfPresent(pendingClarificationID, forKey: .pendingClarificationID)
        try container.encodeIfPresent(pendingClarification, forKey: .pendingClarification)
        try container.encodeIfPresent(backendMetadata, forKey: .backendMetadata)
        if !schemaToolCalls.isEmpty {
            try container.encode(schemaToolCalls, forKey: .schemaToolCalls)
        }
        if !inspectionToolCalls.isEmpty {
            try container.encode(inspectionToolCalls, forKey: .inspectionToolCalls)
        }
    }
}

extension SQLGenerationResult {
    /// Multi-line summary for the generation debug log, shared by every
    /// generator backend.
    var logDescription: String {
        """
        sql: \(sql)
        explanation: \(explanation)
        assumptions: \(assumptions.joined(separator: " | "))
        referencedTables: \(referencedTables.joined(separator: ", "))
        confidence: \(confidence) · risk: \(riskLevel.rawValue) · needsClarification: \(needsClarification)
        clarificationQuestion: \(clarificationQuestion ?? "-")
        generationCallCount: \(generationCallCount.map(String.init) ?? "-")
        groundingConcepts: \(groundingConcepts.map { "\($0.term):\($0.state.rawValue)" }.joined(separator: ", "))
        """
    }
}

struct SQLGenerationUsageEvent: Equatable, Sendable {
    var httpAttemptCount: Int
    var promptTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    var totalTokens: Int?
    var costUSD: Double?

    static func httpAttempts(_ count: Int) -> SQLGenerationUsageEvent {
        SQLGenerationUsageEvent(
            httpAttemptCount: max(0, count),
            promptTokens: nil,
            completionTokens: nil,
            reasoningTokens: nil,
            totalTokens: nil,
            costUSD: nil
        )
    }
}

public struct SQLGenerationConfig: Equatable, Sendable {
    public var defaultRowLimit: Int
    public var databaseContext: String
    var usageSink: (@Sendable (SQLGenerationUsageEvent) -> Void)?

    public init(defaultRowLimit: Int = 100, databaseContext: String = "") {
        self.defaultRowLimit = defaultRowLimit
        self.databaseContext = databaseContext
        usageSink = nil
    }

    public static func == (lhs: SQLGenerationConfig, rhs: SQLGenerationConfig) -> Bool {
        lhs.defaultRowLimit == rhs.defaultRowLimit
            && lhs.databaseContext == rhs.databaseContext
    }
}
