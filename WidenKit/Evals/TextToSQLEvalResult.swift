import Foundation

public enum TextToSQLEvalBackend: String, Codable, CaseIterable, Equatable, Sendable {
    case cloud

    public static let removedOnDeviceBackendMessage =
        "Eval results from the removed on-device backend (\"local\") cannot be resumed or triaged."

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let backend = Self(rawValue: rawValue) {
            self = backend
        } else if rawValue == "local" {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: Self.removedOnDeviceBackendMessage
            )
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown eval backend \"\(rawValue)\"."
            )
        }
    }
}

public enum TextToSQLEvalCaseStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case passed
    case semanticReviewRequired
    case semanticEnvironmentUnavailable
    case fixtureInvalid
    case wrongDecision
    case invalidSQL
    case wrongSchemaObjects
    case contextWindowFailure
    case generationFailure
    case evalTimeout
    case transportFailure
    case paymentRequired
    case providerLimit
    case skippedBudgetLimit
    case parseFailure
    case backendUnavailable
}

public enum TextToSQLSemanticStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case passed
    case resultMismatch
    case candidateExecutionFailure
    case goldenFixtureFailure
    case resultLimitExceeded
    case semanticEnvironmentUnavailable
    case fixtureInvalid
    case notApplicable
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
    /// The token counts behind `tokenUsage`. Nil when the provider did not
    /// report them, and in results written before they were recorded.
    public var promptTokens: Int?
    /// Prompt tokens served from the provider's prompt cache.
    public var cachedPromptTokens: Int?
    public var completionTokens: Int?
    /// Reasoning tokens, which are billed and counted as completion tokens.
    public var reasoningTokens: Int?
    public var estimatedCloudCostUSD: Double?
    /// A `CloudCostSource` raw value for `estimatedCloudCostUSD`: `reported`
    /// by the provider, or `estimatedPeakList` from token prices (an upper
    /// bound). Nil when no cost was recorded, and in results written before
    /// the source was recorded.
    public var estimatedCloudCostSource: String?
    public var openRouterStructuredOutputMode: String?
    public var openRouterRetryCount: Int?
    public var openRouterRequestedModelID: String?
    public var openRouterReturnedModelID: String?
    public var openRouterProviderName: String?
    public var openRouterAgentSelectionReason: String?
    public var openRouterAgentLogicalTurnCount: Int?
    public var openRouterAgentHTTPAttemptCount: Int?
    public var openRouterSchemaToolCallCount: Int?
    public var openRouterInspectionToolCallCount: Int?
    public var openRouterAgentTerminalOutcome: String?
    public var openRouterAgentDiagnostics: SchemaToolAgentDiagnostics?
    public var postgresVerificationStatus: SQLVerificationStatus?
    public var postgresVerificationSQLState: String?
    public var postgresVerificationDiagnosticKind: DatabaseDiagnosticKind?
    public var postgresVerificationElapsedMs: Int?
    public var postgresVerificationRepairAttempted: Bool?
    public var semanticExecutionAttempted: Bool?
    public var semanticEnvironmentAvailable: Bool?
    public var goldenExecutionSucceeded: Bool?
    public var candidateExecutionSucceeded: Bool?
    public var resultEquivalent: Bool?
    public var endToEndPassed: Bool?
    public var semanticStatus: TextToSQLSemanticStatus?
    public var goldenRowCount: Int?
    public var candidateRowCount: Int?
    public var comparisonMode: TextToSQLResultComparisonMode?
    public var executionLatencyMs: Int?
    public var goldenResultDigest: String?
    public var candidateResultDigest: String?
    public var semanticMismatchCategory: String?
    /// True when the grounding postprocessor replaced the generated SQL with
    /// the clarification this result answered with. Nil otherwise, and in
    /// results written before it was recorded. The SQL itself is never
    /// written; see `TextToSQLEvalResult.withheldSQL`.
    public var groundingWithheldSQL: Bool?
    /// How the withheld SQL compared with the golden SQL on the seeded
    /// database, for results that expected SQL in a semantic run:
    /// `candidateExecutionFailure` when the safety or schema guards stopped
    /// it before execution. It never changes `status` or `endToEndPassed`.
    public var withheldSQLSemanticStatus: TextToSQLSemanticStatus?
    /// Whether the withheld SQL matched the golden result; false when the
    /// guards stopped it. Nil when it was not compared, or when the golden
    /// SQL or the database failed and the comparison could not judge it.
    public var withheldSQLSemanticPassed: Bool?

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
        promptTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        completionTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        estimatedCloudCostUSD: Double? = nil,
        estimatedCloudCostSource: String? = nil,
        openRouterStructuredOutputMode: String? = nil,
        openRouterRetryCount: Int? = nil,
        openRouterRequestedModelID: String? = nil,
        openRouterReturnedModelID: String? = nil,
        openRouterProviderName: String? = nil,
        openRouterAgentSelectionReason: String? = nil,
        openRouterAgentLogicalTurnCount: Int? = nil,
        openRouterAgentHTTPAttemptCount: Int? = nil,
        openRouterSchemaToolCallCount: Int? = nil,
        openRouterInspectionToolCallCount: Int? = nil,
        openRouterAgentTerminalOutcome: String? = nil,
        openRouterAgentDiagnostics: SchemaToolAgentDiagnostics? = nil,
        postgresVerificationStatus: SQLVerificationStatus? = nil,
        postgresVerificationSQLState: String? = nil,
        postgresVerificationDiagnosticKind: DatabaseDiagnosticKind? = nil,
        postgresVerificationElapsedMs: Int? = nil,
        postgresVerificationRepairAttempted: Bool? = nil,
        semanticExecutionAttempted: Bool? = nil,
        semanticEnvironmentAvailable: Bool? = nil,
        goldenExecutionSucceeded: Bool? = nil,
        candidateExecutionSucceeded: Bool? = nil,
        resultEquivalent: Bool? = nil,
        endToEndPassed: Bool? = nil,
        semanticStatus: TextToSQLSemanticStatus? = nil,
        goldenRowCount: Int? = nil,
        candidateRowCount: Int? = nil,
        comparisonMode: TextToSQLResultComparisonMode? = nil,
        executionLatencyMs: Int? = nil,
        goldenResultDigest: String? = nil,
        candidateResultDigest: String? = nil,
        semanticMismatchCategory: String? = nil,
        groundingWithheldSQL: Bool? = nil,
        withheldSQLSemanticStatus: TextToSQLSemanticStatus? = nil,
        withheldSQLSemanticPassed: Bool? = nil
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
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.estimatedCloudCostUSD = estimatedCloudCostUSD
        self.estimatedCloudCostSource = estimatedCloudCostSource
        self.openRouterStructuredOutputMode = openRouterStructuredOutputMode
        self.openRouterRetryCount = openRouterRetryCount
        self.openRouterRequestedModelID = openRouterRequestedModelID
        self.openRouterReturnedModelID = openRouterReturnedModelID
        self.openRouterProviderName = openRouterProviderName
        self.openRouterAgentSelectionReason = openRouterAgentSelectionReason
        self.openRouterAgentLogicalTurnCount = openRouterAgentLogicalTurnCount
        self.openRouterAgentHTTPAttemptCount = openRouterAgentHTTPAttemptCount
        self.openRouterSchemaToolCallCount = openRouterSchemaToolCallCount
        self.openRouterInspectionToolCallCount = openRouterInspectionToolCallCount
        self.openRouterAgentTerminalOutcome = openRouterAgentTerminalOutcome
        self.openRouterAgentDiagnostics = openRouterAgentDiagnostics
        self.postgresVerificationStatus = postgresVerificationStatus
        self.postgresVerificationSQLState = postgresVerificationSQLState
        self.postgresVerificationDiagnosticKind = postgresVerificationDiagnosticKind
        self.postgresVerificationElapsedMs = postgresVerificationElapsedMs
        self.postgresVerificationRepairAttempted = postgresVerificationRepairAttempted
        self.semanticExecutionAttempted = semanticExecutionAttempted
        self.semanticEnvironmentAvailable = semanticEnvironmentAvailable
        self.goldenExecutionSucceeded = goldenExecutionSucceeded
        self.candidateExecutionSucceeded = candidateExecutionSucceeded
        self.resultEquivalent = resultEquivalent
        self.endToEndPassed = endToEndPassed
        self.semanticStatus = semanticStatus
        self.goldenRowCount = goldenRowCount
        self.candidateRowCount = candidateRowCount
        self.comparisonMode = comparisonMode
        self.executionLatencyMs = executionLatencyMs
        self.goldenResultDigest = goldenResultDigest
        self.candidateResultDigest = candidateResultDigest
        self.semanticMismatchCategory = semanticMismatchCategory
        self.groundingWithheldSQL = groundingWithheldSQL
        self.withheldSQLSemanticStatus = withheldSQLSemanticStatus
        self.withheldSQLSemanticPassed = withheldSQLSemanticPassed
    }
}

