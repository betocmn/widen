import Foundation

public enum TextToSQLEvalBackend: String, Codable, CaseIterable, Equatable, Sendable {
    case local
    case cloud
}

public enum TextToSQLEvalCaseStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case passed
    case semanticReviewRequired
    case wrongDecision
    case invalidSQL
    case wrongSchemaObjects
    case contextWindowFailure
    case generationFailure
    case transportFailure
    case parseFailure
    case backendUnavailable
}

public struct TextToSQLEvalMetrics: Codable, Equatable, Sendable {
    public var backendAvailable: Bool
    public var transportSuccess: Bool
    public var structuredResponseParsed: Bool
    public var decisionMatches: Bool
    public var safetyValid: Bool?
    public var schemaValid: Bool?
    public var requiredTableCoverage: Double?
    public var requiredColumnBindingCoverage: Double?
    public var forbiddenBindingViolations: [String]
    public var clarificationQuality: Bool?
    public var latencyMs: Int
    public var modelCallCount: Int?
    public var estimatedInitialPromptCharacters: Int?
    public var tokenUsage: Int?
    public var estimatedCloudCostUSD: Double?

    public init(
        backendAvailable: Bool,
        transportSuccess: Bool,
        structuredResponseParsed: Bool,
        decisionMatches: Bool,
        safetyValid: Bool? = nil,
        schemaValid: Bool? = nil,
        requiredTableCoverage: Double? = nil,
        requiredColumnBindingCoverage: Double? = nil,
        forbiddenBindingViolations: [String] = [],
        clarificationQuality: Bool? = nil,
        latencyMs: Int,
        modelCallCount: Int? = nil,
        estimatedInitialPromptCharacters: Int? = nil,
        tokenUsage: Int? = nil,
        estimatedCloudCostUSD: Double? = nil
    ) {
        self.backendAvailable = backendAvailable
        self.transportSuccess = transportSuccess
        self.structuredResponseParsed = structuredResponseParsed
        self.decisionMatches = decisionMatches
        self.safetyValid = safetyValid
        self.schemaValid = schemaValid
        self.requiredTableCoverage = requiredTableCoverage
        self.requiredColumnBindingCoverage = requiredColumnBindingCoverage
        self.forbiddenBindingViolations = forbiddenBindingViolations
        self.clarificationQuality = clarificationQuality
        self.latencyMs = latencyMs
        self.modelCallCount = modelCallCount
        self.estimatedInitialPromptCharacters = estimatedInitialPromptCharacters
        self.tokenUsage = tokenUsage
        self.estimatedCloudCostUSD = estimatedCloudCostUSD
    }
}

public struct TextToSQLEvalDiagnostics: Codable, Equatable, Sendable {
    public var missingTables: [String]
    public var missingColumnBindings: [String]
    public var missingOperations: [TextToSQLEvalOperation]
    public var safetyErrors: [String]
    public var schemaErrors: [String]
    public var errorMessage: String?

    public init(
        missingTables: [String] = [],
        missingColumnBindings: [String] = [],
        missingOperations: [TextToSQLEvalOperation] = [],
        safetyErrors: [String] = [],
        schemaErrors: [String] = [],
        errorMessage: String? = nil
    ) {
        self.missingTables = missingTables
        self.missingColumnBindings = missingColumnBindings
        self.missingOperations = missingOperations
        self.safetyErrors = safetyErrors
        self.schemaErrors = schemaErrors
        self.errorMessage = errorMessage
    }
}

public struct TextToSQLEvalResult: Codable, Equatable, Sendable {
    public var caseID: String
    public var backend: TextToSQLEvalBackend
    public var model: String?
    public var repeatIndex: Int
    public var status: TextToSQLEvalCaseStatus
    public var metrics: TextToSQLEvalMetrics
    public var diagnostics: TextToSQLEvalDiagnostics
    public var generatedSQL: String?
    public var clarificationQuestion: String?
    public var referencedTables: [String]
    public var referencedColumnBindings: [String]
    public var estimatedInitialPrompt: String?

    public init(
        caseID: String,
        backend: TextToSQLEvalBackend,
        model: String? = nil,
        repeatIndex: Int,
        status: TextToSQLEvalCaseStatus,
        metrics: TextToSQLEvalMetrics,
        diagnostics: TextToSQLEvalDiagnostics = TextToSQLEvalDiagnostics(),
        generatedSQL: String? = nil,
        clarificationQuestion: String? = nil,
        referencedTables: [String] = [],
        referencedColumnBindings: [String] = [],
        estimatedInitialPrompt: String? = nil
    ) {
        self.caseID = caseID
        self.backend = backend
        self.model = model
        self.repeatIndex = repeatIndex
        self.status = status
        self.metrics = metrics
        self.diagnostics = diagnostics
        self.generatedSQL = generatedSQL
        self.clarificationQuestion = clarificationQuestion
        self.referencedTables = referencedTables
        self.referencedColumnBindings = referencedColumnBindings
        self.estimatedInitialPrompt = estimatedInitialPrompt
    }
}