public struct TextToSQLEvalDiagnostics: Codable, Equatable, Sendable {
    public var missingTables: [String]
    public var missingColumnBindings: [String]
    public var missingOperations: [TextToSQLEvalOperation]
    public var safetyErrors: [String]
    public var schemaErrors: [String]
    public var errorMessage: String?
    public var openRouterFailureCategory: String?
    public var openRouterHTTPStatus: Int?
    public var openRouterErrorType: String?
    public var openRouterProviderCode: String?
    public var openRouterCompletionID: String?
    public var openRouterRequestID: String?
    public var openRouterRequestedModelID: String?
    public var openRouterReturnedModelID: String?
    public var openRouterProviderName: String?
    public var openRouterRetryAfterSeconds: Double?
    public var openRouterSuggestedWaitSeconds: Double?
    public var openRouterAttemptCount: Int?
    public var postgresVerificationSQLState: String?
    public var postgresVerificationDiagnosticKind: DatabaseDiagnosticKind?
    public var postgresVerificationMessage: String?

    public init(
        missingTables: [String] = [],
        missingColumnBindings: [String] = [],
        missingOperations: [TextToSQLEvalOperation] = [],
        safetyErrors: [String] = [],
        schemaErrors: [String] = [],
        errorMessage: String? = nil,
        openRouterFailure: CloudRequestFailureDiagnostic? = nil,
        postgresVerificationDiagnostic: DatabaseDiagnostic? = nil
    ) {
        self.missingTables = missingTables
        self.missingColumnBindings = missingColumnBindings
        self.missingOperations = missingOperations
        self.safetyErrors = safetyErrors
        self.schemaErrors = schemaErrors
        self.errorMessage = errorMessage
        self.openRouterFailureCategory = openRouterFailure?.category.rawValue
        self.openRouterHTTPStatus = openRouterFailure?.httpStatus
        self.openRouterErrorType = openRouterFailure?.providerErrorType
        self.openRouterProviderCode = openRouterFailure?.providerCode
        self.openRouterCompletionID = openRouterFailure?.completionID
        self.openRouterRequestID = openRouterFailure?.requestID
        self.openRouterRequestedModelID = openRouterFailure?.requestedModelID
        self.openRouterReturnedModelID = openRouterFailure?.returnedModelID
        self.openRouterProviderName = openRouterFailure?.providerName
        self.openRouterRetryAfterSeconds = openRouterFailure?.retryAfterSeconds
        self.openRouterSuggestedWaitSeconds = openRouterFailure?.suggestedWaitSeconds
        self.openRouterAttemptCount = openRouterFailure?.attemptCount
        self.postgresVerificationSQLState = postgresVerificationDiagnostic?.sqlState
        self.postgresVerificationDiagnosticKind = postgresVerificationDiagnostic?.kind
        self.postgresVerificationMessage = postgresVerificationDiagnostic?.message
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
    public var trace: TextToSQLTrace?
    /// The SQL the grounding postprocessor withheld, kept in memory so a
    /// semantic run can score it. It is not encoded: cases.jsonl records only
    /// `metrics.groundingWithheldSQL` and the withheld SQL's semantic status,
    /// and a decoded result has none. `generatedSQL` stays the SQL the
    /// result answered with.
    public var withheldSQL: String? = nil

    private enum CodingKeys: String, CodingKey {
        case caseID
        case backend
        case model
        case repeatIndex
        case status
        case metrics
        case diagnostics
        case generatedSQL
        case clarificationQuestion
        case referencedTables
        case referencedColumnBindings
        case estimatedInitialPrompt
        case trace
    }

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
        estimatedInitialPrompt: String? = nil,
        trace: TextToSQLTrace? = nil
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
        self.trace = trace
    }
}
